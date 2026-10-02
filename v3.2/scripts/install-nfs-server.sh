#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="3.2.0"
readonly ROLE="server"
readonly RUNTIME_DIR="/usr/local/libexec/nfs-wg-manager"
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
ADD_CLIENT_PEER_MODE=0
APPLY_FIREWALL_MODE=0
FORCE_MODE=0
ADD_PEER_ROLLBACK=0
ADD_PEER_ROUTE_ADDED=0
ADD_PEER_ADDRESS=""
ADD_PEER_BACKUP_DIR=""
ADD_PEER_WG_STAGE=""
ADD_PEER_EXPORTS_STAGE=""
ADD_PEER_SYNC_FILE=""

for arg in "$@"; do
    case "$arg" in
        --add-client-peer) ADD_CLIENT_PEER_MODE=1 ;;
        --apply-firewall) APPLY_FIREWALL_MODE=1 ;;
        --force) FORCE_MODE=1 ;;
    esac
done

cleanup() {
    if (( ADD_PEER_ROLLBACK )); then
        rollback_client_peer_update
    fi
    if [[ -n ${NEW_PEERS_FILE:-} && -e $NEW_PEERS_FILE ]]; then
        rm -f -- "$NEW_PEERS_FILE"
    fi
    [[ -z ${ADD_PEER_WG_STAGE:-} ]] || rm -f -- "$ADD_PEER_WG_STAGE"
    if [[ -n ${ADD_PEER_EXPORTS_STAGE:-} ]]; then
        rm -f -- "$ADD_PEER_EXPORTS_STAGE" "${ADD_PEER_EXPORTS_STAGE}.nfs-wg-manager.bak"
    fi
    [[ -z ${ADD_PEER_SYNC_FILE:-} ]] || rm -f -- "$ADD_PEER_SYNC_FILE"
    if [[ -n ${ADD_PEER_BACKUP_DIR:-} && -d $ADD_PEER_BACKUP_DIR ]]; then
        rm -rf -- "$ADD_PEER_BACKUP_DIR"
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
用法：sudo bash install-nfs-server.sh [--force]

脚本会交互式安装 WireGuard/NFS 服务端，并将输入的媒体目录以 NFSv4 根导出。
首次安装可隐藏粘贴本机离线私钥；直接回车则自动生成。默认媒体目录为 /srv/media。

恢复隧道内防火墙规则：sudo bash install-nfs-server.sh --apply-firewall [--force]
公网 UDP 端口需自行放行；脚本仅管理 wg0 上的 NFS TCP 8388。

已安装服务端后新增 Jellyfin 客户端 Peer：
  sudo bash install-nfs-server.sh --add-client-peer [--force] \
    --peer-name hhost_jf --peer-address 10.96.0.1 \
    --public-key-file /root/hhost_jf.pub

公钥文件必须只有一行 WireGuard 公钥。私钥必须留在客户端机器上。
请传入客户端用 wg pubkey 派生的 .pub 文件，不要传 wg0.key；公钥和私钥编码相同，程序无法仅凭内容辨认误传的私钥。
EOF
}

for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        --version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    esac
done

[[ $EUID -eq 0 ]] || die "请使用 root 运行此脚本。"
[[ -r /etc/os-release ]] || die "找不到 /etc/os-release。"
if (( ! ADD_CLIENT_PEER_MODE && ! APPLY_FIREWALL_MODE )); then
    [[ -r /dev/tty ]] || die "需要交互终端；请直接在 VPS 上运行，或使用 curl | sudo bash。"
fi

# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian ]] || die "v3.2 仅支持 Debian stable，当前系统为 ${PRETTY_NAME:-unknown}。"

if (( ADD_CLIENT_PEER_MODE || APPLY_FIREWALL_MODE )); then
    [[ -d $STATE_DIR ]] || die "尚未安装 NFS_Wireguard_Manager NFS 服务端。"
else
    command -v apt-get >/dev/null 2>&1 || die "找不到 apt-get。"
    command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl。"
fi

if (( ADD_CLIENT_PEER_MODE || APPLY_FIREWALL_MODE )); then
    [[ -d $WG_DIR ]] || die "找不到 WireGuard 配置目录；请先完成 NFS Server 安装。"
else
    mkdir -p "$STATE_DIR" "$WG_DIR" "$NFS_CONF_DIR"
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

valid_abs_path() {
    local path=$1
    local normalized
    normalized=$(normalize_abs_path "$path") || return 1
    [[ $normalized == "$path" ]]
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
        if grep -qF "$begin" "$file" && ! grep -qF "$end" "$file" && (( ! FORCE_MODE )); then
            rm -f "$tmp"
            die "$file 中发现不完整的 NFS_Wireguard_Manager 配置块；请手工修复或使用 --force。"
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
    if [[ -f $WG_CONFIG ]] && ! grep -qF "$MANAGED_MARKER" "$WG_CONFIG" && (( ! FORCE_MODE )); then
        die "$WG_CONFIG 已存在且不是本工具生成的文件；请使用 --force 覆盖。"
    fi
}

