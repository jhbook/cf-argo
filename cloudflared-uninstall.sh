#!/bin/sh

set +e

BIN_PATH="/usr/local/bin/cloudflared"
LOG_FILE="/var/log/cloudflared.log"
OPENRC_SERVICE="/etc/init.d/cloudflared"
SYSTEMD_SERVICE="/etc/systemd/system/cloudflared.service"

echo "=== Cloudflared 卸载脚本（Alpine / Debian 通用）==="

# 判断 init 系统
if [ -d /run/openrc ]; then
  INIT="openrc"
elif command -v systemctl >/dev/null 2>&1; then
  INIT="systemd"
else
  INIT="unknown"
fi

echo "检测到 init 系统: $INIT"

# ---- Alpine / OpenRC ----
if [ "$INIT" = "openrc" ]; then
  echo "停止 cloudflared（OpenRC）..."
  service cloudflared stop 2>/dev/null

  echo "移除开机自启（OpenRC）..."
  rc-update del cloudflared default 2>/dev/null

  if [ -f "$OPENRC_SERVICE" ]; then
    echo "删除 OpenRC 服务文件..."
    rm -f "$OPENRC_SERVICE"
  fi
fi

# ---- Debian / systemd ----
if [ "$INIT" = "systemd" ]; then
  echo "停止 cloudflared（systemd）..."
  systemctl stop cloudflared 2>/dev/null

  echo "禁用 cloudflared 开机自启..."
  systemctl disable cloudflared 2>/dev/null

  if [ -f "$SYSTEMD_SERVICE" ]; then
    echo "删除 systemd 服务文件..."
    rm -f "$SYSTEMD_SERVICE"
  fi

  systemctl daemon-reexec
  systemctl daemon-reload
fi

# ---- 通用清理 ----
if [ -f "$BIN_PATH" ]; then
  echo "删除 cloudflared 二进制..."
  rm -f "$BIN_PATH"
fi

if [ -f "$LOG_FILE" ]; then
  echo "删除 cloudflared 日志..."
  rm -f "$LOG_FILE"
fi

echo "=============================="
echo "cloudflared 已彻底卸载完成"
echo "Cloudflare 面板 Tunnel 未受影响"
echo "=============================="
