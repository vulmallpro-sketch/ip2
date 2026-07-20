#!/bin/bash
set -e
if [ -n "$DEBUG_INSTALL" ]; then
	set -x
fi

warning() { echo -e "\033[31m\033[01m$*\033[0m"; }
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }

if [ "$EUID" -ne 0 ]; then
	error "请用 root 权限运行"
fi

#### 服务名（支持静默安装 S=xxx）

if [ -z "$S" ]; then
	read -p "请输入服务名 [默认 ip-api] : " service_name
	service_name=${service_name:-ip-api}
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

command -v python3 >/dev/null 2>&1 || { info "安装 python3..."; apt-get update -qq && apt-get install -y python3 python3-pip; }
command -v curl >/dev/null 2>&1 || apt-get install -y curl
pip3 install flask --break-system-packages -q 2>/dev/null || pip3 install flask -q

PORT="${PORT:-${1:-8080}}"

mkdir -p "$INSTALL_DIR"

CONFIG_PATH="${INSTALL_DIR}/config.json"
if [ ! -f "$CONFIG_PATH" ]; then
	IPCH_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(8))")
	SHOW_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(8))")
	cat > "$CONFIG_PATH" <<EOF
{
  "ipch_token": "${IPCH_TOKEN}",
  "show_token": "${SHOW_TOKEN}",
  "port": ${PORT}
}
EOF
	chmod 600 "$CONFIG_PATH"
else
	info "检测到已有配置，复用现有 token"
fi

cat > "${INSTALL_DIR}/redial.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
dhclient -r
rm -rf /var/lib/dhcp/dhclient*
sleep 30
dhclient -v
reboot
EOF
chmod +x "${INSTALL_DIR}/redial.sh"

cat > "${INSTALL_DIR}/app.py" <<'PYEOF'
from flask import Flask, jsonify, Response
import subprocess, os, json, time, threading

app = Flask(__name__)
BASE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(BASE, 'config.json')) as f:
    cfg = json.load(f)

IPCH_TOKEN = cfg["ipch_token"]
SHOW_TOKEN = cfg["show_token"]
PORT = cfg.get("port", 8080)
REDIAL_SCRIPT = os.path.join(BASE, 'redial.sh')
MIN_INTERVAL = 60

lock = threading.Lock()
last_redial_time = 0


def get_current_ip():
    try:
        r = subprocess.run(['curl', '-s', '--max-time', '5', 'https://ipinfo.io/ip'],
                            capture_output=True, text=True, timeout=8)
        return r.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


@app.route(f'/show/{SHOW_TOKEN}')
def show_ip():
    return jsonify({"ip": get_current_ip()})


POLL_PAGE = """<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<title>换IP中</title>
<style>
body {{ font-family: -apple-system, sans-serif; background:#0f172a; color:#e2e8f0;
       display:flex; align-items:center; justify-content:center; height:100vh; margin:0; }}
.card {{ background:#1e293b; padding:32px 40px; border-radius:12px; text-align:center; min-width:320px; }}
.spinner {{ width:36px; height:36px; border:4px solid #334155; border-top-color:#38bdf8;
           border-radius:50%; animation:spin 1s linear infinite; margin:0 auto 16px; }}
@keyframes spin {{ to {{ transform:rotate(360deg); }} }}
.ip {{ font-size:20px; font-weight:600; color:#38bdf8; margin-top:8px; }}
.old {{ color:#94a3b8; font-size:14px; }}
.done .spinner {{ display:none; }}
.done {{ border: 1px solid #22c55e33; }}
</style>
</head>
<body>
<div class="card" id="card">
  <div class="spinner"></div>
  <div id="status">已触发换IP，机器重启中，请稍候...</div>
  <div class="old">旧IP: {old_ip}</div>
  <div class="ip" id="newip"></div>
</div>
<script>
const oldIp = "{old_ip}";
const showUrl = "/show/{show_token}";
let attempts = 0;
const maxAttempts = 40; // 40 * 5s = 200s 超时

async function poll() {{
  attempts++;
  try {{
    const res = await fetch(showUrl, {{ cache: "no-store" }});
    if (res.ok) {{
      const data = await res.json();
      if (data.ip && data.ip !== "unknown") {{
        document.getElementById('status').innerText =
          data.ip !== oldIp ? "换IP成功" : "重启完成，IP未变化（可能是DHCP租约未释放）";
        document.getElementById('newip').innerText = data.ip;
        document.getElementById('card').classList.add('done');
        return;
      }}
    }}
  }} catch (e) {{
    // 机器重启期间连不上是正常的，继续轮询
  }}
  if (attempts < maxAttempts) {{
    setTimeout(poll, 5000);
  }} else {{
    document.getElementById('status').innerText = "等待超时，请手动刷新查询IP接口";
  }}
}}
setTimeout(poll, 8000); // 先等8秒再开始轮询，给 sleep 30 + reboot 一点缓冲
</script>
</body>
</html>"""


@app.route(f'/ipch/{IPCH_TOKEN}')
def change_ip():
    global last_redial_time
    with lock:
        now = time.time()
        if now - last_redial_time < MIN_INTERVAL:
            wait = int(MIN_INTERVAL - (now - last_redial_time))
            return jsonify({"error": f"too frequent, wait {wait}s"}), 429
        last_redial_time = now

    old_ip = get_current_ip()

    subprocess.Popen(
        ['bash', REDIAL_SCRIPT],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True
    )

    html = POLL_PAGE.format(old_ip=old_ip, show_token=SHOW_TOKEN)
    return Response(html, mimetype='text/html')


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT)
PYEOF

echo "[Unit]
Description=${service_name}
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
IPCH_TOKEN=$(python3 -c "import json; print(json.load(open('${CONFIG_PATH}'))['ipch_token'])")
SHOW_TOKEN=$(python3 -c "import json; print(json.load(open('${CONFIG_PATH}'))['show_token'])")

info "安装成功"
echo "查询IP: http://${SERVER_IP}:${PORT}/show/${SHOW_TOKEN}"
echo "更换IP: http://${SERVER_IP}:${PORT}/ipch/${IPCH_TOKEN}"
echo

UNINSTALL_FILE="/opt/${service_name}.uninstall.sh"
echo_uninstall "$service_name" > "$UNINSTALL_FILE"
info "如需卸载："
echo "bash $UNINSTALL_FILE"
