#import "IcliLaunchPrivate.h"
#import "IcliSystemPrivate.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>

@interface NSObject (IcliLaunchLS)
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

// The system shell: SpringBoard, or PineBoard on tvOS.
#if TARGET_OS_TV
static NSString *const kSystemShell = @"com.apple.PineBoard";
#else
static NSString *const kSystemShell = @"com.apple.springboard";
#endif

static mach_port_t (*pSBSSpringBoardServerPort)(void);
static void (*pSBGetScreenLockStatus)(mach_port_t, BOOL *, BOOL *);
// The Copy rule: the identifier comes back retained.
static NSString *(*pSBSCopyFrontmostApplicationDisplayIdentifier)(void) NS_RETURNS_RETAINED;
static int (*pSBSLaunchApplicationWithIdentifierAndLaunchOptions)(NSString *, NSDictionary *, NSDictionary *, BOOL);

static void icli_launch_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sbs = dlopen(
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            RTLD_NOW
        );
        if (!sbs) return;
#define SYM(p, name) p = (typeof(p))dlsym(sbs, name)
        SYM(pSBSSpringBoardServerPort, "SBSSpringBoardServerPort");
        SYM(pSBGetScreenLockStatus, "SBGetScreenLockStatus");
        SYM(pSBSCopyFrontmostApplicationDisplayIdentifier, "SBSCopyFrontmostApplicationDisplayIdentifier");
        SYM(pSBSLaunchApplicationWithIdentifierAndLaunchOptions, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
#undef SYM
    });
}

static char *launchJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : strdup("{}");
}

static bool notifyFlag(const char *name) {
    int token = 0;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
        return false;
    }
    uint64_t state = 0;
    notify_get_state(token, &state);
    notify_cancel(token);
    return state != 0;
}

// SBSGetScreenLockStatus reads unlocked on a locked iOS 26 device, and
// MobileKeyBag answers nothing useful without a passcode, so the lock comes
// from SpringBoard's notification and SBGetScreenLockStatus together.
IcliLockStatus icli_lock_status(void) {
    icli_launch_init();
    IcliLockStatus st = {
        .locked = notifyFlag("com.apple.springboard.lockstate"),
        .screen_off = notifyFlag("com.apple.springboard.hasBlankedScreen"),
    };
    if (pSBSSpringBoardServerPort && pSBGetScreenLockStatus) {
        BOOL locked = NO;
        BOOL passcode = NO;
        pSBGetScreenLockStatus(pSBSSpringBoardServerPort(), &locked, &passcode);
        st.locked = st.locked || locked;
        st.passcode_enabled = passcode;
    }
    return st;
}

#if TARGET_OS_TV
// FrontBoard's own open request, which PineBoard serves: tvOS runs no
// SpringBoard to answer SpringBoardServices. A refusal says why, such as
// Setup Assistant still running or an app PineBoard has not enabled; it lands
// in `reason`.
static BOOL frontBoardOpen(NSString *bundleID, NSString **reason) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL sharedService = NSSelectorFromString(@"sharedService");
    SEL open = NSSelectorFromString(@"openApplication:options:withResult:");
    id service = [serviceClass respondsToSelector:sharedService]
        ? ((id (*)(id, SEL))objc_msgSend)(serviceClass, sharedService)
        : nil;
    if (![service respondsToSelector:open]) return NO;
    __block NSError *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, open, bundleID, @{}, ^(NSError *error) {
        failure = error;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        *reason = @"FrontBoard did not answer the open request";
        return NO;
    }
    if (failure) *reason = failure.localizedFailureReason ?: failure.localizedDescription;
    return failure == nil;
}
#endif

