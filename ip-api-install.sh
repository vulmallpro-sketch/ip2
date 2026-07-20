#!/bin/bash
set -e
if [ -n "$DEBUG_INSTALL" ]; then
	set -x
fi

warning() { echo -e "\033[31m\033[01m$*\033[0m"; }
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }

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

command -v python3 >/dev/null 2>&1 || { info "安装 python3..."; apt_install python3; }
command -v curl >/dev/null 2>&1 || { info "安装 curl..."; apt_install curl; }

if ! command -v pip3 >/dev/null 2>&1; then
  info "安装 pip3..."
  if ! apt_install python3-pip; then
    python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
  python3 -m pip --version >/dev/null 2>&1 || error "pip3 安装失败，请手动安装 python3-pip 后重试"
fi

python3 -m pip install flask --break-system-packages -q 2>/dev/null || python3 -m pip install flask -q

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
    return Response(f"""<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<title>当前IP</title>
<style>
body {{ font-family: -apple-system, sans-serif; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); 
       display:flex; align-items:center; justify-content:center; height:100vh; margin:0; }}
.card {{ background:#fff; padding:48px; border-radius:16px; box-shadow:0 20px 60px rgba(0,0,0,0.3);
       text-align:center; }}
.label {{ font-size:14px; color:#666; margin-bottom:8px; font-weight:500; }}
.ip {{ font-size:48px; font-weight:700; color:#667eea; word-break:break-all; }}
.refresh {{ margin-top:16px; }}
.btn {{ display:inline-block; padding:10px 20px; background:#667eea; color:#fff; border:none; 
      border-radius:8px; cursor:pointer; font-size:14px; transition:all 0.3s; }}
.btn:hover {{ background:#764ba2; transform:translateY(-2px); }}
</style>
</head>
<body>
<div class="card">
  <div class="label">当前公网IP</div>
  <div class="ip" id="ip">{get_current_ip()}</div>
  <div class="refresh">
    <button class="btn" onclick="location.reload()">刷新</button>
  </div>
</div>
</body>
</html>""", mimetype='text/html')


@app.route(f'/api/show/{SHOW_TOKEN}')
def api_show_ip():
    return jsonify({{"ip": get_current_ip()}})


@app.route(f'/ipch/{IPCH_TOKEN}')
def change_ip():
    global last_redial_time
    with lock:
        now = time.time()
        if now - last_redial_time < MIN_INTERVAL:
            wait = int(MIN_INTERVAL - (now - last_redial_time))
            return jsonify({"status": "error", "message": f"too frequent, wait {wait}s"}), 429
        last_redial_time = now

    old_ip = get_current_ip()

    subprocess.Popen(
        ['bash', REDIAL_SCRIPT],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True
    )

    return jsonify({"status": "success", "message": "IP更换已开始执行，机器即将重启", "old_ip": old_ip})


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
