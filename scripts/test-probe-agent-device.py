#!/usr/bin/env python3
"""Probe attachment and remote REPL acceptance against a foreground test app.

Uses ssh-iphone. Never quits/restarts the app. Pass --require-attach when the
app was launched normally and has no agent yet; otherwise tests agent reuse.
An existing lease token may be supplied through ICLI_LEASE.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', default='dev.owngoal.icli.ContainerFixture')
parser.add_argument('--require-attach', action='store_true')
parser.add_argument('--report', type=Path, default=ROOT / '.build/probe-agent-device.json')
args = parser.parse_args()
report = {'app': args.app, 'trace': [], 'checks': []}
BIN = '/var/jb/usr/bin/icli'


def run(argv, stdin=None, expected=0):
    prefix = ['env', 'ICLI_LEASE=' + os.environ['ICLI_LEASE']] if os.environ.get('ICLI_LEASE') else []
    process = subprocess.run(['ssh-iphone', shlex.join(prefix + argv)],
                             input=stdin, text=True, capture_output=True, timeout=45)
    trace = {'argv': argv, 'exit': process.returncode,
             'stdout': process.stdout, 'stderr': process.stderr}
    report['trace'].append(trace)
    assert process.returncode == expected, trace
    return process


def cli(*argv, **kwargs):
    return json.loads(run([BIN, *argv], **kwargs).stdout)


def check(name, condition):
    assert condition, name
    report['checks'].append(name)
    print('PASS ' + name, flush=True)


try:
    local_sha = hashlib.sha256((ROOT / '.build/icli').read_bytes()).hexdigest()
    installed = run(['/var/jb/usr/bin/sha256sum', BIN]).stdout.split()[0]
    report['binary_sha256'] = installed
    check('installed binary matches build', installed == local_sha)
    front = cli('app', 'frontmost')
    check('test app is foreground', front.get('bundle_id') == args.app and front.get('verified'))
    pid = front['pid']
    report['pid_before'] = pid
    if args.require_attach:
        absent = cli('probe', '--app', args.app, '--check', expected=1)
        check('--check does not attach', not absent['ok'] and 'no probe agent' in absent['error'])
    result = cli('probe', '--app', args.app, '-e',
                 "[ObjC.use('NSProcessInfo').processInfo().processIdentifier(), ObjC.use('NSThread').isMainThread()]")
    check('script runs in same app on main thread', result['ok'] and json.loads(result['result']) == [pid, True])
    check('attachment preserves process', cli('app', 'frontmost')['pid'] == pid)
    statements = """var replCounter = 41
replCounter + 1
function replDouble(n) {
return n * 2;
}
replDouble(replCounter)
print('remote-output'); 'remote-value'
throw new Error('expected-remote-error')
6 * 7
.help
.exit
"""
    repl = run([BIN, 'probe', '--app', args.app, 'repl'], stdin=statements)
    check('remote REPL identifies app', args.app in repl.stdout and str(pid) in repl.stdout)
    check('REPL keeps variables and handles multiline', '\n42\n' in repl.stdout and '\n82\n' in repl.stdout)
    check('REPL returns print output and result', 'remote-output' in repl.stdout and 'remote-value' in repl.stdout)
    check('REPL recovers from script errors', 'expected-remote-error' in repl.stderr and repl.stdout.count('\n42\n') == 2)
    check('REPL help describes app environment', 'api() is not' in repl.stdout)
    value = cli('probe', '--app', args.app, '-e', 'replCounter')
    check('exiting preserves app and context', value['ok'] and value['result'] == '41' and cli('app', 'frontmost')['pid'] == pid)
    short = run([BIN, 'probe', '--app', args.app], stdin="replCounter + 1\n.quit\n")
    check('no-script form opens app REPL', '\n42\n' in short.stdout)
    inline = cli('probe', '-e', '6 * 7')
    check('inline probe still works', inline['ok'] and inline['result'] == '42')
    report['passed'] = True
finally:
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
