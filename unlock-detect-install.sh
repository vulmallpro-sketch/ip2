#!/bin/bash
set -e
if [ -n "$DEBUG_INSTALL" ]; then
	set -x
fi

warning() { echo -e "\033[31m\033[01m$*\033[0m"; }
error()   { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info()    { echo -e "\033[32m\033[01m$*\033[0m"; }
hint()    { echo -e "\033[33m\033[01m$*\033[0m"; }

APT_UPDATED=0

apt_install() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    apt-get update -qq
    APT_UPDATED=1
  fi
  apt-get install -y "$@"
}

if [ "$EUID" -ne 0 ]; then
	error "请用 root 权限运行"
fi

#### 服务名（支持静默安装 S=xxx）

if [ -z "$S" ]; then
	read -p "请输入服务名 [默认 unlock-detect] : " service_name
	service_name=${service_name:-unlock-detect}
	if [[ ! "$service_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
		error "服务名不符合规则，只接受英文和数字。"
	fi
else
	service_name="$S"
fi

INSTALL_DIR="/opt/${service_name}"

echo_uninstall() {
	echo "systemctl disable --now $1 ; rm -f /etc/systemd/system/$1.service ; rm -rf /opt/$1"
}

if [ -f "/etc/systemd/system/${service_name}.service" ]; then
	hint "该服务已存在，请先运行以下命令卸载："
	echo_uninstall "$service_name"
	read -p "或者输入 [r] 彻底重装（不保留token）: " reinstall
	if [ "${reinstall,,}" == "r" ]; then
		rm -rf "$INSTALL_DIR"
	else
		exit
	fi
fi

command -v python3 >/dev/null 2>&1 || { info "安装 python3..."; apt_install python3; }
command -v curl    >/dev/null 2>&1 || { info "安装 curl...";    apt_install curl; }

if ! command -v pip3 >/dev/null 2>&1; then
  info "安装 pip3..."
  if ! apt_install python3-pip; then
    python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
  python3 -m pip --version >/dev/null 2>&1 || error "pip3 安装失败，请手动安装 python3-pip 后重试"
fi

python3 -m pip install flask requests --break-system-packages -q 2>/dev/null \
    || python3 -m pip install flask requests -q

# PORT 支持环境变量或首参数，默认 3000
# INTERVAL 支持环境变量，默认 1800（秒），即每 30 分钟自动检测一次
PORT="${PORT:-${1:-3000}}"
INTERVAL="${INTERVAL:-1800}"

mkdir -p "$INSTALL_DIR"

CONFIG_PATH="${INSTALL_DIR}/config.json"
if [ ! -f "$CONFIG_PATH" ]; then
	SHOW_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(8))")
	cat > "$CONFIG_PATH" <<EOF
{
  "show_token": "${SHOW_TOKEN}",
  "port": ${PORT},
  "check_interval": ${INTERVAL}
}
EOF
	chmod 600 "$CONFIG_PATH"
else
	info "检测到已有配置，复用现有 token"
fi

cat > "${INSTALL_DIR}/app.py" <<'PYEOF'
import os, json, time, threading, re, logging, concurrent.futures
import requests
from flask import Flask, jsonify, request

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger(__name__)

app = Flask(__name__)
BASE = os.path.dirname(os.path.abspath(__file__))

with open(os.path.join(BASE, 'config.json')) as f:
    cfg = json.load(f)

SHOW_TOKEN     = cfg["show_token"]
PORT           = cfg.get("port", 8080)
CHECK_INTERVAL = cfg.get("check_interval", 1800)
RESULT_PATH    = os.path.join(BASE, 'result.json')

TIMEOUT = 12
UA = (
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/141.0.0.0 Safari/537.36'
)
HEADERS = {
    'User-Agent': UA,
    'Accept-Language': 'en-US,en;q=0.9',
}

# ─── 工具函数 ────────────────────────────────────────────────

def _cf_loc(domain):
    """通过 Cloudflare trace 获取出口地区码"""
    try:
        r = requests.get(
            f'https://{domain}/cdn-cgi/trace',
            headers={'User-Agent': UA}, timeout=TIMEOUT
        )
        for line in r.text.splitlines():
            if line.startswith('loc='):
                return line[4:].strip().upper()
    except Exception:
        pass
    return None

def _norm(region):
    v = str(region or '').strip().upper()
    return v if re.fullmatch(r'[A-Z]{2,3}', v) else ''

# ─── 各平台检测函数 ──────────────────────────────────────────

def check_exit_ip():
    try:
        r = requests.get('https://api.ip.sb/geoip', headers={'User-Agent': UA}, timeout=TIMEOUT)
        d = r.json()
        region = _norm(d.get('country_code'))
        place  = ' · '.join(filter(None, [d.get('country'), d.get('city')]))
        network = ' · '.join(filter(None, [d.get('isp'), d.get('ip')]))
        return {
            "status": "available",
            "region": region,
            "detail": '\n'.join(filter(None, [place, network])) or '已获取出口信息',
            "ip": d.get('ip'),
        }
    except Exception as e:
        return {"status": "error", "detail": str(e)}


def check_youtube():
    try:
        r = requests.get(
            'https://www.youtube.com/premium',
            headers={**HEADERS}, timeout=TIMEOUT
        )
        body = r.text
        m = (re.search(r'"INNERTUBE_CONTEXT_GL"\s*:\s*"([A-Z]{2})"', body)
             or re.search(r'"GL"\s*:\s*"([A-Z]{2})"', body))
        region = m.group(1) if m else ''
        if 'www.google.cn' in body or re.search(r'Premium is not available in your country', body, re.I):
            return {"status": "unavailable", "detail": "当前地区不可用", "region": region}
        if r.status_code == 200 and (re.search(r'ad-free', body, re.I) or m):
            return {"status": "available", "detail": "完整可用", "region": region}
        return {"status": "error", "detail": f"检测失败 · HTTP {r.status_code}", "region": region}
    except Exception as e:
        return {"status": "error", "detail": str(e)}


def check_netflix(exit_region=''):
    try:
        r = requests.get(
            'https://www.netflix.com/title/81280792',
            headers={
                **HEADERS,
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
                'sec-ch-ua': '"Chromium";v="141", "Google Chrome";v="141", "Not_A Brand";v="99"',
                'sec-ch-ua-mobile': '?0',
                'sec-ch-ua-platform': '"Windows"',
            },
            timeout=TIMEOUT, allow_redirects=True
        )
        body = r.text
        m = (re.search(r'"id":"([A-Z]{2})","countryName":', body)
             or re.search(r'netflix\.com/([a-z]{2})/', str(r.url), re.I))
        region = _norm(m.group(1)) if m else exit_region
        if r.status_code == 403:
            return {"status": "unavailable", "detail": "IP 被限制", "region": region}
        if r.status_code == 404 or re.search(r'Oh no!', body, re.I):
            return {"status": "partial", "detail": "仅自制内容", "region": region}
        if re.search(r'unsupportedbrowser', body, re.I):
            return {"status": "warning", "detail": "页面要求更新浏览器，无法确认", "region": region}
        if r.status_code == 200:
            return {"status": "available", "detail": "完整解锁", "region": region}
        return {"status": "error", "detail": f"检测失败 · HTTP {r.status_code}", "region": region}
    except Exception as e:
        return {"status": "error", "detail": str(e)}


def check_disney(exit_region=''):
    try:
        r = requests.post(
            'https://disney.api.edge.bamgrid.com/graph/v1/device/graphql',
            headers={
                'Accept-Language': 'en',
                'Authorization': 'ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84',
                'Content-Type': 'application/json',
                'User-Agent': UA,
            },
            json={
                "query": "mutation registerDevice($input: RegisterDeviceInput!) { registerDevice(registerDevice: $input) { grant { grantType assertion } } }",
                "variables": {"input": {
                    "applicationRuntime": "chrome",
                    "attributes": {
                        "browserName": "chrome", "browserVersion": "141",
                        "manufacturer": "microsoft", "model": None,
                        "operatingSystem": "windows", "operatingSystemVersion": "10",
                        "osDeviceIds": []
                    },
                    "deviceFamily": "browser",
                    "deviceLanguage": "en",
                    "deviceProfile": "windows",
                }}
            },
            timeout=TIMEOUT,
        )
        if r.status_code != 200:
            return {"status": "unavailable", "detail": f"当前 IP 不可用 · HTTP {r.status_code}", "region": exit_region}
        d = r.json()
        sdk     = (d.get('extensions') or {}).get('sdk') or {}
        session = sdk.get('session') or {}
        loc     = session.get('location') or {}
        region  = _norm(loc.get('countryCode')) or exit_region
        supported = (session.get('inSupportedLocation') is True
                     or str(session.get('inSupportedLocation')).lower() == 'true')
        return {
            "status": "available" if supported else "unavailable",
            "detail": "完整可用" if supported else "当前地区不可用",
            "region": region,
        }
    except Exception as e:
        return {"status": "error", "detail": str(e)}


def check_prime(exit_region=''):
    try:
        r = requests.get(
            'https://www.primevideo.com/',
            headers={**HEADERS}, timeout=TIMEOUT
        )
        body = r.text
        m = re.search(r'"currentTerritory":"([A-Z]{2})"', body)
        region = m.group(1) if m else exit_region
        if re.search(r'isServiceRestricted', body, re.I):
            return {"status": "unavailable", "detail": "服务受地区限制", "region": region}
        if r.status_code == 200 and m:
            return {"status": "available", "detail": "完整可用", "region": region}
        return {"status": "error", "detail": "无法确认服务地区", "region": region}
    except Exception as e:
        return {"status": "error", "detail": str(e)}


def check_tiktok(exit_region=''):
    headers = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
    }
    def _parse(r):
        body = r.text
        code = r.status_code
        final_url = str(r.url)
        src = body.replace('&quot;', '"')
        m = re.search(r'["\'](?:region|regionCode)["\']\s*:\s*["\']([A-Z]{2})["\']', src, re.I)
        region = _norm(m.group(1)) if m else ''
        if code == 451:
            return {"status": "unavailable", "detail": "当前地区不受支持", "region": region or exit_region}
        if re.search(r'unsupported[-_/]?(?:country|region)|not[-_/]?available[-_/]?(?:country|region)', final_url, re.I):
            return {"status": "unavailable", "detail": "当前地区不受支持", "region": region or exit_region}
        if re.search(r'(?:our services|this service|tiktok)\s+(?:are|is|isn\'t)?\s*(?:currently\s+)?not available\s+in\s+(?:your\s+)?(?:country|region)', body, re.I):
            return {"status": "unavailable", "detail": "当前地区不受支持", "region": region or exit_region}
        if code == 200 and region:
            return {"status": "available", "detail": "完整可用", "region": region}
        if code in (403, 429):
            return {"status": "warning", "detail": "请求被拒绝，可能触发风控", "region": region or exit_region}
        if code == 200 and re.search(r'TikTok|SIGI_STATE|__UNIVERSAL_DATA_FOR_REHYDRATION__', body, re.I):
            return {"status": "warning", "detail": "页面可访问，未能解析地区", "region": region or exit_region}
        if 200 <= code < 400:
            return {"status": "warning", "detail": "入口可访问，状态待确认", "region": region or exit_region}
        return {"status": "error", "detail": f"检测失败 · HTTP {code}", "region": region or exit_region}
    try:
        r1 = requests.get('https://www.tiktok.com/', headers=headers, timeout=TIMEOUT, allow_redirects=True)
        res = _parse(r1)
        if res['status'] in ('available', 'unavailable'):
            return res
        try:
            r2 = requests.get('https://www.tiktok.com/explore', headers=headers, timeout=TIMEOUT, allow_redirects=True)
            res2 = _parse(r2)
            return res2 if res2['status'] != 'error' else res
        except Exception:
            return res
    except Exception as e:
        return {"status": "error", "detail": str(e)}