IcliLaunchResult icli_launch_app_with_options(
    const char *bundle_id, const char *arguments_json, const char *environment_json, char **reason) {
    icli_launch_init();
    if (reason) *reason = NULL;
    NSString *refusal = @"FrontBoard's open service is unavailable";
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
        Class serviceClass = NSClassFromString(@"FBSOpenApplicationService");
        Class optionsClass = NSClassFromString(@"FBSOpenApplicationOptions");
        SEL shared = NSSelectorFromString(@"serviceWithDefaultShellEndpoint");
        SEL make = NSSelectorFromString(@"optionsWithDictionary:");
        SEL open = NSSelectorFromString(@"openApplication:withOptions:completion:");
        NSData *argumentData = [NSData dataWithBytes:arguments_json length:strlen(arguments_json)];
        NSData *environmentData = [NSData dataWithBytes:environment_json length:strlen(environment_json)];
        id arguments = [NSJSONSerialization JSONObjectWithData:argumentData options:0 error:nil];
        id environment = [NSJSONSerialization JSONObjectWithData:environmentData options:0 error:nil];
        id service = [serviceClass respondsToSelector:shared]
            ? ((id (*)(id, SEL))objc_msgSend)(serviceClass, shared) : nil;
        if ([service respondsToSelector:open] && [optionsClass respondsToSelector:make] && arguments && environment) {
            id options = ((id (*)(id, SEL, id))objc_msgSend)(optionsClass, make, @{
                @"__ActivateSuspended": @NO,
                @"__DebugOptions": @{@"__Arguments": arguments, @"__Environment": environment},
            });
            __block NSError *failure = nil;
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            void (^completion)(id, NSError *) = ^(id process, NSError *error) {
                failure = error;
                dispatch_semaphore_signal(done);
            };
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, open, @(bundle_id), options, completion);
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
                refusal = @"FrontBoard did not answer the open request";
            } else if (!failure) {
                return IcliLaunchAccepted;
            } else {
                NSError *cause = failure.userInfo[NSUnderlyingErrorKey];
                refusal = cause.localizedFailureReason ?: cause.localizedDescription
                    ?: failure.localizedFailureReason ?: failure.localizedDescription;
            }
        }
        if (reason && refusal.length) *reason = strdup(refusal.UTF8String);
    }
    IcliLockStatus lock = icli_lock_status();
    return lock.locked || lock.screen_off ? IcliLaunchLocked : IcliLaunchRefused;
}

// SpringBoardServices launches for a caller with
// com.apple.springboard.launchapplications. Any other caller falls back to
// LaunchServices, which needs no entitlement and answers NO while the device
// is locked; that answer is the result, not something to wait out. On tvOS
// FrontBoard comes last, and its refusal carries PineBoard's reason.
IcliLaunchResult icli_launch_app(const char *bundle_id, char **reason) {
    icli_launch_init();
    if (reason) *reason = NULL;
    @autoreleasepool {
        NSString *bid = [NSString stringWithUTF8String:bundle_id];
        if (pSBSLaunchApplicationWithIdentifierAndLaunchOptions &&
            pSBSLaunchApplicationWithIdentifierAndLaunchOptions(bid, nil, nil, NO) == 0) {
            return IcliLaunchAccepted;
        }
        id ws = icli_ls_workspace();
        if ([ws respondsToSelector:@selector(openApplicationWithBundleID:)] &&
            [ws openApplicationWithBundleID:bid]) {
            return IcliLaunchAccepted;
        }
#if TARGET_OS_TV
        NSString *refusal = nil;
        if (frontBoardOpen(bid, &refusal)) return IcliLaunchAccepted;
        if (reason && refusal.length) *reason = strdup(refusal.UTF8String);
#endif
    }
    IcliLockStatus lock = icli_lock_status();
    return lock.locked || lock.screen_off ? IcliLaunchLocked : IcliLaunchRefused;
}

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static NSString *(*pNSStringFromRBSRole)(uint8_t);
static Class handleClass;
static Class identifierClass;
static SEL roleSelector;
static SEL identifierSelector;
static SEL handleSelector;

// Separate from icli_launch_init so icli_lock_status never loads RunningBoard.
static void icli_running_board_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = dlopen(
            "/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices",
            RTLD_NOW
        );
        if (framework) pNSStringFromRBSRole = dlsym(framework, "NSStringFromRBSRole");
        handleClass = NSClassFromString(@"RBSProcessHandle");
        identifierClass = NSClassFromString(@"RBSProcessIdentifier");
        roleSelector = NSSelectorFromString(@"cpuRole");
        identifierSelector = NSSelectorFromString(@"identifierWithPid:");
        handleSelector = NSSelectorFromString(@"handleForIdentifier:error:");
    });
}

