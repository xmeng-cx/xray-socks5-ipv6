#!/bin/bash
set -e

INSTALL_DIR="/opt/xray-panel"
XRAYL_BIN="/usr/local/bin/xrayL"
XRAYL_CONFIG="/etc/xrayL/config.toml"
XRAYL_SERVICE="xrayL"
PANEL_SERVICE="xray-panel"
PANEL_PORT=8888

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 用户运行此脚本"
    fi
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)  echo "64" ;;
        aarch64) echo "arm64-v8a" ;;
        armv7l)  echo "arm32-v7a" ;;
        *)       error "不支持的架构: $arch" ;;
    esac
}

install_deps() {
    info "安装依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq curl unzip python3 python3-pip > /dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl unzip python3 python3-pip > /dev/null 2>&1
    else
        error "不支持的包管理器"
    fi
    pip3 install flask --break-system-packages -q 2>/dev/null || \
    pip3 install flask -q 2>/dev/null || \
    python3 -m pip install flask -q
}

install_xray() {
    if [ -f "$XRAYL_BIN" ]; then
        info "XrayL 已存在，跳过安装"
        return
    fi
    local arch=$(detect_arch)
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    local tmp_zip="/tmp/xrayl.zip"
    info "下载 Xray ($arch)..."
    curl -sL "$url" -o "$tmp_zip" || error "下载 Xray 失败"
    unzip -o "$tmp_zip" -d /tmp/xrayl_extract > /dev/null 2>&1
    mv /tmp/xrayl_extract/xray "$XRAYL_BIN"
    chmod +x "$XRAYL_BIN"
    rm -rf "$tmp_zip" /tmp/xrayl_extract
    info "XrayL 安装完成: $($XRAYL_BIN version | head -1)"
}

setup_xrayl_service() {
    cat > /etc/systemd/system/${XRAYL_SERVICE}.service << EOF
[Unit]
Description=XrayL Service
After=network.target

[Service]
ExecStart=${XRAYL_BIN} -c ${XRAYL_CONFIG}
Restart=on-failure
User=nobody
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ${XRAYL_SERVICE} > /dev/null 2>&1
}

install_panel() {
    info "安装管理面板..."
    mkdir -p "${INSTALL_DIR}/templates"

    cat > "${INSTALL_DIR}/app.py" << 'PYLEOF'
#!/usr/bin/env python3
import os
import json
import random
import subprocess
import re
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

INSTALL_DIR = "/opt/xray-panel"
STATE_FILE = os.path.join(INSTALL_DIR, "state.json")
XRAYL_CONFIG = "/etc/xrayL/config.toml"
XRAYL_SERVICE = "xrayL"
INTERFACE = "eth0"
SOCKS_USER = "xrayuser"
SOCKS_PASS = "a815c8e8d6a57229"
START_PORT = 1081
PORT_COUNT = 10
PREFIX_CACHE = None


def run_cmd(cmd):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
    return result.stdout.strip(), result.returncode


def get_prefix():
    stdout, _ = run_cmd(f"ip -6 addr show dev {INTERFACE} scope global | grep 'inet6'")
    candidates = []
    for line in stdout.splitlines():
        if 'deprecated' in line or 'temporary' in line or 'tentative' in line:
            continue
        m = re.search(r'inet6 ([0-9a-f:]+)/(\d+)', line)
        if m:
            full = m.group(1)
            plen = int(m.group(2))
            candidates.append((full, plen))

    for full, plen in candidates:
        parts = full.split(':')
        if plen <= 52:
            return ':'.join(parts[:3]), 'wide'
        if plen <= 60:
            return ':'.join(parts[:3]), 'narrow'
        if plen == 64:
            return ':'.join(parts[:4]), 'fixed'
        if plen == 128:
            continue

    if candidates:
        full, plen = candidates[0]
        parts = full.split(':')
        if plen == 128:
            return ':'.join(parts[:4]), 'fixed'
        return ':'.join(parts[:4]), 'fixed'

    return "2408:824e:cb06:a6a0", 'fixed'


def get_prefix_info():
    global PREFIX_CACHE
    if PREFIX_CACHE is None:
        PREFIX_CACHE = get_prefix()
    return PREFIX_CACHE


def gen_ipv6(prefix, mode):
    if mode == 'narrow':
        subnet_nib = f'{random.randint(0, 0xf):x}'
        parts = prefix.split(':')
        fourth = parts[3][:3] + subnet_nib if len(parts) >= 4 else subnet_nib
        base = ':'.join(parts[:3])
        host = ':'.join(f'{random.randint(0, 0xffff):04x}' for _ in range(4))
        return f"{base}:{fourth}:{host}"
    elif mode == 'wide':
        subnet = f'{random.randint(0, 0xf):x}'
        host = ':'.join(f'{random.randint(0, 0xffff):04x}' for _ in range(4))
        return f"{prefix}:{subnet}:{host}"
    else:
        host = ':'.join(f'{random.randint(0, 0xffff):04x}' for _ in range(4))
        return f"{prefix}:{host}"


def is_ipv6_used(ipv6):
    stdout, _ = run_cmd(f"ip -6 addr show dev {INTERFACE} | grep '{ipv6}'")
    return ipv6 in stdout


def load_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, 'w') as f:
        json.dump(state, f, indent=2)