def check_bbc(exit_region=''):
    try:
        r = requests.get(
            'https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/bbc_one_london/format/json/jsfunc/JS_callbacks0',
            headers={'User-Agent': UA}, timeout=TIMEOUT
        )
        body = r.text
        if re.search(r'geolocation', body, re.I):
            return {"status": "unavailable", "detail": "仅限英国地区", "region": exit_region}
        if re.search(r'vs-hls-push-uk', body, re.I):
            return {"status": "available", "detail": "英国内容可播放", "region": "GB"}
        return {"status": "error", "detail": "无法确认播放权限", "region": exit_region}
    except Exception as e:
        return {"status": "error", "detail": str(e)}


def check_abema(exit_region=''):
    try:
        r = requests.get(
            'https://api.abema.io/v1/ip/check?device=android',
            headers={'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 14)'}, timeout=TIMEOUT
        )
        d = r.json()
        region = _norm(d.get('isoCountryCode')) or exit_region
        if not d.get('isoCountryCode'):
            return {"status": "unavailable", "detail": "服务拒绝当前 IP", "region": region}
        if region == 'JP':
            return {"status": "available", "detail": "日本版完整可用", "region": region}
        return {"status": "partial", "detail": "仅海外版内容", "region": region}
    except Exception as e:
        return {"status": "error", "detail": str(e)}



def check_bilibili(exit_region=''):
    try:
        r = requests.get(
            'https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi',
            headers={'User-Agent': UA}, timeout=TIMEOUT
        )
        d = r.json()
        code = int(d.get('code', -1))
        if code == 0:
            return {"status": "available", "detail": "地区限定内容可播放", "region": exit_region}
        if code == -10403:
            return {"status": "unavailable", "detail": "地区限定内容不可用", "region": exit_region}
        return {"status": "error", "detail": f"检测失败 · code {code}", "region": exit_region}
    except Exception as e:
        return {"status": "error", "detail": str(e)}


def check_googleplay(exit_region=''):
    try:
        r = requests.get(
            'https://play.google.com/',
            headers={**HEADERS, 'Accept-Language': 'en-US;q=0.9'}, timeout=TIMEOUT
        )
        body = r.text
        m = re.search(r'<div class="yVZQTb">\s*([^<(]+)', body)
        place = m.group(1).strip() if m else ''
        if r.status_code == 200 and place:
            return {"status": "info", "detail": f"Google Play 识别为 {place}", "region": exit_region, "region_name": place}
        if r.status_code == 200:
            return {"status": "warning", "detail": "页面可访问，未能解析地区", "region": exit_region}
        return {"status": "error", "detail": f"检测失败 · HTTP {r.status_code}", "region": exit_region}
    except Exception as e:
        return {"status": "error", "detail": str(e)}


def check_chatgpt(exit_region=''):
    try:
        r_compliance = requests.get(
            'https://api.openai.com/compliance/cookie_requirements',
            headers={
                'Authorization': 'Bearer null',
                'Content-Type': 'application/json',
                'Origin': 'https://platform.openai.com',
                'User-Agent': UA,
            }, timeout=TIMEOUT
        )
        r_trace = requests.get(
            'https://chatgpt.com/cdn-cgi/trace',
            headers={'User-Agent': UA}, timeout=TIMEOUT
        )
        region = _cf_loc('chatgpt.com') or exit_region
        # re-parse from already fetched trace
        for line in r_trace.text.splitlines():
            if line.startswith('loc='):
                region = _norm(line[4:]) or region
                break
        if re.search(r'unsupported_country', r_compliance.text, re.I):
            return {"status": "unavailable", "detail": "当前地区不受支持", "region": region}
        if r_compliance.status_code == 200 and r_trace.status_code == 200:
            return {"status": "available", "detail": "Web / API 入口可用", "region": region}
        return {"status": "error", "detail": "无法确认服务状态", "region": region}
    except Exception as e:
        return {"status": "error", "detail": str(e)}