// Whether the app whose executable is at `path` is tagged hidden: a view
// service SpringBoard hosts in its own interface, such as the Dock's folder
// stacks on iPad or a widget, rather than an app a user opens. Such a service
// holds the same FrontBoard focal assertion as the app on screen while it is
// shown, on the Home Screen too.
static BOOL hiddenApplication(const char *path) {
    static NSMutableDictionary<NSString *, NSNumber *> *cache;
    const char *app = path ? strstr(path, ".app/") : NULL;
    if (!app) return NO;
    NSString *bundle = [[NSString alloc] initWithBytes:path length:(NSUInteger)(app + 4 - path) encoding:NSUTF8StringEncoding];
    if (!bundle) return NO;
    @synchronized([NSProcessInfo class]) {
        if (!cache) cache = [NSMutableDictionary dictionary];
        NSNumber *hidden = cache[bundle];
        if (!hidden) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
            id tags = info[@"SBAppTags"];
            hidden = @([tags isKindOfClass:[NSArray class]] && [tags containsObject:@"hidden"]);
            cache[bundle] = hidden;
        }
        return hidden.boolValue;
    }
}

// One RunningBoard request for every application's state: 0.7 ms on iOS 17.1.1
// against 4.6 ms for one request per app process (52 of them) in the scan
// below. Its states carry the same assertions. It answers only when the scan's
// first two rules would: one app holding a focal assertion, or one of several
// holding ForegroundFocal. Anything else (no focal app, roles, tvOS) is left to
// the scan, which also explains a missing answer.
static NSString *bulkFocalApplication(NSMutableDictionary<NSString *, NSNumber *> *pids) {
#if TARGET_OS_TV
    return nil;
#else
    static id connection, predicate, descriptor;
    static SEL statesSelector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class connectionClass = NSClassFromString(@"RBSConnection");
        Class predicateClass = NSClassFromString(@"RBSProcessPredicate");
        Class descriptorClass = NSClassFromString(@"RBSProcessStateDescriptor");
        SEL shared = NSSelectorFromString(@"sharedInstance");
        SEL applications = NSSelectorFromString(@"predicateMatchingProcessTypeApplication");
        SEL make = NSSelectorFromString(@"descriptor");
        SEL setValues = NSSelectorFromString(@"setValues:");
        statesSelector = NSSelectorFromString(@"statesForPredicate:withDescriptor:error:");
        if (![connectionClass respondsToSelector:shared] || ![predicateClass respondsToSelector:applications] ||
            ![descriptorClass respondsToSelector:make]) return;
        id shell = ((id (*)(id, SEL))objc_msgSend)(connectionClass, shared);
        id made = ((id (*)(id, SEL))objc_msgSend)(descriptorClass, make);
        if (![shell respondsToSelector:statesSelector] || ![made respondsToSelector:setValues]) return;
        // Task state, legacy and primitive assertions: the scan reads assertions.
        ((void (*)(id, SEL, unsigned long))objc_msgSend)(made, setValues, 0x1 | 0x8 | 0x10);
        predicate = ((id (*)(id, SEL))objc_msgSend)(predicateClass, applications);
        descriptor = made;
        connection = predicate ? shell : nil;
    });
    if (!connection) return nil;
    NSString *answer = nil;
    @autoreleasepool {
    @try {
        NSError *error = nil;
        NSArray *states = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(
            connection, statesSelector, predicate, descriptor, &error);
        if (![states isKindOfClass:[NSArray class]]) return nil;
        NSMutableSet<NSString *> *focalIDs = [NSMutableSet set];
        NSMutableSet<NSString *> *foregroundFocalIDs = [NSMutableSet set];
        for (id state in states) {
            id handle = [state valueForKey:@"process"];
            NSString *bundleID = [[handle valueForKey:@"identity"] valueForKey:@"embeddedApplicationIdentifier"];
            if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length ||
                [bundleID containsString:@"WidgetRenderer"]) {
                continue;
            }
            BOOL focal = NO, foregroundFocal = NO;
            for (id assertion in [state valueForKey:@"assertions"]) {
                NSString *domain = [assertion valueForKey:@"domain"];
                if ([domain isKindOfClass:[NSString class]] &&
                    ([domain containsString:@"Workspace-ForegroundFocal"] ||
                     [domain containsString:@"com.apple.frontboard:SuspendableRole-UIFocal"])) {
                    focal = YES;
                    foregroundFocal = foregroundFocal || [domain containsString:@"JetsamPriority-ForegroundFocal"];
                }
            }
            if (!focal) continue;
            pid_t pid = [[handle valueForKey:@"pid"] intValue];
            char path[4096] = {0};
            // The scan's filters: app bundles only, hidden view services apart.
            if (proc_pidpath(pid, path, sizeof(path)) > 0) {
                char *app = strstr(path, ".app/");
                if (!app || strchr(app + 5, '/') || strstr(path, "WidgetRenderer") || hiddenApplication(path)) continue;
            }
            [focalIDs addObject:bundleID];
            if (foregroundFocal) [foregroundFocalIDs addObject:bundleID];
            if (!pids[bundleID]) pids[bundleID] = @(pid);
        }
        if (focalIDs.count == 1) answer = focalIDs.anyObject;
        else if (focalIDs.count > 1 && foregroundFocalIDs.count == 1) answer = foregroundFocalIDs.anyObject;
    } @catch (NSException *) {
    }
    }
    return answer;
