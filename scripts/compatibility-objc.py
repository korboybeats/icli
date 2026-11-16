#!/usr/bin/env python3
"""Read cached Objective-C metadata without rewriting or extracting cache images.

Format references: Apple's dyld_cache_format.h, objc-shared-cache.h and
ObjCVisitor.h; local go-macho's types/objc/objc.go for relative list entries.
Unsupported cache formats and invalid strings raise errors instead of absent
results. Unparseable type encodings remain explicit unresolved method records.
Separate category lists retain their defining image: their presence does not
prove that image is loaded by a caller. Unresolved methods are not absence
proof. Receiver classes must be confirmed at their source call sites.

https://github.com/apple-oss-distributions/dyld/blob/main/include/mach-o/dyld_cache_format.h
https://github.com/apple-oss-distributions/dyld/blob/main/include/objc-shared-cache.h
https://github.com/apple-oss-distributions/objc4/blob/main/runtime/objc-runtime-new.h
"""
from bisect import bisect_right
from functools import cache
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct


def signature_types(encoding):
    position, result = 0, []
    def one():
        nonlocal position
        start = position
        while encoding[position] in 'rnNoORVA':
            position += 1
        char = encoding[position]
        position += 1
        if char in '^j':
            one()
        elif char in '{[(':
            stack = [char]
            while stack:
                char = encoding[position]
                position += 1
                if char == '"':
                    while encoding[position] != '"':
                        position += 2 if encoding[position] == '\\' else 1
                    position += 1
                elif char in '{[(':
                    stack.append(char)
                elif char in '}])':
                    assert {'}': '{', ']': '[', ')': '('}[char] == stack.pop()
        elif char == '@':
            if position < len(encoding) and encoding[position] == '?':
                position += 1
                if position < len(encoding) and encoding[position] == '<':
                    depth = 1
                    position += 1
                    while depth:
                        char = encoding[position]
                        position += 1
                        if char == '"':
                            position = encoding.index('"', position) + 1
                        elif char == '<':
                            depth += 1
                        elif char == '>':
                            depth -= 1
            elif position < len(encoding) and encoding[position] == '"':
                position = encoding.index('"', position + 1) + 1
        elif char == 'b':
            while position < len(encoding) and encoding[position].isdigit():
                position += 1
        else:
            assert char in 'v#:cCsSiIlLqQfdDB*?', (encoding, char)
        return encoding[start:position]
    while position < len(encoding):
        result.append(one())
        if position < len(encoding) and encoding[position] in '+-':
            position += 1
        while position < len(encoding) and encoding[position].isdigit():
            position += 1
    return result


