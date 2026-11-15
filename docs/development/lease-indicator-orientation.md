# Lease indicator orientation repair — 2026-11-13

The previous bounds-only repair did not establish the window's rendered
orientation. With RuneLite in landscape, the installed indicator window and
its controller reported orientation 1 (portrait), while SpringBoard and its
main scene reported 4. Its view was nevertheless 932 by 430 points, and its
label frame looked correct at 375.333,396,181.333,18. This is why the earlier
frame checks could pass while the user saw a sideways, clipped label.

UIKitCore was inspected in IDA. UIWindow's orientation update asks its root
controller for `_preferredInterfaceOrientationGivenCurrentOrientation:`;
that normally consults the window scene's orientation resolver. On this
phone, the resolver returned portrait even with landscape requested and an
orientation mask allowing landscape. A live experiment confirmed that
following SpringBoard's active interface orientation and correcting the
window bounds fixes the rendered result.

The indicator's own controller now returns SpringBoard's active interface
orientation, with a runtime selector check and the supplied orientation as
fallback. Its layout callback synchronizes the window frame to its screen
bounds before positioning the label. No hooks into system classes, timers,
polling, or rotation-lock changes were added. The indicator target explicitly
links CoreGraphics for CGRectEqualToRect.

Built arm64 and arm64e on the Mac with warnings treated as errors, signed,
passed indicator import and iOS 15 deployment-floor verification, copied only
the indicator dylib to the phone, and restarted SpringBoard. Installed and
built SHA-256 both equal:

`b6dc789080cf0af6cf05383b64deefb638443a337c518da5c75a0bf82f972955`

Validation on iPhone 15 Pro Max, iOS 17.1.1:

| Check | Result |
| --- | --- |
| RuneLite landscape left, orientation 4 | Horizontal label, centered, frame y=396..414 |
| Settings portrait, orientation 1 | Horizontal label, centered, frame y=898..916 |
| RuneLite landscape right, orientation 3 | Horizontal label, centered, frame y=396..414 |
| Destroy and recreate the indicator while already in landscape | Correct orientation and visible placement |
| Portrait to landscape and back to original landscape | Correct without manual layout repair |
| Normal screenshot exclusion | 0 indicator-colored pixels in the tested label region, versus 2431 when temporarily visible |
| Release our lease | Window hidden; no lease held |

Screenshots were visually inspected, including both landscape directions.
The landscape home bar begins at y=417, leaving the intended three-point gap
below the label's frame. Screenshot exclusion was temporarily cleared for
visible proof, then restored and read back as mask 2. The window still
reports `_ignoresHitTest` true; this run did not independently retest tapping
through the label.

The original RuneLite process (PID 8844) remains running and foreground.
Original landscape-left orientation and enabled rotation lock were restored.
This is an indicator-only installation, not a rebuilt package or release.

Evidence is local under `.build/indicator-orientation-fix/`: build log,
signed dylib, portrait and landscape images, screenshot-exclusion pair, and
`icli-indicator-fixed-validation.jsonl`. The live experimental controller was
removed by the SpringBoard restart; validation used IcliIndicatorViewController
from the installed dylib.
