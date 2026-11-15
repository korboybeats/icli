#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/IcliPrivate/FullUnlock.m').read_text()
start = source.index('static bool unlockTypeMatches(')
end = source.index('static void cleanup(', start)
Path(sys.argv[1], 'unlock-signature-production.inc').write_text(source[start:end])
PY
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I"$work" \
  Tests/UnlockSignatures/main.m -framework Foundation -o "$work/unlock-signatures"
"$work/unlock-signatures"
