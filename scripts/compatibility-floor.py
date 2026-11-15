#!/usr/bin/env python3
"""Write the iOS 14.0 export evidence used by binary verification."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import runpy

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scan', type=Path, required=True, help='Completed 14.0 cache scan directory')
parser.add_argument('--additional', type=Path, action='append', default=[], help='Additional full-path definition records')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.scan.name != '14.0':
    parser.error('The floor must be measured from the 14.0 cache, not a later release.')
metadata = json.loads((args.scan / 'scan.json').read_text())
is_exported = runpy.run_path(str(Path(__file__).with_name('compatibility-matrix.py')))['is_exported']
exports = defaultdict(set)
inputs = []
for path in [args.scan / 'definitions.json', *args.additional]:
    raw = path.read_bytes()
    inputs.append({'file': path.name, 'sha256': hashlib.sha256(raw).hexdigest()})
    for item in json.loads(raw):
        if not item.get('address') or 'undefined' in item['type'].lower():
            continue
        if not is_exported(item):
            continue
        if not item['image'].startswith('/'):
            parser.error('Definition owners must be full image paths: ' + item['image'])
        exports[item['name']].add(item['image'])
cache = {name: {key: value for key, value in info.items() if key != 'mtime_ns'}
         for name, info in metadata['cache'].items()}
result = {'schema': 1, 'version': '14.0', 'cache': cache,
          'ipsw_version': metadata['ipsw_version'], 'query_sha256': metadata['query_sha256'],
          'inputs': inputs, 'exports': {name: sorted(images) for name, images in sorted(exports.items())}}
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(f'Wrote {len(exports)} measured iOS 14.0 export names')
