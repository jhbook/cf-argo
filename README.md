# Cloudflared Token Tunnel 一键管理脚本（v4）

一个面向 Cloudflare Tunnel（Token 模式）的**一键部署 + 菜单化管理**脚本。支持国内服务器多源加速下载，卸载即干净（连 Token 与快捷命令一起删除）。

## 功能特性

- **一键部署**：自动识别系统与 CPU 架构，多源降级下载 cloudflared 二进制，创建服务并启动
- **交互式菜单**：部署 / 重启 / 日志 / 卸载 / 重装快捷命令 / 更新脚本 一体化管理
- **菜单实时状态**：打开菜单即显示 `运行中（版本）/ 已停止 / 未安装`
- **快捷命令 `a`**：部署成功后自动安装，之后输入 `a` 即可随时打开菜单；支持 `a 1`、`a status` 等参数直达
- **Token 持久化**：保存到 `/etc/cloudflared/token`（600 权限），重装自动复用；卸载时一并清除
- **卸载即干净**：停止并移除服务、删除二进制 / 日志 / logrotate 配置 / Token / 快捷命令 `a`，一次清空
- **更新脚本**：从镜像拉取最新版脚本并替换，`a update` 即可升级

## 系统要求

| 项目 | 支持范围 |
|---|---|
| 系统 | Alpine（OpenRC）、Debian / Ubuntu（systemd） |
| 架构 | x86_64/amd64、aarch64/arm64、armv7l/armhf、i386/i686 |
| 权限 | 需要 root（`sudo` 亦可） |

> 玩客云等 armv7l 设备（如晶晨 S805）需先刷 Armbian（Debian 系）再运行本脚本。

## 快速开始

一键安装（任意方式运行均可，推荐）：

```bash
bash <(curl -sL https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh)
```

备用加速地址（国内服务器更快）：

```bash
bash <(curl -sL https://git.jhbook.eu.org/https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh)
```

或下载到本地运行：

```bash
curl -sL -o cloudflared.sh https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh
chmod +x cloudflared.sh && sudo ./cloudflared.sh
```

首次进入选择 `1` 部署，按提示粘贴 Token 即可。部署成功后自动安装快捷命令 `a`，以后直接输入 `a` 管理。

## 菜单说明

```
============================================
        Cloudflared 管理菜单 v4
============================================

  Cloudflared 状态：运行中（版本）/ 已停止 / 未安装   ← 实时检测

  1) 部署 / 更新 Cloudflared   安装/升级二进制、配置 Token、创建服务、装快捷命令
  2) 重启服务
  3) 查看日志（最近 50 行）
  4) 卸载 Cloudflared          彻底卸载（见下文）
  5) 重新安装快捷命令 a        从镜像重新拉取安装
  6) 更新脚本                  从镜像拉取最新版脚本，替换 /usr/local/bin/a
  0) 退出
```

## 参数直达（跳过菜单）

安装后 `a` 支持关键词或菜单编号直接执行：

```bash
a 1 / a install   部署 / 更新
a 2 / a restart   重启服务
a 3 / a log       查看日志（50 行）
a 4 / a uninstall 卸载
a 5               重装快捷命令 a
a 6 / a update    更新脚本
a status          查看详细状态（服务状态 + 最近日志）
```

## Token 输入方式

两种输入方式均可，脚本自动识别：

```bash
# 方式 1：完整命令（Cloudflare 面板「复制命令」按钮得到的内容）
cloudflared service install eyJhIjoi...

# 方式 2：纯 Token（仅 eyJhIjoi... 开头的一串）
eyJhIjoi...
```

Token 会持久化到 `/etc/cloudflared/token`（600 权限），下次部署自动读取并询问是否复用；输入 `n` 可重新填写。

## 下载源策略

### cloudflared 二进制（三源自动降级）

1. GitHub 代理加速：`git.jhbook.eu.org`（国内快）
2. GitHub 官方 Release 直连
3. 备用代理：`ghproxy.net`

下载后三重校验：`file` 类型检查（拦截 HTML 错误页）→ 打印实际 SHA256（可对照官方 Release 页核对）→ `--version` 可执行验证。

### 脚本自身镜像（装 `a` / 更新脚本用，四源自动降级）

1. `git.jhbook.eu.org` 代理 GitHub raw（优先，国内快 + 即时最新）
2. `ghproxy.net` 代理 GitHub raw（备用）
3. jsDelivr CDN
4. GitHub raw 直连（兜底）

> 注意：jsDelivr 有 CDN 缓存延迟，仓库更新后可能短暂返回旧版；脚本内置内容校验（含「Cloudflared 管理菜单」标识才算有效），命中旧版会自动切下一个源。

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
| 快捷命令 | `/usr/local/bin/a` |

Cloudflare 面板侧的 Tunnel 记录不受影响，可随时重新部署。

## 脚本管理的文件一览

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/cloudflared` | cloudflared 二进制 |
| `/usr/local/bin/a` | 菜单快捷命令 |
| `/etc/cloudflared/token` | Token（600 权限，卸载删除） |
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
部署成功后脚本按镜像顺序下载最新版到 `/usr/local/bin/a`，与运行方式无关（兼容 `bash <(curl ...)` 管道运行）。丢失时菜单选 5 重装。

**Q：如何 fork 后自用？**
改脚本内 `SCRIPT_MIRRORS` 四个地址为你自己的仓库地址；或用环境变量覆盖（不修改脚本本体）：

```bash
SCRIPT_MIRROR=https://你的地址 bash <(curl -sL 你的地址)
```

## 许可证

个人 / 服务器运维自用。二次分发请保留脚本头部说明。