_CLAUDE_SUPPORTED = (
    ',AL,DZ,AD,AO,AG,AR,AM,AU,AT,AZ,BS,BH,BD,BB,BE,BZ,BJ,BT,BO,BA,BW,BR,BN,BG,BF,BI,'
    'CV,KH,CM,CA,CF,TD,CL,CO,KM,CG,CR,CI,HR,CY,CZ,DK,DJ,DM,DO,EC,EG,SV,GQ,ER,EE,SZ,'
    'ET,FJ,FI,FR,GA,GM,GE,DE,GH,GR,GD,GT,GN,GW,GY,HT,HN,HU,IS,IN,ID,IQ,IE,IL,IT,JM,'
    'JP,JO,KZ,KE,KI,KW,KG,LA,LV,LB,LS,LR,LY,LI,LT,LU,MG,MW,MY,MV,ML,MT,MH,MR,MU,MX,'
    'FM,MD,MC,MN,ME,MA,MZ,NA,NR,NP,NL,NZ,NI,NE,NG,MK,NO,OM,PK,PW,PS,PA,PG,PY,PE,PH,'
    'PL,PT,QA,RO,RW,KN,LC,VC,WS,SM,ST,SA,SN,RS,SC,SL,SG,SK,SI,SO,SB,ZA,KR,SS,ES,LK,'
    'SD,SR,SE,CH,TW,TJ,TZ,TH,TL,TG,TO,TT,TN,TR,TM,TV,UG,UA,AE,GB,US,UY,UZ,VU,VA,VN,'
    'ZM,ZW,'
)


def check_claude(exit_region=''):
    try:
        r_land  = requests.get('https://claude.ai/', headers={'User-Agent': UA}, timeout=TIMEOUT, allow_redirects=True)
        r_trace = requests.get('https://claude.ai/cdn-cgi/trace', headers={'User-Agent': UA}, timeout=TIMEOUT)
        region = ''
        for line in r_trace.text.splitlines():
            if line.startswith('loc='):
                region = _norm(line[4:])
                break
        region = region or exit_region
        officially = region and (f',{region},' in _CLAUDE_SUPPORTED)
        if re.search(r'app-unavailable-in-region', str(r_land.url), re.I) or (region and not officially):
            return {"status": "unavailable", "detail": "官方暂未支持该地区", "region": region}
        if r_trace.status_code == 200 and officially:
            return {"status": "available", "detail": "官方支持 · 入口可访问", "region": region}
        return {"status": "warning", "detail": "入口可访问，地区状态待确认", "region": region}
    except Exception as e:
        return {"status": "error", "detail": str(e)}


def check_gemini(exit_region=''):
    try:
        r = requests.get(
            'https://gemini.google.com/',
            headers={**HEADERS}, timeout=TIMEOUT, allow_redirects=True
        )
        body = r.text
        m = re.search(r',2,1,200,"([A-Z]{3})"', body)
        detail_region = f' · {m.group(1)}' if m else ''
        if '45631641,null,true' in body:
            return {"status": "available", "detail": f"Web 版可用{detail_region}", "region": exit_region}
        if '45631641,null,false' in body or re.search(
                r'Gemini[^\n<]{0,80}(?:is )?not available|not available in (?:your |this )?(?:country|region)', body, re.I):
            return {"status": "unavailable", "detail": "当前地区不受支持", "region": exit_region}
        # fallback: CN is known unsupported
        if exit_region == 'CN':
            return {"status": "unavailable", "detail": "当前地区不受支持", "region": exit_region}
        if r.status_code == 200 and re.search(r'Gemini', body, re.I):
            return {"status": "warning", "detail": f"页面可访问，功能状态待确认{detail_region}", "region": exit_region}
        return {"status": "unavailable", "detail": "当前地区不可用", "region": exit_region}
    except Exception as e:
        return {"status": "error", "detail": str(e)}


# ─── 调度 & 缓存 ─────────────────────────────────────────────

_cache = {}
_lock  = threading.Lock()


def run_all_checks():
    log.info("开始流媒体解锁检测...")

    exit_info = check_exit_ip()
    er = exit_info.get('region', '')

    tasks = {
        'youtube_premium': lambda: check_youtube(),
        'netflix':         lambda: check_netflix(er),
        'disney_plus':     lambda: check_disney(er),
        'prime_video':     lambda: check_prime(er),
        'tiktok':          lambda: check_tiktok(er),
        'bbc_iplayer':     lambda: check_bbc(er),
        'abema':           lambda: check_abema(er),
        'bilibili_intl':   lambda: check_bilibili(er),
        'google_play':     lambda: check_googleplay(er),
        'chatgpt':         lambda: check_chatgpt(er),
        'claude':          lambda: check_claude(er),
        'gemini':          lambda: check_gemini(er),
    }

    results = {'exit': exit_info}
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(fn): key for key, fn in tasks.items()}
        for fut in concurrent.futures.as_completed(futures):
            key = futures[fut]
            try:
                results[key] = fut.result()
            except Exception as e:
                results[key] = {"status": "error", "detail": str(e)}

    results['updated_at'] = int(time.time())

    with _lock:
        _cache.clear()
        _cache.update(results)
    try:
        with open(RESULT_PATH, 'w') as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
    except Exception:
        pass
    log.info("检测完成")
    return results


def _load_cache():
    if os.path.exists(RESULT_PATH):
        try:
            with open(RESULT_PATH) as f:
                _cache.update(json.load(f))
        except Exception:
            pass


def _loop():
    while True:
        try:
            run_all_checks()
        except Exception as e:
            log.error(f"检测异常: {e}")
        time.sleep(CHECK_INTERVAL)


# ─── Flask 路由 ──────────────────────────────────────────────

@app.route(f'/status/{SHOW_TOKEN}')
def get_status():
    with _lock:
        if not _cache:
            return jsonify({"error": "尚未完成首次检测，请稍候..."}), 503
        return jsonify(dict(_cache))


