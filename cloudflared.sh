#!/bin/sh

# ============================================================
# Cloudflared Token Tunnel 管理菜单（v7）
#
# 基于 v3 改造，新增：
#   - 交互式菜单：部署/状态/日志/重启/卸载 一体化管理
#   - 快捷命令 a：首次运行自动安装，之后输入 a 即可打开菜单；
#     先下载到临时文件并校验，再执行，避免 curl | sh 占用交互输入
#   - Token 持久化：保存到 /etc/cloudflared/token，重新部署时自动复用；
#     卸载时一并清除，保证卸载干净
#   - 卸载时连同快捷命令 a（/usr/local/bin/a）一并删除，卸载即干净
#
# 保留 v3 全部能力：
#   - Alpine / OpenRC、Debian / Ubuntu / systemd
#   - x86_64 / aarch64 / armv7l(armhf) / i386
#   - 多下载源自动降级（主代理 → 官方直连 → 备用代理）
#   - file 类型检查 + 实际 SHA256 打印 + --version 可执行验证
#   - logrotate 日志轮转
# ============================================================


# ============================================================
# 常量
# ============================================================

SCRIPT_VERSION="v7"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
LOG_FILE="/var/log/cloudflared.log"
TOKEN_FILE="/etc/cloudflared/token"
OPENRC_SERVICE="/etc/init.d/cloudflared"
SYSTEMD_SERVICE="/etc/systemd/system/cloudflared.service"
LOGROTATE_CONF="/etc/logrotate.d/cloudflared"

# 颜色
_red='\033[0;31m'
_green='\033[0;32m'
_yellow='\033[0;33m'
_plain='\033[0m'

GITHUB_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"
GITHUB_PROXY="https://git.jhbook.eu.org/"
GITHUB_PROXY_BACKUP="https://ghproxy.net/"

# 自身镜像地址列表（进程替换/管道运行且无法复制自身时，按序尝试下载）
# 顺序策略：GitHub 代理加速（国内快+即时最新）优先，jsDelivr 其次，raw 直连兜底
# 如果你 fork 了本脚本，请改成你自己的地址；也可运行时用环境变量覆盖：
#   SCRIPT_MIRROR=https://你的地址 bash <(curl -sL ...)
SCRIPT_MIRROR_DEFAULT="https://git.jhbook.eu.org/https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh"
SCRIPT_MIRROR_BACKUP1="https://ghproxy.net/https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh"
SCRIPT_MIRROR_BACKUP2="https://cdn.jsdelivr.net/gh/jhbook/cf-argo@main/cloudflared.sh"
SCRIPT_MIRROR_BACKUP3="https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh"


# ============================================================
# 工具函数
# ============================================================

need_root() {
    [ "$(id -u)" = "0" ] && return 0
    echo "[-] 此操作需要 root 权限，请用 sudo 运行"
    return 1
}

detect_init() {
    if [ -d /run/openrc ]; then
        INIT_TYPE="openrc"
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_TYPE="systemd"
    else
        INIT_TYPE="unknown"
    fi
}

detect_arch() {
    a="$(uname -m)"
    case "$a" in
        x86_64|amd64)      CF_FILE="cloudflared-linux-amd64" ;;
        aarch64|arm64)     CF_FILE="cloudflared-linux-arm64" ;;
        armv7l|armhf)      CF_FILE="cloudflared-linux-armhf" ;;
        i386|i686)         CF_FILE="cloudflared-linux-386" ;;
        *)
            echo "[-] 不支持的 CPU 架构: $a"
            return 1
            ;;
    esac
    ARCH="$a"
    return 0
}

