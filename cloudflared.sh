#!/bin/bash
set -e

# ============================================================
# Cloudflared Token Tunnel 通用自动部署脚本
#
# 支持：
#   - Alpine Linux / OpenRC
#   - Debian / Ubuntu / systemd
#
# CPU：
#   - x86_64 / amd64
#   - aarch64 / arm64
#   - armv7
#   - armhf
#   - i386 / i686
#
# 下载：
#   GitHub 官方 Release
#   ↓
#   GitHub 代理
#   https://gitv6.4106666.xyz/
# ============================================================


# ============================================================
# 基础配置
# ============================================================

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
LOG_FILE="/var/log/cloudflared.log"

# GitHub 官方 Release
GITHUB_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"

# GitHub 代理
GITHUB_PROXY="https://git.jhbook.eu.org/"


echo "============================================================"
echo "        Cloudflared Token Tunnel 自动部署"
echo "============================================================"


# ============================================================
# 1. 检测系统
# ============================================================

if [ -f /etc/alpine-release ]; then

    echo "[+] 检测到 Alpine Linux"

    apk add --no-cache curl file >/dev/null

    INIT_TYPE="openrc"

elif [ -f /etc/debian_version ]; then

    echo "[+] 检测到 Debian / Ubuntu"

    apt-get update -y
    apt-get install -y curl file

    INIT_TYPE="systemd"

else

    echo "[-] 不支持的系统类型"
    exit 1

fi

echo "[+] Init 系统: $INIT_TYPE"


# ============================================================
# 2. 检测 CPU 架构
# ============================================================

ARCH="$(uname -m)"

case "$ARCH" in

    # x86_64
    x86_64|amd64)
        CF_FILE="cloudflared-linux-amd64"
        ;;

    # ARM64
    aarch64|arm64)
        CF_FILE="cloudflared-linux-arm64"
        ;;

    # ARM 32位
    armv7l|armv7)
        CF_FILE="cloudflared-linux-arm"
        ;;

    # ARMHF
    armhf)
        CF_FILE="cloudflared-linux-armhf"
        ;;

    # x86 32位
    i386|i686)
        CF_FILE="cloudflared-linux-386"
        ;;

    *)
        echo "[-] 不支持的 CPU 架构: $ARCH"
        exit 1
        ;;

esac


echo "[+] CPU 架构: $ARCH"
echo "[+] Cloudflared 文件: $CF_FILE"


# ============================================================
# 3. 生成下载地址
# ============================================================

# 官方 GitHub 地址
GITHUB_URL="${GITHUB_BASE}/${CF_FILE}"

# GitHub 代理地址
DOWNLOAD_URL="${GITHUB_PROXY}${GITHUB_URL}"


echo ""
echo "[+] GitHub 官方地址:"
echo "$GITHUB_URL"

echo ""
echo "[+] GitHub 代理地址:"
echo "$DOWNLOAD_URL"


# ============================================================
# 4. 检查已有 Cloudflared
# ============================================================

NEED_DOWNLOAD=0

if [ -x "$CLOUDFLARED_BIN" ]; then

    echo ""
    echo "[+] 检测到已有 Cloudflared"

    if "$CLOUDFLARED_BIN" --version >/dev/null 2>&1; then

        echo "[+] 已有 Cloudflared 可以正常运行"

        "$CLOUDFLARED_BIN" --version

    else

        echo "[!] 已有 Cloudflared 无法正常运行"
        echo "[!] 可能是 CPU 架构不匹配或文件损坏"

        NEED_DOWNLOAD=1

    fi

else

    echo "[!] 未检测到 Cloudflared"

    NEED_DOWNLOAD=1

fi


# ============================================================
# 5. 下载 Cloudflared
# ============================================================

if [ "$NEED_DOWNLOAD" = "1" ]; then

    echo ""
    echo "============================================================"
    echo "下载 Cloudflared"
    echo "============================================================"

    TEMP_FILE="${CLOUDFLARED_BIN}.tmp"

    rm -f "$TEMP_FILE"


    # --------------------------------------------------------
    # 使用 curl
    # --------------------------------------------------------

    if command -v curl >/dev/null 2>&1; then

        echo "[+] 使用 curl 下载"

        curl \
            -fL \
            --retry 3 \
            --retry-delay 2 \
            --connect-timeout 15 \
            --max-time 300 \
            -o "$TEMP_FILE" \
            "$DOWNLOAD_URL"


    # --------------------------------------------------------
    # 使用 wget
    # --------------------------------------------------------

    elif command -v wget >/dev/null 2>&1; then

        echo "[+] 使用 wget 下载"

        wget \
            --tries=3 \
            --timeout=15 \
            -O "$TEMP_FILE" \
            "$DOWNLOAD_URL"


    else

        echo "[-] 系统没有 curl 或 wget"
        exit 1

    fi


    # ========================================================
    # 6. 检查下载结果
    # ========================================================

    if [ ! -s "$TEMP_FILE" ]; then

        echo "[-] Cloudflared 下载失败"

        rm -f "$TEMP_FILE"

        exit 1

    fi


    # --------------------------------------------------------
    # 检查文件类型
    # --------------------------------------------------------

    FILE_TYPE="$(file "$TEMP_FILE" 2>/dev/null || true)"

    echo ""
    echo "[+] 下载文件类型:"
    echo "$FILE_TYPE"


    # 如果代理返回 HTML / 文本错误页面
    if echo "$FILE_TYPE" | grep -qiE "HTML|text"; then

        echo ""
        echo "[-] 下载到的不是 Cloudflared 二进制文件"
        echo "[!] GitHub 代理可能返回了错误页面"

        rm -f "$TEMP_FILE"

        exit 1

    fi


    # ========================================================
    # 7. 安装 Cloudflared
    # ========================================================

    chmod +x "$TEMP_FILE"

    mv -f "$TEMP_FILE" "$CLOUDFLARED_BIN"

    chmod +x "$CLOUDFLARED_BIN"

    echo ""
    echo "[+] Cloudflared 安装完成"


