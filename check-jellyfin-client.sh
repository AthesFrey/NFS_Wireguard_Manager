#!/usr/bin/env bash
# Jellyfin 客户端状态查询脚本

set -Eeuo pipefail

readonly STATE_DIR="/etc/nfs-wg-manager"
readonly NODE_FILE="${STATE_DIR}/node.conf"
readonly PEERS_FILE="${STATE_DIR}/client-peers.tsv"
readonly WG_CONFIG="/etc/wireguard/wg0.conf"
readonly WG_KEY_FILE="/etc/wireguard/wg0.key"

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

state_get() {
    local key=$1
    local file=$2
    [[ -f $file ]] || return 1
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

printf '=== Jellyfin 客户端状态 ===\n\n'

# 检查配置文件是否存在
if [[ ! -f $NODE_FILE ]]; then
    die "未找到配置文件 $NODE_FILE，请先运行安装脚本。"
fi

# 读取节点信息
NODE_NAME=$(state_get NODE_NAME "$NODE_FILE" || echo "未设置")
ROLE=$(state_get ROLE "$NODE_FILE" || echo "未设置")
WG_ADDRESS=$(state_get WG_ADDRESS "$NODE_FILE" || echo "未设置")
WG_SUBNET=$(state_get WG_SUBNET "$NODE_FILE" || echo "未设置")
WG_LISTEN_PORT=$(state_get WG_LISTEN_PORT "$NODE_FILE" || echo "未设置")
MEDIA_ROOT=$(state_get MEDIA_ROOT "$NODE_FILE" || echo "未设置")
CONTAINER_NAME=$(state_get CONTAINER_NAME "$NODE_FILE" || echo "未设置")

printf '【节点配置】\n'
printf '  节点名称:      %s\n' "$NODE_NAME"
printf '  角色:          %s\n' "$ROLE"
printf '  WG 地址:       %s\n' "$WG_ADDRESS"
printf '  WG 网段:       %s\n' "$WG_SUBNET"
printf '  WG 监听端口:   %s/udp\n' "$WG_LISTEN_PORT"
printf '  媒体根目录:    %s\n' "$MEDIA_ROOT"
printf '  容器名称:      %s\n' "$CONTAINER_NAME"
printf '\n'

# 读取 WireGuard 公钥
if [[ -f $WG_KEY_FILE ]]; then
    PRIVATE_KEY=$(<"$WG_KEY_FILE")
    PUBLIC_KEY=$(printf '%s' "$PRIVATE_KEY" | wg pubkey 2>/dev/null || echo "无效")
    printf '【WireGuard 密钥】\n'
    printf '  公钥:          %s\n' "$PUBLIC_KEY"
    printf '\n'
else
    printf '【WireGuard 密钥】\n'
    printf '  未找到密钥文件: %s\n' "$WG_KEY_FILE"
    printf '\n'
fi

# WireGuard 运行状态
printf '【WireGuard 状态】\n'
if command -v wg >/dev/null 2>&1 && wg show wg0 >/dev/null 2>&1; then
    WG_STATUS=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo "未运行")
    printf '  服务状态:      %s\n' "$WG_STATUS"
    printf '  接口信息:\n'
    wg show wg0 | sed 's/^/    /'
else
    printf '  wg0 未运行或未安装\n'
fi
printf '\n'

# NFS Peer 清单
printf '【NFS Server Peer 清单】\n'
if [[ -f $PEERS_FILE && -s $PEERS_FILE ]]; then
    printf '  %-20s %-15s %-50s\n' 'Peer 名称' 'WG 地址' 'Endpoint'
    printf '  %s\n' '--------------------------------------------------------------------------------'
    while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
        [[ -n ${name:-} ]] || continue
        printf '  %-20s %-15s %-50s\n' "$name" "$peer_ip" "$endpoint"
    done < "$PEERS_FILE"
else
    printf '  未配置 NFS Server Peer\n'
fi
printf '\n'

# NFS 挂载状态
printf '【NFS 挂载状态】\n'
if command -v findmnt >/dev/null 2>&1; then
    MOUNT_COUNT=$(findmnt -t nfs,nfs4 -n --output TARGET,SOURCE | grep -c "^${MEDIA_ROOT}/" || echo "0")
    printf '  活跃挂载数量:  %s\n' "$MOUNT_COUNT"
    if [[ $MOUNT_COUNT -gt 0 ]]; then
        printf '  挂载详情:\n'
        findmnt -t nfs,nfs4 -n --output TARGET,SOURCE,FSTYPE,OPTIONS | grep "^${MEDIA_ROOT}/" | sed 's/^/    /' || true
    fi
else
    printf '  findmnt 命令不可用\n'
fi
printf '\n'

# 防火墙状态
printf '【防火墙状态】\n'
FW_SERVICE=$(systemctl is-active nfs-wg-firewall 2>/dev/null || echo "未运行")
printf '  防火墙服务:    %s\n' "$FW_SERVICE"
if command -v nft >/dev/null 2>&1; then
    if nft list table inet nfs_wg_manager >/dev/null 2>&1; then
        printf '  nftables 表:   已创建\n'
    else
        printf '  nftables 表:   未找到\n'
    fi
fi
printf '\n'

# Docker 容器状态
printf '【Docker 容器状态】\n'
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
        printf '  容器状态:      %s\n' "$CONTAINER_STATUS"
        MEDIA_MOUNT=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/media"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME")
        printf '  /media 挂载源: %s\n' "$MEDIA_MOUNT"
    else
        printf '  容器 %s 不存在\n' "$CONTAINER_NAME"
    fi
else
    printf '  Docker 不可用\n'
fi
printf '\n'

printf '查询完成。\n'
