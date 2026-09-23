#!/bin/bash
set -e

# ============================================================
# Cloudflared Token Tunnel 通用自动部署脚本（改进版 v3）
#
# 支持系统：
#   - Alpine Linux / OpenRC
#   - Debian / Ubuntu / systemd
#
# 支持 CPU：
#   - x86_64 / amd64
#   - aarch64 / arm64
#   - armv7l（armhf）
#   - i386 / i686
#
# v3 变更说明：
#   1. 采用 latest 最新版本下载，不再硬编码 SHA256 哈希
#      （官方持续发版，固定哈希必然失效；且 GitHub API 匿名
#        调用有 rate limit，动态拉取哈希在国内服务器也不可靠）
#   2. 质量兜底改为三层：
#      a. file 检查文件类型，拦截代理返回的 HTML 错误页
#      b. 下载后打印实际 SHA256，方便与官方 release 页核对
#      c. 最终运行 cloudflared --version 验证可执行性
#   3. 修复 armv7l 架构误匹配 bug（原脚本匹配 arm 老版本，
#      现正确匹配 armhf）
#   4. 多下载源自动降级（主代理 → 官方直连 → 备用代理）
#   5. Token 解析兼容两种输入（完整命令 / 纯 Token）
#   6. 新增 logrotate 日志轮转配置
#
# 如需严格核对哈希，官方地址：
#   https://github.com/cloudflare/cloudflared/releases
#   展开对应版本的 Assets 即可看到各文件 SHA256
# ============================================================


# ============================================================
# 基础配置
# ============================================================

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
LOG_FILE="/var/log/cloudflared.log"

# GitHub 官方 Release 基础地址（latest 自动跟随最新版）
GITHUB_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"

# 主代理（国内加速）
GITHUB_PROXY="https://git.jhbook.eu.org/"
# 备用代理
GITHUB_PROXY_BACKUP="https://ghproxy.net/"


echo "============================================================"
echo "        Cloudflared Token Tunnel 自动部署（改进版 v3）"
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

    echo "[-] 不支持的系统类型（仅支持 Alpine / Debian / Ubuntu）"
    exit 1

fi

echo "[+] Init 系统: $INIT_TYPE"


# ============================================================
# 2. 检测 CPU 架构（决定下载哪个文件）
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

    # ARM 32位（armv7 统一使用 armhf 版本，修复原脚本误匹配 arm 老版本）
    armv7l|armhf)
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
# 3. 生成下载地址（多源，按序自动降级）
# ============================================================

GITHUB_URL="${GITHUB_BASE}/${CF_FILE}"

DOWNLOAD_SOURCES=(
    "${GITHUB_PROXY}${GITHUB_URL}"       # 主代理
    "${GITHUB_URL}"                       # 官方直连
    "${GITHUB_PROXY_BACKUP}${GITHUB_URL}" # 备用代理
)

echo ""
for i in "${!DOWNLOAD_SOURCES[@]}"; do
    echo "[+] 下载源 $((i+1)): ${DOWNLOAD_SOURCES[$i]}"
done


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
# 5. 下载函数（优先 curl，降级 wget）
# ============================================================

download_one() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --retry-delay 2 \
            --connect-timeout 15 --max-time 300 \
            -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=2 --timeout=15 -O "$out" "$url"
    else
        return 1
    fi
}


# ============================================================
# 6. 下载 Cloudflared（多源自动降级）
# ============================================================

