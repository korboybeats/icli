#!/usr/bin/env python3
"""Reject process-launch imports, imports beyond the deployment floor, and a linked JavaScriptCore."""
from pathlib import Path
import argparse
import json
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def verify_no_process_imports(binary):
    output = subprocess.check_output(['nm', '-u', str(binary)], text=True)
    forbidden = re.compile(r'^_(?:posix_spawn.*|exec[lv].*|system|popen|fork|vfork)$|NSTask')
    imports = sorted({line.split()[-1] for line in output.splitlines() if line.strip()})
    found = [symbol for symbol in imports if forbidden.search(symbol)]
    if found:
        raise SystemExit('Forbidden process-launch imports: ' + ', '.join(found))
    return {'undefined_symbols_checked': len(imports), 'forbidden_process_imports': found}


def verify_javascriptcore_not_linked(binary):
    """The probe reaches JavaScriptCore with dlopen so a platform without it
    still loads icli. Its headers leave an autolink request in every IcliProbe
    object, which ld honors as soon as anything names a JavaScriptCore symbol
    directly, so only the load commands show whether that rule still holds."""
    output = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    linked = [line.split()[0] for line in output.splitlines()[1:] if 'JavaScriptCore.framework' in line]
    if linked:
        raise SystemExit(
            'JavaScriptCore is linked rather than loaded at runtime: ' + ', '.join(linked)
            + '\nReach it through IcliProbeContextClass / IcliProbeValueClass, never a JavaScriptCore symbol.'
        )


def sdk_declared_names(sdk_name='iphoneos', extra_frameworks=()):
    """Every identifier any public header in the SDK, or in the extra
    framework folders the build searches, spells."""
    sdk = Path(subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-path'], text=True).strip())
    names = set()
    # os.walk, not rglob: several frameworks in the SDK are symlinks, and
    # rglob does not follow a symlinked directory (SafariServices is one)
    for folder in [sdk / 'usr/include', sdk / 'System/Library/Frameworks', *extra_frameworks]:
        for directory, _, files in os.walk(folder, followlinks=True):
            for file in files:
                if file.endswith('.h'):
                    # a comment declares nothing: proc_pidinfo is spelled in one
                    text = re.sub(r'/\*.*?\*/|//[^\n]*', ' ', (Path(directory) / file).read_text(errors='ignore'), flags=re.S)
                    names.update(re.findall(r'[A-Za-z_$][A-Za-z0-9_$]*', text))
    return names


def verify_floor_imports(binary, sdk_name='iphoneos', extra_frameworks=()):
    """Check all iOS strong imports, including mangled Swift, against measured
    iOS 14.0 exports. Retain the private-import review list as well. tvOS keeps
    its SDK availability check and its separate 15.0 concurrency boundary."""
    allowed = set()
    for line in (ROOT / 'scripts/floor-imports.txt').read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            allowed.add(line)
    output = subprocess.check_output(['nm', '-m', '-u', str(binary)], text=True)
    strong, raw_strong = set(), set()
    if sdk_name == 'appletvos':
        allowed.update(['swift_task_alloc', 'swift_task_dealloc', 'swift_task_switch'])
    for line in output.splitlines():
        if '(undefined)' not in line or ' weak ' in line:
            continue
        symbol = line.split()[2]
        raw_strong.add(symbol)
        name = symbol[1:] if symbol.startswith('_') else symbol
        # A class reference is checked by the class name its header spells.
        name = re.sub(r'^OBJC_(?:META)?CLASS_\$_', '', name)
        if name.startswith(('$s', '_Tt')):
            continue
        strong.add(name)
    floor_report = {}
    if sdk_name == 'iphoneos':
        floor = json.loads((ROOT / 'scripts/floor-exports-ios14.json').read_text())
        missing = sorted(raw_strong - floor['exports'].keys())
        if missing:
            raise SystemExit('Strong imports without a measured iOS 14.0 export: ' + ', '.join(missing)
                             + '\nResolve newer optional APIs at runtime or regenerate the floor evidence from the cache.')
        floor_report = {'floor_symbols_checked': len(raw_strong), 'missing_floor_exports': missing,
                        'floor_version': floor['version'], 'floor_cache': floor['cache']}
    declared = sdk_declared_names(sdk_name, extra_frameworks)
    unknown = sorted(name for name in strong if name not in declared and name not in allowed)
    if unknown:
        raise SystemExit(
            'Strong imports no SDK header declares and floor-imports.txt does not list: ' + ', '.join(unknown)
            + '\nConfirm the deployment floor exports each one and list it, or resolve it with dlsym.'
        )
    return {'strong_imports_checked': len(strong), 'unlisted_private_imports': unknown, **floor_report}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=['ios', 'tvos', 'agent', 'flex', 'engine', 'reflex', 'indicator'], default='ios')
    platform = parser.parse_args().platform
    if platform == 'tvos':
        # The tvOS build takes IOKit's headers from the stub it links against.
        binary, sdk_name, extra = ROOT / '.build/icli-tvos', 'appletvos', [ROOT / '.build/tvos-stubs']
    elif platform == 'engine':
        binary, sdk_name, extra = ROOT / '.build/libicli-flexultra.dylib', 'iphoneos', []
    elif platform == 'reflex':
        binary, sdk_name, extra = ROOT / '.build/libicli-reflex.dylib', 'iphoneos', []
    elif platform == 'flex':
        binary, sdk_name, extra = ROOT / '.build/libicli-flex.dylib', 'iphoneos', []
    elif platform == 'indicator':
        # The lease indicator runs inside SpringBoard: the same rules as the agent.
        binary, sdk_name, extra = ROOT / '.build/IcliLeaseIndicator.dylib', 'iphoneos', []
    elif platform == 'agent':
        # The probe agent runs inside somebody else's app, so it is held to the
        # same rules: it starts no process, names nothing iOS 14.0 may not
        # export, and still reaches JavaScriptCore with dlopen rather than
        # forcing the framework into an app that never asked for it.
        binary, sdk_name, extra = ROOT / '.build/icli-probe-agent.dylib', 'iphoneos', []
    else:
        binary, sdk_name, extra = ROOT / '.build/icli', 'iphoneos', []
    label = 'tvOS' if platform == 'tvos' else 'iOS'
    verify_no_process_imports(binary)
    print('PASS no process-launch imports')
    verify_floor_imports(binary, sdk_name, extra)
    print(f'PASS no strong import beyond the {label} {"15.0" if platform == "tvos" else "14.0"} floor')
    verify_javascriptcore_not_linked(binary)
    print('PASS JavaScriptCore is loaded at runtime, not linked')