# 安装快捷命令 a：快捷命令始终通过远程脚本启动，便于获取最新版
ensure_shortcut() {
    need_root || return 1
    SHORTCUT_URL=""
    TMP_A="$(mktemp /tmp/a_install.XXXXXX 2>/dev/null)" || {
        echo "[-] 无法创建临时文件"
        return 1
    }

    for mirror in "${SCRIPT_MIRROR:-$SCRIPT_MIRROR_DEFAULT}" "$SCRIPT_MIRROR_BACKUP1" "$SCRIPT_MIRROR_BACKUP2" "$SCRIPT_MIRROR_BACKUP3"; do
        if curl -fsSL --connect-timeout 15 --max-time 60 "$mirror" -o "$TMP_A" \
            && [ -s "$TMP_A" ] \
            && grep -q "Cloudflared 管理菜单" "$TMP_A"; then
            SHORTCUT_URL="$mirror"
            break
        fi
    done
    rm -f "$TMP_A"

    if [ -z "$SHORTCUT_URL" ]; then
        echo "[-] 无法验证远程脚本，快捷命令安装失败"
        return 1
    fi

    cat > /usr/local/bin/a <<EOF
#!/bin/sh
# Cloudflared 管理菜单远程快捷入口
# 先下载到临时文件，再执行；不要使用 curl | sh，否则菜单 read 可能读到脚本内容而循环打印。
set -u
SCRIPT_URL='$SHORTCUT_URL'
TMP_SCRIPT="$(mktemp /tmp/cloudflared-menu.XXXXXX)" || exit 1
trap 'rm -f "$TMP_SCRIPT"' EXIT HUP INT TERM
if ! curl -fsSL --connect-timeout 15 --max-time 120 "$SCRIPT_URL" -o "$TMP_SCRIPT"; then
    echo "[-] 下载管理脚本失败：$SCRIPT_URL" >&2
    exit 1
fi
if [ ! -s "$TMP_SCRIPT" ] || ! grep -q 'Cloudflared 管理菜单' "$TMP_SCRIPT"; then
    echo "[-] 下载内容校验失败，拒绝执行" >&2
    exit 1
fi
sh "$TMP_SCRIPT" "$@"
EOF
    chmod 755 /usr/local/bin/a
    echo "[+] 快捷命令 a 安装完成：运行 a 即可下载并进入远程交互菜单"
}



# ============================================================
# 部署 / 更新 Cloudflared
# ============================================================

