#!/usr/bin/env python3
"""Verify signed CLI and private runtime packages after extraction."""
import hashlib
import argparse
import io
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
verifier = runpy.run_path(str(root / 'scripts/verify-binary.py'))
parser = argparse.ArgumentParser()
parser.add_argument('--ios-only', action='store_true', help='Verify the two iOS packages without a tvOS build')
options = parser.parse_args()


def verify_slice(binary, platform, sdk_name, architecture, extra_frameworks=()):
    """Apply every binary invariant independently to one architecture."""
    entitlements = plistlib.loads(subprocess.check_output(['ldid', '-e', str(binary)]))
    assert entitlements == plistlib.loads((root / 'Resources/icli.entitlements').read_bytes())
    assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == architecture
    build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
    # The CLI, the package and the DEB's firmware dependency share one floor.
    # The SDK is the one it was built with: a lower stamp sends newer systems
    # down their old-SDK compatibility paths.
    sdk = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-version'], text=True).strip()
    fields = [line.split() for line in build.splitlines()]
    assert ['platform', platform] in fields and ['minos', '15.0'] in fields and ['sdk', sdk] in fields, build
    loads = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    for load in loads:
        name = load.strip().split(' (')[0]
        assert name.startswith(('/System/Library/', '/usr/lib/')), name
        assert 'libarchive' not in name, 'libarchive must be statically linked'
    verifier['verify_javascriptcore_not_linked'](binary)
    report = {'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'architecture': architecture,
              'system_loads': loads, 'javascriptcore_linked': False}
    report.update(verifier['verify_no_process_imports'](binary))
    report.update(verifier['verify_floor_imports'](binary, sdk_name, extra_frameworks))
    return report


def verify_binary(binary, platform, sdk_name, extra_frameworks=()):
    """Check the complete architecture set and every signed slice."""
    architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    expected = ['arm64', 'arm64e'] if platform == 'IOS' else ['arm64']
    assert architectures == expected, (architectures, expected)
    slices = {}
    with tempfile.TemporaryDirectory(prefix='icli-package-slices-') as directory:
        for architecture in architectures:
            thin = binary
            if len(architectures) > 1:
                thin = Path(directory) / architecture
                subprocess.run(['lipo', str(binary), '-thin', architecture, '-output', str(thin)], check=True)
            slices[architecture] = verify_slice(thin, platform, sdk_name, architecture, extra_frameworks)
    return {**slices[architectures[0]], 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'architecture': ' '.join(architectures), 'slices': slices}


def verify_private_runtime(binary, install_name):
    assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split() == ['arm64', 'arm64e']
    with tempfile.TemporaryDirectory(prefix='icli-flex-slices-') as directory:
        for architecture in ['arm64', 'arm64e']:
            thin = Path(directory) / architecture
            subprocess.run(['lipo', str(binary), '-thin', architecture, '-output', str(thin)], check=True)
            build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(thin)], text=True)
            fields = [line.split() for line in build.splitlines()]
            assert ['platform', 'IOS'] in fields and ['minos', '15.0'] in fields, build
            loads = subprocess.check_output(['otool', '-L', str(thin)], text=True).splitlines()[1:]
            assert loads[0].strip().split(' (')[0] == install_name
            for load in loads[1:]:
                name = load.strip().split(' (')[0]
                assert name.startswith(('/System/Library/', '/usr/lib/')), name
            verifier['verify_no_process_imports'](thin)
            verifier['verify_floor_imports'](thin)
            verifier['verify_javascriptcore_not_linked'](thin)


ios = verify_binary(root / '.build/icli', 'IOS', 'iphoneos')
report = {'version': version, **ios, 'minimum_ios': '15.0', 'packages': []}
# tvOS is its own executable: the same sources built against the AppleTVOS
# SDK, with IOKit's headers from the stub the tvOS build links against.
layouts = [('rootless', 'iphoneos-arm64', 'var/jb', ios['binary_sha256']),
           ('roothide', 'iphoneos-arm64e', '', ios['binary_sha256'])]
if not options.ios_only:
    tvos = verify_binary(root / '.build/icli-tvos', 'TVOS', 'appletvos', [root / '.build/tvos-stubs'])
    report['tvos'] = {'binary': 'icli-tvos', **tvos, 'minimum_tvos': '15.0'}
    layouts.append(('tvos', 'appletvos-arm64', '', tvos['binary_sha256']))
