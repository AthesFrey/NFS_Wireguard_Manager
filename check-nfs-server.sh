#!/usr/bin/env bash
# NFS 服务端状态查询脚本

set -Eeuo pipefail

readonly STATE_DIR="/etc/nfs-wg-manager"
readonly NODE_FILE="${STATE_DIR}/node.conf"
readonly PEERS_FILE="${STATE_DIR}/server-peers.tsv"
readonly WG_CONFIG="/etc/wireguard/wg0.conf"
readonly WG_KEY_FILE="/etc/wireguard/wg0.key"
readonly NFS_PORT="8388"

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

printf '=== NFS 服务端状态 ===\n\n'

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

printf '【节点配置】\n'
printf '  节点名称:      %s\n' "$NODE_NAME"
printf '  角色:          %s\n' "$ROLE"
printf '  WG 地址:       %s\n' "$WG_ADDRESS"
printf '  WG 网段:       %s\n' "$WG_SUBNET"
printf '  WG 监听端口:   %s/udp\n' "$WG_LISTEN_PORT"
printf '  媒体目录:      %s\n' "$MEDIA_ROOT"
printf '  NFS 端口:      %s/tcp\n' "$NFS_PORT"
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

# Jellyfin Client Peer 清单
printf '【Jellyfin 客户端 Peer 清单】\n'
if [[ -f $PEERS_FILE && -s $PEERS_FILE ]]; then
    printf '  %-20s %-15s %-50s\n' 'Peer 名称' 'WG 地址' '公钥 (前20字符)'
    printf '  %s\n' '--------------------------------------------------------------------------------'
    while IFS='|' read -r name peer_ip public_key; do
        [[ -n ${name:-} ]] || continue
        printf '  %-20s %-15s %-50s\n' "$name" "$peer_ip" "${public_key:0:20}..."
    done < "$PEERS_FILE"
else
    printf '  未配置 Jellyfin 客户端 Peer\n'
fi
printf '\n'

# NFS 服务状态
printf '【NFS 服务状态】\n'
NFS_SERVICE="nfs-server"
if command -v systemctl >/dev/null 2>&1; then
    NFS_STATUS=$(systemctl is-active "$NFS_SERVICE" 2>/dev/null || echo "未运行")
    printf '  服务状态:      %s\n' "$NFS_STATUS"
fi

# NFS 协议版本检查
if [[ -r /proc/fs/nfsd/versions ]]; then
    VERSIONS=$(cat /proc/fs/nfsd/versions)
    printf '  协议版本:      %s\n' "$VERSIONS"
    if [[ $VERSIONS == *"+4.1"* && $VERSIONS != *"+2"* && $VERSIONS != *"+3"* ]]; then
        printf '  ✓ NFSv4.1 已正确配置\n'
    else
        printf '  ⚠ NFSv4.1 配置可能不正确\n'
    fi
else
    printf '  无法读取 NFS 协议版本信息\n'
fi

# NFS 端口检查
if [[ -r /proc/fs/nfsd/portlist ]]; then
    PORTLIST=$(cat /proc/fs/nfsd/portlist)
    printf '  监听端口:      %s\n' "$PORTLIST"
else
    printf '  无法读取 NFS 端口列表\n'
fi

# TCP 端口监听检查
if command -v ss >/dev/null 2>&1; then
    if ss -H -lnt "sport = :${NFS_PORT}" | grep -q .; then
        printf '  ✓ TCP %s 正在监听\n' "$NFS_PORT"
    else
        printf '  ⚠ TCP %s 未监听\n' "$NFS_PORT"
    fi
fi
printf '\n'

# NFS 导出状态
printf '【NFS 导出状态】\n'
if command -v exportfs >/dev/null 2>&1; then
    EXPORT_COUNT=$(exportfs -s 2>/dev/null | grep -c "^${MEDIA_ROOT}" || echo "0")
    printf '  活跃导出数量:  %s\n' "$EXPORT_COUNT"
    if [[ $EXPORT_COUNT -gt 0 ]]; then
        printf '  导出详情:\n'
        exportfs -s | grep "^${MEDIA_ROOT}" | sed 's/^/    /' || true
    fi
else
    printf '  exportfs 命令不可用\n'
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

# 媒体目录状态
printf '【媒体目录状态】\n'
if [[ -d $MEDIA_ROOT ]]; then
    printf '  目录存在:      是\n'
    DISK_INFO=$(df -h "$MEDIA_ROOT" | tail -n1 | awk '{printf "  已用: %s / 总计: %s (%s)", $3, $2, $5}')
    printf '%s\n' "$DISK_INFO"
else
    printf '  目录存在:      否\n'
    printf '  ⚠ 媒体目录 %s 不存在\n' "$MEDIA_ROOT"
fi
printf '\n'

printf '查询完成。\n'
