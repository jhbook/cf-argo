# Cloudflared Token Tunnel 一键管理脚本（v8.2）

一个面向 Cloudflare Tunnel（Token 模式）的**一键部署 + 菜单化管理**脚本。支持国内服务器多源加速下载，卸载即干净（连 Token 与快捷命令一起删除）。

## 功能特性

- **一键部署**：自动识别系统与 CPU 架构，多源降级下载 cloudflared 二进制，创建服务并启动
- **交互式菜单**：部署 / 重启 / 日志 / 卸载 / 更新脚本 一体化管理
- **菜单实时状态**：打开菜单即显示 `运行中（版本）/ 已停止 / 未安装`
- **POSIX `sh` 兼容**：使用 `#!/bin/sh`，面向 Alpine BusyBox `ash`，同时支持 Debian / Ubuntu 的 `/bin/sh`
- **快捷命令 `a`**：首次通过远程命令启动时自动安装 `/usr/local/bin/a`，之后输入 `a` 即可通过 `curl -fsSL "$SCRIPT_URL" | sh` 启动远程菜单；交互输入从 `/dev/tty` 读取，避免管道占用菜单输入
- **Token 提取优化**：支持粘贴面板的 `service install` 命令、带 `--token` 的运行命令或纯 Token，自动提取 Token 并校验输入
- **IP 版本可选**：部署时可选 IPv4、IPv6 或 IPv4/IPv6 自动模式，配置会保存并在下次部署时作为默认值；卸载时一并清除
- **卸载即干净**：停止并移除服务、删除二进制 / 日志 / logrotate 配置 / Token / IP 版本配置 / 快捷命令 `a` / 本地管理脚本（如存在），一次清空
- **版本显示**：菜单显示管理脚本版本与已安装的 Cloudflared 版本
- **更新脚本**：验证远程脚本可用并刷新快捷入口，菜单选 `5` 或执行 `a update`

## 系统要求

| 项目 | 支持范围 |
|---|---|
| 系统 | Alpine（OpenRC）、Debian / Ubuntu（systemd） |
| 架构 | x86_64/amd64、aarch64/arm64、armv7l/armhf、i386/i686 |
| 权限 | 需要 root（`sudo` 亦可） |

> 玩客云等 armv7l 设备（如晶晨 S805）需先刷 Armbian（Debian 系）再运行本脚本。

## 快速开始

推荐的一键安装方式（POSIX `sh`，适用于 Alpine / Debian / Ubuntu）：

```sh
curl -fsSL 'https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh' | sh
```

如果代理地址不可用，可尝试 GitHub Raw 直连：

```sh
curl -fsSL 'https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh' | sh
```

也可以下载到本地运行：

```sh
curl -fsSL 'https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh' | sh
chmod +x cloudflared.sh
sh ./cloudflared.sh
```

首次运行会尝试安装快捷命令 `a`，随后进入交互菜单。部署 Cloudflared 需要 root 权限；非 root 用户请先使用 `sudo -i` 切换到 root，再执行安装命令。安装完成后输入 `a` 即可重新打开菜单。
## 菜单说明

```
============================================
        Cloudflared 管理菜单 8.1
============================================

  脚本版本：8.2
  Cloudflared 版本：已安装版本 / 未安装
  Cloudflared 状态：运行中（版本）/ 已停止 / 未安装

  1) 安装 / 更新 Cloudflared 二进制（并配置/启动 Tunnel）
  2) 重启服务
  3) 查看日志（最近 50 行）
  4) 卸载 Cloudflared          彻底卸载（见下文）
  5) 更新脚本 / 快捷入口       验证远程脚本并刷新 /usr/local/bin/a
  0) 退出
```

## 参数直达（跳过菜单）

安装后 `a` 支持关键词或菜单编号直接执行：

```bash
a 1 / a install   部署 / 更新
a 2 / a restart   重启服务
a 3 / a log       查看日志（50 行）
a 4 / a uninstall 卸载
a 5 / a update    更新脚本
a status          查看详细状态（服务状态 + 最近日志）
```

## Token 输入方式

支持以下输入方式，脚本会自动提取 Token：

```bash
# 方式 1：Cloudflare 面板的安装命令
cloudflared service install eyJhIjoi...

# 方式 2：带 --token 的运行命令
cloudflared tunnel run --token eyJhIjoi...

# 方式 3：纯 Token
eyJhIjoi...
```

Token 会持久化到 `/etc/cloudflared/token`（600 权限），下次部署自动读取并询问是否复用；输入 `n` 可重新填写。

## 连接 IP 版本选择

每次部署或更新服务时，可选择 Cloudflared 连接 Cloudflare Edge 的 IP 版本：

1. **IPv4**：仅通过 IPv4 连接（`--edge-ip-version 4`）
2. **IPv6**：仅通过 IPv6 连接（`--edge-ip-version 6`）
3. **IPv4/IPv6 自动**：根据系统 DNS 解析顺序选择优先地址族，并在双栈环境下具备连接回退能力（`--edge-ip-version auto`）

