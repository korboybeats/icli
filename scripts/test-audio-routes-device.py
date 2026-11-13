#!/usr/bin/env python3
"""Run on the phone inside an owned ICLI_LEASE; never starts playback.

Requires an available alternate UID from `icli cc audio list`. Restores the
original route in finally, including on failed assertions. Does not release a
lease it did not acquire. Invoke through the existing SSH shell/session.
"""
import argparse
import json
import os
import pathlib
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--alternate-uid', required=True)
parser.add_argument('--report', required=True)
args = parser.parse_args()
assert os.environ.get('ICLI_LEASE'), 'Run inside your owned ICLI_LEASE'
records = []


def cli(*argv, success=True):
    process = subprocess.run(['icli', *argv], text=True, capture_output=True, timeout=20)
    result = json.loads(process.stdout)
    records.append({'argv': argv, 'exit': process.returncode, 'result': result})
    assert (process.returncode == 0) == success, records[-1]
    return result


def native_selected():
    # Independent process/native route read, rather than the selector's result.
    value = cli('probe', '-e', 'var c=ObjC.use("AVSystemController").sharedAVSystemController(); '
                'JSON.stringify(c.pickableRoutesForCategory_("Audio/Video").$value)')
    assert value['ok'], value
    routes = json.loads(value['result'])
    picked = [r['RouteUID'] for r in routes if r.get('RouteCurrentlyPicked', False)]
    assert len(picked) == 1, routes
    return picked[0]


before = cli('cc', 'audio', 'list')
original = before['selected_uid']
assert isinstance(original, str) and original != args.alternate_uid, before
assert any(r['uid'] == args.alternate_uid for r in before['routes']), before
assert native_selected() == original
original_volume = cli('device', 'volume', 'get')
cc_before = cli('cc', 'list')
passed = False
restored = False
try:
    noop = cli('cc', 'audio', 'select', original)
    assert noop['changed'] is False and noop['selected_uid'] == original, noop
    missing = cli('cc', 'audio', 'select', 'icli-test-missing-' + str(uuid.uuid4()), success=False)
    assert missing['error'] == 'route_unavailable' and missing['selected_uid'] == original, missing
    assert native_selected() == original
    volumes = {original: original_volume}
    # Two cycles check both directions and each route's saved volume.
    for uid in [args.alternate_uid, original, args.alternate_uid, original]:
        selected = cli('cc', 'audio', 'select', uid)
        assert selected['changed'] is True and selected['selected_uid'] == uid, selected
        assert native_selected() == uid
        volume = cli('device', 'volume', 'get')
        if uid in volumes:
            assert abs(volume['volume'] - volumes[uid]['volume']) < 0.00001, (uid, volume, volumes[uid])
        volumes[uid] = volume
    assert cli('cc', 'list') == cc_before, 'Control Center toggle states changed'
    passed = True
finally:
    try:
        cli('cc', 'audio', 'select', original)
        restored = native_selected() == original
        assert restored, 'Original output was not restored'
    finally:
        pathlib.Path(args.report).write_text(json.dumps({
            'passed': passed, 'restored': restored, 'original_uid': original,
            'alternate_uid': args.alternate_uid, 'commands': records,
        }, indent=2) + '\n')
print('PASS audio routes: both directions, independent native reads, saved volumes, no-op, missing UID, cc states, original output restored')
