#!/usr/bin/env bash
# NFS 服务端诊断脚本

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "必须以 root 运行"; exit 1; }

STATE_DIR="/etc/nfs-wg-manager"
NODE_FILE="${STATE_DIR}/node.conf"

[[ -f $NODE_FILE ]] || { echo "未找到配置"; exit 1; }

ROLE=$(awk -F= '/^ROLE=/ {print $2}' "$NODE_FILE")
[[ $ROLE == "server" ]] || { echo "此脚本仅在 NFS 服务端运行"; exit 1; }

MEDIA_ROOT=$(awk -F= '/^MEDIA_ROOT=/ {print $2}' "$NODE_FILE")
WG_ADDRESS=$(awk -F= '/^WG_ADDRESS=/ {print $2}' "$NODE_FILE")
NODE_NAME=$(awk -F= '/^NODE_NAME=/ {print $2}' "$NODE_FILE")

echo "=== NFS 服务端诊断 ==="
echo ""

echo "【节点信息】"
echo "  名称: $NODE_NAME"
echo "  WG 地址: $WG_ADDRESS"
echo "  媒体目录: $MEDIA_ROOT"
echo ""

echo "【媒体文件】"
FILE_COUNT=$(find "$MEDIA_ROOT" -type f 2>/dev/null | wc -l)
MP4_COUNT=$(find "$MEDIA_ROOT" -type f -name "*.mp4" 2>/dev/null | wc -l)
DIR_SIZE=$(du -sh "$MEDIA_ROOT" 2>/dev/null | awk '{print $1}')
echo "  总文件数: $FILE_COUNT"
echo "  MP4 数量: $MP4_COUNT"
echo "  目录大小: $DIR_SIZE"
echo ""

echo "【文件权限】"
ROOT_PERM=$(stat -Lc '%a' "$MEDIA_ROOT")
echo "  根目录权限: $ROOT_PERM"
[[ $ROOT_PERM == "755" ]] && echo "  ✓ 权限正确" || echo "  ⚠ 权限需要修复"
echo ""

echo "【NFS 服务】"
NFS_STATUS=$(systemctl is-active nfs-server 2>/dev/null || echo "stopped")
echo "  nfs-server: $NFS_STATUS"
[[ $NFS_STATUS == "active" ]] && echo "  ✓ 运行中" || echo "  ✗ 未运行"
echo ""

echo "【NFS 导出】"
if grep -q "BEGIN NFS_WG_MANAGER" /etc/exports 2>/dev/null; then
    EXPORT_LINE=$(grep "^${MEDIA_ROOT}" /etc/exports | head -1)
    echo "  $EXPORT_LINE"
    echo "  ✓ 已配置"
else
    echo "  ✗ 未配置"
fi
echo ""

echo "【WireGuard】"
WG_STATUS=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo "stopped")
echo "  wg0 服务: $WG_STATUS"
PEER_COUNT=$(wg show wg0 peers 2>/dev/null | wc -l)
echo "  连接 Peer 数: $PEER_COUNT"
echo ""

echo "【防火墙】"
FW_STATUS=$(systemctl is-active nfs-wg-firewall 2>/dev/null || echo "stopped")
echo "  nfs-wg-firewall: $FW_STATUS"
echo ""

echo "【快速修复】"
if [[ $ROOT_PERM != "755" ]]; then
    echo "  权限不正确，运行:"
    echo "    sudo find $MEDIA_ROOT -type d -exec chmod 755 {} +"
    echo "    sudo find $MEDIA_ROOT -type f -exec chmod 644 {} +"
    echo "    sudo exportfs -rav"
fi
