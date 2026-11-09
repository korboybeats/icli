#!/usr/bin/env python3
"""Acceptance for the complete icli FlexUltra port, on disposable TestHost apps.

ICLI_LEASE is forwarded to the phone. Reports retain complete protocol responses.
Only the icli ContainerFixture is accepted; sections may mutate its own UI/data.
The realm section reads Bark's (me.fin.bark) own Realm database and changes nothing.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import sqlite3
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP = 'dev.owngoal.icli.ContainerFixture'
BIN = '/var/jb/usr/bin/icli'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--section', choices=['core', 'storage', 'ui', 'trace', 'mcp', 'lifecycle', 'metadata', 'physical', 'realm', 'all'], default='core')
parser.add_argument('--report', type=Path)
args = parser.parse_args()
REPORT = args.report or ROOT / ('.build/full-flex-validation-' + args.section + '.json')
report = {'section': args.section, 'app': APP, 'trace': [], 'checks': [], 'conditional': [], 'passed': False}
TOKEN = os.environ.get('ICLI_LEASE')
BASE = (['env', 'ICLI_LEASE=' + TOKEN] if TOKEN else []) + [BIN]


def persist():
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + '\n')


def run(argv, stdin=None, timeout=140):
    p = subprocess.run(['ssh-iphone', shlex.join(BASE + list(argv))], input=stdin,
                       text=True, capture_output=True, timeout=timeout)
    report['trace'].append({'argv': list(argv), 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    persist()
    return p


def cli(*argv):
    p = run(argv)
    assert p.returncode == 0, report['trace'][-1]
    return json.loads(p.stdout)


def call(op, argv=(), expected=0, target=True):
    p = run(['flex', *argv, *(['--target', APP] if target else [])])
    report['trace'][-1]['operation'] = op
    persist()
    assert p.returncode == expected, report['trace'][-1]
    answer = json.loads(p.stdout)
    assert bool(answer.get('ok')) == (expected == 0), answer
    return answer.get('result') if expected == 0 else answer['error']


def raw(op, expected=0, **fields):
    return call(op, ['request', json.dumps({'op': op, 'target': APP, **fields}, separators=(',', ':'))], expected, target=False)


def check(name, condition=True):
    assert condition, name
    report['checks'].append(name)
    persist()
    print('PASS ' + name, flush=True)


def ready():
    cli('app', 'launch', APP, '--wait-foreground')
    identity = call('ping', ['ping'])
    report['pid'] = identity['pid']; report['generation'] = identity['generation']
    return identity


def window():
    return call('ui.key_window', ['ui', 'key-window'])['window']


def find(identifier):
    result = call('ui.find', ['ui', 'find', '--identifier', identifier])
    assert result['count'] == 1, result
    return result['matches'][0]


def get(handle, name, kind='property'):
    return call('object.get', ['object', 'get', handle, name, '--kind', kind])['value']


def invoke(handle, selector, *values, pin=False, class_method=False):
    argv = ['object', 'call', handle, selector, *[json.dumps(v, separators=(',', ':')) for v in values]]
    if pin: argv += ['--pin-result']
    if class_method: argv += ['--class']
    return call('object.call', argv)


def class_handle(name):
    return call('runtime.class', ['runtime', 'class', name])['class_object']['id']


def core():
    identity = ready()
    targets = call('targets', ['targets'], target=False)['targets']
    row = next(x for x in targets if x['pid'] == identity['pid'])
    check('target discovery returns real generation', row['generation'] == identity['generation'] and row['current_agent'])
    selected = call('target.resolve', ['resolve'])['target']
    check('PID resolution preserves identity', selected['pid'] == identity['pid'])
    history = call('target.history', ['history'])
    check('target history records observed connections', history['current_targets'] and history['events'])
    health = call('target.health', ['health'])
    check('health reports full engine', health['agent_responsive'] and health['capabilities']['heap_inspection'])
    check('Swift value reads retain original restriction', health['capabilities']['swift_value_inspection'] is False)
    info = call('agent.info', ['info'])
    check('agent info matches process', info['pid'] == identity['pid'])
    status = call('flex.status', ['flex', 'status'])
    check('private FLEX runtime loaded', status['available'] and status['loaded'])
    queries = [
        ('runtime.classes', ['runtime', 'classes', 'TestController', '--limit', '5']),
        ('runtime.class_protocols', ['runtime', 'class-protocols', 'TestController', '--direct-only', '--limit', '5']),
        ('runtime.images', ['runtime', 'images', 'IcliTestHost', '--limit', '5']),
        ('runtime.image_classes', ['runtime', 'image-classes', 'IcliTestHost', '--query', 'TestController', '--limit', '5']),
        ('runtime.protocols', ['runtime', 'protocols', 'UITextViewDelegate', '--limit', '5']),
        ('runtime.protocol', ['runtime', 'protocol', 'UITextViewDelegate', '--limit', '5']),
        ('runtime.protocol_classes', ['runtime', 'protocol-classes', 'UITextViewDelegate', '--query', 'TestController', '--limit', '5']),
        ('runtime.methods', ['runtime', 'methods', 'increment', '--class-name', 'TestController', '--limit', '5']),
        ('runtime.properties', ['runtime', 'properties', 'directActivation', '--class-name', 'TestController', '--limit', '5']),
        ('runtime.ivars', ['runtime', 'ivars', '_directActivation', '--class-name', 'TestController', '--limit', '5']),
    ]
    for op, argv in queries:
        call(op, argv); check(op)
    windows = call('ui.windows', ['ui', 'windows'])
    check('live windows exist', windows['count'] >= 1)
    root = window()['root_view_controller']
    button = find('counter.increment')
    for op, sub in [('object.inspect', 'inspect'), ('object.properties', 'properties'), ('object.ivars', 'ivars'), ('object.methods', 'methods')]:
        call(op, ['object', sub, root['id'], '--limit', '8', *([] if sub == 'methods' else ['--no-values'])]); check(op)
    old = get(root['id'], 'directActivation')
    call('object.set', ['object', 'set', root['id'], 'directActivation', 'true', '--kind', 'property'])
    check('property setter changes actual object', get(root['id'], 'directActivation') is True)
    call('object.set', ['object', 'set', root['id'], '_directActivation', json.dumps(old), '--kind', 'ivar'])
    check('ivar setter restores actual value', get(root['id'], '_directActivation', 'ivar') == old)
    allocated = invoke(class_handle('TestController'), 'new', pin=True, class_method=True)['value']['object']
    check('method invocation returns a hidden live object', allocated['class'] == 'TestController' and allocated['address'] != root['address'])
    check('hidden object has no UI parent', invoke(allocated['id'], 'parentViewController')['value'] is None)
    heap = call('heap.instances', ['heap', 'instances', 'TestController', '--limit', '20'])
    check('heap finds object outside UI tree', any(x['address'] == allocated['address'] for x in heap['instances']))
    call('object.pin', ['object', 'pin', allocated['id']]); check('object.pin')
    snapshot = call('heap.snapshot', ['heap', 'snapshot', '--query', 'TestController', '--limit', '5'])
    check('heap.snapshot returns real allocation data', snapshot is not None)
    call('heap.subclasses', ['heap', 'subclasses', 'UIViewController', '--limit', '5']); check('heap.subclasses')
    references = call('heap.references', ['heap', 'references', button['id'], '--limit', '10'])
    check('heap references find owning controller', root['address'] in json.dumps(references))
    graph = call('heap.reference_graph', ['heap', 'reference-graph', button['id'], '--max-depth', '1', '--max-nodes', '25', '--per-node-limit', '20'])
    check('heap reference graph finds owning controller', root['address'] in json.dumps(graph))
    call('object.unpin', ['object', 'unpin', allocated['id']]); check('object.unpin')
    swift = call('swift.inspect', ['swift', 'inspect', root['id'], '--no-values', '--limit', '5'])
    check('Swift inspector uses metadata-only path', swift['swift_values_available'] is False)
    for op, argv in [('investigate.screen', ['investigate', 'screen', '--no-values', '--no-image', '--max-nodes', '50', '--limit', '5']),
                     ('investigate.element', ['investigate', 'element', button['id'], '--no-values', '--no-reference-graph', '--limit', '5'])]:
        call(op, argv); check(op)
    stale = call('ping', ['ping', '--expected-generation', 'not-the-current-generation'], expected=1)
    check('generation mismatch refuses before operation', stale['code'] == 'target_generation_changed')
    check('app survives core operations', call('ping', ['ping'])['pid'] == identity['pid'])


def storage():
    ready()
    key = 'icli.flex.acceptance.' + uuid.uuid4().hex
    value = {'fixture': True, 'count': 42, 'items': ['one', 'two']}
    try:
        call('defaults.set', ['defaults', 'set', key, json.dumps(value)])
        check('defaults round trip', call('defaults.get', ['defaults', 'get', key])['value'] == value)
        entries = call('defaults.entries', ['defaults', 'entries', '--query', key])
        check('defaults enumeration includes written key', key in json.dumps(entries))
        experiment = call('experiment.begin', ['experiment', 'begin'])['experiment_id']
        call('defaults.set', ['defaults', 'set', key, 'false', '--experiment', experiment])
        state = call('experiment.status', ['experiment', 'status'])
        check('experiment tracks mutation', state['active'])
        call('experiment.rollback', ['experiment', 'rollback'])
        check('rollback restores actual default', call('defaults.get', ['defaults', 'get', key])['value'] == value)
        experiment = call('experiment.begin', ['experiment', 'begin'])['experiment_id']
        call('defaults.set', ['defaults', 'set', key, 'true', '--experiment', experiment])
        call('experiment.commit', ['experiment', 'commit'])
        check('commit retains actual default', call('defaults.get', ['defaults', 'get', key])['value'] is True)
    finally:
        call('defaults.remove', ['defaults', 'remove', key])
    check('defaults removal', call('defaults.get', ['defaults', 'get', key])['exists'] is False)
    home = cli('app', 'info', APP)['data_path']
    unique = 'icli-flex-' + uuid.uuid4().hex
    local = ROOT / '.build' / (unique + '.sqlite')
    db = sqlite3.connect(local)
    db.execute('create table acceptance (id integer primary key, title text)')
    db.executemany('insert into acceptance values (?, ?)', [(1, 'alpha'), (2, '中文')]); db.commit(); db.close()
    relative = 'Documents/' + local.name
    remote = home + '/' + relative
    subprocess.run(['scp-iphone', str(local), remote], check=True, capture_output=True, text=True)
    try:
        listing = call('filesystem.list', ['filesystem', 'list', 'Documents', '--root', 'home', '--limit', '1000'])
        check('filesystem lists fixture file', local.name in json.dumps(listing))
        stat = call('filesystem.stat', ['filesystem', 'stat', relative, '--root', 'home'])
        check('filesystem stat returns file', local.name in json.dumps(stat))
        data = call('filesystem.read', ['filesystem', 'read', relative, '--root', 'home', '--max-bytes', '32'])
        check('filesystem reads exact bytes', (base64.b64decode(data['base64']) if data['encoding'] == 'base64' else data['text'].encode()) == local.read_bytes()[:32])
        search = call('filesystem.search', ['filesystem', 'search', unique, 'Documents', '--root', 'home'])
        check('filesystem search finds fixture', local.name in json.dumps(search))
        tables = call('database.sqlite.tables', ['database', 'sqlite', 'tables', relative, '--root', 'home'])
        check('SQLite tables from real database', 'acceptance' in tables['tables'])
        columns = call('database.sqlite.columns', ['database', 'sqlite', 'columns', relative, 'acceptance', '--root', 'home'])
        check('SQLite columns', columns['columns'] == ['id', 'title'])
        rows = call('database.sqlite.rows', ['database', 'sqlite', 'rows', relative, 'acceptance', '--root', 'home', '--offset', '1', '--limit', '1'])
        # FLEXSQLiteDatabaseManager returns INTEGER and REAL columns as strings.
        check('SQLite paginated row and unicode', rows['total'] == 2 and rows['rows'] == [['2', '中文']])
        for sub in ['tables', 'columns', 'rows']:
            argv = ['database', 'realm', sub, relative, *([] if sub == 'tables' else ['acceptance']), '--root', 'home']
            error = call('database.realm.' + sub, argv, expected=1)
            check('Realm missing dependency is explicit: ' + sub, error['code'] == 'realm_unavailable')
        report['conditional'].append('Realm handlers present; no Realm runtime in fixture, data browsing needs a Realm app.')
    finally:
        subprocess.run(['ssh-iphone', shlex.join(['/var/jb/usr/bin/rm', '-f', remote])], check=True, capture_output=True)
        local.unlink(missing_ok=True)
    root = window()['root_view_controller']
    bookmark = call('bookmarks.add', ['bookmarks', 'add', root['id']])
    try:
        bookmarks = call('bookmarks.list', ['bookmarks', 'list'])
        check('bookmark retains selected live object', any(x['id'] == root['id'] for x in bookmarks['bookmarks']))
    finally:
        call('bookmarks.remove', ['bookmarks', 'remove', str(bookmark['index'])])
    for kind in ['http', 'websocket', 'firebase']:
        call('network.transactions', ['network', 'transactions', '--kind', kind, '--limit', '5']); check('network history ' + kind)
    call('logs.messages', ['logs', 'messages', '--query', unique, '--limit', '5']); check('log history')
    call('keychain.items', ['keychain', 'items', unique, '--limit', '5']); check('keychain fixture-only search')
    keychain = class_handle('FLEXKeychain')
    created = invoke(keychain, 'setPassword:forService:account:', 'acceptance-value', unique, unique, class_method=True)['value']
    check('fixture keychain item created', created is True)
    try:
        item = call('keychain.item', ['keychain', 'item', unique, unique])
        check('keychain reads actual fixture value', item['password'] == 'acceptance-value')
    finally:
        invoke(keychain, 'deletePasswordForService:account:', unique, unique, class_method=True)
    error = call('keychain.item', ['keychain', 'item', unique, unique], expected=1)
    check('missing keychain item handled', error['code'] == 'not_found')
    entries = call('globals.entries', ['globals', 'entries', '--limit', '200'])['entries']
    check('global entries enumerate', len(entries) > 0)
    # Explicitly choose a read-only app defaults inspector, never arbitrary global actions.
    # FLEX lists the app's NSUserDefaults inspector as "💾  Preferences".
    entry = next(x for x in entries if x['name'].endswith('Preferences') and x['has_view_controller_future'])
    call('globals.open', ['globals', 'open', str(entry['section_index']), str(entry['row_index'])]); check('global inspector opens without presentation')
    # The no-action result is part of the original protocol when the selected row has no rowAction.
    if not entry['has_row_action']:
        error = call('globals.invoke', ['globals', 'invoke', str(entry['section_index']), str(entry['row_index']), '--no-present'], expected=1)
        check('global action availability is checked', error['code'] == 'global_requires_open')


def fixture_mode(root, mode):
    expression = "ObjC.use('UIApplication').sharedApplication().keyWindow().rootViewController().handleURL_(ObjC.use('NSURL').URLWithString_(" + json.dumps('icli-test://' + mode) + ")); 'fixture-ready'"
    result = cli('probe', '--app', APP, '-e', expression)
    assert result['ok'] and result['result'] == 'fixture-ready', result


def ui():
    ready()
    root = window()['root_view_controller']['id']
    button = find('counter.increment')
    selector = json.dumps(button['selector'], separators=(',', ':'))
    call('ui.hierarchy', ['ui', 'hierarchy', '--max-depth', '3', '--max-children', '15', '--max-nodes', '100']); check('UI hierarchy')
    resolved = call('ui.resolve', ['ui', 'resolve', selector]); check('durable selector resolves', button['id'] in json.dumps(resolved))
    call('ui.wait', ['ui', 'wait', '--identifier', 'counter.increment', '--timeout-ms', '1000']); check('UI wait exists')
    call('ui.wait', ['ui', 'wait', '--identifier', 'icli.flex.absent', '--state', 'gone', '--timeout-ms', '1000']); check('UI wait gone')
    call('ui.deep_inspect', ['ui', 'deep-inspect', button['id'], '--no-values', '--limit', '5']); check('deep inspection')
    frame = button['frame']; x = frame['x'] + frame['width']/2; y = frame['y'] + frame['height']/2
    call('ui.hit_test', ['ui', 'hit-test', str(x), str(y)]); check('UI hit test')
    before = call('ui.snapshot_save', ['ui', 'snapshot-save', '--max-nodes', '200'])['snapshot_id']
    status = find('counter.status')['id']; old = get(status, 'text')
    call('ui.activate', ['ui', 'activate', selector]); check('activation changes counter', get(status, 'text') != old)
    old = get(status, 'text'); call('ui.tap', ['ui', 'tap', str(x), str(y)]); check('UI tap changes counter', get(status, 'text') != old)
    diff = call('ui.snapshot_diff', ['ui', 'snapshot-diff', before, '--max-nodes', '200'])
    check('snapshot diff detects real changes', sum(diff['counts'].values()) > 0)
    shot = call('ui.screenshot', ['ui', 'screenshot', '--format', 'png', '--max-dimension', '128'])
    check('screenshot returns actual PNG', base64.b64decode(shot['data']).startswith(b'\x89PNG\r\n\x1a\n'))
    snapshot = call('ui.snapshot', ['ui', 'snapshot', '--no-image', '--max-nodes', '100'])
    check('snapshot includes live UI', 'counter.increment' in json.dumps(snapshot))
    input_ref = find('input.text')['id']
    original = get(input_ref, 'text')
    try:
        call('ui.set_text', ['ui', 'set-text', input_ref, 'FlexUltra 中文']); check('text setter updates actual text', get(input_ref, 'text') == 'FlexUltra 中文')
        error = call('ui.select', ['ui', 'select', input_ref], expected=1)
        check('list selection rejects non-cell input', error['code'] == 'invalid_cell')
        call('ui.activate', ['ui', 'activate', input_ref])
        responder = call('ui.first_responder', ['ui', 'first-responder']); check('first responder is actual input', input_ref in json.dumps(responder))
        call('ui.dismiss_keyboard', ['ui', 'dismiss-keyboard']); check('keyboard dismissal')
    finally:
        call('ui.set_text', ['ui', 'set-text', input_ref, original])
    switch = invoke(class_handle('UISwitch'), 'new', pin=True, class_method=True)['value']['object']['id']
    try:
        call('ui.set_value', ['ui', 'set-value', switch, 'true', '--no-notify'])
        check('control value updates actual switch', invoke(switch, 'isOn')['value'] is True)
    finally:
        call('object.unpin', ['object', 'unpin', switch])
    scroll = find('scroll.list')['id']
    old_offset = invoke(scroll, 'contentOffset')['value']
    call('ui.scroll', ['ui', 'scroll', scroll, '--dy', '100'])
    check('scroll changes actual offset', invoke(scroll, 'contentOffset')['value'] != old_offset)
    call('ui.scroll', ['ui', 'scroll', scroll, '--dy', '-100'])
    fixture_mode(root, 'alert')
    alert = call('ui.alert', ['ui', 'alert']); check('alert inspection finds fixture title', 'Fixture alert' in json.dumps(alert))
    call('ui.alert_action', ['ui', 'alert-action', '--title', 'Allow']); check('alert action')
    fixture_mode(root, 'nav')
    call('ui.back', ['ui', 'back']); check('navigation goes back')
    call('ui.dismiss', ['ui', 'dismiss']); check('modal dismissed')
    call('flex.show', ['flex', 'show']); check('FLEX explorer shows')
    call('flex.hide', ['flex', 'hide']); check('FLEX explorer hides')


def trace():
    ready()
    # The tracer rebinds each image's imported objc_msgSend, so it records calls
    # made from those images; UIKit's action sends and object.call are outside
    # it. ui.key_window calls -[UIWindow alpha] from the agent image itself.
    started = call('trace.start', ['trace', 'start', '--method', 'alpha', '--max-events', '20', '--max-total-events', '100', '--max-duration-ms', '30000', '--arguments', 'none'])
    try:
        check('tracing starts', started['active'])
        state = call('trace.status', ['trace', 'status']); check('tracing reports same session', state['session_id'] == started['session_id'])
        call('ui.key_window', ['ui', 'key-window'])
        events = call('trace.events', ['trace', 'events', '--limit', '20'])
        check('trace captures actual method invocation', any(x.get('class') == 'UIWindow' and x.get('method') == 'alpha' for x in events['events']))
    finally:
        stopped = call('trace.stop', ['trace', 'stop']); check('trace stops', not stopped['active'])
    check('app responds after tracing stops', call('ping', ['ping'])['pid'] == report['pid'])


def mcp():
    ready()
    messages = [
        {'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'icli-acceptance','version':'1'}}},
        {'jsonrpc':'2.0','method':'notifications/initialized'},
        {'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}},
        {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'flexultra_ping','arguments':{'target':APP}}},
        {'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'flexultra_runtime_class','arguments':{'target':APP,'name':'TestController'}}},
        {'jsonrpc':'2.0','id':5,'method':'tools/call','params':{'name':'does_not_exist','arguments':{}}},
    ]
    p = run(['flex', 'mcp'], stdin=''.join(json.dumps(x) + '\n' for x in messages))
    assert p.returncode == 0, report['trace'][-1]
    answers = {x['id']:x for x in map(json.loads,p.stdout.splitlines())}
    check('MCP initializes', 'protocolVersion' in answers[1]['result'])
    tools = answers[2]['result']['tools']
    check('all 102 MCP tools exposed', len(tools) == 102 and len({x['name'] for x in tools}) == 102)
    for index in [3,4]:
        check('MCP tool succeeds ' + str(index), not answers[index]['result'].get('isError',False))
    check('MCP rejects unknown tool', 'error' in answers[5] or answers[5]['result'].get('isError',False))
    for op,argv in [('app.list',['app','list']),('app.running',['app','running']),('app.frontmost',['app','frontmost']),('app.launch',['app','launch',APP])]:
        call(op,argv,target=False); check(op)
    for op in ['input.tap','input.double_tap','input.long_press','input.swipe','input.drag','input.touch','input.touch_sequence']:
        error = raw(op,expected=1)
        check(op + ' validates before execution', error['code'] == 'invalid_arguments')


def lifecycle():
    previous = ready()
    old = window()['root_view_controller']['id']
    call('app.kill', ['app', 'kill', APP, '--force'], target=False)
    call('targets', ['targets'], target=False)
    cli('app','launch', APP, '--env','CHOICY_DENIED_TWEAKS_OVERRIDE=FLEXing:libFLEX','--wait-foreground')
    current = call('ping',['ping'])
    check('process relaunch creates a fresh generation', current['pid'] != previous['pid'] and current['generation'] != previous['generation'])
    error = call('object.inspect',['object','inspect',old,'--no-values'],expected=1)
    check('old object handles rejected after restart', error['code'] in ['stale_handle','object_expired','unknown_handle','stale_object_handle'])
    history = call('target.history',['history'])
    check('target history sees restart', 'disconnected' in json.dumps(history) and 'connected' in json.dumps(history))
    error = call('ping',['ping','--expected-generation',previous['generation']],expected=1)
    check('stale-generation request refused', error['code'] == 'target_generation_changed')


def metadata():
    ready()
    binary = ROOT / '.build/FlexMetadataFixture'
    assert binary.exists(), 'Build the fixture on the Mac with scripts/build-flex-metadata-fixture.sh and copy .build/FlexMetadataFixture here.'
    import plistlib
    info = ROOT / '.build/FlexMetadataFixture-Info.plist'
    info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.owngoal.icli.FlexMetadataFixture','CFBundleExecutable':'Fixture','CFBundlePackageType':'BNDL','CFBundleVersion':'1'}))
    home = cli('app','info',APP)['data_path']
    bundle = home + '/Documents/ICLIFlexMetadataFixture.bundle'
    subprocess.run(['ssh-iphone',shlex.join(['/var/jb/usr/bin/mkdir','-p',bundle])],check=True,capture_output=True)
    for source,dest in [(binary,'Fixture'),(info,'Info.plist')]:
        subprocess.run(['scp-iphone',str(source),bundle+'/'+dest],check=True,capture_output=True)
    expression = 'ObjC.use("NSBundle").bundleWithPath_(' + json.dumps(bundle) + ').load()'
    loaded = cli('probe','--app',APP,'-e',expression)
    check('Swift fixture loads in target process', loaded['ok'] and loaded['result'] == 'true')
    handle = class_handle('ICLIFlexMetadataFixture')
    inspected = call('swift.inspect',['swift','inspect',handle,'--no-values','--limit','10'])
    check('Swift metadata identifies actual Swift class', inspected['swift_metadata_available'])
    fields = {x['name']:x for x in inspected['ivars']}
    check('Swift metadata returns actual field names and offsets', set(fields) == {'count','title'} and all(isinstance(x['offset'],int) for x in fields.values()))
    check('Swift metadata never reads live values', inspected['swift_values_available'] is False and inspected['include_values'] is False and all('value' not in x for x in fields.values()))
    report['metadata_fixture_bundle'] = bundle


def physical():
    ready()
    root = window()['root_view_controller']['id']
    state_handle = get(root,'state')['object']['id']
    def count(key): return invoke(state_handle,'objectForKey:',key)['value'] or 0
    def center(identifier):
        f=find(identifier)['frame'];return f['x']+f['width']/2,f['y']+f['height']/2
    x,y=center('counter.increment');old=count('counter')
    raw('input.tap',x=x,y=y)
    check('physical tap reaches real button',count('counter') == old+1)
    x,y=center('gesture.area');old=count('double_taps')
    raw('input.double_tap',x=x,y=y,interval=0.1)
    check('physical double tap reaches recognizer',count('double_taps') == old+1)
    old=count('long_presses')
    raw('input.long_press',x=x,y=y,seconds=0.5)
    check('physical long press reaches recognizer',count('long_presses') == old+1)
    scroll=find('scroll.list')['id'];f=find('scroll.list')['frame']
    old=invoke(scroll,'contentOffset')['value']
    raw('input.swipe',from_x=f['x']+30,from_y=f['y']+80,to_x=f['x']+30,to_y=f['y']+20,seconds=0.25,steps=20)
    check('physical swipe scrolls real view',invoke(scroll,'contentOffset')['value'] != old)
    drag=find('drag.target')['id'];x,y=center('drag.target');old=invoke(drag,'center')['value']
    raw('input.drag',from_x=x,from_y=y,to_x=x+100,to_y=y,seconds=0.4,steps=20)
    check('physical drag moves real target',invoke(drag,'center')['value'] != old)
    x,y=center('counter.increment');old=count('counter')
    try: raw('input.touch',phase='down',x=x,y=y)
    finally: raw('input.touch',phase='up',x=x,y=y)
    check('physical touch down/up activates real button',count('counter') == old+1)
    old=count('counter')
    raw('input.touch_sequence',events=[{'phase':'down','x':x,'y':y,'delay_ms':0},{'phase':'up','x':x,'y':y,'delay_ms':50}])
    check('physical touch sequence activates real button',count('counter') == old+1)


def realm():
    # Read-only, on an App Store app that ships Realm and sets schema version 18,
    # which a blank configuration (version 0) cannot open.
    app, relative = 'me.fin.bark', 'Documents/bark.realm'
    def bark(op, argv):
        p = run(['flex', *argv, '--target', app])
        report['trace'][-1]['operation'] = op
        assert p.returncode == 0, report['trace'][-1]
        answer = json.loads(p.stdout); assert answer.get('ok'), answer
        return answer['result']
    cli('app', 'launch', app, '--wait-foreground')
    truth = cli('probe', '--app', app, '-e', 'var s=ObjC.use("RLMRealm").defaultRealm().schema().objectSchema(); var n=[]; for (var i=0;i<s.count();i++) n.push(String(s.objectAtIndex_(i).className())); JSON.stringify(n.sort())')
    expected = json.loads(truth['result'])
    tables = bark('database.realm.tables', ['database', 'realm', 'tables', relative, '--root', 'home'])['tables']
    check('Realm tables match the app schema', sorted(tables) == expected and len(tables) > 0)
    for table in tables:
        columns = bark('database.realm.columns', ['database', 'realm', 'columns', relative, table, '--root', 'home'])['columns']
        check('Realm columns: ' + table, len(columns) > 0)
        count = cli('probe', '--app', app, '-e', 'String(ObjC.use("RLMRealm").defaultRealm().allObjects_(' + json.dumps(table) + ').count())')
        rows = bark('database.realm.rows', ['database', 'realm', 'rows', relative, table, '--root', 'home', '--limit', '2'])
        check('Realm rows: ' + table, rows['total'] == int(count['result']) and len(rows['rows']) == min(2, rows['total']) and all(len(r) == len(columns) for r in rows['rows']))


SECTIONS = {'core': core, 'storage':storage, 'ui':ui, 'trace':trace, 'mcp':mcp, 'metadata':metadata, 'physical':physical, 'lifecycle':lifecycle, 'realm':realm}
try:
    for artifact, remote in [('icli', BIN), ('icli-probe-agent.dylib', '/var/jb/usr/lib/icli-probe-agent.dylib'),
                             ('libicli-flex.dylib', '/var/jb/usr/lib/icli/libFLEX.dylib'),
                             ('libicli-flexultra.dylib', '/var/jb/usr/lib/icli/libicli-flexultra.dylib'),
                             ('libicli-reflex.dylib', '/var/jb/usr/lib/icli/libicli-reflex.dylib')]:
        expected = hashlib.sha256((ROOT / '.build' / artifact).read_bytes()).hexdigest()
        p = subprocess.run(['ssh-iphone', shlex.join(['/var/jb/usr/bin/sha256sum', remote])], capture_output=True, text=True, timeout=20)
        assert p.returncode == 0 and p.stdout.split()[0] == expected, artifact
    check('all installed artifacts match build')
    for section in (SECTIONS if args.section == 'all' else [args.section]):
        SECTIONS[section]()
    report['passed'] = True
finally:
    persist()
