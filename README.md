# Cloudflared Token Tunnel 自动部署脚本

一个 **安全、简洁** 的 cloudflared Token Tunnel 自动部署脚本，  
支持 **Alpine Linux（OpenRC）** 与 **Debian / Ubuntu（systemd）**。

---

## ✨ 特性

- ✅ 支持 Cloudflare Tunnel **Token 模式**
- ✅ 自动识别系统（Alpine / Debian / Ubuntu）
- ✅ 自动安装 cloudflared 并注册为系统服务
- ✅ 支持 OpenRC / systemd
- ✅ **安全设计：不 eval、不执行用户输入**
- ✅ 既可粘贴完整命令，也可直接粘贴 Token

---

## 📦 支持系统

| 系统 | 初始化方式 |
|------|------------|
| Alpine Linux | OpenRC |
| Debian | systemd |
| Ubuntu | systemd |

---er

## 🚀 使用方法

### 1️⃣ 运行脚本

```bash
bash <(curl -sL https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh)
```
### 2️⃣ 卸载脚本
```bash
bash <(curl -sL https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared-uninstall.sh)
```