#endif
}

// The FrontBoard focal assertion identifies the app receiving input. The
// older SpringBoard query may be stale even while another app is on screen.
// Hidden view services hold that assertion too and are left out. When several
// apps hold it, as with windows side by side on iPad in iOS 27, the one
// FrontBoard also gives the ForegroundFocal jetsam priority has the focus.
// Setup Assistant drops its launch assertion and never takes a workspace focal
// one, yet RunningBoard keeps its role at UserInteractiveFocal, so the role
// decides when no assertion does.
//
// Without an answer, `why` says what was missing, so a host whose process
// context differs from the CLI's can tell which step failed.
static NSString *runningBoardFocalApplication(NSMutableDictionary *why) {
    icli_running_board_init();
    if (![identifierClass respondsToSelector:identifierSelector] || ![handleClass respondsToSelector:handleSelector]) {
        why[@"reason"] = @"runningboard_unavailable";
        return nil;
    }
    NSMutableDictionary<NSString *, NSNumber *> *bulkPIDs = [NSMutableDictionary dictionary];
    NSString *bulk = bulkFocalApplication(bulkPIDs);
    if (bulk) {
        why[@"pids"] = bulkPIDs;
        return bulk;
    }
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0) {
        why[@"reason"] = @"process_list_failed";
        return nil;
    }
    length += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = calloc(1, length);
    if (!processes || sysctl(mib, 3, processes, &length, NULL, 0) != 0) {
        free(processes);
        why[@"reason"] = @"process_list_failed";
        return nil;
    }
    long candidates = 0, handles = 0, states = 0, pathlessCount = 0;
    NSString *handleError = nil;
    NSMutableSet<NSString *> *focalIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *foregroundFocalIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *hiddenFocalIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *focalRoleIDs = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *focalPIDs = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < length / sizeof(struct kinfo_proc); i++) {
        pid_t pid = processes[i].kp_proc.p_pid;
        char path[4096] = {0};
        if (pid <= 0) continue;
        // An app whose bundle was replaced while it ran has no path any more;
        // its RunningBoard identity decides below.
        bool pathless = proc_pidpath(pid, path, sizeof(path)) <= 0;
        // Only app bundles can be the frontmost application.
        char *app = pathless ? NULL : strstr(path, ".app/");
        if (!pathless && (!app || strchr(app + 5, '/') || strstr(path, "WidgetRenderer"))) continue;
        candidates++;
        if (pathless) pathlessCount++;
        // Callers poll this, launchApp ten times a second, and a host thread
        // may have no pool of its own to drain the RunningBoard objects.
        @autoreleasepool {
        @try {
            id identifier = ((id (*)(id, SEL, int))objc_msgSend)(identifierClass, identifierSelector, pid);
            NSError *error = nil;
            id handle = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(handleClass, handleSelector, identifier, &error);
            if (!handle) {
                if (!handleError) handleError = error.description ?: @"no handle";
                continue;
            }
            handles++;
            id identity = [handle valueForKey:@"identity"];
            SEL isApplication = NSSelectorFromString(@"isApplication");
            if (pathless && !([identity respondsToSelector:isApplication] &&
                              ((BOOL (*)(id, SEL))objc_msgSend)(identity, isApplication))) {
                continue;
            }
            NSString *bundleID = [identity valueForKey:@"embeddedApplicationIdentifier"];
            if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length ||
                [bundleID containsString:@"WidgetRenderer"]) {
                continue;
            }
            id state = [handle valueForKey:@"currentState"];
            if (state) states++;
            if (pNSStringFromRBSRole && [state respondsToSelector:roleSelector]) {
                uint8_t role = ((uint8_t (*)(id, SEL))objc_msgSend)(state, roleSelector);
                if ([pNSStringFromRBSRole(role) isEqualToString:@"UserInteractiveFocal"]) {
                    [focalRoleIDs addObject:bundleID];
                }
            }
            BOOL focal = NO, foregroundFocal = NO;
            for (id assertion in [state valueForKey:@"assertions"]) {
                NSString *domain = [assertion valueForKey:@"domain"];
                if ([domain isKindOfClass:[NSString class]] &&
                    ([domain containsString:@"Workspace-ForegroundFocal"] ||
                     [domain containsString:@"com.apple.frontboard:SuspendableRole-UIFocal"])) {
                    focal = YES;
                    foregroundFocal = foregroundFocal || [domain containsString:@"JetsamPriority-ForegroundFocal"];
                }
            }
            if (focal && !focalPIDs[bundleID]) focalPIDs[bundleID] = @(pid);
            if (focal && !pathless && hiddenApplication(path)) {
                [hiddenFocalIDs addObject:bundleID];
            } else if (focal) {
                [focalIDs addObject:bundleID];
                if (foregroundFocal) [foregroundFocalIDs addObject:bundleID];
            }
        } @catch (NSException *) {
        }
        }
    }
    free(processes);
    why[@"pids"] = focalPIDs;
