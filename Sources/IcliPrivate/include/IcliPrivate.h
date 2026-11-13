#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

// The read-only system half lives in IcliSystemPrivate and the lock, launch
// and frontmost bridge in IcliLaunchPrivate; both are re-exported here, so this
// module still declares the whole private bridge.
#include "IcliSystemPrivate.h"
#include "IcliLaunchPrivate.h"
#include "IcliInterfaceGeometry.h"

#ifdef __cplusplus
extern "C" {
#endif

void icli_private_init(void);

/// Whether the device has a passcode, whether or not it is locked now.
bool icli_passcode_set(void);
IcliScreenMetrics icli_screen_metrics(void);
/// Converts a point in the upright interface to the fixed (portrait) space
/// that the digitizer and accessibility hit testing use.
void icli_screen_point_to_fixed(double x, double y, double *fx, double *fy);
/// The inverse of icli_screen_point_to_fixed.
void icli_screen_fixed_to_point(double fx, double fy, double *x, double *y);
/// Converts a point in the upright interface to 0…1 digitizer coordinates.
void icli_screen_point_to_digitizer(double x, double y, double *nx, double *ny);

/// The panel's size in pixels, the fixed space the render server draws in.
void icli_panel_pixels(int *width, int *height);
/// An app's TCC permissions as {"entries":[{"service","granted"}]}, or {"error"}.
char *icli_permissions_json(const char *bundle_path);
bool icli_tcc_set(const char *service, const char *bundle_path, bool granted);
/// Back to never asked, so the app's next request shows the system prompt.
bool icli_tcc_reset(const char *service, const char *bundle_id);
/// CLAuthorizationStatus as locationd holds it for the app, or -1 when unavailable.
int icli_location_authorization_get(const char *bundle_id);
/// 0 never asked, 2 denied, 3 always, 4 while using.
bool icli_location_authorization_set(const char *bundle_id, int status);
/// An app's container preferences as cfprefsd serves them to the app, for the
/// mobile user. The setter takes NULL to remove the key, and synchronizes.
CFArrayRef icli_container_prefs_keys(CFStringRef domain, CFStringRef container) CF_RETURNS_RETAINED;
CFPropertyListRef icli_container_prefs_copy(CFStringRef key, CFStringRef domain, CFStringRef container) CF_RETURNS_RETAINED;
bool icli_container_prefs_set(CFStringRef key, CFPropertyListRef value, CFStringRef domain, CFStringRef container);
/// The upright screen as an image, one pixel per point or at full resolution,
/// without the JPEG round trip a screenshot file takes.
CGImageRef icli_screen_cgimage(bool native_resolution) CF_RETURNS_RETAINED;
/// A session ends on SIGINT, SIGTERM or SIGHUP through exit(), so its exit
/// handlers run. Call again after a step that took the signals over.
void icli_session_exit_on_signals(void);
/// While deferred, a stop signal ends the session only once the step is over.
void icli_session_defer_signals(bool defer);
/// Takes over SIGINT, SIGTERM and SIGHUP: instead of ending the process they end
/// icli_stop_signal_wait, until icli_stop_signals_release gives them back.
void icli_stop_signals_catch(void);
/// True as soon as a signal came, false after this many seconds without one.
bool icli_stop_signal_wait(double seconds);
void icli_stop_signals_release(void);
/// Draws what the display shows into an IOSurface this process has not locked.
bool icli_render_display(void *surface);
/// Runs a block as the mobile user. Appearance and text size live in that user's
/// preferences, so root would read and change a copy that no app ever looks at.
void icli_as_mobile_user(void (^body)(void));
/// 1 is light, 2 dark, -1 unavailable.
int icli_appearance_get(void);
bool icli_appearance_set(int mode);
char *icli_accessibility_json(void);
/// reduce_motion, increase_contrast or reduce_transparency.
bool icli_accessibility_set_flag(const char *name, bool on);
bool icli_accessibility_set_text_size(const char *category);

bool icli_screenshot_jpeg(const char *path, float quality, int max_bytes, bool native_resolution);
/// A screenshot as JPEG or PNG. width > 0 scales it to that many pixels wide
/// (keeping the aspect ratio) instead of one pixel per point or native pixels.
bool icli_screenshot_write(const char *path, float quality, int max_bytes, bool native_resolution, double width, bool png);
char *icli_ax_elements_json(int pid, int max_elements);
/// The same; with hierarchy, each element also has its depth below the application (1 and deeper).
char *icli_ax_elements_hierarchy_json(int pid, int max_elements, bool hierarchy);
/// Scrolls the scroll view at or nearest a point by one page with accessibility's
/// own action: direction is down, up, left or right. moved is false at the end of
/// the content or where accessibility cannot scroll that view. With sameView, only
/// the scroll view the last page moved is paged.
char *icli_ax_scroll_page_json(int pid, double x, double y, const char *direction, bool sameView);
/// Scrolls an element into view when its tap point is clipped; the element is the
/// one with this label and identifier at this point in the element list.
char *icli_ax_reveal_json(int pid, const char *label, const char *identifier, double x, double y);
char *icli_ax_element_at_json(int pid, double x, double y);
/// Frames shown on the main display, for waits that look again only after the
/// screen changed. begin answers false where frame notifications are unavailable;
/// every true begin needs one end. wait returns the frame count, still `seen`
/// when no frame arrived within `timeout` seconds.
bool icli_frames_begin(void);
void icli_frames_end(void);
uint64_t icli_frames_count(void);
uint64_t icli_frames_wait(uint64_t seen, double timeout);
/// PID, executable path and kernel start time, for detecting app replacement.
char *icli_ui_process_identity_json(int pid);
/// Owned remote AX reference. Direct activation never falls back to touch.
typedef struct IcliAXActivationTarget IcliAXActivationTarget;
IcliAXActivationTarget *icli_ax_activation_target_create(int pid, const char *identifier, char **report);
char *icli_ax_activation_target_hit_json(IcliAXActivationTarget *target, double x, double y);
int icli_ax_activation_target_perform(IcliAXActivationTarget *target);
void icli_ax_activation_target_free(IcliAXActivationTarget *target);
/// Puts the system-wide accessibility switches that AX queries turned on back
/// off. icli does this at exit; a long-running host calls it when it is done.
void icli_ax_restore_switches(void);

bool icli_hid_tap(double x, double y);
bool icli_hid_double_tap(double x, double y, double interval);
bool icli_hid_long_press(double x, double y, double seconds);
bool icli_hid_swipe(double x1, double y1, double x2, double y2, double seconds, int steps);
bool icli_hid_drag(const double *xs, const double *ys, int count, double hold, double seconds, int steps);
/// One finger through every point in UI points, evenly over `seconds`; it rests
/// on the last point for `rest` seconds before lifting, so a scroll view keeps no
/// velocity.
/// A swipe whose touch comes in from the screen's edge, as UIKit's edge recognizers require.
bool icli_hid_edge_swipe(double x1, double y1, double x2, double y2, double seconds, int steps);
bool icli_hid_stroke(const double *xs, const double *ys, int count, double seconds, double rest);
/// Two-finger pinch centred on (cx, cy) in UI points: the fingers sit on a line at
/// `angle` degrees and move from `from` to `to` points apart (to > from zooms in).
bool icli_hid_pinch(double cx, double cy, double from, double to, double angle, double seconds, int steps);
/// One digitizer event at 0…1 digitizer coordinates. Phase uses UITouchPhase
/// numbers, as vphoned's protocol does: 0 down, 1 move, 3 up.
bool icli_hid_touch(int phase, double nx, double ny);
bool icli_hid_key(uint16_t usage_page, uint16_t usage, bool down);
bool icli_hid_text(const char *text);
bool icli_hid_button(const char *name);
bool icli_wake(void);
#if TARGET_OS_TV
/// Asks PineBoard to dismiss the screen saver; harmless when none is up.
/// False when this system has no PineBoardServices to ask.
bool icli_deactivate_screen_saver(void);
#endif

/// What the icli_pointer_ calls return.
enum {
    ICLI_POINTER_OK = 0,
    /// The system does not have the private IOKit symbols.
    ICLI_POINTER_UNAVAILABLE = 1,
    /// IOHIDUserDeviceCreate refused to make the device.
    ICLI_POINTER_REFUSED = 2,
    /// The device exists but iOS has not put an event service over it yet.
    ICLI_POINTER_NOT_READY = 3,
    /// The report or the event could not be made or delivered.
    ICLI_POINTER_FAILED = 4,
};

/// Puts the virtual pointer at x, y: 0…1 from the top-left corner of the
/// interface as it is shown. Creates the pointing device on first use; it
/// lives as long as the process. `buttons` are the buttons held from then on,
/// bit 0 primary, bit 1 secondary, bit 2 middle; a negative value keeps the
/// ones held.
int icli_pointer_move(double x, double y, int buttons);
/// Presses or releases buttons where the pointer is.
int icli_pointer_buttons(int buttons);
/// One scroll event to the view under the pointer. `phase` is an
/// IOHIDEventPhaseBits value: 1 began, 2 changed, 4 ended, 8 cancelled. dx and
/// dy are interface points, with a browser wheel event's signs.
int icli_pointer_scroll(int phase, double dx, double dy);

bool icli_open_url(const char *url);
bool icli_open_url_in_app(const char *url, const char *bundle_id);
/// Live application processes reported by RunningBoard, as a JSON object.
char *icli_runningboard_apps_json(void);
bool icli_uninstall_app(const char *bundle_id);
bool icli_unregister_app(const char *path);
char *icli_app_handlers_json(const char *url_or_scheme);

double icli_battery_fraction(void);
int icli_battery_state(void);

double icli_brightness_get(void);
bool icli_brightness_set(double value);
/// 1 when auto-brightness is on, 0 when off, -1 when it cannot be read.
int icli_auto_brightness(void);
double icli_volume_get(const char *category);
bool icli_volume_set(double value, const char *category);

typedef struct {
    int degrees;
    int device_orientation;
    bool locked;
} IcliRotation;

/// SpringBoard's interface orientation in degrees, or -1 when it does not answer.
int icli_interface_degrees(void);
IcliRotation icli_rotation_get(void);
bool icli_rotation_set(int degrees);
bool icli_rotation_lock_set(bool locked);

char *icli_extract_ipa_json(const char *source, const char *destination);
char *icli_deb_read_json(const char *path, const char *destination);
char *icli_deb_unpack_json(const char *path, const char *prefix, const char **skip, int skip_count);
char *icli_capture_packets_json(
    const char *interface,
    const char *filter_text,
    double seconds,
    const char *output_path
);
char *icli_tar_entry_text(const char *path, const char *entry_name);
int icli_compare_debian_versions(const char *left, const char *right, int *comparison);

char *icli_apps_unregister_directory_json(const char *directory);
char *icli_app_registration_json(const char *path);
/// Every app LaunchServices lists, as an XML property list array of
/// {bundle_id, path, type, signer} with the path normalized. NULL when
/// LaunchServices cannot be asked.
char *icli_app_index_plist(void);
/// The record of the app registered as `bundle_id` at `path`, as an XML
/// property list: the bundle identifier, normalized path, and what a uicache
/// registration sets (versions, type, signer, containerization, data
/// container, environment, group identifiers, entitlements, settings bundle),
/// with its plug-ins under "plugins". An empty dictionary when no such app is
/// registered, NULL when LaunchServices cannot be asked.
char *icli_app_record_plist(const char *bundle_id, const char *path);
/// A bundle path in the form LaunchServices reports it: symlinks in every
/// existing component resolved, /private/var as /var.
char *icli_normalized_app_path(const char *path);

/// A MobileContainerManager container; kind is app, data, plugin, group or
/// system-group. Returns {"path", "existed"}, {"missing": true} when create is
/// false and there is none, or {"error"}.
char *icli_container_json(const char *kind, const char *identifier, bool create);
/// Deletes a container through containermanagerd and reads the result back:
/// {"destroyed": true, "path"}, {"missing": true} or {"error"}.
char *icli_container_destroy_json(const char *kind, const char *identifier);
/// Registers an app from a LaunchServices registration dictionary (XML plist).
bool icli_register_app_dictionary(const char *plist_xml);

bool icli_springboard_relaunch(void);

char *icli_account_set_password_json(const char *etc_directory, const char *user, const char *password);

bool icli_platform_binary(void);
int icli_reboot(bool userspace);
char *icli_app_network_policy_json(const char *bundle_id, bool repair);
char *icli_system_apps_visible_json(int desired);
char *icli_bootlogo_render_json(
    const char *mark_path,
    const char *output_path,
    bool dark,
    int width,
    int height,
    double mark_points
);
char *icli_active_audio_json(void);
char *icli_audio_button_json(const char *button);

/// amfid's Developer Mode reply ({success, status, armed, writable}); arm
/// asks amfid to turn Developer Mode on after the next restart.
char *icli_amfi_developer_mode_json(bool arm);
/// powerd's Low Power Mode: 1 on, 0 off, -1 when the service is unavailable.
int icli_low_power_mode_get(void);
/// 0 on acceptance; -1 if unavailable, -2 on timeout, -3 on rejection.
int icli_low_power_mode_set(bool enabled);

/// Control Center toggles. Getters return 1 on, 0 off, -1 when the service is
/// unavailable. Setters return 0 once the new state reads back, -1 when the
/// service is unavailable, -2 when the state did not change in time and -3
/// when the service refused the change.
int icli_cc_airplane_get(void);
int icli_cc_airplane_set(bool enabled);
int icli_cc_wifi_get(void);
int icli_cc_wifi_set(bool enabled);
int icli_cc_bluetooth_get(void);
int icli_cc_bluetooth_set(bool enabled);
int icli_cc_cellular_get(void);
int icli_cc_cellular_set(bool enabled);
/// Netrb's raw global service state: 1023 on, 1022 off, lower when the
/// hotspot is unavailable; -1 when Netrb is missing.
int icli_cc_hotspot_state(void);
int icli_cc_hotspot_get(void);
int icli_cc_hotspot_set(bool enabled);
/// AirDrop receiving: 0 off, 1 contacts only, 2 everyone; -1 unavailable.
int icli_cc_airdrop_get(void);
bool icli_cc_airdrop_time_limited(void);
int icli_cc_airdrop_set(int mode);
/// Flashlight level 0–1, or -1 when the device has no flashlight service.
double icli_cc_flashlight_level(void);
bool icli_cc_flashlight_overheated(void);
int icli_cc_flashlight_set(double level);
/// {active, mode_id, mode, modes: [{id, name}]} or {error}.
char *icli_cc_focus_json(void);
/// Turns the Focus `mode` on, or every active Focus off when mode is NULL.
/// On -3, *message holds a malloc'd reason.
int icli_cc_focus_set(const char *mode, char **message);
/// {mirroring, device} or {error}.
char *icli_cc_mirroring_json(void);
/// Audio/Video outputs: {routes: [{name, uid, selected}], selected_uid}.
/// Selection succeeds only after a native read confirms the exact UID. Errors
/// carry {error, message} and the last route snapshot when available.
char *icli_cc_audio_list_json(void);
char *icli_cc_audio_select_json(const char *routeUID, double timeout);
/// MobileKeyBag's lock state and attempt counters as JSON: lock_state, and
/// when the keybag reports them failed_attempts, backoff_seconds,
/// permanently_blocked, should_wipe and recovery_countdown.
char *icli_keybag_info_json(void);
/// MKBUnlockDevice with the passcode bytes; 0 unlocks. available is false when
/// MobileKeyBag does not offer the call, and nothing was attempted.
int icli_keybag_unlock(const uint8_t *passcode, size_t length, bool *available);
/// Full unlock using SBLockScreenManager inside SpringBoard, without an
/// installed tweak, subprocess, or saved passcode. Root only. JSON reports
/// attempted, confirmed, ready and detail; checkOnly does not execute code.
/// Must run between signals_begin/end on the same thread. Keep that scope
/// through ledger persistence and passcode-buffer wiping, including errors.
char *icli_full_unlock_json(const uint8_t *passcode, size_t length, bool checkOnly);
bool icli_full_unlock_signals_begin(void);
bool icli_full_unlock_signals_end(void);
/// Load and start the probe agent in an existing app without relaunching it.
/// Verifies the task's executable before using the owned-thread transport.
char *icli_probe_attach_json(int pid, const char *executable, const char *dylib, const char *socketPath);
/// timed's automatic time zone: 1 on, 0 off, -1 when CoreTime does not offer
/// it, -2 when timed does not answer within 3 seconds.
int icli_automatic_time_zone_get(void);
/// Sends timed the setting without waiting; -1 when CoreTime does not offer it.
int icli_automatic_time_zone_set(bool enabled);
/// Asks tzlinkd to point /var/db/timezone/localtime at the Olson name. Returns
/// tzlinkd's errno (0 on success), -1 without tzlink, -2 after 5 silent seconds.
int icli_time_zone_link(const char *name);
/// Posts a Darwin notification through notifyd, first setting its state when
/// set_state is true. delivered reports whether this process's own listener
/// received the post within a second. Returns a notify(3) status; 0 is success.
uint32_t icli_notify_post(const char *name, bool set_state, uint64_t state, bool *delivered);
/// A Darwin notification's current state. Returns a notify(3) status.
uint32_t icli_notify_get_state(const char *name, uint64_t *state);
/// Location simulation through locationd; the location outlives the process.
char *icli_location_simulate_json(
    double latitude,
    double longitude,
    double altitude,
    double horizontal_accuracy,
    double vertical_accuracy,
    double speed,
    double course
);
char *icli_location_clear_json(void);
/// Waits up to `timeout` seconds for a fresh fix (at the target coordinate when `match`).
char *icli_location_read_json(double timeout, bool match, double latitude, double longitude);

/// Listens for `seconds` and answers the matching entries, at most
/// `max_lines` of them. Every filter applies before the cap; NULL or empty
/// strings and a pid of 0 or less match anything.
char *icli_syslog_json(
    double seconds,
    const char *process,
    int pid,
    const char *subsystem,
    const char *category,
    const char *message_contains,
    const char *level,
    int max_lines
);

/// Why a syslog stream ended.
typedef enum {
    IcliSyslogEndCancelled = 0,
    /// Its duration passed.
    IcliSyslogEndDuration = 1,
    /// It delivered its maximum number of entries.
    IcliSyslogEndEntryLimit = 2,
    /// The entry handler answered false.
    IcliSyslogEndStopped = 3,
    /// The system ended the stream: logd went away or refused this process.
    IcliSyslogEndInterrupted = 4,
} IcliSyslogEnd;

/// One matching entry. The strings are never NULL, are valid for the call
/// only (retain one to keep it), hold any NUL the message had, and are
/// well-formed: a lone UTF-16 surrogate becomes U+FFFD. `date` is seconds
/// since 1970, or NaN when the event has none. Answer false to stop.
typedef bool (^IcliSyslogEntryHandler)(
    CFStringRef process,
    int pid,
    CFStringRef subsystem,
    CFStringRef category,
    CFStringRef level,
    CFStringRef message,
    double date
);
typedef void (^IcliSyslogEndHandler)(IcliSyslogEnd reason, long delivered);

/// Starts one continuous listen with the filters of icli_syslog_json. It ends
/// after `seconds` when that is above zero, after `max_entries` entries when
/// that is above zero, when `entry` answers false, when the system ends it, or
/// at icli_syslog_stream_cancel. Answers NULL when the stream is unavailable
/// or `level` is unknown. The handle stays valid until
/// icli_syslog_stream_release, which cancels first.
void *icli_syslog_stream_open(
    const char *process,
    int pid,
    const char *subsystem,
    const char *category,
    const char *message_contains,
    const char *level,
    double seconds,
    long max_entries,
    IcliSyslogEntryHandler entry,
    IcliSyslogEndHandler end
);
/// No entry is delivered once this returns. Idempotent.
void icli_syslog_stream_cancel(void *stream);
void icli_syslog_stream_release(void *stream);
char *icli_ioreg_json(const char *plane);

#ifdef __cplusplus
}
#endif
