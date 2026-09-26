#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="0.1.0"
readonly STATE_DIR="/etc/nfs-wg-manager"
readonly WG_DIR="/etc/wireguard"
readonly WG_INTERFACE="wg0"
readonly WG_CONFIG="${WG_DIR}/${WG_INTERFACE}.conf"
readonly WG_KEY_FILE="${WG_DIR}/${WG_INTERFACE}.key"
readonly WG_DEFAULT_SUBNET="10.96.0.0/16"
readonly WG_DEFAULT_PORT="35669"
readonly NFS_PORT="8388"
readonly DEFAULT_MEDIA_ROOT="/srv/media"
readonly MANAGED_MARKER="# Managed by NFS_Wireguard_Manager"
readonly EXPORTS_BEGIN="# BEGIN NFS_WG_MANAGER"
readonly EXPORTS_END="# END NFS_WG_MANAGER"

PEERS_FILE="${STATE_DIR}/server-peers.tsv"
NODE_FILE="${STATE_DIR}/node.conf"
NFS_CONF_DIR="/etc/nfs.conf.d"
NFS_CONF_FILE="${NFS_CONF_DIR}/99-nfs-wg-manager.conf"
NEW_PEERS_FILE=""
MEDIA_ROOT=""
WG_ADDRESS=""
WG_SUBNET=""
WG_LISTEN_PORT=""
NODE_NAME=""
PRIVATE_KEY=""
PUBLIC_KEY=""
NFS_SERVICE=""

cleanup() {
    if [[ -n ${NEW_PEERS_FILE:-} && -e $NEW_PEERS_FILE ]]; then
        rm -f -- "$NEW_PEERS_FILE"
    fi
}
trap cleanup EXIT

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

warn() {
    printf '警告：%s\n' "$*" >&2
}

info() {
    printf '%s\n' "$*"
}

usage() {
    cat <<'EOF'
用法：sudo bash install-nfs-server.sh

脚本会交互式安装 WireGuard/NFS 服务端，并将输入的媒体目录以 NFSv4 根导出。
默认媒体目录为 /srv/media；重新运行脚本可以重新输入客户端 Peer 清单。
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--version" ]]; then
    printf '%s\n' "$SCRIPT_VERSION"
    exit 0
fi

[[ $EUID -eq 0 ]] || die "请使用 root 运行此脚本。"
[[ -r /etc/os-release ]] || die "找不到 /etc/os-release。"
[[ -r /dev/tty ]] || die "需要交互终端；请直接在 VPS 上运行，或使用 curl | sudo bash。"

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    debian)
        [[ "${VERSION_ID%%.*}" =~ ^(11|12)$ ]] || die "仅支持 Debian 11/12，当前为 ${PRETTY_NAME:-unknown}。"
        ;;
    ubuntu)
        [[ "${VERSION_ID%%.*}" =~ ^(20|22|24)$ ]] || die "仅支持 Ubuntu 20.04/22.04/24.04，当前为 ${PRETTY_NAME:-unknown}。"
        ;;
    *)
        die "仅支持 Debian 11/12 和 Ubuntu 20.04/22.04/24.04，当前为 ${PRETTY_NAME:-unknown}。"
        ;;
esac

command -v apt-get >/dev/null 2>&1 || die "找不到 apt-get。"
command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl。"

mkdir -p "$STATE_DIR" "$WG_DIR" "$NFS_CONF_DIR"
chmod 0700 "$STATE_DIR"
umask 077

exec 9>/run/lock/nfs-wg-manager.lock
if command -v flock >/dev/null 2>&1; then
    flock -n 9 || die "已有另一个 NFS_Wireguard_Manager 实例正在运行。"
fi

prompt() {
    local label=$1
    local default=${2-}
    local value

    if [[ -n $default ]]; then
        printf '%s [%s]: ' "$label" "$default" >/dev/tty
    else
        printf '%s: ' "$label" >/dev/tty
    fi
    IFS= read -r value </dev/tty || die "读取交互输入失败。"
    if [[ -z $value ]]; then
        value=$default
    fi
    printf '%s' "$value"
}

