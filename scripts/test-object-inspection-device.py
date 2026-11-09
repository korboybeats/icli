#!/usr/bin/env python3
"""FLEX inspection acceptance against the dedicated icli TestHost fixture.

Bring it forward first. Pass ICLI_LEASE in the local environment. --expect-lazy
requires a fresh app process and proves FLEX is loaded only by inspection.
No app is quit or restarted by this script. Full responses are saved.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', default='dev.owngoal.icli.TestHost')
parser.add_argument('--expect-lazy', action='store_true')
parser.add_argument('--report', type=Path, default=ROOT / '.build/object-inspection-device.json')
args = parser.parse_args()
report = {'app': args.app, 'trace': [], 'checks': [], 'passed': False}
BIN = '/var/jb/usr/bin/icli'


def run(argv, success=True, stdin=None):
    prefix = ['env', 'ICLI_LEASE=' + os.environ['ICLI_LEASE']] if os.environ.get('ICLI_LEASE') else []
    process = subprocess.run(['ssh-iphone', shlex.join(prefix + argv)],
                             input=stdin, text=True, capture_output=True, timeout=45)
    trace = {'argv': argv, 'exit': process.returncode,
             'stdout': process.stdout, 'stderr': process.stderr}
    report['trace'].append(trace)
    assert (process.returncode == 0) == success, trace
    return process


def cli(*argv, **kwargs):
    return json.loads(run([BIN, *argv], **kwargs).stdout)


def check(name, condition):
    assert condition, name
    report['checks'].append(name)
    print('PASS ' + name, flush=True)


def probe(source):
    answer = cli('probe', '--app', args.app, '-e', source)
    assert answer['ok'], answer
    return answer['result']


def inspect(target, *flags, success=True):
    answer = cli('probe', '--app', args.app, '--inspect', target, *flags, success=success)
    assert answer['ok'] == success, answer
    return answer.get('result', answer)


try:
    report['hashes'] = {}
    for local, remote in [('icli', BIN), ('icli-probe-agent.dylib', '/var/jb/usr/lib/icli-probe-agent.dylib'),
                          ('libicli-flex.dylib', '/var/jb/usr/lib/icli/libFLEX.dylib')]:
        digest = hashlib.sha256((ROOT / '.build' / local).read_bytes()).hexdigest()
        installed = run(['/var/jb/usr/bin/sha256sum', remote]).stdout.split()[0]
        check(local + ' matches installed artifact', digest == installed)
        report['hashes'][local] = digest
    front = cli('app', 'frontmost')
    check('fixture is foreground', front['bundle_id'] == args.app and front['verified'])
    pid = front['pid']
    existence = "(function(){try{ObjC.use('FLEXObjectExplorer');return true}catch(e){return false}})()"
    if args.expect_lazy:
        check('ordinary probe leaves FLEX unloaded', probe(existence) == 'false')
    oracle = json.loads(probe("var r=ObjC.use('UIApplication').sharedApplication().keyWindow().rootViewController(); "
                              "var b=r.incrementButton(); "
                              "[String(r), String(b), b.convertPoint_toCoordinateSpace_({x:10,y:10}, b.window().screen().coordinateSpace()), "
                              "r.directActivation(), r.toggleDelay(), r.state().objectForKey_('counter')]"))
    root = inspect('root-controller', '--limit', '20')
    check('uses actual FLEX explorer in same process', root['engine'] == 'FLEXObjectExplorer' and root['pid'] == pid)
    check('root is exact live fixture object', root['class'] == 'TestController' and root['address'] == re.search(r'0x[0-9a-f]+', oracle[0])[0])
    check('reports inherited classes', root['class_hierarchy'] == ['TestController', 'UIViewController', 'UIResponder', 'NSObject'])
    properties = {x['name']: x for x in root['properties']}
    ivars = {x['name']: x for x in root['ivars']}
    check('reports known property and field types', properties['state']['type_encoding'] == '@"NSMutableDictionary"'
          and ivars['_directActivation']['type_encoding'] == 'B')
    check('reports known method', any(x['name'] == 'increment:' and x['declaring_class'] == 'TestController' for x in root['methods']))
    check('values absent by default', not root['include_values'] and all('value' not in x for x in root['properties'] + root['ivars']))
    check('inspection lazily loads FLEX', probe(existence) == 'true')
    if args.expect_lazy:
        check('inspection uses packaged FLEX runtime', root['runtime_image'].endswith('/usr/lib/icli/libFLEX.dylib'))
    val = inspect('root-controller', '--values', '--limit', '18')
    vals = {x['name']: x for x in val['properties']}
    check('property values match independent probe', vals['directActivation']['value'] == oracle[3] and vals['toggleDelay']['value'] == oracle[4])
    fields = {x['name']: x for x in val['ivars']}
    check('field values match independent probe', fields['_directActivation']['value'] == oracle[3])
    check('object values are bounded references', isinstance(vals['state']['value'], dict) and 'address' in vals['state']['value'])
    first = inspect('root-controller', '--limit', '2')
    second = inspect('root-controller', '--limit', '2', '--offset', '2')
    for group in ['properties', 'ivars', 'methods', 'class_methods']:
        check(group + ' pagination', first[group] + second[group] == root[group][:4]
              and first['totals'][group] == root['totals'][group] and first['truncated'][group])
    point = oracle[2]
    hit = inspect(str(point['x']) + ',' + str(point['y']), '--limit', '5')
    check('screen point resolves exact live button', hit['class'] == 'ActivationProbeButton' and hit['address'] == re.search(r'0x[0-9a-f]+', oracle[1])[0])
    window = inspect('window', '--limit', '2')
    check('window target works', window['class'] == 'UIWindow' and window['pid'] == pid)
    absent = inspect('1000000,1000000', success=False)
    check('missing screen object gives clear error', 'no live object' in absent['error'])
    for flags, message in [(['--inspect', 'bad'], 'target must be'), (['--inspect', 'nan,0'], 'target must be'),
                           (['--inspect', 'window', '--limit', '0'], '--limit'),
                           (['--inspect', 'window', '--offset', '-1'], '--offset'),
                           (['--inspect', 'window', '-e', '1'], 'cannot be combined'),
                           (['--values'], 'belong to --inspect')]:
        bad = run([BIN, 'probe', '--app', args.app, *flags], success=False)
        check('rejects ' + shlex.join(flags), message in bad.stdout + bad.stderr)
    inline = cli('probe', '-e', existence)
    check('FLEX stays out of icli itself', inline['ok'] and inline['result'] == 'false')
    check('inspection preserves process and counter', cli('app', 'frontmost')['pid'] == pid
          and json.loads(probe("r.state().objectForKey_('counter')")) == oracle[5])
    report['passed'] = True
finally:
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
