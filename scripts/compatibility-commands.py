#!/usr/bin/env python3
"""Publish command coverage from acceptance assertions, separately from cache evidence."""
import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--acceptance', type=Path, action='append', required=True)
parser.add_argument('--presence', type=Path, default=Path('docs/development/ios-compatibility-presence.summary.json'))
parser.add_argument('--output', type=Path, default=Path('docs/development/ios-compatibility-commands.tsv'))
parser.add_argument('--defer-reboot', action='store_true')
args = parser.parse_args()
presence = json.loads(args.presence.read_text())
versions = sorted(presence['versions'], key=lambda v: tuple(map(int, v.split('.'))))
reports = [json.loads(p.read_text()) for p in args.acceptance]
runtime_versions = {r['device']['ios_version'] for r in reports}
assert len(runtime_versions) == 1, 'Use reports from one runtime OS'
runtime_version = runtime_versions.pop()
assert runtime_version in versions, 'Runtime OS has no cache column'
assert len({r['binary_sha256'] for r in reports}) == 1, 'Do not combine different binaries'
commands = reports[0]['command_inventory']
assert all(r['command_inventory'] == commands for r in reports), 'Different command inventories'
passed, failed = defaultdict(set), defaultdict(set)
for report in reports:
    assert report['binary_sha256'] == report['installed_binary_sha256'], 'Installed binary does not match the build'
    for case in report['cases'] + report.get('lifecycle', []):
        for trace in case['trace']:
            argv = trace.get('cli_arguments', [])
            if trace['exit'] != 0 or any(a in argv for a in ['--help', '--experimental-dump-help']):
                continue
            for command in commands:
                words = command.split()
                if argv[:len(words)] == words:
                    (passed if case['passed'] else failed)[command].add(case['name'])
counts = Counter()
with args.output.open('w') as output:
    writer = csv.writer(output, delimiter='\t', lineterminator='\n')
    writer.writerow(['command', 'runtime_' + runtime_version, 'passing_cases', *versions])
    for command in commands:
        state = 'case_pass' if passed[command] else 'case_fail' if failed[command] else 'not_executed'
        if command == 'device reboot' and args.defer_reboot and not passed[command]:
            state = 'deferred'
        counts[state] += 1
        static = []
        for version in versions:
            if version == runtime_version:
                static.append(state)
            elif version.startswith('14.') and command in ['location set', 'location clear']:
                static.append('unavailable')
            else:
                gaps = presence['versions'][version]['strong_imports_without_export_evidence']
                static.append('loading_gap' if gaps else 'imports_only')
        writer.writerow([command, state, ','.join(sorted(passed[command])), *static])
summary = {
    'runtime_os': runtime_version,
    'binary_sha256': reports[0]['binary_sha256'],
    'command_counts': dict(counts),
    'presence_sha256': hashlib.sha256(args.presence.read_bytes()).hexdigest(),
    'reports': [{
        'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'tested_at': report['tested_at'], 'runner_sha256': report['runner_sha256'],
        'root_only': report.get('root_only', False), 'completed_run': report.get('completed_run', False),
        'passing_cases': sum(c['passed'] for c in report['cases']), 'total_cases': len(report['cases']),
    } for path, report in zip(args.acceptance, reports)],
    'limits': [
        'case_pass requires positive execution in a passing asserted scenario; it does not cover every mode or input.',
        'Passcode preflight, audio no-op selection, lease indicator reads, and fixture FLEX inspection have limited scenarios.',
        'imports_only is whole-process loader evidence, not per-command private ABI or runtime proof.',
        'Only the source-gated iOS 14 location simulation commands are marked unavailable here.',
    ],
}
args.output.with_suffix('.summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(dict(counts), sort_keys=True))