@app.route(f'/ui/{SHOW_TOKEN}')
def ui():
    with _lock:
        data = dict(_cache)

    # txt_color, badge_bg, card_bg, label, icon
    STATUS_META = {
        "available":   ("#15803d", "#dcfce7", "#f0fdf4", "可用",  "✓"),
        "partial":     ("#92400e", "#fef3c7", "#fffbeb", "部分",  "~"),
        "unavailable": ("#b91c1c", "#fee2e2", "#fff1f2", "受限",  "✕"),
        "warning":     ("#92400e", "#fef3c7", "#fffbeb", "警告",  "!"),
        "error":       ("#374151", "#f3f4f6", "#f9fafb", "失败",  "!"),
        "info":        ("#1d4ed8", "#dbeafe", "#eff6ff", "信息",  "i"),
    }
    SERVICES = {
        "youtube_premium": ("YouTube Premium", "#FF0000",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#FF0000"/><path d="M28 20L16 27V13z" fill="#fff"/></svg>'),
        "netflix": ("Netflix", "#E50914",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#141414"/><svg x="3" y="13" width="34" height="14" viewBox="0 0 512 138" preserveAspectRatio="xMidYMid meet"><path fill="#db202c" d="M340.657 0v100.203q18.54.861 36.98 2.09v21.245a1822 1822 0 0 0-58.542-2.959V0zM512 .012l-28.077 65.094l28.07 72.438l-.031.013a1789 1789 0 0 0-24.576-3.323l-15.763-40.656l-15.913 36.882a1816 1816 0 0 0-22.662-2.36l27.371-63.43L435.352.013h23.325l14.035 36.184L488.318.012zM245.093 119.526V.011h60.19v21.436h-38.628v27.78h29.227v21.245h-29.227v49.05zM164.58 21.448V.01h66.69v21.437h-22.565v98.66c-7.197.19-14.386.412-21.56.683V21.448zM90.868 126.966V.014h59.89v21.435h-38.331v29.036c8.806-.113 21.327-.24 29.117-.222V71.51c-9.751-.12-20.758.134-29.117.217v32.164a1848 1848 0 0 1 38.331-2.62v21.247a1816 1816 0 0 0-59.89 4.45M48.571 77.854L48.57.01h21.562v128.96q-11.823 1.216-23.603 2.584L21.56 59.824v74.802q-10.8 1.406-21.56 2.936V.012h20.491zm346.854 46.965V.012h21.563V126.6c-7.179-.64-14.364-1.23-21.563-1.78"/></svg></svg>'),
        "disney_plus": ("Disney+", "#0063E5",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#040714"/><svg x="1" y="5" width="38" height="30" viewBox="0 0 1041 565" preserveAspectRatio="xMidYMid meet"><path d="M735.8 365.7 C721.4 369 683.5 370.9 683.5 370.9 L678.7 385.9 C678.7 385.9 697.6 384.3 711.4 385.7 711.4 385.7 715.9 385.2 716.4 390.8 716.6 396 716 401.6 716 401.6 716 401.6 715.7 405 710.9 405.8 705.7 406.7 670.1 408 670.1 408 L664.3 427.5 C664.3 427.5 662.2 432 667 430.7 671.5 429.5 708.8 422.5 713.7 423.5 718.9 424.8 724.7 431.7 723 438.1 721 445.9 683.8 469.7 661.1 468 661.1 468 649.2 468.8 639.1 452.7 629.7 437.4 642.7 408.3 642.7 408.3 642.7 408.3 636.8 394.7 641.1 390.2 641.1 390.2 643.7 387.9 651.1 387.3 L660.2 368.4 C660.2 368.4 649.8 369.1 643.6 361.5 637.8 354.2 637.4 350.9 641.8 348.9 646.5 346.6 689.8 338.7 719.6 339.7 719.6 339.7 730 338.7 738.9 356.7 738.8 356.7 743.2 364 735.8 365.7 Z M623.7 438.3 C619.9 447.3 609.8 456.9 597.3 450.9 584.9 444.9 565.2 404.6 565.2 404.6 565.2 404.6 557.7 389.6 556.3 389.9 556.3 389.9 554.7 387 553.7 403.4 552.7 419.8 553.9 451.7 547.4 456.7 541.2 461.7 533.7 459.7 529.8 453.8 526.3 448 524.8 434.2 526.7 410 529 385.8 534.6 360 541.8 351.9 549 343.9 554.8 349.7 557 351.8 557 351.8 566.6 360.5 582.5 386.1 L585.3 390.8 C585.3 390.8 599.7 415 601.2 414.9 601.2 414.9 602.4 416 603.4 415.2 604.9 414.8 604.3 407 604.3 407 604.3 407 601.3 380.7 588.2 336.1 588.2 336.1 586.2 330.5 587.6 325.3 588.9 320 594.2 322.5 594.2 322.5 594.2 322.5 614.6 332.7 624.4 365.9 634.1 399.4 627.5 429.3 623.7 438.3 Z M523.5 353 C521.8 356.4 520.8 361.3 512.2 362.6 512.2 362.6 429.9 368.2 426 374 426 374 423.1 377.4 427.6 378.4 432.1 379.3 450.7 381.8 459.7 382.3 469.3 382.4 501.7 382.7 513.3 397.2 513.3 397.2 520.2 404.1 519.9 419.7 519.6 435.7 516.8 441.3 510.6 447.1 504.1 452.5 448.3 477.5 412.3 439.1 412.3 439.1 395.7 420.6 418 406.6 418 406.6 434.1 396.9 475 408.3 475 408.3 487.4 412.8 486.8 417.3 486.1 422.1 476.6 427.2 462.8 426.9 449.4 426.5 439.6 420.1 441.5 421.1 443.3 421.8 427.1 413.3 422.1 419.1 417.1 424.4 418.3 427.7 423.2 431 435.7 438.1 484 435.6 498.4 419.6 498.4 419.6 504.1 413.1 495.4 407.8 486.7 402.8 461.8 399.8 452.1 399.3 442.8 398.8 408.2 399.4 403.2 390.2 403.2 390.2 398.2 384 403.7 366.4 409.5 348 449.8 340.9 467.2 339.3 467.2 339.3 515.1 337.6 523.9 347.4 523.8 347.4 525 349.7 523.5 353 Z M387.5 460.9 C381.7 465.2 369.4 463.3 365.9 458.5 362.4 454.2 361.2 437.1 361.9 410.3 362.6 383.2 363.2 349.6 369 344.3 375.2 338.9 379 343.6 381.4 347.3 384 350.9 387.1 354.9 387.8 363.4 388.4 371.9 390.4 416.5 390.4 416.5 390.4 416.5 393 456.7 387.5 460.9 Z M400 317.1 C383.1 322.7 371.5 320.8 361.7 316.6 357.4 324.1 354.9 326.4 351.6 326.9 346.8 327.4 342.5 319.7 341.7 317.2 340.9 315.3 338.6 312.1 341.4 304.5 331.8 295.9 331.1 284.3 332.7 276.5 335.1 267.5 351.3 233.3 400.6 229.3 400.6 229.3 424.7 227.5 428.8 240.4 L429.5 240.4 C429.5 240.4 452.9 240.5 452.4 261.3 452.1 282.2 426.4 308.2 400 317.1 Z M354 270.8 C349 278.8 348.8 283.6 351.1 286.9 356.8 278.2 367.2 264.5 382.5 254.1 370.7 255.1 360.8 260.2 354 270.8 Z M422.1 257.4 C406.6 259.7 382.6 280.5 371.2 297.5 388.7 300.7 419.6 299.5 433.3 271.6 433.2 271.6 439.8 254.3 422.1 257.4 Z M842.9 418.5 C833.6 434.7 807.5 468.5 772.7 460.6 761.2 488.5 751.6 516.6 746.1 558.8 746.1 558.8 744.9 567 738.1 564.1 731.4 561.7 720.2 550.5 718 535 715.6 514.6 724.7 480.1 743.2 440.6 737.8 431.8 734.1 419.2 737.3 401.3 737.3 401.3 742 368.1 775.3 338.1 775.3 338.1 779.3 334.6 781.6 335.7 784.2 336.8 783 347.6 780.9 352.8 778.8 358 763.9 383.8 763.9 383.8 763.9 383.8 754.6 401.2 757.2 414.9 774.7 388 814.5 333.7 839.2 350.8 847.5 356.7 851.3 369.6 851.3 383.5 851.2 395.8 848.3 408.8 842.9 418.5 Z M835.7 375.9 C835.7 375.9 834.3 365.2 823.9 377 814.9 386.9 798.7 405.6 785.6 430.9 799.3 429.4 812.5 421.9 816.5 418.1 823 412.3 838.1 396.7 835.7 375.9 Z M350.2 389.5 C348.3 413.7 339 454.4 273.1 474.5 229.6 487.6 188.5 481.3 166.1 475.6 165.6 484.5 164.6 488.3 163.2 489.8 161.3 491.7 147.1 499.9 139.3 488.3 135.8 482.8 134 472.8 133 463.9 82.6 440.7 59.4 407.3 58.5 405.8 57.4 404.7 45.9 392.7 57.4 378 68.2 364.7 103.5 351.4 135.3 346 136.4 318.8 139.6 298.3 143.4 288.9 148 278 153.8 287.8 158.8 295.2 163 300.7 165.5 324.4 165.7 343.3 186.5 342.3 198.8 343.8 222 348 252.2 353.5 272.4 368.9 270.6 386.4 269.3 403.6 253.5 410.7 247.5 411.2 241.2 411.7 231.4 407.2 231.4 407.2 224.7 404 230.9 401.2 239 397.7 247.8 393.4 245.8 389 245.8 389 242.5 379.4 203.3 372.7 164.3 372.7 164.1 394.2 165.2 429.9 165.7 450.7 193 455.9 213.4 454.9 213.4 454.9 213.4 454.9 313 452.1 316 388.5 319.1 324.8 216.7 263.7 141 244.3 65.4 224.5 22.6 238.3 18.9 240.2 14.9 242.2 18.6 242.8 18.6 242.8 18.6 242.8 22.7 243.4 29.8 245.8 37.3 248.2 31.5 252.1 31.5 252.1 18.6 256.2 4.1 253.6 1.3 247.7 -1.5 241.8 3.2 236.5 8.6 228.9 14 220.9 19.9 221.2 19.9 221.2 113.4 188.8 227.3 247.4 227.3 247.4 334 301.5 352.2 364.9 350.2 389.5 Z M68 386.2 C57.4 391.4 64.7 398.9 64.7 398.9 84.6 420.3 109.1 433.7 132.4 442 135.1 405.1 134.7 392.1 135 373.5 98.6 376 77.6 381.8 68 386.2 Z" fill="#01147c"/><path d="M1040.9 378.6 L1040.9 391.8 C1040.9 394.7 1038.6 397 1035.7 397 L972.8 397 C972.8 400.3 972.9 403.2 972.9 405.9 972.9 425.4 972.1 441.3 970.2 459.2 969.9 461.9 967.7 463.9 965.1 463.9 L951.5 463.9 C950.1 463.9 948.8 463.3 947.9 462.3 947 461.3 946.5 459.9 946.7 458.5 948.6 440.7 949.5 425 949.5 405.9 949.5 403.1 949.5 400.2 949.4 397 L887.2 397 C884.3 397 882 394.7 882 391.8 L882 378.6 C882 375.7 884.3 373.4 887.2 373.4 L948.5 373.4 C947.2 351.9 944.6 331.2 940.4 310.2 940.2 308.9 940.5 307.6 941.3 306.6 942.1 305.6 943.3 305 944.6 305 L959.3 305 C961.6 305 963.5 306.6 964 308.9 968.1 330.6 970.7 351.7 972 373.4 L1035.7 373.4 C1038.5 373.4 1040.9 375.8 1040.9 378.6 Z" fill="#01147c"/><defs><radialGradient id="rdg" gradientUnits="userSpaceOnUse" cx="942.524" cy="279.896" r="760.124"><stop offset="0.007" stop-color="#021192"/><stop offset="0.191" stop-color="#0000fe"/><stop offset="1" stop-color="#00ffff" stop-opacity="0"/></radialGradient></defs><path d="M955.3 273.9 C922.8 194 867.9 125.9 796.5 76.9 723.4 26.8 637.7 0.3 548.7 0.3 401.5 0.3 264.9 73.4 183.4 195.9 182.5 197.2 182.3 198.9 182.8 200.4 183.3 202 184.5 203.1 186 203.6 L197.4 207.5 C198.1 207.7 198.8 207.8 199.4 207.8 201.5 207.8 203.5 206.7 204.7 205 242.1 150 292.7 104.3 351.1 72.7 411.4 40.1 479.7 22.8 548.6 22.8 631.9 22.8 712.2 47.4 781 93.8 848.1 139.1 900.2 202.4 931.7 276.7 932.6 278.9 934.8 280.4 937.2 280.4 L950.8 280.4 C952.4 280.4 953.9 279.6 954.7 278.3 955.7 277 955.9 275.4 955.3 273.9 Z" fill="url(#rdg)"/></svg></svg>'),
        "prime_video": ("Prime Video", "#00A8E1",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#0F1111"/><svg x="2" y="9" width="36" height="22" viewBox="0 0 4605.7 2723.6" preserveAspectRatio="xMidYMid meet"><path fill="#0779ff" d="M2246 2723.1a2591.3 2591.3 0 0 1-591.4-83.5 2159.7 2159.7 0 0 1-516.8-208.3A1728.5 1728.5 0 0 1 679.1 2060c-55.6-63.6-86-106.3-101-141.4a93 93 0 0 1-9-35.5c-1.2-22.7 6-36.6 23.6-45.2 6.3-3.2 7-3.3 18.6-3.3a51 51 0 0 1 19 2.3c20.3 6.6 46.1 22.7 79.5 49.4a2069.6 2069.6 0 0 0 372.5 240.3c147.7 74.5 292.3 128.2 473.7 176a3157 3157 0 0 0 627.8 98.4c72.8 4.1 93.8 4.6 189.5 4.6 105.9 0 154.2-1.5 242-7.5 361.5-24.8 718.7-108.9 984.8-231.8a2156 2156 0 0 0 63-31c45.1-22.7 57-28.2 75.7-35 26.3-9.4 44.4-6.3 59.7 10.2a50.4 50.4 0 0 1 14.8 38.5c-5.1 41.5-59 100.4-163.7 179.3-249.6 188-594.4 319.3-974.8 371.2a2718 2718 0 0 1-263.5 22.6 3806 3806 0 0 1-165.4 1zm1615-239.4a51.1 51.1 0 0 1-26.8-24c-7.7-16.8-5.3-31.5 10.4-64.1a572 572 0 0 1 31.9-56.5c41.2-68.3 82.6-159.4 102.1-224.6 19.6-65.4 22-102.6 8-123.8-12-18.2-50.5-29.6-113.2-33.7-24.5-1.6-103.2-.6-126.7 1.5-52.5 4.9-89 10.2-138 20.1-35 7.1-41.8 8-66.5 8-23.9 0-28.8-.7-38.5-5.5a41 41 0 0 1-21-41.6c2.5-13.7 11.4-26.6 27.8-40.3 41.9-35 107.4-69 178.7-92.6a654.9 654.9 0 0 1 232.5-33.3 596 596 0 0 1 133 19.4c71.2 18.4 114.3 42 129.3 71 11.5 22.3 15.8 44.9 15.7 83.6a617 617 0 0 1-33.6 195.2 608 608 0 0 1-156.5 249.2c-53 52.3-89.7 80-119.5 90a57.3 57.3 0 0 1-29 2zm-3838.6-729a39.2 39.2 0 0 1-19.9-17.9l-2.3-4.2-.2-656.5c-.2-594.8-.1-657 1.3-661.9 2-6.9 10.3-16 18.3-19.8l5.6-2.8h181l4.7 2.2a34.4 34.4 0 0 1 16.7 17.1c3.6 7.7 4.7 12.9 19.3 84.5l10.3 50.7h10l4.5-9.7a318.5 318.5 0 0 1 38.7-63.3 322 322 0 0 1 65.6-59.3 278.7 278.7 0 0 1 218.2-40.6c76.2 16.7 145 67.4 195 143.7 48.3 73.8 82.2 179.6 93 290.7 3.2 33 3.7 42.2 4.2 89.7a905 905 0 0 1-6.7 140.3c-16 127.7-59.3 238.2-122 311a470 470 0 0 1-46 44.7 285.6 285.6 0 0 1-137 60c-19.6 3-66.8 3.3-85.5.5-72.7-10.9-127.5-44.7-175.8-108.5a491.5 491.5 0 0 1-36-56.4c-2.7-4.7-2.8-4.8-7.7-4.8h-5l-.2 224.3-.3 224.2-3 5.3a40.6 40.6 0 0 1-18.1 16.6c-4.2 1.4-16 1.6-110.8 1.6-86.6 0-106.8-.3-109.9-1.4M466 1231c38-7.3 68.2-28.8 92-65.5 30-46 47.6-113 52.9-201.8 1.6-26.5.7-105.1-1.5-127.7-4.6-48-12.1-87-23-118.7-25.2-73.5-64.5-114.7-120.4-126a222 222 0 0 0-57.3 0c-45.8 9.2-80.6 38.3-106.3 88.7a346 346 0 0 0-31 94c-12.9 65.2-15.2 163.8-5.5 239.4 8.2 64.1 25.4 116.1 50.7 153.6 27 39.7 60.5 60.9 104.7 66 10.8 1.3 32.9.3 44.7-2m3677.3 224.4-15.5-1.5a408 408 0 0 1-207.3-78.7 477 477 0 0 1-78.6-75.9c-64-80.8-103.7-183.6-115.5-299.8-3.1-30.9-3.8-50-3.3-92.7a661 661 0 0 1 10.3-120.8c37.3-212.7 172.2-371.6 348-409.8 32.2-7 57.7-9.6 94.4-9.6a382 382 0 0 1 144.5 26.1 505 505 0 0 1 51.3 24.9 426.6 426.6 0 0 1 135 127.6 588 588 0 0 1 85.6 210.8c10.3 51.4 14 96.8 13.5 167-.3 42.6-.4 43.6-2.6 47.6a31.6 31.6 0 0 1-22.1 17c-4.6 1.1-57.6 1.4-293.5 1.4h-287.8l.6 6.8c8 86.2 23.8 142.4 51.7 184.1 23.3 35 51.9 55 90 63.2 12.2 2.6 41.2 3.6 55.8 2 39.6-4.6 68.5-18 92.6-43.3 19.4-20.3 32.7-45.7 42.3-80.8 4.9-18 6-20.7 10.8-26 5.2-5.8 11-8.3 19.3-8.3 9 0 197.8 42.2 205.6 45.9a24 24 0 0 1 14 25.3c-2 15.6-24.8 68.7-42.6 99.7a387 387 0 0 1-161.5 154.2 437.6 437.6 0 0 1-148.5 41.8c-13.6 1.5-76 2.8-86.5 1.8m192.1-648.6c-1.3-14-5.7-42.5-9.1-59.7-16.1-79.3-48.4-134.1-92.4-157a133.2 133.2 0 0 0-117.6-.3 133 133 0 0 0-37.5 28.2 173.4 173.4 0 0 0-32.7 43.2c-19 34.3-33.3 80.5-41.2 133.8-1.1 7.4-2 14.7-2 16.3v2.7H4336l-.7-7.2zm-3283 621.4a39 39 0 0 1-18-18.8c-1.4-4.3-1.6-47.8-1.6-499.4 0-447.5.2-495 1.6-499.3a29.4 29.4 0 0 1 15.6-16.3l6.3-2.9 87.5-.3c91-.3 95.3-.2 103.1 3.8 5.5 2.8 12.4 11 14.8 17.7 1.2 3.2 7.8 33.5 14.6 67.3l13 63.8c.6 2 1 2.3 5.6 2l5-.3 5.3-12a330.4 330.4 0 0 1 42.2-71.5c9.5-11.9 30-32 42-41.1 46.7-35.6 96.4-52 158.3-51.9 42 0 79 7.2 113 21.8 11.2 4.8 17.3 9.7 21 16.5 2.4 4.8 2.6 6.1 2.6 16.2 0 11-.1 11.3-24.8 111-13.6 55-25.5 102-26.3 104.2-2 5.2-7.2 10.8-12.2 13a31 31 0 0 1-11.2 1.6c-8.5 0-9.2-.2-43.7-14.2-36.1-14.7-63.3-23.2-84.3-26.2a267.2 267.2 0 0 0-55 .4 142 142 0 0 0-51.7 18.9c-12 7.4-30.7 26-39.5 39.3-24.3 36.9-35.3 79.5-37.8 145.5-.5 13.5-.9 151.7-1 307 0 312.7.6 286.5-6.4 296.1a23.8 23.8 0 0 1-9.2 7.5l-5.9 2.9-108.5.3-108.5.2zm745 1.4c-9.8-3-16.1-9-19.3-18-1.7-4.9-1.8-27.7-1.8-501.1v-496l2.6-5.5c3.3-7 8-11.5 15-14.9l5.4-2.6 105.5-.3c109.3-.3 114.3-.1 122 3.8a30 30 0 0 1 11.8 12.8c1.7 3.5 1.8 30 2 500.7.2 453.3.1 497.4-1.3 502.5a23 23 0 0 1-7.3 11.1c-9.5 9.5-.6 9-123.6 8.8-83.4 0-108-.3-111-1.3m449.3 0c-8.3-3-15.6-9.5-20-17.8l-2.4-4.3v-994l2.4-5.3a28.2 28.2 0 0 1 15.1-14.1l5.5-2.6h91c84.7 0 91.4.1 95.6 1.8a32 32 0 0 1 19 19.5c1.7 4.6 10.5 46.2 27 128l1 5.2h10.5l3.5-8.8a414 414 0 0 1 25.1-49.7c40.4-64.6 98.8-104.9 169.8-117 47.2-8.1 99.7-4.2 142.8 10.6 56.5 19.4 103.7 58 138.5 113.4a432 432 0 0 1 23.4 44.8l2.9 6.7h10l8-12.2c35.9-55 80.4-100.5 124.5-127.2a295 295 0 0 1 194.4-37 258.8 258.8 0 0 1 171.2 103c12 16 21.3 31.3 31.4 51.9 25.9 52.6 42 112.8 48.5 181.7 3.4 35.7 3.7 63.6 3.3 384.3l-.3 317-2.6 5.5a27.7 27.7 0 0 1-14.1 15.1l-5.3 2.4h-219l-4.3-2.3a41.3 41.3 0 0 1-15.7-15.4l-3-5.3-.5-320c-.6-340.2-.4-324.1-5-351-9.7-57.3-35.1-97.2-73.5-115.6-19-9.1-37.6-12.5-63.8-11.6-37 1.3-64.6 12.7-88.1 36.2-28.2 28.1-44.5 69.5-52.3 132.5-1.5 12.3-1.7 42-2.2 321.5l-.6 308-2.6 5.5a27.7 27.7 0 0 1-14.1 15.1l-5.3 2.4h-219l-5.2-3a40.5 40.5 0 0 1-15.4-15.6l-2.4-4.4-.5-320c-.6-340.2-.4-324.1-5-351-9.7-57.3-35.1-97.2-73.5-115.6-19-9.1-37.6-12.5-63.8-11.6-37 1.3-64.6 12.7-88.1 36.2-28.2 28.1-44.5 69.5-52.3 132.5-1.5 12.3-1.7 42-2.2 321.5l-.6 308-2.6 5.5a27.7 27.7 0 0 1-14.1 15.1l-5.3 2.4-108 .2c-86.6.2-108.7 0-111.6-1zM1887.8 309a154 154 0 0 1-94-46.7 139.7 139.7 0 0 1-37-72c-3-15-3.8-44-1.6-60.8 6-45 26.5-79 62.3-103C1869-8 1944.5-9 1995.4 24.2a154 154 0 0 1 48.3 49.5c21.5 36.4 26 93 11.1 137.5a147.5 147.5 0 0 1-85.6 88c-23.8 9.2-54 12.9-81.4 9.8"/></svg></svg>'),
        "tiktok": ("TikTok", "#010101",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#010101"/><svg x="1" y="1" width="38" height="38" viewBox="0 0 352.28 398.67" xmlns="http://www.w3.org/2000/svg"><path d="M137.17 156.98v-15.56c-5.34-.73-10.76-1.18-16.29-1.18C54.23 140.24 0 194.47 0 261.13c0 40.9 20.43 77.09 51.61 98.97-20.12-21.6-32.46-50.53-32.46-82.31 0-65.7 52.69-119.28 118.03-120.81Z" fill="#25f4ee"/><path d="M140.02 333c29.74 0 54-23.66 55.1-53.13l.11-263.2h48.08c-1-5.41-1.55-10.97-1.55-16.67h-65.67l-.11 263.2c-1.1 29.47-25.36 53.13-55.1 53.13-9.24 0-17.95-2.31-25.61-6.34C105.3 323.9 121.6 333 140.02 333ZM333.13 106V91.37c-18.34 0-35.43-5.45-49.76-14.8 12.76 14.65 30.09 25.22 49.76 29.43Z" fill="#25f4ee"/><path d="M283.38 76.57c-13.98-16.05-22.47-37-22.47-59.91h-17.59c4.63 25.02 19.48 46.49 40.06 59.91ZM120.88 205.92c-30.44 0-55.21 24.77-55.21 55.21 0 21.2 12.03 39.62 29.6 48.86-6.55-9.08-10.45-20.18-10.45-32.2 0-30.44 24.77-55.21 55.21-55.21 5.68 0 11.13.94 16.29 2.55v-67.05c-5.34-.73-10.76-1.18-16.29-1.18-.96 0-1.9.05-2.85.07v51.49c-5.16-1.61-10.61-2.55-16.29-2.55Z" fill="#fe2c55"/><path d="M333.13 106v51.04c-34.05 0-65.61-10.89-91.37-29.38v133.47c0 66.66-54.23 120.88-120.88 120.88-25.76 0-49.64-8.12-69.28-21.91 22.08 23.71 53.54 38.57 88.42 38.57 66.66 0 120.88-54.23 120.88-120.88V144.33c25.76 18.49 57.32 29.38 91.37 29.38v-65.68c-6.57 0-12.97-.71-19.14-2.03Z" fill="#fe2c55"/><path d="M241.76 261.13V127.66c25.76 18.49 57.32 29.38 91.37 29.38V106c-19.67-4.21-37-14.77-49.76-29.43-20.58-13.42-35.43-34.88-40.06-59.91h-48.08l-.11 263.2c-1.1 29.47-25.36 53.13-55.1 53.13-18.42 0-34.72-9.1-44.75-23.01-17.57-9.25-29.6-27.67-29.6-48.86 0-30.44 24.77-55.21 55.21-55.21 5.68 0 11.13.94 16.29 2.55v-51.49C71.83 158.5 19.14 212.08 19.14 277.78c0 31.78 12.34 60.71 32.46 82.31C71.23 373.87 95.12 382 120.88 382c66.65 0 120.88-54.23 120.88-120.88Z" fill="#fff"/></svg></svg>'),
        "bbc_iplayer": ("BBC iPlayer", "#C0002A",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#C0002A"/><rect x="3" y="13" width="10" height="14" rx="2" fill="#fff"/><rect x="15" y="13" width="10" height="14" rx="2" fill="#fff"/><rect x="27" y="13" width="10" height="14" rx="2" fill="#fff"/><text x="8" y="24" font-family="Arial,sans-serif" font-size="9" font-weight="900" fill="#C0002A" text-anchor="middle">B</text><text x="20" y="24" font-family="Arial,sans-serif" font-size="9" font-weight="900" fill="#C0002A" text-anchor="middle">B</text><text x="32" y="24" font-family="Arial,sans-serif" font-size="9" font-weight="900" fill="#C0002A" text-anchor="middle">C</text></svg>'),
        "abema": ("ABEMA", "#7C3AED",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#7C3AED"/><path d="M13 8l-4 8h4zm14 0l4 8h-4z" fill="#fff"/><rect x="6" y="16" width="28" height="18" rx="3" fill="#fff"/><circle cx="15" cy="26" r="3" fill="#7C3AED"/><circle cx="25" cy="26" r="3" fill="#7C3AED"/></svg>'),
        "bilibili_intl": ("哔哩哔哩港澳台", "#FB7299",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#FB7299"/><path d="M13 9l4 5M27 9l-4 5" stroke="#fff" stroke-width="2" stroke-linecap="round"/><rect x="5" y="14" width="30" height="20" rx="6" fill="#fff"/><circle cx="15" cy="25" r="3" fill="#FB7299"/><circle cx="25" cy="25" r="3" fill="#FB7299"/><path d="M15 30c2 2 8 2 10 0" fill="none" stroke="#FB7299" stroke-width="1.5" stroke-linecap="round"/></svg>'),
        "google_play": ("Google Play 地区", "#4285F4",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#fff"/><path d="M9 9l13 11L9 31z" fill="#34A853"/><path d="M9 9l13 11 8-4.5z" fill="#FBBC04"/><path d="M9 31l13-11 8 4.5z" fill="#EA4335"/><path d="M30 15.5L22 20l8 4.5z" fill="#4285F4"/></svg>'),
        "chatgpt": ("ChatGPT", "#000000",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#000"/><svg x="4" y="4" width="32" height="32" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M9.205 8.658v-2.26c0-.19.072-.333.238-.428l4.543-2.616c.619-.357 1.356-.523 2.117-.523 2.854 0 4.662 2.212 4.662 4.566 0 .167 0 .357-.024.547l-4.71-2.759a.797.797 0 00-.856 0l-5.97 3.473zm10.609 8.8V12.06c0-.333-.143-.57-.429-.737l-5.97-3.473 1.95-1.118a.433.433 0 01.476 0l4.543 2.617c1.309.76 2.189 2.378 2.189 3.948 0 1.808-1.07 3.473-2.76 4.163zM7.802 12.703l-1.95-1.142c-.167-.095-.239-.238-.239-.428V5.899c0-2.545 1.95-4.472 4.591-4.472 1 0 1.927.333 2.712.928L8.23 5.067c-.285.166-.428.404-.428.737v6.898zM12 15.128l-2.795-1.57v-3.33L12 8.658l2.795 1.57v3.33L12 15.128zm1.796 7.23c-1 0-1.927-.332-2.712-.927l4.686-2.712c.285-.166.428-.404.428-.737v-6.898l1.974 1.142c.167.095.238.238.238.428v5.233c0 2.545-1.974 4.472-4.614 4.472zm-5.637-5.303l-4.544-2.617c-1.308-.761-2.188-2.378-2.188-3.948A4.482 4.482 0 014.21 6.327v5.423c0 .333.143.571.428.738l5.947 3.449-1.95 1.118a.432.432 0 01-.476 0zm-.262 3.9c-2.688 0-4.662-2.021-4.662-4.519 0-.19.024-.38.047-.57l4.686 2.71c.286.167.571.167.856 0l5.97-3.448v2.26c0 .19-.07.333-.237.428l-4.543 2.616c-.619.357-1.356.523-2.117.523zm5.899 2.83a5.947 5.947 0 005.827-4.756C22.287 18.339 24 15.84 24 13.296c0-1.665-.713-3.282-1.998-4.448.119-.5.19-.999.19-1.498 0-3.401-2.759-5.947-5.946-5.947-.642 0-1.26.095-1.88.31A5.962 5.962 0 0010.205 0a5.947 5.947 0 00-5.827 4.757C1.713 5.447 0 7.945 0 10.49c0 1.666.713 3.283 1.998 4.448-.119.5-.19 1-.19 1.499 0 3.401 2.759 5.946 5.946 5.946.642 0 1.26-.095 1.88-.309a5.96 5.96 0 004.162 1.713z" fill="#fff"/></svg></svg>'),
        "claude": ("Claude", "#D97757",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#D97757"/><text x="20" y="27" font-family="Georgia,serif" font-size="22" font-weight="bold" fill="#fff" text-anchor="middle">A</text></svg>'),
        "gemini": ("Gemini", "#4E82EE",
            '<svg viewBox="0 0 40 40" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="40" rx="10" fill="#4E82EE"/><path d="M20 6c0 7.7-6.3 14-14 14 7.7 0 14 6.3 14 14 0-7.7 6.3-14 14-14-7.7 0-14-6.3-14-14z" fill="#fff"/></svg>'),
    }

    def flag(cc):
        cc = (cc or "").upper()
        if len(cc) != 2: return ""
        return chr(ord(cc[0]) + 127397) + chr(ord(cc[1]) + 127397)

    def render_card(key, info):
        name, brand_color, svg = SERVICES[key]
        st = info.get("status", "error")
        txt_color, badge_bg, card_bg, label, badge_icon = STATUS_META.get(st, ("#374151", "#f3f4f6", "#f9fafb", st, "?"))
        region = info.get("region", "")
        detail = info.get("detail", "")
        flag_str = flag(region)
        region_html = f'<span class="flag-chip">{flag_str}&nbsp;{region}</span>' if region else ""
        return f'''<div class="card" style="background:{card_bg}">
  <div class="card-icon">{svg}</div>
  <div class="card-body">
    <div class="card-title">{name}&nbsp;{region_html}</div>
    <div class="card-detail">{detail}</div>
  </div>
  <div class="badge" style="color:{txt_color};background:{badge_bg}">
    <span class="badge-icon">{badge_icon}</span>{label}
  </div>
</div>'''

    exit_info   = data.get("exit", {})
    exit_ip     = exit_info.get("ip", "—")
    exit_rgn    = exit_info.get("region", "")
    exit_detail = (exit_info.get("detail") or "").split("\n")
    exit_place  = exit_detail[0] if exit_detail else ""
    exit_isp    = exit_detail[1] if len(exit_detail) > 1 else ""
    updated_at  = data.get("updated_at")
    updated_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(updated_at)) if updated_at else "—"

    streaming_keys = ["youtube_premium","netflix","disney_plus","prime_video","tiktok","bbc_iplayer","abema","bilibili_intl"]
    ai_keys        = ["google_play","chatgpt","claude","gemini"]

    _empty = {"status": "error", "detail": "无数据"}

    def section(title, keys):
        cards = "".join(render_card(k, data.get(k, _empty)) for k in keys)
        return f'<div class="section"><div class="section-label">{title}</div><div class="card-list">{cards}</div></div>'

    streaming_html = section("流媒体", streaming_keys)
    ai_html        = section("AI 服务", ai_keys)

    html = f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>综合解锁检测</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{
  font-family:"Segoe UI Variable","Segoe UI",-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;
  background:linear-gradient(135deg,#e8eaf0 0%,#dde3ee 100%);
  min-height:100vh;
  color:#1a1a2e;
}}
.topbar{{
  background:rgba(255,255,255,.75);
  backdrop-filter:blur(20px) saturate(180%);
  -webkit-backdrop-filter:blur(20px) saturate(180%);
  border-bottom:1px solid rgba(0,0,0,.08);
  padding:14px 20px;
  display:flex;align-items:center;justify-content:space-between;
  position:sticky;top:0;z-index:100;
}}
.topbar-title{{font-size:1rem;font-weight:600;color:#1a1a2e;letter-spacing:-.01em}}
.topbar-btn{{
  background:#0078d4;color:#fff;border:none;border-radius:6px;
  padding:6px 16px;font-size:.82rem;font-weight:500;
  cursor:pointer;text-decoration:none;letter-spacing:.01em;
  box-shadow:0 1px 4px rgba(0,120,212,.3);
  transition:background .15s;
}}
.topbar-btn:hover{{background:#106ebe}}
.wrap{{max-width:600px;margin:0 auto;padding:16px 14px 40px}}
.exit-card{{
  background:rgba(255,255,255,.85);
  backdrop-filter:blur(12px);
  border-radius:14px;
  border:1px solid rgba(255,255,255,.9);
  box-shadow:0 2px 12px rgba(0,0,0,.08);
  padding:18px 20px;
  display:flex;align-items:center;gap:16px;
  margin-bottom:6px;
}}
.exit-flag{{font-size:2.6rem;line-height:1;filter:drop-shadow(0 1px 2px rgba(0,0,0,.15))}}
.exit-body{{flex:1;min-width:0}}
.exit-ip{{font-size:1.15rem;font-weight:700;letter-spacing:-.01em}}
.exit-sub{{font-size:.8rem;color:#666;margin-top:3px}}
.exit-time{{text-align:center;font-size:.72rem;color:#999;margin-bottom:20px;padding-top:6px}}
.section{{margin-bottom:8px}}
.section-label{{
  font-size:.72rem;font-weight:600;color:#666;
  text-transform:uppercase;letter-spacing:.08em;
  padding:14px 4px 6px;
}}
.card-list{{display:flex;flex-direction:column;gap:8px}}
.card{{
  background:rgba(255,255,255,.88);
  backdrop-filter:blur(8px);
  border:1px solid rgba(255,255,255,.95);
  border-radius:14px;
  box-shadow:0 1px 6px rgba(0,0,0,.07);
  padding:13px 16px;
  display:flex;align-items:center;gap:14px;
  transition:box-shadow .15s,transform .12s;
}}
.card:hover{{box-shadow:0 4px 16px rgba(0,0,0,.10);transform:translateY(-1px)}}
.card-icon{{
  width:44px;height:44px;
  display:flex;align-items:center;justify-content:center;
  flex-shrink:0;
}}
.card-icon svg{{width:40px;height:40px;}}
.card-body{{flex:1;min-width:0}}
.card-title{{
  font-size:.92rem;font-weight:600;
  display:flex;align-items:center;gap:5px;flex-wrap:wrap;
}}
.flag-chip{{font-size:.78rem;color:#888;font-weight:400}}
.card-detail{{font-size:.77rem;color:#888;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
.badge{{
  flex-shrink:0;display:flex;align-items:center;gap:5px;
  font-size:.8rem;font-weight:600;
  padding:5px 12px;border-radius:20px;white-space:nowrap;
}}
.badge-icon{{
  width:16px;height:16px;border-radius:50%;
  background:currentColor;color:#fff;
  display:inline-flex;align-items:center;justify-content:center;
  font-size:.65rem;font-weight:700;flex-shrink:0;
}}
.refresh-wrap{{text-align:center;padding-top:20px}}
.refresh-btn{{
  display:inline-flex;align-items:center;gap:8px;
  background:#0078d4;color:#fff;text-decoration:none;
  border-radius:8px;padding:11px 28px;
  font-size:.88rem;font-weight:500;
  box-shadow:0 2px 8px rgba(0,120,212,.3);
  transition:background .15s;
}}
.refresh-btn:hover{{background:#106ebe}}
</style>
</head>
<body>
<div class="topbar">
  <span class="topbar-title">综合解锁检测</span>
  <a class="topbar-btn" href="/check/{SHOW_TOKEN}?redirect=1">刷新检测</a>
</div>
<div class="wrap">
  <div class="exit-card">
    <div class="exit-flag">{flag(exit_rgn)}</div>
    <div class="exit-body">
      <div class="exit-ip">{exit_ip}</div>
      <div class="exit-sub">{exit_place}{"&nbsp;·&nbsp;" + exit_isp if exit_isp else ""}</div>
    </div>
  </div>
  <div class="exit-time">最后检测：{updated_str}</div>
  {streaming_html}
  {ai_html}
  <div class="refresh-wrap">
    <a class="refresh-btn" href="/check/{SHOW_TOKEN}?redirect=1">🔄&nbsp;手动重新检测</a>
  </div>
</div>
</body>
</html>'''
    if not data:
        return "<h2 style='font-family:sans-serif;padding:40px;color:#999'>尚未完成首次检测，请稍候...</h2>", 503
    return html


@app.route(f'/check/{SHOW_TOKEN}', methods=['GET'])
def trigger_check_redirect():
    threading.Thread(target=run_all_checks, daemon=True).start()
    if 'redirect' in request.args:
        return '<meta http-equiv="refresh" content="35;url=." /><p style="font-family:sans-serif;padding:40px">已触发检测，约 30 秒后自动跳回结果页...</p>'
    return jsonify({"message": "已触发检测，约 30 秒后查询 /status/ 获取最新结果"})


if __name__ == '__main__':
    _load_cache()
    threading.Thread(target=_loop, daemon=True).start()
    app.run(host='0.0.0.0', port=PORT)
PYEOF

echo "[Unit]
Description=${service_name} - Streaming Unlock Detector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=3
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/app.py

[Install]
WantedBy=multi-user.target
" > /etc/systemd/system/"${service_name}".service

systemctl daemon-reload
systemctl enable "${service_name}"
systemctl restart "${service_name}"

sleep 2
SERVER_IP=$(curl -s --max-time 5 https://ipinfo.io/ip || echo "your-server-ip")
SHOW_TOKEN=$(python3 -c "import json; print(json.load(open('${CONFIG_PATH}'))['show_token'])")
ACTUAL_PORT=$(python3 -c "import json; print(json.load(open('${CONFIG_PATH}'))['port'])")

info "安装成功"
echo "可视化面板:   http://${SERVER_IP}:${ACTUAL_PORT}/ui/${SHOW_TOKEN}"
echo "JSON 接口:    http://${SERVER_IP}:${ACTUAL_PORT}/status/${SHOW_TOKEN}"
echo "手动触发检测: http://${SERVER_IP}:${ACTUAL_PORT}/check/${SHOW_TOKEN}"
echo "自动检测间隔: ${INTERVAL} 秒（默认每 30 分钟一次，可用 INTERVAL=xxx 环境变量修改）"
echo

UNINSTALL_FILE="/opt/${service_name}.uninstall.sh"
echo_uninstall "$service_name" > "$UNINSTALL_FILE"
info "如需卸载："
echo "bash $UNINSTALL_FILE"
