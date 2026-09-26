#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="0.2.0"
readonly STATE_DIR="/etc/nfs-wg-manager"
readonly WG_DIR="/etc/wireguard"
readonly WG_INTERFACE="wg0"
readonly WG_CONFIG="${WG_DIR}/${WG_INTERFACE}.conf"
readonly WG_KEY_FILE="${WG_DIR}/${WG_INTERFACE}.key"
readonly WG_DEFAULT_SUBNET="10.96.0.0/16"
readonly WG_DEFAULT_PORT="35669"
readonly NFS_PORT="8388"
readonly DEFAULT_MEDIA_ROOT="/opt/jellyfin/media"
readonly DEFAULT_CONTAINER="jellyfin"
readonly MANAGED_MARKER="# Managed by NFS_Wireguard_Manager"
readonly FSTAB_BEGIN="# BEGIN NFS_WG_MANAGER"
readonly FSTAB_END="# END NFS_WG_MANAGER"
readonly DOCKER_BEGIN="# BEGIN NFS_WG_MANAGER Docker ordering"
readonly DOCKER_END="# END NFS_WG_MANAGER Docker ordering"

PEERS_FILE="${STATE_DIR}/client-peers.tsv"
NODE_FILE="${STATE_DIR}/node.conf"
NEW_PEERS_FILE=""
MEDIA_ROOT=""
CONTAINER_NAME=""
WG_ADDRESS=""
WG_SUBNET=""
WG_LISTEN_PORT=""
NODE_NAME=""
PRIVATE_KEY=""
PUBLIC_KEY=""
ACTIVE_MOUNTS=0

declare -a OLD_MOUNT_PATHS=()

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
用法：sudo bash install-jellyfin-client.sh

脚本会交互式安装 WireGuard/NFS 客户端，并配置 Jellyfin 宿主机上的 NFS 挂载。
重新运行本脚本可以重新输入 NFS Server Peer 清单；本机 WireGuard 私钥会保留。
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
        [[ "${VERSION_ID%%.*}" =~ ^(11|12|13)$ ]] || die "仅支持 Debian 11/12/13，当前为 ${PRETTY_NAME:-unknown}。"
        ;;
    ubuntu)
        [[ "${VERSION_ID%%.*}" =~ ^(20|22|24)$ ]] || die "仅支持 Ubuntu 20.04/22.04/24.04，当前为 ${PRETTY_NAME:-unknown}。"
        ;;
    *)
        die "仅支持 Debian 11/12/13 和 Ubuntu 20.04/22.04/24.04，当前为 ${PRETTY_NAME:-unknown}。"
        ;;
esac

command -v apt-get >/dev/null 2>&1 || die "找不到 apt-get。"
command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl。"

mkdir -p "$STATE_DIR" "$WG_DIR"
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

