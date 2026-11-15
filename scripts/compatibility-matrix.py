#!/usr/bin/env python3
"""Measure cache symbol definitions for the compatibility inventory.

Only a nonzero definition counts. Undefined imports and stub references are
discarded. Method results retain their implementing class: they do not prove
that another class responds to that selector, or that an ABI is unchanged.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def queries(inventory):
    symbols, classes, selectors = set(), set(), set()
    for item in inventory['items']:
        kind, name = item['kind'], item['name']
        if kind in ('symbol', 'symbol-candidate', 'floor-import', 'c-reference'):
            symbols.add('_' + name)
        elif kind in ('class', 'class-candidate'):
            classes.add(name)
        elif kind in ('selector', 'selector-candidate'):
            selectors.add(name)
        elif kind == 'objc-message':
            selectors.add(name.split(' ')[-1])
    for artifact in inventory.get('artifacts', {}).values():
        for imports in artifact['slices'].values():
            symbols.update(item['name'] for item in imports)
    union = lambda values: '(?:' + '|'.join(re.escape(x) for x in sorted(values)) + ')'
    pattern = '^(?:' + union(symbols) + r'|_OBJC_(?:META)?CLASS_\$_' + union(classes)
    pattern += r'|[+-]\[[^ ]+ ' + union(selectors) + r'\])$'
    return [{'pattern': pattern}], symbols, classes, selectors


def cache_identity(folder):
    candidates = [p for p in folder.glob('dyld_shared_cache_*')
                  if p.name in ('dyld_shared_cache_arm64', 'dyld_shared_cache_arm64e')]
    if len(candidates) != 1:
        raise ValueError(f'Expected one primary cache in {folder}, found {candidates}')
    cache = candidates[0]
    parts = {}
    for path in sorted(folder.glob(cache.name + '*')):
        with path.open('rb') as stream:
            header = stream.read(4096)
        if not header.startswith(b'dyld_v1'):
            continue
        info = path.stat()
        parts[path.name] = {'size': info.st_size, 'mtime_ns': info.st_mtime_ns,
                            'header_sha256': hashlib.sha256(header).hexdigest()}
    return cache, parts


def scan(version, args, query, query_hash):
    cache, identity = cache_identity(args.corpus / version / 'dsc')
    folder = args.output / version
    folder.mkdir(parents=True, exist_ok=True)
    metadata = folder / 'scan.json'
    expected = {'scan_schema': 2, 'cache': identity, 'query_sha256': query_hash,
                'ipsw_version': subprocess.check_output(['ipsw', 'version'], text=True).strip()}
    if metadata.exists() and json.loads(metadata.read_text()) == expected and (folder / 'definitions.json').exists():
        print('Reusing ' + version, flush=True)
        return
    # An unrestricted GetSymbols query retains Mach-O data for every image.
    # On the 27.2.1 cache that consumed over 8 GiB. The same search scoped to
    # batches of 128 images measured 1.42 GiB. All images are still searched.
    info = json.loads(subprocess.check_output(['ipsw', '--no-color', 'dyld', 'info', str(cache), '--json'], text=True))
    pattern = json.loads(query.read_text())[0]['pattern']
    groups, group, basenames = [], [], set()
    for image in info['dylibs']:
        basename = Path(image['name']).name
        if len(group) == 128 or basename in basenames:
            groups.append(group)
            group, basenames = [], set()
        group.append(image)
        basenames.add(basename)
    if group:
        groups.append(group)
    unique, completed = set(), 0
    for start, group in enumerate(groups):
        batch = folder / f'batch-{start:04d}.json'
        batch_meta = batch.with_suffix('.scan.json')
        batch_expected = {**expected, 'images': [i['name'] for i in group]}
        if not (batch.exists() and batch_meta.exists() and json.loads(batch_meta.read_text()) == batch_expected):
            lookup = folder / 'batch-query.json'
            lookup.write_text(json.dumps([{'image': item['name'], 'pattern': pattern}
                                          for item in group]) + '\n')
            raw = folder / 'symbols.raw.json'
            command = ['ipsw', '--no-color', 'dyld', 'symaddr', str(cache), '--in', str(lookup), '--output', str(raw)]
            with (folder / f'batch-{start:04d}.log').open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True,
                               env={**os.environ, 'GOMEMLIMIT': '2GiB', 'GOMAXPROCS': '2'})
            matches = [m for m in (json.loads(raw.read_text()) or [])
                       if m.get('address', 0) and 'undefined' not in m['type'].lower()]
            # ipsw returns only basenames. Several accessibility bundles and
            # plug-ins share their framework's basename, so never put two of
            # those in the same batch; retain the full owner path in evidence.
            paths = {Path(i['name']).name: i['name'] for i in group}
            for match in matches:
                match['image'] = paths[match['image']]
            batch.write_text(json.dumps(matches, separators=(',', ':')) + '\n')
            raw.unlink()
            batch_meta.write_text(json.dumps(batch_expected, indent=2) + '\n')
        matches = json.loads(batch.read_text())
        unique.update((m['name'], m['image'], m['type'], m['address']) for m in matches)
        completed += len(group)
        print(f'{version}: {completed}/{len(info["dylibs"])} images', flush=True)
    definitions = [{'name': name, 'image': image, 'type': kind, 'address': address}
                   for name, image, kind, address in sorted(unique)]
    (folder / 'definitions.json').write_text(json.dumps(definitions, separators=(',', ':')) + '\n')
    metadata.write_text(json.dumps(expected, indent=2) + '\n')
    print(f'Scanned {version}: {len(definitions)} definitions', flush=True)


def report(versions, args, symbols, classes, selectors):
    by_symbol, by_class, by_selector = defaultdict(dict), defaultdict(dict), defaultdict(dict)
    for version in versions:
        definitions = json.loads((args.output / version / 'definitions.json').read_text())
        for item in definitions:
            name = item['name']
            if name in symbols:
                by_symbol[name].setdefault(version, []).append(item)
            match = re.fullmatch(r'_OBJC_CLASS_\$_(.+)', name)
            if match and match[1] in classes:
                by_class[match[1]].setdefault(version, []).append(item)
            match = re.fullmatch(r'([+-])\[([^ ]+) (.+)\]', name)
            if match and match[3] in selectors:
                by_selector[match[3]].setdefault(version, []).append(item)
    matrix = {'schema': 1, 'versions': versions, 'inventory_sha256': digest(args.inventory),
              'symbols': {name: by_symbol[name] for name in sorted(symbols)},
              'classes': {name: by_class[name] for name in sorted(classes)},
              'selectors': {name: by_selector[name] for name in sorted(selectors)}}
    (args.output / 'matrix.json').write_text(json.dumps(matrix, separators=(',', ':')) + '\n')
    # These tables are starting points for gap investigation. In particular,
    # project-owned functions, compiler builtins and optional app libraries can
    # be absent from every system cache without being compatibility failures.
    lines = ['kind\tname\t' + '\t'.join(versions)]
    for kind, names, results in [('symbol', symbols, by_symbol), ('class', classes, by_class)]:
        for name in sorted(names):
            states = []
            for version in versions:
                hits = results[name].get(version, [])
                exports = [h for h in hits if h['type'] in ('regular', 'weak_def') or 're-export' in h['type']]
                chosen = exports or hits
                states.append(('export:' if exports else 'definition:') + ','.join(sorted({h['image'] for h in chosen}))
                              if chosen else 'not-found')
            lines.append(kind + '\t' + name + '\t' + '\t'.join(states))
    (args.output / 'presence.tsv').write_text('\n'.join(lines) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, default=ROOT / '.build/compatibility/inventory-ast.json')
    parser.add_argument('--corpus', type=Path, default=Path.home() / 're/ios')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/compatibility/cache-matrix')
    parser.add_argument('--version', action='append', dest='versions')
    args = parser.parse_args()
    inventory = json.loads(args.inventory.read_text())
    if not inventory.get('ast_requested') or inventory.get('ast_errors'):
        parser.error('A complete Clang inventory is required; inspect ast_errors before scanning.')
    versions = args.versions or sorted([p.name for p in args.corpus.iterdir()
                                       if re.fullmatch(r'\d+(?:\.\d+)+', p.name) and (p / 'dsc').is_dir()],
                                      key=lambda s: tuple(map(int, s.split('.'))))
    args.output.mkdir(parents=True, exist_ok=True)
    lookups, symbols, classes, selectors = queries(inventory)
    query = args.output / 'queries.json'
    query.write_text(json.dumps(lookups) + '\n')
    query_hash = digest(query)
    for version in versions:
        scan(version, args, query, query_hash)
    report(versions, args, symbols, classes, selectors)
    print(f'Wrote presence.tsv and matrix.json for {len(versions)} caches', flush=True)


if __name__ == '__main__':
    main()