load_or_create_key() {
    local key_tmp=""
    local save_key=0
    if [[ -s $WG_KEY_FILE ]]; then
        PRIVATE_KEY=$(<"$WG_KEY_FILE")
    elif [[ -f $WG_CONFIG ]]; then
        PRIVATE_KEY=$(awk -F'= ' '/^[[:space:]]*PrivateKey[[:space:]]*=/ {print $2; exit}' "$WG_CONFIG")
        if [[ -n $PRIVATE_KEY ]]; then
            save_key=1
        elif (( ! FORCE_MODE )); then
            die "无法从现有 WireGuard 配置恢复私钥；请使用 --force 覆盖。"
        fi
    fi
    if [[ -z $PRIVATE_KEY ]]; then
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
    if [[ -e $output ]] && ! grep -qF "$MANAGED_MARKER" "$output" && (( ! FORCE_MODE )); then
        die "$output 已存在且不是本工具生成的文件；请使用 --force 覆盖。"
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
"""Reconcile IPv4 NFS-over-WireGuard rules without owning external firewalls."""
import fcntl
import ipaddress
import json
import pathlib
import re
import shlex
import shutil
import subprocess
import sys

STATE = pathlib.Path('/etc/nfs-wg-manager')
LOCK = '/run/nfs-wg-manager-firewall.lock'
TABLE = 'nfs_wg_manager'
NATIVE_TABLE = 'filter'
MARK = 'nfs-wg-manager:'
NFS_PORT = '8388'


def run(argv, data=None, check=True):
    p = subprocess.run(argv, input=data, text=True, capture_output=True)
    if check and p.returncode:
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
            match(packet('tcp', 'dport' if request else 'sport'), int(NFS_PORT))]
    if not request:
        expr.append(match({'ct': {'key': 'state'}}, {'set': ['established', 'related']}))
    return expr + [{'counter': None}, {'accept': None}]


def table_objects(objects, family, name):
    return [o for o in objects if any(isinstance(v, dict) and v.get('family') == family
                                      and ((k == 'table' and v.get('name') == name) or
                                           (k != 'table' and v.get('table') == name))
                                      for k, v in o.items())]


def validate_own_table(objects):
    own = table_objects(objects, 'inet', TABLE)
    if not own:
        return []
    own_chains = [o['chain'] for o in own if 'chain' in o]
    if {c.get('name') for c in own_chains} != {'input', 'output'}:
        raise ValueError('保留表名 nfs_wg_manager 已被其他规则占用。')
    for o in own:
        if 'chain' in o:
            c = o['chain']
            if (c.get('hook') != c.get('name') or c.get('type') != 'filter'
                    or c.get('policy') != 'accept' or c.get('prio') != -10):
                raise ValueError('本工程防火墙表的结构已被修改。')
        elif 'rule' in o:
            if not o['rule'].get('comment', '').startswith(MARK):
                raise ValueError('本工程防火墙表含有外部规则，停止更新。')
        elif 'table' not in o:
            raise ValueError('本工程防火墙表含有外部对象，停止更新。')
    return own


def native_filter_targets(objects, compat):
    if ('inet', NATIVE_TABLE) in compat:
        raise ValueError('inet filter 由 iptables 兼容层管理，必须保留原生 nftables 管理。')
    chains = [o['chain'] for o in objects if 'chain' in o and o['chain'].get('family') == 'inet'
              and o['chain'].get('table') == NATIVE_TABLE]
    targets = []
    for direction in ('input', 'output'):
        matches = [c for c in chains if c.get('name') == direction and c.get('hook') == direction
                   and c.get('type') == 'filter']
        if len(matches) > 1:
            raise ValueError('inet filter/%s 存在重复原生基链。' % direction)
        if matches:
            c = matches[0]
            targets.append(c)
    if not chains:
        raise ValueError('找不到原生 inet filter 表；请先创建 input/output 基链。')
    if len(targets) != 2:
        missing = sorted({'input', 'output'} - {c['name'] for c in targets})
        raise ValueError('inet filter 缺少原生 input/output 链：' + ','.join(missing))
    return targets


