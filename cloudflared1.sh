#!/bin/bash
set -e

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
LOG_FILE="/var/log/cloudflared.log"

echo "=== Cloudflared Token Tunnel 自动部署 ==="

# 检测系统类型并安装依赖
if [ -f /etc/alpine-release ]; then
    echo "检测到 Alpine Linux"
    apk add --no-cache curl unzip
    INIT_TYPE="openrc"
elif [ -f /etc/debian_version ]; then
    echo "检测到 Debian/Ubuntu"
    apt update
    apt install -y curl unzip
    INIT_TYPE="systemd"
else
    echo "❌ 不支持的系统类型"
    exit 1
fi

# 交互式输入原始命令（自动提取 token）
read -rp "请直接粘贴 cloudflared service install 原始命令: " RAW_CMD

CF_TOKEN=$(echo "$RAW_CMD" | sed -E 's/.*service install[[:space:]]+//')

if [ -z "$CF_TOKEN" ] || [ "$CF_TOKEN" = "$RAW_CMD" ]; then
    echo "❌ 未能从命令中解析出 Tunnel Token"
    exit 1
fi


# 下载 cloudflared
if [ ! -x "$CLOUDFLARED_BIN" ]; then
    echo "正在下载 cloudflared..."
    if command -v wget >/dev/null 2>&1; then
        wget -O "$CLOUDFLARED_BIN" \
            https://gitv6.4106666.xyz/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    else
        curl -L -o "$CLOUDFLARED_BIN" \
            https://gitv6.4106666.xyz/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    fi
    chmod +x "$CLOUDFLARED_BIN"
else
    echo "cloudflared 已存在，跳过下载"
fi

# 部署启动脚本 / 服务
if [ "$INIT_TYPE" = "openrc" ]; then
    echo "部署 OpenRC 服务..."
    INIT_SCRIPT="/etc/init.d/cloudflared"
    cat > "$INIT_SCRIPT" <<EOF
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel (Token mode)"

command="$CLOUDFLARED_BIN"
command_args="tunnel --edge-ip-version auto run --token $CF_TOKEN"
command_background=true
command_redirect="$LOG_FILE"
pidfile="/run/cloudflared.pid"

depend() {
  need net
}
EOF

    chmod +x "$INIT_SCRIPT"
    rc-update add cloudflared default >/dev/null 2>&1 || true
    service cloudflared stop >/dev/null 2>&1 || true
    service cloudflared start
    echo "=============================="
    service cloudflared status || true

elif [ "$INIT_TYPE" = "systemd" ]; then
    echo "部署 systemd 服务..."
    SERVICE_FILE="/etc/systemd/system/cloudflared.service"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel (Token mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CLOUDFLARED_BIN tunnel --edge-ip-version auto run --token $CF_TOKEN
Restart=always
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl restart cloudflared
    echo "=============================="
    systemctl status cloudflared --no-pager || true
fi

echo "cloudflared Token Tunnel 已部署完成"
echo "日志文件: $LOG_FILE"
echo "=============================="
