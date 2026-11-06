#!/usr/bin/env bash
# Jellyfin 客户端诊断脚本

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "必须以 root 运行"; exit 1; }

STATE_DIR="/etc/nfs-wg-manager"
NODE_FILE="${STATE_DIR}/node.conf"

[[ -f $NODE_FILE ]] || { echo "未找到配置"; exit 1; }

ROLE=$(awk -F= '/^ROLE=/ {print $2}' "$NODE_FILE")
[[ $ROLE == "client" ]] || { echo "此脚本仅在 Jellyfin 客户端运行"; exit 1; }

MEDIA_ROOT=$(awk -F= '/^MEDIA_ROOT=/ {print $2}' "$NODE_FILE")
WG_ADDRESS=$(awk -F= '/^WG_ADDRESS=/ {print $2}' "$NODE_FILE")
CONTAINER_NAME=$(awk -F= '/^CONTAINER_NAME=/ {print $2}' "$NODE_FILE")
NODE_NAME=$(awk -F= '/^NODE_NAME=/ {print $2}' "$NODE_FILE")

echo "=== Jellyfin 客户端诊断 ==="
echo ""

echo "【节点信息】"
echo "  名称: $NODE_NAME"
echo "  WG 地址: $WG_ADDRESS"
echo "  媒体根目录: $MEDIA_ROOT"
echo "  容器名称: $CONTAINER_NAME"
echo ""

echo "【WireGuard 连接】"
WG_STATUS=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo "stopped")
echo "  wg0 服务: $WG_STATUS"
if [[ $WG_STATUS == "active" ]]; then
    PEER_COUNT=$(wg show wg0 peers 2>/dev/null | wc -l)
    echo "  连接 Peer 数: $PEER_COUNT"
    echo "  ✓ 连接正常"
else
    echo "  ✗ WireGuard 未运行"
fi
echo ""

echo "【网络连通性】"
PEERS_FILE="${STATE_DIR}/client-peers.tsv"
if [[ -f $PEERS_FILE ]]; then
    while IFS='|' read -r name peer_ip _ _ _; do
        [[ -n $name ]] || continue
        if timeout 1 ping -c 1 "$peer_ip" >/dev/null 2>&1; then
            echo "  ✓ $name ($peer_ip) 可达"
        else
            echo "  ✗ $name ($peer_ip) 不可达"
        fi
    done < "$PEERS_FILE"
fi
echo ""

echo "【NFS 挂载状态】"
if mountpoint -q "$MEDIA_ROOT" 2>/dev/null; then
    echo "  ✓ 媒体根目录已挂载"
    MOUNT_INFO=$(mount | grep "$MEDIA_ROOT" | head -1)
    echo "  $MOUNT_INFO" | sed 's/^/    /'
else
    echo "  ✗ 媒体根目录未挂载"
fi
echo ""

echo "【NFS 文件访问】"
if [[ -d $MEDIA_ROOT ]]; then
    MP4_COUNT=$(find "$MEDIA_ROOT" -maxdepth 3 -type f -name "*.mp4" 2>/dev/null | wc -l)
    echo "  MP4 文件数: $MP4_COUNT"
    if [[ $MP4_COUNT -gt 0 ]]; then
        echo "  ✓ 文件可访问"
    else
        echo "  ✗ 看不到文件"
    fi
else
    echo "  ✗ 媒体根目录不存在"
fi
echo ""

echo "【Docker 容器】"
CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not found")
echo "  容器状态: $CONTAINER_STATUS"
if [[ $CONTAINER_STATUS == "running" ]]; then
    CONTAINER_MP4=$(docker exec "$CONTAINER_NAME" find /media -maxdepth 3 -type f -name "*.mp4" 2>/dev/null | wc -l)
    echo "  容器内 MP4: $CONTAINER_MP4"
    if [[ $CONTAINER_MP4 -gt 0 ]]; then
        echo "  ✓ 容器内可见文件"
    else
        echo "  ✗ 容器内看不到文件"
    fi
fi
echo ""

echo "【防火墙】"
FW_STATUS=$(systemctl is-active nfs-wg-firewall 2>/dev/null || echo "stopped")
echo "  nfs-wg-firewall: $FW_STATUS"
echo ""

echo "【快速排查】"
if [[ $WG_STATUS != "active" ]]; then
    echo "  1. WireGuard 未运行，执行:"
    echo "     sudo systemctl start wg-quick@wg0"
fi
if [[ $(mountpoint -q "$MEDIA_ROOT" 2>/dev/null || echo "no") == "no" ]]; then
    echo "  2. NFS 未挂载，执行:"
    echo "     sudo systemctl restart nfs-wg-mounts.timer"
    echo "     sleep 5"
    echo "     findmnt -t nfs,nfs4"
fi
