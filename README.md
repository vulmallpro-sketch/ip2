# IP-API - 一键更换IP服务

一个轻量级的 IP 更换服务，部署在 VPS 上可实现远程一键换IP。基于 DHCP 重新申请和机器重启来更新公网 IP，提供 Web API 接口。

## 📋 功能特性

- ✅ **查看 IP**：实时查询当前服务器的公网 IP
- ✅ **更换 IP**：通过 DHCP 重新申请 + 机器重启来更换 IP
- ✅ **一键安装**：支持完全自动化部署，自动处理依赖和配置
- ✅ **Token 认证**：生成随机 Token 保护 API 接口
- ✅ **智能限流**：防止频繁调用，60 秒内最多换一次 IP
- ✅ **自动启动**：以 systemd 服务运行，机器重启后自动启动
- ✅ **Web UI**：更换 IP 时提供实时进度显示页面

## 🚀 快速开始

### 一键安装

**要求**：
- 需要 root 权限
- Linux 系统（Debian/Ubuntu）
- 网络连接正常

**安装命令**：

```bash
bash <(curl -fLSs https://raw.githubusercontent.com/vulmallpro-sketch/ip2/main/ip-api-install.sh)
```

**交互式安装流程**：
1. 脚本会提示输入服务名称（默认 `ip-api`）
2. 自动检查并安装依赖（Python3、Pip、Curl）
3. 生成 Token 并配置 systemd 服务
4. 安装完成后显示 API 地址和 Token

**安装输出示例**：
```
安装 python3...
安装 pip3...
安装成功
查询IP: http://your.server.ip:8080/show/abc123def456
更换IP: http://your.server.ip:8080/ipch/xyz789abc123
```

### 静默安装（指定参数）

如果需要自动化脚本部署，可用环境变量指定参数：

```bash
# 指定服务名
S=my-ip-api bash <(curl -fLSs https://raw.githubusercontent.com/vulmallpro-sketch/ip2/main/ip-api-install.sh)

# 指定端口（通过 PORT 环境变量）
PORT=9090 bash <(curl -fLSs https://raw.githubusercontent.com/vulmallpro-sketch/ip2/main/ip-api-install.sh)

# 启用调试输出
DEBUG_INSTALL=1 bash <(curl -fLSs https://raw.githubusercontent.com/vulmallpro-sketch/ip2/main/ip-api-install.sh)
```

## 📡 API 使用

安装完成后，脚本会输出两个 API 地址和对应的 Token。

### 查询 IP

**端点**：`GET /show/{SHOW_TOKEN}`

**功能**：获取当前服务器的公网 IP

**示例**：
```bash
curl http://your.server.ip:8080/show/abc123def456
```

**响应**：
```json
{
  "ip": "203.0.113.42"
}
```

### 更换 IP

**端点**：`GET /ipch/{IPCH_TOKEN}`

**功能**：触发 IP 更换流程（DHCP 重新申请 + 机器重启）

**示例**：
```bash
curl http://your.server.ip:8080/ipch/xyz789abc123
```

**流程**：
1. 触发请求后，脚本会在后台启动重启流程
2. 返回 HTML 页面，显示实时换 IP 进度
3. 脚本在后台：
   - 释放 DHCP 租约（`dhclient -r`）
   - 等待 30 秒
   - 重新申请 IP（`dhclient -v`）
   - 重启机器（`reboot`）
4. 页面会每 5 秒查询一次新 IP，更新进度
5. 新 IP 获得或等待超时（200 秒）后停止轮询

**限流**：
- 同一台服务器 60 秒内无法连续触发换 IP
- 超限会返回 HTTP 429 和错误信息：`{"error": "too frequent, wait XXs"}`

## 📦 安装文件说明

安装后生成的文件结构（默认路径 `/opt/ip-api`）：

```
/opt/ip-api/
├── app.py              # Flask 应用主文件
├── config.json         # 配置（token 和端口）
├── redial.sh           # DHCP 重新申请和重启脚本
└── ip-api.uninstall.sh # 卸载脚本
```

**配置文件** `config.json`：
```json
{
  "ipch_token": "生成的更换IP Token",
  "show_token": "生成的查询IP Token",
  "port": 8080
}
```

## 🔧 管理服务

假设服务名为 `ip-api`（默认值）：

### 查看服务状态
```bash
systemctl status ip-api
```

### 查看运行日志
```bash
journalctl -u ip-api -f
```

### 重启服务
```bash
systemctl restart ip-api
```

### 停止服务
```bash
systemctl stop ip-api
```

### 卸载服务

安装脚本会自动生成卸载脚本 `/opt/ip-api.uninstall.sh`：

```bash
bash /opt/ip-api.uninstall.sh
```

或手动卸载：
```bash
systemctl disable --now ip-api
rm -f /etc/systemd/system/ip-api.service
rm -rf /opt/ip-api
```

### 重装服务

如果需要重新安装替换已有的服务，运行安装脚本时选择 `r` 选项：

```
该服务已存在，请先运行以下命令卸载：
...
或者输入 [r] 彻底重装（不保留token）: r
```

## ⚙️ 环境变量和配置

### 安装时可用的环境变量

| 变量 | 说明 | 示例 |
|-----|------|------|
| `S` | 服务名称 | `S=my-api` |
| `PORT` | 服务端口 | `PORT=9090` |
| `DEBUG_INSTALL` | 启用调试日志 | `DEBUG_INSTALL=1` |

### 已安装后修改配置

编辑 `/opt/ip-api/config.json` 后重启服务：

```bash
systemctl restart ip-api
```

## 🛡️ 安全建议

1. **Token 保护**：Token 是随机生成的，但建议不要在公网直接暴露这些地址
   - 使用 Nginx/Caddy 反向代理添加认证
   - 使用防火墙限制 IP 访问范围

2. **Token 更换**：如果 Token 泄露，编辑 `config.json` 手动修改并重启服务

3. **端口配置**：默认监听 `0.0.0.0`（所有网卡），如需限制可修改 `app.py`

## 📝 故障排查

### 安装失败：pip3 找不到

**症状**：
```
/dev/fd/63: line 47: pip3: command not found
```

**解决**：
脚本已改进，会自动尝试 `python3 -m ensurepip` 安装 pip。如果仍然失败：

```bash
apt-get update
apt-get install -y python3-pip
```

然后重新运行安装脚本。

### 服务无法启动

检查日志：
```bash
journalctl -u ip-api -n 50
```

常见原因：
- Port 已被占用：改用其他端口重装
- 权限问题：确保以 root 运行
- Python 依赖缺失：重新运行安装脚本

### 换 IP 无法生效

确认事项：
1. 机器需要支持 DHCP（大多数云服务商 VPS 支持）
2. 检查接口是否真的被调用（查看日志）
3. DCHP 租约可能未真正释放，稍等重试

## 📄 许可

MIT License
