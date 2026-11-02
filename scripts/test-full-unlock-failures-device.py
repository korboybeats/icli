#!/usr/bin/env python3
"""Run fault cases only against disposable phone fixtures with synthetic input."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--target', type=Path, required=True)
parser.add_argument('--driver', type=Path, required=True)
parser.add_argument('--report', type=Path, default=Path('.build/device-failures.json'))
args = parser.parse_args()
assert args.target.is_file() and args.driver.is_file()
remote = '/var/jb/tmp/icli-fault-' + uuid.uuid4().hex
reports = []

def ssh(command, **kwargs):
    return subprocess.run(['ssh-iphone', command], **kwargs)

ssh('/var/jb/bin/mkdir -m 700 ' + remote, check=True)
try:
    for source, name in [(args.target, 'target'), (args.driver, 'driver')]:
        subprocess.run(['scp-iphone', str(source), remote + '/' + name], check=True)
    ssh('/var/jb/usr/bin/chmod 755 ' + remote + '/target ' + remote + '/driver', check=True)
    cases = os.environ.get('ICLI_FAILURE_CASES',
        'data-fault secret deallocate reply restore restore-denied exit term hup int').split()
    for case in cases:
        fixture_pid = client_pid = None
        client = None
        mode = 'exit' if case == 'exit' else 'signal' if case in ('term', 'hup', 'int') else 'normal'
        fixture = subprocess.Popen(['ssh-iphone', "printf 'PID=%s\\n' \"$$\"; exec " +
            shlex.quote(remote + '/target') + ' ' + shlex.quote(remote + '/result') + ' ' + mode],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            line = fixture.stdout.readline().strip()
            assert line.startswith('PID=') and line[4:].isdigit(), line
            fixture_pid = int(line[4:])
            assert fixture.stdout.readline().strip() == 'READY'
            client = subprocess.Popen(['ssh-iphone', remote + '/driver ' + str(fixture_pid) + ' ' + case],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            line = client.stdout.readline().strip()
            assert line.startswith('DRIVER=') and line[7:].isdigit(), line
            client_pid = int(line[7:])
            if case in ('term', 'hup', 'int'):
                assert fixture.stdout.readline().strip() == 'GATE_WAITING'
                client.stdin.write('1'); client.stdin.flush()
                assert client.stdout.readline().strip() == 'SIGNAL_DELIVERED'
                ssh('kill -USR1 ' + str(fixture_pid), check=True)
            if case == 'exit':
                fixture.wait(timeout=20)
            try:
                client.wait(timeout=5 if case == 'exit' else 30)
                output, error = client.stdout.read(), client.stderr.read()
                result = {'case': case, 'exit': client.returncode, 'stdout': output, 'stderr': error}
            except subprocess.TimeoutExpired:
                result = {'case': case, 'exit': None, 'failure': 'client did not finish'}
            reports.append(result)
            print(json.dumps(result), flush=True)
        finally:
            # Kill the owned target first: never strand a live process that
            # depends on a stuck client's exception reply channel.
            if fixture_pid and fixture.poll() is None:
                ssh('kill -KILL ' + str(fixture_pid), capture_output=True)
            fixture.wait(timeout=10)
            if client is not None and client.poll() is None:
                if client_pid:
                    ssh('kill -KILL ' + str(client_pid), capture_output=True)
                client.wait(timeout=10)
finally:
    ssh('/var/jb/bin/rm -rf ' + remote, check=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(reports, indent=2) + '\n')
raise SystemExit(0 if reports and all(item.get('exit') == 0 and 'PASS mode=' in item.get('stdout', '') for item in reports) else 1)