def add_ipv6(ipv6):
    _, code = run_cmd(f"ip -6 addr add {ipv6}/128 dev {INTERFACE}")
    return code == 0


def del_ipv6(ipv6):
    _, code = run_cmd(f"ip -6 addr del {ipv6}/128 dev {INTERFACE}")
    return code == 0


def clean_foreign_addresses(prefix, mode):
    stdout, _ = run_cmd(f"ip -6 addr show dev {INTERFACE} scope global | grep 'inet6'")
    for line in stdout.splitlines():
        if 'deprecated' in line or 'temporary' in line or 'tentative' in line:
            continue
        m = re.search(r'inet6 ([0-9a-f:]+)/(\d+)', line)
        if m:
            addr = m.group(1)
            if not addr.startswith(prefix):
                del_ipv6(addr)


def gen_config(state):
    inbounds = []
    outbounds = []
    rules = []
    for i in range(PORT_COUNT):
        port = START_PORT + i
        tag = f"tag_{i+1}"
        ipv6 = state.get(str(port), "")
        inbounds.append(f'''[[inbounds]]
port = {port}
protocol = "socks"
tag = "{tag}"
[inbounds.settings]
auth = "password"
udp = true
ip = "::"
[[inbounds.settings.accounts]]
user = "{SOCKS_USER}"
pass = "{SOCKS_PASS}"
[inbounds.sniffing]
enabled = true
destOverride = ["http", "tls"]
''')
        outbounds.append(f'''[[outbounds]]
sendThrough = "{ipv6}"
protocol = "freedom"
tag = "{tag}"
''')
        rules.append(f'''[[routing.rules]]
type = "field"
inboundTag = "{tag}"
outboundTag = "{tag}"
''')
    content = 'log = { loglevel = "warning" }\n\n'
    content += '\n'.join(inbounds) + '\n'
    content += '\n'.join(outbounds) + '\n'
    content += '\n'.join(rules)
    os.makedirs(os.path.dirname(XRAYL_CONFIG), exist_ok=True)
    with open(XRAYL_CONFIG, 'w') as f:
        f.write(content)


def restart_xrayl():
    run_cmd(f"systemctl restart {XRAYL_SERVICE}")


def get_service_status():
    stdout, _ = run_cmd(f"systemctl is-active {XRAYL_SERVICE}")
    return stdout


def check_port_exit(port):
    cmd = f'curl -x socks5h://{SOCKS_USER}:{SOCKS_PASS}@127.0.0.1:{port} -s --max-time 8 https://api64.ipify.org'
    stdout, code = run_cmd(cmd)
    if code == 0 and ':' in stdout:
        return stdout
    return None


@app.route('/')
def index():
    return render_template('index.html')


