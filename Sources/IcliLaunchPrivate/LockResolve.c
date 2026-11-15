#include "IcliLaunchPrivate.h"

// SpringBoard answers SBGetScreenLockStatus from SBLockScreenManager's live
// isUILocked, and writes the same value into com.apple.springboard.lockstate
// only when the UI lock changes. A SpringBoard that starts unlocked after a
// respring (SBDontLockAfterCrash, as NoPassAfterRespring sets it) never
// writes it, so the state of the SpringBoard that was killed remains.
// Either source alone can say locked on an unlocked phone, so locked needs
// both to agree, and a disagreement is reported instead of blocking commands.
//
// iOS 26.6.2's SpringBoard answers unlocked when any connected window scene
// is unlocked (SBGetAggregatedLockStatus), so a locked phone can read
// unlocked while another scene is not. A disagreement is therefore settled by
// the keybag when it says locked: the UI cannot be unlocked over a locked
// keybag.
IcliLockStatus icli_lock_resolve(IcliLockStatus s) {
    s.sources_disagree = s.springboard_answered && s.springboard_locked != s.notification_locked;
    s.locked = s.springboard_answered ? s.springboard_locked && s.notification_locked : s.notification_locked;
    if (s.sources_disagree && s.keybag_checked && s.keybag_locked) s.locked = true;
    return s;
}