def transaction(snapshot, role, address, peers, compat=()):
    objects = snapshot['nftables']
    rules = [o['rule'] for o in objects if 'rule' in o]
    own = validate_own_table(objects)
    targets = native_filter_targets(objects, compat)
    for c in targets:
        members = [r for r in rules if all(r.get(k) == c.get(k) for k in ('family', 'table'))
                   and r.get('chain') == c.get('name')]
        if any('ufw' in str(x).lower() or 'firewalld' in str(x).lower()
               for x in (c.get('name'), members)):
            raise ValueError('检测到 UFW/firewalld 托管规则，请使用原生 nftables 主机过滤规则。')
    commands = []
    for r in rules:
        if (r.get('comment', '').startswith(MARK) and r.get('family') == 'inet'
                and r.get('table') == NATIVE_TABLE):
            commands.append({'delete': {'rule': {k: r[k] for k in ('family', 'table', 'chain', 'handle')}}})
    if own:
        commands.append({'delete': {'table': {'family': 'inet', 'name': TABLE}}})
    commands.append({'add': {'table': {'family': 'inet', 'name': TABLE}}})
    for direction in ('input', 'output'):
        commands.append({'add': {'chain': {'family': 'inet', 'table': TABLE, 'name': direction,
                         'type': 'filter', 'hook': direction, 'prio': -10, 'policy': 'accept'}}})
        if peers:
            own_rule = {'family': 'inet', 'table': TABLE, 'chain': direction,
                        'expr': flow(role, address, peers, direction),
                        'comment': MARK + role + ':' + direction}
            commands.append({'add': {'rule': own_rule}})
            for c in targets:
                if c.get('hook') != direction:
                    continue
                rule = dict(family='inet', table=NATIVE_TABLE, chain=c['name'],
                            expr=flow(role, address, peers, direction),
                            comment=MARK + role + ':' + direction)
                commands.append({'insert': {'rule': rule}})
    if role == 'server':
        commands.append({'add': {'rule': {'family': 'inet', 'table': TABLE, 'chain': 'input',
            'expr': [match({'meta': {'key': 'l4proto'}}, 'tcp'),
                     match(packet('tcp', 'dport'), int(NFS_PORT)),
                     {'counter': None}, {'drop': None}],
            'comment': MARK + 'deny-other-nfs'}}})
    return {'nftables': commands}


def compat_tables(text):
    return set(re.findall(r'table\s+(ip6?|inet)\s+(\S+)\s+is managed by iptables', text))


def comment_from_tokens(tokens):
    try:
        return tokens[tokens.index('--comment') + 1]
    except (ValueError, IndexError):
        return ''


def iptables_specs(role, address, peers):
    specs = []
    for peer in peers:
        tag = '%s%s:%s:%s' % (MARK, role, '%s', peer)
        if role == 'server':
            specs.append(('INPUT', ['-i', 'wg0', '-s', peer, '-d', address, '-p', 'tcp',
                                    '--dport', NFS_PORT, '-m', 'comment', '--comment', tag % 'input',
                                    '-j', 'ACCEPT']))
            specs.append(('OUTPUT', ['-o', 'wg0', '-s', address, '-d', peer, '-p', 'tcp',
                                     '--sport', NFS_PORT, '-m', 'conntrack', '--ctstate', 'ESTABLISHED,RELATED',
                                     '-m', 'comment', '--comment', tag % 'output', '-j', 'ACCEPT']))
        else:
            specs.append(('OUTPUT', ['-o', 'wg0', '-s', address, '-d', peer, '-p', 'tcp',
                                     '--dport', NFS_PORT, '-m', 'comment', '--comment', tag % 'output',
                                     '-j', 'ACCEPT']))
            specs.append(('INPUT', ['-i', 'wg0', '-s', peer, '-d', address, '-p', 'tcp',
                                    '--sport', NFS_PORT, '-m', 'conntrack', '--ctstate', 'ESTABLISHED,RELATED',
                                    '-m', 'comment', '--comment', tag % 'input', '-j', 'ACCEPT']))
    return specs


def external_state(binary):
    if not shutil.which(binary):
        raise RuntimeError('%s 不存在，但检测到 iptables-managed IPv4 filter 表。' % binary)
    p = run([binary, '-t', 'filter', '-S'], check=False)
    if p.returncode:
        raise RuntimeError('%s 无法读取 filter 规则：%s' % (binary, p.stderr.strip()))
    chains = set()
    own = []
    for line in p.stdout.splitlines():
        tokens = shlex.split(line)
        if len(tokens) >= 2 and tokens[0] in ('-P', '-N', '-A'):
            chain = tokens[1]
            chains.add(chain)
            if tokens[0] == '-A' and chain in ('INPUT', 'OUTPUT') and comment_from_tokens(tokens).startswith(MARK):
                own.append((chain, tokens[2:]))
    return chains, own


def external_snapshot(binary):
    return external_state(binary)[1]


def iptables_command(binary, action, chain, rule):
    args = [binary, '-t', 'filter', action, chain]
    if action == '-I':
        args.append('1')
    args.extend(rule)
    return args


