#!/bin/sh

# ============================================================
# Cloudflared Token Tunnel 管理菜单（v8.2）
#
# 基于 v3 改造，新增：
#   - 交互式菜单：部署/状态/日志/重启/卸载 一体化管理
#   - 快捷命令 a：首次运行自动安装，之后输入 a 即可打开菜单；
#     使用 curl | sh 执行远程脚本，交互输入从 /dev/tty 读取
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

SCRIPT_VERSION="8.2"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
LOG_FILE="/var/log/cloudflared.log"
TOKEN_FILE="/etc/cloudflared/token"
EDGE_IP_VERSION_FILE="/etc/cloudflared/edge_ip_version"
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

# 自身脚本镜像地址列表：默认 GitHub raw，失败时回退到 jsDelivr CDN
# 如果你 fork 了本脚本，请同步修改下面两个地址。
SCRIPT_MIRROR_DEFAULT="https://raw.githubusercontent.com/jhbook/cf-argo/refs/heads/main/cloudflared.sh"
SCRIPT_MIRROR_BACKUP1="https://cdn.jsdelivr.net/gh/jhbook/cf-argo@main/cloudflared.sh"


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

# 安装快捷命令 a：快捷命令始终通过 curl | sh 远程启动；交互输入从 /dev/tty 读取
ensure_shortcut() {
    need_root || return 1

    # 按默认 raw → jsDelivr 的顺序验证自身脚本镜像。
    SCRIPT_URL=""
    for MIRROR_URL in "$SCRIPT_MIRROR_DEFAULT" "$SCRIPT_MIRROR_BACKUP1"; do
        echo "[+] 验证脚本镜像：$MIRROR_URL"
        if curl -fsSL --connect-timeout 15 --max-time 60 "$MIRROR_URL" | grep -q "Cloudflared Token Tunnel 管理菜单"; then
            SCRIPT_URL="$MIRROR_URL"
            break
        fi
        echo "[!] 镜像不可用，尝试下一个地址..."
    done

    if [ -z "$SCRIPT_URL" ]; then
        echo "[-] 所有自身脚本镜像均无法验证"
        return 1
    fi

    cat > /usr/local/bin/a <<EOF
#!/bin/sh
SCRIPT_MIRROR_DEFAULT='$SCRIPT_MIRROR_DEFAULT'
SCRIPT_MIRROR_BACKUP1='$SCRIPT_MIRROR_BACKUP1'
SCRIPT_URL=""
for MIRROR_URL in "\$SCRIPT_MIRROR_DEFAULT" "\$SCRIPT_MIRROR_BACKUP1"; do
    if curl -fsSL --connect-timeout 15 --max-time 60 "\$MIRROR_URL" | grep -q "Cloudflared Token Tunnel 管理菜单"; then
        SCRIPT_URL="\$MIRROR_URL"
        break
    fi
done
if [ -z "\$SCRIPT_URL" ]; then
    echo "[-] 所有脚本镜像均不可用"
    exit 1
fi
exec curl -fsSL "\$SCRIPT_URL" | sh -s -- "\$@"
EOF
    chmod 755 /usr/local/bin/a
    echo "[+] 快捷命令 a 已安装：运行 a 即可打开远程管理菜单"
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
        printf "%s" "是否重新下载最新版? [y/N] "; read ANS </dev/tty
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
        printf "%s" "使用已保存 Token 继续? [Y/n] "; read ANS </dev/tty
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
        printf "%s" "Cloudflared Token / 命令: "; read RAW_CMD </dev/tty || {
            echo "[-] 未获取到输入"
            return 1
        }

        # 兼容面板复制命令、tunnel run --token 命令，以及纯 Token。
        # 优先提取 --token 参数，再处理 service install，避免把整条命令误存为 Token。
        if echo "$RAW_CMD" | grep -Eq -- '(^|[[:space:]])--token([=[:space:]])'; then
            CF_TOKEN="$(printf '%s\n' "$RAW_CMD" | sed -E 's/.*--token[=[:space:]]+([^[:space:]]+).*/\1/' | tr -d '"'"'"'')"
        elif echo "$RAW_CMD" | grep -Eq 'service[[:space:]]+install'; then
            CF_TOKEN="$(printf '%s\n' "$RAW_CMD" | sed -E 's/.*service[[:space:]]+install[[:space:]]+//' | awk '{print $1}' | tr -d '"'"'"'')"
        else
            CF_TOKEN="$(printf '%s' "$RAW_CMD" | tr -d '[:space:]' | tr -d '"'"'"'')"
        fi

        if [ -z "$CF_TOKEN" ] || echo "$CF_TOKEN" | grep -Eq '[[:space:]]|cloudflared'; then
            echo "[-] 未能解析出有效的 Tunnel Token，请粘贴完整安装命令或纯 Token"
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

    # ---- 选择 Cloudflare Edge 连接 IP 版本 ----
    EDGE_IP_VERSION="4"
    if [ -s "$EDGE_IP_VERSION_FILE" ]; then
        SAVED_EDGE_IP_VERSION="$(cat "$EDGE_IP_VERSION_FILE" 2>/dev/null)"
        case "$SAVED_EDGE_IP_VERSION" in 4|6|auto) EDGE_IP_VERSION="$SAVED_EDGE_IP_VERSION" ;; esac
    fi
    case "$EDGE_IP_VERSION" in
        4) EDGE_DEFAULT_LABEL="IPv4" ;;
        6) EDGE_DEFAULT_LABEL="IPv6" ;;
        auto) EDGE_DEFAULT_LABEL="IPv4/IPv6 自动选择" ;;
    esac
    echo ""
    echo "选择 Cloudflared 连接 Cloudflare Edge 的 IP 版本："
    echo "  1) IPv4（仅 IPv4）"
    echo "  2) IPv6（仅 IPv6）"
    echo "  3) IPv4/IPv6（自动选择并在双栈环境中回退）"
    printf "当前默认：%s；请输入 [1-3，直接回车沿用默认]: " "$EDGE_DEFAULT_LABEL"
    read EDGE_CHOICE </dev/tty || EDGE_CHOICE=""
    case "$EDGE_CHOICE" in
        1) EDGE_IP_VERSION="4" ;;
        2) EDGE_IP_VERSION="6" ;;
        3) EDGE_IP_VERSION="auto" ;;
        "") ;;
        *) echo "[-] 无效选择，保留默认：$EDGE_DEFAULT_LABEL" ;;
    esac
    mkdir -p "$(dirname "$EDGE_IP_VERSION_FILE")"
    chmod 700 "$(dirname "$EDGE_IP_VERSION_FILE")"
    printf '%s\n' "$EDGE_IP_VERSION" > "$EDGE_IP_VERSION_FILE"
    chmod 600 "$EDGE_IP_VERSION_FILE"
    case "$EDGE_IP_VERSION" in
        4) echo "[+] 已选择 IPv4 连接模式" ;;
        6) echo "[+] 已选择 IPv6 连接模式" ;;
        auto) echo "[+] 已选择 IPv4/IPv6 自动模式" ;;
    esac

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
command_args="tunnel --edge-ip-version $EDGE_IP_VERSION run --token $CF_TOKEN"

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

