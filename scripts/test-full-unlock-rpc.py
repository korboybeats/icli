#!/usr/bin/env python3
"""macOS arm64 integration, restricted to a process this test launches."""
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='icli-unlock-rpc-') as name:
    work = pathlib.Path(name)
    flags = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
             '-I', str(root / 'Sources/IcliPrivate/include'),
             '-I', str(root / 'Sources/IcliSystemPrivate/include'),
             '-I', str(root / 'Sources/IcliLaunchPrivate/include')]
    target, driver = work / 'target', work / 'driver'
    simple = os.environ.get('ICLI_RPC_SIMPLE_UNLOCK') == '1'
    subprocess.run(flags + [f'-DICLI_RPC_SIMPLE_UNLOCK={int(simple)}', str(root / 'Tests/FullUnlockRPC/target.m'), '-o', str(target)], check=True)
    subprocess.run(flags + [str(root / 'Tests/FullUnlockRPC/driver.m'),
                           str(root / 'Sources/IcliPrivate/MachExceptions/IcliMachExceptionServer.c'),
                           '-o', str(driver)], check=True)
    entitlements = work / 'target.plist'
    entitlements.write_text('<?xml version="1.0"?><plist version="1.0"><dict>'
                            '<key>com.apple.security.get-task-allow</key><true/></dict></plist>')
    subprocess.run(['codesign', '-s', '-', '--entitlements', str(entitlements), str(target)], check=True)
    subprocess.run(['codesign', '-s', '-', str(driver)], check=True)
    process = subprocess.Popen([str(target), str(work / 'result')], stdout=subprocess.PIPE, text=True)
    try:
        assert process.stdout.readline().strip() == 'READY'
        # This test needs task-port permission. It never changes host settings.
        for index in range(int(os.environ.get('ICLI_RPC_TEST_REPEATS', '2'))):
            subprocess.run(['sudo', '-n', str(driver), str(process.pid)], check=True, timeout=40)
            observed = (work / 'result').read_text()
            assert observed.startswith('PASS ') and observed.endswith(f'count={index + 1}'), observed
            assert process.poll() is None, 'target died after state restoration'
        result = (work / 'result').read_text()
        print(result)
        assert result.startswith('PASS ')
    finally:
        process.terminate()
        process.wait(timeout=5)
