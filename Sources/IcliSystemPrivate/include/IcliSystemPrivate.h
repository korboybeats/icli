#pragma once

#include <stdbool.h>
#include <stdint.h>

// The read-only half of the private bridge: bootstrap paths, processes, boot
// facts, launchd's bootstrap pipe, LaunchServices registrations and jetsam.
// Foundation and libxpc only; nothing here links UIKit, IOKit or Vision.

#ifdef __cplusplus
extern "C" {
#endif

void icli_string_free(char *s);

char *icli_bootstrap_json(void);
char *icli_jbroot_path(const char *path);
char *icli_rootfs_path(const char *path);
bool icli_roothide_root_name(const char *name);
char *icli_roothide_root_in(const char *parent);
char *icli_processes_json(void);
/// The pid of a process whose kernel name (p_comm) is `name`, -1 when none runs.
int icli_process_pid_named(const char *name);
char *icli_boot_info_json(void);
char *icli_file_md5(const char *path);

char *icli_launchd_load_json(const char **paths, int count, bool load, bool override);
char *icli_launchd_enable_json(const char *label, bool enable);
char *icli_launchd_service_json(const char *label);
char *icli_launchd_services_json(void);
char *icli_launchd_disabled_json(void);
char *icli_launchd_start_json(const char *label);
char *icli_launchd_stop_json(const char *label);
char *icli_launchd_remove_json(const char *label);
char *icli_launchd_kickstart_json(const char *label, bool kill);
char *icli_launchd_kill_json(const char *label, int signal);
char *icli_launchd_print_json(const char *label);
char *icli_launchd_getenv_json(const char *key);
char *icli_launchd_setenv_json(const char *key, const char *value, bool unset);
int icli_launchd_stop(const char *label);
const char *icli_launchd_strerror(int error);

char *icli_apps_json(void);
// Quicker than listing every app: true only when LaunchServices knows it.
bool icli_app_is_installed(const char *bundle_id);
/// The app's display name from its LaunchServices record (malloc'd), or NULL.
char *icli_app_name(const char *bundle_id);
char *icli_jetsam_json(void);

#ifdef __OBJC__
@class NSDictionary;
@class NSString;

// LaunchServices proxy access, shared with IcliPrivate's registration code.
// Not part of the Swift API; the Swift layer reads icli_apps_json instead.
id icli_ls_workspace(void);
id icli_ls_value(id proxy, NSString *key);
NSString *icli_ls_string(id value);
NSDictionary *icli_ls_app_dictionary(id proxy);
#endif

#ifdef __cplusplus
}
#endif
