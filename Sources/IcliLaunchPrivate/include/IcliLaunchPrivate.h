#pragma once

#include <stdbool.h>
#include <stdint.h>

// Lock state, app launch and the frontmost app: what a host needs to bring an
// app forward. Foundation only; SpringBoardServices, LaunchServices and
// RunningBoardServices are looked up at runtime, so nothing here links UIKit.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    /// Locked only when every source that answered says locked.
    bool locked;
    bool screen_off;
    bool passcode_enabled;
    /// com.apple.springboard.lockstate's state: SpringBoard writes it on each
    /// UI lock change, and notifyd keeps the last value across a respring.
    bool notification_locked;
    /// Whether SpringBoard answered SBGetScreenLockStatus, and its live
    /// SBLockScreenManager isUILocked.
    bool springboard_answered;
    bool springboard_locked;
    /// SpringBoard answered and the notification state says otherwise.
    bool sources_disagree;
} IcliLockStatus;

/// Fills `locked` and `sources_disagree` from the source fields. Pure, so a
/// host test can run it.
IcliLockStatus icli_lock_resolve(IcliLockStatus sources);

typedef enum {
    /// SpringBoard, LaunchServices or (on tvOS) FrontBoard accepted the request.
    IcliLaunchAccepted = 0,
    /// Refused while the device was locked or its screen was off.
    IcliLaunchLocked = 1,
    /// Refused on an unlocked device.
    IcliLaunchRefused = 2,
} IcliLaunchResult;

IcliLockStatus icli_lock_status(void);
/// On a refusal, `reason` (when not NULL) receives the system shell's
/// explanation when it gave one (PineBoard on tvOS), to be released with free().
IcliLaunchResult icli_launch_app(const char *bundle_id, char **reason);
/// FrontBoard's open request with debug options, which reach the new process
/// only: JSON for an array of arguments and an object of environment variables.
IcliLaunchResult icli_launch_app_with_options(
    const char *bundle_id, const char *arguments_json, const char *environment_json, char **reason);
char *icli_frontmost_app_json(void);

/// Counts posts of 1-8 Darwin notification names while a wait runs, so it
/// looks again only when one arrived. NULL when a name cannot be registered;
/// every watch needs icli_watch_end. wait returns the
/// count, still `seen` when nothing arrived within `timeout` seconds.
typedef struct IcliWatch IcliWatch;
IcliWatch *icli_watch_notify(const char *const *names, int count);
uint64_t icli_watch_count(IcliWatch *watch);
uint64_t icli_watch_wait(IcliWatch *watch, uint64_t seen, double timeout);
void icli_watch_end(IcliWatch *watch);

#ifdef __cplusplus
}
#endif