if [ "$NEED_DOWNLOAD" = "1" ]; then

    echo ""
    echo "============================================================"
    echo "下载 Cloudflared"
    echo "============================================================"

    TEMP_FILE="${CLOUDFLARED_BIN}.tmp"

    rm -f "$TEMP_FILE"

    DOWNLOAD_OK=0

    for src in "${DOWNLOAD_SOURCES[@]}"; do

        echo ""
        echo "[+] 尝试下载源: $src"

        if download_one "$src" "$TEMP_FILE"; then

            echo "[+] 下载成功"
            DOWNLOAD_OK=1
            break

        else

            echo "[!] 下载失败，切换下一个下载源..."

        fi

    done

    if [ "$DOWNLOAD_OK" != "1" ]; then

        echo ""
        echo "[-] 所有下载源均失败"
        echo "[!] 网络排查建议："
        echo "    1. 检查服务器能否访问外网: curl -I https://www.google.com"
        echo "    2. 检查 DNS 是否正常: nslookup github.com"
        echo "    3. 如代理域名已失效，修改脚本顶部 GITHUB_PROXY 变量"
        echo "    4. 也可手动下载后重试: curl -L -o $CLOUDFLARED_BIN $GITHUB_URL"

        exit 1

    fi

    # 检查文件是否为空
    if [ ! -s "$TEMP_FILE" ]; then

        echo "[-] 下载文件为空"

        rm -f "$TEMP_FILE"

        exit 1

    fi


    # --------------------------------------------------------
    # 检查文件类型（防止代理返回 HTML 错误页）
    # --------------------------------------------------------

    FILE_TYPE="$(file "$TEMP_FILE" 2>/dev/null || true)"

    echo ""
    echo "[+] 下载文件类型:"
    echo "$FILE_TYPE"

    if echo "$FILE_TYPE" | grep -qiE "HTML|text"; then

        echo ""
        echo "[-] 下载到的不是 Cloudflared 二进制文件"
        echo "[!] 下载源可能返回了错误页面"

        rm -f "$TEMP_FILE"

        exit 1

    fi


    # --------------------------------------------------------
    # 打印实际 SHA256（供与官方 release 页面核对）
    # --------------------------------------------------------

    echo ""
    echo "[+] 文件 SHA256（可对照官方 Release 页核对）:"
    sha256sum "$TEMP_FILE"


    # --------------------------------------------------------
    # 安装 Cloudflared
    # --------------------------------------------------------

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
# 7. 最终验证（可执行性验证，确保二进制可用）
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
# 8. 输入 Tunnel Token
# ============================================================

echo ""
echo "============================================================"
echo "请输入 Cloudflare Tunnel Token"
echo "============================================================"

echo ""
echo "两种输入方式均可："
echo "  1. 完整命令: cloudflared service install eyJhIjoi..."
echo "  2. 纯 Token:  eyJhIjoi..."
echo ""

read -rp "Cloudflared Token / 命令: " RAW_CMD || {
    echo "[-] 未获取到输入（非交互环境下无法输入）"
    exit 1
}


# ============================================================
# 9. 自动提取 Token（兼容两种输入）
# ============================================================

if echo "$RAW_CMD" | grep -q 'service[[:space:]]\+install'; then

    CF_TOKEN="$(echo "$RAW_CMD" | sed -E 's/.*service[[:space:]]+install[[:space:]]+//')"

else

    CF_TOKEN="$(echo "$RAW_CMD" | tr -d '[:space:]')"

fi

if [ -z "$CF_TOKEN" ]; then

    echo ""
    echo "[-] 未能解析出 Tunnel Token"
    echo "[!] 正确格式: cloudflared service install <TOKEN>"
    echo "     或直接粘贴 <TOKEN>"

    exit 1

fi

echo "[+] Token 解析成功 (长度: ${#CF_TOKEN})"


# ============================================================
# 10. 创建日志文件
# ============================================================

touch "$LOG_FILE"
chmod 644 "$LOG_FILE"


# ============================================================
# 11. Alpine / OpenRC
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

    # 加入开机启动（已存在不报错）
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

    # logrotate（Alpine 若已安装则配置）
    if command -v logrotate >/dev/null 2>&1; then

        cat > /etc/logrotate.d/cloudflared <<LOGR
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

        echo "[+] logrotate 配置已写入 /etc/logrotate.d/cloudflared"

    fi


# ============================================================
# 12. Debian / Ubuntu / systemd
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

    # logrotate（Debian/Ubuntu 默认自带 logrotate）
    if command -v logrotate >/dev/null 2>&1; then

        cat > /etc/logrotate.d/cloudflared <<LOGR
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

        echo "[+] logrotate 配置已写入 /etc/logrotate.d/cloudflared"

    fi

fi


# ============================================================
# 13. 最终结果
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