def restore_external(binary, rules):
    for chain, rule in external_snapshot(binary):
        run(iptables_command(binary, '-D', chain, rule), check=False)
    for chain, rule in rules:
        run(iptables_command(binary, '-I', chain, rule), check=False)


def reconcile_external(role, address, peers, compat, check_only=False):
    if ('ip', 'filter') not in compat:
        if ('ip6', 'filter') in compat:
            print('信息：检测到 ip6 filter 由 iptables 管理；当前工具仅使用 IPv4，保留该表。')
        return []
    binary = 'iptables'
    chains, old = external_state(binary)
    desired = [spec for spec in iptables_specs(role, address, peers) if spec[0] in chains]
    if check_only:
        return old
    removed = []
    added = []
    try:
        for chain, rule in old:
            removed.append((chain, rule))
            run(iptables_command(binary, '-D', chain, rule))
        for chain, rule in desired:
            run(iptables_command(binary, '-I', chain, rule))
            added.append((chain, rule))
    except (OSError, RuntimeError):
        for chain, rule in added:
            run(iptables_command(binary, '-D', chain, rule), check=False)
        restore_external(binary, removed)
        raise
    if ('ip6', 'filter') in compat:
        print('信息：检测到 ip6 filter 由 iptables 管理；当前工具仅使用 IPv4，保留该表。')
    return removed


