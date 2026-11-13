#!/usr/bin/env python3
"""File-only concurrency checks over one SSH connection; never shares a foreign token."""
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
import base64, hashlib, json, os, pathlib, shutil, subprocess, tempfile, traceback
report = {'checks': [], 'commands': []}
owned = False
os.environ.pop('ICLI_LEASE', None)
def run(argv, expected=0, stdin=None):
    p = subprocess.run(['icli', *argv], input=stdin, text=True, capture_output=True, timeout=35)
    report['commands'].append({'argv': argv, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    assert p.returncode == expected, report['commands'][-1]
    return json.loads(p.stdout)
def check(name): report['checks'].append(name)
try:
    actual = hashlib.sha256(pathlib.Path(shutil.which('icli')).read_bytes()).hexdigest()
    assert actual == EXPECTED, 'installed binary differs from .build/icli'
    report['sha256'] = actual
    before = run(['lease', 'status'])
    if not before['held']:
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
                   ['probe','-e','1+1']]
        for argv in guarded:
            refused = run(argv, expected=75)
            assert refused['error'] == 'leased' and refused['owner'] == before['owner'], refused
        check('guarded input/settings/app/probe refused with 75')
        batch = run(['batch'], expected=75, stdin=json.dumps([
            ['fs','read',path], ['screen','tap','--','-100','-100'], ['fs','write',directory+'/must-not-exist','bad']]))
        assert batch['completed'] == 2 and batch['failed_step'] == 1, batch
        assert not pathlib.Path(directory+'/must-not-exist').exists()
        check('batch background succeeds, guarded step refuses, following write does not run')
        p = subprocess.run(['icli','session'], input='\n'.join(json.dumps(a) for a in [
            ['fs','read',path], ['screen','tap','--','-100','-100'], ['fs','read',path]])+'\n', text=True, capture_output=True, timeout=35)
        report['commands'].append({'argv':['session'], 'exit':p.returncode, 'stdout':p.stdout, 'stderr':p.stderr})
        assert p.returncode == 0, p.stderr
        rows = [json.loads(line) for line in p.stdout.splitlines()]
        assert rows[0]['ready'] and [r['exit_code'] for r in rows[1:]] == [0,75,0], rows
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
    if owned:
        assert after['last_used_at'] == before['last_used_at'] and after['expires_at'] == before['expires_at'], after
        check('background commands did not renew lease')
    else:
        check('existing holder preserved; concurrent holder may renew its own lease')
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