deploy() {
    need_root || return 1

    echo ""
    echo "========== 部署 / 更新 Cloudflared =========="

    # ---- 系统检测 ----
    if [ -f /etc/alpine-release ]; then
        echo "[+] 检测到 Alpine Linux"
        apk add --no-cache curl file >/dev/null
    elif [ -f /etc/debian_version ]; then
        echo "[+] 检测到 Debian / Ubuntu"
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y curl file >/dev/null
    else
        echo "[-] 不支持的系统类型（仅支持 Alpine / Debian / Ubuntu）"
        return 1
    fi

    detect_init
    detect_arch || return 1
    echo "[+] Init 系统: $INIT_TYPE | CPU: $ARCH | 文件: $CF_FILE"

    # ---- 检查已有二进制 ----
    NEED_DOWNLOAD=1
    if [ -x "$CLOUDFLARED_BIN" ] && "$CLOUDFLARED_BIN" --version >/dev/null 2>&1; then
        echo ""
        echo "[+] 已安装版本: $("$CLOUDFLARED_BIN" --version)"
        printf "%s" "是否重新下载最新版? [y/N] "; read ANS
        case "$ANS" in
            y|Y|yes|YES) NEED_DOWNLOAD=1 ;;
            *) NEED_DOWNLOAD=0 ;;
        esac
    fi

    # ---- 下载（多源自动降级）----
    if [ "$NEED_DOWNLOAD" = "1" ]; then
        echo ""
        echo "---------- 下载 Cloudflared ----------"

        GITHUB_URL="${GITHUB_BASE}/${CF_FILE}"

        TEMP_FILE="${CLOUDFLARED_BIN}.tmp"
        rm -f "$TEMP_FILE"

        DOWNLOAD_OK=0
        for src in "${GITHUB_PROXY}${GITHUB_URL}" "$GITHUB_URL" "${GITHUB_PROXY_BACKUP}${GITHUB_URL}"; do
            echo "[+] 尝试下载源: $src"
            if command -v curl >/dev/null 2>&1; then
                curl -fL --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 300 -o "$TEMP_FILE" "$src"
            elif command -v wget >/dev/null 2>&1; then
                wget --tries=2 --timeout=15 -O "$TEMP_FILE" "$src"
            else
                echo "[-] 系统没有 curl 或 wget"
                return 1
            fi

            if [ -s "$TEMP_FILE" ]; then
                DOWNLOAD_OK=1
                echo "[+] 下载成功"
                break
            else
                echo "[!] 下载失败，切换下一个下载源..."
            fi
        done

        if [ "$DOWNLOAD_OK" != "1" ]; then
            echo "[-] 所有下载源均失败"
            echo "[!] 排查：外网连通 / DNS / 代理域名是否失效"
            return 1
        fi

        # file 类型检查（拦截 HTML 错误页）
        FILE_TYPE="$(file "$TEMP_FILE" 2>/dev/null || true)"
        echo ""
        echo "[+] 下载文件类型: $FILE_TYPE"
        if echo "$FILE_TYPE" | grep -qiE "HTML|text"; then
            echo "[-] 下载到的不是二进制文件（下载源返回错误页）"
            rm -f "$TEMP_FILE"
            return 1
        fi

        # 打印实际 SHA256（供与官方 Release 页核对）
        echo ""
        echo "[+] 文件 SHA256（可对照官方 Release 页核对）:"
        sha256sum "$TEMP_FILE"

        # 安装
        chmod +x "$TEMP_FILE"
        mv -f "$TEMP_FILE" "$CLOUDFLARED_BIN"
        chmod +x "$CLOUDFLARED_BIN"
        echo "[+] Cloudflared 安装完成"
    else
        echo ""
        echo "[+] 复用现有二进制，跳过下载"
    fi

    # ---- 最终可执行验证 ----
    if ! "$CLOUDFLARED_BIN" --version >/dev/null 2>&1; then
        echo "[-] Cloudflared 无法正常执行（架构不匹配或文件损坏）"
        echo "    当前架构: $ARCH，应使用: $CF_FILE"
        return 1
    fi
    echo ""
    echo "[+] 版本: $("$CLOUDFLARED_BIN" --version)"

    # ---- 获取 Token（复用已保存 / 重新输入）----
    CF_TOKEN=""
    if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
        CF_TOKEN="$(cat "$TOKEN_FILE")"
        echo "[+] 读取已保存的 Token（${#CF_TOKEN} 位）"
        printf "%s" "使用已保存 Token 继续? [Y/n] "; read ANS
        case "$ANS" in
            n|N|no) CF_TOKEN="" ;;
            *) ;;
        esac
    fi

    if [ -z "$CF_TOKEN" ]; then
        echo ""
        echo "两种输入方式均可："
        echo "  1. 完整命令: cloudflared service install eyJhIjoi..."
        echo "  2. 纯 Token:  eyJhIjoi..."
        printf "%s" "Cloudflared Token / 命令: "; read RAW_CMD || {
            echo "[-] 未获取到输入"
            return 1
        }

        if echo "$RAW_CMD" | grep -q 'service[[:space:]]\+install'; then
            CF_TOKEN="$(echo "$RAW_CMD" | sed -E 's/.*service[[:space:]]+install[[:space:]]+//' | tr -d '[:space:]')"
        else
            CF_TOKEN="$(echo "$RAW_CMD" | tr -d '[:space:]')"
        fi

        if [ -z "$CF_TOKEN" ]; then
            echo "[-] 未能解析出 Tunnel Token"
            return 1
        fi

        # 持久化 Token
        mkdir -p "$(dirname "$TOKEN_FILE")"
        chmod 700 "$(dirname "$TOKEN_FILE")"
        echo "$CF_TOKEN" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        echo "[+] Token 已保存到 $TOKEN_FILE（重装无需再输入）"
    fi
    echo "[+] Token 解析成功（${#CF_TOKEN} 位）"

    # ---- 日志文件 ----
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    # ---- 部署服务 ----
    if [ "$INIT_TYPE" = "openrc" ]; then
        cat > "$OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel (Token mode)"

command="$CLOUDFLARED_BIN"
command_args="tunnel --edge-ip-version 4 run --token $CF_TOKEN"

supervisor="supervise-daemon"