valid_endpoint() {
    local endpoint=$1
    local host=${endpoint%:*}
    local port=${endpoint##*:}
    [[ $endpoint != *[[:space:]\|\#\;]* ]] || return 1
    [[ $host != "$endpoint" && -n $host ]] || return 1
    if [[ $host == \[*\] ]]; then
        [[ $host =~ ^\[[0-9A-Fa-f:.]+\]$ ]] || return 1
    else
        [[ $host != *:* ]] || return 1
        [[ $host =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    fi
    valid_port "$port"
}

valid_abs_path() {
    local path=$1
    [[ $path == /* ]] || return 1
    [[ $path == "/" || $path =~ ^/[A-Za-z0-9._/@+~-]+$ ]]
}

valid_mount_path() {
    local path=$1
    valid_abs_path "$path" || return 1
    if [[ $MEDIA_ROOT == "/" ]]; then
        [[ $path != "/" ]] || return 1
    else
        [[ $path == "$MEDIA_ROOT"/* ]] || return 1
    fi
    [[ $path != *"/../"* && $path != */.. && $path != *"/./"* && $path != */. ]]
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

remove_block() {
    local file=$1
    local begin=$2
    local end=$3
    local tmp
    [[ -f $file ]] || return 0
    backup_once "$file"
    tmp=$(mktemp "${file}.nwm.XXXXXX")
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { inside = 1; next }
        $0 == end { inside = 0; next }
        !inside { print }
    ' "$file" > "$tmp"
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
        printf 'CONTAINER_NAME=%s\n' "$CONTAINER_NAME"
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
    local name peer_ip public_key endpoint mount_path old_ip old_key old_endpoint old_mount
    NEW_PEERS_FILE=$(mktemp "${STATE_DIR}/client-peers.XXXXXX")
    chmod 0600 "$NEW_PEERS_FILE"

    if [[ -s $PEERS_FILE ]] && confirm "保留当前 NFS Peer 清单？重新输入请选择 n" "Y"; then
        cp -f "$PEERS_FILE" "$NEW_PEERS_FILE"
    else
        : > "$NEW_PEERS_FILE"
        while :; do
            name=$(prompt "NFS Server Peer 名称（填写服务端节点名，例如 ddps_nft；留空结束）" "")
            [[ -z $name ]] && break
            valid_name "$name" || { warn "名称只能包含字母、数字、点、下划线和短横线。"; continue; }
            [[ $name != "$NODE_NAME" ]] || { warn "Peer 名称不能与本机相同。"; continue; }
            peer_exists_in_file "$NEW_PEERS_FILE" "$name" && { warn "Peer 名称重复。"; continue; }

            old_ip=$(old_peer_field "$name" 2 || true)
            old_key=$(old_peer_field "$name" 3 || true)
            old_endpoint=$(old_peer_field "$name" 4 || true)
            old_mount=$(old_peer_field "$name" 5 || true)

            peer_ip=$(prompt "NFS Server ${name} 的 WireGuard IPv4 地址（例如 10.96.0.1）" "$old_ip")
            valid_ipv4 "$peer_ip" || { warn "IPv4 地址无效。"; continue; }
            ipv4_in_cidr "$peer_ip" "$WG_SUBNET" || { warn "Peer 地址不在 WireGuard 网段 $WG_SUBNET 内。"; continue; }
            [[ $peer_ip != "$WG_ADDRESS" ]] || { warn "Peer 地址不能与本机相同。"; continue; }
            peer_ip_exists_in_file "$NEW_PEERS_FILE" "$peer_ip" && { warn "Peer WireGuard 地址重复。"; continue; }
            public_key=$(prompt "NFS Server ${name} 输出的 WireGuard 公钥（一行 44 字符，不是名称或 IP）" "$old_key")
            valid_key "$public_key" || { warn "WireGuard 公钥格式无效。"; continue; }
            endpoint=$(prompt "NFS Server ${name} 的公网 Endpoint（公网 IP 或域名:35669，例如 203.0.113.10:35669）" "$old_endpoint")
            valid_endpoint "$endpoint" || { warn "Endpoint 必须是 host:port，端口范围 1-65535。"; continue; }
            mount_path=$(prompt "${name} 的本地挂载目录" "${old_mount:-${MEDIA_ROOT}/${name}}")
            valid_mount_path "$mount_path" || { warn "挂载目录必须位于 Jellyfin 媒体根目录 $MEDIA_ROOT 下，且只能包含安全路径字符。"; continue; }
            printf '%s|%s|%s|%s|%s\n' "$name" "$peer_ip" "$public_key" "$endpoint" "$mount_path" >> "$NEW_PEERS_FILE"
        done
    fi
}

validate_peer_file() {
    local name peer_ip public_key endpoint mount_path
    [[ -f $NEW_PEERS_FILE ]] || return 0
    while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
        [[ -n ${name:-} ]] || continue
        valid_name "$name" || die "Peer $name 的名称无效。"
        if ! valid_ipv4 "$peer_ip" || ! ipv4_in_cidr "$peer_ip" "$WG_SUBNET"; then
            die "Peer $name 的地址 $peer_ip 不在网段 $WG_SUBNET 内。"
        fi
        [[ $peer_ip != "$WG_ADDRESS" ]] || die "Peer $name 的地址不能与本机相同。"
        valid_key "$public_key" || die "Peer $name 的 WireGuard 公钥无效。"
        valid_endpoint "$endpoint" || die "Peer $name 的 Endpoint 无效。"
        valid_mount_path "$mount_path" || die "Peer $name 的挂载目录不在当前媒体根目录下；请选择重新输入 Peer 清单。"
    done < "$NEW_PEERS_FILE"
}

remember_old_mounts() {
    OLD_MOUNT_PATHS=()
    [[ -f $PEERS_FILE ]] || return 0
    while IFS='|' read -r _ _ _ _ mount_path; do
        [[ -n ${mount_path:-} ]] && OLD_MOUNT_PATHS+=("$mount_path")
    done < "$PEERS_FILE"
}

write_wg_config() {
    local tmp name peer_ip public_key endpoint mount_path
    tmp=$(mktemp "${WG_CONFIG}.XXXXXX")
    {
        printf '%s\n' "$MANAGED_MARKER"
        printf '# Node: %s\n' "$NODE_NAME"
        printf '[Interface]\n'
        printf 'Address = %s/32\n' "$WG_ADDRESS"
        printf 'ListenPort = %s\n' "$WG_LISTEN_PORT"
        printf 'PrivateKey = %s\n' "$PRIVATE_KEY"
        if [[ -s $PEERS_FILE ]]; then
            while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
                [[ -n ${name:-} ]] || continue
                printf '\n[Peer]\n'
                printf '# %s\n' "$name"
                printf 'PublicKey = %s\n' "$public_key"
                printf 'AllowedIPs = %s/32\n' "$peer_ip"
                printf 'Endpoint = %s\n' "$endpoint"
                printf 'PersistentKeepalive = 25\n'
            done < "$PEERS_FILE"
        fi
    } > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$WG_CONFIG"
}

write_fstab() {
    local block name peer_ip public_key endpoint mount_path
    block="$FSTAB_BEGIN"
    if [[ -s $PEERS_FILE ]]; then
        while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
            [[ -n ${name:-} ]] || continue
            install -d -m 0755 "$mount_path"
            block+=$'\n'
            block+="# ${name}"
            block+=$'\n'
            block+="${peer_ip}:/ ${mount_path} nfs4 ro,vers=4.1,proto=tcp,port=${NFS_PORT},_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30s,hard,timeo=600,retrans=2,nosuid,nodev 0 0"
        done < "$PEERS_FILE"
    fi
    block+=$'\n'
    block+="$FSTAB_END"
    replace_block /etc/fstab "$FSTAB_BEGIN" "$FSTAB_END" "$block"
}

write_docker_ordering() {
    local dropin=/etc/systemd/system/docker.service.d/nfs-wg-manager.conf
    local mount_units=""
    local name peer_ip public_key endpoint mount_path mount_unit

    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi
    if ! docker info >/dev/null 2>&1; then
        warn "Docker 守护进程当前不可用；保留现有 Docker 启动依赖，不修改它。"
        return 0
    fi
    if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        if [[ -f $dropin ]] && grep -qF "$DOCKER_BEGIN" "$dropin"; then
            rm -f "$dropin"
        fi
        return 0
    fi

    local mapping
    mapping=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/media"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
    if [[ $mapping != "$MEDIA_ROOT" ]]; then
        warn "容器 $CONTAINER_NAME 的 /media 映射不是 $MEDIA_ROOT；不会写入 Docker 启动依赖。"
        if [[ -f $dropin ]] && grep -qF "$DOCKER_BEGIN" "$dropin"; then
            rm -f "$dropin"
        fi
        return 0
    fi

    if [[ ! -s $PEERS_FILE ]]; then
        if [[ -f $dropin ]] && grep -qF "$DOCKER_BEGIN" "$dropin"; then
            rm -f "$dropin"
        fi
        return 0
    fi

    mkdir -p "$(dirname "$dropin")"
    while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
        [[ -n ${name:-} ]] || continue
        mount_unit=$(systemd-escape --path --suffix=mount "$mount_path")
        mount_units+=" ${mount_unit}"
    done < "$PEERS_FILE"

    local block
    block=$(cat <<EOF
$DOCKER_BEGIN
[Unit]
Wants=wg-quick@${WG_INTERFACE}.service${mount_units}
After=network-online.target wg-quick@${WG_INTERFACE}.service${mount_units}
$DOCKER_END
EOF
)
    if [[ -f $dropin ]] && ! grep -qF "$DOCKER_BEGIN" "$dropin"; then
        die "$dropin 已存在且不是本工具生成的文件；请手工合并后重试。"
    fi
    backup_once "$dropin"
    printf '%s\n' "$block" > "$dropin"
    chmod 0644 "$dropin"
}

start_wireguard() {
    systemctl enable wg-quick@"$WG_INTERFACE" >/dev/null
    if systemctl is-active --quiet wg-quick@"$WG_INTERFACE"; then
        systemctl restart wg-quick@"$WG_INTERFACE"
    else
        systemctl start wg-quick@"$WG_INTERFACE"
    fi
}

mount_configured_peers() {
    local name peer_ip public_key endpoint mount_path
    ACTIVE_MOUNTS=0
    [[ -s $PEERS_FILE ]] || return 0
    while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
        [[ -n ${name:-} ]] || continue
        if mountpoint -q "$mount_path"; then
            ACTIVE_MOUNTS=$((ACTIVE_MOUNTS + 1))
            continue
        fi
        if timeout 30s mount "$mount_path" >/dev/null 2>&1 && mountpoint -q "$mount_path"; then
            info "已挂载 ${name} -> ${mount_path}"
            ACTIVE_MOUNTS=$((ACTIVE_MOUNTS + 1))
        else
            warn "挂载 ${name} 失败；请检查 WireGuard、公钥、Endpoint、nftables 和 NFS 服务。"
        fi
    done < "$PEERS_FILE"
}

unmount_removed_peers() {
    local old_path
    for old_path in "${OLD_MOUNT_PATHS[@]}"; do
        if ! awk -F'|' -v p="$old_path" '$5 == p {found=1} END {exit !found}' "$PEERS_FILE"; then
            if mountpoint -q "$old_path"; then
                if timeout 15s umount "$old_path" >/dev/null 2>&1; then
                    info "已卸载移除的 Peer 挂载：$old_path"
                else
                    warn "无法卸载已移除的挂载 $old_path；可稍后手工执行 umount。"
                fi
            fi
        fi
    done
}

maybe_restart_jellyfin() {
    local state
    [[ $ACTIVE_MOUNTS -gt 0 ]] || return 0
    command -v docker >/dev/null 2>&1 || return 0
    docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || return 0
    state=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)
    if [[ $state == running ]]; then
        if docker restart "$CONTAINER_NAME" >/dev/null; then
            info "已重启现有 Jellyfin 容器 $CONTAINER_NAME，使 NFS 子目录对 /media 映射生效。"
        else
            warn "重启 Jellyfin 容器失败，请手工执行 docker restart $CONTAINER_NAME。"
        fi
    fi
}

install_packages() {
    info "安装 wireguard 和 nfs-common..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard nfs-common
}

main() {
    local current
    install_packages
    ensure_manager_wg_config

    current=$(state_get NODE_NAME "$NODE_FILE" || true)
    NODE_NAME=$(prompt "本机节点名称（Jellyfin 客户端示例：hhost_jf）" "$current")
    valid_name "$NODE_NAME" || die "节点名称无效。"

    current=$(state_get WG_ADDRESS "$NODE_FILE" || true)
    WG_ADDRESS=$(prompt "本机 WireGuard IPv4 地址（Jellyfin 客户端示例：10.96.0.2）" "$current")
    valid_ipv4 "$WG_ADDRESS" || die "WireGuard IPv4 地址无效。"

    current=$(state_get WG_SUBNET "$NODE_FILE" || true)
    WG_SUBNET=$(prompt "WireGuard 网段" "${current:-$WG_DEFAULT_SUBNET}")
    valid_cidr "$WG_SUBNET" || die "WireGuard 网段必须是 IPv4 CIDR，例如 10.96.0.0/16。"
    ipv4_in_cidr "$WG_ADDRESS" "$WG_SUBNET" || die "本机 WireGuard 地址不在网段 $WG_SUBNET 内。"

    current=$(state_get WG_LISTEN_PORT "$NODE_FILE" || true)
    WG_LISTEN_PORT=$(prompt "WireGuard UDP 监听端口" "${current:-$WG_DEFAULT_PORT}")
    valid_port "$WG_LISTEN_PORT" || die "WireGuard 端口无效。"

    current=$(state_get MEDIA_ROOT "$NODE_FILE" || true)
    MEDIA_ROOT=$(prompt "Jellyfin 宿主机媒体根目录" "${current:-$DEFAULT_MEDIA_ROOT}")
    valid_abs_path "$MEDIA_ROOT" || die "媒体根目录必须是无空格的绝对路径。"
    install -d -m 0755 "$MEDIA_ROOT"

    current=$(state_get CONTAINER_NAME "$NODE_FILE" || true)
    CONTAINER_NAME=$(prompt "Jellyfin Docker 容器名" "${current:-$DEFAULT_CONTAINER}")
    valid_name "$CONTAINER_NAME" || die "容器名无效。"

    remember_old_mounts
    collect_peers
    validate_peer_file
    mv -f "$NEW_PEERS_FILE" "$PEERS_FILE"
    chmod 0600 "$PEERS_FILE"
    save_node_state
    load_or_create_key
    write_wg_config
    write_fstab
    write_docker_ordering

    systemctl daemon-reload
    start_wireguard
    unmount_removed_peers
    mount_configured_peers
    maybe_restart_jellyfin

    printf '\n本机节点：%s\n' "$NODE_NAME"
    printf 'WireGuard 地址：%s\n' "$WG_ADDRESS"
    printf 'WireGuard 公钥：%s\n' "$PUBLIC_KEY"
    printf 'WireGuard 端口：%s/udp\n' "$WG_LISTEN_PORT"
    printf 'NFS 服务端口：%s/tcp\n' "$NFS_PORT"
    printf '活跃 NFS 挂载：%s\n' "$ACTIVE_MOUNTS"
    printf '\n下一步：把本机 WireGuard 公钥加入每个 NFS Server 的客户端 Peer；可使用服务端脚本的 --add-client-peer 模式，然后检查 wg show、findmnt 和 docker exec。\n'
}

main "$@"
