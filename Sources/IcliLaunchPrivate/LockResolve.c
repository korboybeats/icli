#include "IcliLaunchPrivate.h"

// SpringBoard answers SBGetScreenLockStatus from SBLockScreenManager's live
// isUILocked, and writes the same value into com.apple.springboard.lockstate
// only when the UI lock changes. A SpringBoard that starts unlocked after a
// respring (SBDontLockAfterCrash, as NoPassAfterRespring sets it) never
// writes it, so the state of the SpringBoard that was killed remains, and
// SBGetScreenLockStatus reads unlocked on a locked iOS 26 device. Either
// source alone can say locked on an unlocked phone, so locked needs both to
// agree, and a disagreement is reported instead of blocking commands.
IcliLockStatus icli_lock_resolve(IcliLockStatus s) {
    s.sources_disagree = s.springboard_answered && s.springboard_locked != s.notification_locked;
    s.locked = s.springboard_answered ? s.springboard_locked && s.notification_locked : s.notification_locked;
    return s;
}
