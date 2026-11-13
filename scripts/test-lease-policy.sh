#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
work = Path(sys.argv[1])
status = Path('Sources/IcliKit/Status.swift').read_text()
lease = status[status.index('public enum Lease {'):status.index('public func leaseStatus()')]
lease = lease.replace('"/var/mobile/Library/Caches/com.korboy.icli/lease.json"', 'testLeasePath')
envelope = Path('Sources/IcliKit/Envelope.swift').read_text()
policy = envelope[envelope.index('    public static func applyLockPolicy('):envelope.index('    public static func printJSON(')]
fixture = Path('Tests/LeasePolicy/main.swift').read_text()
fixture = fixture.replace('// PRODUCTION LEASE', lease).replace('// PRODUCTION POLICY', policy)
(work / 'main.swift').write_text(fixture)
PY
"${SWIFTC:-swiftc}" "$work/main.swift" -o "$work/lease-tests"
"$work/lease-tests"