def main():
    if sys.argv[1:] not in ([], ['--check']):
        raise ValueError('用法：firewall [--check]')
    check_only = sys.argv[1:] == ['--check']
    with open(LOCK, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        p = run(['nft', '-j', 'list', 'ruleset'])
        plain = run(['nft', 'list', 'ruleset'])
        compat = compat_tables(p.stderr + plain.stderr + plain.stdout)
        role, address, peers = settings()
        data = json.dumps(transaction(json.loads(p.stdout), role, address, peers, compat=compat))
        run(['nft', '-j', '-c', '-f', '-'], data)
        if check_only:
            reconcile_external(role, address, peers, compat, check_only=True)
            return
        old_external = reconcile_external(role, address, peers, compat, check_only=False)
        try:
            run(['nft', '-j', '-f', '-'], data)
        except (OSError, RuntimeError):
            if ('ip', 'filter') in compat:
                restore_external('iptables', old_external)
            raise


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
    systemctl cat nfs-wg-firewall.service >/dev/null 2>&1 || die "nfs-wg-firewall.service 未正确安装。"
    systemctl cat nftables.service >/dev/null 2>&1 || die "nftables.service drop-in 未正确加载。"
    systemctl cat wg-quick@wg0.service >/dev/null 2>&1 || die "wg-quick@wg0.service drop-in 未正确加载。"
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

collect_peers() {
    local name peer_ip public_key old_ip old_key
    NEW_PEERS_FILE=$(mktemp "${STATE_DIR}/server-peers.XXXXXX")
    chmod 0600 "$NEW_PEERS_FILE"

    if [[ -s $PEERS_FILE ]] && confirm "保留当前 Jellyfin 客户端 Peer 清单？重新输入请选择 n" "Y"; then
        cp -f "$PEERS_FILE" "$NEW_PEERS_FILE"
        if validate_peer_file; then
            return 0
        fi
        confirm "当前 Jellyfin Peer 清单字段无效或重复；是否重新输入完整清单？" "Y" || die "未更改不合规的 Peer 清单。"
    fi

    : > "$NEW_PEERS_FILE"
    while :; do
        while :; do
            name=$(prompt "Jellyfin 客户端 Peer 名称（填写客户端节点名，例如 hhost_jf；留空结束）" "")
            [[ -z $name ]] && return 0
            valid_name "$name" || { warn "名称只能包含字母、数字、点、下划线和短横线。请重新输入 Peer 名称。"; continue; }
            [[ $name != "$NODE_NAME" ]] || { warn "Peer 名称不能与本机相同。请重新输入 Peer 名称。"; continue; }
            peer_exists_in_file "$NEW_PEERS_FILE" "$name" && { warn "Peer 名称重复。请重新输入 Peer 名称。"; continue; }
            break
        done

        old_ip=$(old_peer_field "$name" 2 || true)
        old_key=$(old_peer_field "$name" 3 || true)
        while :; do
            peer_ip=$(prompt "Jellyfin 客户端 ${name} 的 WireGuard IPv4 地址（例如 10.96.0.1）" "${old_ip:-10.96.0.1}")
            if valid_ipv4 "$peer_ip" && ipv4_in_cidr "$peer_ip" "$WG_SUBNET" && [[ $peer_ip != "$WG_ADDRESS" ]] && ! peer_ip_exists_in_file "$NEW_PEERS_FILE" "$peer_ip"; then
                break
            fi
            warn "IPv4 地址无效、超出 WireGuard 网段、与本机冲突或已被使用。请重新输入 ${name} 的地址。"
        done

        while :; do
            public_key=$(prompt "Jellyfin 客户端 ${name} 输出的 WireGuard 公钥（一行 44 字符，不是名称或 IP）" "$old_key")
            if valid_key "$public_key" && ! peer_key_exists_in_file "$NEW_PEERS_FILE" "$public_key"; then
                break
            fi
            warn "WireGuard 公钥格式无效或已被使用。请重新输入 ${name} 的公钥。"
        done
        printf '%s|%s|%s\n' "$name" "$peer_ip" "$public_key" >> "$NEW_PEERS_FILE"
    done
}

validate_peer_file() {
    local name peer_ip public_key
    local -A seen_names=() seen_ips=() seen_keys=()
    [[ -f $NEW_PEERS_FILE ]] || return 0
    while IFS='|' read -r name peer_ip public_key; do
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
        seen_names[$name]=1
        seen_ips[$peer_ip]=1
        seen_keys[$public_key]=1
    done < "$NEW_PEERS_FILE"
}

write_wg_config() {
    local output=${1:-$WG_CONFIG}
    local peers_file=${2:-$PEERS_FILE}
    local tmp name peer_ip public_key
    tmp=$(mktemp "${output}.XXXXXX")
    {
        printf '%s\n' "$MANAGED_MARKER"
        printf '# Node: %s\n' "$NODE_NAME"
        printf '[Interface]\n'
        printf 'Address = %s/32\n' "$WG_ADDRESS"
        printf 'ListenPort = %s\n' "$WG_LISTEN_PORT"
        printf 'PrivateKey = %s\n' "$PRIVATE_KEY"
        if [[ -s $peers_file ]]; then
            while IFS='|' read -r name peer_ip public_key; do
                [[ -n ${name:-} ]] || continue
                printf '\n[Peer]\n'
                printf '# %s\n' "$name"
                printf 'PublicKey = %s\n' "$public_key"
                printf 'AllowedIPs = %s/32\n' "$peer_ip"
            done < "$peers_file"
        fi
    } > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$output"
}

write_nfs_config() {
    write_managed_file "$NFS_CONF_FILE" <<EOF
$MANAGED_MARKER
[nfsd]
port = ${NFS_PORT}
tcp = yes
udp = no
vers2 = no
vers3 = no
vers4 = yes
vers4.0 = no
vers4.1 = yes
vers4.2 = no
rdma = no
EOF
    find_nfs_service
    write_managed_file "/etc/systemd/system/${NFS_SERVICE}.service.d/nfs-wg-manager.conf" <<EOF
$MANAGED_MARKER
[Unit]
Requires=wg-quick@wg0.service nfs-wg-firewall.service
After=wg-quick@wg0.service nfs-wg-firewall.service
EOF
}

verify_nfs_service() {
    local versions listeners
    [[ -r /proc/fs/nfsd/versions ]] || die "NFS 内核服务未运行。"
    versions=" $(cat /proc/fs/nfsd/versions) "
    [[ $versions == *" +4.1 "* && $versions != *" +2 "* && $versions != *" +3 "* && $versions != *" +4.2 "* ]] || die "NFS 协议限制未生效：$versions"
    [[ $versions == *" -4.0 "* || $versions == *" -4 "* ]] || die "NFSv4.0 尚未关闭：$versions"
    [[ -r /proc/fs/nfsd/portlist ]] || die "无法读取 NFS 内核监听端口。"
    awk 'NF { if ($1 !~ /^tcp6?$/ || $2 != 8388) bad=1; found=1 } END { exit (bad || !found) }' /proc/fs/nfsd/portlist || die "NFS 内核监听端口或传输协议与 TCP 8388 不符。"
    listeners=$(ss -H -lnt 'sport = :8388')
    [[ -n $listeners ]] || die "NFS 未监听 TCP 8388；请检查 nfsd 配置是否生效。"
    [[ -z $(ss -H -lnt 'sport = :2049') ]] || die "仍有 TCP 2049 监听，请检查是否有其他 NFS 配置覆盖。"
    info "已核对 NFS TCP 8388 监听与仅启用 NFSv4.1。"
}

write_exports() {
    local output=${1:-/etc/exports}
    local peers_file=${2:-$PEERS_FILE}
    local block="${EXPORTS_BEGIN}" name peer_ip public_key
    block+=$'\n'
    if [[ -s $peers_file ]]; then
        block+="${MEDIA_ROOT}"
        while IFS='|' read -r name peer_ip public_key; do
            [[ -n ${name:-} ]] || continue
            block+=" ${peer_ip}/32(ro,sync,root_squash,no_subtree_check,fsid=0)"
        done < "$peers_file"
        block+=$'\n'
    else
        block+="# 尚未配置 Jellyfin 客户端 Peer；使用 --add-client-peer 添加客户端。"
        block+=$'\n'
    fi
    block+="$EXPORTS_END"
    replace_block "$output" "$EXPORTS_BEGIN" "$EXPORTS_END" "$block"
}

find_nfs_service() {
    systemctl cat nfs-server.service >/dev/null 2>&1 || die "Debian stable 未提供 nfs-server.service。"
    NFS_SERVICE="nfs-server"
}

start_services() {
    start_firewall
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
    verify_nfs_service
}

install_packages() {
    info "安装 wireguard、nfs-kernel-server、nftables、iptables 和 python3..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard nfs-kernel-server nftables iptables python3
}

rollback_client_peer_update() {
    local sync_file=""
    if [[ -n ${ADD_PEER_BACKUP_DIR:-} && -d $ADD_PEER_BACKUP_DIR ]]; then
        cp -a "$ADD_PEER_BACKUP_DIR/peers.tsv" "$PEERS_FILE" || warn "恢复 Peer 清单失败。"
        cp -a "$ADD_PEER_BACKUP_DIR/wg0.conf" "$WG_CONFIG" || warn "恢复 WireGuard 配置失败。"
        cp -a "$ADD_PEER_BACKUP_DIR/exports" /etc/exports || warn "恢复 NFS 导出配置失败。"
    fi

    if command -v wg-quick >/dev/null 2>&1 && command -v wg >/dev/null 2>&1 && wg show "$WG_INTERFACE" >/dev/null 2>&1; then
        if sync_file=$(mktemp "${WG_CONFIG}.rollback.XXXXXX" 2>/dev/null); then
            if wg-quick strip "$WG_INTERFACE" > "$sync_file"; then
                wg syncconf "$WG_INTERFACE" "$sync_file" || warn "已恢复文件，但恢复 WireGuard 运行状态失败。"
            else
                warn "已恢复文件，但无法生成 WireGuard 回滚配置。"
            fi
            rm -f -- "$sync_file"
        else
            warn "已恢复文件，但无法创建 WireGuard 回滚临时文件。"
        fi
    fi
    if command -v exportfs >/dev/null 2>&1; then
        exportfs -ra || warn "已恢复文件，但重新加载 NFS 导出失败。"
    fi
    if (( ADD_PEER_ROUTE_ADDED )); then
        ip -4 route del "${ADD_PEER_ADDRESS}/32" dev "$WG_INTERFACE" || warn "撤销本次新增路由失败。"
        ADD_PEER_ROUTE_ADDED=0
    fi
    "$RUNTIME_DIR/firewall" || warn "恢复本工程防火墙规则失败，请执行 --apply-firewall。"
    ADD_PEER_ROLLBACK=0
}

ensure_client_route() {
    local peer_address=$1 route_state
    route_state=$(ip -4 -j route show exact "${peer_address}/32" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print("missing" if not rows else "present" if len(rows) == 1 and rows[0].get("dev") == "wg0" and not rows[0].get("gateway") and rows[0].get("type", "unicast") == "unicast" else "conflict")
') || die "读取客户端路由失败。"
    case "$route_state" in
        missing)
            ip -4 route add "${peer_address}/32" dev "$WG_INTERFACE" || die "添加客户端回程路由失败。"
            ADD_PEER_ADDRESS=$peer_address
            ADD_PEER_ROUTE_ADDED=1
            ;;
        present) ;;
        *) die "${peer_address}/32 已存在其他路由；未覆盖该路由。" ;;
    esac
}