@app.route('/api/status')
def api_status():
    global PREFIX_CACHE
    PREFIX_CACHE = None
    state = load_state()
    prefix, mode = get_prefix_info()
    statuses = []
    for i in range(PORT_COUNT):
        port = START_PORT + i
        ipv6 = state.get(str(port), "")
        bound = is_ipv6_used(ipv6) if ipv6 else False
        statuses.append({"port": port, "ipv6": ipv6, "bound": bound})
    return jsonify({"ok": True, "prefix": prefix, "mode": mode, "service": get_service_status(), "ports": statuses})


@app.route('/api/init', methods=['POST'])
def api_init():
    global PREFIX_CACHE
    PREFIX_CACHE = None
    state = load_state()
    prefix, mode = get_prefix_info()
    used = set(state.values())
    clean_foreign_addresses(prefix, mode)
    for i in range(PORT_COUNT):
        port = START_PORT + i
        old_ipv6 = state.get(str(port), "")
        if old_ipv6 and is_ipv6_used(old_ipv6):
            del_ipv6(old_ipv6)
            used.discard(old_ipv6)
        while True:
            new_ipv6 = gen_ipv6(prefix, mode)
            if new_ipv6 not in used:
                break
        used.add(new_ipv6)
        add_ipv6(new_ipv6)
        state[str(port)] = new_ipv6
    save_state(state)
    gen_config(state)
    restart_xrayl()
    results = [{"port": START_PORT + i, "ipv6": state[str(START_PORT + i)]} for i in range(PORT_COUNT)]
    return jsonify({"ok": True, "message": "初始化完成", "ports": results})


@app.route('/api/change', methods=['POST'])
def api_change():
    global PREFIX_CACHE
    PREFIX_CACHE = None
    data = request.get_json() or {}
    state = load_state()
    prefix, mode = get_prefix_info()
    used = set(state.values())
    changed = []
    ports = data.get("ports", [])
    if not ports:
        port = data.get("port")
        if port:
            ports = [int(port)]
    if not ports:
        return jsonify({"ok": False, "message": "未指定端口"}), 400
    for port in ports:
        port = int(port)
        old_ipv6 = state.get(str(port), "")
        if old_ipv6 and is_ipv6_used(old_ipv6):
            del_ipv6(old_ipv6)
            used.discard(old_ipv6)
        while True:
            new_ipv6 = gen_ipv6(prefix, mode)
            if new_ipv6 not in used:
                break
        used.add(new_ipv6)
        add_ipv6(new_ipv6)
        state[str(port)] = new_ipv6
        changed.append({"port": port, "ipv6": new_ipv6})
    save_state(state)
    gen_config(state)
    restart_xrayl()
    return jsonify({"ok": True, "message": f"已更换 {len(changed)} 个IP", "changed": changed})


@app.route('/api/check/<int:port>')
def api_check(port):
    ipv6 = check_port_exit(port)
    if ipv6:
        return jsonify({"ok": True, "port": port, "exit_ipv6": ipv6})
    return jsonify({"ok": False, "port": port, "message": "检测失败或超时"})


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8888, debug=False)
PYLEOF

    cat > "${INSTALL_DIR}/templates/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Xray SOCKS5 IPv6 Manager</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f172a;color:#e2e8f0;min-height:100vh}
