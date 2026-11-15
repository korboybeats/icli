#!/usr/bin/env python3
"""Index compatibility dependencies without treating a string hit as API support.

The lexical index retains *all* literals, including ones passed through helpers,
tables and variables. --ast adds actual C calls and ObjC messages from Clang on
the build Mac. The inventory is research input, not a compatibility certificate.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXTENSIONS = {'.h', '.m', '.mm', '.c', '.swift'}
TOKEN = re.compile(r'//[^\n]*|/\*.*?\*/|@?"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', re.S)
LOOKUP = re.compile(r'\b(dlsym|NSClassFromString|objc_getClass|NSSelectorFromString|sel_registerName|dlopen)\s*\(')


def source_paths():
    # These are the sources the package and agent Makefiles compile. Generated
    # FlexUltra files are indexed too: scripts/prepare-flexultra.py changes API
    # lookups, so its archived inputs alone do not describe the shipped engine.
    folders = ['Sources', 'Agent', 'Vendor/FLEX/Classes',
               'Vendor/FlexUltra/ThirdParty/ObjSee/src/libobjsee',
               'Vendor/FlexUltra/VendoredReflex/Sources', '.build/flexultra-src']
    return sorted(p for folder in folders for p in (ROOT / folder).rglob('*')
                  if p.is_file() and p.suffix in EXTENSIONS
                  and not ('ThirdParty/ObjSee/src/libobjsee/' in str(p)
                           and {'injection', 'springboard', 'workarounds'} & set(p.parts)))


def lexical(path, add):
    source = path.read_text(errors='replace')
    # Preserve offsets while masking comments. A comment may contain a quoted
    # example; it must never become evidence of a shipped dependency.
    clean = list(source)
    literals = []
    for match in TOKEN.finditer(source):
        token = match[0]
        if token.startswith(('//', '/*')):
            clean[match.start():match.end()] = ['\n' if c == '\n' else ' ' for c in token]
        elif token.startswith(('"', '@"')):
            literals.append(match)
    clean = ''.join(clean)
    for match in literals:
        token = match[0].removeprefix('@')
        try:
            value = json.loads(token)
        except json.JSONDecodeError:
            value = token[1:-1]  # C escapes are retained verbatim, never guessed.
        line = source.count('\n', 0, match.start()) + 1
        before = clean[max(0, match.start() - 180):match.start()]
        call = re.search(r'(\w+)\s*\([^();]*$', before)
        function = call[1] if call else ''
        kind = 'literal'
        if value.startswith('/'):
            kind = 'path'
        if value.startswith(('com.apple.', 'kern.', 'hw.')):
            kind = 'system-name'
        if function in ('NSClassFromString', 'objc_getClass'):
            kind = 'class'
        elif function in ('sel_registerName', 'NSSelectorFromString'):
            kind = 'selector'
        elif function in ('dlsym', 'SYM', 'symbol', 'nativeString') or function.lower().endswith('symbol'):
            kind = 'symbol'
        elif re.fullmatch(r'(?:[A-Za-z_]\w*:)+', value):
            kind = 'selector-candidate'
        elif re.match(r'^(?:_AXS|AVSystemController_|kMKBInfo)', value):
            kind = 'symbol-candidate'
        elif re.fullmatch(r'(?:AV|AX|BKS|BS|CA|CF|CL|DND|FB|LS|MCM|MC|MT|NS|OS|PB|RB|SB|SF|UI|WK|_PM)[A-Z]\w+', value):
            kind = 'class-candidate'
        add(kind, value, path, line)
        if re.search(r'\bCFSTR\s*\(\s*$', before):
            add('cf-string', value, path, line)
    for match in re.finditer(r'@selector\s*\(([^)]+)\)', clean):
        add('selector', re.sub(r'\s+', '', match[1]), path, source.count('\n', 0, match.start()) + 1)
    for match in LOOKUP.finditer(clean):
        end = clean.find('\n', match.start())
        add('lookup-site', clean[match.start():end if end >= 0 else len(clean)].strip(),
            path, source.count('\n', 0, match.start()) + 1)
    for match in re.finditer(r'@(?:interface|implementation)\s+(\w+)', clean):
        add('objc-declaration', match[1], path, source.count('\n', 0, match.start()) + 1)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clang_references(path, sdk, add):
    includes = ['Sources/IcliPrivate/include', 'Sources/IcliSystemPrivate/include',
                'Sources/IcliLaunchPrivate/include', 'Sources/IcliProbe', 'Sources/IcliProbe/include',
                'Sources/IcliFlexClient', 'Sources/IcliFlexClient/include',
                '.build/flexultra-src', '.build/flexultra-src/Shared', '.build/flexultra-src/Agent',
                'Agent/FlexUltra', 'Vendor/FlexUltra/ThirdParty/ObjSee',
                'Vendor/FlexUltra/ThirdParty/ObjSee/dependencies/yyjson/src',
                'Vendor/FlexUltra/VendoredReflex/Sources/CEcho/include']
    for folder in ['Vendor/FLEX/Classes', 'Vendor/FlexUltra/ThirdParty/ObjSee/src/libobjsee']:
        includes += [str(p.relative_to(ROOT)) for p in (ROOT / folder).rglob('*') if p.is_dir()]
    frameworks = [p.parent for p in (ROOT / '.build').glob(
        'swiftpm-arm64/artifacts/libarchive.xcframework/libarchive/libarchive.xcframework/ios-arm64_arm64e/libarchive.framework')]
    command = ['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios14.0',
               '-isysroot', sdk, '-fsyntax-only', '-fobjc-arc', '-fobjc-weak',
               '-Xclang', '-ast-dump=json', *['-I' + s for s in includes],
               *['-F' + str(p) for p in frameworks], str(path)]
    if path.suffix == '.mm':
        command += ['-std=gnu++11']
    if str(path.relative_to(ROOT)).startswith(('.build/flexultra-src/', 'Vendor/FlexUltra/ThirdParty/ObjSee/')):
        command += ['-include', 'Agent/FlexUltra/ICLIFlexCompat.h', '-include', '.build/flexultra-src/ICLIFlexBuild.h',
                    '-DFU_AGENT_BUILD_ID=@ICLI_FULL_FLEX_BUILD']
    # Clang's SDK AST is large. Reuse a temporary file one translation unit at
    # a time, and retain the diagnostics if an input cannot be indexed.
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.PIPE, text=True)
        if result.returncode:
            return {'file': str(path.relative_to(ROOT)), 'diagnostics': result.stderr}
        output.seek(0)
        tree = json.load(output)
    source = path.read_text()

    def visit(node):
        begin = node.get('range', {}).get('begin', {})
        position = begin.get('expansionLoc', begin)
        offset = position.get('offset')
        local = offset is not None and 'includedFrom' not in position and offset < len(source)
        if local:
            line = source.count('\n', 0, offset) + 1
            kind = node.get('kind')
            if kind == 'ObjCMessageExpr':
                owner = node.get('classType', {}).get('qualType')
                if not owner and node.get('inner'):
                    owner = node['inner'][0].get('type', {}).get('qualType')
                add('objc-message', (owner or '?') + ' ' + node['selector'], path, line)
            elif kind == 'DeclRefExpr' and node.get('referencedDecl', {}).get('kind') == 'FunctionDecl':
                add('c-reference', node['referencedDecl']['name'], path, line)
        for child in node.get('inner', []):
            visit(child)

    visit(tree)
    return None


def inventory(args):
    entries = defaultdict(set)

    def add(kind, name, path, line):
        if name:
            entries[kind, name].add(f'{path.relative_to(ROOT)}:{line}')

    files = {str(p.relative_to(ROOT)): lexical(p, add) for p in source_paths()}
    for line, text in enumerate((ROOT / 'scripts/floor-imports.txt').read_text().splitlines(), 1):
        name = text.split('#', 1)[0].strip()
        if name:
            add('floor-import', name, ROOT / 'scripts/floor-imports.txt', line)
    entitlements = plistlib.loads((ROOT / 'Resources/icli.entitlements').read_bytes())
    for name in entitlements:
        add('entitlement', name, ROOT / 'Resources/icli.entitlements', 1)
    errors, ast_files = [], []
    artifacts = {}
    if args.imports:
        for name in ['icli', 'icli-probe-agent.dylib', 'IcliLeaseIndicator.dylib',
                     'libicli-flex.dylib', 'libicli-flexultra.dylib', 'libicli-reflex.dylib']:
            binary = ROOT / '.build' / name
            architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True).split()
            slices = {}
            for architecture in architectures:
                output = subprocess.check_output(['xcrun', 'nm', '-arch', architecture, '-m', '-u', str(binary)], text=True)
                imports = []
                for line in output.splitlines():
                    match = re.search(r'\(undefined\) (.*?)external (\S+)(?: \(from (.*)\))?$', line.strip())
                    if match:
                        imports.append({'name': match[2], 'weak': 'weak' in match[1], 'library': match[3]})
                    elif '(undefined)' in line:
                        raise ValueError('Unparsed import: ' + line)
                slices[architecture] = imports
            artifacts[name] = {'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'slices': slices}
    if args.ast:
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        for name in files:
            path = ROOT / name
            if path.suffix not in ('.c', '.m', '.mm'):
                continue
            if not args.ast_vendor and not name.startswith(('Sources/', 'Agent/')):
                continue
            error = clang_references(path, sdk, add)
            if error:
                errors.append(error)
            else:
                ast_files.append(name)
            print('Indexed ' + name, flush=True)
    rows = [{'kind': kind, 'name': name, 'sources': sorted(locations)}
            for (kind, name), locations in sorted(entries.items())]
    output = {'schema': 1, 'source_sha256': files, 'ast_requested': args.ast,
              'ast_vendor_requested': args.ast_vendor, 'ast_files': ast_files, 'ast_errors': errors,
              'entitlements': entitlements, 'artifacts': artifacts,
              'counts': dict(Counter(row['kind'] for row in rows)), 'items': rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({'files': len(files), 'counts': output['counts'], 'ast_errors': len(errors)}))
    return output


def export_index(data, destination):
    """Keep a reviewable index in git; large raw compiler/cache data stays in .build."""
    lines = ['kind\tname (JSON escaped)\tsource locations']
    for item in data['items']:
        lines.append(item['kind'] + '\t' + json.dumps(item['name'], ensure_ascii=False)
                     + '\t' + '; '.join(item['sources']))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text('\n'.join(lines) + '\n')
    imports = defaultdict(set)
    for name, artifact in data.get('artifacts', {}).items():
        for architecture, records in artifact['slices'].items():
            for item in records:
                imports[name, item['name'], item['weak'], item['library']].add(architecture)
    lines = ['artifact\tarchitectures\tsymbol\tlinkage\tlibrary']
    for (name, symbol, weak, library), architectures in sorted(imports.items()):
        lines.append('\t'.join([name, ','.join(sorted(architectures)), symbol,
                                'weak' if weak else 'strong', library or '']))
    destination.with_suffix('.imports.tsv').write_text('\n'.join(lines) + '\n')
    summary = {key: value for key, value in data.items() if key != 'items'}
    for artifact in summary.get('artifacts', {}).values():
        artifact['import_counts'] = {arch: {'total': len(items), 'strong': sum(not i['weak'] for i in items)}
                                     for arch, items in artifact.pop('slices').items()}
    destination.with_suffix('.summary.json').write_text(json.dumps(summary, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ast', action='store_true', help='Also index compiled calls with the Mac iPhoneOS SDK')
    parser.add_argument('--ast-vendor', action='store_true', help='Include compiled calls in the bundled library sources (use with --ast)')
    parser.add_argument('--imports', action='store_true', help='Record strong and weak imports from every built iOS artifact and slice')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/compatibility/inventory.json')
    parser.add_argument('--from-inventory', type=Path, help='Export a saved inventory without repeating Clang analysis')
    parser.add_argument('--export', type=Path, help='Write the complete dependency and literal index as TSV')
    args = parser.parse_args()
    data = json.loads(args.from_inventory.read_text()) if args.from_inventory else inventory(args)
    if args.export:
        export_index(data, args.export)
