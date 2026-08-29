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

    STATUS_META = {
        "available":   ("#16a34a", "#dcfce7", "可用"),
        "partial":     ("#b45309", "#fef3c7", "部分"),
        "unavailable": ("#dc2626", "#fee2e2", "受限"),
        "warning":     ("#b45309", "#fef3c7", "警告"),
        "error":       ("#6b7280", "#f3f4f6", "失败"),
        "info":        ("#2563eb", "#dbeafe", "信息"),
    }
    SERVICES = {
        "youtube_premium": ("YouTube Premium", "#FF0000", "https://img.icons8.com/color/96/youtube-play.png"),
        "netflix":         ("Netflix",         "#E50914", "https://img.icons8.com/color/96/netflix.png"),
        "disney_plus":     ("Disney+",         "#0063E5", "https://img.icons8.com/color/96/disney-plus.png"),
        "prime_video":     ("Prime Video",     "#00A8E1", "https://img.icons8.com/color/96/amazon-prime-video.png"),
        "tiktok":          ("TikTok",          "#010101", "https://img.icons8.com/color/96/tiktok.png"),
        "bbc_iplayer":     ("BBC iPlayer",     "#C0002A", "https://img.icons8.com/color/96/bbc.png"),
        "abema":           ("ABEMA",           "#7C3AED", "https://img.icons8.com/color/96/tv-show.png"),
        "bilibili_intl":   ("哔哩哔哩港澳台",  "#FB7299", "https://img.icons8.com/color/96/bilibili.png"),
        "google_play":     ("Google Play 地区","#4285F4", "https://img.icons8.com/color/96/google-play.png"),
        "chatgpt":         ("ChatGPT",         "#10A37F", "https://img.icons8.com/color/96/chatgpt.png"),
        "claude":          ("Claude",          "#D97757", "https://img.icons8.com/color/96/claude.png"),
        "gemini":          ("Gemini",          "#4E82EE", "https://img.icons8.com/color/96/google-gemini.png"),
    }

    def flag(cc):
        cc = (cc or "").upper()
        if len(cc) != 2: return ""
        return chr(ord(cc[0]) + 127397) + chr(ord(cc[1]) + 127397)

    def render_row(key, info):
        name, brand_color, icon_url = SERVICES[key]
        st = info.get("status", "error")
        txt_color, badge_bg, label = STATUS_META.get(st, ("#6b7280", "#f3f4f6", st))
        region  = info.get("region", "")
        detail  = info.get("detail", "")
        flag_html = f'{flag(region)}&nbsp;' if region else ""
        return f'''<div class="row">
  <div class="row-icon" style="background:{brand_color}1a;border-color:{brand_color}33">
    <img src="{icon_url}" alt="{name}" onerror="this.style.display='none';this.parentNode.innerHTML='<span style=font-size:1.4rem;color:{brand_color}>●</span>'" />
  </div>
  <div class="row-body">
    <div class="row-name">{name}&nbsp;<span class="row-flag">{flag_html}{region}</span></div>
    <div class="row-detail">{detail}</div>
  </div>
  <div class="row-badge" style="color:{txt_color};background:{badge_bg}">{label}</div>
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
        rows = "".join(render_row(k, data.get(k, _empty)) for k in keys)
        return f'<div class="section"><div class="section-title">{title}</div><div class="list">{rows}</div></div>'

    streaming_html = section("🎬 流媒体", streaming_keys)
    ai_html        = section("🤖 AI 服务", ai_keys)

    html = f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>综合解锁检测</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB",sans-serif;background:#f2f2f7;color:#1c1c1e;min-height:100vh}}
.topbar{{background:#fff;padding:16px 20px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #e5e5ea;position:sticky;top:0;z-index:10}}
.topbar-title{{font-size:1.05rem;font-weight:600;color:#1c1c1e}}
.topbar-btn{{background:#007aff;color:#fff;border:none;border-radius:8px;padding:6px 14px;font-size:.85rem;cursor:pointer;text-decoration:none}}
.exit-card{{margin:16px;background:#fff;border-radius:14px;padding:16px 18px;display:flex;align-items:center;gap:14px;box-shadow:0 1px 3px rgba(0,0,0,.07)}}
.exit-flag{{font-size:2.2rem;line-height:1}}
.exit-body{{flex:1;min-width:0}}
.exit-ip{{font-size:1.1rem;font-weight:700;color:#1c1c1e;letter-spacing:.02em}}
.exit-place{{font-size:.82rem;color:#8e8e93;margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.exit-meta{{font-size:.75rem;color:#c7c7cc;margin-top:10px;text-align:center}}
.section{{margin:0 16px 20px}}
.section-title{{font-size:.75rem;font-weight:600;color:#8e8e93;text-transform:uppercase;letter-spacing:.06em;padding:12px 4px 6px}}
.list{{background:#fff;border-radius:14px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.07)}}
.row{{display:flex;align-items:center;gap:14px;padding:13px 16px;border-bottom:1px solid #f2f2f7}}
.row:last-child{{border-bottom:none}}
.row-icon{{width:44px;height:44px;border-radius:12px;border:1px solid transparent;display:flex;align-items:center;justify-content:center;flex-shrink:0;overflow:hidden}}
.row-icon img{{width:32px;height:32px;object-fit:contain}}
.row-body{{flex:1;min-width:0}}
.row-name{{font-size:.93rem;font-weight:600;color:#1c1c1e;display:flex;align-items:center;gap:4px;flex-wrap:wrap}}
.row-flag{{font-size:.8rem;color:#8e8e93;font-weight:400}}
.row-detail{{font-size:.78rem;color:#8e8e93;margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.row-badge{{flex-shrink:0;font-size:.78rem;font-weight:600;padding:4px 10px;border-radius:20px;white-space:nowrap}}
.refresh-wrap{{text-align:center;padding:8px 16px 32px}}
.refresh-btn{{display:inline-block;background:#007aff;color:#fff;text-decoration:none;border-radius:12px;padding:12px 32px;font-size:.9rem;font-weight:500}}
</style>
</head>
<body>
<div class="topbar">
  <span class="topbar-title">综合解锁检测</span>
  <a class="topbar-btn" href="/check/{SHOW_TOKEN}?redirect=1">刷新检测</a>
</div>
<div class="exit-card">
  <div class="exit-flag">{flag(exit_rgn)}</div>
  <div class="exit-body">
    <div class="exit-ip">{exit_ip}</div>
    <div class="exit-place">{exit_place}{"&nbsp;·&nbsp;" + exit_isp if exit_isp else ""}</div>
  </div>
</div>
<div class="exit-meta">最后检测：{updated_str}</div>
{streaming_html}
{ai_html}
<div class="refresh-wrap">
  <a class="refresh-btn" href="/check/{SHOW_TOKEN}?redirect=1">🔄 手动触发重新检测</a>
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