confirm() {
    local label=$1
    local default=${2:-N}
    local value
    printf '%s [%s]: ' "$label" "$default" >/dev/tty
    IFS= read -r value </dev/tty || die "读取交互输入失败。"
    value=${value:-$default}
    [[ $value =~ ^[Yy]([Ee][Ss])?$ ]]
}

state_get() {
    local key=$1
    local file=$2
    [[ -f $file ]] || return 1
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

valid_name() {
    [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

valid_ipv4() {
    local ip=$1
    local part
    local -a octets
    [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for part in "${octets[@]}"; do
        [[ $part =~ ^[0-9]+$ ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}

valid_cidr() {
    local cidr=$1
    local ip=${cidr%/*}
    local prefix=${cidr##*/}
    valid_ipv4 "$ip" || return 1
    [[ $prefix =~ ^[0-9]+$ ]] || return 1
    ((10#$prefix >= 1 && 10#$prefix <= 32))
}

ipv4_to_int() {
    local ip=$1
    local -a octets
    IFS=. read -r -a octets <<< "$ip"
    printf '%u' "$(( (10#${octets[0]} << 24) | (10#${octets[1]} << 16) | (10#${octets[2]} << 8) | 10#${octets[3]} ))"
}

ipv4_in_cidr() {
    local ip=$1
    local cidr=$2
    local network prefix
    local mask ip_int network_int
    network=${cidr%/*}
    prefix=${cidr##*/}
    if ((10#$prefix == 32)); then
        mask=4294967295
    else
        mask=$(( (4294967295 << (32 - 10#$prefix)) & 4294967295 ))
    fi
    ip_int=$(ipv4_to_int "$ip")
    network_int=$(ipv4_to_int "$network")
    (( (ip_int & mask) == (network_int & mask) ))
}

valid_port() {
    local port=$1
    [[ $port =~ ^[0-9]+$ ]] || return 1
    ((10#$port >= 1 && 10#$port <= 65535))
}

valid_key() {
    local key=$1
    [[ ${#key} -eq 44 && $key =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

valid_abs_path() {
    local path=$1
    [[ $path == /* ]] || return 1
    [[ $path == "/" || $path =~ ^/[A-Za-z0-9._/@+~-]+$ ]]
}

backup_once() {
    local file=$1
    local backup="${file}.nfs-wg-manager.bak"
    if [[ -f $file && ! -e $backup ]]; then
        cp -a "$file" "$backup"
    fi
}

replace_block() {
    local file=$1
    local begin=$2
    local end=$3
    local block=$4
    local tmp

    backup_once "$file"
    tmp=$(mktemp "${file}.nwm.XXXXXX")
    if [[ -f $file ]]; then
        if grep -qF "$begin" "$file" && ! grep -qF "$end" "$file"; then
            rm -f "$tmp"
            die "$file 中发现不完整的 NFS_Wireguard_Manager 配置块；请手工修复后重试。"
        fi
        awk -v begin="$begin" -v end="$end" '
            $0 == begin { inside = 1; next }
            $0 == end { inside = 0; next }
            !inside { print }
        ' "$file" > "$tmp"
    fi
    if [[ -s $tmp ]]; then
        printf '\n' >> "$tmp"
    fi
    printf '%s\n' "$block" >> "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$file"
}

ensure_manager_wg_config() {
    if [[ -f $WG_CONFIG ]] && ! grep -qF "$MANAGED_MARKER" "$WG_CONFIG"; then
        die "$WG_CONFIG 已存在且不是本工具生成的文件；为避免覆盖现有 WireGuard 配置，脚本已停止。"
    fi
}

load_or_create_key() {
    local key_tmp
    if [[ -s $WG_KEY_FILE ]]; then
        PRIVATE_KEY=$(<"$WG_KEY_FILE")
    elif [[ -f $WG_CONFIG ]]; then
        PRIVATE_KEY=$(awk -F'= ' '/^[[:space:]]*PrivateKey[[:space:]]*=/ {print $2; exit}' "$WG_CONFIG")
        [[ -n $PRIVATE_KEY ]] || die "无法从现有管理配置恢复 WireGuard 私钥。"
        printf '%s\n' "$PRIVATE_KEY" > "$WG_KEY_FILE"
        chmod 0600 "$WG_KEY_FILE"
    else
        command -v wg >/dev/null 2>&1 || die "安装 wireguard 后仍找不到 wg 命令。"
        key_tmp=$(mktemp "${WG_KEY_FILE}.XXXXXX")
        wg genkey > "$key_tmp"
        chmod 0600 "$key_tmp"
        mv -f "$key_tmp" "$WG_KEY_FILE"
        PRIVATE_KEY=$(<"$WG_KEY_FILE")
    fi
    [[ -n $PRIVATE_KEY ]] || die "WireGuard 私钥为空。"
    PUBLIC_KEY=$(printf '%s' "$PRIVATE_KEY" | wg pubkey)
}

save_node_state() {
    local tmp
    tmp=$(mktemp "${NODE_FILE}.XXXXXX")
    {
        printf 'NODE_NAME=%s\n' "$NODE_NAME"
        printf 'WG_ADDRESS=%s\n' "$WG_ADDRESS"
        printf 'WG_SUBNET=%s\n' "$WG_SUBNET"
        printf 'WG_LISTEN_PORT=%s\n' "$WG_LISTEN_PORT"
        printf 'MEDIA_ROOT=%s\n' "$MEDIA_ROOT"
    } > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$NODE_FILE"
}

old_peer_field() {
    local name=$1
    local field=$2
    [[ -f $PEERS_FILE ]] || return 0
    awk -F'|' -v n="$name" -v f="$field" '$1 == n {print $f; exit}' "$PEERS_FILE"
}

peer_exists_in_file() {
    local file=$1
    local name=$2
    [[ -f $file ]] || return 1
    awk -F'|' -v n="$name" '$1 == n {found=1} END {exit !found}' "$file"
}

peer_ip_exists_in_file() {
    local file=$1
    local peer_ip=$2
    [[ -f $file ]] || return 1
    awk -F'|' -v ip="$peer_ip" '$2 == ip {found=1} END {exit !found}' "$file"
}

collect_peers() {
    local name peer_ip public_key old_ip old_key
    NEW_PEERS_FILE=$(mktemp "${STATE_DIR}/server-peers.XXXXXX")
    chmod 0600 "$NEW_PEERS_FILE"

    if [[ -s $PEERS_FILE ]] && confirm "保留当前 Jellyfin 客户端 Peer 清单？重新输入请选择 n" "Y"; then
        cp -f "$PEERS_FILE" "$NEW_PEERS_FILE"
    else
        : > "$NEW_PEERS_FILE"
        while :; do
            name=$(prompt "Jellyfin 客户端 Peer 名称（留空结束）" "")
            [[ -z $name ]] && break
            valid_name "$name" || { warn "名称只能包含字母、数字、点、下划线和短横线。"; continue; }
            [[ $name != "$NODE_NAME" ]] || { warn "Peer 名称不能与本机相同。"; continue; }
            peer_exists_in_file "$NEW_PEERS_FILE" "$name" && { warn "Peer 名称重复。"; continue; }

            old_ip=$(old_peer_field "$name" 2 || true)
            old_key=$(old_peer_field "$name" 3 || true)
            peer_ip=$(prompt "${name} 的 WireGuard IPv4 地址" "$old_ip")
            valid_ipv4 "$peer_ip" || { warn "IPv4 地址无效。"; continue; }
            ipv4_in_cidr "$peer_ip" "$WG_SUBNET" || { warn "Peer 地址不在 WireGuard 网段 $WG_SUBNET 内。"; continue; }
            [[ $peer_ip != "$WG_ADDRESS" ]] || { warn "Peer 地址不能与本机相同。"; continue; }
            peer_ip_exists_in_file "$NEW_PEERS_FILE" "$peer_ip" && { warn "Peer WireGuard 地址重复。"; continue; }
            public_key=$(prompt "${name} 的 WireGuard 公钥" "$old_key")
            valid_key "$public_key" || { warn "WireGuard 公钥格式无效。"; continue; }
            printf '%s|%s|%s\n' "$name" "$peer_ip" "$public_key" >> "$NEW_PEERS_FILE"
        done
    fi
}

validate_peer_file() {
    local name peer_ip public_key
    [[ -f $NEW_PEERS_FILE ]] || return 0
    while IFS='|' read -r name peer_ip public_key; do
        [[ -n ${name:-} ]] || continue
        valid_name "$name" || die "Peer $name 的名称无效。"
        if ! valid_ipv4 "$peer_ip" || ! ipv4_in_cidr "$peer_ip" "$WG_SUBNET"; then
            die "Peer $name 的地址 $peer_ip 不在网段 $WG_SUBNET 内。"
        fi
        [[ $peer_ip != "$WG_ADDRESS" ]] || die "Peer $name 的地址不能与本机相同。"
        valid_key "$public_key" || die "Peer $name 的 WireGuard 公钥无效。"
    done < "$NEW_PEERS_FILE"
}

write_wg_config() {
    local tmp name peer_ip public_key
    tmp=$(mktemp "${WG_CONFIG}.XXXXXX")
    {
        printf '%s\n' "$MANAGED_MARKER"
        printf '# Node: %s\n' "$NODE_NAME"
        printf '[Interface]\n'
        printf 'Address = %s/32\n' "$WG_ADDRESS"
        printf 'ListenPort = %s\n' "$WG_LISTEN_PORT"
        printf 'PrivateKey = %s\n' "$PRIVATE_KEY"
        if [[ -s $PEERS_FILE ]]; then
            while IFS='|' read -r name peer_ip public_key; do
                [[ -n ${name:-} ]] || continue
                printf '\n[Peer]\n'
                printf '# %s\n' "$name"
                printf 'PublicKey = %s\n' "$public_key"
                printf 'AllowedIPs = %s/32\n' "$peer_ip"
            done < "$PEERS_FILE"
        fi
    } > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$WG_CONFIG"
}

write_nfs_config() {
    local tmp
    tmp=$(mktemp "${NFS_CONF_FILE}.XXXXXX")
    cat > "$tmp" <<EOF
# Managed by NFS_Wireguard_Manager
# NFSv4 only over WireGuard. NFS service port is intentionally non-default.
[nfsd]
port = ${NFS_PORT}
tcp = yes
udp = no
vers3 = no
vers4 = yes
vers4.0 = no
vers4.1 = yes
vers4.2 = no
rdma = no
EOF
    chmod 0644 "$tmp"
    if [[ -f $NFS_CONF_FILE ]] && ! grep -qF "$MANAGED_MARKER" "$NFS_CONF_FILE"; then
        die "$NFS_CONF_FILE 已存在且不是本工具生成的文件；请手工合并后重试。"
    fi
    backup_once "$NFS_CONF_FILE"
    mv -f "$tmp" "$NFS_CONF_FILE"
}

write_exports() {
    local block="${EXPORTS_BEGIN}" name peer_ip public_key
    block+=$'\n'
    if [[ -s $PEERS_FILE ]]; then
        block+="${MEDIA_ROOT}"
        while IFS='|' read -r name peer_ip public_key; do
            [[ -n ${name:-} ]] || continue
            block+=" ${peer_ip}/32(ro,sync,root_squash,no_subtree_check,fsid=0)"
        done < "$PEERS_FILE"
        block+=$'\n'
    else
        block+="# 尚未配置 Jellyfin 客户端 Peer；重新运行脚本后添加客户端。"
        block+=$'\n'
    fi
    block+="$EXPORTS_END"
    replace_block /etc/exports "$EXPORTS_BEGIN" "$EXPORTS_END" "$block"
}

find_nfs_service() {
    if systemctl cat nfs-server.service >/dev/null 2>&1; then
        NFS_SERVICE="nfs-server"
    elif systemctl cat nfs-kernel-server.service >/dev/null 2>&1; then
        NFS_SERVICE="nfs-kernel-server"
    else
        NFS_SERVICE="nfs-server"
    fi
}

start_services() {
    systemctl enable wg-quick@"$WG_INTERFACE" >/dev/null
    if systemctl is-active --quiet wg-quick@"$WG_INTERFACE"; then
        systemctl restart wg-quick@"$WG_INTERFACE"
    else
        systemctl start wg-quick@"$WG_INTERFACE"
    fi

    find_nfs_service
    systemctl enable "$NFS_SERVICE" >/dev/null
    if systemctl is-active --quiet "$NFS_SERVICE"; then
        systemctl restart "$NFS_SERVICE"
    else
        systemctl start "$NFS_SERVICE"
    fi
    exportfs -rav
}

install_packages() {
    info "安装 wireguard 和 nfs-kernel-server..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard nfs-kernel-server
}

main() {
    local current
    install_packages
    ensure_manager_wg_config

    current=$(state_get NODE_NAME "$NODE_FILE" || true)
    NODE_NAME=$(prompt "本机节点名称" "$current")
    valid_name "$NODE_NAME" || die "节点名称无效。"

    current=$(state_get WG_ADDRESS "$NODE_FILE" || true)
    WG_ADDRESS=$(prompt "本机 WireGuard IPv4 地址" "$current")
    valid_ipv4 "$WG_ADDRESS" || die "WireGuard IPv4 地址无效。"

    current=$(state_get WG_SUBNET "$NODE_FILE" || true)
    WG_SUBNET=$(prompt "WireGuard 网段" "${current:-$WG_DEFAULT_SUBNET}")
    valid_cidr "$WG_SUBNET" || die "WireGuard 网段必须是 IPv4 CIDR，例如 10.96.0.0/16。"
    ipv4_in_cidr "$WG_ADDRESS" "$WG_SUBNET" || die "本机 WireGuard 地址不在网段 $WG_SUBNET 内。"

    current=$(state_get WG_LISTEN_PORT "$NODE_FILE" || true)
    WG_LISTEN_PORT=$(prompt "WireGuard UDP 监听端口" "${current:-$WG_DEFAULT_PORT}")
    valid_port "$WG_LISTEN_PORT" || die "WireGuard 端口无效。"

    current=$(state_get MEDIA_ROOT "$NODE_FILE" || true)
    MEDIA_ROOT=$(prompt "NFS 导出的媒体目录" "${current:-$DEFAULT_MEDIA_ROOT}")
    valid_abs_path "$MEDIA_ROOT" || die "媒体目录必须是无空格的绝对路径。"
    if [[ ! -d $MEDIA_ROOT ]]; then
        warn "$MEDIA_ROOT 不存在，将创建该目录；请确认实际媒体磁盘已经挂载。"
        install -d -m 0755 "$MEDIA_ROOT"
    fi

    collect_peers
    validate_peer_file
    mv -f "$NEW_PEERS_FILE" "$PEERS_FILE"
    chmod 0600 "$PEERS_FILE"
    save_node_state
    load_or_create_key
    write_wg_config
    write_nfs_config
    write_exports
    start_services

    printf '\n本机节点：%s\n' "$NODE_NAME"
    printf 'WireGuard 地址：%s\n' "$WG_ADDRESS"
    printf 'WireGuard 公钥：%s\n' "$PUBLIC_KEY"
    printf 'WireGuard 端口：%s/udp\n' "$WG_LISTEN_PORT"
    printf 'NFS 媒体目录：%s\n' "$MEDIA_ROOT"
    printf 'NFS 服务端口：%s/tcp\n' "$NFS_PORT"
    printf '\n下一步：将本机公钥和 Endpoint 信息填入 Jellyfin 客户端脚本，并在本机 nftables 放行 wg0 上的 TCP 8388。\n'
}

main "$@"





