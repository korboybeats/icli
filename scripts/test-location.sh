#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Compile production request/response logic and JSON decoding. Only OS
# availability, native bridge calls and the wall-clock wait are substituted.
python3 - "$work" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
source = Path('Sources/IcliKit/Location.swift').read_text()
availability = '#available(iOS 15.0, tvOS 15.0, *)'
assert source.count(availability) == 2
source = source.replace('import IcliPrivate\n', '').replace('import IcliSystem\n', '')
source = source.replace(availability, 'fixtureHasSourceInformation')
assert source.count('Thread.sleep(forTimeInterval: 1.5)') == 1
source = source.replace('Thread.sleep(forTimeInterval: 1.5)', 'fixtureLocationWait()')
(out / 'Location.swift').write_text(source)
errors = Path('Sources/IcliSystem/Errors.swift').read_text().replace('import IcliSystemPrivate\n', '')
(out / 'Errors.swift').write_text(errors)
native = Path('Sources/IcliPrivate/Location.m').read_text()
send = native[native.index('static NSString *sendAll('):native.index('\nchar *icli_location_simulate_json(')]
clear = native[native.index('char *icli_location_clear_json('):native.index('\n@interface IcliLocationReader')]
assert clear.count('@available(iOS 15.0, tvOS 15.0, *)') == 1
clear = clear.replace('@available(iOS 15.0, tvOS 15.0, *)', 'fixtureSourceInformationAvailable()')
(out / 'Delivery.m').write_text(send + '\n' + clear)
PY
xcrun swiftc -swift-version 5 -module-cache-path "$work/modules" \
  Tests/Location/main.swift "$work/Location.swift" "$work/Errors.swift" \
  -o "$work/location-tests"
"$work/location-tests"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation \
  -ISources/IcliPrivate -include Tests/Location/Delivery.h \
  "$work/Delivery.m" Tests/Location/Delivery.m -o "$work/location-delivery-tests"
"$work/location-delivery-tests"
