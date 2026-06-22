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
            parts = full.split(':')
            if len(parts) >= 4:
                prefix = ':'.join(parts[:4])
                candidates.append(prefix)
    for p in candidates:
        low = p[-1].lower()
        if low in ('0', '1', '2'):
            return p
    return candidates[0] if candidates else "2408:824e:cb06:a6a0"


def gen_ipv6(prefix):
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


def clean_foreign_addresses(prefix):
    stdout, _ = run_cmd(f"ip -6 addr show dev {INTERFACE} scope global | grep 'inet6'")
    for line in stdout.splitlines():
        if 'deprecated' in line or 'temporary' in line or 'tentative' in line:
            continue
        m = re.search(r'inet6 ([0-9a-f:]+)/(\d+)', line)
        if m:
            addr = m.group(1)
            addr_prefix = ':'.join(addr.split(':')[:4])
            if addr_prefix != prefix:
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
    state = load_state()
    prefix = get_prefix()
    statuses = []
    for i in range(PORT_COUNT):
        port = START_PORT + i
        ipv6 = state.get(str(port), "")
        bound = is_ipv6_used(ipv6) if ipv6 else False
        statuses.append({
            "port": port,
            "ipv6": ipv6,
            "bound": bound,
        })
    return jsonify({
        "ok": True,
        "prefix": prefix,
        "service": get_service_status(),
        "ports": statuses,
    })


@app.route('/api/init', methods=['POST'])
def api_init():
    state = load_state()
    prefix = get_prefix()
    used = set(state.values())

    clean_foreign_addresses(prefix)

    for i in range(PORT_COUNT):
        port = START_PORT + i
        old_ipv6 = state.get(str(port), "")
        if old_ipv6 and is_ipv6_used(old_ipv6):
            del_ipv6(old_ipv6)
            used.discard(old_ipv6)

        while True:
            new_ipv6 = gen_ipv6(prefix)
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
    data = request.get_json() or {}
    state = load_state()
    prefix = get_prefix()
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
            new_ipv6 = gen_ipv6(prefix)
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
