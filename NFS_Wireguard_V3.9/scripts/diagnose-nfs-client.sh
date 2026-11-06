#!/usr/bin/env bash
# Jellyfin 客户端 NFS 挂载诊断脚本

set -Eeuo pipefail

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

warn() {
    printf '警告：%s\n' "$*" >&2
}

info() {
    printf '✓ %s\n' "$*"
}

printf '=== Jellyfin 客户端 NFS 诊断工具 ===\n\n'

STATE_DIR="/etc/nfs-wg-manager"
NODE_FILE="${STATE_DIR}/node.conf"

# 检查是否为客户端
if [[ ! -f $NODE_FILE ]]; then
    die "未找到配置文件，请在 Jellyfin 客户端机器上运行此脚本。"
fi

ROLE=$(awk -F= '/^ROLE=/ {print $2}' "$NODE_FILE" || echo "unknown")
[[ $ROLE == "client" ]] || die "此脚本仅在 Jellyfin 客户端 (client) 运行。当前角色: $ROLE"

MEDIA_ROOT=$(awk -F= '/^MEDIA_ROOT=/ {print $2}' "$NODE_FILE" || echo "")
[[ -n $MEDIA_ROOT ]] || die "媒体根目录未配置"

printf '【1. 检查媒体根目录挂载】\n'
printf '媒体根目录: %s\n' "$MEDIA_ROOT"

if mountpoint -q "$MEDIA_ROOT"; then
    info "媒体根目录已挂载"
    mount | grep "$MEDIA_ROOT" | sed 's/^/  /'
else
    warn "媒体根目录未挂载"
fi
printf '\n'

printf '【2. 检查 NFS 挂载点】\n'
if command -v findmnt >/dev/null 2>&1; then
    NFS_MOUNTS=$(findmnt -t nfs,nfs4 -n --output TARGET,SOURCE,FSTYPE 2>/dev/null | grep "^${MEDIA_ROOT}")
    if [[ -n $NFS_MOUNTS ]]; then
        info "发现 NFS 挂载："
        echo "$NFS_MOUNTS" | sed 's/^/  /'
    else
        warn "未找到 NFS 挂载"
    fi
else
    warn "findmnt 命令不可用"
fi
printf '\n'

printf '【3. 检查挂载权限】\n'
if [[ -e $MEDIA_ROOT ]]; then
    stat -Lc '目录权限: %a (%A)
所有者: %U:%G
可访问: %s 字节' "$MEDIA_ROOT"
    printf '\n'

    # 测试读权限
    if [[ -r $MEDIA_ROOT ]]; then
        info "当前用户有读权限"
    else
        warn "当前用户无读权限"
    fi
else
    warn "媒体根目录不存在"
fi
printf '\n'

printf '【4. 测试目录列表】\n'
if [[ -d $MEDIA_ROOT ]]; then
    DIR_COUNT=$(find "$MEDIA_ROOT" -maxdepth 1 -type d | wc -l)
    printf '子目录数量: %s\n' "$((DIR_COUNT - 1))"

    if [[ $DIR_COUNT -gt 1 ]]; then
        info "能列出子目录"
        find "$MEDIA_ROOT" -maxdepth 1 -type d ! -name "$(basename "$MEDIA_ROOT")" | head -5 | sed 's/^/  /'
    else
        warn "未找到子目录"
    fi
else
    warn "媒体根目录不可访问"
fi
printf '\n'

printf '【5. 测试文件访问】\n'
MP4_COUNT=0
if [[ -d $MEDIA_ROOT ]]; then
    MP4_COUNT=$(find "$MEDIA_ROOT" -maxdepth 3 -type f -name "*.mp4" 2>/dev/null | wc -l)
fi

printf 'MP4 文件数量: %s\n' "$MP4_COUNT"
if [[ $MP4_COUNT -eq 0 ]]; then
    warn "未找到 MP4 文件"
    printf '\n可能的原因：\n'
    printf '  1. NFS 服务端文件权限不足（服务端无读权限）\n'
    printf '  2. 文件还未同步或位置不对\n'
    printf '  3. NFS 挂载选项配置不当\n'
else
    info "找到 $MP4_COUNT 个 MP4 文件"
    find "$MEDIA_ROOT" -maxdepth 3 -type f -name "*.mp4" 2>/dev/null | head -3 | sed 's/^/  /'
fi
printf '\n'

printf '【6. 检查 WireGuard 连接】\n'
if command -v wg >/dev/null 2>&1 && wg show wg0 >/dev/null 2>&1; then
    info "WireGuard 接口正常"
    PEER_COUNT=$(wg show wg0 peers | wc -l)
    printf '连接的 Peer 数: %s\n' "$PEER_COUNT"
else
    warn "WireGuard 接口不可用"
fi
printf '\n'

printf '【7. 检查网络连通性】\n'
PEERS_FILE="${STATE_DIR}/client-peers.tsv"
if [[ -f $PEERS_FILE && -s $PEERS_FILE ]]; then
    while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
        [[ -n ${name:-} ]] || continue
        printf '测试 Peer: %s (%s)\n' "$name" "$peer_ip"
        if ping -c 1 -W 1 "$peer_ip" >/dev/null 2>&1; then
            info "  可以 ping 通"

            # 测试 NFS 端口
            if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${peer_ip}/8388" 2>/dev/null; then
                info "  NFS 端口 8388 可连接"
            else
                warn "  NFS 端口 8388 无法连接"
            fi
        else
            warn "  无法 ping 通"
        fi
    done < "$PEERS_FILE"
else
    warn "未找到 Peer 清单"
fi
printf '\n'

printf '【8. Docker 容器状态】\n'
CONTAINER_NAME=$(awk -F= '/^CONTAINER_NAME=/ {print $2}' "$NODE_FILE" || echo "jellyfin")
if command -v docker >/dev/null 2>&1; then
    if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
        printf '容器状态: %s\n' "$STATUS"

        # 检查容器内挂载
        printf '容器内检查:\n'
        docker exec "$CONTAINER_NAME" ls -la /media 2>/dev/null | sed 's/^/  /' || warn "  无法访问容器内文件"

        # 计算容器内 MP4 文件
        CONTAINER_MP4=$(docker exec "$CONTAINER_NAME" find /media -maxdepth 3 -type f -name "*.mp4" 2>/dev/null | wc -l)
        printf '容器内 MP4 数量: %s\n' "$CONTAINER_MP4"
    else
        warn "容器 $CONTAINER_NAME 不存在"
    fi
else
    warn "Docker 不可用"
fi
printf '\n'

printf '【诊断总结】\n'
if [[ $MP4_COUNT -eq 0 ]]; then
    printf '\n⚠ 问题：看不到 MP4 文件\n\n'
    printf '快速排查步骤：\n'
    printf '1. 在 NFS 服务端检查文件权限：\n'
    printf '   sudo bash fix-nfs-permissions.sh\n\n'
    printf '2. 验证 NFS 导出配置（必须包含 -ro,sync,root_squash）：\n'
    printf '   cat /etc/exports | grep "BEGIN NFS_WG_MANAGER" -A 10\n\n'
    printf '3. 重新加载 NFS 导出：\n'
    printf '   sudo exportfs -rav\n\n'
    printf '4. 在客户端重新挂载：\n'
    printf '   sudo systemctl restart nfs-wg-mounts.timer\n'
else
    info "未发现问题，MP4 文件可访问"
fi
printf '\n'
