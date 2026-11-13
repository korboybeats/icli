#!/usr/bin/env python3
"""Prepare complete release assets from already verified builds; never publishes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--tag', required=True)
parser.add_argument('--repository', default='korboybeats/icli')
args = parser.parse_args()
version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
assert args.tag.removeprefix('v') == version, 'tag and package version differ'
assert re.fullmatch(r'v?\d+\.\d+\.\d+(\+korboy\d+)?', args.tag)
commit = subprocess.check_output(['git','rev-parse','HEAD'], cwd=root, text=True).strip()
assert not subprocess.check_output(['git','status','--porcelain','--untracked-files=no'], cwd=root, text=True), 'commit source changes before preparing a release'
notes_path = root / f'docs/releases/{version}.md'
notes = notes_path.read_text().strip()
report = json.loads((root / '.build/package-verification.json').read_text())
assert report['version'] == version
assert {p['layout'] for p in report['packages']} == {'rootless','roothide','tvos'}

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

assert digest(root / '.build/icli') == report['binary_sha256']
assert digest(root / '.build/icli-tvos') == report['tvos']['binary_sha256']
output = root / '.build' / ('publish-' + version)
if output.exists(): shutil.rmtree(output)
output.mkdir()
for package in report['packages']:
    path = root / '.build' / package['file']
    assert digest(path) == package['sha256'], 'package differs from verification: ' + path.name
    shutil.copy2(path, output / path.name)
for name in ['icli','icli-tvos','package-verification.json']:
    shutil.copy2(root / '.build' / name, output / name)
provenance = {'version': version, 'tag': args.tag, 'repository': args.repository,
              'commit': commit, 'ios_sha256': report['binary_sha256'],
              'tvos_sha256': report['tvos']['binary_sha256'],
              'build_environment': {'github_actions': os.environ.get('GITHUB_ACTIONS') == 'true',
                                    'run_id': os.environ.get('GITHUB_RUN_ID'),
                                    'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
                                    'workflow': os.environ.get('GITHUB_WORKFLOW')},
              'device_validation': 'See versioned release notes; package checks do not establish device acceptance.'}
(output / 'release-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
# Every document/skill/license in the source checkout, plus the actual binaries.
entries = {}
for path in subprocess.check_output(['git','ls-files','docs','Resources/Licenses','README.md','LICENSE','THIRD_PARTY_NOTICES.md','Resources/Info.plist','Resources/icli.entitlements','Resources/IcliLeaseIndicator.plist'], cwd=root, text=True).splitlines():
    entries[path] = root / path
for name in ['icli','icli-probe-agent.dylib','IcliLeaseIndicator.dylib']:
    entries['ios/' + name] = root / '.build' / name
for source, destination in [('libicli-flex.dylib','libFLEX.dylib'), ('libicli-flexultra.dylib','libicli-flexultra.dylib'), ('libicli-reflex.dylib','libicli-reflex.dylib')]:
    entries['ios/' + destination] = root / '.build' / source
entries['tvos/icli-tvos'] = root / '.build/icli-tvos'
for path in output.iterdir(): entries['packages/' + path.name] = path
manifest = ''.join(digest(path) + '  ' + name + '\n' for name, path in sorted(entries.items()))
with zipfile.ZipFile(output / f'icli-{version}-complete.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for name, path in sorted(entries.items()): archive.write(path, f'icli-{version}/' + name)
    archive.writestr(f'icli-{version}/SHA256SUMS', manifest)
    archive.writestr(f'icli-{version}/CONTENTS.md', '''# Complete icli release

The packages/ directory contains all three verified DEBs, standalone executables,
and verification/provenance reports. Prefer the matching DEB for installation;
it places all required iOS libraries and the lease indicator correctly.
ios/ contains the universal CLI and all five private libraries/tweaks; tvos/
contains the standalone tvOS CLI. The lease indicator plist and signing profiles
are under Resources/. docs/ includes all usage/API/development guides and the
agent skill; licenses are included. SHA256SUMS covers every archived source file.
The GitHub release's source archives contain the full tagged repository source.
Historical validation documents describe their own versions and devices.
''')
files = sorted(output.iterdir())
(output / 'SHA256SUMS').write_text(''.join(digest(path) + '  ' + path.name + '\n' for path in files))
# Resolve source-relative documentation links for the GitHub Release surface.
def link(match):
    label, url = match.groups()
    if '://' in url or url.startswith('#'): return match.group(0)
    file, _, anchor = url.partition('#')
    target = (notes_path.parent / file).resolve()
    if not target.is_relative_to(root) or not target.exists(): return match.group(0)
    return '[' + label + '](https://github.com/' + args.repository + '/blob/' + args.tag + '/' + target.relative_to(root).as_posix() + ('#' + anchor if anchor else '') + ')'
notes = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', link, notes)
notes += f'''\n\n## Downloads and source\n\n- Rootless (`iphoneos-arm64`) and experimental RootHide (`iphoneos-arm64e`) DEBs include the same signed universal **arm64/arm64e** iOS CLI, probe agent, FLEX, FlexUltra, Swift metadata runtime and SpringBoard lease indicator.\n- tvOS (`appletvos-arm64`) DEB and standalone `icli-tvos` contain the separate signed tvOS executable.\n- `icli-{version}-complete.zip` includes all packages, binaries/runtimes, documentation, agent skill, licenses and verification reports. A standalone iOS `icli` is also attached; install its runtimes from the DEB or complete archive for app inspection.\n- `SHA256SUMS`, `package-verification.json` and `release-provenance.json` identify the delivered files and source. GitHub’s source archives contain the complete tagged repository.\n- Source commit: `{commit}`. iOS CLI SHA-256: `{report['binary_sha256']}`.\n- Package checks cover architecture, iOS/tvOS 15 floor, signed entitlements, system dependencies, root ownership, identical packaged payloads, and prohibited process-launch imports. Package checks do not rerun device acceptance.\n'''
(root / '.build/release-notes.md').write_text(notes + '\n')
print(output)
print('\n'.join(path.name for path in sorted(output.iterdir())))
