#!/usr/bin/env bash
# NFS 服务端诊断脚本

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "需要 root 权限"; exit 1; }

STATE_DIR="/etc/nfs-wg-manager"
NODE_FILE="$STATE_DIR/node.conf"
[[ -f $NODE_FILE ]] || { echo "未找到配置文件"; exit 1; }

MEDIA_ROOT=$(grep '^MEDIA_ROOT=' "$NODE_FILE" | cut -d= -f2)
NODE_NAME=$(grep '^NODE_NAME=' "$NODE_FILE" | cut -d= -f2)
WG_ADDRESS=$(grep '^WG_ADDRESS=' "$NODE_FILE" | cut -d= -f2)

echo "=== NFS 服务端诊断 ==="
echo ""
echo "【配置】"
printf "  节点名称: %s\n" "$NODE_NAME"
printf "  WG 地址: %s\n" "$WG_ADDRESS"
printf "  媒体目录: %s\n" "$MEDIA_ROOT"
echo ""

echo "【媒体文件】"
FILE_COUNT=$(find "$MEDIA_ROOT" -type f 2>/dev/null | wc -l)
MP4_COUNT=$(find "$MEDIA_ROOT" -name "*.mp4" 2>/dev/null | wc -l)
printf "  文件总数: %s | MP4 文件: %s\n" "$FILE_COUNT" "$MP4_COUNT"
echo ""

echo "【文件权限】"
PERM=$(stat -c '%a' "$MEDIA_ROOT")
OWNER=$(stat -c '%U:%G' "$MEDIA_ROOT")
printf "  权限: %s | 所有者: %s\n" "$PERM" "$OWNER"
if [[ $PERM == "755" ]]; then
    echo "  ✓ 权限正确"
else
    echo "  ✗ 权限错误（应为 755）"
fi
echo ""

echo "【服务状态】"
NFS_STATUS=$(systemctl is-active nfs-server 2>/dev/null || echo "stopped")
WG_STATUS=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo "stopped")
FW_STATUS=$(systemctl is-active nfs-wg-firewall 2>/dev/null || echo "stopped")
printf "  NFS 服务: %s\n" "$NFS_STATUS"
printf "  WireGuard: %s\n" "$WG_STATUS"
printf "  防火墙: %s\n" "$FW_STATUS"
echo ""

echo "【NFS 导出】"
if grep -q "^$MEDIA_ROOT" /etc/exports 2>/dev/null; then
    grep "^$MEDIA_ROOT" /etc/exports | head -1 | sed 's/^/  /'
    echo "  ✓ 已配置"
else
    echo "  ✗ 未配置"
fi
echo ""
