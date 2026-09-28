#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="3.1.0"
readonly ROLE="client"
readonly RUNTIME_DIR="/usr/local/libexec/nfs-wg-manager"
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
手动重载 nftables 后恢复隧道内规则：sudo bash install-jellyfin-client.sh --apply-firewall
公网 UDP 端口需自行放行；脚本仅管理 wg0 上的 NFS TCP 8388。
首次运行时可隐藏粘贴本机离线私钥，直接回车则自动生成；重新运行时会保留已有私钥。
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
if [[ ${1:-} != --apply-firewall ]]; then
    [[ -r /dev/tty ]] || die "需要交互终端；请直接在 VPS 上运行，或使用 curl | sudo bash。"
fi

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

if [[ ${1:-} == --apply-firewall ]]; then
    [[ -d $STATE_DIR ]] || die "请先完成客户端安装。"
else
    mkdir -p "$STATE_DIR" "$WG_DIR"
    chmod 0700 "$STATE_DIR"
fi
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

prompt_secret() {
    local label=$1
    local value
    printf '%s: ' "$label" >/dev/tty
    IFS= read -r -s value </dev/tty || die "读取交互输入失败。"
    printf '\n' >/dev/tty
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
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for part in "${octets[@]}"; do
        [[ $part == 0 || $part =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}

valid_cidr() {
    local cidr=$1
    local ip=${cidr%/*}
    local prefix=${cidr##*/}
    valid_ipv4 "$ip" || return 1
    [[ $cidr == */* && $prefix =~ ^[1-9][0-9]?$ ]] || return 1
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
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    ((10#$port >= 1 && 10#$port <= 65535))
}

valid_key() {
    local key=$1
    [[ ${#key} -eq 44 && $key =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]
}

valid_endpoint() {
    local endpoint=$1
    local host=${endpoint%:*}
    local port=${endpoint##*:}
    [[ $endpoint != *[[:space:]\|\#\;]* ]] || return 1
    [[ $host != "$endpoint" && -n $host ]] || return 1
    if [[ $host == \[*\] ]]; then
        [[ $host =~ ^\[[0-9A-Fa-f:.]+\]$ ]] || return 1
        python3 -c 'import ipaddress, sys; ipaddress.IPv6Address(sys.argv[1])' "${host:1:-1}" >/dev/null 2>&1 || return 1
    else
        [[ $host != *:* ]] || return 1
        [[ $host =~ ^[A-Za-z0-9._-]+$ ]] || return 1
        if [[ $host =~ ^[0-9.]+$ ]]; then
            valid_ipv4 "$host" || return 1
        fi
    fi
    valid_port "$port"
}

normalize_abs_path() {
    local path=$1 component
    local -a components
    [[ $path == /* && ($path == "/" || $path =~ ^/[A-Za-z0-9._/@+~-]+$) ]] || return 1
    while [[ $path != "/" && $path == */ ]]; do
        path=${path%/}
    done
    [[ $path != *//* ]] || return 1
    IFS=/ read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [[ -n $component && $component != . && $component != .. ]] || return 1
    done
    printf '%s' "$path"
}

valid_mount_path() {
    local path=$1
    local root_real path_real
    path=$(normalize_abs_path "$path") || return 1
    if [[ $MEDIA_ROOT == "/" ]]; then
        [[ $path != "/" ]] || return 1
    else
        [[ $path == "$MEDIA_ROOT"/* ]] || return 1
    fi
    root_real=$(realpath -m -- "$MEDIA_ROOT") || return 1
    path_real=$(realpath -m -- "$path") || return 1
    normalize_abs_path "$path_real" >/dev/null || return 1
    if [[ $root_real == "/" ]]; then
        [[ $path_real != "/" ]] || return 1
    else
        [[ $path_real == "$root_real"/* ]] || return 1
    fi
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
    local key_tmp=""
    local save_key=0
    if [[ -s $WG_KEY_FILE ]]; then
        PRIVATE_KEY=$(<"$WG_KEY_FILE")
    elif [[ -f $WG_CONFIG ]]; then
        PRIVATE_KEY=$(awk -F'= ' '/^[[:space:]]*PrivateKey[[:space:]]*=/ {print $2; exit}' "$WG_CONFIG")
        [[ -n $PRIVATE_KEY ]] || die "无法从现有管理配置恢复 WireGuard 私钥。"
        save_key=1
    else
        command -v wg >/dev/null 2>&1 || die "安装 wireguard 后仍找不到 wg 命令。"
        PRIVATE_KEY=$(prompt_secret "输入本机 WireGuard 私钥（隐藏输入；回车自动生成）" "")
        key_tmp=$(mktemp "${WG_KEY_FILE}.XXXXXX")
        if [[ -n $PRIVATE_KEY ]]; then
            printf '%s\n' "$PRIVATE_KEY" > "$key_tmp"
        else
            wg genkey > "$key_tmp" || { rm -f -- "$key_tmp"; die "生成 WireGuard 私钥失败。"; }
        fi
        chmod 0600 "$key_tmp"
        PRIVATE_KEY=$(<"$key_tmp")
        save_key=1
    fi
    [[ -n $PRIVATE_KEY ]] || die "WireGuard 私钥为空。"
    PUBLIC_KEY=$(printf '%s' "$PRIVATE_KEY" | wg pubkey) || {
        [[ -z $key_tmp ]] || rm -f -- "$key_tmp"
        die "WireGuard 私钥无效；请粘贴本机的一行私钥。"
    }
    if (( save_key )); then
        if [[ -z $key_tmp ]]; then
            key_tmp=$(mktemp "${WG_KEY_FILE}.XXXXXX")
            printf '%s\n' "$PRIVATE_KEY" > "$key_tmp"
            chmod 0600 "$key_tmp"
        fi
        mv -f "$key_tmp" "$WG_KEY_FILE"
    fi
}

write_managed_file() {
    local output=$1 mode=${2:-0644} tmp
    if [[ -e $output ]] && ! grep -qF "$MANAGED_MARKER" "$output"; then
        die "$output 已存在且不是本工具生成的文件。"
    fi
    mkdir -p "$(dirname "$output")"
    tmp=$(mktemp "${output}.XXXXXX")
    cat > "$tmp"
    chmod "$mode" "$tmp"
    backup_once "$output"
    mv -f "$tmp" "$output"
}

apply_saved_firewall() {
    [[ -x $RUNTIME_DIR/firewall && -f $NODE_FILE ]] || die "请先完整运行一次本版本安装器。"
    [[ $(state_get ROLE "$NODE_FILE") == "$ROLE" ]] || die "本机保存的节点角色与此安装入口不符。"
    "$RUNTIME_DIR/firewall"
    info "已重新应用 wg0 上的 NFS 防火墙规则；公网 UDP 规则由你管理。"
}

install_firewall_support() {
    write_managed_file "$RUNTIME_DIR/firewall" 0755 <<'NWM_FIREWALL_PY'
#!/usr/bin/python3
# Managed by NFS_Wireguard_Manager
"""Reconcile only NFS-over-WireGuard rules; never open the public UDP port."""
import fcntl
import ipaddress
import json
import pathlib
import re
import subprocess
import sys

STATE = pathlib.Path('/etc/nfs-wg-manager')
LOCK = '/run/nfs-wg-manager-firewall.lock'
TABLE = 'nfs_wg_manager'
MARK = 'nfs-wg-manager:'


def run(argv, data=None):
    p = subprocess.run(argv, input=data, text=True, capture_output=True)
    if p.returncode:
        raise RuntimeError(' '.join(argv[:3]) + ': ' + p.stderr.strip())
    return p


def settings():
    node = dict(line.split('=', 1) for line in (STATE / 'node.conf').read_text().splitlines() if '=' in line)
    role = node.get('ROLE')
    if role not in ('server', 'client'):
        raise ValueError('缺少节点角色，请先运行对应安装器。')
    address = str(ipaddress.IPv4Address(node['WG_ADDRESS']))
    peers = []
    for line in (STATE / (role + '-peers.tsv')).read_text().splitlines():
        if not line:
            continue
        fields = line.split('|')
        if len(fields) != (3 if role == 'server' else 5):
            raise ValueError('Peer 清单字段数量错误。')
        peer = str(ipaddress.IPv4Address(fields[1]))
        if peer == address or peer in peers:
            raise ValueError('Peer 地址与本机冲突或重复。')
        peers.append(peer)
    return role, address, peers


def match(left, right):
    return {'match': {'op': '==', 'left': left, 'right': right}}


def packet(protocol, field):
    return {'payload': {'protocol': protocol, 'field': field}}


def flow(role, address, peers, direction):
    incoming = direction == 'input'
    request = (role == 'server') == incoming
    expr = [match({'meta': {'key': 'iifname' if incoming else 'oifname'}}, 'wg0'),
            match(packet('ip', 'saddr' if incoming else 'daddr'), {'set': peers}),
            match(packet('ip', 'daddr' if incoming else 'saddr'), address),
            match({'meta': {'key': 'l4proto'}}, 'tcp'),
            match(packet('tcp', 'dport' if request else 'sport'), 8388)]
    if not request:
        expr.append(match({'ct': {'key': 'state'}}, {'set': ['established', 'related']}))
    return expr + [{'counter': None}, {'accept': None}]


def transaction(snapshot, role, address, peers, compat=()):
    objects = snapshot['nftables']
    chains = [o['chain'] for o in objects if 'chain' in o]
    rules = [o['rule'] for o in objects if 'rule' in o]
    own = [o for o in objects if any(isinstance(v, dict) and v.get('family') == 'inet'
           and (v.get('table') == TABLE or (k == 'table' and v.get('name') == TABLE))
           for k, v in o.items())]
    if own:
        # The name is reserved, but it must never authorize erasing foreign data.
        own_chains = [o['chain'] for o in own if 'chain' in o]
        if {c['name'] for c in own_chains} != {'input', 'output'}:
            raise ValueError('保留表名 nfs_wg_manager 已被其他规则占用。')
        for o in own:
            if 'chain' in o:
                c = o['chain']
                if (c.get('hook') != c['name'] or c.get('type') != 'filter'
                        or c.get('policy') != 'accept' or c.get('prio') != -10):
                    raise ValueError('本工程防火墙表的结构已被修改。')
            elif 'rule' in o:
                if not o['rule'].get('comment', '').startswith(MARK):
                    raise ValueError('本工程防火墙表含有外部规则，停止更新。')
            elif 'table' not in o:
                raise ValueError('本工程防火墙表含有外部对象，停止更新。')
    targets = []
    for c in chains:
        if c.get('family') == 'netdev' and c.get('hook') in ('ingress', 'egress') and ('wg0' == c.get('dev') or 'wg0' in c.get('devices', [])):
            raise ValueError('wg0 存在 netdev 过滤链，请先核对该链；未自动混用。')
        if c.get('family') not in ('ip', 'inet') or (c['family'], c.get('table')) == ('inet', TABLE) or 'hook' not in c:
            continue
        members = [r for r in rules if all(r.get(k) == c.get(k) for k in ('family', 'table')) and r['chain'] == c['name']]
        external = [r for r in members if not r.get('comment', '').startswith(MARK)]
        if c['hook'] not in ('input', 'output'):
            # NAT and Docker forwarding are outside this tool's ownership.
            if c.get('type') == 'filter' and c['hook'] in ('ingress', 'prerouting', 'postrouting') and (external or c.get('policy') == 'drop'):
                raise ValueError('存在额外的前置或后置过滤链 %s/%s/%s；请先核对其对 wg0 的限制。' % (c['family'], c['table'], c['name']))
            continue
        if c.get('type') != 'filter':
            if c.get('type') == 'route' and (external or c.get('policy') == 'drop'):
                raise ValueError('存在额外的 output route 过滤链，请先核对其对 wg0 的限制。')
            continue
        if (c['family'], c['table']) in compat:
            if c.get('policy') == 'accept' and not external:
                continue
            raise ValueError('主机过滤链由 iptables 管理，不能自动混用：' + c['table'] + '/' + c['name'])
        if any('ufw' in str(x).lower() or 'firewalld' in str(x).lower() for x in (c['table'], c['name'], external)):
            raise ValueError('检测到 UFW/firewalld 托管规则，请使用原生 nftables 主机过滤规则。')
        targets.append(c)
    commands = []
    for r in rules:
        if r.get('comment', '').startswith(MARK) and not (r['family'] == 'inet' and r['table'] == TABLE):
            commands.append({'delete': {'rule': {k: r[k] for k in ('family', 'table', 'chain', 'handle')}}})
    if own:
        commands.append({'delete': {'table': {'family': 'inet', 'name': TABLE}}})
    commands.append({'add': {'table': {'family': 'inet', 'name': TABLE}}})
    for direction in ('input', 'output'):
        commands.append({'add': {'chain': {'family': 'inet', 'table': TABLE, 'name': direction,
                         'type': 'filter', 'hook': direction, 'prio': -10, 'policy': 'accept'}}})
        if peers:
            for c in [dict(family='inet', table=TABLE, name=direction, hook=direction)] + [c for c in targets if c['hook'] == direction]:
                rule = dict(family=c['family'], table=c['table'], chain=c['name'],
                            expr=flow(role, address, peers, direction), comment=MARK + role + ':' + direction)
                commands.append({'add' if (c['family'], c['table']) == ('inet', TABLE) else 'insert': {'rule': rule}})
    if role == 'server':
        commands.append({'add': {'rule': {'family': 'inet', 'table': TABLE, 'chain': 'input',
            'expr': [match({'meta': {'key': 'l4proto'}}, 'tcp'), match(packet('tcp', 'dport'), 8388),
                     {'counter': None}, {'drop': None}], 'comment': MARK + 'deny-other-nfs'}}})
    return {'nftables': commands}


def main():
    if sys.argv[1:] not in ([], ['--check']):
        raise ValueError('用法：firewall [--check]')
    with open(LOCK, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        p = run(['nft', '-j', 'list', 'ruleset'])
        plain = run(['nft', 'list', 'ruleset'])
        compat = set(re.findall(r'table\s+(ip|inet)\s+(\S+)\s+is managed by iptables', p.stderr + plain.stderr + plain.stdout))
        data = json.dumps(transaction(json.loads(p.stdout), *settings(), compat=compat))
        run(['nft', '-j', '-c', '-f', '-'], data)
        if '--check' not in sys.argv:
            run(['nft', '-j', '-f', '-'], data)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError) as exc:
        print('NFS 防火墙错误：' + str(exc), file=sys.stderr)
        sys.exit(1)
NWM_FIREWALL_PY
    write_managed_file /etc/systemd/system/nfs-wg-firewall.service <<EOF
$MANAGED_MARKER
[Unit]
Description=NFS over WireGuard firewall
After=nftables.service
Before=wg-quick@wg0.service
[Service]
Type=oneshot
ExecStart=$RUNTIME_DIR/firewall
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    write_managed_file /etc/systemd/system/nftables.service.d/nfs-wg-manager.conf <<EOF
$MANAGED_MARKER
[Service]
ExecStartPost=$RUNTIME_DIR/firewall
ExecReload=$RUNTIME_DIR/firewall
EOF
    write_managed_file /etc/systemd/system/wg-quick@wg0.service.d/nfs-wg-manager.conf <<EOF
$MANAGED_MARKER
[Unit]
Requires=nfs-wg-firewall.service
After=nfs-wg-firewall.service
EOF
}

start_firewall() {
    systemctl daemon-reload
    "$RUNTIME_DIR/firewall" --check
    systemctl enable nfs-wg-firewall.service >/dev/null
    systemctl restart nfs-wg-firewall.service
}

save_node_state() {
    local tmp
    tmp=$(mktemp "${NODE_FILE}.XXXXXX")
    {
        printf 'ROLE=%s\n' "$ROLE"
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

peer_key_exists_in_file() {
    local file=$1
    local public_key=$2
    [[ -f $file ]] || return 1
    awk -F'|' -v key="$public_key" '$3 == key {found=1} END {exit !found}' "$file"
}

peer_mount_exists_in_file() {
    local file=$1
    local mount_path=$2
    local existing_path existing_real target_real
    [[ -f $file ]] || return 1
    target_real=$(realpath -m -- "$mount_path") || return 1
    while IFS='|' read -r _ _ _ _ existing_path; do
        [[ -n ${existing_path:-} ]] || continue
        existing_real=$(realpath -m -- "$existing_path") || continue
        [[ $target_real != "$existing_real" && $target_real != "$existing_real"/* && $existing_real != "$target_real"/* ]] || return 0
    done < "$file"
    return 1
}

collect_peers() {
    local name peer_ip public_key endpoint mount_path old_ip old_key old_endpoint old_mount
    NEW_PEERS_FILE=$(mktemp "${STATE_DIR}/client-peers.XXXXXX")
    chmod 0600 "$NEW_PEERS_FILE"

    if [[ -s $PEERS_FILE ]] && confirm "保留当前 NFS Peer 清单？重新输入请选择 n" "Y"; then
        cp -f "$PEERS_FILE" "$NEW_PEERS_FILE"
        if validate_peer_file; then
            return 0
        fi
        confirm "当前 Peer 清单不符合媒体根目录或字段校验；是否重新输入完整清单？" "Y" || die "未更改不合规的 Peer 清单。"
    fi

    : > "$NEW_PEERS_FILE"
    while :; do
        while :; do
            name=$(prompt "NFS Server Peer 名称（填写服务端节点名，例如 ddps_nft；留空结束）" "")
            [[ -z $name ]] && return 0
            valid_name "$name" || { warn "名称只能包含字母、数字、点、下划线和短横线。请重新输入 Peer 名称。"; continue; }
            [[ $name != "$NODE_NAME" ]] || { warn "Peer 名称不能与本机相同。请重新输入 Peer 名称。"; continue; }
            peer_exists_in_file "$NEW_PEERS_FILE" "$name" && { warn "Peer 名称重复。请重新输入 Peer 名称。"; continue; }
            break
        done

        old_ip=$(old_peer_field "$name" 2 || true)
        old_key=$(old_peer_field "$name" 3 || true)
        old_endpoint=$(old_peer_field "$name" 4 || true)
        old_mount=$(old_peer_field "$name" 5 || true)

        while :; do
            peer_ip=$(prompt "NFS Server ${name} 的 WireGuard IPv4 地址（例如 10.96.0.2）" "${old_ip:-10.96.0.2}")
            if valid_ipv4 "$peer_ip" && ipv4_in_cidr "$peer_ip" "$WG_SUBNET" && [[ $peer_ip != "$WG_ADDRESS" ]] && ! peer_ip_exists_in_file "$NEW_PEERS_FILE" "$peer_ip"; then
                break
            fi
            warn "IPv4 地址无效、超出 WireGuard 网段、与本机冲突或已被使用。请重新输入 ${name} 的地址。"
        done

        while :; do
            public_key=$(prompt "NFS Server ${name} 输出的 WireGuard 公钥（一行 44 字符，不是名称或 IP）" "$old_key")
            if valid_key "$public_key" && ! peer_key_exists_in_file "$NEW_PEERS_FILE" "$public_key"; then
                break
            fi
            warn "WireGuard 公钥格式无效或已被使用。请重新输入 ${name} 的公钥。"
        done

        while :; do
            endpoint=$(prompt "NFS Server ${name} 的公网 Endpoint（公网 IP 或域名:35669，例如 203.0.113.10:35669）" "$old_endpoint")
            valid_endpoint "$endpoint" && break
            warn "Endpoint 必须是 host:port，端口范围 1-65535。请重新输入 ${name} 的 Endpoint。"
        done

        while :; do
            mount_path=$(prompt "${name} 的本地挂载目录" "${old_mount:-${MEDIA_ROOT}/${name}}")
            mount_path=$(normalize_abs_path "$mount_path" 2>/dev/null || true)
            if valid_mount_path "$mount_path" && ! peer_mount_exists_in_file "$NEW_PEERS_FILE" "$mount_path"; then
                mount_path=$(realpath -m -- "$mount_path")
                break
            fi
            warn "挂载目录必须是 Jellyfin 媒体根目录 $MEDIA_ROOT 下的安全子目录，且不能与其他 Peer 重复。请重新输入 ${name} 的挂载目录。"
        done
        printf '%s|%s|%s|%s|%s\n' "$name" "$peer_ip" "$public_key" "$endpoint" "$mount_path" >> "$NEW_PEERS_FILE"
    done
}

validate_peer_file() {
    local name peer_ip public_key endpoint mount_path
    local mount_real existing_mount
    local -A seen_names=() seen_ips=() seen_keys=() seen_mounts=()
    [[ -f $NEW_PEERS_FILE ]] || return 0
    while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
        [[ -n ${name:-} ]] || continue
        if ! valid_name "$name" || [[ $name == "$NODE_NAME" ]] || [[ -n ${seen_names[$name]+x} ]]; then
            warn "Peer 清单中的名称无效、重复或与本机同名：${name:-<空>}。"
            return 1
        fi
        if ! valid_ipv4 "$peer_ip" || ! ipv4_in_cidr "$peer_ip" "$WG_SUBNET" || [[ $peer_ip == "$WG_ADDRESS" ]] || [[ -n ${seen_ips[$peer_ip]+x} ]]; then
            warn "Peer $name 的 WireGuard 地址无效、冲突或重复：${peer_ip:-<空>}。"
            return 1
        fi
        if ! valid_key "$public_key" || [[ -n ${seen_keys[$public_key]+x} ]]; then
            warn "Peer $name 的 WireGuard 公钥无效或重复。"
            return 1
        fi
        if ! valid_endpoint "$endpoint"; then
            warn "Peer $name 的 Endpoint 无效。"
            return 1
        fi
        if ! valid_mount_path "$mount_path"; then
            warn "Peer $name 的挂载目录不在当前媒体根目录下、路径不安全或与其他 Peer 重复。"
            return 1
        fi
        mount_real=$(realpath -m -- "$mount_path") || return 1
        [[ $mount_real == "$mount_path" ]] || { warn "Peer $name 的路径需要重新输入为规范的实际路径。"; return 1; }
        for existing_mount in "${!seen_mounts[@]}"; do
            if [[ $mount_real == "$existing_mount" || $mount_real == "$existing_mount"/* || $existing_mount == "$mount_real"/* ]]; then
                warn "Peer $name 的挂载目录与其他 Peer 重复或互相嵌套。"
                return 1
            fi
        done
        seen_names[$name]=1
        seen_ips[$peer_ip]=1
        seen_keys[$public_key]=1
        seen_mounts[$mount_real]=1
    done < "$NEW_PEERS_FILE"
}

unmount_changed_peers() {
    local name peer_ip public_key endpoint mount_path unit suffix
    [[ -s $PEERS_FILE ]] || return 0
    while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
        [[ -n ${name:-} ]] || continue
        if awk -F'|' -v ip="$peer_ip" -v key="$public_key" -v ep="$endpoint" -v path="$mount_path" \
            '$2 == ip && $3 == key && $4 == ep && $5 == path {found=1} END {exit !found}' "$NEW_PEERS_FILE"; then
            continue
        fi
        "$RUNTIME_DIR/mounts" --check-old "$mount_path" "$peer_ip" || die "旧路径 $mount_path 的实际挂载不是该 Peer 的预期 NFS；未自动卸载。"
        for suffix in automount mount; do
            unit=$(systemd-escape --path --suffix="$suffix" "$mount_path")
            if [[ $(systemctl show --property=LoadState --value "$unit") != not-found ]]; then
                timeout -k 5s 35s systemctl stop "$unit" || die "停止 $unit 失败；Peer 清单尚未替换。"
            fi
        done
        "$RUNTIME_DIR/mounts" --absent "$mount_path" || die "$mount_path 仍存在挂载；Peer 清单尚未替换。"
        unit=$(systemd-escape --path --suffix=automount "$mount_path")
        if [[ -f /etc/systemd/system/${unit}.d/nfs-wg-manager.conf ]] && grep -qF "$MANAGED_MARKER" "/etc/systemd/system/${unit}.d/nfs-wg-manager.conf"; then
            rm -f -- "/etc/systemd/system/${unit}.d/nfs-wg-manager.conf"
            rmdir "/etc/systemd/system/${unit}.d" 2>/dev/null || true
        fi
        info "已停止移除或变更的挂载：$mount_path"
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

install_mount_support() {
    write_managed_file "$RUNTIME_DIR/mounts" 0755 <<'NWM_MOUNTS_PY'
#!/usr/bin/python3
# Managed by NFS_Wireguard_Manager
"""Prepare mount propagation and reconcile host NFS mounts without walking NFS."""
import fcntl
import ipaddress
import json
import pathlib
import subprocess
import sys
import time

STATE = pathlib.Path('/etc/nfs-wg-manager')
# This service runs before local-fs.target and /run/lock creation by tmpfiles.
LOCK = '/run/nfs-wg-manager-mounts.lock'


def run(argv, check=True):
    p = subprocess.run(argv, text=True, capture_output=True)
    if check and p.returncode:
        raise RuntimeError(' '.join(argv[:3]) + ': ' + p.stderr.strip())
    return p.stdout.strip()


def records():
    # No pathname canonicalization or stat: a hard NFS outage must not hang checks.
    return json.loads(run(['findmnt', '--kernel', '--list', '--json', '--nocanonicalize',
                          '--output', 'TARGET,SOURCE,FSTYPE,OPTIONS,PROPAGATION']))['filesystems']


def at(path, rows):
    matches = [r for r in rows if r['target'] == path]
    return matches[-1] if matches else None


def matches(row, address):
    if not row or row['fstype'] != 'nfs4' or row['source'] != address + ':/':
        return False
    options = set(row.get('options', '').split(','))
    return {'ro', 'vers=4.1', 'proto=tcp', 'port=8388'} <= options


def settings():
    node = dict(line.split('=', 1) for line in (STATE / 'node.conf').read_text().splitlines() if '=' in line)
    if node.get('ROLE') != 'client':
        raise ValueError('需要客户端节点配置。')
    root = node['MEDIA_ROOT']
    if root == '/' or not root.startswith('/') or str(pathlib.PurePosixPath(root)) != root or '..' in pathlib.PurePosixPath(root).parts:
        raise ValueError('媒体根目录必须是规范的绝对目录，且不能是 /。')
    peers = []
    for line in (STATE / 'client-peers.tsv').read_text().splitlines():
        if not line:
            continue
        fields = line.split('|')
        if len(fields) != 5 or not fields[4].startswith(root + '/') or '..' in pathlib.PurePosixPath(fields[4]).parts:
            raise ValueError('Peer 挂载路径或字段错误。')
        ipaddress.IPv4Address(fields[1])
        peers.append((fields[0], fields[1], fields[4]))
    return root, peers


def prepare(root):
    rows = records()
    current = at(root, rows)
    parent = current or max((r for r in rows if root.startswith(r['target'].rstrip('/') + '/')),
                            key=lambda r: len(r['target']))
    if parent['fstype'] in ('nfs', 'nfs4', 'autofs', 'cifs', 'smb3', 'fuse.sshfs'):
        raise RuntimeError('媒体根目录本身必须位于本地文件系统。')
    if not current:
        children = [r for r in rows if r['target'].startswith(root + '/')]
        if children:
            if 'shared' in parent.get('propagation', '').split(','):
                return  # Existing shared parent already propagates these submounts.
            raise RuntimeError('媒体根目录已有子挂载且父挂载未共享；请先停止子挂载，再重新运行安装器。')
        run(['mount', '--bind', '--', root, root])
    run(['mount', '--make-rshared', '--', root])


def reconcile(peers, wait=False):
    rows = records()
    errors = []
    for name, address, path in peers:
        row = at(path, rows)
        if matches(row, address):
            continue
        if row and row['fstype'] != 'autofs':
            errors.append(name + ' 的现有挂载来源、类型或选项不符；未自动卸载。')
            continue
        unit = run(['systemd-escape', '--path', '--suffix=mount', path])
        status = run(['systemctl', 'show', '--property=ActiveState', '--value', unit], check=False)
        if status in ('activating', 'deactivating'):
            continue
        try:
            run(['systemctl', 'reset-failed', unit], check=False)
            run(['systemctl', 'start', '--no-block', unit])
        except RuntimeError as exc:
            errors.append(name + ': ' + str(exc))
    deadline = time.monotonic() + (35 if wait else 0)
    while True:
        rows = records()
        active = sum(matches(at(path, rows), address) for _, address, path in peers)
        if active == len(peers) or time.monotonic() >= deadline:
            break
        time.sleep(1)
    for error in errors:
        print(error, file=sys.stderr)
    print('NFS 挂载就绪：%s/%s；未就绪的节点会在后续周期重试。' % (active, len(peers)))
    return 1 if errors else 0


def main():
    args = sys.argv[1:]
    if len(args) == 3 and args[0] in ('--verify', '--check-old'):
        row = at(args[1], records())
        okay = matches(row, str(ipaddress.IPv4Address(args[2])))
        if args[0] == '--check-old' and (not row or row['fstype'] == 'autofs'):
            okay = True
        return 0 if okay else 1
    if len(args) == 2 and args[0] == '--absent':
        return 0 if at(args[1], records()) is None else 1
    if args not in (['--prepare'], ['--reconcile'], ['--reconcile', '--wait']):
        raise ValueError('用法：mounts --prepare | --reconcile [--wait]')
    with open(LOCK, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        root, peers = settings()
        if args == ['--prepare']:
            prepare(root)
            return 0
        return reconcile(peers, '--wait' in args)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError) as exc:
        print('NFS 挂载错误：' + str(exc), file=sys.stderr)
        sys.exit(1)
NWM_MOUNTS_PY
    write_managed_file /etc/systemd/system/nfs-wg-media-root.service <<EOF
$MANAGED_MARKER
[Unit]
Description=Prepare shared Jellyfin media root
DefaultDependencies=no
After=local-fs-pre.target
Before=local-fs.target docker.service shutdown.target
Conflicts=shutdown.target
RequiresMountsFor=$MEDIA_ROOT $RUNTIME_DIR /usr/bin/python3
[Service]
Type=oneshot
ExecStart=$RUNTIME_DIR/mounts --prepare
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    write_managed_file /etc/systemd/system/nfs-wg-mounts.service <<EOF
$MANAGED_MARKER
[Unit]
Description=Reconcile NFS mounts for Jellyfin
Requires=nfs-wg-media-root.service wg-quick@wg0.service nfs-wg-firewall.service
After=nfs-wg-media-root.service wg-quick@wg0.service nfs-wg-firewall.service
[Service]
Type=oneshot
ExecStart=$RUNTIME_DIR/mounts --reconcile
TimeoutStartSec=45s
EOF
    write_managed_file /etc/systemd/system/nfs-wg-mounts.timer <<EOF
$MANAGED_MARKER
[Unit]
Description=Retry missing Jellyfin NFS mounts
[Timer]
OnBootSec=30s
OnUnitInactiveSec=30s
AccuracySec=5s
Unit=nfs-wg-mounts.service
[Install]
WantedBy=timers.target
EOF
}

write_fstab() {
    local block name peer_ip public_key endpoint mount_path auto_unit
    block="$FSTAB_BEGIN"
    if [[ -s $PEERS_FILE ]]; then
        while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
            [[ -n ${name:-} ]] || continue
            if "$RUNTIME_DIR/mounts" --absent "$mount_path"; then
                [[ -d $mount_path ]] || install -d -m 0755 "$mount_path"
            fi
            auto_unit=$(systemd-escape --path --suffix=automount "$mount_path")
            write_managed_file "/etc/systemd/system/${auto_unit}.d/nfs-wg-manager.conf" <<EOF
$MANAGED_MARKER
[Unit]
Requires=nfs-wg-media-root.service
After=nfs-wg-media-root.service
EOF
            block+=$'\n'
            block+="# ${name}"
            block+=$'\n'
            block+="${peer_ip}:/ ${mount_path} nfs4 ro,vers=4.1,proto=tcp,port=${NFS_PORT},_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30s,x-systemd.requires=wg-quick@wg0.service,x-systemd.requires=nfs-wg-firewall.service,x-systemd.requires=nfs-wg-media-root.service,hard,timeo=600,retrans=2,nosuid,nodev 0 0"
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
Wants=nfs-wg-media-root.service wg-quick@${WG_INTERFACE}.service${mount_units}
After=network-online.target nfs-wg-media-root.service wg-quick@${WG_INTERFACE}.service${mount_units}
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

stop_mount_recovery() {
    local unit load_state
    for unit in nfs-wg-mounts.timer nfs-wg-mounts.service; do
        load_state=$(systemctl show --property=LoadState --value "$unit") || {
            [[ $load_state == not-found ]] || die "读取 $unit 状态失败。"
        }
        [[ $load_state != not-found ]] || continue
        systemctl stop "$unit" || die "停止 $unit 失败；Peer 清单尚未替换。"
    done
}

activate_nfs_mount() {
    "$RUNTIME_DIR/mounts" --verify "$1" "$2"
}

mount_configured_peers() {
    local name peer_ip public_key endpoint mount_path
    ACTIVE_MOUNTS=0
    "$RUNTIME_DIR/mounts" --reconcile --wait || warn "部分挂载存在冲突，请按上方错误处理。"
    while IFS='|' read -r name peer_ip public_key endpoint mount_path; do
        [[ -n ${name:-} ]] || continue
        if activate_nfs_mount "$mount_path" "$peer_ip"; then
            info "已确认 NFS 挂载：${name} -> ${mount_path}"
            ACTIVE_MOUNTS=$((ACTIVE_MOUNTS + 1))
        else
            warn "${name} 尚未就绪；检查公网 UDP 放行、双方公钥和 NFS 服务。恢复任务会继续重试。"
        fi
    done < "$PEERS_FILE"
}

maybe_restart_jellyfin() {
    local state mapping propagation
    command -v docker >/dev/null 2>&1 || return 0
    docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || return 0
    mapping=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/media"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME")
    [[ $mapping == "$MEDIA_ROOT" ]] || { warn "容器 /media 来源与媒体根目录不符，请先修正卷映射。"; return 0; }
    propagation=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/media"}}{{.Propagation}}{{end}}{{end}}' "$CONTAINER_NAME")
    if [[ $propagation == rslave || $propagation == rshared ]]; then
        info "容器已启用递归挂载传播，NFS 补挂后无需重启容器；媒体入库仍需扫描。"
        return 0
    fi
    warn "容器 /media 使用 ${propagation:-未知}，后续补挂不能保证自动可见。请保留原容器参数，将该卷改为 :rslave 后重新创建容器；脚本不会自动重建。"
    [[ $ACTIVE_MOUNTS -gt 0 ]] || return 0
    state=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
    if [[ $state == running ]]; then
        docker restart "$CONTAINER_NAME" >/dev/null || { warn "重启容器失败，请手工执行 docker restart $CONTAINER_NAME。"; return 0; }
        info "已重启容器以接收本次成功挂载；这不等于已获得后续自动挂载传播能力。"
    fi
}

install_packages() {
    info "安装 wireguard、nfs-common、nftables 和 python3..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard nfs-common nftables python3
}

main() {
    local current
    if [[ ${1:-} == --apply-firewall && $# == 1 ]]; then
        apply_saved_firewall
        return
    fi
    (($# == 0)) || die "未知参数；请使用 --help。"
    install_packages
    ensure_manager_wg_config
    local saved_role
    saved_role=$(state_get ROLE "$NODE_FILE" || true)
    [[ -z $saved_role || $saved_role == "$ROLE" ]] || die "同一机器不能混用本工程的服务端与客户端角色。"

    current=$(state_get NODE_NAME "$NODE_FILE" || true)
    NODE_NAME=$(prompt "本机节点名称（Jellyfin 客户端示例：hhost_jf）" "${current:-hhost_jf}")
    valid_name "$NODE_NAME" || die "节点名称无效。"

    current=$(state_get WG_ADDRESS "$NODE_FILE" || true)
    WG_ADDRESS=$(prompt "本机 WireGuard IPv4 地址（Jellyfin 客户端示例：10.96.0.1）" "${current:-10.96.0.1}")
    valid_ipv4 "$WG_ADDRESS" || die "WireGuard IPv4 地址无效。"

    current=$(state_get WG_SUBNET "$NODE_FILE" || true)
    WG_SUBNET=$(prompt "WireGuard 网段" "${current:-$WG_DEFAULT_SUBNET}")
    valid_cidr "$WG_SUBNET" || die "WireGuard 网段必须是 IPv4 CIDR，例如 10.96.0.0/16。"
    ipv4_in_cidr "$WG_ADDRESS" "$WG_SUBNET" || die "本机 WireGuard 地址不在网段 $WG_SUBNET 内。"

    current=$(state_get WG_LISTEN_PORT "$NODE_FILE" || true)
    WG_LISTEN_PORT=$(prompt "WireGuard UDP 监听端口" "${current:-$WG_DEFAULT_PORT}")
    valid_port "$WG_LISTEN_PORT" || die "WireGuard 端口无效。"

    current=$(state_get MEDIA_ROOT "$NODE_FILE" || true)
    while :; do
        MEDIA_ROOT=$(prompt "Jellyfin 宿主机媒体根目录" "${current:-$DEFAULT_MEDIA_ROOT}")
        if MEDIA_ROOT=$(normalize_abs_path "$MEDIA_ROOT") && MEDIA_ROOT=$(realpath -m -- "$MEDIA_ROOT") && MEDIA_ROOT=$(normalize_abs_path "$MEDIA_ROOT") && [[ $MEDIA_ROOT != / ]]; then
            break
        fi
        warn "媒体根目录必须是无空格、无路径穿越的绝对路径。请重新输入。"
        current=""
    done
    [[ -d $MEDIA_ROOT ]] || install -d -m 0755 "$MEDIA_ROOT"

    current=$(state_get CONTAINER_NAME "$NODE_FILE" || true)
    CONTAINER_NAME=$(prompt "Jellyfin Docker 容器名" "${current:-$DEFAULT_CONTAINER}")
    valid_name "$CONTAINER_NAME" || die "容器名无效。"

    collect_peers
    validate_peer_file
    load_or_create_key
    install_firewall_support
    install_mount_support
    # Stop the reconciler before changing its authoritative Peer list.
    stop_mount_recovery
    unmount_changed_peers
    mv -f "$NEW_PEERS_FILE" "$PEERS_FILE"
    chmod 0600 "$PEERS_FILE"
    save_node_state
    write_wg_config
    write_fstab
    write_docker_ordering

    start_firewall
    systemctl enable nfs-wg-media-root.service >/dev/null
    systemctl restart nfs-wg-media-root.service
    start_wireguard
    mount_configured_peers
    maybe_restart_jellyfin
    systemctl enable --now nfs-wg-mounts.timer >/dev/null

    printf '\n本机节点：%s\n' "$NODE_NAME"
    printf 'WireGuard 地址：%s\n' "$WG_ADDRESS"
    printf 'WireGuard 公钥：%s\n' "$PUBLIC_KEY"
    printf 'WireGuard 端口：%s/udp\n' "$WG_LISTEN_PORT"
    printf 'NFS 服务端口：%s/tcp\n' "$NFS_PORT"
    printf '活跃 NFS 挂载：%s\n' "$ACTIVE_MOUNTS"
    printf '\n下一步：确认每个 NFS Server 已登记本机 WireGuard 公钥；若首次安装时已填写，无需再次添加。公网 UDP 放行由你负责，隧道内 TCP 8388 已自动管理。检查 wg show、findmnt 和容器内目录，再扫描媒体库。\n'
}

main "$@"
