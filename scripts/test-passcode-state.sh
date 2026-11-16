#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Compile the production function verbatim; only framework/class lookup is replaced.
python3 - "$work/passcode-state.m" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/IcliPrivate/IcliPrivate.m').read_text()
start = source.index('int icli_passcode_set(void) {')
end = source.index('\nstatic int parseRotationDegrees', start)
Path(sys.argv[1]).write_text('#import "IcliPrivate.h"\n#import <objc/message.h>\n' + source[start:end])
PY
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -include Tests/PasscodeStateFixture.h -framework Foundation \
  -ISources/IcliPrivate/include -ISources/IcliSystemPrivate/include -ISources/IcliLaunchPrivate/include \
  "$work/passcode-state.m" Tests/PasscodeStateFixture.m -o "$work/passcode-state-tests"
"$work/passcode-state-tests"