ExecStart=$CLOUDFLARED_BIN tunnel --edge-ip-version $EDGE_IP_VERSION run --token $CF_TOKEN

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

    printf "%s" "确认卸载 cloudflared 及服务/日志配置? [y/N] "; read ANS </dev/tty
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
    rm -f "$TOKEN_FILE" "$EDGE_IP_VERSION_FILE"
    rmdir "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
    echo "[+] Token 与 IP 版本配置已删除（/etc/cloudflared/）"

    # 快捷命令 a 一并清除，卸载即干净
    rm -f /usr/local/bin/a /usr/local/bin/cloudflared.sh
    echo "[+] 管理脚本及快捷入口已删除（/usr/local/bin/a、/usr/local/bin/cloudflared.sh，如存在）"

    echo ""
    echo "[+] Cloudflared、管理脚本及快捷入口已彻底卸载，Cloudflare 面板 Tunnel 未受影响"
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
    echo "  1) 安装 / 更新 Cloudflared 二进制（并配置/启动 Tunnel）"
    echo "  2) 重启服务"
    echo "  3) 查看日志（最近 50 行）"
    echo "  4) 卸载 Cloudflared"
    echo "  5) 更新脚本 / 快捷入口"
    echo "  0) 退出"
    echo ""
}

main() {
    # 首次运行时自动安装快捷命令 a；安装后继续进入交互菜单。
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
        update|5)           update_script; exit $? ;;
    esac

    while true; do
        show_menu
        printf "%s" "请选择 [0-5]: "; read CHOICE </dev/tty || CHOICE=""
        case "$CHOICE" in
            1) deploy ;;
            2) restart_service ;;
            3) show_log ;;
            4) uninstall_cloudflared ;;
            5) update_script ;;
            0)
                echo "再见！之后输入 a 即可随时打开菜单"
                exit 0
                ;;
            *) echo "[!] 无效选项，请输入 0-5" ;;
        esac
        echo ""
        printf "%s" "按回车返回菜单..."; read _ </dev/tty || true
    done
}

main "$@"