class Cache:
    def __init__(self, folder):
        primaries = [p for p in folder.glob('dyld_shared_cache_*')
                     if p.name in ['dyld_shared_cache_arm64', 'dyld_shared_cache_arm64e']]
        assert len(primaries) == 1, primaries
        self.regions, self.fds, self.identity = [], [], {}
        self._categories = None
        for path in sorted(folder.glob(primaries[0].name + '*')):
            fd = os.open(path, os.O_RDONLY)
            self.fds.append(fd)
            h = os.pread(fd, 4096, 0)
            if not h.startswith(b'dyld_v1'):
                continue
            stat = path.stat()
            self.identity[path.name] = {'size': stat.st_size, 'mtime_ns': stat.st_mtime_ns,
                                        'header_sha256': hashlib.sha256(h).hexdigest()}
            mo, mc = struct.unpack_from('<II', h, 16)
            if path == primaries[0]:
                self.primary, self.header = fd, h
            slides = {}
            if mo >= 320:
                offset, count = struct.unpack_from('<II', h, 312)
                assert count < 128
                for i in range(count):
                    a, size, off, slide, slide_size, flags, mx, init = struct.unpack(
                        '<QQQQQQII', os.pread(fd, 56, offset + 56 * i))
                    if slide_size:
                        info = os.pread(fd, 40, slide)
                        version = struct.unpack_from('<I', info)[0]
                        if version in [3, 5]:
                            add, mask = struct.unpack_from('<Q', info, 16)[0], 0
                        elif version == 2:
                            mask, add = struct.unpack_from('<QQ', info, 24)
                        else:
                            raise ValueError(f'unsupported slide version {version}')
                        slides[a] = (version, add, mask)
            for i in range(mc):
                a, size, off, mx, init = struct.unpack('<QQQII', os.pread(fd, 32, mo + i * 32))
                self.regions.append((a, a + size, fd, off, *slides.get(a, (0, 0, 0))))
        self.regions.sort()
        self.starts = [m[0] for m in self.regions]
        self.base = self.starts[0]
        self.opt_version, self.selector_base = self.optimizations()

    def region(self, address):
        index = bisect_right(self.starts, address) - 1
        if index < 0 or not self.regions[index][0] <= address < self.regions[index][1]:
            raise ValueError(f'address outside cache: {address:#x}')
        return self.regions[index]

    def read(self, address, size):
        lo, hi, fd, off, *_ = self.region(address)
        if address + size > hi:
            raise ValueError(f'read crosses mapping: {address:#x}+{size}')
        data = os.pread(fd, size, off + address - lo)
        assert len(data) == size
        return data

    def unpack(self, fmt, address):
        return struct.unpack(fmt, self.read(address, struct.calcsize(fmt)))

    def pointer(self, address):
        value, = self.unpack('<Q', address)
        if not value:
            return 0
        _, _, _, _, version, add, mask = self.region(address)
        if version == 3:
            if value >> 63:
                return add + (value & 0xffffffff)
            return (value & 0x7ffffffffff) | ((value & 0x7f80000000000) << 13)
        if version == 5:
            target = add + (value & 0x3ffffffff)
            return target if value >> 63 else target | (((value >> 34) & 0xff) << 56)
        if version == 2:
            value &= ~mask
            return value + add if value else 0
        return value

    def string(self, address):
        if not address:
            raise ValueError('null string')
        hi = self.region(address)[1]
        data = self.read(address, min(16384, hi - address))
        if b'\0' not in data:
            raise ValueError(f'unterminated string: {address:#x}')
        return data.split(b'\0', 1)[0].decode('utf-8')

    def images(self):
        h = self.header
        offset, count = struct.unpack_from('<II', h, 448) if struct.unpack_from('<I', h, 16)[0] >= 456 else (0, 0)
        if not offset:
            offset, count = struct.unpack_from('<II', h, 24)
        assert 0 < count < 20000
        images = os.pread(self.primary, count * 32, offset)
        for i in range(count):
            address, _, _, path_offset, _ = struct.unpack_from('<QQQII', images, i * 32)
            path = os.pread(self.primary, 1024, path_offset).split(b'\0', 1)[0].decode()
            yield path, address

    def image_address(self, name):
        for path, address in self.images():
            if path == name:
                return address
        raise ValueError('image not located: ' + name)

    def sections(self, image):
        magic, cpu, subtype, kind, ncmds, size, flags, reserved = self.unpack('<IIIIIIII', image)
        assert magic == 0xfeedfacf and size < 16 * 1024 * 1024
        commands = self.read(image + 32, size)
        offset = 0
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', commands, offset)
            assert size >= 8
            if cmd == 0x19:
                count, = struct.unpack_from('<I', commands, offset + 64)
                for i in range(count):
                    entry = offset + 72 + i * 80
                    name = commands[entry:entry + 16].rstrip(b'\0').decode()
                    yield name, struct.unpack_from('<QQ', commands, entry + 32)
            offset += size

    def section(self, image, section):
        for name, value in self.sections(image):
            if name == section:
                return value
        raise ValueError('section not located: ' + section)

    def categories(self, address):
        if self._categories is None:
            categories = {}
            seen = set()
            for image, header in self.images():
                for name, (start, size) in self.sections(header):
                    if name not in ['__objc_catlist', '__objc_nlcatlist']:
                        continue
                    assert size % 8 == 0, (image, name, size)
                    for entry in range(start, start + size, 8):
                        category = self.pointer(entry)
                        if not category or category in seen:
                            continue
                        seen.add(category)
                        cls = self.pointer(category + 8)
                        if not cls:
                            continue  # Weak or unresolved class reference; no receiver claim.
                        category_name = self.string(self.pointer(category))
                        for owner, offset in [(cls, 16), (self.pointer(cls), 24)]:
                            methods = self.pointer(category + offset)
                            if owner and methods:
                                categories.setdefault(owner, []).append({
                                    'name': category_name, 'image': image,
                                    'address': category, 'method_list': methods})
            self._categories = categories
        return [{**category, 'methods': self.methods(category['method_list'])}
                for category in self._categories.get(address, [])]

    def optimizations(self):
        address, size = self.section(self.image_address('/usr/lib/libobjc.A.dylib'), '__objc_opt_ro')
        version, flags = self.unpack('<II', address)
        if version == 16:
            offset, = self.unpack('<q', address + 40)
            return version, address + offset if offset else 0
        if version == 15:
            return version, 0
        raise ValueError(f'unsupported Objective-C optimization version: {version}')

    def lists(self, address):
        if not address:
            return []
        if not address & 1:
            return [address]
        address &= ~1
        size, count = self.unpack('<II', address)
        assert size == 8 and count < 10000, (hex(address), size, count)
        return [entry + (self.unpack('<q', entry)[0] >> 16)
                for entry in range(address + 8, address + 8 + 8 * count, 8)]

    @cache
    def methods(self, address):
        output = []
        for method_list in self.lists(address):
            flags, count = self.unpack('<II', method_list)
            if count == 0:
                continue
            size = flags & 0xfffc
            assert size in [12, 24] and count < 100000, (hex(method_list), hex(flags), count)
            for i in range(count):
                entry = method_list + 8 + i * size
                if flags & 0x80000000:
                    assert size == 12
                    no, to, io = self.unpack('<iii', entry)
                    if flags & 0x40000000:
                        name_address = self.selector_base + (no & 0xffffffff) if self.opt_version >= 16 else entry + no
                    else:
                        name_address = self.pointer(entry + no)
                    if flags & 0x20000000:
                        assert self.selector_base
                        type_address = self.selector_base + (to & 0xffffffff)
                    else:
                        type_address = entry + 4 + to
                    implementation = entry + 8 + io
                else:
                    assert size == 24
                    name_address, type_address, implementation = [self.pointer(entry + j) for j in [0, 8, 16]]
                selector, types = self.string(name_address), self.string(type_address)
                assert selector
                self.region(implementation)
                encoding_error = None
                try:
                    tokens = signature_types(types)
                    assert len(tokens) == selector.count(':') + 3, 'type count differs from selector arity'
                except (AssertionError, IndexError, ValueError) as error:
                    tokens, encoding_error = None, str(error)
                output.append({'selector': selector, 'types': types, 'signature': tokens,
                               'encoding_error': encoding_error,
                               'implementation': implementation, 'entry': entry})
        return output

    def chain(self, address):
        result, seen = [], set()
        while address:
            assert address not in seen and len(seen) < 128
            seen.add(address)
            ro = self.pointer(address + 32) & ~7
            result.append({'name': self.string(self.pointer(ro + 24)), 'address': address,
                           'ro_flags': self.unpack('<I', ro)[0],
                           'methods': self.methods(self.pointer(ro + 32)),
                           'categories': self.categories(address)})
            address = self.pointer(address + 8)
        return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--definitions', type=Path, required=True)
    parser.add_argument('--supplement', type=Path, action='append', default=[])
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--corpus', type=Path, default=Path.home() / 're/ios')
    parser.add_argument('--class', dest='classes', action='append')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    inventory = json.loads(args.inventory.read_text())
    classes = args.classes or sorted({i['name'] for i in inventory['items']
                                     if i['kind'] in ['class', 'class-candidate']})
    cache = Cache(args.corpus / args.version / 'dsc')
    records, inputs = [], []
    for definitions in [args.definitions, *args.supplement]:
        metadata = json.loads(definitions.with_name('scan.json').read_text())
        assert metadata['cache'] == cache.identity, 'Cache identity differs from symbol scan'
        records.extend(json.loads(definitions.read_text()))
        inputs.append({'file': str(definitions), 'sha256': hashlib.sha256(definitions.read_bytes()).hexdigest(),
                       'scan': metadata})
    output = {'version': args.version, 'objc_optimization_version': cache.opt_version,
              'selector_base': cache.selector_base, 'cache': cache.identity,
              'inventory_sha256': hashlib.sha256(args.inventory.read_bytes()).hexdigest(),
              'reader_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'definitions': inputs, 'classes': {}, 'nodes': {}}
    for name in classes:
        addresses = {r['address'] for r in records if r['name'] == '_OBJC_CLASS_$_' + name and r['address']
                     and 'undefined' not in r['type'].lower()}
        if len(addresses) != 1:
            output['classes'][name] = {'unresolved_symbol_addresses': sorted(addresses)}
            continue
        address = addresses.pop()
        instance = cache.chain(address)
        assert instance[0]['name'] == name
        metaclass = cache.chain(cache.pointer(address))
        for node in instance + metaclass:
            output['nodes'][str(node['address'])] = node
        output['classes'][name] = {'instance': [n['address'] for n in instance],
                                   'class': [n['address'] for n in metaclass]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + '\n')
    resolved = sum('instance' in c for c in output['classes'].values())
    print(json.dumps({'version': args.version, 'resolved_classes': resolved,
                      'requested_classes': len(classes), 'method_records': sum(
                          len(n['methods']) for n in output['nodes'].values()),
                      'unparsed_encodings': sum(m['signature'] is None
                          for n in output['nodes'].values() for m in n['methods'])}))