add_client_peer() {
    local peer_name="" peer_address="" public_key_file="" public_key=""
    local key_file_size
    local -a public_key_lines=()

    while (($#)); do
        case "$1" in
            --peer-name)
                (($# >= 2)) || die "--peer-name 缺少参数。"
                peer_name=$2
                shift 2
                ;;
            --peer-address)
                (($# >= 2)) || die "--peer-address 缺少参数。"
                peer_address=$2
                shift 2
                ;;
            --public-key-file)
                (($# >= 2)) || die "--public-key-file 缺少参数。"
                public_key_file=$2
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                die "未知参数：$1。请使用 --help 查看 Peer 添加用法。"
                ;;
        esac
    done

    [[ -n $peer_name ]] || die "必须提供 --peer-name。"
    [[ -n $peer_address ]] || die "必须提供 --peer-address。"
    [[ -n $public_key_file ]] || die "必须提供 --public-key-file。"
    valid_name "$peer_name" || die "客户端 Peer 名称无效。"
    valid_ipv4 "$peer_address" || die "客户端 Peer IPv4 地址无效。"
    [[ $public_key_file == *.pub ]] || die "公钥文件名必须以 .pub 结尾；请勿指定 wg0.key。"
    [[ -f $public_key_file && -r $public_key_file ]] || die "公钥文件不存在或不可读：$public_key_file。"
    key_file_size=$(wc -c < "$public_key_file") || die "读取公钥文件失败。"
    (( key_file_size <= 256 )) || die "公钥文件过大；文件应只有一行公钥。"
    mapfile -t public_key_lines < "$public_key_file" || die "读取公钥文件失败。"
    [[ ${#public_key_lines[@]} -eq 1 ]] || die "公钥文件必须恰好只有一行 WireGuard 公钥。"
    public_key=${public_key_lines[0]}
    valid_key "$public_key" || die "公钥格式无效；请使用客户端脚本输出的 44 字符 WireGuard 公钥。"

    [[ -x $RUNTIME_DIR/firewall ]] || die "请先完整运行本版本服务端安装器，以安装防火墙支持。"
    [[ -f $NODE_FILE && -f $PEERS_FILE && -s $WG_CONFIG && -f /etc/exports ]] || die "服务端配置不完整；请先完成 NFS Server 安装。"
    if ! grep -qF "$MANAGED_MARKER" "$WG_CONFIG" && (( ! FORCE_MODE )); then
        die "$WG_CONFIG 不是本工具生成的配置；请使用 --force 覆盖。"
    fi
    [[ -s $WG_KEY_FILE ]] || die "找不到服务端 WireGuard 私钥文件；请先完成 NFS Server 安装。"
    command -v wg >/dev/null 2>&1 || die "找不到 wg 命令。"
    command -v wg-quick >/dev/null 2>&1 || die "找不到 wg-quick 命令。"
    command -v exportfs >/dev/null 2>&1 || die "找不到 exportfs 命令。"
    wg show "$WG_INTERFACE" >/dev/null 2>&1 || die "WireGuard 接口 $WG_INTERFACE 未运行；请先检查 NFS Server 服务。"

    [[ $(state_get ROLE "$NODE_FILE") == server ]] || die "节点状态不是本版本服务端配置，请先完整运行安装器。"
    NODE_NAME=$(state_get NODE_NAME "$NODE_FILE" || true)
    WG_ADDRESS=$(state_get WG_ADDRESS "$NODE_FILE" || true)
    WG_SUBNET=$(state_get WG_SUBNET "$NODE_FILE" || true)
    WG_LISTEN_PORT=$(state_get WG_LISTEN_PORT "$NODE_FILE" || true)
    MEDIA_ROOT=$(state_get MEDIA_ROOT "$NODE_FILE" || true)
    valid_name "$NODE_NAME" || die "服务端节点状态无效。"
    valid_ipv4 "$WG_ADDRESS" || die "服务端 WireGuard 地址状态无效。"
    valid_cidr "$WG_SUBNET" || die "服务端 WireGuard 网段状态无效。"
    ipv4_in_cidr "$WG_ADDRESS" "$WG_SUBNET" || die "服务端 WireGuard 地址不在已保存网段内。"
    valid_port "$WG_LISTEN_PORT" || die "服务端 WireGuard 端口状态无效。"
    valid_abs_path "$MEDIA_ROOT" || die "NFS 媒体目录状态无效。"
    [[ $peer_name != "$NODE_NAME" ]] || die "客户端 Peer 名称不能与服务端节点名相同。"
    ipv4_in_cidr "$peer_address" "$WG_SUBNET" || die "客户端地址 $peer_address 不在已配置网段 $WG_SUBNET 内。"
    [[ $peer_address != "$WG_ADDRESS" ]] || die "客户端地址不能与服务端地址相同。"
    peer_exists_in_file "$PEERS_FILE" "$peer_name" && die "客户端 Peer 名称已存在：$peer_name。"
    peer_ip_exists_in_file "$PEERS_FILE" "$peer_address" && die "客户端 WireGuard 地址已被使用：$peer_address。"
    peer_key_exists_in_file "$PEERS_FILE" "$public_key" && die "该公钥已存在于客户端 Peer 清单中。"

    PRIVATE_KEY=$(<"$WG_KEY_FILE")
    [[ -n $PRIVATE_KEY ]] || die "服务端 WireGuard 私钥为空。"
    printf '%s' "$PRIVATE_KEY" | wg pubkey >/dev/null || die "服务端 WireGuard 私钥无效。"

    NEW_PEERS_FILE=$(mktemp "${STATE_DIR}/server-peers.XXXXXX")
    chmod 0600 "$NEW_PEERS_FILE"
    cp -f "$PEERS_FILE" "$NEW_PEERS_FILE"
    printf '%s|%s|%s\n' "$peer_name" "$peer_address" "$public_key" >> "$NEW_PEERS_FILE"
    validate_peer_file

    ADD_PEER_WG_STAGE=$(mktemp "${WG_CONFIG}.stage.XXXXXX")
    write_wg_config "$ADD_PEER_WG_STAGE" "$NEW_PEERS_FILE"
    ADD_PEER_EXPORTS_STAGE=$(mktemp /etc/exports.nwm-stage.XXXXXX)
    cp -a /etc/exports "$ADD_PEER_EXPORTS_STAGE"
    write_exports "$ADD_PEER_EXPORTS_STAGE" "$NEW_PEERS_FILE"

    ADD_PEER_BACKUP_DIR=$(mktemp -d "${STATE_DIR}/.add-client-peer.XXXXXX")
    cp -a "$PEERS_FILE" "$ADD_PEER_BACKUP_DIR/peers.tsv"
    cp -a "$WG_CONFIG" "$ADD_PEER_BACKUP_DIR/wg0.conf"
    cp -a /etc/exports "$ADD_PEER_BACKUP_DIR/exports"

    ADD_PEER_ROLLBACK=1
    mv -f "$NEW_PEERS_FILE" "$PEERS_FILE"
    mv -f "$ADD_PEER_WG_STAGE" "$WG_CONFIG"
    mv -f "$ADD_PEER_EXPORTS_STAGE" /etc/exports

    ADD_PEER_SYNC_FILE=$(mktemp "${WG_CONFIG}.syncconf.XXXXXX")
    wg-quick strip "$WG_INTERFACE" > "$ADD_PEER_SYNC_FILE" || die "生成 WireGuard 运行配置失败。"
    wg syncconf "$WG_INTERFACE" "$ADD_PEER_SYNC_FILE" || die "应用 WireGuard 客户端 Peer 失败。"
    ensure_client_route "$peer_address"
    "$RUNTIME_DIR/firewall" || die "更新 NFS 防火墙失败。"
    exportfs -ra || die "重新加载 NFS 导出失败。"
    ADD_PEER_ROLLBACK=0

    info "已添加客户端 Peer：${peer_name} (${peer_address})。"
    info "WireGuard、回程路由、NFS 导出和防火墙已在线更新。"
}

main() {
    local current arg
    if (( ${APPLY_FIREWALL_MODE:-0} )); then
        for arg in "$@"; do
            [[ $arg == --apply-firewall || $arg == --force ]] || die "未知参数：$arg。"
        done
        apply_saved_firewall
        return
    fi
    if (( ADD_CLIENT_PEER_MODE )); then
        local -a peer_args=()
        for arg in "$@"; do
            [[ $arg == --add-client-peer || $arg == --force ]] || peer_args+=("$arg")
        done
        add_client_peer "${peer_args[@]}"
        return
    fi
    for arg in "$@"; do
        [[ $arg == --force ]] || die "不支持的位置参数：$arg。请使用 --help 查看用法。"
    done
    install_packages
    ensure_manager_wg_config
    local saved_role
    saved_role=$(state_get ROLE "$NODE_FILE" || true)
    [[ -z $saved_role || $saved_role == "$ROLE" ]] || die "同一机器不能混用本工程的服务端与客户端角色。"

    current=$(state_get NODE_NAME "$NODE_FILE" || true)
    NODE_NAME=$(prompt "本机节点名称（NFS Server 示例：ddps_nft）" "${current:-ddps_nft}")
    valid_name "$NODE_NAME" || die "节点名称无效。"

    current=$(state_get WG_ADDRESS "$NODE_FILE" || true)
    WG_ADDRESS=$(prompt "本机 WireGuard IPv4 地址（NFS Server 示例：10.96.0.2）" "${current:-10.96.0.2}")
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
        MEDIA_ROOT=$(prompt "NFS 导出的媒体目录" "${current:-$DEFAULT_MEDIA_ROOT}")
        if MEDIA_ROOT=$(normalize_abs_path "$MEDIA_ROOT"); then
            break
        fi
        warn "媒体目录必须是无空格、无路径穿越的绝对路径。请重新输入。"
        current=""
    done
    if [[ ! -d $MEDIA_ROOT ]]; then
        warn "$MEDIA_ROOT 不存在，将创建该目录；请确认实际媒体磁盘已经挂载。"
        install -d -m 0755 "$MEDIA_ROOT"
    fi

    collect_peers
    validate_peer_file
    load_or_create_key
    install_firewall_support
    mv -f "$NEW_PEERS_FILE" "$PEERS_FILE"
    chmod 0600 "$PEERS_FILE"
    save_node_state
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
    printf '\n下一步：在 Jellyfin 客户端 Peer 中填写本机公钥和公网 Endpoint；若本次已在客户端 Peer 清单中录入客户端公钥，无需再运行添加命令。wg0 上 TCP 8388 已自动管理；请自行放行公网 WireGuard UDP 端口。\n'
}

main "$@"
