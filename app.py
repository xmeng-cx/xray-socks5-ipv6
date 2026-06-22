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
            plen = int(m.group(2))
            candidates.append((full, plen))

    for full, plen in candidates:
        parts = full.split(':')
        if plen <= 48:
            return ':'.join(parts[:3]), 'wide'
        if plen <= 52:
            return ':'.join(parts[:3]), 'wide'
        if plen <= 60:
            subnet_nib = int(parts[3], 16) & 0xf
            return ':'.join(parts[:3]) + ':' + parts[3][:3], 'narrow'
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


PREFIX_CACHE = None


def get_prefix_info():
    global PREFIX_CACHE
    if PREFIX_CACHE is None:
        PREFIX_CACHE = get_prefix()
    return PREFIX_CACHE


def gen_ipv6(prefix, mode):
    if mode == 'narrow':
        subnet_nib = f'{random.randint(0, 0xf):x}'
        fourth = prefix.split(':')[3] + subnet_nib if len(prefix.split(':')) >= 4 else subnet_nib
        base = ':'.join(prefix.split(':')[:3])
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
        statuses.append({
            "port": port,
            "ipv6": ipv6,
            "bound": bound,
        })
    return jsonify({
        "ok": True,
        "prefix": prefix,
        "mode": mode,
        "service": get_service_status(),
        "ports": statuses,
    })


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
