#!/bin/sh
# Exercise the production native bridge without touching a device.
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PYTHON'
from pathlib import Path
import sys
out = Path(sys.argv[1])
source = Path('Sources/IcliPrivate/SilentMode.m').read_text()
assert source.count('@available(iOS 17.0, *)') == 2
source = source.replace('@available(iOS 17.0, *)', 'fixtureModernSilentAPI()')
(out / 'SilentMode.m').write_text(source)
source = Path('Sources/IcliPrivate/FullUnlock.m').read_text()
types = source[source.index('static bool unlockTypeMatches('):source.index('static bool invokeUnlock(')]
ringer = source[source.index('static bool invokeRinger('):source.index('static void cleanup(')]
(out / 'ringer-production.inc').write_text(types + ringer)
PYTHON
for fixture in main legacy; do
  xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -include Tests/AudioControllerFixture.h \
    -framework Foundation \
    -ISources/IcliPrivate -ISources/IcliPrivate/include -ISources/IcliSystemPrivate/include -ISources/IcliLaunchPrivate/include \
    "$work/SilentMode.m" "Tests/SilentMode/$fixture.m" -o "$work/silent-mode-tests"
  "$work/silent-mode-tests"
done
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I"$work" \
  Tests/SilentMode/ringer.m -framework Foundation -o "$work/ringer-tests"
"$work/ringer-tests"
