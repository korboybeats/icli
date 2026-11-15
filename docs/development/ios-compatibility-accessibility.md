# Accessibility protocol evidence

Scope: native instruction and dispatch-table inspection of iOS 14.0.1 and
27.2.1, plus native accessor argument-load witnesses and scroll mapping checks
across all 40 supplied caches.
The available iOS 17.1.1 device separately passed the complete `korboy7`
non-reboot acceptance suite. The later `korboy8` run was paused after 68 passing
cases and remains incomplete.
The static results do not prove device operation on another release. No
production behavior changed in this check.

`Sources/IcliPrivate/Accessibility.m` uses numeric AX attributes/actions. The
numbers below were checked against actual native instructions, not the
similarly named macOS prototypes that IDA's type library can attach to these
iOS exports. Short tail-call wrappers can also decompile without displaying
their argument loads; their disassembly is the evidence for those constants.

| Dependency | icli value | iOS 14.0.1 native evidence | iOS 27.2.1 native evidence |
| --- | ---: | --- | --- |
| Label attribute | 2001 | `AXElement.label`, `0x19e585614` | `AXElement.label`, `0x18fd6f37c` |
| Value attribute | 2006 | `AXElement.value`, `0x19e585728` | `AXElement.value`, `0x18fd6f438` |
| Frame attribute | 2003 | `AXElement.frame`, `0x19e5859a8` | `AXElement.frame`, `0x18fd6f744` |
| Traits attribute | 2004 | `AXElement.traits`; saved native argument load | `AXElement.traits`; saved native argument load |
| Center point attribute | 2007 | `AXElement.centerPoint`; native load `0x7d7` | `AXElement.centerPoint`; native load `0x7d7` |
| Accessibility identifier attribute | 5019 | App-side dispatch calls `accessibilityIdentifier`; detailed below | `AXElement.axIdentifier`; native load `0x139b` |
| Parent attribute | 5002 | `AXElement.parent`, `0x19e5898e0` | `AXElement.parent`, `0x18fd73024` |
| Visible element list | 3015 | `AXElement.visibleElements`; saved native argument load | `AXElement.visibleElements`; saved native argument load |
| Clipped frame attribute | 2057 | `AXElement.visibleFrame`, `0x19e585b78` | `AXElement.visibleFrame`, `0x18fd6f86c` |
| Direct activation capability | 2019 | `AXElement.canPerformActivate`, `0x19e5884fc` | `AXElement.canPerformActivate`, `0x18fd71c00` |
| Direct activation action | 2010 | `AXElement._performActivate`, `0x19e588674` | `AXElement._performActivate`, `0x18fd71cf8` |
| Reveal action | 2003 | `AXElement.scrollToVisible`; native action argument | `AXElement.scrollToVisible`; native action argument |

`AXElement.scrollAncestorForScrollAction:` is at `0x19e58815c` on 14.0.1 and
`0x18fd71848` on 27.2.1. Both subtract 2006 from the action and index the native
three-entry table for offsets 0–2; the remaining branch selects 2107. Reading
the actual table bytes at `0x19e5a2778` and `0x18fd87b70` gives the same values:

| icli direction | Action | Ancestor attribute |
| --- | ---: | ---: |
| down | 2006 | 2109 |
| up | 2007 | 2108 |
| left | 2008 | 2106 |
| right | 2009 | 2107 |

## Checks across all supplied caches

The [native witness matrix](ios-compatibility-accessibility.tsv) adds a column
for every supplied cache. Its [input summary](ios-compatibility-accessibility.summary.json)
retains the source, cache, reader, collector, raw-record and IDA-reference hashes.
It contains 444 matching native argument-load witnesses and 160 separately
checked scroll mappings, with 36 unresolved wrapper cells.

For the eleven common accessor/action rows, the actual `AXElement` method
metadata identifies the native implementation address in each cache. Its
copied bytes contain the expected unshifted `MOVZ` into argument register 1
or 2; each cell records that instruction address, register, word and native
method encoding. These are bounded argument-load witnesses, not a proof of
the complete method's control flow or every private C/MIG signature.

The `axIdentifier` wrapper supplies four additional 5019 argument-load witnesses
on 26–27. The earlier 36 class-chain snapshots do not provide that wrapper.
Those cells remain `method_unresolved`, which does not mean the attribute is
unavailable. The older app-side 5019 dispatch proof below and the 17.1.1 fixture
runtime result remain separate evidence; other older app-side dispatchers are
not inferred from the newer wrapper.

Every cache's scroll mapping was checked against its actual code and table.
Thirty-two use the inline three-value table and a 2107 default. The eight
16.x caches call a native switch helper. IDA disassembly and decompilation of
16.0.3, 16.4.1 and arm64-only 16.7.16 establish the three helper code shapes.
The later arm64e helper changes the range-check instructions; the arm64 helper
uses different jump registers and has no caller authentication instruction.
For each supplied cache, all helper instructions match one inspected shape
apart from the two page-address instructions, which are decoded and checked
against the actual jump-table bytes. No unknown shape receives a mapping.
All four mappings agree with the table above in all 40 caches.

The raw class snapshots, copied instructions and switch/table records remain
in `.build/compatibility/ax-native-methods/`. The native inputs were collected
with `compatibility-objc.py`'s cache reader and the local
`.build/compatibility/collect-ax-native-methods.py` and
`collect-ax-scroll-mappings.py` research scripts. The latter records the exact
inspected helper shapes and rejects unmatched code. Regenerate the committed
matrix from those saved inputs with:

```sh
python3 scripts/compatibility-accessibility.py \
  --metadata .build/compatibility/ax-native-methods
```

## Identifier dispatch on iOS 14

The older `AXElement.identifier` wrapper loads 2031. That is a different
attribute from the accessibility identifier requested by icli; the wrapper's
name alone must not be used to substitute its number.

The app-side `NSObject(AXPrivCategory)._iosAccessibilityAttributeValue:` entry
is `0x193852a14` in 14.0.1 UIAccessibility. Its 5001-based dispatch table is at
`0x1938574d4`. For 5019, index 18 contains signed relative offset -16012,
selecting native code at `0x193853648`. Its selector references resolve in the
same cache to `accessibilityIdentifier` at `0x1ca6ba607`, followed by
`_accessibilityPostProcessValueForAutomation:` at `0x1c9da2408`.

This directly establishes the older service's 5019 getter. IDA did not create
a function for the complete large dispatcher automatically, so the result was
obtained from its actual dispatch instructions, table bytes and selected native
instructions. No missing method-name result was treated as absence.

## Evidence and remaining scope

Raw IDA disassembly, pseudocode, table bytes and selector resolutions remain in
`.build/compatibility/ax-protocol/14.0.1.json`, `27.2.1.json` and
`14.0.1-uiaccessibility.json`. Image, source and raw-evidence hashes are retained
in `identities.json` there. The framework images were extracted from the
existing caches; this check used no additional device or full firmware download.

The endpoint `AXUIElementPerformAction` implementations both dispatch a
numeric action through their native MIG path. The attribute-copy implementation
likewise passes the numeric attribute through its native request. These checks
do not establish every MIG field, requesting-client policy, entitlement gate,
app-specific handler or attribute on every supplied release. The all-cache
argument-load witnesses and scroll mappings above do not close those limits.
Those remain
separate compatibility qualification work.