#if TARGET_OS_TV
    // The screen saver covers whatever stays focal beneath it, the Home
    // screen included, so while it runs it is the one on screen.
    if ([hiddenFocalIDs containsObject:@"com.apple.IdleScreen"]) return @"com.apple.IdleScreen";
#endif
    if (focalIDs.count == 1) return focalIDs.anyObject;
    if (focalIDs.count > 1 && foregroundFocalIDs.count == 1) return foregroundFocalIDs.anyObject;
#if TARGET_OS_TV
    // tvOS tags its Home screen (HeadBoard), Setup, the screen saver and its
    // view services hidden alike, so a hidden app alone is the one on screen.
    if (!focalIDs.count && hiddenFocalIDs.count == 1) return hiddenFocalIDs.anyObject;
#endif
    [focalRoleIDs minusSet:hiddenFocalIDs];
    if (!focalIDs.count && focalRoleIDs.count == 1) return focalRoleIDs.anyObject;
    why[@"reason"] = focalIDs.count ? @"several_focal_apps"
        : focalRoleIDs.count ? @"several_focal_roles"
        : !handles ? @"no_process_handles"
        : !states ? @"no_process_states"
        : @"no_focal_app";
    why[@"app_processes"] = @(candidates);
    why[@"pathless_processes"] = @(pathlessCount);
    why[@"handles"] = @(handles);
    why[@"states"] = @(states);
    if (handleError) why[@"handle_error"] = handleError;
    NSArray *sorted = [(focalIDs.count ? focalIDs : focalRoleIDs).allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (sorted.count) why[@"focal"] = sorted;
    if (hiddenFocalIDs.count) why[@"hidden_focal"] = [hiddenFocalIDs.allObjects sortedArrayUsingSelector:@selector(compare:)];
    return nil;
}

char *icli_frontmost_app_json(void) {
    icli_launch_init();
    NSMutableDictionary *why = [NSMutableDictionary dictionary];
    NSString *bid = runningBoardFocalApplication(why);
    NSDictionary *pids = why[@"pids"];
    [why removeObjectForKey:@"pids"];
    NSArray *hidden = why[@"hidden_focal"];
    if (hidden.count == 1 && pids[hidden.firstObject]) why[@"hidden_focal_pid"] = pids[hidden.firstObject];
    if (bid.length) {
        NSMutableDictionary *found = [@{@"bundle_id": bid, @"verified": @YES, @"source": @"runningboard"} mutableCopy];
        if (pids[bid]) found[@"pid"] = pids[bid];
        return launchJSON(found);
    }
    if (pSBSCopyFrontmostApplicationDisplayIdentifier)
        bid = pSBSCopyFrontmostApplicationDisplayIdentifier();
    return launchJSON(@{
        @"bundle_id": bid.length ? bid : kSystemShell,
        @"verified": @NO,
        @"source": bid.length ? @"springboard_query" : @"unavailable",
        @"runningboard": why,
    });
}

