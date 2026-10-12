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
CACHE = Path('/srv/paseo/cache/NFS_Wireguard_V3.5-validation')


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

    def test_export_format_uses_one_shared_root_fsid(self):
        (self.path / 'peers').write_text(
            'jf_srv1|10.96.0.1|' + 'A' * 43 + '=\n'
            'jf_srv2|10.96.0.10|' + 'B' * 43 + '=\n')
        result = self.bash('server', '''
MEDIA_ROOT=/srv/media
PEERS_FILE=$TEST_ROOT/peers
EXPORTS_BEGIN='# BEGIN NFS_WG_MANAGER'
EXPORTS_END='# END NFS_WG_MANAGER'
write_exports "$TEST_ROOT/exports" "$PEERS_FILE"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = (self.path / 'exports').read_text()
        self.assertIn('/srv/media -ro,sync,root_squash,no_subtree_check,fsid=0 10.96.0.1/32 10.96.0.10/32', data)
        self.assertEqual(data.count('fsid=0'), 1)

    @unittest.skipUnless(shutil.which('unshare') and
                         (shutil.which('exportfs') or Path('/usr/sbin/exportfs').exists()
                          or os.environ.get('NWM_EXPORTFS')),
                         'requires exportfs and unshare')
    def test_real_exportfs_accepts_two_peer_format(self):
        exportfs = os.environ.get('NWM_EXPORTFS') or shutil.which('exportfs') or '/usr/sbin/exportfs'
        (self.path / 'peers').write_text(
            'jf_srv1|10.96.0.1|' + 'A' * 43 + '=\n'
            'jf_srv2|10.96.0.10|' + 'B' * 43 + '=\n')
        result = self.bash('server', '''
MEDIA_ROOT=/srv/media
PEERS_FILE=$TEST_ROOT/peers
EXPORTS_BEGIN='# BEGIN NFS_WG_MANAGER'
EXPORTS_END='# END NFS_WG_MANAGER'
write_exports "$TEST_ROOT/exports" "$PEERS_FILE"
''')
        self.assertEqual(result.returncode, 0, result.stderr)

        root = Path(tempfile.mkdtemp(prefix='nwm-exportfs-', dir=CACHE))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / 'etc').mkdir(parents=True)
        (root / 'usr/sbin').mkdir(parents=True)
        (root / 'srv/media').mkdir(parents=True)
        (root / 'var/lib/nfs').mkdir(parents=True)
        shutil.copy2(self.path / 'exports', root / 'etc/exports')
        shutil.copy2(exportfs, root / 'usr/sbin/exportfs')

        ldd = subprocess.run(['ldd', exportfs], capture_output=True, text=True)
        if ldd.returncode:
            self.skipTest('ldd cannot inspect exportfs: ' + ldd.stderr.strip())
        dependencies = set()
        for line in ldd.stdout.splitlines():
            match = re.search(r'=>\s+(/[^ ]+)', line) or re.match(r'\s*(/[^ ]+)\s+\(', line)
            if match:
                dependencies.add(match.group(1))
        for dependency in dependencies:
            target = root / dependency.lstrip('/')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(dependency, target)

        runner = (
            'import os, sys\n'
            'os.chroot(sys.argv[1])\n'
            'os.chdir("/")\n'
            'os.execv("/usr/sbin/exportfs", ["exportfs", "-rav"])\n'
        )
        result = subprocess.run(
            ['unshare', '--user', '--map-root-user', 'python3', '-c', runner, str(root)],
            capture_output=True, text=True)
        if result.returncode and 'Operation not permitted' in result.stderr:
            self.skipTest('user namespaces are unavailable')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('exporting 10.96.0.1/32:/srv/media', result.stdout)
        self.assertIn('exporting 10.96.0.10/32:/srv/media', result.stdout)
        etab = (root / 'var/lib/nfs/etab').read_text()
        self.assertEqual(etab.count('/srv/media'), 2)

    def test_v35_default_hostnames_are_user_facing_defaults(self):
        self.assertIn('NFS Server 示例：nft_srv1', source('server'))
        self.assertIn('Jellyfin 客户端示例：jf_srv1', source('client'))
        self.assertNotIn('ddps_nft', source('server'))
        self.assertNotIn('hhost_jf', source('server') + source('client'))

    def test_installers_offer_install_append_force_and_remove_modes(self):
        for role in ('server', 'client'):
            text = source(role)
            self.assertIn('1) 新安装 / 重新配置', text)
            self.assertIn('2) 追加', text)
            self.assertIn('3) Force 安装', text)
            self.assertNotIn('--add-client-peer', text)
            self.assertNotIn('--peer-name', text)
            self.assertNotIn('--peer-address', text)
            self.assertNotIn('--public-key-file', text)

    def test_install_mode_menu_selects_all_operations(self):
        expected = {'1': 'install|0', '2': 'append|0', '3': 'force|1', '4': 'remove|0'}
        for role in ('server', 'client'):
            for choice, value in expected.items():
                with self.subTest(role=role, choice=choice):
                    result = self.bash(role, '''
ROLE=$TEST_ROLE
NODE_FILE=$TEST_ROOT/node.conf
PEERS_FILE=$TEST_ROOT/peers.tsv
WG_CONFIG=$TEST_ROOT/wg0.conf
FORCE_MODE=0
prompt() { printf '%s' "$TEST_CHOICE"; }
select_install_mode
printf '%s|%s' "$INSTALL_MODE" "$FORCE_MODE"
''', {'TEST_ROLE': role, 'TEST_CHOICE': choice})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue(result.stdout.endswith(value), result.stdout)

    def test_existing_install_defaults_to_append_without_running_install(self):
        for role in ('server', 'client'):
            state = self.path / role
            state.mkdir()
            node = state / 'node.conf'
            node.write_text('ROLE=' + role + '\n')
            (state / 'peers.tsv').write_text('')
            (state / 'wg0.conf').write_text('managed\n')
            body = '''
ROLE=$TEST_ROLE
NODE_FILE=$TEST_STATE/node.conf
PEERS_FILE=$TEST_STATE/peers.tsv
WG_CONFIG=$TEST_STATE/wg0.conf
FORCE_MODE=0
APPLY_FIREWALL_MODE=0
prompt() { printf '%s\\n' "$1" >> "$TEST_STATE/prompts"; printf '2'; }
install_packages() { touch "$TEST_STATE/installed"; }
append_client_peer() { touch "$TEST_STATE/appended"; }
append_server_peer() { touch "$TEST_STATE/appended"; }
main
'''
            result = self.bash(role, body, {'TEST_ROLE': role, 'TEST_STATE': str(state)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((state / 'appended').exists())
            self.assertFalse((state / 'installed').exists())
            prompts = (state / 'prompts').read_text()
            self.assertIn('输入 1、2、3 或 4', prompts)
            self.assertNotIn('本机节点名称', prompts)

    def test_client_interactive_append_preserves_existing_peer(self):
        media = self.path / 'media'
        media.mkdir()
        old = ['nft_srv1', '10.96.0.2', 'A' * 43 + '=', '203.0.113.10:35669', str(media / 'nft_srv1')]
        (self.path / 'peers').write_text('|'.join(old) + '\n')
        (self.path / 'input').write_text(
            'sky_nfs\n10.96.0.10\n' + 'B' * 42 + 'A=\n203.0.113.20:35669\n' + str(media / 'sky_nfs') + '\n')
        result = self.bash('client', '''
STATE_DIR=$TEST_ROOT
PEERS_FILE=$TEST_ROOT/peers
MEDIA_ROOT=$TEST_ROOT/media
NODE_NAME=jf_srv1
WG_ADDRESS=10.96.0.1
WG_SUBNET=10.96.0.0/16
exec 8< "$TEST_ROOT/input"
prompt() { local answer; IFS= read -r answer <&8; printf '%s' "$answer"; }
collect_additional_peer
validate_peer_file
cp "$NEW_PEERS_FILE" "$TEST_ROOT/result"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = (self.path / 'result').read_text().splitlines()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0], '|'.join(old))
        self.assertEqual(rows[1], 'sky_nfs|10.96.0.10|' + 'B' * 42 + 'A=|203.0.113.20:35669|' + str(media / 'sky_nfs'))

    def test_client_append_rejects_public_key_path_and_reprompts_for_text(self):
        state = self.path / 'client-state'
        state.mkdir()
        media = self.path / 'media'
        media.mkdir()
        key = 'B' * 42 + 'A='
        key_file = self.path / 'nfs-server.pub'
        key_file.write_text(key + '\n')
        (state / 'client-peers.tsv').write_text('')
        (state / 'input').write_text('\n'.join([
            'sky_nfs', '10.96.0.10', str(key_file), f' {key} ',
            '203.0.113.20:35669', str(media / 'sky_nfs'),
        ]) + '\n')
        result = self.bash('client', '''
STATE_DIR=$TEST_ROOT/client-state
PEERS_FILE=$STATE_DIR/client-peers.tsv
MEDIA_ROOT=$TEST_ROOT/media
NODE_NAME=jf_srv1
WG_ADDRESS=10.96.0.1
WG_SUBNET=10.96.0.0/16
exec 8< "$STATE_DIR/input"
prompt() { local answer; printf '%s\\n' "$1" >> "$TEST_ROOT/prompts"; IFS= read -r answer <&8; trim_input "$answer"; }
collect_additional_peer
validate_peer_file
cp "$NEW_PEERS_FILE" "$TEST_ROOT/result"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.path / 'result').read_text(),
                         'sky_nfs|10.96.0.10|' + key + '|203.0.113.20:35669|' + str(media / 'sky_nfs') + '\n')
        prompts = (self.path / 'prompts').read_text()
        self.assertEqual(prompts.count('WireGuard 公钥'), 2)
        self.assertIn('直接粘贴', prompts)

    def test_server_unknown_peer_removal_is_read_only(self):
        state = self.path / 'server-state'
        state.mkdir()
        peers = state / 'server-peers.tsv'
        wg = state / 'wg0.conf'
        exports = self.path / 'exports'
        peer_row = 'kept_jf|10.96.0.10|' + 'A' * 43 + '=\n'
        wg_text = ('# Managed by NFS_Wireguard_Manager\n[Interface]\nAddress = 10.96.0.2/32\n'
                   '[Peer]\n# kept_jf\nPublicKey = ' + 'A' * 43 + '=\nAllowedIPs = 10.96.0.10/32\n')
        exports_text = ('# BEGIN NFS_WG_MANAGER\n/srv/media -ro,sync,root_squash,no_subtree_check,fsid=0 '
                        '10.96.0.10/32\n# END NFS_WG_MANAGER\n')
        peers.write_text(peer_row)
        wg.write_text(wg_text)
        exports.write_text(exports_text)
        node = state / 'node.conf'
        node.write_text('ROLE=server\nWG_ADDRESS=10.96.0.2\n')
        (state / 'input').write_text('not_configured\n')
        result = self.bash('server', '''
STATE_DIR=$TEST_ROOT/server-state
NODE_FILE=$STATE_DIR/node.conf
PEERS_FILE=$STATE_DIR/server-peers.tsv
WG_CONFIG=$STATE_DIR/wg0.conf
WG_INTERFACE=wg0
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
EXPORTS_BEGIN='# BEGIN NFS_WG_MANAGER'
EXPORTS_END='# END NFS_WG_MANAGER'
exec 8< "$STATE_DIR/input"
prompt() { local answer; IFS= read -r answer <&8; trim_input "$answer"; }
confirm() { touch "$STATE_DIR/confirmation-called"; return 0; }
remove_jellyfin_client_peer
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('未发现可清理对象：not_configured', result.stdout)
        self.assertEqual(peers.read_text(), peer_row)
        self.assertEqual(wg.read_text(), wg_text)
        self.assertEqual(exports.read_text(), exports_text)
        self.assertFalse((state / 'confirmation-called').exists())
        self.assertFalse(any(state.glob('.peer-remove.*')))

    def test_client_unknown_peer_removal_is_read_only(self):
        etc = self.path / 'etc'
        state = etc / 'nfs-wg-manager'
        wgdir = etc / 'wireguard'
        state.mkdir(parents=True)
        wgdir.mkdir()
        media = self.path / 'media'
        media.mkdir()
        node = state / 'node.conf'
        node.write_text('ROLE=client\nWG_ADDRESS=10.96.0.1\nMEDIA_ROOT=' + str(media) + '\n')
        wg = wgdir / 'wg0.conf'
        wg_text = ('# Managed by NFS_Wireguard_Manager\n[Interface]\nAddress = 10.96.0.1/32\n')
        wg.write_text(wg_text)
        fstab = etc / 'fstab'
        fstab_text = '# keep outside\n# BEGIN NFS_WG_MANAGER\n# END NFS_WG_MANAGER\n'
        fstab.write_text(fstab_text)
        (self.path / 'input').write_text('not_configured\n')
        result = self.bash('client', '''
ROLE=client
STATE_DIR=$TEST_ROOT/etc/nfs-wg-manager
NODE_FILE=$STATE_DIR/node.conf
PEERS_FILE=$STATE_DIR/client-peers.tsv
WG_CONFIG=$TEST_ROOT/etc/wireguard/wg0.conf
WG_INTERFACE=wg0
RUNTIME_DIR=$TEST_ROOT/runtime-missing
FSTAB_BEGIN='# BEGIN NFS_WG_MANAGER'
FSTAB_END='# END NFS_WG_MANAGER'
DOCKER_BEGIN='# BEGIN NFS_WG_MANAGER Docker ordering'
DOCKER_END='# END NFS_WG_MANAGER Docker ordering'
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
exec 8< "$TEST_ROOT/input"
prompt() { local answer; IFS= read -r answer <&8; trim_input "$answer"; }
confirm() { touch "$TEST_ROOT/confirmation-called"; return 0; }
remove_nfs_server_peer
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('未发现可清理对象：not_configured', result.stdout)
        self.assertFalse((state / 'client-peers.tsv').exists())
        self.assertEqual(wg.read_text(), wg_text)
        self.assertEqual(fstab.read_text(), fstab_text)
        self.assertFalse((self.path / 'confirmation-called').exists())
        self.assertFalse(any(state.glob('.peer-remove.*')))

    def test_peer_input_retries_only_invalid_field_and_trims_whitespace(self):
        media = self.path / 'media'
        media.mkdir()
        key = 'B' * 42 + 'A='
        (self.path / 'input').write_text('\n'.join([
            'sky_nfs', '10.96.0.999', ' 10.96.0.10 ', f' {key} ',
            ' 203.0.113.20:35669 ', f' {media / "sky_nfs"} ',
        ]) + '\n')
        (self.path / 'absent-peers').write_text('')
        result = self.bash('client', '''
STATE_DIR=$TEST_ROOT
PEERS_FILE=$TEST_ROOT/absent-peers
MEDIA_ROOT=$TEST_ROOT/media
NODE_NAME=jf_srv1
WG_ADDRESS=10.96.0.1
WG_SUBNET=10.96.0.0/16
exec 8< "$TEST_ROOT/input"
prompt() { local answer; IFS= read -r answer <&8; trim_input "$answer"; }
collect_additional_peer
cp "$NEW_PEERS_FILE" "$TEST_ROOT/result"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.path / 'result').read_text(),
                         'sky_nfs|10.96.0.10|' + key + '|203.0.113.20:35669|' + str(media / 'sky_nfs') + '\n')

    def test_initial_install_retries_invalid_variables_on_both_roles(self):
        cases = {
            'client': ['1', 'bad name', 'jf_srv1', '999.0.0.1', '10.96.0.1', 'bad-cidr', '10.96.0.0/16',
                       '70000', '35669', '/bad path', str(self.path / 'client-media'), 'bad name', 'jellyfin'],
            'server': ['1', 'bad name', 'nft_srv1', '999.0.0.1', '10.96.0.2', 'bad-cidr', '10.96.0.0/16',
                       '70000', '35669', '/bad path', str(self.path / 'server-media')],
        }
        for role, answers in cases.items():
            with self.subTest(role=role):
                state = self.path / (role + '-install')
                state.mkdir()
                (state / 'input').write_text('\n'.join(answers) + '\n')
                result = self.bash(role, '''
STATE_DIR=$TEST_STATE
ROLE=$TEST_ROLE
FORCE_MODE=0
APPLY_FIREWALL_MODE=0
WG_DEFAULT_SUBNET=10.96.0.0/16
WG_DEFAULT_PORT=35669
DEFAULT_MEDIA_ROOT=/opt/jellyfin/media
DEFAULT_CONTAINER=jellyfin
NFS_PORT=8388
NODE_FILE=$STATE_DIR/node.conf
WG_DIR=$STATE_DIR/wireguard
WG_CONFIG=$WG_DIR/wg0.conf
WG_KEY_FILE=$WG_DIR/wg0.key
PEERS_FILE=$STATE_DIR/peers.tsv
RUNTIME_DIR=$TEST_STATE/runtime
NFS_CONF_DIR=$TEST_STATE/nfs.conf.d
NFS_CONF_FILE=$NFS_CONF_DIR/99-nfs-wg-manager.conf
exec 8< "$TEST_STATE/input"
prompt() { local answer; printf '%s\\n' "$1" >> "$TEST_STATE/prompts"; IFS= read -r answer <&8; trim_input "$answer"; }
confirm() { return 1; }
install_packages() { :; }
ensure_manager_wg_config() { :; }
collect_peers() { NEW_PEERS_FILE=$TEST_STATE/new-peers; : > "$NEW_PEERS_FILE"; }
validate_peer_file() { :; }
load_or_create_key() { PRIVATE_KEY=test; PUBLIC_KEY=test-public; }
install_firewall_support() { :; }
install_mount_support() { :; }
stop_mount_recovery() { :; }
unmount_changed_peers() { :; }
save_node_state() { :; }
write_wg_config() { :; }
write_fstab() { :; }
write_docker_ordering() { :; }
write_nfs_config() { :; }
write_exports() { :; }
start_firewall() { :; }
start_wireguard() { :; }
start_services() { :; }
systemctl() { :; }
main
printf 'FINAL=%s|%s|%s|%s|%s|%s' "$NODE_NAME" "$WG_ADDRESS" "$WG_SUBNET" "$WG_LISTEN_PORT" "$MEDIA_ROOT" "${CONTAINER_NAME:-none}"
''', {'TEST_STATE': str(state), 'TEST_ROLE': role})
                self.assertEqual(result.returncode, 0, result.stderr)
                final = ('jf_srv1|10.96.0.1|10.96.0.0/16|35669|' + str(self.path / 'client-media') + '|jellyfin'
                         if role == 'client' else
                         'nft_srv1|10.96.0.2|10.96.0.0/16|35669|' + str(self.path / 'server-media') + '|none')
                self.assertIn('FINAL=' + final, result.stdout)
                prompts = (state / 'prompts').read_text()
                for prompt_text in ('节点名称', 'WireGuard IPv4 地址', 'WireGuard 网段', '端口', '媒体'):
                    self.assertGreaterEqual(prompts.count(prompt_text), 2, (role, prompt_text, prompts))
                if role == 'client':
                    self.assertGreaterEqual(prompts.count('容器名'), 2)

    def test_client_peer_removal_cleans_and_rolls_back(self):
        for failure in ('', 'malformed', 'sync', 'route', 'firewall', 'systemd', 'timer'):
            with self.subTest(failure=failure):
                state = self.path / ('remove-' + (failure or 'success'))
                etc = state / 'etc'
                nwm = etc / 'nfs-wg-manager'
                wgdir = etc / 'wireguard'
                runtime = state / 'usr/local/libexec/nfs-wg-manager'
                systemd = self.path / 'etc/systemd/system'
                media = state / 'media'
                old_mount, keep_mount = media / 'old', media / 'keep'
                old_mount.mkdir(parents=True)
                keep_mount.mkdir(parents=True)
                nwm.mkdir(parents=True)
                wgdir.mkdir(parents=True)
                runtime.mkdir(parents=True)
                systemd.mkdir(parents=True, exist_ok=True)
                old = (['old_nfs', 'broken-address', '', 'invalid', ''] if failure == 'malformed' else
                       ['old_nfs', '10.96.0.2', 'A' * 43 + '=', '203.0.113.10:35669', str(old_mount)])
                keep = ['keep_nfs', '10.96.0.3', 'B' * 42 + 'A=', '203.0.113.11:35669', str(keep_mount)]
                original_peers = '|'.join(old) + '\n' + '|'.join(keep) + '\n'
                (nwm / 'client-peers.tsv').write_text(original_peers)
                (nwm / 'node.conf').write_text('ROLE=client\nNODE_NAME=jf_srv1\nWG_ADDRESS=10.96.0.1\nWG_SUBNET=10.96.0.0/16\nMEDIA_ROOT=' + str(media) + '\nCONTAINER_NAME=jellyfin\n')
                original_wg = ('# Managed by NFS_Wireguard_Manager\n[Interface]\nAddress = 10.96.0.1/32\n'
                    '[Peer]\n# old_nfs\nPublicKey = ' + old[2] + '\nAllowedIPs = 10.96.0.2/32\n'
                    '[Peer]\n# keep_nfs\nPublicKey = ' + keep[2] + '\nAllowedIPs = 10.96.0.3/32\n')
                (wgdir / 'wg0.conf').write_text(original_wg)
                fstab = self.path / 'etc/fstab'
                fstab.parent.mkdir(parents=True, exist_ok=True)
                original_fstab = ('# keep outside manager block\n# BEGIN NFS_WG_MANAGER\n# old_nfs\n10.96.0.2:/ ' + str(old_mount) + ' nfs4 ro 0 0\n'
                    '# keep_nfs\n10.96.0.3:/ ' + str(keep_mount) + ' nfs4 ro 0 0\n# END NFS_WG_MANAGER\n')
                fstab.write_text(original_fstab)
                docker_dropin = systemd / 'docker.service.d/nfs-wg-manager.conf'
                docker_dropin.parent.mkdir(parents=True, exist_ok=True)
                original_docker = ('# BEGIN NFS_WG_MANAGER Docker ordering\n[Unit]\nWants=media-old.mount media-keep.mount\n'
                                   'After=media-old.mount media-keep.mount\n# END NFS_WG_MANAGER Docker ordering\n')
                docker_dropin.write_text(original_docker)
                auto_dropin = systemd / 'old.automount.d/nfs-wg-manager.conf'
                auto_dropin.parent.mkdir(parents=True, exist_ok=True)
                original_auto = '# Managed by NFS_Wireguard_Manager\n[Unit]\nAfter=nfs-wg-media-root.service\n'
                auto_dropin.write_text(original_auto)
                firewall = runtime / 'firewall'
                firewall.write_text('''#!/bin/bash
peers="$TEST_STATE/etc/nfs-wg-manager/client-peers.tsv"
[[ $TEST_FAILURE != firewall || $(wc -l < "$peers") -ne 1 ]]
''')
                firewall.chmod(0o755)
                mounts = runtime / 'mounts'
                mounts.write_text('#!/bin/bash\ncase "$1" in --check-old|--absent|--reconcile) exit 0 ;; *) exit 9 ;; esac\n')
                mounts.chmod(0o755)
                (state / 'input').write_text('old_nfs\n')
                (state / 'route').write_text('present')
                result = self.bash('client', '''
STATE_DIR=$TEST_STATE/etc/nfs-wg-manager
ROLE=client
NODE_FILE=$STATE_DIR/node.conf
PEERS_FILE=$STATE_DIR/client-peers.tsv
WG_DIR=$TEST_STATE/etc/wireguard
WG_CONFIG=$WG_DIR/wg0.conf
RUNTIME_DIR=$TEST_STATE/usr/local/libexec/nfs-wg-manager
WG_INTERFACE=wg0
FSTAB_BEGIN='# BEGIN NFS_WG_MANAGER'
FSTAB_END='# END NFS_WG_MANAGER'
DOCKER_BEGIN='# BEGIN NFS_WG_MANAGER Docker ordering'
DOCKER_END='# END NFS_WG_MANAGER Docker ordering'
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
PEER_REMOVE_ROLLBACK=0
PEER_REMOVE_ROUTE_REMOVED=0
PEER_REMOVE_BACKUP_DIR=''
PEER_REMOVE_AUTO_DROPIN=''
PEER_REMOVE_MOUNT_STOPPED=0
PEER_REMOVE_PEERS_STAGE=''
PEER_REMOVE_WG_STAGE=''
PEER_REMOVE_FSTAB_STAGE=''
trap cleanup EXIT
exec 8< "$TEST_STATE/input"
prompt() { local answer; IFS= read -r answer <&8; trim_input "$answer"; }
confirm() { return 0; }
systemd-escape() { printf '%s.%s' "${3##*/}" "${2#--suffix=}"; }
timeout() { shift 3; "$@"; }
systemctl() {
    case "$*" in
        'show --property=LoadState --value nfs-wg-mounts.timer'|'show --property=LoadState --value nfs-wg-mounts.service') printf 'not-found' ;;
        'show --property=LoadState --value old.automount'|'show --property=LoadState --value old.mount') printf 'loaded' ;;
        daemon-reload) [[ $TEST_FAILURE != systemd ]] ;;
        'enable --now nfs-wg-mounts.timer') [[ $TEST_FAILURE != timer ]] ;;
        *) return 0 ;;
    esac
}
wg() {
    case "$1" in
        show) return 0 ;;
        syncconf)
            if [[ $TEST_FAILURE == sync && ! -e $TEST_STATE/sync-failed ]]; then touch "$TEST_STATE/sync-failed"; return 1; fi
            return 0
            ;;
    esac
}
wg-quick() { printf '[Interface]\\n'; }
ip() {
    if [[ $* == *' show '* ]]; then
        [[ ! -e $TEST_STATE/route ]] || { printf '[{"dev":"wg0","type":"unicast"}]'; return; }
        printf '[]'
    elif [[ $* == *' del '* ]]; then [[ $TEST_FAILURE != route ]] || return 1; rm -f "$TEST_STATE/route"
    elif [[ $* == *' add '* ]]; then touch "$TEST_STATE/route"; fi
}
remove_nfs_server_peer
''', {'TEST_FAILURE': failure, 'TEST_STATE': str(state)})
                if failure not in ('', 'malformed'):
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual((nwm / 'client-peers.tsv').read_text(), original_peers)
                    self.assertEqual((wgdir / 'wg0.conf').read_text(), original_wg)
                    self.assertEqual(fstab.read_text(), original_fstab)
                    self.assertEqual(docker_dropin.read_text(), original_docker)
                    self.assertEqual(auto_dropin.read_text(), original_auto)
                    self.assertTrue((state / 'route').exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((nwm / 'client-peers.tsv').read_text(), '|'.join(keep) + '\n')
                    self.assertNotIn('# old_nfs', (wgdir / 'wg0.conf').read_text())
                    self.assertIn('# keep_nfs', (wgdir / 'wg0.conf').read_text())
                    self.assertNotIn('10.96.0.2:/', fstab.read_text())
                    self.assertIn('10.96.0.3:/', fstab.read_text())
                    self.assertIn('keep.mount', docker_dropin.read_text())
                    self.assertNotIn('old.mount', docker_dropin.read_text())
                    self.assertFalse(auto_dropin.exists())
                    self.assertFalse((state / 'route').exists())
                    self.assertFalse(old_mount.exists())

    def test_client_removes_orphaned_fstab_peer_without_peer_list_or_helpers(self):
        etc = self.path / 'etc'
        nwm = etc / 'nfs-wg-manager'
        nwm.mkdir(parents=True)
        media = self.path / 'media'
        orphan_path = media / 'orphan'
        orphan_path.mkdir(parents=True)
        (nwm / 'node.conf').write_text('ROLE=client\nWG_ADDRESS=10.96.0.1\nMEDIA_ROOT=' + str(media) + '\n')
        fstab = etc / 'fstab'
        fstab.write_text('# keep outside\n# BEGIN NFS_WG_MANAGER\n# orphan_nfs\n10.96.0.9:/ ' + str(orphan_path) + ' nfs4 ro 0 0\n# END NFS_WG_MANAGER\n')
        docker_dropin = etc / 'systemd/system/docker.service.d/nfs-wg-manager.conf'
        docker_dropin.parent.mkdir(parents=True)
        docker_dropin.write_text('# BEGIN NFS_WG_MANAGER Docker ordering\n[Unit]\nWants=nfs-wg-media-root.service wg-quick@wg0.service orphan.mount keep.mount\n'
                                'After=network-online.target nfs-wg-media-root.service wg-quick@wg0.service orphan.mount keep.mount\n'
                                '# END NFS_WG_MANAGER Docker ordering\n')
        (self.path / 'input').write_text('orphan_nfs\n')
        result = self.bash('client', '''
ROLE=client
STATE_DIR=$TEST_ROOT/etc/nfs-wg-manager
NODE_FILE=$STATE_DIR/node.conf
PEERS_FILE=$STATE_DIR/client-peers.tsv
WG_CONFIG=$TEST_ROOT/etc/wireguard/wg0.conf
WG_DIR=$TEST_ROOT/etc/wireguard
RUNTIME_DIR=$TEST_ROOT/runtime-missing
mkdir -p "$WG_DIR" "$RUNTIME_DIR"
WG_INTERFACE=wg0
FSTAB_BEGIN='# BEGIN NFS_WG_MANAGER'
FSTAB_END='# END NFS_WG_MANAGER'
DOCKER_BEGIN='# BEGIN NFS_WG_MANAGER Docker ordering'
DOCKER_END='# END NFS_WG_MANAGER Docker ordering'
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
PEER_REMOVE_ROLLBACK=0
PEER_REMOVE_ROUTE_REMOVED=0
PEER_REMOVE_BACKUP_DIR=''
PEER_REMOVE_AUTO_DROPIN=''
PEER_REMOVE_MOUNT_STOPPED=0
PEER_REMOVE_PEERS_STAGE=''
PEER_REMOVE_WG_STAGE=''
PEER_REMOVE_FSTAB_STAGE=''
trap cleanup EXIT
exec 8< "$TEST_ROOT/input"
prompt() { local answer; IFS= read -r answer <&8; trim_input "$answer"; }
confirm() { return 0; }
systemd-escape() { printf '%s.%s' "${3##*/}" "${2#--suffix=}"; }
timeout() { shift 3; "$@"; }
findmnt() { return 1; }
systemctl() {
    case "$*" in
        'show --property=LoadState --value nfs-wg-mounts.timer'|'show --property=LoadState --value nfs-wg-mounts.service') printf 'not-found' ;;
        'show --property=LoadState --value orphan.automount'|'show --property=LoadState --value orphan.mount') printf 'loaded' ;;
        'enable --now nfs-wg-mounts.timer') touch "$TEST_ROOT/timer-enabled" ;;
        *) return 0 ;;
    esac
}
ip() { printf '[]'; }
remove_nfs_server_peer
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('helper 缺失', result.stderr)
        self.assertTrue((nwm / 'client-peers.tsv').exists())
        self.assertEqual((nwm / 'client-peers.tsv').read_text(), '')
        self.assertNotIn('orphan_nfs', fstab.read_text())
        self.assertFalse(orphan_path.exists())
        self.assertTrue((self.path / 'timer-enabled').exists())
        self.assertNotIn('orphan.mount', docker_dropin.read_text())
        self.assertIn('keep.mount', docker_dropin.read_text())

    def test_client_removes_orphaned_wireguard_peer_without_peer_list(self):
        etc = self.path / 'etc'
        nwm = etc / 'nfs-wg-manager'
        wgdir = etc / 'wireguard'
        nwm.mkdir(parents=True)
        wgdir.mkdir(parents=True)
        (nwm / 'node.conf').write_text('ROLE=client\nWG_ADDRESS=10.96.0.1\nMEDIA_ROOT=' + str(self.path / 'media') + '\n')
        wg = wgdir / 'wg0.conf'
        wg.write_text('# Managed by NFS_Wireguard_Manager\n[Interface]\nAddress = 10.96.0.1/32\n'
                      '[Peer]\n# orphan_wg\nPublicKey = ' + 'A' * 43 + '=\nAllowedIPs = 10.96.0.9/32\n')
        (self.path / 'input').write_text('orphan_wg\n')
        result = self.bash('client', '''
ROLE=client
STATE_DIR=$TEST_ROOT/etc/nfs-wg-manager
NODE_FILE=$STATE_DIR/node.conf
PEERS_FILE=$STATE_DIR/client-peers.tsv
WG_DIR=$TEST_ROOT/etc/wireguard
WG_CONFIG=$WG_DIR/wg0.conf
RUNTIME_DIR=$TEST_ROOT/runtime-missing
WG_INTERFACE=wg0
FSTAB_BEGIN='# BEGIN NFS_WG_MANAGER'
FSTAB_END='# END NFS_WG_MANAGER'
DOCKER_BEGIN='# BEGIN NFS_WG_MANAGER Docker ordering'
DOCKER_END='# END NFS_WG_MANAGER Docker ordering'
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
PEER_REMOVE_ROLLBACK=0
PEER_REMOVE_ROUTE_REMOVED=0
PEER_REMOVE_BACKUP_DIR=''
PEER_REMOVE_AUTO_DROPIN=''
PEER_REMOVE_MOUNT_STOPPED=0
PEER_REMOVE_PEERS_STAGE=''
PEER_REMOVE_WG_STAGE=''
PEER_REMOVE_FSTAB_STAGE=''
trap cleanup EXIT
exec 8< "$TEST_ROOT/input"
prompt() { local answer; IFS= read -r answer <&8; trim_input "$answer"; }
confirm() { return 0; }
systemctl() { return 0; }
ip() { printf '[]'; }
remove_nfs_server_peer
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('# orphan_wg', wg.read_text())
        self.assertIn('磁盘配置已清理', result.stderr)
        self.assertTrue((nwm / 'client-peers.tsv').exists())
        self.assertEqual((nwm / 'client-peers.tsv').read_text(), '')

    def test_client_orphan_removal_failure_restores_missing_peer_list(self):
        etc = self.path / 'etc'
        nwm = etc / 'nfs-wg-manager'
        wgdir = etc / 'wireguard'
        nwm.mkdir(parents=True)
        wgdir.mkdir()
        node = nwm / 'node.conf'
        node.write_text('ROLE=client\nWG_ADDRESS=10.96.0.1\nMEDIA_ROOT=' + str(self.path / 'media') + '\n')
        wg = wgdir / 'wg0.conf'
        original_wg = ('# Managed by NFS_Wireguard_Manager\n[Interface]\nAddress = 10.96.0.1/32\n'
                       '[Peer]\n# orphan_wg\nPublicKey = ' + 'A' * 43 + '=\nAllowedIPs = 10.96.0.9/32\n')
        wg.write_text(original_wg)
        (self.path / 'input').write_text('orphan_wg\n')
        (self.path / 'routes').write_text('10.96.0.9\n')
        result = self.bash('client', '''
ROLE=client
STATE_DIR=$TEST_ROOT/etc/nfs-wg-manager
NODE_FILE=$STATE_DIR/node.conf
PEERS_FILE=$STATE_DIR/client-peers.tsv
WG_DIR=$TEST_ROOT/etc/wireguard
WG_CONFIG=$WG_DIR/wg0.conf
RUNTIME_DIR=$TEST_ROOT/runtime-missing
WG_INTERFACE=wg0
FSTAB_BEGIN='# BEGIN NFS_WG_MANAGER'
FSTAB_END='# END NFS_WG_MANAGER'
DOCKER_BEGIN='# BEGIN NFS_WG_MANAGER Docker ordering'
DOCKER_END='# END NFS_WG_MANAGER Docker ordering'
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
PEER_REMOVE_ROLLBACK=0
PEER_REMOVE_ROUTE_REMOVED=0
PEER_REMOVE_BACKUP_DIR=''
PEER_REMOVE_AUTO_DROPIN=''
PEER_REMOVE_MOUNT_STOPPED=0
PEER_REMOVE_PEERS_STAGE=''
PEER_REMOVE_WG_STAGE=''
PEER_REMOVE_FSTAB_STAGE=''
trap cleanup EXIT
exec 8< "$TEST_ROOT/input"
prompt() { local answer; IFS= read -r answer <&8; trim_input "$answer"; }
confirm() { return 0; }
systemctl() {
    case "$*" in
        'show --property=LoadState --value nfs-wg-mounts.timer'|'show --property=LoadState --value nfs-wg-mounts.service') printf 'not-found' ;;
        daemon-reload) return 1 ;;
        *) return 0 ;;
    esac
}
wg() { case "$1" in show|syncconf) return 0 ;; esac; }
wg-quick() { printf '[Interface]\\n'; }
ip() {
    if [[ $* == *' show '* ]]; then
        if grep -qx '10.96.0.9' "$TEST_ROOT/routes"; then printf '[{"dev":"wg0","type":"unicast"}]'; else printf '[]'; fi
    elif [[ $* == *' del '* ]]; then
        grep -vx '10.96.0.9' "$TEST_ROOT/routes" > "$TEST_ROOT/routes.tmp"
        mv "$TEST_ROOT/routes.tmp" "$TEST_ROOT/routes"
    elif [[ $* == *' add '* ]]; then printf '10.96.0.9\\n' >> "$TEST_ROOT/routes"; fi
}
remove_nfs_server_peer
''')
        self.assertEqual(result.returncode, 1)
        self.assertFalse((nwm / 'client-peers.tsv').exists())
        self.assertEqual(wg.read_text(), original_wg)
        self.assertIn('10.96.0.9', (self.path / 'routes').read_text())

    def test_server_peer_removal_cleans_exports_and_rolls_back(self):
        for failure in ('', 'malformed', 'sync', 'route', 'firewall', 'exports'):
            with self.subTest(failure=failure):
                state = self.path / ('server-remove-' + (failure or 'success'))
                state.mkdir()
                nwm, wgdir, runtime = state / 'state', state / 'wireguard', state / 'runtime'
                nwm.mkdir()
                wgdir.mkdir()
                runtime.mkdir()
                old = ['old_jf', 'broken-address', ''] if failure == 'malformed' else ['old_jf', '10.96.0.10', 'A' * 43 + '=']
                keep = ['keep_jf', '10.96.0.20', 'B' * 42 + 'A=']
                original_peers = '|'.join(old) + '\n' + '|'.join(keep) + '\n'
                (nwm / 'peers.tsv').write_text(original_peers)
                (nwm / 'node.conf').write_text('ROLE=server\nNODE_NAME=nft_srv1\nWG_ADDRESS=10.96.0.2\nWG_SUBNET=10.96.0.0/16\nMEDIA_ROOT=/srv/media\n')
                original_wg = ('# Managed by NFS_Wireguard_Manager\n[Interface]\nAddress = 10.96.0.2/32\n'
                    '[Peer]\n# old_jf\nPublicKey = ' + ('C' * 42 + 'A=' if failure == 'malformed' else old[2]) + '\nAllowedIPs = 10.96.0.10/32\n'
                    '[Peer]\n# keep_jf\nPublicKey = ' + keep[2] + '\nAllowedIPs = 10.96.0.20/32\n')
                (wgdir / 'wg0.conf').write_text(original_wg)
                exports = self.path / 'etc/exports'
                exports.parent.mkdir(parents=True, exist_ok=True)
                original_exports = ('# keep outside\n# BEGIN NFS_WG_MANAGER\n/srv/media -ro,sync,root_squash,no_subtree_check,fsid=0 '
                    '10.96.0.10/32 10.96.0.20/32\n# END NFS_WG_MANAGER\n')
                exports.write_text(original_exports)
                firewall = runtime / 'firewall'
                firewall.write_text('''#!/bin/bash
peers="$TEST_STATE/state/peers.tsv"
[[ $TEST_FAILURE != firewall || $(wc -l < "$peers") -ne 1 ]]
''')
                firewall.chmod(0o755)
                (state / 'routes').write_text('10.96.0.10\n10.96.0.20\n')
                (state / 'input').write_text('old_jf\n')
                result = self.bash('server', '''
STATE_DIR=$TEST_STATE/state
NODE_FILE=$STATE_DIR/node.conf
PEERS_FILE=$STATE_DIR/peers.tsv
WG_DIR=$TEST_STATE/wireguard
WG_CONFIG=$WG_DIR/wg0.conf
WG_KEY_FILE=$WG_DIR/wg0.key
RUNTIME_DIR=$TEST_STATE/runtime
WG_INTERFACE=wg0
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
EXPORTS_BEGIN='# BEGIN NFS_WG_MANAGER'
EXPORTS_END='# END NFS_WG_MANAGER'
SERVER_REMOVE_ROLLBACK=0
SERVER_REMOVE_ROUTE_REMOVED=0
SERVER_REMOVE_ADDRESS=''
SERVER_REMOVE_BACKUP_DIR=''
ADD_PEER_WG_STAGE=''
ADD_PEER_EXPORTS_STAGE=''
ADD_PEER_SYNC_FILE=''
NEW_PEERS_FILE=''
trap cleanup EXIT
exec 8< "$TEST_STATE/input"
prompt() { local answer; IFS= read -r answer <&8; trim_input "$answer"; }
confirm() { return 0; }
wg() {
    case "$1" in
        show) return 0 ;;
        syncconf)
            if [[ $TEST_FAILURE == sync && ! -e $TEST_STATE/sync-failed ]]; then touch "$TEST_STATE/sync-failed"; return 1; fi
            return 0
            ;;
    esac
}
wg-quick() { printf '[Interface]\\n'; }
ip() {
    if [[ $3 == route && $4 == show ]]; then
        local target=${6%/32}
        if grep -qx "$target" "$TEST_STATE/routes"; then printf '[{"dev":"wg0","type":"unicast"}]'; else printf '[]'; fi
    elif [[ $2 == route && $3 == del ]]; then
        [[ $TEST_FAILURE != route ]] || return 1
        grep -vx "${4%/32}" "$TEST_STATE/routes" > "$TEST_STATE/routes.tmp"
        mv "$TEST_STATE/routes.tmp" "$TEST_STATE/routes"
    elif [[ $2 == route && $3 == add ]]; then printf '%s\\n' "${4%/32}" >> "$TEST_STATE/routes"; fi
}
exportfs() {
    if [[ $TEST_FAILURE == exports && $(wc -l < "$PEERS_FILE") -eq 1 ]]; then
        printf 'exportfs: synthetic export error\\n' >&2
        return 1
    fi
    return 0
}
systemctl() { [[ $1 != is-active ]] || printf 'active\\n'; }
remove_jellyfin_client_peer
''', {'TEST_FAILURE': failure, 'TEST_STATE': str(state)})
                if failure not in ('', 'malformed'):
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual((nwm / 'peers.tsv').read_text(), original_peers)
                    self.assertEqual((wgdir / 'wg0.conf').read_text(), original_wg)
                    self.assertEqual(exports.read_text(), original_exports)
                    self.assertIn('10.96.0.10', (state / 'routes').read_text())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((nwm / 'peers.tsv').read_text(), '|'.join(keep) + '\n')
                    self.assertNotIn('# old_jf', (wgdir / 'wg0.conf').read_text())
                    self.assertIn('# keep_jf', (wgdir / 'wg0.conf').read_text())
                    self.assertNotIn('10.96.0.10/32', exports.read_text())
                    self.assertIn('10.96.0.20/32', exports.read_text())
                    self.assertNotIn('10.96.0.10', (state / 'routes').read_text())

    def test_server_removes_orphan_peer_without_peer_list(self):
        for failure in ('', 'exports'):
            with self.subTest(failure=failure):
                state = self.path / ('server-orphan-' + (failure or 'success'))
                nwm, wgdir, runtime = state / 'state', state / 'wireguard', state / 'runtime'
                nwm.mkdir(parents=True)
                wgdir.mkdir()
                runtime.mkdir()
                node = nwm / 'node.conf'
                node.write_text('ROLE=server\nNODE_NAME=nft_srv1\nWG_ADDRESS=10.96.0.2\n')
                wg = wgdir / 'wg0.conf'
                wg.write_text('# Managed by NFS_Wireguard_Manager\n[Interface]\nAddress = 10.96.0.2/32\n'
                              '[Peer]\n# orphan_jf\nPublicKey = ' + 'A' * 43 + '=\nAllowedIPs = 10.96.0.9/32\n')
                exports = self.path / 'etc/exports'
                exports.parent.mkdir(parents=True, exist_ok=True)
                original_exports = ('# BEGIN NFS_WG_MANAGER\n/srv/media -ro,sync,root_squash,no_subtree_check,fsid=0 '
                                    '10.96.0.9/32\n# END NFS_WG_MANAGER\n')
                exports.write_text(original_exports)
                fw = runtime / 'firewall'
                fw.write_text('''#!/bin/bash
[[ -f "$TEST_STATE/state/peers.tsv" && ! -s "$TEST_STATE/state/peers.tsv" ]] || exit 2
printf 'firewall\\n' >> "$TEST_STATE/order"
''')
                fw.chmod(0o755)
                (state / 'routes').write_text('10.96.0.9\n')
                (state / 'input').write_text('orphan_jf\n')
                result = self.bash('server', '''
STATE_DIR=$TEST_STATE/state
NODE_FILE=$STATE_DIR/node.conf
PEERS_FILE=$STATE_DIR/peers.tsv
WG_CONFIG=$TEST_STATE/wireguard/wg0.conf
RUNTIME_DIR=$TEST_STATE/runtime
WG_INTERFACE=wg0
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
EXPORTS_BEGIN='# BEGIN NFS_WG_MANAGER'
EXPORTS_END='# END NFS_WG_MANAGER'
SERVER_REMOVE_ROLLBACK=0
SERVER_REMOVE_ROUTE_REMOVED=0
SERVER_REMOVE_ADDRESS=''
SERVER_REMOVE_BACKUP_DIR=''
ADD_PEER_WG_STAGE=''
ADD_PEER_EXPORTS_STAGE=''
ADD_PEER_SYNC_FILE=''
NEW_PEERS_FILE=''
trap cleanup EXIT
exec 8< "$TEST_STATE/input"
prompt() { local answer; IFS= read -r answer <&8; trim_input "$answer"; }
confirm() { return 0; }
wg() { case "$1" in show) return 0 ;; syncconf) return 0 ;; esac; }
wg-quick() { printf '[Interface]\\n'; }
ip() {
    if [[ $* == *' show '* ]]; then
        if grep -qx '10.96.0.9' "$TEST_STATE/routes"; then printf '[{"dev":"wg0","type":"unicast"}]'; else printf '[]'; fi
    elif [[ $* == *' del '* ]]; then grep -vx '10.96.0.9' "$TEST_STATE/routes" > "$TEST_STATE/routes.tmp"; mv "$TEST_STATE/routes.tmp" "$TEST_STATE/routes"
    elif [[ $* == *' add '* ]]; then printf '10.96.0.9\\n' >> "$TEST_STATE/routes"; fi
}
exportfs() {
    printf 'exportfs\\n' >> "$TEST_STATE/order"
    if [[ $TEST_FAILURE == exports && ! -e $TEST_STATE/export-failed ]]; then
        touch "$TEST_STATE/export-failed"
        return 1
    fi
}
systemctl() { [[ $1 != is-active ]] || printf 'active\\n'; }
remove_jellyfin_client_peer
''', {'TEST_FAILURE': failure, 'TEST_STATE': str(state)})
                if failure:
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertFalse((nwm / 'peers.tsv').exists())
                    self.assertIn('# orphan_jf', wg.read_text())
                    self.assertEqual(exports.read_text(), original_exports)
                    self.assertIn('10.96.0.9', (state / 'routes').read_text())
                    self.assertNotIn('firewall', (state / 'order').read_text())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue((nwm / 'peers.tsv').exists())
                    self.assertEqual((nwm / 'peers.tsv').read_text(), '')
                    self.assertNotIn('# orphan_jf', wg.read_text())
                    self.assertNotIn('10.96.0.9/32', exports.read_text())
                    self.assertNotIn('10.96.0.9', (state / 'routes').read_text())
                    order = (state / 'order').read_text().splitlines()
                    self.assertLess(order.index('exportfs'), order.index('firewall'))

    def test_client_peer_append_transaction_and_rollback(self):
        for failure in ('', 'sync', 'route', 'firewall', 'systemd', 'timer'):
            with self.subTest(failure=failure):
                state = self.path / ('client-append-' + (failure or 'success'))
                etc = state / 'etc'
                wg_dir = etc / 'wireguard'
                nwm = etc / 'nfs-wg-manager'
                runtime = state / 'usr/local/libexec/nfs-wg-manager'
                media = state / 'media'
                media.mkdir(parents=True)
                wg_dir.mkdir(parents=True)
                nwm.mkdir(parents=True)
                runtime.mkdir(parents=True)
                key = 'A' * 43 + '='
                old = ['nft_srv1', '10.96.0.2', key, '203.0.113.10:35669', str(media / 'nft_srv1')]
                (nwm / 'client-peers.tsv').write_text('|'.join(old) + '\n')
                (nwm / 'node.conf').write_text(
                    'ROLE=client\nNODE_NAME=jf_srv1\nWG_ADDRESS=10.96.0.1\nWG_SUBNET=10.96.0.0/16\n'
                    'WG_LISTEN_PORT=35669\nMEDIA_ROOT=' + str(media) + '\nCONTAINER_NAME=jellyfin\n')
                (wg_dir / 'wg0.conf').write_text('# Managed by NFS_Wireguard_Manager\n[Interface]\n')
                (wg_dir / 'wg0.key').write_text('synthetic-private-key\n')
                fstab = self.path / 'etc/fstab'
                fstab.parent.mkdir(parents=True, exist_ok=True)
                fstab.write_text('# keep outside manager block\n# BEGIN NFS_WG_MANAGER\nold\n# END NFS_WG_MANAGER\n')
                firewall = runtime / 'firewall'
                firewall.write_text('''#!/bin/bash
peer_file="$TEST_STATE/etc/nfs-wg-manager/client-peers.tsv"
if [[ $TEST_FAILURE == firewall && $(wc -l < "$peer_file") -gt 1 ]]; then exit 1; fi
cp "$peer_file" "$TEST_STATE/firewall-peers"
''')
                firewall.chmod(0o755)
                mounts = runtime / 'mounts'
                mounts.write_text('''#!/bin/bash
case "$1" in
    --absent|--verify|--reconcile) exit 0 ;;
    *) exit 9 ;;
esac
''')
                mounts.chmod(0o755)
                (state / 'input').write_text(
                    'sky_nfs\n10.96.0.10\n' + 'B' * 42 + 'A=\n203.0.113.20:35669\n' + str(media / 'sky_nfs') + '\n')
                result = self.bash('client', '''
STATE_DIR=$TEST_STATE/etc/nfs-wg-manager
ROLE=client
WG_INTERFACE=wg0
NFS_PORT=8388
WG_DIR=$TEST_STATE/etc/wireguard
WG_CONFIG=$WG_DIR/wg0.conf
WG_KEY_FILE=$WG_DIR/wg0.key
PEERS_FILE=$STATE_DIR/client-peers.tsv
NODE_FILE=$STATE_DIR/node.conf
RUNTIME_DIR=$TEST_STATE/usr/local/libexec/nfs-wg-manager
MANAGED_MARKER='# Managed by NFS_Wireguard_Manager'
FSTAB_BEGIN='# BEGIN NFS_WG_MANAGER'
FSTAB_END='# END NFS_WG_MANAGER'
DOCKER_BEGIN='# BEGIN NFS_WG_MANAGER Docker ordering'
DOCKER_END='# END NFS_WG_MANAGER Docker ordering'
PEER_UPDATE_ROLLBACK=0
PEER_UPDATE_ROUTE_ADDED=0
PEER_UPDATE_ADDRESS=''
PEER_UPDATE_BACKUP_DIR=''
PEER_UPDATE_AUTO_DROPIN=''
PEER_UPDATE_MOUNT_DIR_CREATED=0
PEER_UPDATE_MOUNT_PATH=''
PEER_UPDATE_SYNC_FILE=''
trap cleanup EXIT
exec 8< "$TEST_STATE/input"
prompt() { local answer; IFS= read -r answer <&8; printf '%s' "$answer"; }
wg() {
    case $1 in
        show) return 0 ;;
        pubkey) cat >/dev/null; printf 'Cxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=\n' ;;
        syncconf)
            if [[ $TEST_FAILURE == sync && ! -e $TEST_STATE/sync-failed ]]; then touch "$TEST_STATE/sync-failed"; return 1; fi
            cp "$PEERS_FILE" "$TEST_STATE/wg-peers"
            ;;
    esac
}
wg-quick() { printf '[Interface]\n'; }
ip() {
    if [[ $* == *' show '* ]]; then printf '[]';
    elif [[ $* == *' add '* ]]; then
        [[ $TEST_FAILURE != route ]] || return 1
        printf '%s' "$*" > "$TEST_STATE/route"
    else rm -f "$TEST_STATE/route"; fi
}
systemctl() {
    case "$*" in
        'show --property=LoadState --value nfs-wg-mounts.timer'|'show --property=LoadState --value nfs-wg-mounts.service') printf 'not-found' ;;
        daemon-reload) [[ $TEST_FAILURE != systemd || $(wc -l < "$PEERS_FILE") -eq 1 ]] ;;
        'enable --now nfs-wg-mounts.timer') [[ $TEST_FAILURE != timer || $(wc -l < "$PEERS_FILE") -eq 1 ]] ;;
        *) return 0 ;;
    esac
}
systemd-escape() { printf 'nwm-test.mount'; }
docker() { return 1; }
append_server_peer
''', {'TEST_FAILURE': failure, 'TEST_STATE': str(state)})
                self.assertEqual(result.returncode, 1 if failure else 0, result.stderr)
                peers = (nwm / 'client-peers.tsv').read_text()
                self.assertEqual(peers, '|'.join(old) + '\n' if failure else
                                 '|'.join(old) + '\nsky_nfs|10.96.0.10|' + 'B' * 42 + 'A=|203.0.113.20:35669|' + str(media / 'sky_nfs') + '\n')
                self.assertEqual((wg_dir / 'wg0.conf').read_text().count('[Peer]'), 0 if failure else 2)
                self.assertEqual((state / 'route').exists(), not failure)
                self.assertEqual(sum(line.startswith('10.96.0.10:/') for line in fstab.read_text().splitlines()), 0 if failure else 1)
                self.assertIn('# keep outside manager block', fstab.read_text())

    def test_interactive_nfs_peer_append_transaction_and_rollback(self):
        for failure in ['', 'sync', 'route', 'firewall', 'exports', 'exports-silent', 'exports-no-restart']:
            with self.subTest(failure=failure):
                state = self.path / ('case-' + (failure or 'success'))
                state.mkdir()
                (self.path / 'etc').mkdir(exist_ok=True)
                exports = self.path / 'etc/exports'
                exports.write_text('# pre-existing exports\n')
                old_peer = 'jf_existing|10.96.0.1|' + 'A' * 43 + '=\n'
                (state / 'peers').write_text(old_peer)
                (state / 'node.conf').write_text('ROLE=server\nNODE_NAME=nft_srv1\nWG_ADDRESS=10.96.0.2\nWG_SUBNET=10.96.0.0/16\nWG_LISTEN_PORT=35669\nMEDIA_ROOT=/srv/media\n')
                (state / 'wg0.conf').write_text('# Managed by NFS_Wireguard_Manager\n[Interface]\nAddress = 10.96.0.2/32\n[Peer]\nAllowedIPs = 10.96.0.1/32\n')
                (state / 'wg0.key').write_text('synthetic-test-key\n')
                (state / 'jf.pub').write_text('B' * 42 + 'A=\n')
                runtime = state / 'runtime'
                runtime.mkdir()
                fw = runtime / 'firewall'
                fw.write_text('''#!/bin/bash
if [[ $TEST_FAILURE == firewall ]] && [[ $(wc -l < "$TEST_STATE/peers") -gt 1 ]]; then exit 1; fi
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
exec 8<<<"sky_jf
10.96.0.10
$TEST_STATE/jf.pub
  $TEST_PUBLIC_KEY  "
prompt() { local answer; printf '%s\\n' "$1" >> "$STATE_DIR/prompts"; IFS= read -r answer <&8; trim_input "$answer"; }
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
    if [[ ($TEST_FAILURE == exports || $TEST_FAILURE == exports-silent || $TEST_FAILURE == exports-no-restart) && $(wc -l < "$PEERS_FILE") -gt 1 ]]; then
        if [[ $TEST_FAILURE == exports ]]; then
            printf 'exportfs: synthetic invalid export\n' >&2
        fi
        if [[ $TEST_FAILURE == exports-no-restart ]]; then
            printf 'exportfs: synthetic online reload failure\n' >&2
        fi
        return 7
    fi
    cp "$PEERS_FILE" "$STATE_DIR/export-peers"
}
systemctl() {
    case "$*" in
        'cat nfs-server.service') return 0 ;;
        'restart nfs-server') touch "$STATE_DIR/nfs-restarted" ;;
        'is-active nfs-server') printf 'active\\n' ;;
        *) return 0 ;;
    esac
}
append_client_peer
''', {'TEST_FAILURE': failure, 'TEST_STATE': str(state), 'TEST_PUBLIC_KEY': 'B' * 42 + 'A='})
                success = failure == ''
                self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
                self.assertIn('公钥格式无效', result.stderr)
                prompts = (state / 'prompts').read_text()
                self.assertEqual(prompts.count('WireGuard 公钥'), 2)
                self.assertIn('直接粘贴', prompts)
                expected = old_peer + ('sky_jf|10.96.0.10|' + 'B' * 42 + 'A=\n' if success else '')
                self.assertEqual((state / 'peers').read_text(), expected)
                self.assertEqual((state / 'firewall-peers').read_text(), expected)
                self.assertEqual((state / 'wg-peers').read_text(), expected)
                self.assertEqual((state / 'route').exists(), success)
                if not success:
                    self.assertEqual(exports.read_text(), '# pre-existing exports\n')
                    self.assertIn('AllowedIPs = 10.96.0.1/32', (state / 'wg0.conf').read_text())
                    self.assertNotIn('AllowedIPs = 10.96.0.10/32', (state / 'wg0.conf').read_text())
                if failure == 'exports':
                    self.assertIn('synthetic invalid export', result.stderr)
                if failure == 'exports-silent':
                    self.assertIn('exportfs -rav 失败，退出码：7。', result.stderr)
                    self.assertIn('exportfs -rav 未返回诊断信息。', result.stderr)
                if failure == 'exports-no-restart':
                    self.assertIn('synthetic online reload failure', result.stderr)
                    self.assertNotIn('重启 nfs-server', result.stderr)
                    self.assertFalse((state / 'nfs-restarted').exists())

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
        self.assertNotIn('rdma = no', data)

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
NODE_NAME=jf_srv1
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
NODE_NAME=jf_srv1
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
        (self.path / 'input').write_text('nft_srv1\n10.96.0.2\n' + 'A' * 43 + '=\n203.0.113.10:35669\n/media/nft/\n' + str(media / 'nft_srv1') + '\n\n')
        result = self.bash('client', '''
STATE_DIR=$TEST_ROOT
PEERS_FILE=$TEST_ROOT/absent-peers
NODE_NAME=jf_srv1
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