output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() {
    need net
}
EOF
        chmod +x "$OPENRC_SERVICE"
        rc-update add cloudflared default >/dev/null 2>&1 || true
        rc-service cloudflared stop >/dev/null 2>&1 || true
        rc-service cloudflared start
        rc-service cloudflared status || true

    elif [ "$INIT_TYPE" = "systemd" ]; then
        cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Cloudflare Tunnel (Token mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

ExecStart=$CLOUDFLARED_BIN tunnel --edge-ip-version 4 run --token $CF_TOKEN

Restart=always
RestartSec=5

StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable cloudflared
        systemctl restart cloudflared
        systemctl status cloudflared --no-pager || true
    else
        echo "[-] 无法识别 init 系统，服务未创建（二进制已就绪）"
        return 1
    fi

    # ---- logrotate ----
    if command -v logrotate >/dev/null 2>&1; then
        cat > "$LOGROTATE_CONF" <<LOGR
$LOG_FILE {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGR
        echo "[+] logrotate 配置已写入 $LOGROTATE_CONF"
    fi

    echo ""
    echo "[+] 部署完成！服务运行中，日志: tail -f $LOG_FILE"

    # 部署成功后安装快捷命令 a（菜单入口）
    ensure_shortcut
}


# ============================================================
# 查看运行状态
# ============================================================

show_status() {
    echo ""
    echo "========== Cloudflared 运行状态 =========="

    if [ -x "$CLOUDFLARED_BIN" ]; then
        echo "[+] 二进制版本: $("$CLOUDFLARED_BIN" --version 2>/dev/null)"
    else
        echo "[-] 未安装 cloudflared（先选菜单 1 部署）"
        return 0
    fi

    detect_init
    echo ""
    case "$INIT_TYPE" in
        systemd)
            systemctl status cloudflared --no-pager 2>/dev/null || echo "[-] 服务未创建/未运行"
            ;;
        openrc)
            rc-service cloudflared status 2>/dev/null || echo "[-] 服务未创建/未运行"
            ;;
        *)
            echo "[!] 无法识别 init 系统"
            ;;
    esac

    echo ""
    echo "---------- 最近日志 ----------"
    if [ -f "$LOG_FILE" ]; then
        tail -n 10 "$LOG_FILE" 2>/dev/null
    else
        echo "(暂无日志)"
    fi
}


# ============================================================
# 重启服务
# ============================================================

restart_service() {
    need_root || return 1
    echo ""
    echo "========== 重启 Cloudflared =========="
    detect_init
    case "$INIT_TYPE" in
        systemd)
            systemctl restart cloudflared
            systemctl status cloudflared --no-pager || true
            ;;
        openrc)
            rc-service cloudflared restart
            rc-service cloudflared status || true
            ;;
        *)
            echo "[-] 无法识别 init 系统"
            return 1
            ;;
    esac
}


# ============================================================
# 查看日志
# ============================================================

show_log() {
    echo ""
    echo "========== Cloudflared 日志（最近 50 行）=========="
    if [ -f "$LOG_FILE" ]; then
        tail -n 50 "$LOG_FILE"
    else
        echo "(暂无日志)"
    fi
}


# ============================================================
# 卸载 Cloudflared（保留 Token 文件，重装免输入）
# ============================================================

uninstall_cloudflared() {
    need_root || return 1
    echo ""
    echo "========== 卸载 Cloudflared =========="

    printf "%s" "确认卸载 cloudflared 及服务/日志配置? [y/N] "; read ANS
    case "$ANS" in
        y|Y|yes|YES) ;;
        *) echo "已取消卸载"; return 0 ;;
    esac

    detect_init
    case "$INIT_TYPE" in
        openrc)
            echo "[+] 停止并移除 OpenRC 服务..."
            service cloudflared stop 2>/dev/null
            rc-update del cloudflared default 2>/dev/null
            rm -f "$OPENRC_SERVICE"
            ;;
        systemd)
            echo "[+] 停止并移除 systemd 服务..."
            systemctl stop cloudflared 2>/dev/null
            systemctl disable cloudflared 2>/dev/null
            rm -f "$SYSTEMD_SERVICE"
            systemctl daemon-reload
            ;;
        unknown)
            echo "[!] 未识别 init 系统，尝试清理常见服务文件..."
            rm -f "$OPENRC_SERVICE" "$SYSTEMD_SERVICE"
            command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null
            ;;
    esac

    # 残留进程兜底
    echo "[+] 清理残留进程..."
    pkill -f "$CLOUDFLARED_BIN" 2>/dev/null
    pkill -x cloudflared 2>/dev/null

    # 通用清理
    rm -f "$CLOUDFLARED_BIN"
    rm -f "${CLOUDFLARED_BIN}.tmp"
    rm -f "$LOG_FILE"
    rm -f "$LOGROTATE_CONF"

    # Token 一并清除，卸载即干净
    rm -f "$TOKEN_FILE"
    rmdir "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
    echo "[+] Token 文件已删除（/etc/cloudflared/token）"

    # 快捷命令 a 一并清除，卸载即干净
    rm -f /usr/local/bin/a
    echo "[+] 快捷命令 a 已删除（/usr/local/bin/a）"

    echo ""
    echo "[+] cloudflared 已彻底卸载，Cloudflare 面板 Tunnel 未受影响"
}


