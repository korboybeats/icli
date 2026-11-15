#!/usr/bin/env python3
"""Publish selected receiver/selector metadata separately from name presence.

The index's first four columns are the reviewed query catalog. Unresolved
records are not absence proof: the cache reader does not merge all categories.
Method encodings do not establish block prototypes, permissions or behavior.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--metadata', type=Path, required=True)
parser.add_argument('--inventory', type=Path, required=True)
parser.add_argument('--index', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
with args.index.open() as stream:
    queries = [{key: row[key] for key in ['receiver', 'side', 'selector', 'sources']}
               for row in csv.DictReader(stream, delimiter='\t')]
assert queries and len({(q['receiver'], q['side'], q['selector']) for q in queries}) == len(queries)
inventory_hash = hashlib.sha256(args.inventory.read_bytes()).hexdigest()
inventory = json.loads(args.inventory.read_text())
source_hashes = {}
for query in queries:
    for name in query['sources'].split(';'):
        path = Path(__file__).resolve().parents[1] / name
        expected = inventory['source_sha256'][name]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, 'Reviewed source changed: ' + name
        source_hashes[name] = expected
inputs = {p.stem: p for p in args.metadata.glob('*.json') if re.fullmatch(r'\d+(?:\.\d+)+', p.stem)}
versions = sorted(inputs, key=lambda value: tuple(map(int, value.split('.'))))
assert versions, 'No versioned metadata inputs'
rows = [dict(query) for query in queries]
evidence = {}
for version in versions:
    path = inputs[version]
    snapshot = json.loads(path.read_text())
    assert snapshot['version'] == version and snapshot['inventory_sha256'] == inventory_hash
    evidence[version] = {'metadata_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                         'reader_sha256': snapshot['reader_sha256'], 'cache': snapshot['cache']}
    for row in rows:
        assert row['side'] in ['class', 'instance']
        cls = snapshot['classes'].get(row['receiver'], {})
        value = 'class_unresolved' if row['side'] not in cls else 'method_unresolved'
        for address in cls.get(row['side'], []):
            owner = snapshot['nodes'][str(address)]
            methods = [m for m in owner['methods'] if m['selector'] == row['selector']]
            if methods:
                encodings = {method['types'] for method in methods}
                assert len(encodings) == 1, (version, row['receiver'], row['selector'], encodings)
                value = json.dumps({'owner': owner['name'], 'encoding': encodings.pop()}, separators=(',', ':'))
                break
        row[version] = value
with args.output.open('w') as stream:
    writer = csv.DictWriter(stream, fieldnames=['receiver', 'side', 'selector', 'sources', *versions],
                            delimiter='\t', lineterminator='\n')
    writer.writeheader()
    writer.writerows(rows)
args.output.with_suffix('.summary.json').write_text(json.dumps({
    'inventory_sha256': inventory_hash,
    'selected_methods': len(queries),
    'reviewed_source_sha256': source_hashes,
    'versions': evidence,
    'legend': {'json': 'Actual declaring owner and native Objective-C method encoding',
               'class_unresolved': 'No unique class definition in the recorded symbol scopes',
               'method_unresolved': 'Method not resolved in recorded base, attached and superclass lists; not absence proof'},
    'limits': ['The query catalog is selected from reviewed source call sites, not every private call.',
               'Metadata establishes method encoding only; block prototypes, entitlements, service protocols and runtime behavior need separate evidence.',
               'Raw unparsed encodings remain available in metadata snapshots; unresolved results are never converted to availability claims.'],
}, indent=2) + '\n')
print(f'Published {len(queries)} selected receiver/selector rows across {len(versions)} caches')
