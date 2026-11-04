#!/usr/bin/env python3
"""Physical phone acceptance via ssh-iphone and TestHost's independent state.

Only the dedicated TestHost is mutated. Does not unlock the phone, install,
retry actions, reboot, or change passcodes. The caller prepares the device.
"""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = '/var/jb/usr/bin/icli'
APP = 'dev.owngoal.icli.TestHost'
STATE = '/var/mobile/Library/Caches/icli-testhost/state.json'
REPORT = ROOT / '.build/verified-ui-device.json'
report = {'cases': [], 'trace': [], 'binary_sha256': hashlib.sha256((ROOT / '.build/icli').read_bytes()).hexdigest()}


def run(args, expected=0):
    start = time.monotonic()
    proc = subprocess.run(['ssh-iphone', shlex.join(args)], capture_output=True, text=True, timeout=90)
    report['trace'].append({'args': args, 'exit': proc.returncode, 'stdout': proc.stdout,
                            'stderr': proc.stderr, 'elapsed_ms': round((time.monotonic()-start)*1000)})
    assert proc.returncode == expected, report['trace'][-1]
    return json.loads(proc.stdout)


def cli(*args, expected=0):
    return run([BIN, *args], expected)


def state():
    return run(['/var/jb/bin/cat', STATE])


def url(host):
    value = 'icli-test://' + host
    cli('url', 'open', value)
    deadline = time.monotonic() + 5
    while state().get('last_url') != value:
        assert time.monotonic() < deadline, 'TestHost URL callback never completed'


def reset():
    url('reset')
    cli('ui', 'wait', '--identifier', 'counter.increment', '--timeout', '5')
    assert state()['counter'] == 0


def perform(tap='counter.increment', condition='--expect-value-changed', identifier='counter.status',
            expected=0, timeout='6', extra=()):
    return cli('ui', 'perform', '--app', APP, '--tap-identifier', tap,
               condition, identifier, '--timeout', timeout, *extra, expected=expected)


def case(name, body):
    result = body()
    report['cases'].append({'name': name, 'passed': True, 'evidence': result})
    REPORT.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS ' + name, flush=True)


def counter():
    reset()
    result = perform()
    observed = state()
    assert result['outcome'] == 'verified' and observed['counter'] == 1 and not observed.get('other_taps'), (result, observed)
    return result


def transitions():
    reset()
    appeared = perform('element.toggle', '--expect-appeared', 'element.ready')
    observed = state()
    assert appeared['verified'] and observed['delayed_visible'] and observed['toggle_taps'] == 1, (appeared, observed)
    # The second's wait after the tap is paced by displayed frames, not a sleep.
    assert appeared['trigger'] == 'frames', appeared
    disappeared = perform('element.toggle', '--expect-disappeared', 'element.ready')
    observed = state()
    assert disappeared['verified'] and not observed['delayed_visible'] and observed['toggle_taps'] == 2, (disappeared, observed)
    return [appeared, disappeared]


def baseline():
    reset()
    results = [perform(condition='--expect-appeared', identifier='screen.title', expected=1),
               perform(condition='--expect-disappeared', identifier='missing', expected=1)]
    assert all(r['outcome'] == 'refused' and not r['dispatch_attempted'] for r in results), results
    assert state()['counter'] == 0
    return results


def duplicates():
    reset()
    url('verified-duplicate')
    result = perform(expected=1)
    observed = state()
    assert result['outcome'] == 'refused' and not result['dispatch_attempted'], result
    assert observed['counter'] == 0 and not observed.get('other_taps'), observed
    return result


def same_labels():
    reset()
    url('verified-label')
    result = perform()
    observed = state()
    assert result['verified'] and observed['counter'] == 1 and not observed.get('other_taps'), (result, observed)
    return result


def refused_fixture(mode):
    reset()
    url('verified-' + mode)
    result = perform(expected=1)
    observed = state()
    assert result['outcome'] == 'refused' and not result['dispatch_attempted'], result
    assert observed['counter'] == 0 and not observed.get('other_taps'), observed
    return result


