#!/usr/bin/env python3
"""Isolated regression tests. Never contact real nft, iptables, Docker, mounts or services."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path('/srv/paseo/cache/data_share')


def source(role):
    return (ROOT / 'scripts' / ('install-nfs-server.sh' if role == 'server' else 'install-jellyfin-client.sh')).read_text()


def embedded(role, name):
    body = re.search("<<'" + name + "'\n(.*?)\n" + name, source(role), re.S)[1]
    module = types.ModuleType(name)
    exec(compile(body, name, 'exec'), module.__dict__)
    return module


def functions(role):
    return '\n\n'.join(m[0] for m in re.finditer(r'^[A-Za-z_][A-Za-z0-9_]*\(\) \{\n.*?^\}', source(role), re.M | re.S))


class Ruleset:
    """Small packet evaluator for the native and external filter objects."""
    def __init__(self):
        self.objects = []
        self.handle = 0
        self.objects.append({'table': dict(family='inet', name='filter')})
        for hook in ['input', 'output']:
            self.objects.append({'chain': dict(family='inet', table='filter', name=hook,
                                              hook=hook, type='filter', prio=0, policy='drop')})
        self.objects.append({'table': dict(family='ip', name='filter')})
        for hook in ['INPUT', 'OUTPUT']:
            self.objects.append({'chain': dict(family='ip', table='filter', name=hook,
                                              hook=hook.lower(), type='filter', prio=0, policy='accept')})
        self.objects.append({'table': dict(family='ip6', name='filter')})
        self.objects.append({'chain': dict(family='ip', table='filter', name='FORWARD', hook='forward',
                                          type='filter', prio=0, policy='accept')})

    def snapshot(self):
        return {'nftables': copy.deepcopy(self.objects)}

    def apply(self, transaction):
        for command in transaction['nftables']:
            action, obj = next(iter(command.items()))
            kind, body = next(iter(obj.items()))
            body = copy.deepcopy(body)
            if action == 'delete':
                if kind == 'table':
                    self.objects = [o for o in self.objects if not any(v.get('family') == body['family'] and
                        (v.get('table') == body['name'] or (k == 'table' and v.get('name') == body['name']))
                        for k, v in o.items())]
                else:
                    self.objects = [o for o in self.objects if not ('rule' in o and all(o['rule'].get(k) == v for k, v in body.items()))]
                continue
            if kind == 'rule':
                self.handle += 1
                body['handle'] = self.handle
            if action == 'insert':
                self.objects.insert(0, {kind: body})
            else:
                self.objects.append({kind: body})

    def accepts(self, hook, packet):
        chains = sorted([o['chain'] for o in self.objects if 'chain' in o
                         and o['chain'].get('hook') == hook
                         and o['chain'].get('family') in ('inet', 'ip')], key=lambda c: c['prio'])
        for chain in chains:
            verdict = chain['policy']
            for obj in self.objects:
                rule = obj.get('rule')
                if not rule or rule['chain'] != chain['name'] or any(rule[k] != chain[k] for k in ('family', 'table')):
                    continue
                hit = True
                result = None
                for expr in rule['expr']:
                    if 'match' in expr:
                        item = expr['match']
                        kind, field = next(iter(item['left'].items()))
                        key = field.get('field') if kind == 'payload' else field['key']
                        actual = packet.get(key)
                        wanted = item['right']
                        hit &= actual in wanted['set'] if isinstance(wanted, dict) else actual == wanted
                    elif 'accept' in expr or 'drop' in expr:
                        result = 'accept' if 'accept' in expr else 'drop'
                if hit and result:
                    verdict = result
                    break
            if verdict == 'drop':
                return False
        return True


class FirewallTests(unittest.TestCase):
    def setUp(self):
        self.fw = embedded('server', 'NWM_FIREWALL_PY')
        self.kernel = Ruleset()

    def update(self, role='server', peers=None, compat=()):
        self.kernel.apply(self.fw.transaction(self.kernel.snapshot(), role,
            '10.96.0.2' if role == 'server' else '10.96.0.1',
            peers if peers is not None else ['10.96.0.1'], compat=compat))

    def test_default_drop_and_multiple_base_chains(self):
        self.update()
        packet = dict(iifname='wg0', saddr='10.96.0.1', daddr='10.96.0.2', l4proto='tcp', dport=8388)
        self.assertTrue(self.kernel.accepts('input', packet))
        for changed in [dict(iifname='eth0'), dict(saddr='10.96.0.9'), dict(dport=2049), dict(l4proto='udp', dport=35669)]:
            self.assertFalse(self.kernel.accepts('input', dict(packet, **changed)))
        self.assertTrue(self.kernel.accepts('output', dict(oifname='wg0', saddr='10.96.0.2', daddr='10.96.0.1',
                                                         l4proto='tcp', sport=8388, state='established')))

    def test_client_directions_and_no_new_inbound_connections(self):
        self.update('client', ['10.96.0.2'])
        self.assertTrue(self.kernel.accepts('output', dict(oifname='wg0', saddr='10.96.0.1', daddr='10.96.0.2', l4proto='tcp', dport=8388)))
        reply = dict(iifname='wg0', saddr='10.96.0.2', daddr='10.96.0.1', l4proto='tcp', sport=8388, state='established')
        self.assertTrue(self.kernel.accepts('input', reply))
        self.assertFalse(self.kernel.accepts('input', dict(reply, state='new')))

    def test_idempotent_reconciliation_and_foreign_objects(self):
        original = copy.deepcopy(self.kernel.objects)
        self.update(peers=['10.96.0.1', '10.96.0.3'])
        count = len(self.kernel.objects)
        self.update(peers=['10.96.0.1', '10.96.0.3'])
        self.assertEqual(len(self.kernel.objects), count)
        for obj in original:
            self.assertIn(obj, self.kernel.objects)
        self.update(peers=[])
        self.assertFalse(self.kernel.accepts('input', dict(iifname='wg0', saddr='10.96.0.1', daddr='10.96.0.2', l4proto='tcp', dport=8388)))

    def test_iptables_managed_ip_filter_is_allowed_and_not_in_nft_transaction(self):
        foreign = {'rule': {'family': 'ip', 'table': 'filter', 'chain': 'INPUT',
                             'expr': [{'counter': None}, {'accept': None}],
                             'comment': 'external'}}
        self.kernel.objects.append(foreign)
        tx = self.fw.transaction(self.kernel.snapshot(), 'server', '10.96.0.2',
                                 ['10.96.0.1'], compat={('ip', 'filter')})
        self.assertFalse(any(any(v.get('family') == 'ip' for v in obj.values() if isinstance(v, dict))
                             for cmd in tx['nftables'] for obj in cmd.values()))
        self.kernel.apply(tx)
        self.assertIn(foreign, self.kernel.objects)

    def test_ip6_objects_are_untouched(self):
        before = [copy.deepcopy(o) for o in self.kernel.objects if any(
            isinstance(v, dict) and v.get('family') == 'ip6' for v in o.values())]
        self.update(compat={('ip6', 'filter')})
        after = [o for o in self.kernel.objects if any(
            isinstance(v, dict) and v.get('family') == 'ip6' for v in o.values())]
        self.assertEqual(before, after)

    def test_native_filter_is_required(self):
        self.kernel.objects = [o for o in self.kernel.objects if not any(
            isinstance(v, dict) and v.get('family') == 'inet' for v in o.values())]
        with self.assertRaisesRegex(ValueError, '原生 inet filter'):
            self.update()

    def test_reserved_name_in_another_family_is_ignored(self):
        self.kernel.objects += [
            {'table': dict(family='ip', name=self.fw.TABLE)},
            {'chain': dict(family='ip', table=self.fw.TABLE, name='input', hook='input',
                           type='filter', prio=5, policy='accept')}]
        self.update()
        self.assertTrue(self.kernel.accepts('input', dict(iifname='wg0', saddr='10.96.0.1',
            daddr='10.96.0.2', l4proto='tcp', dport=8388)))

    def test_external_iptables_rules_are_exact_and_idempotent(self):
        old = [
            ('INPUT', ['-p', 'tcp', '--dport', '3666', '-m', 'comment', '--comment', 'nfs-wg-manager:old', '-j', 'ACCEPT']),
            ('OUTPUT', ['-p', 'tcp', '--sport', '3666', '-m', 'comment', '--comment', 'nfs-wg-manager:old-out', '-j', 'ACCEPT']),
        ]
        calls = []
        def fake(argv, data=None, check=True):
            calls.append(argv)
            if argv[0] == 'iptables' and argv[3] == '-S':
                lines = ['-A %s %s' % (c, ' '.join(shlex.quote(x) for x in rule)) for c, rule in old]
                return types.SimpleNamespace(returncode=0, stdout='\n'.join(lines) + ('\n' if lines else ''), stderr='')
            return types.SimpleNamespace(returncode=0, stdout='', stderr='')
        with patch.object(self.fw, 'run', fake), patch.object(self.fw.shutil, 'which', return_value='/sbin/iptables'):
            self.fw.reconcile_external('server', '10.96.0.2', ['10.96.0.1'],
                                       {('ip', 'filter'), ('ip6', 'filter')})
        self.assertTrue(any(c[3] == '-D' for c in calls))
        inserts = [c for c in calls if c[3] == '-I']
        self.assertEqual(len(inserts), 2)
        self.assertTrue(any('nfs-wg-manager:' in token for cmd in inserts for token in cmd))

    def test_external_rule_rollback(self):
        calls = []
        old = [
            ('INPUT', ['-p', 'tcp', '--dport', '3666', '-m', 'comment', '--comment',
                       'nfs-wg-manager:old', '-j', 'ACCEPT']),
            ('OUTPUT', ['-p', 'tcp', '--sport', '3666', '-m', 'comment', '--comment',
                        'nfs-wg-manager:old-out', '-j', 'ACCEPT']),
        ]
        def fake(argv, data=None, check=True):
            calls.append(argv)
            if argv[0] == 'iptables' and argv[3] == '-S':
                lines = ['-A %s %s' % (chain, ' '.join(shlex.quote(x) for x in rule)) for chain, rule in old]
                return types.SimpleNamespace(returncode=0, stdout='\n'.join(lines) + '\n', stderr='')
            if argv[0] == 'iptables' and argv[3] == '-I' and check and len([c for c in calls if c[3] == '-I']) > 1:
                raise RuntimeError('insert failed')
            return types.SimpleNamespace(returncode=0, stdout='', stderr='')
        with patch.object(self.fw, 'run', fake), patch.object(self.fw.shutil, 'which', return_value='/sbin/iptables'):
            with self.assertRaises(RuntimeError):
                self.fw.reconcile_external('server', '10.96.0.2', ['10.96.0.1'],
                                            {('ip', 'filter')})
        self.assertTrue(any(c[3] == '-D' for c in calls))

    def test_docker_only_filter_without_input_output_is_left_alone(self):
        calls = []
        def fake(argv, data=None, check=True):
            calls.append(argv)
            if argv[0] == 'iptables' and argv[3] == '-S':
                return types.SimpleNamespace(returncode=0, stdout='-P FORWARD ACCEPT\n', stderr='')
            return types.SimpleNamespace(returncode=0, stdout='', stderr='')
        with patch.object(self.fw, 'run', fake), patch.object(self.fw.shutil, 'which', return_value='/sbin/iptables'):
            self.fw.reconcile_external('client', '10.96.0.1', ['10.96.0.2'], {('ip', 'filter')})
        self.assertFalse(any(c[3] in ('-I', '-D') for c in calls))

    def test_nft_failure_restores_previous_external_rules(self):
        old_rule = ['-p', 'tcp', '--dport', '3666', '-m', 'comment', '--comment',
                    'nfs-wg-manager:old', '-j', 'ACCEPT']
        current = [('INPUT', old_rule[:])]
        calls = []
        def fake(argv, data=None, check=True):
            calls.append(argv)
            if argv[:3] == ['nft', '-j', 'list']:
                return types.SimpleNamespace(stdout=json.dumps(self.kernel.snapshot()),
                                             stderr='# Warning: table ip filter is managed by iptables-nft')
            if argv[:3] == ['nft', 'list', 'ruleset']:
                return types.SimpleNamespace(stdout='# Warning: table ip filter is managed by iptables-nft', stderr='')
            if argv[:4] == ['nft', '-j', '-c', '-f']:
                return types.SimpleNamespace(stdout='', stderr='')
            if argv[:4] == ['nft', '-j', '-f', '-']:
                raise RuntimeError('nft apply failed')
            if argv[0] == 'iptables' and argv[3] == '-S':
                lines = ['-A %s %s' % (chain, ' '.join(shlex.quote(x) for x in rule))
                         for chain, rule in current]
                return types.SimpleNamespace(returncode=0, stdout='\n'.join(lines) + ('\n' if lines else ''), stderr='')
            if argv[0] == 'iptables' and argv[3] == '-D':
                chain, rule = argv[4], argv[5:]
                current.remove((chain, rule))
                return types.SimpleNamespace(returncode=0, stdout='', stderr='')
            if argv[0] == 'iptables' and argv[3] == '-I':
                current.insert(0, (argv[4], argv[6:]))
                return types.SimpleNamespace(returncode=0, stdout='', stderr='')
            return types.SimpleNamespace(returncode=0, stdout='', stderr='')
        with tempfile.TemporaryDirectory(prefix='nwm-fw-rollback-', dir=CACHE) as temp:
            with patch.object(self.fw, 'LOCK', str(Path(temp) / 'lock')), patch.object(self.fw, 'run', fake), \
                 patch.object(self.fw, 'settings', return_value=('server', '10.96.0.2', ['10.96.0.1'])), \
                 patch.object(self.fw.shutil, 'which', return_value='/sbin/iptables'), \
                 patch.object(self.fw.sys, 'argv', ['firewall']):
                with self.assertRaisesRegex(RuntimeError, 'nft apply failed'):
                    self.fw.main()
        self.assertEqual(current, [('INPUT', old_rule)])
        self.assertTrue(any(c[:4] == ['nft', '-j', '-f', '-'] for c in calls))

    def test_check_failure_never_applies(self):
        CACHE.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='nwm-fw-test-', dir=CACHE) as temp:
            calls = []
            def fake(argv, data=None, check=True):
                calls.append(argv)
                if '-c' in argv:
                    raise RuntimeError('rejected transaction')
                if argv[:3] == ['nft', '-j', 'list']:
                    return types.SimpleNamespace(stdout=json.dumps(self.kernel.snapshot()), stderr='')
                return types.SimpleNamespace(stdout='', stderr='')
            with patch.object(self.fw, 'LOCK', str(Path(temp) / 'lock')), patch.object(self.fw, 'run', fake), \
                 patch.object(self.fw, 'settings', return_value=('server', '10.96.0.2', ['10.96.0.1'])), \
                 patch.object(self.fw.sys, 'argv', ['firewall']):
                with self.assertRaises(RuntimeError):
                    self.fw.main()
            self.assertNotIn(['nft', '-j', '-f', '-'], calls)


class MountTests(unittest.TestCase):
    def setUp(self):
        self.m = embedded('client', 'NWM_MOUNTS_PY')
        self.peers = [('one', '10.96.0.2', '/media/one'), ('two', '10.96.0.3', '/media/two')]

    def nfs(self, path='/media/one', address='10.96.0.2', **kw):
        return dict(target=path, source=address + ':/', fstype='nfs4', options='ro,vers=4.1,proto=tcp,port=8388', propagation='shared', **kw)

    def reconcile(self, rows, statuses=None):
        calls = []
        def fake(argv, check=True):
            calls.append(argv)
            if argv[0] == 'systemd-escape':
                return argv[-1].replace('/', '-') + '.mount'
            if argv[:2] == ['systemctl', 'show']:
                return (statuses or {}).get(argv[-1], 'inactive')
            return ''
        with patch.object(self.m, 'records', return_value=rows), patch.object(self.m, 'run', fake), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = self.m.reconcile(self.peers)
        return status, calls

    def test_autofs_explicit_start_and_other_peer_not_blocked(self):
        rows = [dict(target='/media/one', fstype='autofs'), self.nfs('/media/two', '10.96.0.3')]
        status, calls = self.reconcile(rows)
        starts = [c for c in calls if c[:2] == ['systemctl', 'start']]
        self.assertEqual(status, 0)
        self.assertEqual(starts, [['systemctl', 'start', '--no-block', '-media-one.mount']])
        self.assertFalse(any(c[0] in ('stat', 'docker', 'umount') for c in calls))

    def test_wrong_source_options_and_activating_not_replaced(self):
        for source in [self.nfs(address='10.96.0.99'), dict(self.nfs(), options='ro,vers=4.1,proto=tcp,port=2049')]:
            status, calls = self.reconcile([source], {'-media-two.mount': 'activating'})
            self.assertEqual(status, 1)
            self.assertFalse(any(c[:2] == ['systemctl', 'start'] for c in calls))

    def test_late_recovery_no_restart_or_repeated_mount(self):
        _, calls = self.reconcile([])
        self.assertEqual(len([c for c in calls if c[:2] == ['systemctl', 'start']]), 2)
        _, calls = self.reconcile([self.nfs(), self.nfs('/media/two', '10.96.0.3')])
        self.assertEqual(calls, [])

    def test_private_root_isolated_bind_and_existing_shared_children(self):
        calls = []
        root = dict(target='/', fstype='ext4', propagation='private')
        with patch.object(self.m, 'records', return_value=[root]), patch.object(self.m, 'run', side_effect=lambda args: calls.append(args)):
            self.m.prepare('/media')
        self.assertEqual(calls, [['mount', '--bind', '--', '/media', '/media'], ['mount', '--make-rshared', '--', '/media']])
        with patch.object(self.m, 'records', return_value=[root, self.nfs()]):
            with self.assertRaises(RuntimeError):
                self.m.prepare('/media')
        with patch.object(self.m, 'records', return_value=[dict(root, propagation='shared'), self.nfs()]), patch.object(self.m, 'run') as run:
            self.m.prepare('/media')
            run.assert_not_called()

    def test_media_root_inside_remote_filesystem_is_rejected(self):
        with patch.object(self.m, 'records', return_value=[dict(target='/', fstype='ext4'),
                dict(target='/media', fstype='nfs4', propagation='shared')]), patch.object(self.m, 'run') as run:
            with self.assertRaises(RuntimeError):
                self.m.prepare('/media/jellyfin')
            run.assert_not_called()


class ShellTests(unittest.TestCase):
    def setUp(self):
        CACHE.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='nwm-shell-test-', dir=CACHE)
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)

    def bash(self, role, body, env=None):
        text = functions(role).replace('/etc/', str(self.path / 'etc') + '/').replace('/usr/local/libexec/', str(self.path / 'libexec') + '/')
        return subprocess.run(['bash'], input='set -Eeuo pipefail\n' + text + '\n' + body, capture_output=True, text=True,
                              env=dict(os.environ, TEST_ROOT=str(self.path), **(env or {})))

    def test_numeric_validation(self):
        for role in ['server', 'client']:
            result = self.bash(role, '''
valid_ipv4 10.96.0.1
for ip in 010.096.0.1 18446744073709551626.96.0.1 256.1.2.3; do
    if valid_ipv4 "$ip"; then exit 9; fi
done
if valid_cidr 10.96.0.0; then exit 9; fi
if valid_port 18446744073709587285; then exit 9; fi
valid_key AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
if valid_key BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=; then exit 9; fi
''')
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_endpoint_address_validation(self):
        result = self.bash('client', '''
for endpoint in 203.0.113.10:35669 '[2001:db8::1]:35669' nfs.example.com:35669; do
    valid_endpoint "$endpoint"
done
for endpoint in 300.1.2.3:35669 010.1.2.3:35669 '[:::]:35669' 203.0.113.10:99999; do
    if valid_endpoint "$endpoint"; then exit 9; fi
done
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_apply_firewall_only_uses_saved_matching_role(self):
        runtime = self.path / 'runtime'
        runtime.mkdir()
        helper = runtime / 'firewall'
        helper.write_text('#!/bin/bash\ntouch "$TEST_ROOT/applied"\n')
        helper.chmod(0o755)
        for role in ['client', 'server']:
            for saved_role in ['client', 'server']:
                (self.path / 'node.conf').write_text('ROLE=' + saved_role + '\n')
                result = self.bash(role, '''
ROLE=$TEST_ROLE
RUNTIME_DIR=$TEST_ROOT/runtime
NODE_FILE=$TEST_ROOT/node.conf
APPLY_FIREWALL_MODE=1
install_packages() { exit 9; }
prompt() { exit 9; }
systemctl() { exit 9; }
main --apply-firewall
''', {'TEST_ROLE': role})
                self.assertEqual(result.returncode, 0 if role == saved_role else 1, result.stderr)
                applied = self.path / 'applied'
                self.assertEqual(applied.exists(), role == saved_role)
                if applied.exists():
                    applied.unlink()

    def test_routes_do_not_overwrite_conflicts(self):
        for route, expected in [('[]', 0), ('[{"dev":"wg0"}]', 0), ('[{"dev":"eth0"}]', 1)]:
            result = self.bash('server', '''
WG_INTERFACE=wg0
ADD_PEER_ROUTE_ADDED=0
ip() {
    if [[ $* == *' show '* ]]; then printf '%s' "$TEST_ROUTES";
    else printf '%s\\n' "$*" >> "$TEST_ROOT/route-events"; fi
}
ensure_client_route 10.96.0.1
printf '%s' "$ADD_PEER_ROUTE_ADDED"
''', {'TEST_ROUTES': route})
            self.assertEqual(result.returncode, expected, result.stderr)
            if expected == 0:
                self.assertEqual(result.stdout, '1' if route == '[]' else '0')
            events = self.path / 'route-events'
            if events.exists():
                self.assertEqual(route, '[]')
                events.unlink()

    def test_add_peer_transaction_and_rollback(self):
        for failure in ['', 'sync', 'route', 'firewall', 'exports']:
            with self.subTest(failure=failure):
                state = self.path / ('case-' + (failure or 'success'))
                state.mkdir()
                (self.path / 'etc').mkdir(exist_ok=True)
                exports = self.path / 'etc/exports'
                exports.write_text('# pre-existing exports\n')
                (state / 'peers').write_text('')
                (state / 'node.conf').write_text('ROLE=server\nNODE_NAME=ddps_nft\nWG_ADDRESS=10.96.0.2\nWG_SUBNET=10.96.0.0/16\nWG_LISTEN_PORT=35669\nMEDIA_ROOT=/srv/media\n')
                (state / 'wg0.conf').write_text('# Managed by NFS_Wireguard_Manager\n[Interface]\nAddress = 10.96.0.2/32\n')
                (state / 'wg0.key').write_text('synthetic-test-key\n')
                (state / 'hhost.pub').write_text('A' * 43 + '=\n')
                runtime = state / 'runtime'
                runtime.mkdir()
                fw = runtime / 'firewall'
                fw.write_text('''#!/bin/bash
if [[ $TEST_FAILURE == firewall ]] && [[ -s $TEST_STATE/peers ]]; then exit 1; fi
cp "$TEST_STATE/peers" "$TEST_STATE/firewall-peers"
''')
                fw.chmod(0o755)
                result = self.bash('server', '''
STATE_DIR=$TEST_STATE
NODE_FILE=$STATE_DIR/node.conf
PEERS_FILE=$STATE_DIR/peers
WG_CONFIG=$STATE_DIR/wg0.conf
WG_KEY_FILE=$STATE_DIR/wg0.key
RUNTIME_DIR=$STATE_DIR/runtime
WG_INTERFACE=wg0
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
EXPORTS_BEGIN='# BEGIN NFS_WG_MANAGER'
EXPORTS_END='# END NFS_WG_MANAGER'
ADD_PEER_ROLLBACK=0
ADD_PEER_ROUTE_ADDED=0
ADD_PEER_ADDRESS=''
ADD_PEER_BACKUP_DIR=''
ADD_PEER_WG_STAGE=''
ADD_PEER_EXPORTS_STAGE=''
ADD_PEER_SYNC_FILE=''
NEW_PEERS_FILE=''
SYNC_FAILED=0
trap cleanup EXIT
wg() {
    case $1 in
        show) return 0 ;;
        pubkey) cat >/dev/null; printf 'synthetic-public-key\\n' ;;
        syncconf)
            if [[ $TEST_FAILURE == sync && $SYNC_FAILED == 0 ]]; then SYNC_FAILED=1; return 1; fi
            cp "$PEERS_FILE" "$STATE_DIR/wg-peers"
            ;;
    esac
}
wg-quick() { printf '[Interface]\\n'; }
ip() {
    if [[ $* == *' show '* ]]; then printf '[]';
    elif [[ $* == *' add '* ]]; then
        [[ $TEST_FAILURE != route ]] || return 1
        printf '%s' "$*" > "$STATE_DIR/route"
    else rm -f "$STATE_DIR/route"; fi
}
exportfs() {
    if [[ $TEST_FAILURE == exports && -s $PEERS_FILE ]]; then return 1; fi
    cp "$PEERS_FILE" "$STATE_DIR/export-peers"
}
add_client_peer --peer-name hhost_jf --peer-address 10.96.0.1 --public-key-file "$STATE_DIR/hhost.pub"
''', {'TEST_FAILURE': failure, 'TEST_STATE': str(state)})
                self.assertEqual(result.returncode, 1 if failure else 0, result.stderr)
                expected = '' if failure else 'hhost_jf|10.96.0.1|' + 'A' * 43 + '=\n'
                self.assertEqual((state / 'peers').read_text(), expected)
                self.assertEqual((state / 'firewall-peers').read_text(), expected)
                self.assertEqual((state / 'wg-peers').read_text(), expected)
                self.assertEqual((state / 'route').exists(), not failure)
                if failure:
                    self.assertEqual(exports.read_text(), '# pre-existing exports\n')
                    self.assertNotIn('AllowedIPs', (state / 'wg0.conf').read_text())

    def test_nfs_config_uses_only_modern_debian_configuration(self):
        result = self.bash('server', '''
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
NFS_PORT=8388
NFS_CONF_FILE=$TEST_ROOT/nfs.conf.d/99-nfs-wg-manager.conf
systemctl() { return 0; }
write_nfs_config
write_nfs_config
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = (self.path / 'nfs.conf.d/99-nfs-wg-manager.conf').read_text()
        self.assertEqual(data.count('port = 8388'), 1)
        self.assertIn('vers4.1 = yes', data)
        self.assertNotIn('RPCNFSDOPTS', data)

    def test_force_overwrites_unmanaged_file(self):
        output = self.path / 'etc/conflict'
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text('external\n')
        result = self.bash('server', f'''
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
write_managed_file "$TEST_ROOT/etc/conflict" <<'EOF'
$MANAGED_MARKER
new
EOF
''')
        self.assertNotEqual(result.returncode, 0)
        result = self.bash('server', f'''
FORCE_MODE=1
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
write_managed_file "$TEST_ROOT/etc/conflict" <<'EOF'
$MANAGED_MARKER
new
EOF
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('new', output.read_text())

    def test_removed_last_peer_stops_automount_before_mount(self):
        runtime = self.path / 'runtime'
        runtime.mkdir()
        helper = runtime / 'mounts'
        helper.write_text('#!/bin/bash\nexit 0\n')
        helper.chmod(0o755)
        (self.path / 'old').write_text('one|10.96.0.2|test|203.0.113.10:35669|/media/one\n')
        (self.path / 'new').write_text('')
        result = self.bash('client', '''
RUNTIME_DIR=$TEST_ROOT/runtime
PEERS_FILE=$TEST_ROOT/old
NEW_PEERS_FILE=$TEST_ROOT/new
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
timeout() { shift 3; "$@"; }
systemctl() {
    if [[ $1 == show ]]; then printf 'loaded\\n'; else printf '%s\\n' "$*" >> "$TEST_ROOT/events"; fi
}
unmount_changed_peers
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.path / 'events').read_text().splitlines(), ['stop media-one.automount', 'stop media-one.mount'])

    def test_stop_failure_preserves_old_peer_list(self):
        runtime = self.path / 'runtime'
        runtime.mkdir()
        helper = runtime / 'mounts'
        helper.write_text('#!/bin/bash\nexit 0\n')
        helper.chmod(0o755)
        old = 'one|10.96.0.2|test|203.0.113.10:35669|/media/one\n'
        (self.path / 'old').write_text(old)
        (self.path / 'new').write_text('')
        result = self.bash('client', '''
RUNTIME_DIR=$TEST_ROOT/runtime
PEERS_FILE=$TEST_ROOT/old
NEW_PEERS_FILE=$TEST_ROOT/new
timeout() { shift 3; "$@"; }
systemctl() { if [[ $1 == show ]]; then printf 'loaded\\n'; else return 1; fi; }
unmount_changed_peers
mv "$NEW_PEERS_FILE" "$PEERS_FILE"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.path / 'old').read_text(), old)

    def test_recovery_stop_distinguishes_missing_units_from_failure(self):
        for state, stop_result in [('not-found', 1), ('loaded', 0), ('loaded', 1)]:
            result = self.bash('client', '''
systemctl() {
    if [[ $1 == show ]]; then printf '%s' "$TEST_STATE"; else return "$TEST_STOP"; fi
}
stop_mount_recovery
''', {'TEST_STATE': state, 'TEST_STOP': str(stop_result)})
            self.assertEqual(result.returncode, 1 if state == 'loaded' and stop_result else 0, result.stderr)

    def test_retained_peer_validation_and_media_root_change(self):
        media = self.path / 'media'
        media.mkdir()
        base = ['one', '10.96.0.2', 'A' * 43 + '=', '203.0.113.10:35669', str(media / 'one')]
        for field in range(5):
            duplicate = ['two', '10.96.0.3', 'B' * 42 + 'A=', '203.0.113.11:35669', str(media / 'two')]
            if field == 3:  # endpoints may legitimately repeat; exercise traversal instead
                duplicate[4] = str(media / '../outside')
            else:
                duplicate[field] = base[field]
            (self.path / 'peers').write_text('|'.join(base) + '\n' + '|'.join(duplicate) + '\n')
            result = self.bash('client', '''
NEW_PEERS_FILE=$TEST_ROOT/peers
NODE_NAME=hhost_jf
WG_ADDRESS=10.96.0.1
WG_SUBNET=10.96.0.0/16
MEDIA_ROOT=$TEST_ROOT/media
validate_peer_file
''')
            self.assertNotEqual(result.returncode, 0, field)
        (self.path / 'peers').write_text('|'.join(base) + '\n')
        result = self.bash('client', '''
STATE_DIR=$TEST_ROOT
PEERS_FILE=$TEST_ROOT/peers
NODE_NAME=hhost_jf
WG_ADDRESS=10.96.0.1
WG_SUBNET=10.96.0.0/16
MEDIA_ROOT=$TEST_ROOT/new-media
confirm() { return 0; }
prompt() { printf '%s\\n' "$1" >> "$TEST_ROOT/prompts"; }
collect_peers
[[ ! -s $NEW_PEERS_FILE ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('NFS Server Peer 名称', (self.path / 'prompts').read_text())

    def test_existing_mount_and_directory_permissions_are_untouched(self):
        for mounted in [False, True]:
            media = self.path / ('mounted' if mounted else 'local')
            media.mkdir(mode=0o711)
            media.chmod(0o711)
            (self.path / 'peers').write_text('one|10.96.0.2|test|203.0.113.10:35669|' + str(media) + '\n')
            runtime = self.path / 'runtime'
            runtime.mkdir(exist_ok=True)
            helper = runtime / 'mounts'
            helper.write_text('#!/bin/bash\nexit ' + ('1' if mounted else '0') + '\n')
            helper.chmod(0o755)
            result = self.bash('client', '''
RUNTIME_DIR=$TEST_ROOT/runtime
PEERS_FILE=$TEST_ROOT/peers
NFS_PORT=8388
FSTAB_BEGIN='# BEGIN NFS_WG_MANAGER'
FSTAB_END='# END NFS_WG_MANAGER'
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
write_fstab
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(media.stat().st_mode & 0o777, 0o711)

    @unittest.skipUnless(shutil.which('systemd-analyze') and shutil.which('cc') and
                         Path('/usr/lib/systemd/system-generators/systemd-fstab-generator').exists(),
                         'requires systemd offline tools and a C compiler for the cache redirect stub')
    def test_generated_units_have_no_boot_dependency_cycle(self):
        runtime = self.path / 'runtime'
        runtime.mkdir()
        (self.path / 'peers').write_text('one|10.96.0.2|test|203.0.113.10:35669|' + str(self.path / 'media/one') + '\n')
        # Helper stubs are installed after generation, so no real mount or service can run.
        result = self.bash('client', '''
RUNTIME_DIR=$TEST_ROOT/runtime
MEDIA_ROOT=$TEST_ROOT/media
CONTAINER_NAME=jellyfin
PEERS_FILE=$TEST_ROOT/peers
NFS_PORT=8388
WG_INTERFACE=wg0
FSTAB_BEGIN='# BEGIN NFS_WG_MANAGER'
FSTAB_END='# END NFS_WG_MANAGER'
DOCKER_BEGIN='# BEGIN NFS_WG_MANAGER Docker ordering'
DOCKER_END='# END NFS_WG_MANAGER Docker ordering'
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
install_firewall_support
install_mount_support
printf '#!/bin/sh\\nexit 0\\n' > "$RUNTIME_DIR/mounts"
printf '#!/bin/sh\\nexit 0\\n' > "$RUNTIME_DIR/firewall"
docker() { if [[ $* == *'--format'* ]]; then printf '%s' "$MEDIA_ROOT"; fi; }
write_fstab
write_docker_ordering
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        units = self.path / 'etc/systemd/system'
        generated = self.path / 'generated'
        generated.mkdir()
        env = dict(os.environ, SYSTEMD_FSTAB=str(self.path / 'etc/fstab'), SYSTEMD_IN_INITRD='0')
        result = subprocess.run(['/usr/lib/systemd/system-generators/systemd-fstab-generator', str(generated)],
                                capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        mounts = list(generated.glob('*.mount'))
        self.assertEqual(len(mounts), 1, result.stderr)
        mount = mounts[0].read_text()
        self.assertIn('After=wg-quick@wg0.service nfs-wg-firewall.service nfs-wg-media-root.service', mount)
        self.assertIn('Requires=wg-quick@wg0.service nfs-wg-firewall.service nfs-wg-media-root.service', mount)
        for unit in ['docker.service', 'wg-quick@.service']:
            (units / unit).write_text('[Unit]\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\nExecStart=/bin/true\nRemainAfterExit=yes\n')
        # Use the distribution's actual nftables unit to retain its early-boot ordering.
        paths = [str(units), str(generated), '/usr/lib/systemd/system']
        env = dict(os.environ, SYSTEMD_UNIT_PATH=':'.join(paths), TMPDIR=str(self.path))
        # systemd-analyze hardcodes /tmp instead of honoring TMPDIR. Redirect only
        # its temporary-directory helper; leave unit/dependency verification intact.
        shim_source = self.path / 'cache-redirect.c'
        shim = self.path / 'cache-redirect.so'
        shim_source.write_text('''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int mkdtemp_malloc(const char *pattern, char **result) {
    int (*original)(const char *, char **) = dlsym(RTLD_NEXT, "mkdtemp_malloc");
    const char *cache = getenv("TMPDIR");
    if (cache && pattern && strncmp(pattern, "/tmp/", 5) == 0) {
        char *redirected = NULL;
        if (asprintf(&redirected, "%s/%s", cache, pattern + 5) < 0) return -ENOMEM;
        int rc = original(redirected, result);
        free(redirected);
        return rc;
    }
    return original(pattern, result);
}
''')
        result = subprocess.run(['cc', '-shared', '-fPIC', '-o', str(shim), str(shim_source), '-ldl'],
                                capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        env['LD_PRELOAD'] = str(shim) + (':' + env['LD_PRELOAD'] if env.get('LD_PRELOAD') else '')
        result = subprocess.run(['systemd-analyze', '--generators=no', '--man=no', 'verify',
            str(units / 'nfs-wg-media-root.service'), str(units / 'nfs-wg-mounts.timer'),
            str(units / 'nfs-wg-firewall.service'), str(units / 'docker.service'),
            str(mounts[0]), str(next(generated.glob('*.automount')))], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_nfs_runtime_protocol_and_port_checks(self):
        proc = self.path / 'nfsd'
        proc.mkdir()
        for versions, ports, success in [
            ('-2 -3 +4 -4.0 +4.1 -4.2', 'tcp 8388\ntcp 8388\n', True),
            ('-2 -3 +4 +4.1 -4.2', 'tcp 8388\n', False),
            ('-2 -3 +4 -4.0 +4.1 -4.2', 'tcp 2049\n', False),
            ('-2 -3 +4 -4.0 +4.1 -4.2', 'tcp 8388\nudp 8388\n', False)]:
            (proc / 'versions').write_text(versions + '\n')
            (proc / 'portlist').write_text(ports)
            isolated = functions('server').replace('/proc/fs/nfsd', str(proc))
            result = subprocess.run(['bash'], input='set -Eeuo pipefail\n' + isolated + '''
ss() { if [[ $* == *8388* ]]; then printf 'LISTEN tcp8388\\n'; fi; }
verify_nfs_service
''', capture_output=True, text=True)
            self.assertEqual(result.returncode, 0 if success else 1, result.stderr)

    def test_bad_mount_path_retries_same_peer(self):
        media = self.path / 'media'
        media.mkdir()
        (self.path / 'input').write_text('ddps_nft\n10.96.0.2\n' + 'A' * 43 + '=\n203.0.113.10:35669\n/media/nft/\n' + str(media / 'ddps_nft') + '\n\n')
        result = self.bash('client', '''
STATE_DIR=$TEST_ROOT
PEERS_FILE=$TEST_ROOT/absent-peers
NODE_NAME=hhost_jf
WG_ADDRESS=10.96.0.1
WG_SUBNET=10.96.0.0/16
MEDIA_ROOT=$TEST_ROOT/media
exec 8< "$TEST_ROOT/input"
prompt() { local answer; printf '%s\\n' "$1" >> "$TEST_ROOT/prompts"; IFS= read -r answer <&8; printf '%s' "$answer"; }
collect_peers
validate_peer_file
cp "$NEW_PEERS_FILE" "$TEST_ROOT/result"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        prompts = (self.path / 'prompts').read_text()
        self.assertEqual(prompts.count('的本地挂载目录'), 2)
        self.assertEqual(prompts.count('NFS Server Peer 名称'), 2)
        self.assertEqual(len((self.path / 'result').read_text().splitlines()), 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