for kind, arch, prefix, digest in layouts:
    package = root / f'.build/com.icli.icli_{version}_{arch}.deb'
    folder = root / '.build/package-check' / kind / prefix
    cli = folder / 'usr/bin/icli'
    assert hashlib.sha256(cli.read_bytes()).hexdigest() == digest
    assert not (folder / 'Applications').exists(), 'CLI package must not contain an app'
    assert subprocess.check_output(['dpkg-deb', '-f', str(package), 'Architecture'], text=True).strip() == arch
    assert subprocess.check_output(['dpkg-deb', '-f', str(package), 'Version'], text=True).strip() == version
    dependencies = subprocess.check_output(['dpkg-deb', '-f', str(package), 'Depends'], text=True).strip()
    assert dependencies == 'firmware (>= 15.0)', dependencies
    archive = subprocess.check_output(['dpkg-deb', '--fsys-tarfile', str(package)])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        members = tar.getmembers()
        assert all(m.uid == 0 and m.gid == 0 for m in members)
        executables = [m for m in members if m.isfile() and m.mode & 0o111]
        names = sorted(m.name.rsplit('/', 1)[-1] for m in executables)
        # iOS carries the agent, its lazily loaded private FLEX runtime and
        # the SpringBoard lease indicator. tvOS keeps the executable alone.
        expected = ['icli'] if kind == 'tvos' else ['IcliLeaseIndicator.dylib', 'icli', 'icli-probe-agent.dylib', 'libFLEX.dylib', 'libicli-flexultra.dylib', 'libicli-reflex.dylib']
        assert names == expected, names
    agent_sha = flex_sha = None
    runtimes = {}
    if kind != 'tvos':
        agent = folder / 'usr/lib/icli-probe-agent.dylib'
        agent_sha = hashlib.sha256(agent.read_bytes()).hexdigest()
        assert agent_sha == hashlib.sha256((root / '.build/icli-probe-agent.dylib').read_bytes()).hexdigest()
        flex = folder / 'usr/lib/icli/libFLEX.dylib'
        flex_sha = hashlib.sha256(flex.read_bytes()).hexdigest()
        assert flex_sha == hashlib.sha256((root / '.build/libicli-flex.dylib').read_bytes()).hexdigest()
        assert (folder / 'usr/share/doc/icli/licenses/FLEX.txt').read_bytes() == (root / 'Resources/Licenses/FLEX.txt').read_bytes()
        verify_private_runtime(flex, '@rpath/libFLEX.dylib')
        runtimes = {}
        for name in ['libicli-flexultra.dylib', 'libicli-reflex.dylib']:
            runtime = folder / 'usr/lib/icli' / name
            digest_runtime = hashlib.sha256(runtime.read_bytes()).hexdigest()
            assert digest_runtime == hashlib.sha256((root / '.build' / name).read_bytes()).hexdigest()
            verify_private_runtime(runtime, '@rpath/' + name)
            runtimes[name] = digest_runtime
        indicator = folder / 'Library/MobileSubstrate/DynamicLibraries/IcliLeaseIndicator.dylib'
        assert indicator.read_bytes() == (root / '.build/IcliLeaseIndicator.dylib').read_bytes()
        assert indicator.with_suffix('.plist').read_bytes() == (root / 'Resources/IcliLeaseIndicator.plist').read_bytes()
        for license in (root / 'Resources/Licenses').glob('*.txt'):
            assert (folder / 'usr/share/doc/icli/licenses' / license.name).read_bytes() == license.read_bytes()
    report['packages'].append({'layout': kind, 'file': package.name,
                               'sha256': hashlib.sha256(package.read_bytes()).hexdigest(),
                               'binary_sha256': digest, 'depends': dependencies,
                               'executables': names, 'agent_sha256': agent_sha, 'flex_sha256': flex_sha, 'private_runtimes': runtimes, 'root_owned': True})
(root / '.build/package-verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS ' + ('iOS' if options.ios_only else 'iOS and tvOS') + ' package architecture, metadata, entitlements, system dependencies, ownership, '
      'CLI-only contents, JavaScriptCore loaded at runtime and no process-launch imports')
