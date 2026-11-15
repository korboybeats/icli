#!/usr/bin/env python3
"""Publish native AX argument-load witnesses separately from device results.

Inputs retain cache identities, Objective-C method metadata and copied native
bytes. An argument-load witness establishes the recorded instruction, not the
complete function's control flow, service policy or app-side implementation.
Scroll mappings are separately checked against native switch code and tables.
"""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--metadata', type=Path, required=True)
parser.add_argument('--presence', type=Path, default=ROOT / 'docs/development/ios-compatibility-presence.summary.json')
parser.add_argument('--output', type=Path, default=ROOT / 'docs/development/ios-compatibility-accessibility.tsv')
args = parser.parse_args()
presence = json.loads(args.presence.read_text())
versions = sorted(presence['versions'], key=lambda value: tuple(map(int, value.split('.'))))
source = ROOT / 'Sources/IcliPrivate/Accessibility.m'
source_text = source.read_text()
attributes = [
    ('label', 2001, 'label'), ('value', 2006, 'value'), ('frame', 2003, 'frame'),
    ('traits', 2004, 'traits'), ('center_point', 2007, 'centerPoint'),
    ('accessibility_identifier', 5019, 'axIdentifier'), ('parent', 5002, 'parent'),
    ('visible_elements', 3015, 'visibleElements'), ('clipped_frame', 2057, 'visibleFrame'),
    ('can_activate', 2019, 'canPerformActivate'), ('activate', 2010, '_performActivate'),
    ('reveal', 2003, 'scrollToVisible'),
]
directions = [('down', 2006, 2109), ('up', 2007, 2108), ('left', 2008, 2106), ('right', 2009, 2107)]
for _, value, _ in attributes:
    assert re.search(r'\b' + str(value) + r'\b', source_text), 'Source value changed: ' + str(value)
for direction, action, ancestor in directions:
    assert re.search(r'\{"' + direction + r'",\s*' + str(action) + r',\s*' + str(ancestor) + r'\}', source_text)
rows = {(dependency, str(value), selector): [] for dependency, value, selector in attributes}
rows.update({('scroll_' + direction, f'{action}->{ancestor}', 'scrollAncestorForScrollAction:'): []
             for direction, action, ancestor in directions})
summary = {
    'scope': 'Static native argument-load witnesses and separately checked scroll mappings; no device result',
    'source_sha256': {str(source.relative_to(ROOT)): hashlib.sha256(source.read_bytes()).hexdigest()},
    'presence_sha256': hashlib.sha256(args.presence.read_bytes()).hexdigest(),
    'versions': {}, 'counts': {},
    'limits': [
        'A matched native argument load does not prove the entire method, C ABI, MIG protocol or service policy.',
        'method_unresolved means no wrapper witness in the recorded class chain, not that the numeric attribute is unavailable.',
        'In particular, axIdentifier has no recorded wrapper before 26; older 5019 app-side dispatch requires separate evidence.',
        'Native switch/table records prove the selected scroll mapping, not successful scrolling in every app.',
    ],
}
counts = Counter()
for version in versions:
    path = args.metadata / (version + '.json')
    data = json.loads(path.read_text())
    scroll_path = args.metadata / (version + '-scroll.json')
    scroll = json.loads(scroll_path.read_text())
    assert data['version'] == scroll['version'] == version
    assert data['cache'] == scroll['cache'] == presence['versions'][version]['scan']['cache']
    assert scroll['metadata_sha256'] == hashlib.sha256(path.read_bytes()).hexdigest()
    assert scroll['mapping'] == {str(action): ancestor for _, action, ancestor in directions}
    for dependency, expected, selector in attributes:
        method = data['selectors'][selector]
        if 'implementation' not in method:
            value = 'method_unresolved'
            counts[value] += 1
        else:
            raw = bytes.fromhex(method['first_256_native_bytes'])
            assert len(raw) == 256 and hashlib.sha256(raw).hexdigest() == method['first_256_sha256']
            # MOVZ (W/X) immediate, no shift, in native argument register 1 or 2.
            # These encodings were checked against the saved IDA instructions.
            matches = [(index * 4, word) for index, (word,) in enumerate(struct.iter_unpack('<I', raw))
                       if word & 0x7f800000 == 0x52800000 and (word >> 21) & 3 == 0
                       and (word >> 5) & 0xffff == expected and word & 31 in (1, 2)]
            assert matches, f'No recorded argument-load witness: {version} {selector}'
            offset, word = matches[0]
            value = json.dumps({'method': hex(method['implementation']),
                                'load': hex(method['implementation'] + offset),
                                'register': ('x' if word >> 31 else 'w') + str(word & 31),
                                'word': f'{word:08x}', 'encoding': method['types']}, separators=(',', ':'))
            counts['argument_load_witness'] += 1
        rows[dependency, str(expected), selector].append(value)
    for direction, action, ancestor in directions:
        value = json.dumps({'method': hex(scroll['method_address']), 'layout': scroll['layout'],
                            'table': hex(scroll['table_address'])}, separators=(',', ':'))
        rows['scroll_' + direction, f'{action}->{ancestor}', 'scrollAncestorForScrollAction:'].append(value)
        counts['scroll_mapping'] += 1
    summary['versions'][version] = {'cache': data['cache'], 'reader_sha256': data['reader_sha256'],
                                    'metadata_collector_sha256': data['collector_sha256'],
                                    'scroll_collector_sha256': scroll['collector_sha256'],
                                    'metadata_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                                    'scroll_sha256': hashlib.sha256(scroll_path.read_bytes()).hexdigest(),
                                    'scroll_reference_ida_sha256': scroll['reference_ida_sha256']}
args.output.parent.mkdir(parents=True, exist_ok=True)
with args.output.open('w') as stream:
    writer = csv.writer(stream, delimiter='\t', lineterminator='\n')
    writer.writerow(['dependency', 'source_value', 'native_witness_selector', *versions])
    for key, cells in rows.items():
        writer.writerow([*key, *cells])
summary['counts'] = dict(counts)
args.output.with_suffix('.summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps({'rows': len(rows), 'versions': len(versions), 'counts': dict(counts)}))
