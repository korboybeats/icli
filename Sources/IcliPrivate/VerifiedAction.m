#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

char *icli_ui_process_identity_json(int pid) {
    struct kinfo_proc info = {0};
    size_t size = sizeof(info);
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    char path[4096] = {0};
    if (pid <= 0 || sysctl(mib, 4, &info, &size, NULL, 0) || size != sizeof(info)
        || info.kp_proc.p_pid != pid || proc_pidpath(pid, path, sizeof(path)) <= 0)
        return icli_json(@{@"error": @"process identity unavailable"});
    return icli_json(@{@"pid": @(pid), @"executable": @(path),
                      @"started_seconds": @(info.kp_proc.p_starttime.tv_sec),
                      @"started_microseconds": @(info.kp_proc.p_starttime.tv_usec)});
}