.container{max-width:1100px;margin:0 auto;padding:20px}
.header{text-align:center;padding:30px 0 20px}
.header h1{font-size:24px;font-weight:600;color:#f8fafc}
.header p{color:#94a3b8;margin-top:6px;font-size:14px}
.toolbar{display:flex;gap:12px;justify-content:center;margin:20px 0 30px;flex-wrap:wrap}
.btn{padding:10px 24px;border:none;border-radius:8px;font-size:14px;font-weight:500;cursor:pointer;transition:all .2s;display:inline-flex;align-items:center;gap:8px}
.btn:disabled{opacity:.5;cursor:not-allowed}
.btn-primary{background:#3b82f6;color:#fff}
.btn-primary:hover:not(:disabled){background:#2563eb}
.btn-danger{background:#ef4444;color:#fff}
.btn-danger:hover:not(:disabled){background:#dc2626}
.btn-success{background:#10b981;color:#fff}
.btn-success:hover:not(:disabled){background:#059669}
.btn-sm{padding:6px 14px;font-size:12px;border-radius:6px}
.card{background:#1e293b;border-radius:12px;border:1px solid #334155;overflow:hidden}
.card-header{padding:16px 20px;border-bottom:1px solid #334155;display:flex;justify-content:space-between;align-items:center}
.card-header h2{font-size:16px;font-weight:500}
.badge{padding:4px 10px;border-radius:20px;font-size:12px;font-weight:500}
.badge-green{background:#065f46;color:#6ee7b7}
.badge-red{background:#7f1d1d;color:#fca5a5}
table{width:100%;border-collapse:collapse}
th{text-align:left;padding:12px 16px;font-size:12px;font-weight:600;color:#94a3b8;text-transform:uppercase;letter-spacing:.5px;border-bottom:1px solid #334155;background:#172032}
td{padding:14px 16px;border-bottom:1px solid #1e293b;font-size:14px}
tr:hover td{background:#1a2744}
.ipv6-cell{font-family:'SF Mono',SFMono-Regular,Menlo,monospace;font-size:13px;color:#93c5fd}
.port-cell{font-weight:600;color:#f8fafc}
.status-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
.status-dot.green{background:#10b981;box-shadow:0 0 6px #10b98a}
.status-dot.red{background:#ef4444;box-shadow:0 0 6px #ef4444}
.toast{position:fixed;top:20px;right:20px;padding:14px 20px;border-radius:10px;font-size:14px;z-index:9999;transform:translateX(120%);transition:transform .3s ease;max-width:400px}
.toast.show{transform:translateX(0)}
.toast-success{background:#065f46;color:#6ee7b7;border:1px solid #059669}
.toast-error{background:#7f1d1d;color:#fca5a5;border:1px solid #dc2626}
.toast-info{background:#1e3a5f;color:#93c5fd;border:1px solid #3b82f6}
.spinner{display:inline-block;width:14px;height:14px;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;animation:spin .6s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.empty-state{text-align:center;padding:60px 20px;color:#64748b}
.empty-state p{margin-top:10px;font-size:14px}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>Xray SOCKS5 IPv6 管理面板</h1>
    <p>每个 SOCKS5 端口绑定独立 IPv6 出口地址</p>
  </div>
  <div class="toolbar">
    <button class="btn btn-primary" id="btnInit" onclick="doInit()"><span id="initText">一键初始化</span></button>
    <button class="btn btn-danger" id="btnChangeAll" onclick="doChangeAll()" style="display:none"><span id="changeAllText">一键换全部 IP</span></button>
  </div>
  <div class="card">
    <div class="card-header">
      <h2>SOCKS5 端口列表</h2>
      <span class="badge badge-green" id="serviceBadge" style="display:none">XrayL 运行中</span>
    </div>
    <table>
      <thead><tr><th>端口</th><th>IPv6 出口地址</th><th>绑定状态</th><th style="text-align:right">操作</th></tr></thead>
      <tbody id="portTable"><tr><td colspan="4" class="empty-state"><p>点击"一键初始化"开始配置</p></td></tr></tbody>
    </table>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
let portData=[];
function showToast(m,t='info'){const e=document.getElementById('toast');e.className='toast toast-'+t+' show';e.textContent=m;setTimeout(()=>e.classList.remove('show'),4000)}
function setLoading(b,l,i,o){if(l){b.disabled=true;document.getElementById(i).innerHTML='<span class="spinner"></span> 处理中...'}else{b.disabled=false;document.getElementById(i).textContent=o}}
function renderTable(d){const t=document.getElementById('portTable');portData=d.ports;if(!d.ports||!d.ports.length){t.innerHTML='<tr><td colspan="4" class="empty-state"><p>点击"一键初始化"开始配置</p></td></tr>';document.getElementById('btnChangeAll').style.display='none';return}document.getElementById('btnChangeAll').style.display='';const s=document.getElementById('serviceBadge');if(d.service==='active'){s.className='badge badge-green';s.textContent='XrayL 运行中';s.style.display=''}else{s.className='badge badge-red';s.textContent='XrayL 未运行';s.style.display=''}let h='';for(const p of d.ports){const c=p.bound?'green':'red';const st=p.bound?'已绑定':'未绑定';const ip=p.ipv6||'--';h+=`<tr><td class="port-cell">${p.port}</td><td class="ipv6-cell">${ip}</td><td><span class="status-dot ${c}"></span>${st}</td><td style="text-align:right"><button class="btn btn-success btn-sm" onclick="doChangeOne(${p.port})" ${!p.ipv6?'disabled':''}>换IP</button> <button class="btn btn-primary btn-sm" onclick="doCheck(${p.port})" ${!p.ipv6?'disabled':''}>验证</button></td></tr>`}t.innerHTML=h}
async function fetchStatus(){try{const r=await fetch('/api/status');const d=await r.json();if(d.ok)renderTable(d)}catch(e){showToast('获取状态失败','error')}}
async function doInit(){const b=document.getElementById('btnInit');setLoading(b,true,'initText','一键初始化');showToast('正在初始化...','info');try{const r=await fetch('/api/init',{method:'POST'});const d=await r.json();if(d.ok){showToast(d.message,'success');await fetchStatus()}else showToast('失败: '+d.message,'error')}catch(e){showToast('请求失败','error')}setLoading(b,false,'initText','一键初始化')}
async function doChangeAll(){const b=document.getElementById('btnChangeAll');setLoading(b,true,'changeAllText','一键换全部 IP');showToast('正在更换...','info');try{const r=await fetch('/api/change',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ports:portData.map(p=>p.port)})});const d=await r.json();if(d.ok){showToast(d.message,'success');await fetchStatus()}else showToast('失败','error')}catch(e){showToast('请求失败','error')}setLoading(b,false,'changeAllText','一键换全部 IP')}
async function doChangeOne(p){showToast(`正在更换端口 ${p}...`,'info');try{const r=await fetch('/api/change',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({port:p})});const d=await r.json();if(d.ok){showToast(`端口 ${p} 已更换`,'success');await fetchStatus()}else showToast('失败','error')}catch(e){showToast('请求失败','error')}}
async function doCheck(p){showToast(`正在验证端口 ${p}...`,'info');try{const r=await fetch('/api/check/'+p);const d=await r.json();if(d.ok)showToast(`端口 ${p} 出口: ${d.exit_ipv6}`,'success');else showToast('验证失败','error')}catch(e){showToast('请求失败','error')}}
fetchStatus();
</script>
</body>
</html>
HTMLEOF

    cat > "/etc/systemd/system/${PANEL_SERVICE}.service" << SVCEOF
[Unit]
Description=Xray Panel Web Manager
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/app.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable ${PANEL_SERVICE} > /dev/null 2>&1
    systemctl restart ${PANEL_SERVICE}
}

show_result() {
    local ip=$(hostname -I | awk '{print $1}')
    echo ""
    echo "========================================="
    info "安装完成!"
    echo "========================================="
    echo ""
    echo "  管理面板:  http://${ip}:${PANEL_PORT}"
    echo "  XrayL:    systemctl status ${XRAYL_SERVICE}"
    echo "  Panel:    systemctl status ${PANEL_SERVICE}"
    echo ""
    echo "  默认 SOCKS5 端口: 1081-1090"
    echo "  默认账号: ${SOCKS_USER}"
    echo "  默认密码: ${SOCKS_PASS}"
    echo ""
    echo "  配置文件: ${XRAYL_CONFIG}"
    echo "  安装目录: ${INSTALL_DIR}"
    echo "========================================="
}

main() {
    echo ""
    echo "========================================="
    echo "  Xray SOCKS5 IPv6 一键安装"
    echo "========================================="
    echo ""
    check_root
    install_deps
    install_xray
    setup_xrayl_service
    install_panel
    show_result
}

main "$@"
