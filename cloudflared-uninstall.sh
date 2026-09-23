#!/bin/sh

# ============================================================
# Cloudflared 卸载脚本（改进版）
# Alpine / OpenRC + Debian / systemd 通用
#
# 改进点：
#   1. 增加交互确认（非交互环境需 UNINSTALL_FORCE=1）
#   2. 删除 logrotate 配置（安装脚本会写入 /etc/logrotate.d/）
#   3. 删除下载残留 *.tmp
#   4. 兜底清理残留进程（stop 失败 / supervise-daemon 异常场景）
#   5. unknown init 系统时也尝试清理两个服务文件
#   6. 去掉多余的 systemctl daemon-reexec，daemon-reload 移到删文件后
# ============================================================

set +e

BIN_PATH="/usr/local/bin/cloudflared"
LOG_FILE="/var/log/cloudflared.log"
OPENRC_SERVICE="/etc/init.d/cloudflared"
SYSTEMD_SERVICE="/etc/systemd/system/cloudflared.service"
LOGROTATE_CONF="/etc/logrotate.d/cloudflared"

echo "=== Cloudflared 卸载脚本（Alpine / Debian 通用）==="

# ---- 交互确认（非交互环境用 UNINSTALL_FORCE=1 跳过） ----
if [ "${UNINSTALL_FORCE:-0}" != "1" ]; then
    printf "确认卸载 cloudflared 及其服务/日志配置？[y/N] "
    read -r CONFIRM || CONFIRM="n"
    case "$CONFIRM" in
        y|Y|yes|YES) ;;
        *) echo "已取消卸载"; exit 0 ;;
    esac
fi

# ---- 判断 init 系统 ----
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
        systemctl daemon-reload
    fi
fi

# ---- unknown 兜底：两个服务文件都尝试清理 ----
if [ "$INIT" = "unknown" ]; then
    echo "未识别 init 系统，尝试清理常见服务文件..."
    rm -f "$OPENRC_SERVICE" "$SYSTEMD_SERVICE"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null
fi

# ---- 残留进程兜底清理（按完整路径精确匹配，避免误杀） ----
echo "清理残留 cloudflared 进程（如有）..."
pkill -f "$BIN_PATH" 2>/dev/null
pkill -x cloudflared 2>/dev/null

# ---- 通用清理 ----
rm -f "$BIN_PATH"
rm -f "${BIN_PATH}.tmp"
rm -f "$LOG_FILE"
rm -f "$LOGROTATE_CONF"

echo "=============================="
echo "cloudflared 已彻底卸载完成"
echo "Cloudflare 面板 Tunnel 未受影响"
echo "=============================="
