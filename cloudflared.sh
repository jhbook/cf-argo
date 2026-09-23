#!/bin/bash

# ============================================================
# Cloudflared Token Tunnel 管理菜单（v4）
#
# 基于 v3 改造，新增：
#   - 交互式菜单：部署/状态/日志/重启/卸载 一体化管理
#   - 快捷命令 a：首次运行自动安装，之后输入 a 即可打开菜单
#   - Token 持久化：保存到 /etc/cloudflared/token，重新部署时自动复用；
#     卸载时一并清除，保证卸载干净
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

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
LOG_FILE="/var/log/cloudflared.log"
TOKEN_FILE="/etc/cloudflared/token"
OPENRC_SERVICE="/etc/init.d/cloudflared"
SYSTEMD_SERVICE="/etc/systemd/system/cloudflared.service"
LOGROTATE_CONF="/etc/logrotate.d/cloudflared"

GITHUB_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"
GITHUB_PROXY="https://git.jhbook.eu.org/"
GITHUB_PROXY_BACKUP="https://ghproxy.net/"


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
    local a
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

# 确保快捷命令 a 存在
ensure_shortcut() {
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"

    # 进程替换/管道执行时 $0 是伪文件（如 /root/pipe:[...]），无法复制
    if [ ! -f "$self" ]; then
        echo ""
        echo "[!] 当前通过「进程替换/管道」方式运行，无法自动安装快捷命令 a"
        echo "    请先把脚本下载到本地再运行一次："
        echo ""
        echo "    curl -sL <脚本URL> -o /usr/local/bin/a && chmod +x /usr/local/bin/a"
        echo ""
        echo "    安装后直接输入 a 即可打开本菜单（无需重新部署）"
        return 0
    fi

    if [ "$self" != "/usr/local/bin/a" ]; then
        if cp -f "$self" /usr/local/bin/a 2>/dev/null; then
            chmod +x /usr/local/bin/a
            echo "[+] 快捷命令已安装：以后直接输入 a 即可打开本菜单"
        else
            echo "[!] 复制到 /usr/local/bin/a 失败，请手动执行："
            echo "    sudo cp -f $self /usr/local/bin/a && sudo chmod +x /usr/local/bin/a"
        fi
    fi
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
        read -rp "是否重新下载最新版? [y/N] " ANS
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
        DOWNLOAD_SOURCES=(
            "${GITHUB_PROXY}${GITHUB_URL}"
            "${GITHUB_URL}"
            "${GITHUB_PROXY_BACKUP}${GITHUB_URL}"
        )

        TEMP_FILE="${CLOUDFLARED_BIN}.tmp"
        rm -f "$TEMP_FILE"

        DOWNLOAD_OK=0
        for src in "${DOWNLOAD_SOURCES[@]}"; do
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
        read -rp "使用已保存 Token 继续? [Y/n] " ANS
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
        read -rp "Cloudflared Token / 命令: " RAW_CMD || {
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

    read -rp "确认卸载 cloudflared 及服务/日志配置? [y/N] " ANS
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

    echo ""
    echo "[+] cloudflared 已彻底卸载，Cloudflare 面板 Tunnel 未受影响"
}


# ============================================================
# 菜单
# ============================================================

show_menu() {
    echo ""
    echo "============================================"
    echo "        Cloudflared 管理菜单 v4"
    echo "============================================"
    echo ""
    echo "  1) 部署 / 更新 Cloudflared"
    echo "  2) 查看运行状态"
    echo "  3) 重启服务"
    echo "  4) 查看日志（最近 50 行）"
    echo "  5) 卸载 Cloudflared"
    echo "  6) 重新安装快捷命令 a"
    echo "  0) 退出"
    echo ""
}

main() {
    # 支持直接指定操作: a install / a status / a uninstall
    case "${1:-}" in
        install|deploy) deploy; exit $? ;;
        status)         show_status; exit $? ;;
        restart)        restart_service; exit $? ;;
        log)            show_log; exit $? ;;
        uninstall)      uninstall_cloudflared; exit $? ;;
    esac

    ensure_shortcut

    while true; do
        show_menu
        read -rp "请选择 [0-6]: " CHOICE || CHOICE=""
        case "$CHOICE" in
            1) deploy ;;
            2) show_status ;;
            3) restart_service ;;
            4) show_log ;;
            5) uninstall_cloudflared ;;
            6) ensure_shortcut ;;
            0)
                echo "再见！之后输入 a 即可随时打开菜单"
                exit 0
                ;;
            *) echo "[!] 无效选项，请输入 0-6" ;;
        esac
        echo ""
        read -rp "按回车返回菜单..." _ || true
    done
}

main "$@"
