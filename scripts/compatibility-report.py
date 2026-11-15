#!/usr/bin/env python3
"""Combine completed cache scans into a compact, explicitly static matrix."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import runpy

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--inventory', type=Path, required=True)
parser.add_argument('--scan', type=Path, action='append', required=True,
                    help='Scan root; a later root overrides duplicate versions')
parser.add_argument('--supplement', type=Path, action='append', default=[],
                    help='Additional image-scoped scan root; may be repeated')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
inventory = json.loads(args.inventory.read_text())
matrix = runpy.run_path(str(Path(__file__).with_name('compatibility-matrix.py')))
_, symbols, classes, selectors = matrix['queries'](inventory)
inputs = {}
for root in args.scan:
    for metadata in root.glob('*/scan.json'):
        inputs[metadata.parent.name] = metadata.parent
versions = sorted(inputs, key=lambda v: tuple(map(int, v.split('.'))))
rows = {('symbol', n): [] for n in symbols}
rows.update({('class', n): [] for n in classes})
rows.update({('selector', n): [] for n in selectors})
strong = {i['name'] for a in inventory['artifacts'].values()
          for items in a['slices'].values() for i in items if not i['weak']}
summary = {'inventory_sha256': hashlib.sha256(args.inventory.read_bytes()).hexdigest(),
           'legend': {'E': 'export definition', 'D': 'non-export definition',
                      'M': 'selector has a named implementation, receiver and ABI not established',
                      '-': 'not located by the full cache symbol query, not an absence proof for selectors',
                      'Q': 'not located in the supplemental image scope', 'N': 'not queried'},
           'versions': {}, 'runtime_results': 'not part of this static report'}
for version in versions:
    folder = inputs[version]
    metadata = json.loads((folder / 'scan.json').read_text())
    patterns = [re.compile(json.loads((folder.parent / 'queries.json').read_text())[0]['pattern'])]
    records = json.loads((folder / 'definitions.json').read_text())
    supplemental = []
    for root in args.supplement:
        extra = root / version
        if not (extra / 'scan.json').exists():
            continue
        extra_metadata = json.loads((extra / 'scan.json').read_text())
        assert extra_metadata['cache'] == metadata['cache'], 'different cache identities: ' + version
        supplemental.append(extra_metadata)
        records.extend(json.loads((extra / 'definitions.json').read_text()))
        patterns.append(re.compile(json.loads((extra.parent / 'queries.json').read_text())[0]['pattern']))
    definitions, methods = defaultdict(set), set()
    for item in records:
        if not item.get('address') or 'undefined' in item['type'].lower():
            continue
        exported = matrix['is_exported'](item)
        definitions[item['name']].add('E' if exported else 'D')
        match = re.fullmatch(r'[+-]\[[^ ]+ (.+)\]', item['name'])
        if match:
            methods.add(match[1])
    for (kind, name), states in rows.items():
        query_name = '_OBJC_CLASS_$_' + name if kind == 'class' else name
        if kind == 'selector':
            query_name = '-[ICLIQueryProbe ' + name + ']'
            state = 'M' if name in methods else None
        else:
            hits = definitions[query_name]
            state = 'E' if 'E' in hits else 'D' if hits else None
        if state is None:
            state = '-' if patterns[0].fullmatch(query_name) else 'Q' if any(
                p.fullmatch(query_name) for p in patterns[1:]) else 'N'
        states.append(state)
    missing = sorted(name for name in strong if 'E' not in definitions[name])
    summary['versions'][version] = {'scan': metadata, 'supplement': supplemental,
                                    'strong_imports_without_export_evidence': missing}
    print(f'{version}: {len(strong)} strong import names, {len(missing)} without export evidence', flush=True)
lines = ['kind\tname\tstrong_import\t' + '\t'.join(versions)]
for (kind, name), states in sorted(rows.items()):
    lines.append('\t'.join([kind, json.dumps(name, ensure_ascii=False),
                            'yes' if kind == 'symbol' and name in strong else '', *states]))
args.output.write_text('\n'.join(lines) + '\n')
args.output.with_suffix('.summary.json').write_text(json.dumps(summary, indent=2) + '\n')