def label_alias():
    reset()
    result = perform(tap='Increment', expected=1)
    assert result['outcome'] == 'refused' and state()['counter'] == 0, result
    return result


def wrong_app():
    reset()
    result = cli('ui', 'perform', '--app', 'com.apple.Preferences', '--tap-identifier', 'counter.increment',
                 '--expect-value-changed', 'counter.status', expected=1)
    assert result['outcome'] == 'refused' and not result['dispatch_attempted'] and state()['counter'] == 0, result
    assert result['reason'] == 'intended app is not the verified foreground app', result
    return result


def timeout_once():
    reset()
    path = '/var/mobile/Library/Caches/icli-testhost/verified-failure.jpg'
    result = perform(condition='--expect-appeared', identifier='never.appears', timeout='2', expected=3,
                     extra=['--failure-screenshot', path])
    observed = state()
    assert result['outcome'] == 'sent_unconfirmed' and result['sent'] and observed['counter'] == 1, (result, observed)
    assert result['failure_screenshot']['bytes'] > 0, result
    image = subprocess.check_output(['ssh-iphone', shlex.join(['/var/jb/bin/cat', path])])
    assert image.startswith(b'\xff\xd8\xff'), 'failure capture is not JPEG'
    subprocess.run(['ssh-iphone', shlex.join(['/var/jb/bin/rm', '-f', path])], check=True)
    return result


def slow_once():
    reset()
    url('verified-slow')
    result = perform('element.toggle', '--expect-appeared', 'element.ready', expected=3, timeout='2')
    assert result['outcome'] == 'sent_unconfirmed' and result['sent'], result
    cli('ui', 'wait', '--identifier', 'element.ready', '--timeout', '5')
    observed = state()
    assert observed['delayed_visible'] and observed['toggle_taps'] == 1, observed
    return result


def foreground_lost():
    reset()
    url('verified-slow')
    args = [BIN, 'ui', 'perform', '--app', APP, '--tap-identifier', 'element.toggle',
            '--expect-appeared', 'element.ready', '--timeout', '8']
    proc = subprocess.Popen(['ssh-iphone', shlex.join(args)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 8
        while state().get('toggle_taps') != 1:
            assert time.monotonic() < deadline and proc.poll() is None, 'tap not observed'
        # Change foreground only after the independent oracle sees dispatch.
        cli('button', 'home')
        stdout, stderr = proc.communicate(timeout=15)
        result = json.loads(stdout)
        report['trace'].append({'args': args, 'exit': proc.returncode, 'stdout': stdout, 'stderr': stderr})
        assert proc.returncode == 3 and result['outcome'] == 'sent_unconfirmed', result
        assert state()['toggle_taps'] == 1
        return result
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)
        cli('app', 'launch', APP)


try:
    installed_hash = subprocess.check_output(['ssh-iphone', shlex.join(['/var/jb/usr/bin/sha256sum', BIN])], text=True).split()[0]
    assert installed_hash == report['binary_sha256'], 'installed binary does not match .build/icli'
    report['installed_sha256'] = installed_hash
    report['device'] = cli('device', 'info')
    cli('app', 'launch', APP)
    case('value transition and one independent counter increment', counter)
    case('appeared and disappeared transitions', transitions)
    case('already satisfied expectations refuse without input', baseline)
    case('duplicate identifiers refuse without input', duplicates)
    case('duplicate labels resolved by exact identifier', same_labels)
    case('disabled target refuses without input', lambda: refused_fixture('disabled'))
    case('overlay refuses without input', lambda: refused_fixture('overlay'))
    case('label alias cannot select an identifier', label_alias)
    case('wrong intended foreground app refuses', wrong_app)
    case('timeout never retries and captures valid JPEG', timeout_once)
    case('slow response remains one tap after timeout', slow_once)
    case('foreground change after input stays unconfirmed', foreground_lost)
    reset()
    report['passed'] = True
except BaseException as error:
    report['passed'] = False
    report['failure'] = repr(error)
    raise
finally:
    REPORT.write_text(json.dumps(report, indent=2) + '\n')
