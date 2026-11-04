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
    bool locked;
    bool screen_off;
    bool passcode_enabled;
} IcliLockStatus;

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
