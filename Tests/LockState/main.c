#include <stdio.h>
#include <stdlib.h>
#include "IcliLaunchPrivate.h"

static int failures;

static void expect(const char *name, IcliLockStatus sources, bool locked, bool disagree) {
    IcliLockStatus st = icli_lock_resolve(sources);
    if (st.locked != locked || st.sources_disagree != disagree) {
        fprintf(stderr, "FAIL %s: locked %d (want %d), disagree %d (want %d)\n",
                name, st.locked, locked, st.sources_disagree, disagree);
        failures++;
    }
    if (st.screen_off != sources.screen_off || st.passcode_enabled != sources.passcode_enabled) {
        fprintf(stderr, "FAIL %s: resolve changed screen_off or passcode_enabled\n", name);
        failures++;
    }
}

int main(void) {
    // Measured on iOS 17.1.1 after `killall SpringBoard` with the UI locked and
    // NoPassAfterRespring installed: SpringBoard came back unlocked
    // (isUILocked NO, hasUIEverBeenLocked NO) and never rewrote lockstate,
    // which kept the killed SpringBoard's 1.
    expect("after respring, lockstate left at 1",
           (IcliLockStatus){.notification_locked = true, .springboard_answered = true, .springboard_locked = false},
           false, true);
    expect("locked",
           (IcliLockStatus){.notification_locked = true, .springboard_answered = true, .springboard_locked = true,
                            .screen_off = true, .passcode_enabled = true},
           true, false);
    expect("unlocked",
           (IcliLockStatus){.springboard_answered = true},
           false, false);
    // isUILocked changes before SpringBoard writes the notification state.
    expect("SpringBoard ahead of lockstate",
           (IcliLockStatus){.notification_locked = false, .springboard_answered = true, .springboard_locked = true},
           false, true);
    // During a respring nothing answers on SpringBoard's port.
    expect("SpringBoard not answering, lockstate 1",
           (IcliLockStatus){.notification_locked = true},
           true, false);
    expect("SpringBoard not answering, lockstate 0",
           (IcliLockStatus){0},
           false, false);
    if (failures) return EXIT_FAILURE;
    puts("lock state: 6 cases passed");
    return EXIT_SUCCESS;
}
