#!/usr/bin/env python3
"""Direct AX activation acceptance; requires the dedicated instrumented TestHost.

The optional research probe is built from Tests/VerifiedUIAction/activation-probe.m.
Its stdin barrier moves/covers/replaces the target AFTER retaining its AX reference.
No sleeps or repeated input requests are used.
"""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / '.build/ax-activation-research/device.json'
BIN = '/var/jb/usr/bin/icli'
PROBE = '/var/jb/usr/bin/icli-ax-activation-probe'
APP = 'dev.owngoal.icli.TestHost'
STATE = '/var/mobile/Library/Caches/icli-testhost/state.json'
report = {'cases': [], 'trace': [], 'binary_sha256': hashlib.sha256((ROOT/'.build/icli').read_bytes()).hexdigest()}


def call(*args, expected=0):
    result = subprocess.run(['ssh-iphone', shlex.join(args)], capture_output=True, text=True, timeout=40)
    report['trace'].append({'args': args, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
    assert result.returncode == expected, report['trace'][-1]
    return json.loads(result.stdout)


def cli(*args, expected=0):
    return call(BIN, *args, expected=expected)


def state():
    return call('/var/jb/bin/cat', STATE)


def url(host):
    value = 'icli-test://' + host
    cli('url', 'open', value)
    deadline = time.monotonic() + 5
    while state().get('last_url') != value:
        assert time.monotonic() < deadline


def reset(direct=False):
    url('reset')
    cli('ui', 'wait', '--identifier', 'counter.increment', '--timeout', '5')
    if direct:
        url('verified-direct')


def perform(expected=0, condition='--expect-value-changed', identifier='counter.status', timeout='6'):
    return cli('ui', 'perform', '--method', 'accessibility', '--app', APP,
               '--tap-identifier', 'counter.increment', condition, identifier, '--timeout', timeout, expected=expected)


def assert_no_touch(observed):
    assert not observed.get('touch_began') and not observed.get('touch_ended'), observed


def direct_success():
    reset(True)
    result = perform()
    observed = state()
    assert result['verified'] and result['method'] == 'accessibility' and result['ax_error'] == 0, result
    assert observed['counter'] == observed['activation_calls'] == 1 and observed['activation_handled'], observed
    assert_no_touch(observed)
    return {'result': result, 'oracle': observed}


def native_declines():
    reset()
    result = perform(expected=3)
    observed = state()
    assert result['outcome'] == 'sent_unconfirmed' and result['dispatch_attempted'] and not result['sent'], result
    assert result['ax_error'] == -25200 and observed['counter'] == 0 and observed['activation_calls'] == 1, (result, observed)
    assert_no_touch(observed)
    return {'result': result, 'oracle': observed}


def rejects_after_effect():
    reset()
    url('verified-direct-reject')
    result = perform(expected=3)
    observed = state()
    assert result['outcome'] == 'sent_unconfirmed' and not result['sent'], result
    assert observed['counter'] == observed['activation_calls'] == 1 and not observed['activation_handled'], observed
    assert_no_touch(observed)
    return {'result': result, 'oracle': observed}


def refuses(mode):
    reset(True)
    url('verified-' + mode)
    result = perform(expected=1)
    observed = state()
    assert result['outcome'] == 'refused' and not result['dispatch_attempted'], result
    assert observed['counter'] == 0 and not observed.get('activation_calls') and not observed.get('other_taps'), observed
    assert_no_touch(observed)
    return {'result': result, 'oracle': observed}


def timeout_once():
    reset(True)
    result = perform(expected=3, condition='--expect-appeared', identifier='never.appears', timeout='2')
    observed = state()
    assert result['outcome'] == 'sent_unconfirmed' and result['sent'] and result['ax_error'] == 0, result
    assert observed['counter'] == observed['activation_calls'] == 1, observed
    assert_no_touch(observed)
    return {'result': result, 'oracle': observed}


def retained_reference(change):
    reset(True)
    tree = cli('ui', 'tree')
    info = cli('screen', 'info')
    assert info['width'] == 430 and info['height'] == 932 and info['orientation'] == 0, info
    args = [PROBE, str(tree['pid']), 'counter.increment', 'barrier']
    process = subprocess.Popen(['ssh-iphone', shlex.join(args)], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert json.loads(process.stdout.readline()) == {'phase': 'resolved'}
        url('verified-' + change)
        process.stdin.write('1\n')
        process.stdin.flush()
        process.wait(timeout=10)
        output, error = process.stdout.read(), process.stderr.read()
        report['trace'].append({'args': args, 'exit': process.returncode, 'stdout': output, 'stderr': error})
        assert process.returncode == 0, report['trace'][-1]
        result = json.loads(output)
        observed = state()
        assert_no_touch(observed)
        assert not observed.get('other_taps'), observed
        if change == 'replace':
            assert result['ax_error'] != 0 and observed['counter'] == 0, (result, observed)
        else:
            assert result['ax_error'] == 0 and observed['counter'] == observed['activation_calls'] == 1, (result, observed)
        return {'probe': result, 'oracle': observed}
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)


def case(name, body):
    evidence = body()
    report['cases'].append({'name': name, 'passed': True, 'evidence': evidence})
    REPORT.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS ' + name, flush=True)


try:
    installed = subprocess.check_output(['ssh-iphone', shlex.join(['/var/jb/usr/bin/sha256sum', BIN])], text=True).split()[0]
    assert installed == report['binary_sha256'], 'installed/local binary mismatch'
    report['installed_sha256'] = installed
    report['device'] = cli('device', 'info')
    cli('app', 'launch', APP)
    case('supported direct activation changes value without touches', direct_success)
    case('ordinary button declining activation never falls back to touch', native_declines)
    case('handler returning false after side effect is never retried', rejects_after_effect)
    for mode in ['duplicate', 'disabled', 'overlay']:
        case(mode + ' refuses before activation', lambda mode=mode: refuses(mode))
    case('direct activation timeout remains one request with zero touches', timeout_once)
    case('retained target moves and decoy receives no action', lambda: retained_reference('relocate'))
    case('late overlay cannot redirect activation to the overlay', lambda: retained_reference('overlay'))
    case('removed target reference cannot activate same-identifier replacement', lambda: retained_reference('replace'))
    reset()
    report['passed'] = True
except BaseException as error:
    report['passed'] = False
    report['failure'] = repr(error)
    raise
finally:
    REPORT.write_text(json.dumps(report, indent=2) + '\n')
