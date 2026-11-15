#!/usr/bin/env python3
"""Lease concurrency and terminal/explicit bypass checks over one SSH connection.

Requires a free device and owns its test lease. Silent mode setters only reapply
its current state. Bypass checks run without exporting the test lease's token.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--report', default='.build/lease-policy-device.json')
args = parser.parse_args()
expected = hashlib.sha256(Path('.build/icli').read_bytes()).hexdigest()
remote = r'''
import base64, hashlib, json, os, pathlib, pty, shutil, subprocess, tempfile, traceback
report = {'checks': [], 'commands': []}
owned = False
os.environ.pop('ICLI_LEASE', None)
def process(argv, expected=0, stdin=None, terminal=False):
    if terminal:
        master, slave = pty.openpty()
        try:
            if stdin is not None:
                os.write(master, stdin.encode() + b'\x04')
            p = subprocess.run(['icli', *argv], stdin=slave, text=True, capture_output=True, timeout=35)
        finally:
            os.close(slave)
            os.close(master)
    else:
        p = subprocess.run(['icli', *argv], input=stdin, text=True, capture_output=True, timeout=35)
    report['commands'].append({'argv': argv, 'terminal': terminal, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    assert p.returncode == expected, report['commands'][-1]
    return p
def run(argv, **kwargs):
    p = process(argv, **kwargs)
    return json.loads(p.stdout)
def session(argv, steps, **kwargs):
    p = process(argv, stdin='\n'.join(json.dumps(a) for a in steps)+'\n', **kwargs)
    rows = [json.loads(line) for line in p.stdout.splitlines()]
    assert rows[0]['ready'], rows
    return rows[1:]
def check(name): report['checks'].append(name)
try:
    actual = hashlib.sha256(pathlib.Path(shutil.which('icli')).read_bytes()).hexdigest()
    assert actual == EXPECTED, 'installed binary differs from .build/icli'
    report['sha256'] = actual
    before = run(['lease', 'status'])
    assert not before['held'], 'device busy; wait for the current task to release its lease'
    acquired = run(['lease', 'acquire', '--owner', 'icli-lease-policy-tests', '--ttl', '120'])
    token = acquired['token']
    owned = True
    before = run(['lease', 'status'])
    report['owner'] = before['owner']
    with tempfile.TemporaryDirectory(prefix='icli-lease-policy-') as directory:
        path = directory + '/test.txt'
        run(['fs','write',path,'0123456789'])
        data = run(['fs','read',path,'--offset','2','--limit','3','--binary'])
        assert base64.b64decode(data['content']) == b'234' and data['truncated']
        run(['fs','ls',directory]); run(['fs','find',directory,'test'])
        run(['fs','copy',path,directory+'/copy.txt'])
        run(['fs','move',directory+'/copy.txt',directory+'/moved.txt'])
        run(['fs','chmod',path,'600'])
        run(['fs','mkdir',directory+'/child'])
        run(['fs','rm',directory+'/moved.txt','--force'])
        check('file read/write/offset/list/find/copy/move/chmod/mkdir/remove without token')
        for argv in [['device','info'],['env','info'],['proc','list'],['pkg','list'],['app','frontmost'],['notify','get','com.korboy.icli.lease-policy-test']]:
            run(argv)
        check('background inspection without token')
        # Invalid targets/values remain harmless even if a real holder releases mid-run.
        guarded = [['screen','tap','--','-100','-100'], ['device','brightness','set','--','-1'],
                   ['app','launch','com.korboy.icli.nonexistent-lease-test'],
                   ['probe','-e','1+1'], ['flex','targets']]
        for argv in guarded:
            refused = run(argv, expected=75)
            assert refused['error'] == 'leased' and refused['owner'] == before['owner'], refused
        check('guarded input/settings/app/probe/flex refused with 75')
        for argv, terminal in [(['--ignore-lease','probe','-e','1+1'], False),
                               (['probe','-e','1+1'], True)]:
            answer = run(argv, terminal=terminal)
            assert answer['ok'] and answer['result'] == '2', answer
        check('explicit bypass and terminal input run guarded probe with redirected stdout')
        run(['--ignore-lease','flex','targets'])
        check('explicit bypass applies to Flex requests without app injection')
        silent = run(['cc','get','silent'])
        setter = ['cc','set','silent',silent['state']]
        for argv, terminal in [(setter, True), (['--ignore-lease', *setter], False)]:
            answer = run(argv, terminal=terminal)
            assert answer['enabled'] == silent['enabled'] and answer['changed'] is False, answer
        check('exact Silent mode setter runs through terminal and explicit bypass without changing state')
        inherited = run(['--ignore-lease','batch'], stdin=json.dumps([setter, setter]))
        assert inherited['ok'] and inherited['completed'] == 2, inherited
        for argv, terminal in [(['--ignore-lease','session'], False), (['session'], True)]:
            rows = session(argv, [setter, setter], terminal=terminal)
            assert [r['exit_code'] for r in rows] == [0,0], rows
        check('batch/session inherit explicit bypass; terminal session retains bypass after stdin replacement')
        scoped = [['--ignore-lease', *setter], setter,
                  ['--ignore-lease','fs','read',directory+'/missing'], setter,
                  ['--ignore-lease','not-a-command'], setter, ['fs','read',path]]
        scoped_batch = run(['batch'], expected=75, stdin=json.dumps([
            {'argv': a, 'continue_on_error': True} for a in scoped]))
        assert [r['exit_code'] for r in scoped_batch['steps']] == [0,75,1,75,64,75,0], scoped_batch
        rows = session(['session'], scoped)
        assert [r['exit_code'] for r in rows] == [0,75,1,75,64,75,0], rows
        check('per-step bypass cannot leak after success, runtime failure or parse failure in batch/session')
        forbidden = [['--ignore-lease', c] for c in ['batch','session','probe','flex','tests']]
        forbidden.append(['--ignore-lease','screen','shot','--stdout'])
        refused_batch = run(['batch'], expected=64, stdin=json.dumps([
            {'argv': a, 'continue_on_error': True} for a in forbidden]))
        assert [r['exit_code'] for r in refused_batch['steps']] == [64]*len(forbidden), refused_batch
        check('root bypass flag cannot hide forbidden nested runners or raw screenshot output')
        batch = run(['batch'], expected=75, stdin=json.dumps([
            ['fs','read',path], ['screen','tap','--','-100','-100'], ['fs','write',directory+'/must-not-exist','bad']]))
        assert batch['completed'] == 2 and batch['failed_step'] == 1, batch
        assert not pathlib.Path(directory+'/must-not-exist').exists()
        check('batch background succeeds, guarded step refuses, following write does not run')
        rows = session(['session'], [['fs','read',path], ['screen','tap','--','-100','-100'], ['fs','read',path]])
        assert [r['exit_code'] for r in rows] == [0,75,0], rows
        check('session checks every step and preserves background access after refusal')
        old = os.environ.get('ICLI_FAILURE_ARTIFACTS')
        os.environ['ICLI_FAILURE_ARTIFACTS'] = directory+'/artifacts'
        run(['fs','read',directory+'/missing'], expected=1)
        assert not pathlib.Path(directory+'/artifacts').exists()
        if old is None: os.environ.pop('ICLI_FAILURE_ARTIFACTS', None)
        else: os.environ['ICLI_FAILURE_ARTIFACTS'] = old
        check('background failure does not capture UI artifacts')
    after = run(['lease','status'])
    assert after['held'] and after['owner'] == before['owner'] and after['acquired_at'] == before['acquired_at'], after
    assert after['last_used_at'] == before['last_used_at'] and after['expires_at'] == before['expires_at'], after
    check('background and bypass commands preserved lease ownership and did not renew it')
    report['passed'] = True
except BaseException:
    report['passed'] = False
    report['error'] = traceback.format_exc()
finally:
    if owned:
        os.environ['ICLI_LEASE'] = token
        run(['lease','release'])
    print(json.dumps(report, indent=2))
raise SystemExit(0 if report['passed'] else 1)
'''
payload = 'EXPECTED = ' + repr(expected) + '\n' + remote
p = subprocess.run(['ssh-iphone','python3 -u -'], input=payload, capture_output=True, text=True, timeout=180)
report_path = Path(args.report)
report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.with_suffix('.log').write_text(p.stdout + p.stderr)
try:
    report = json.loads(p.stdout)
except json.JSONDecodeError:
    print(p.stdout + p.stderr)
    raise
report_path.write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k != 'commands'}, indent=2))
if not report['passed']: print(json.dumps(report['commands'][-2:], indent=2))
raise SystemExit(p.returncode)
