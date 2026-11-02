#!/usr/bin/env python3
"""Real Mach RPC failure tests against owned macOS fixtures, never a phone."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
reports = []
with tempfile.TemporaryDirectory(prefix='icli-unlock-failures-') as name:
    work = Path(name)
    flags = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
        '-I', str(root/'Sources/IcliPrivate/include'), '-I', str(root/'Sources/IcliSystemPrivate/include'),
        '-I', str(root/'Sources/IcliLaunchPrivate/include')]
    target, driver = work/'target', work/'driver'
    subprocess.run(flags+['-DICLI_RPC_QUIET=1', str(root/'Tests/FullUnlockRPC/target.m'), '-o', str(target)], check=True)
    subprocess.run(flags+[str(root/'Tests/FullUnlockRPC/fault-driver.m'),
        str(root/'Sources/IcliPrivate/MachExceptions/IcliMachExceptionServer.c'), '-o', str(driver)], check=True)
    profile = work/'target.plist'
    profile.write_text('<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>')
    subprocess.run(['codesign', '-s', '-', '--entitlements', str(profile), str(target)], check=True)
    subprocess.run(['codesign', '-s', '-', str(driver)], check=True)
    cases = os.environ.get('ICLI_FAILURE_CASES', 'data-fault secret deallocate reply restore restore-denied exit term hup int').split()
    for case in cases:
        fixture = subprocess.Popen([str(target), str(work/'result'),
            'exit' if case == 'exit' else 'signal' if case in ('term','hup','int') else 'normal'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        client = None
        client_pid = None
        try:
            assert fixture.stdout.readline().strip() == 'READY'
            client = subprocess.Popen(['sudo', '-n', str(driver), str(fixture.pid), case],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            line = client.stdout.readline().strip()
            assert line.startswith('DRIVER='), line
            client_pid = int(line.split('=')[1])
            if case in ('term','hup','int'):
                assert fixture.stdout.readline().strip() == 'GATE_WAITING'
                client.stdin.write('1'); client.stdin.flush()
                assert client.stdout.readline().strip() == 'SIGNAL_DELIVERED'
                fixture.send_signal(signal.SIGUSR1)
            if case == 'exit': fixture.wait(timeout=15)
            try:
                # Keep using the buffered streams after readline(); mixing
                # communicate() with them can discard an already-read result.
                client.wait(timeout=3 if case == 'exit' else 15)
                output, error = client.stdout.read(), client.stderr.read()
                result = {'case':case, 'exit':client.returncode, 'stdout':output, 'stderr':error}
            except subprocess.TimeoutExpired:
                result = {'case':case, 'exit':None, 'failure':'client remained waiting after target termination' if case=='exit' else 'client did not finish'}
            reports.append(result)
            print(json.dumps(result), flush=True)
        finally:
            # Destroy the disposable fixture before stopping a stuck client;
            # no live target is left depending on that client's reply channel.
            if fixture.poll() is None: fixture.kill()
            fixture.wait(timeout=5)
            if client is not None and client.poll() is None:
                if client_pid: subprocess.run(['sudo','-n','kill','-KILL',str(client_pid)], check=False)
                client.wait(timeout=5)
    report = Path(os.environ.get('ICLI_FAILURE_REPORT', str(root/'.build/full-unlock-failures.json')))
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(reports, indent=2)+'\n')
raise SystemExit(0 if reports and all(item.get('exit') == 0 and 'PASS mode=' in item.get('stdout', '') for item in reports) else 1)
