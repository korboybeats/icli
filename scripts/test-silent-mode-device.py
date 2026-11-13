#!/usr/bin/env python3
"""Run on the phone in an owned lease with the read-only native test helper.

Never acquires/takes over/releases somebody else's lease. Restores the original
Silent mode in finally. Volume setters are used only for failure cleanup if a
baseline unexpectedly changed. No playback, UI actions or app injection.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import time
import traceback

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--native-probe', required=True)
parser.add_argument('--expected-sha256', required=True)
parser.add_argument('--report', required=True)
args = parser.parse_args()
report = {'passed': False, 'restored': False, 'volumes_preserved': True, 'checks': [], 'commands': []}
original = None
baseline = None


def run(argv, stdin=None, expected=0, env=None):
    p = subprocess.run(argv, input=stdin, text=True, capture_output=True, timeout=20, env=env)
    report['commands'].append({'argv': argv, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    assert p.returncode == expected, report['commands'][-1]
    return p.stdout


def cli(*argv, **kwargs):
    return json.loads(run(['icli', *argv], **kwargs))


def native():
    result = json.loads(run([args.native_probe]))
    assert result['ok'] is True, result
    assert set(result['volumes']) == {'Audio/Video', 'Ringtone', 'Alarm', 'Siri'}, result
    assert all(v['available'] and 0 <= v['volume'] <= 1 for v in result['volumes'].values()), result
    return result


def state(result, want, changed=None):
    assert result['toggle'] == 'silent' and result['enabled'] is want, result
    assert result['state'] == ('on' if want else 'off'), result
    if changed is not None:
        assert result['changed'] is changed, result


def verify(want):
    deadline = time.monotonic() + 3
    while True:
        snap = native()
        if snap['volumes'] != baseline:
            report['volumes_preserved'] = False
            raise AssertionError(('volume baseline changed', snap, baseline))
        # Enum meanings and AX SpringBoard request verified in IDA, not inferred
        # from a successful setter or zero/nonzero coercion of the AF enum.
        if snap['ringer_observer_state'] == (2 if want else 1) and snap['springboard_muted'] is want:
            report.setdefault('native_checks', []).append(snap)
            state(cli('cc', 'get', 'silent'), want)
            return
        assert time.monotonic() < deadline, ('independent native state did not agree', want, snap)


def session_line(session):
    assert select.select([session.stdout], [], [], 20)[0], 'session reply timed out'
    line = session.stdout.readline()
    assert line, 'session ended before replying'
    return json.loads(line)


try:
    assert os.environ.get('ICLI_LEASE'), 'Run inside an owned ICLI_LEASE'
    lease = cli('lease', 'status')
    assert lease['held'] and lease['mine'], lease
    actual = hashlib.sha256(Path(shutil.which('icli')).read_bytes()).hexdigest()
    assert actual == args.expected_sha256, 'installed icli differs from the selected local artifact'
    report['sha256'] = actual
    report['lease_owner'] = lease['owner']
    report['help'] = run(['icli', 'cc', '--help'])
    assert 'silent' in report['help'] and 'ringer muted' in report['help'], report['help']
    original = cli('cc', 'get', 'silent')['enabled']
    assert type(original) is bool
    report['original_silent'] = original
    before = native()
    report['native_before'] = before
    baseline = before['volumes']
    verify(original)
    state(next(t for t in cli('cc', 'list')['toggles'] if t['toggle'] == 'silent'), original)
    report['checks'].append('get, list, help, installed hash and independent native baselines')

    # A setter must be guarded even when it would be idempotent.
    no_token = dict(os.environ)
    no_token.pop('ICLI_LEASE')
    state(cli('cc', 'get', 'silent', env=no_token), original)
    for argv in [('set', 'silent', 'on' if original else 'off'), ('toggle', 'silent')]:
        refused = cli('cc', *argv, expected=75, env=no_token)
        assert refused['error'] == 'leased', refused
    rows = [json.loads(line) for line in run(['icli', 'session'], stdin='\n'.join(json.dumps(a) for a in [
        ['cc', 'get', 'silent'], ['cc', 'toggle', 'silent'], ['cc', 'get', 'silent']]) + '\n', env=no_token).splitlines()]
    assert rows[0]['ready'] and [r['exit_code'] for r in rows[1:]] == [0, 75, 0], rows
    verify(original)
    report['checks'].append('background get and per-step session lease refusal without state change')

    state(cli('cc', 'set', 'silent', 'on' if original else 'off'), original, False)
    for want, changed in [(True, not original), (True, False), (False, True), (False, False)]:
        state(cli('cc', 'set', 'silent', 'on' if want else 'off'), want, changed)
        verify(want)
    for want in [True, False]:
        state(cli('cc', 'toggle', 'silent'), want, True)
        verify(want)
    report['checks'].append('on, off, both toggles and repeated idempotent sets with native and volume checks')

    sequence = [(['cc', 'set', 'silent', 'on'], True, True),
                (['cc', 'get', 'silent'], True, None),
                (['cc', 'set', 'silent', 'on'], True, False),
                (['cc', 'set', 'silent', 'off'], False, True),
                (['cc', 'set', 'silent', 'off'], False, False),
                (['cc', 'toggle', 'silent'], True, True),
                (['cc', 'toggle', 'silent'], False, True)]
    steps = [{'argv': a, 'expect': {'enabled': want, 'state': 'on' if want else 'off'}} for a, want, _ in sequence]
    batch = cli('batch', stdin=json.dumps(steps))
    assert batch['ok'] and batch['completed'] == len(sequence), batch
    for row, (_, want, changed) in zip(batch['steps'], sequence):
        assert row['ok'] and row['exit_code'] == 0, row
        state(row['result'], want, changed)
    verify(False)
    report['checks'].append('batch get/set/toggle and idempotence with expectations')

    session = subprocess.Popen(['icli', 'session'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, bufsize=1)
    try:
        assert session_line(session)['ready']
        for index, (argv, want, changed) in enumerate(sequence):
            session.stdin.write(json.dumps({'id': index, 'argv': argv}) + '\n')
            session.stdin.flush()
            row = session_line(session)
            report['commands'].append({'session_step': argv, 'result': row})
            assert row['id'] == index and row['ok'] and row['exit_code'] == 0, row
            state(row['result'], want, changed)
            verify(want)
    finally:
        session.stdin.close()
        try:
            session.wait(timeout=10)
        except subprocess.TimeoutExpired:
            session.kill()
            session.wait(timeout=5)
            raise
        assert session.returncode == 0, session.stderr.read()
    report['checks'].append('persistent session with independent state and volume checks after every step')
    report['passed'] = True
except BaseException:
    report['failure'] = traceback.format_exc()
finally:
    try:
        if original is not None:
            state(cli('cc', 'set', 'silent', 'on' if original else 'off'), original)
        if baseline is not None:
            current = native()
            if current['volumes'] != baseline:
                report['volumes_preserved'] = False
                report['passed'] = False
                for category, saved in baseline.items():
                    if current['volumes'][category] != saved:
                        cli('device', 'volume', 'set', str(saved['volume']), '--category', category)
            verify(original)
            report['restored'] = True
            report['native_after'] = native()
    except BaseException:
        report['passed'] = False
        report['cleanup_failure'] = traceback.format_exc()
    Path(args.report).write_text(json.dumps(report, indent=2) + '\n')

assert report['passed'] and report['restored'] and report['volumes_preserved'], report.get('failure', report.get('cleanup_failure', 'validation failed'))
print('PASS Silent mode: get/on/off/toggle, idempotence, batch, persistent session, lease policy, independent SpringBoard/AF state, four volume baselines, original state restored')