else

    echo ""
    echo "[+] 已有 Cloudflared，跳过下载"

fi


# ============================================================
# 8. 最终验证
# ============================================================

echo ""
echo "============================================================"
echo "验证 Cloudflared"
echo "============================================================"


if ! "$CLOUDFLARED_BIN" --version >/dev/null 2>&1; then

    echo "[-] Cloudflared 无法正常执行"
    echo "[!] 当前 CPU 架构: $ARCH"
    echo "[!] 应使用文件: $CF_FILE"

    exit 1

fi


"$CLOUDFLARED_BIN" --version


# ============================================================
# 9. 输入 Tunnel Token
# ============================================================

echo ""
echo "============================================================"
echo "请输入 Cloudflare Tunnel Token"
echo "============================================================"

echo ""
echo "可以直接粘贴 Cloudflare 提供的完整命令："
echo ""
echo "cloudflared service install eyJhIjoi..."
echo ""

read -rp "Cloudflared Token 命令: " RAW_CMD


# ============================================================
# 10. 自动提取 Token
# ============================================================

CF_TOKEN="$(echo "$RAW_CMD" | sed -E 's/.*service[[:space:]]+install[[:space:]]+//')"


if [ -z "$CF_TOKEN" ] || [ "$CF_TOKEN" = "$RAW_CMD" ]; then

    echo ""
    echo "[-] 未能从命令中解析出 Tunnel Token"

    echo ""
    echo "正确格式类似："
    echo ""
    echo "cloudflared service install <TOKEN>"
    echo ""

    exit 1

fi


echo "[+] Token 解析成功"


# ============================================================
# 11. 创建日志文件
# ============================================================

touch "$LOG_FILE"
chmod 644 "$LOG_FILE"


# ============================================================
# 12. Alpine / OpenRC
# ============================================================

if [ "$INIT_TYPE" = "openrc" ]; then

    echo ""
    echo "============================================================"
    echo "部署 OpenRC 服务"
    echo "============================================================"

    INIT_SCRIPT="/etc/init.d/cloudflared"


    cat > "$INIT_SCRIPT" <<EOF
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


    chmod +x "$INIT_SCRIPT"


    # 加入开机启动
    rc-update add cloudflared default >/dev/null 2>&1 || true


    # 停止旧服务
    rc-service cloudflared stop >/dev/null 2>&1 || true


    # 启动服务
    rc-service cloudflared start


    echo ""
    echo "============================================================"
    echo "OpenRC 服务状态"
    echo "============================================================"

    rc-service cloudflared status || true


# ============================================================
# 13. Debian / Ubuntu / systemd
# ============================================================

elif [ "$INIT_TYPE" = "systemd" ]; then

    echo ""
    echo "============================================================"
    echo "部署 systemd 服务"
    echo "============================================================"

    SERVICE_FILE="/etc/systemd/system/cloudflared.service"


    cat > "$SERVICE_FILE" <<EOF
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


    # 重新读取 systemd 配置
    systemctl daemon-reload


    # 设置开机启动
    systemctl enable cloudflared


    # 重启服务
    systemctl restart cloudflared


    echo ""
    echo "============================================================"
    echo "systemd 服务状态"
    echo "============================================================"

    systemctl status cloudflared --no-pager || true

fi


# ============================================================
# 14. 最终结果
# ============================================================

echo ""
echo "============================================================"
echo "Cloudflared Token Tunnel 部署完成"
echo "============================================================"

echo "系统        : $INIT_TYPE"
echo "CPU         : $ARCH"
echo "Cloudflared : $CLOUDFLARED_BIN"
echo "日志        : $LOG_FILE"

echo ""


if [ "$INIT_TYPE" = "openrc" ]; then

    echo "服务管理:"
    echo "  启动: rc-service cloudflared start"
    echo "  停止: rc-service cloudflared stop"
    echo "  重启: rc-service cloudflared restart"
    echo "  状态: rc-service cloudflared status"

elif [ "$INIT_TYPE" = "systemd" ]; then

    echo "服务管理:"
    echo "  启动: systemctl start cloudflared"
    echo "  停止: systemctl stop cloudflared"
    echo "  重启: systemctl restart cloudflared"
    echo "  状态: systemctl status cloudflared"

fi


echo ""
echo "日志:"
echo "  tail -f $LOG_FILE"

echo ""
echo "============================================================"
