# Xray SOCKS5 IPv6 Proxy Manager

每个 SOCKS5 端口绑定独立 IPv6 出口地址，通过 Web 管理面板一键管理。

## 功能

- 10 个 SOCKS5 端口（1081-1090），每个绑定独立 IPv6
- Web 管理面板：一键初始化、一键换 IP、单条换 IP、出口验证
- 自动检测 IPv6 前缀，随机生成不重复的出口地址
- 纯 IPv6 出口，屏蔽所有 IPv4 流量
- 支持 x86_64 / aarch64 / armv7l 架构

## 一键安装

```bash
curl -sL https://raw.githubusercontent.com/xmeng-cx/xray-socks5-ipv6/main/install.sh | bash -s
```

或手动安装：

```bash
git clone https://github.com/xmeng-cx/xray-socks5-ipv6.git
cd xray-socks5-ipv6
chmod +x install.sh
./install.sh
```

## 使用方法

安装完成后访问管理面板：

```
http://<服务器IP>:8888
```

1. 点击 **一键初始化** — 自动生成 IPv6 并配置 Xray
2. 查看端口列表 — 每个端口显示独立的 IPv6 出口
3. 点击 **换IP** — 更换指定端口的出口 IPv6
4. 点击 **验证** — 检测端口的实际出口地址

## SOCKS5 连接信息

| 项目 | 值 |
|------|-----|
| 地址 | `<服务器IP>` |
| 端口 | 1081-1090 |
| 用户名 | `xrayuser` |
| 密码 | `a815c8e8d6a57229` |
| 协议 | SOCKS5 (支持 TCP/UDP) |

## 技术架构

```
客户端 → SOCKS5 (port 1081) → XrayL (sendThrough IPv6) → 目标网站
              ↓                        ↓
         Web 面板 (port 8888)    IPv6 出口地址
```

- **XrayL**: 基于 Xray-core 的 SOCKS5 代理，TOML 配置
- **sendThrough**: 指定每个 outbound 的源 IPv6 地址
- **Flask**: Web 管理面板后端

## 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 一键安装脚本 |
| `app.py` | Flask 管理面板后端 |
| `templates/index.html` | Web 管理界面 |

## 系统服务

```bash
# XrayL 代理服务
systemctl status xrayL
systemctl restart xrayL

# 管理面板
systemctl status xray-panel
systemctl restart xray-panel
```

## 环境要求

- Linux (Debian/Ubuntu/Armbian)
- Python 3
- IPv6 公网地址
- root 权限

## 卸载

```bash
systemctl stop xray-panel xrayL
systemctl disable xray-panel xrayL
rm -f /etc/systemd/system/xray-panel.service /etc/systemd/system/xrayL.service
rm -rf /opt/xray-panel /usr/local/bin/xrayL /etc/xrayL
systemctl daemon-reload
```