选择会保存到 `/etc/cloudflared/edge_ip_version`，下次部署时按上次选择作为默认值；直接回车沿用默认值。请注意，“自动”不是同时强制使用两种协议，而是由 Cloudflared 根据系统解析结果选择优先地址族并处理回退。

## 下载源策略

### cloudflared 二进制（三源自动降级）

1. GitHub 代理加速：`git.jhbook.eu.org`（国内快）
2. GitHub 官方 Release 直连
3. 备用代理：`ghproxy.net`

下载后三重校验：`file` 类型检查（拦截 HTML 错误页）→ 打印实际 SHA256（可对照官方 Release 页核对）→ `--version` 可执行验证。

### 脚本自身镜像（安装 `a` / 更新快捷入口用，双源自动降级）

1. GitHub raw：`raw.githubusercontent.com`（默认优先，保持即时更新）
2. jsDelivr CDN：`cdn.jsdelivr.net`（raw 不可用时回退）

> 注意：jsDelivr 可能存在 CDN 缓存延迟。脚本会检查下载内容是否包含「Cloudflared 管理菜单」标识；快捷命令 `a` 本身是一个远程启动入口，每次执行都会先尝试 GitHub raw，失败时回退到 jsDelivr CDN，验证脚本标识后再通过 `curl | sh` 执行，避免管道占用交互输入导致菜单循环打印。

## 卸载说明

```bash
a 4   或   a uninstall   或   菜单选 4
```

卸载会**彻底清除**（无需二次确认是否保留，卸载即干净）：

| 项目 | 路径 |
|---|---|
| 服务 | `/etc/systemd/system/cloudflared.service` 或 `/etc/init.d/cloudflared` |
| 二进制 | `/usr/local/bin/cloudflared` |
| 日志 | `/var/log/cloudflared.log` |
| logrotate | `/etc/logrotate.d/cloudflared` |
| Token | `/etc/cloudflared/token`（目录一并删除） |
| IP 版本选择 | `/etc/cloudflared/edge_ip_version`（卸载删除） |
| 快捷命令 | `/usr/local/bin/a` |
| 本地管理脚本（如存在） | `/usr/local/bin/cloudflared.sh` |

Cloudflare 面板侧的 Tunnel 记录不受影响，可随时重新部署。

## 脚本管理的文件一览

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/cloudflared` | cloudflared 二进制 |
| `/usr/local/bin/a` | 菜单快捷命令 |
| `/etc/cloudflared/token` | Token（600 权限，卸载删除） |
| `/etc/cloudflared/edge_ip_version` | IP 版本选择（600 权限，卸载删除） |
| `/var/log/cloudflared.log` | 运行日志（logrotate 每日轮转，保留 7 份压缩） |
| `/etc/logrotate.d/cloudflared` | logrotate 配置 |
| `/etc/systemd/system/cloudflared.service` | systemd 服务 |
| `/etc/init.d/cloudflared` | OpenRC 服务（Alpine） |

## 常见问题

**Q：菜单显示「已停止」但 Cloudflare 面板显示连接正常？**
服务可能正在重启间隙，等几秒再开菜单；或 `a log` 看日志排障。

**Q：为什么不用 jsDelivr 加速 cloudflared 二进制？**
jsDelivr 的 `gh/` 只代理 GitHub 仓库内容，**不代理 Release 资产**（404）；且二进制约 38MB 超其单文件上限。jsDelivr 仅用于代理脚本本体。

**Q：部署时下载失败怎么办？**
脚本会依次尝试 3 个二进制源。全部失败通常是外网连通 / DNS 问题，检查后再选菜单 1 重试。

**Q：快捷命令 `a` 是怎么来的？**
首次以 root 运行时自动写入 `/usr/local/bin/a`。入口使用 `curl -fsSL "$SCRIPT_URL" | sh` 启动远程脚本。为避免管道占用标准输入，所有交互式输入都从 `/dev/tty` 读取，因此可以直接使用 `curl -fsSL '脚本地址' | sh`。菜单选 5 可更新脚本/快捷入口。

**Q：如何 fork 后自用？**
修改脚本中的 `SCRIPT_MIRROR_DEFAULT`（GitHub raw）和 `SCRIPT_MIRROR_BACKUP1`（jsDelivr CDN）为你自己的仓库地址。脚本使用 POSIX `sh`，推荐这样启动：

```sh
curl -fsSL 'https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh' | sh
```

## 许可证

个人 / 服务器运维自用。二次分发请保留脚本头部说明。


## 快捷命令 `a` 报错排查

快捷命令固定从以下地址获取脚本：

```sh
curl -fsSL 'https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh' | sh
```

如果运行 `a` 出现 `curl: (3) URL using bad/illegal format or missing URL`，通常是旧版快捷入口保存了空地址或错误地址。请先用上面的命令运行最新版，在菜单中选择 **5）更新脚本 / 快捷入口**，重新生成 `/usr/local/bin/a`。