# ============================================================
# 更新脚本：验证远程脚本可用，并刷新快捷命令 a 的远程地址
update_script() {
    need_root || return 1
    echo ""
    echo "========== 更新脚本 / 快捷入口 =========="
    ensure_shortcut || return 1
    echo "[+] 更新完成。快捷命令 a 每次运行都会通过 curl -fsSL 获取远程最新版并进入交互菜单。"
}



# ============================================================
# 菜单
# ============================================================

# 获取运行状态：未安装 / 运行中(版本) / 已停止 / 未知
sb_status() {
    if [ ! -x "$CLOUDFLARED_BIN" ]; then
        printf "%b\n" "${_yellow}未安装${_plain}"
        return
    fi
    detect_init
    case "$INIT_TYPE" in
        systemd)
            if systemctl is-active --quiet cloudflared 2>/dev/null; then
                printf "%b\n" "${_green}运行中${_plain}（$("$CLOUDFLARED_BIN" --version 2>/dev/null | head -n 1)）"
            else
                printf "%b\n" "${_red}已停止${_plain}"
            fi
            ;;
        openrc)
            if rc-service cloudflared status 2>/dev/null | grep -q started; then
                printf "%b\n" "${_green}运行中${_plain}（$("$CLOUDFLARED_BIN" --version 2>/dev/null | head -n 1)）"
            else
                printf "%b\n" "${_red}已停止${_plain}"
            fi
            ;;
        *)
            printf "%b\n" "${_yellow}未知${_plain}"
            ;;
    esac
}

show_menu() {
    echo ""
    echo "============================================"
    echo "        Cloudflared 管理菜单 ${SCRIPT_VERSION}"
    echo "============================================"
    echo ""
    echo "  脚本版本：${SCRIPT_VERSION}"
    if [ -x "$CLOUDFLARED_BIN" ]; then
        echo "  Cloudflared 版本：$("$CLOUDFLARED_BIN" --version 2>/dev/null | head -1)"
    else
        echo "  Cloudflared 版本：未安装"
    fi
    echo "  Cloudflared 状态：$(sb_status)"
    echo ""
    echo "  1) 部署 / 更新 Cloudflared"
    echo "  2) 重启服务"
    echo "  3) 查看日志（最近 50 行）"
    echo "  4) 卸载 Cloudflared"
    echo "  5) 重新安装快捷命令 a"
    echo "  6) 更新快捷入口（远程更新快捷入口）"
    echo "  0) 退出"
    echo ""
}

main() {
    # 首次运行时，自动安装快捷命令 a；安装后继续进入交互菜单。
    # 已有快捷入口时不重复写入，避免每次启动都覆盖文件。
    if [ "$(id -u)" = "0" ] && [ ! -x /usr/local/bin/a ]; then
        ensure_shortcut || echo "[!] 快捷命令 a 安装失败，但仍可继续使用当前菜单"
    fi

    # 支持直接指定操作（关键词 或 数字菜单编号）: a install / a 1 / a 3 ...
    case "${1:-}" in
        install|deploy|1)   deploy; exit $? ;;
        status)             show_status; exit $? ;;
        restart|2)          restart_service; exit $? ;;
        log|3)              show_log; exit $? ;;
        uninstall|4)        uninstall_cloudflared; exit $? ;;
        5)                  ensure_shortcut; exit $? ;;
        update|6)           update_script; exit $? ;;
    esac

    while true; do
        show_menu
        printf "%s" "请选择 [0-6]: "; read CHOICE || CHOICE=""
        case "$CHOICE" in
            1) deploy ;;
            2) restart_service ;;
            3) show_log ;;
            4) uninstall_cloudflared ;;
            5) ensure_shortcut ;;
            6) update_script ;;
            0)
                echo "再见！之后输入 a 即可随时打开菜单"
                exit 0
                ;;
            *) echo "[!] 无效选项，请输入 0-6" ;;
        esac
        echo ""
        printf "%s" "按回车返回菜单..."; read _ || true
    done
}

main "$@"
