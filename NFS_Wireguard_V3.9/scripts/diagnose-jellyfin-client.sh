#!/usr/bin/env bash
# Jellyfin 客户端诊断脚本

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "需要 root 权限"; exit 1; }

STATE_DIR="/etc/nfs-wg-manager"
NODE_FILE="$STATE_DIR/node.conf"
[[ -f $NODE_FILE ]] || { echo "未找到配置文件"; exit 1; }

MEDIA_ROOT=$(grep '^MEDIA_ROOT=' "$NODE_FILE" | cut -d= -f2)
NODE_NAME=$(grep '^NODE_NAME=' "$NODE_FILE" | cut -d= -f2)
WG_ADDRESS=$(grep '^WG_ADDRESS=' "$NODE_FILE" | cut -d= -f2)
CONTAINER=$(grep '^CONTAINER_NAME=' "$NODE_FILE" | cut -d= -f2)

echo "=== Jellyfin 客户端诊断 ==="
echo ""
echo "【配置】"
printf "  节点名称: %s\n" "$NODE_NAME"
printf "  WG 地址: %s\n" "$WG_ADDRESS"
printf "  媒体目录: %s\n" "$MEDIA_ROOT"
printf "  容器名称: %s\n" "$CONTAINER"
echo ""

echo "【服务状态】"
WG_STATUS=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo "stopped")
FW_STATUS=$(systemctl is-active nfs-wg-firewall 2>/dev/null || echo "stopped")
printf "  WireGuard: %s\n" "$WG_STATUS"
printf "  防火墙: %s\n" "$FW_STATUS"
echo ""

echo "【网络连通性】"
PEERS_FILE="$STATE_DIR/client-peers.tsv"
if [[ -f $PEERS_FILE ]]; then
    while IFS='|' read -r name peer_ip _ _ _; do
        [[ -n $name ]] || continue
        if timeout 1 ping -c 1 "$peer_ip" >/dev/null 2>&1; then
            printf "  ✓ %s (%s) 可达\n" "$name" "$peer_ip"
        else
            printf "  ✗ %s (%s) 不可达\n" "$name" "$peer_ip"
        fi
    done < "$PEERS_FILE"
else
    echo "  未找到 Peer 配置"
fi
echo ""

echo "【NFS 挂载】"
if mountpoint -q "$MEDIA_ROOT" 2>/dev/null; then
    echo "  ✓ 已挂载"
else
    echo "  ✗ 未挂载"
fi
echo ""

echo "【文件访问】"
MP4_COUNT=$(find "$MEDIA_ROOT" -maxdepth 3 -name "*.mp4" 2>/dev/null | wc -l)
printf "  MP4 文件数: %s\n" "$MP4_COUNT"
if [[ $MP4_COUNT -gt 0 ]]; then
    echo "  ✓ 文件可访问"
else
    echo "  ✗ 看不到文件"
fi
echo ""

echo "【Docker 容器】"
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER")
    printf "  容器状态: %s\n" "$CONTAINER_STATUS"
    if [[ $CONTAINER_STATUS == "running" ]]; then
        C_MP4=$(docker exec "$CONTAINER" find /media -maxdepth 3 -name "*.mp4" 2>/dev/null | wc -l)
        printf "  容器内 MP4: %s\n" "$C_MP4"
    fi
else
    echo "  ✗ 容器不存在"
fi
echo ""
