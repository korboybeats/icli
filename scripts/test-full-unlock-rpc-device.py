#!/usr/bin/env python3
"""Run the engine only against the disposable fixture this test launches.

Build Tests/FullUnlockRPC/{target,driver}.m for arm64e/iOS and sign both with
Resources/icli.entitlements first. No real device passcode is involved.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--target', type=Path, required=True)
parser.add_argument('--driver', type=Path, required=True)
parser.add_argument('--repeats', type=int, default=2)
parser.add_argument('--report', type=Path, default=Path('.build/device-rpc-result.json'))
args = parser.parse_args()
assert 1 <= args.repeats <= 10
assert args.target.is_file() and args.driver.is_file()
remote = '/var/jb/tmp/icli-rpc-' + uuid.uuid4().hex
process = None
pid = None
reports = []
subprocess.run(['ssh-iphone', '/var/jb/bin/mkdir -m 700 ' + remote], check=True)
try:
    for local, name in [(args.target, 'target'), (args.driver, 'driver')]:
        subprocess.run(['scp-iphone', str(local), remote + '/' + name], check=True)
    subprocess.run(['ssh-iphone', '/var/jb/usr/bin/chmod 755 ' + remote + '/target ' + remote + '/driver'], check=True)
    process = subprocess.Popen(['ssh-iphone', "printf 'PID=%s\\n' \"$$\"; exec " +
        shlex.quote(remote + '/target') + ' ' + shlex.quote(remote + '/result')],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = process.stdout.readline().strip()
    assert line.startswith('PID=') and line[4:].isdigit(), line
    pid = int(line[4:])
    ready = process.stdout.readline().strip()
    if ready != 'READY':
        raise RuntimeError('Fixture did not start: ' + process.stderr.read())
    for index in range(args.repeats):
        result = subprocess.run(['ssh-iphone', remote + '/driver ' + str(pid)],
            capture_output=True, text=True, timeout=40)
        reports.append({'iteration': index + 1, 'exit': result.returncode,
            'stdout': result.stdout, 'stderr': result.stderr})
        assert result.returncode == 0, reports[-1]
        observed = subprocess.check_output(['ssh-iphone', '/var/jb/bin/cat ' + remote + '/result'], text=True)
        assert observed.startswith('PASS ') and observed.endswith('count=' + str(index + 1)), observed
        assert process.poll() is None, 'fixture died after restoration'
        print(observed, flush=True)
finally:
    if process is not None:
        if pid and process.poll() is None:
            subprocess.run(['ssh-iphone', 'kill -TERM ' + str(pid)], capture_output=True)
        process.wait(timeout=10)
    subprocess.run(['ssh-iphone', '/var/jb/bin/rm -rf ' + remote], check=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(reports, indent=2) + '\n')
