#import <Foundation/Foundation.h>

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <math.h>
#import <pthread.h>
#import <signal.h>
#import <stdint.h>
#import <stdlib.h>
#import <sys/socket.h>
#import <sys/wait.h>
#import <unistd.h>

#import "FUProtocol.h"

#ifndef FU_EXPECTED_AGENT_BUILD_ID
#define FU_EXPECTED_AGENT_BUILD_ID @""
#endif

static NSLock *FUStateLock;
static NSLock *FUWriteLock;
static NSMutableDictionary<NSNumber *, NSDictionary *> *FUAgents;
static NSMutableDictionary<NSString *, NSDictionary *> *FUPending;
static NSMutableArray<NSDictionary *> *FUTargetHistory;
static unsigned long long FUConnectionSequence;
static unsigned long long FUTargetHistoryEventSequence;
static unsigned long long FUDroppedTargetHistoryEvents;
static unsigned long long FUDaemonStartedAtUnixMS;
static NSDictionary *FUDaemonMemoryPolicy;
static const NSUInteger FUTargetHistoryCapacity = 128;

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);

typedef struct {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} FUMemorystatusMemlimitProperties;

static const uint32_t FUMemorystatusCommandSetJetsamHighWaterMark = 5;
static const uint32_t FUMemorystatusCommandGetMemlimitProperties = 8;
static const int32_t FUDaemonMemoryLimitMB = 128;

static NSDictionary *FUConfigureDaemonMemoryPolicy(void) {
    errno = 0;
    int setRC = memorystatus_control(
        FUMemorystatusCommandSetJetsamHighWaterMark,
        getpid(),
        (uint32_t)FUDaemonMemoryLimitMB,
        NULL,
        0);
    int setErrno = errno;

    FUMemorystatusMemlimitProperties properties = {0};
    errno = 0;
    int getRC = memorystatus_control(
        FUMemorystatusCommandGetMemlimitProperties,
        getpid(),
        0,
        &properties,
        sizeof(properties));
    int getErrno = errno;

    BOOL verified = setRC == 0
        && getRC == 0
        && properties.memlimit_active >= FUDaemonMemoryLimitMB
        && properties.memlimit_inactive >= FUDaemonMemoryLimitMB;

    return @{
        @"requested_mb": @(FUDaemonMemoryLimitMB),
        @"set_rc": @(setRC),
        @"set_errno": @(setErrno),
        @"get_rc": @(getRC),
        @"get_errno": @(getErrno),
        @"active_mb": @(properties.memlimit_active),
        @"active_attr": @(properties.memlimit_active_attr),
        @"inactive_mb": @(properties.memlimit_inactive),
        @"inactive_attr": @(properties.memlimit_inactive_attr),
        @"verified": @(verified),
    };
}

static NSString *FUICLIPath(void) {
    NSArray<NSString *> *candidates = @[
        @"/var/jb/usr/bin/icli",
        @"/usr/bin/icli",
    ];
    for (NSString *candidate in candidates) {
        if (access(candidate.fileSystemRepresentation, X_OK) == 0) {
            return candidate;
        }
    }
    return nil;
}

static NSData *FUReadAllFromFD(int fd) {
    if (lseek(fd, 0, SEEK_SET) < 0) {
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[8192];
    while (YES) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count == 0) {
            break;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return nil;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    return data;
}

static NSString *FUConciseText(NSData *data) {
    if (!data.length) {
        return @"";
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length > 1000) {
        text = [[text substringToIndex:1000] stringByAppendingString:@"…"];
    }
    return text;
}

static id FURunICLI(NSArray<NSString *> *arguments, NSDictionary **errorInfo) {
    NSString *path = FUICLIPath();
    if (!path) {
        if (errorInfo) {
            *errorInfo = FUErrorInfo(@"dependency_unavailable", @"iCLI is not installed or executable. Install iCLI to use broker operations that require device control.");
        }
        return nil;
    }

    char stdoutTemplate[] = "/tmp/flexultra-icli-out.XXXXXX";
    char stderrTemplate[] = "/tmp/flexultra-icli-err.XXXXXX";
    int stdoutFD = mkstemp(stdoutTemplate);
    int stderrFD = mkstemp(stderrTemplate);
    if (stdoutFD < 0 || stderrFD < 0) {
        if (stdoutFD >= 0) close(stdoutFD);
        if (stderrFD >= 0) close(stderrFD);
        if (stdoutFD >= 0) unlink(stdoutTemplate);
        if (stderrFD >= 0) unlink(stderrTemplate);
        if (errorInfo) {
            *errorInfo = FUErrorInfo(@"dependency_failed", @"Could not create temporary capture files for iCLI.");
        }
        return nil;
    }
    unlink(stdoutTemplate);
    unlink(stderrTemplate);

    NSMutableArray<NSString *> *argvStrings = [NSMutableArray arrayWithObject:path];
    [argvStrings addObjectsFromArray:arguments];
    NSUInteger argc = argvStrings.count;
    char **argv = calloc(argc + 1, sizeof(char *));
    if (!argv) {
        close(stdoutFD);
        close(stderrFD);
        if (errorInfo) {
            *errorInfo = FUErrorInfo(@"dependency_failed", @"Could not allocate arguments for iCLI.");
        }
        return nil;
    }
    for (NSUInteger i = 0; i < argc; i++) {
        argv[i] = (char *)[argvStrings[i] UTF8String];
    }

    pid_t pid = fork();
    if (pid == 0) {
        dup2(stdoutFD, STDOUT_FILENO);
        dup2(stderrFD, STDERR_FILENO);
        close(stdoutFD);
        close(stderrFD);
        setenv("_MSSafeMode", "1", 1);
        execv(path.fileSystemRepresentation, argv);
        dprintf(STDERR_FILENO, "execv failed: %s\n", strerror(errno));
        _exit(127);
    }
    free(argv);

    if (pid < 0) {
        close(stdoutFD);
        close(stderrFD);
        if (errorInfo) {
            *errorInfo = FUErrorInfo(@"dependency_failed", [NSString stringWithFormat:@"Could not start iCLI: %s", strerror(errno)]);
        }
        return nil;
    }

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR) {
            continue;
        }
        status = -1;
        break;
    }

    NSData *stdoutData = FUReadAllFromFD(stdoutFD) ?: [NSData data];
    NSData *stderrData = FUReadAllFromFD(stderrFD) ?: [NSData data];
    close(stdoutFD);
    close(stderrFD);

    NSError *jsonError = nil;
    id result = stdoutData.length ? [NSJSONSerialization JSONObjectWithData:stdoutData options:NSJSONReadingAllowFragments error:&jsonError] : nil;

    if (status == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        NSInteger exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        if ([result isKindOfClass:[NSDictionary class]]) {
            NSString *code = [result[@"error"] isKindOfClass:[NSString class]] ? result[@"error"] : nil;
            NSString *message = [result[@"message"] isKindOfClass:[NSString class]] ? result[@"message"] : nil;
            if (code.length) {
                if (errorInfo) {
                    *errorInfo = FUErrorInfo(code, message.length ? message : [NSString stringWithFormat:@"iCLI exited with code %ld.", (long)exitCode]);
                }
                return nil;
            }
        }
        NSString *detail = FUConciseText(stderrData);
        if (!detail.length) {
            detail = FUConciseText(stdoutData);
        }
        NSString *message = detail.length
            ? [NSString stringWithFormat:@"iCLI exited with code %ld: %@", (long)exitCode, detail]
            : [NSString stringWithFormat:@"iCLI exited with code %ld.", (long)exitCode];
        if (errorInfo) {
            *errorInfo = FUErrorInfo(@"dependency_failed", message);
        }
        return nil;
    }

    if (!result) {
        NSString *detail = FUConciseText(stdoutData);
        NSString *message = detail.length
            ? [NSString stringWithFormat:@"iCLI returned malformed JSON: %@", detail]
            : @"iCLI returned an empty response instead of JSON.";
        if (errorInfo) {
            *errorInfo = FUErrorInfo(@"invalid_dependency_response", message);
        }
        return nil;
    }
    return result;
}

static NSDictionary *FUICLIRunningApp(NSString *bundleID, NSDictionary **errorInfo) {
    id running = FURunICLI(@[@"app", @"running"], errorInfo);
    if (![running isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSArray *apps = [running[@"apps"] isKindOfClass:[NSArray class]] ? running[@"apps"] : nil;
    for (id item in apps) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *candidate = [item[@"bundle_id"] isKindOfClass:[NSString class]] ? item[@"bundle_id"] : nil;
        if ([candidate isEqualToString:bundleID]) {
            return item;
        }
    }
    return nil;
}

static id FUForceKillAppFallback(NSString *bundleID, NSDictionary **errorInfo) {
    NSDictionary *lookupError = nil;
    NSDictionary *app = FUICLIRunningApp(bundleID, &lookupError);
    if (!app) {
        if (lookupError) {
            if (errorInfo) *errorInfo = lookupError;
            return nil;
        }
        return @{
            @"killed": bundleID,
            @"force": @YES,
            @"fallback": @"sigkill",
            @"already_stopped": @YES,
        };
    }

    NSNumber *pidValue = [app[@"pid"] isKindOfClass:[NSNumber class]] ? app[@"pid"] : nil;
    pid_t pid = (pid_t)pidValue.intValue;
    if (pid <= 1) {
        if (errorInfo) {
            *errorInfo = FUErrorInfo(@"dependency_failed", @"iCLI returned an invalid PID for the running application.");
        }
        return nil;
    }

    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
        if (errorInfo) {
            *errorInfo = FUErrorInfo(@"dependency_failed", [NSString stringWithFormat:@"SIGKILL failed for %@ (pid %d): %s", bundleID, pid, strerror(errno)]);
        }
        return nil;
    }

    for (NSUInteger attempt = 0; attempt < 20; attempt++) {
        usleep(100000);
        NSDictionary *pollError = nil;
        NSDictionary *remaining = FUICLIRunningApp(bundleID, &pollError);
        if (!remaining && !pollError) {
            return @{
                @"killed": bundleID,
                @"force": @YES,
                @"fallback": @"sigkill",
                @"pid": @(pid),
            };
        }
        if (pollError) {
            if (errorInfo) *errorInfo = pollError;
            return nil;
        }
    }

    if (errorInfo) {
        *errorInfo = FUErrorInfo(@"failed", [NSString stringWithFormat:@"app is still running after SIGKILL fallback: %@", bundleID]);
    }
    return nil;
}

static id FUHandleAppOperation(NSString *op, NSDictionary *request, NSDictionary **errorInfo) {
    if ([op isEqualToString:@"app.list"]) {
        return FURunICLI(@[@"app", @"list"], errorInfo);
    }
    if ([op isEqualToString:@"app.running"]) {
        return FURunICLI(@[@"app", @"running"], errorInfo);
    }
    if ([op isEqualToString:@"app.frontmost"]) {
        return FURunICLI(@[@"app", @"frontmost"], errorInfo);
    }

    NSString *bundleID = [request[@"bundle_id"] isKindOfClass:[NSString class]] ? request[@"bundle_id"] : nil;
    if (([op isEqualToString:@"app.launch"] || [op isEqualToString:@"app.kill"]) && bundleID.length == 0) {
        if (errorInfo) {
            *errorInfo = FUErrorInfo(@"invalid_arguments", @"bundle_id must be a non-empty string.");
        }
        return nil;
    }
    if ([op isEqualToString:@"app.launch"]) {
        return FURunICLI(@[@"app", @"launch", bundleID], errorInfo);
    }
    if ([op isEqualToString:@"app.kill"]) {
        id forceValue = request[@"force"];
        if (forceValue && ![forceValue isKindOfClass:[NSNumber class]]) {
            if (errorInfo) {
                *errorInfo = FUErrorInfo(@"invalid_arguments", @"force must be a boolean.");
            }
            return nil;
        }
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[@"app", @"kill", bundleID]];
        if ([forceValue boolValue]) {
            [arguments addObject:@"--force"];
        }
        NSDictionary *icliError = nil;
        id result = FURunICLI(arguments, &icliError);
        if (result || ![forceValue boolValue]) {
            if (!result && errorInfo) *errorInfo = icliError;
            return result;
        }
        return FUForceKillAppFallback(bundleID, errorInfo);
    }

    if (errorInfo) {
        *errorInfo = FUErrorInfo(@"invalid_arguments", [NSString stringWithFormat:@"Unknown app operation '%@'.", op]);
    }
    return nil;
}

static BOOL FUInputNumber(id value, double *result, BOOL normalized) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    double number = [value doubleValue];
    if (!isfinite(number) || number < 0.0 || (normalized && number > 1.0)) {
        return NO;
    }
    if (result) *result = number;
    return YES;
}

static BOOL FUInputBoolean(id value, BOOL *result) {
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        return NO;
    }
    if (result) *result = [value boolValue];
    return YES;
}

static BOOL FUInputPositiveInteger(id value, NSInteger *result) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    double number = [value doubleValue];
    NSInteger integer = [value integerValue];
    if (!isfinite(number) || number < 1.0 || number != (double)integer) {
        return NO;
    }
    if (result) *result = integer;
    return YES;
}

static NSString *FUInputNumberString(double value) {
    return [NSString stringWithFormat:@"%.17g", value];
}

static NSString *FUInputJSONString(id value) {
    if (![NSJSONSerialization isValidJSONObject:value]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static BOOL FUInputCoordinatePair(NSDictionary *request, NSString *xKey, NSString *yKey, BOOL normalized, double *x, double *y) {
    return FUInputNumber(request[xKey], x, normalized) && FUInputNumber(request[yKey], y, normalized);
}

static id FUHandleInputOperation(NSString *op, NSDictionary *request, NSDictionary **errorInfo) {
    if ([op isEqualToString:@"input.tap"] || [op isEqualToString:@"input.double_tap"] || [op isEqualToString:@"input.long_press"]) {
        double x = 0.0, y = 0.0;
        if (!FUInputCoordinatePair(request, @"x", @"y", NO, &x, &y)) {
            if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"x and y must be finite non-negative numbers in screen points.");
            return nil;
        }
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObject:@"screen"];
        if ([op isEqualToString:@"input.tap"]) {
            [arguments addObjectsFromArray:@[@"tap", FUInputNumberString(x), FUInputNumberString(y)]];
        } else if ([op isEqualToString:@"input.double_tap"]) {
            [arguments addObjectsFromArray:@[@"double-tap", FUInputNumberString(x), FUInputNumberString(y)]];
            id intervalValue = request[@"interval"];
            if (intervalValue) {
                double interval = 0.0;
                if (!FUInputNumber(intervalValue, &interval, NO)) {
                    if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"interval must be a finite non-negative number of seconds.");
                    return nil;
                }
                [arguments addObjectsFromArray:@[@"--interval", FUInputNumberString(interval)]];
            }
        } else {
            [arguments addObjectsFromArray:@[@"long-press", FUInputNumberString(x), FUInputNumberString(y)]];
            id secondsValue = request[@"seconds"];
            if (secondsValue) {
                double seconds = 0.0;
                if (!FUInputNumber(secondsValue, &seconds, NO)) {
                    if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"seconds must be a finite non-negative duration.");
                    return nil;
                }
                [arguments addObjectsFromArray:@[@"--seconds", FUInputNumberString(seconds)]];
            }
        }
        return FURunICLI(arguments, errorInfo);
    }

    if ([op isEqualToString:@"input.swipe"]) {
        double fromX = 0.0, fromY = 0.0, toX = 0.0, toY = 0.0;
        if (!FUInputCoordinatePair(request, @"from_x", @"from_y", NO, &fromX, &fromY) ||
            !FUInputCoordinatePair(request, @"to_x", @"to_y", NO, &toX, &toY)) {
            if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"from_x, from_y, to_x, and to_y must be finite non-negative screen coordinates.");
            return nil;
        }
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[
            @"screen", @"swipe",
            @"--from-x", FUInputNumberString(fromX), @"--from-y", FUInputNumberString(fromY),
            @"--to-x", FUInputNumberString(toX), @"--to-y", FUInputNumberString(toY),
        ]];
        id secondsValue = request[@"seconds"];
        if (secondsValue) {
            double seconds = 0.0;
            if (!FUInputNumber(secondsValue, &seconds, NO)) {
                if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"seconds must be a finite non-negative duration.");
                return nil;
            }
            [arguments addObjectsFromArray:@[@"--seconds", FUInputNumberString(seconds)]];
        }
        id stepsValue = request[@"steps"];
        if (stepsValue) {
            NSInteger steps = 0;
            if (!FUInputPositiveInteger(stepsValue, &steps)) {
                if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"steps must be a positive integer.");
                return nil;
            }
            [arguments addObjectsFromArray:@[@"--steps", [NSString stringWithFormat:@"%ld", (long)steps]]];
        }
        return FURunICLI(arguments, errorInfo);
    }

    if ([op isEqualToString:@"input.drag"]) {
        id pointsValue = request[@"points"];
        BOOL hasPoints = pointsValue != nil;
        BOOL hasAnyEndpoint = request[@"from_x"] || request[@"from_y"] || request[@"to_x"] || request[@"to_y"];
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"screen", @"drag", nil];
        if (hasPoints == hasAnyEndpoint) {
            if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"drag requires either points or all four endpoint coordinates, but not both.");
            return nil;
        }
        if (hasPoints) {
            if (![pointsValue isKindOfClass:[NSArray class]] || [(NSArray *)pointsValue count] < 2) {
                if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"points must be a JSON array containing at least two {x,y} objects.");
                return nil;
            }
            NSMutableArray *points = [NSMutableArray array];
            for (id rawPoint in (NSArray *)pointsValue) {
                if (![rawPoint isKindOfClass:[NSDictionary class]]) {
                    if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"each drag point must be an object with finite non-negative x and y values.");
                    return nil;
                }
                double x = 0.0, y = 0.0;
                if (!FUInputCoordinatePair(rawPoint, @"x", @"y", NO, &x, &y)) {
                    if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"each drag point must have finite non-negative x and y values.");
                    return nil;
                }
                [points addObject:@{ @"x": @(x), @"y": @(y) }];
            }
            NSString *json = FUInputJSONString(points);
            if (!json) {
                if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"points could not be encoded as JSON.");
                return nil;
            }
            [arguments addObjectsFromArray:@[@"--points", json]];
        } else {
            double fromX = 0.0, fromY = 0.0, toX = 0.0, toY = 0.0;
            if (!FUInputCoordinatePair(request, @"from_x", @"from_y", NO, &fromX, &fromY) ||
                !FUInputCoordinatePair(request, @"to_x", @"to_y", NO, &toX, &toY)) {
                if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"drag endpoint coordinates must be finite non-negative numbers.");
                return nil;
            }
            [arguments addObjectsFromArray:@[
                @"--from-x", FUInputNumberString(fromX), @"--from-y", FUInputNumberString(fromY),
                @"--to-x", FUInputNumberString(toX), @"--to-y", FUInputNumberString(toY),
            ]];
        }
        for (NSString *key in @[@"seconds", @"hold"]) {
            id value = request[key];
            if (!value) continue;
            double number = 0.0;
            if (!FUInputNumber(value, &number, NO)) {
                if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", [NSString stringWithFormat:@"%@ must be a finite non-negative duration.", key]);
                return nil;
            }
            [arguments addObjectsFromArray:@[[NSString stringWithFormat:@"--%@", key], FUInputNumberString(number)]];
        }
        id stepsValue = request[@"steps"];
        if (stepsValue) {
            NSInteger steps = 0;
            if (!FUInputPositiveInteger(stepsValue, &steps)) {
                if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"steps must be a positive integer.");
                return nil;
            }
            [arguments addObjectsFromArray:@[@"--steps", [NSString stringWithFormat:@"%ld", (long)steps]]];
        }
        return FURunICLI(arguments, errorInfo);
    }

    BOOL normalized = NO;
    id normalizedValue = request[@"normalized"];
    if (normalizedValue && !FUInputBoolean(normalizedValue, &normalized)) {
        if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"normalized must be a boolean.");
        return nil;
    }

    if ([op isEqualToString:@"input.touch"]) {
        NSString *phase = [request[@"phase"] isKindOfClass:[NSString class]] ? request[@"phase"] : nil;
        if (![@[@"down", @"move", @"up"] containsObject:phase ?: @""]) {
            if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"phase must be down, move, or up.");
            return nil;
        }
        double x = 0.0, y = 0.0;
        if (!FUInputCoordinatePair(request, @"x", @"y", normalized, &x, &y)) {
            NSString *message = normalized ? @"normalized x and y must be finite numbers from 0 through 1." : @"x and y must be finite non-negative screen coordinates.";
            if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", message);
            return nil;
        }
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[@"screen", @"touch", phase, FUInputNumberString(x), FUInputNumberString(y)]];
        if (normalized) [arguments addObject:@"--normalized"];
        return FURunICLI(arguments, errorInfo);
    }

    if ([op isEqualToString:@"input.touch_sequence"]) {
        id eventsValue = request[@"events"];
        if (![eventsValue isKindOfClass:[NSArray class]] || [(NSArray *)eventsValue count] == 0) {
            if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"events must be a non-empty JSON array of touch events.");
            return nil;
        }
        NSMutableArray *events = [NSMutableArray array];
        for (id rawEvent in (NSArray *)eventsValue) {
            if (![rawEvent isKindOfClass:[NSDictionary class]]) {
                if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"each touch event must be an object with phase, x, y, and delay_ms.");
                return nil;
            }
            NSString *phase = [rawEvent[@"phase"] isKindOfClass:[NSString class]] ? rawEvent[@"phase"] : nil;
            double x = 0.0, y = 0.0, delay = 0.0;
            if (![@[@"down", @"move", @"up"] containsObject:phase ?: @""] ||
                !FUInputCoordinatePair(rawEvent, @"x", @"y", normalized, &x, &y) ||
                !FUInputNumber(rawEvent[@"delay_ms"], &delay, NO)) {
                if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"each touch event requires phase down|move|up, valid x/y coordinates, and finite non-negative delay_ms.");
                return nil;
            }
            [events addObject:@{ @"phase": phase, @"x": @(x), @"y": @(y), @"delay_ms": @(delay) }];
        }
        NSString *json = FUInputJSONString(events);
        if (!json) {
            if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"events could not be encoded as JSON.");
            return nil;
        }
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[@"screen", @"touch-sequence", @"--events", json]];
        if (normalized) [arguments addObject:@"--normalized"];
        return FURunICLI(arguments, errorInfo);
    }

    if (errorInfo) {
        *errorInfo = FUErrorInfo(@"invalid_arguments", [NSString stringWithFormat:@"Unknown input operation '%@'.", op]);
    }
    return nil;
}

static void FUWriteLocked(int fd, NSDictionary *message) {
    [FUWriteLock lock];
    FUWriteJSONLine(fd, message, nil);
    [FUWriteLock unlock];
}

static NSString *FUBuildStatus(NSString *agentBuild) {
    NSString *expectedBuild = FU_EXPECTED_AGENT_BUILD_ID;
    return agentBuild.length == 0 ? @"unknown" : ([agentBuild isEqualToString:expectedBuild] ? @"current" : @"stale");
}

static NSDictionary *FUPublicTargetMetadata(NSDictionary *agent) {
    NSString *agentBuild = [agent[@"agent_build"] isKindOfClass:[NSString class]] ? agent[@"agent_build"] : @"";
    NSString *expectedBuild = FU_EXPECTED_AGENT_BUILD_ID;
    NSString *buildStatus = FUBuildStatus(agentBuild);
    BOOL currentAgent = [buildStatus isEqualToString:@"current"];
    return @{
        @"pid": agent[@"pid"] ?: @0,
        @"bundle_id": agent[@"bundle_id"] ?: NSNull.null,
        @"process": agent[@"process"] ?: @"",
        @"generation": agent[@"generation"] ?: @"",
        @"agent_build": agentBuild,
        @"expected_agent_build": expectedBuild ?: @"",
        @"build_status": buildStatus,
        @"current_agent": @(currentAgent),
        @"refresh_recommended": @((BOOL)!currentAgent),
        @"connected_at_unix_ms": agent[@"connected_at_unix_ms"] ?: @0,
        @"connection_sequence": agent[@"connection_sequence"] ?: @0,
        @"capabilities": agent[@"capabilities"] ?: @[],
    };
}

static BOOL FUTargetMetadataMatchesQuery(NSDictionary *metadata, NSString *target) {
    if (target.length == 0) return YES;
    if ([target isEqualToString:[metadata[@"pid"] stringValue]]) return YES;
    NSString *bundleID = [metadata[@"bundle_id"] isKindOfClass:[NSString class]] ? metadata[@"bundle_id"] : nil;
    if (bundleID.length && [target isEqualToString:bundleID]) return YES;
    NSString *process = [metadata[@"process"] isKindOfClass:[NSString class]] ? metadata[@"process"] : nil;
    return process.length && [target isEqualToString:process];
}

static BOOL FUTargetMetadataIsSpringBoard(NSDictionary *metadata, NSString *query) {
    NSString *bundleID = [metadata[@"bundle_id"] isKindOfClass:[NSString class]] ? metadata[@"bundle_id"] : @"";
    NSString *process = [metadata[@"process"] isKindOfClass:[NSString class]] ? metadata[@"process"] : @"";
    return [bundleID isEqualToString:@"com.apple.springboard"]
        || [process isEqualToString:@"SpringBoard"]
        || [query isEqualToString:@"com.apple.springboard"]
        || [query isEqualToString:@"SpringBoard"];
}

static void FUAppendTargetHistoryEventLocked(NSString *event, NSDictionary *agent, NSString *reason) {
    unsigned long long eventAtUnixMS = (unsigned long long)(NSDate.date.timeIntervalSince1970 * 1000.0);
    NSString *agentBuild = [agent[@"agent_build"] isKindOfClass:[NSString class]] ? agent[@"agent_build"] : @"";
    NSString *buildStatus = FUBuildStatus(agentBuild);
    NSMutableDictionary *entry = [@{
        @"event": event ?: @"unknown",
        @"event_at_unix_ms": @(eventAtUnixMS),
        @"history_event_sequence": @(++FUTargetHistoryEventSequence),
        @"pid": agent[@"pid"] ?: @0,
        @"bundle_id": agent[@"bundle_id"] ?: NSNull.null,
        @"process": agent[@"process"] ?: @"",
        @"generation": agent[@"generation"] ?: @"",
        @"agent_build": agentBuild,
        @"expected_agent_build": FU_EXPECTED_AGENT_BUILD_ID ?: @"",
        @"build_status": buildStatus,
        @"current_agent": @([buildStatus isEqualToString:@"current"]),
        @"connected_at_unix_ms": agent[@"connected_at_unix_ms"] ?: @0,
        @"connection_sequence": agent[@"connection_sequence"] ?: @0,
    } mutableCopy];
    if (reason.length) entry[@"reason"] = reason;
    [FUTargetHistory addObject:entry];
    if (FUTargetHistory.count > FUTargetHistoryCapacity) {
        NSUInteger overflow = FUTargetHistory.count - FUTargetHistoryCapacity;
        [FUTargetHistory removeObjectsInRange:NSMakeRange(0, overflow)];
        FUDroppedTargetHistoryEvents += overflow;
    }
}

static NSDictionary *FUTargetHistoryResult(NSDictionary *request, NSDictionary **errorInfo) {
    id targetValue = request[@"target"];
    if (targetValue && ![targetValue isKindOfClass:[NSString class]]) {
        if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"target must be a PID, bundle identifier, or process name string.");
        return nil;
    }
    NSString *target = [targetValue isKindOfClass:[NSString class]] ? targetValue : @"";

    NSUInteger limit = 32;
    id limitValue = request[@"limit"];
    if (limitValue) {
        if (![limitValue isKindOfClass:[NSNumber class]]) {
            if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"limit must be an integer from 1 through 128.");
            return nil;
        }
        double rawLimit = [limitValue doubleValue];
        if (!isfinite(rawLimit) || floor(rawLimit) != rawLimit || rawLimit < 1.0 || rawLimit > (double)FUTargetHistoryCapacity) {
            if (errorInfo) *errorInfo = FUErrorInfo(@"invalid_arguments", @"limit must be an integer from 1 through 128.");
            return nil;
        }
        limit = (NSUInteger)rawLimit;
    }

    [FUStateLock lock];
    NSArray<NSDictionary *> *history = FUTargetHistory.copy;
    NSArray<NSDictionary *> *agents = FUAgents.allValues.copy;
    unsigned long long dropped = FUDroppedTargetHistoryEvents;
    unsigned long long daemonStarted = FUDaemonStartedAtUnixMS;
    [FUStateLock unlock];

    NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
    NSUInteger retainedMatchCount = 0;
    NSUInteger connectedObservations = 0;
    for (NSDictionary *entry in history) {
        if (!FUTargetMetadataMatchesQuery(entry, target)) continue;
        retainedMatchCount++;
        if ([entry[@"event"] isEqualToString:@"connected"]) connectedObservations++;
    }
    for (NSDictionary *entry in [history reverseObjectEnumerator]) {
        if (!FUTargetMetadataMatchesQuery(entry, target)) continue;
        if (events.count >= limit) break;
        [events addObject:entry];
    }

    NSMutableArray<NSDictionary *> *currentTargets = [NSMutableArray array];
    for (NSDictionary *agent in agents) {
        NSDictionary *metadata = FUPublicTargetMetadata(agent);
        if (FUTargetMetadataMatchesQuery(metadata, target)) [currentTargets addObject:metadata];
    }

    NSString *state = @"unfiltered";
    NSString *recoveryHint = @"inspect_history";
    NSString *recommendedAction = @"Use target.resolve or target.health for a live target, or filter target.history to diagnose one target.";
    NSDictionary *latestEvidence = events.firstObject;
    BOOL springBoard = FUTargetMetadataIsSpringBoard(currentTargets.firstObject ?: latestEvidence ?: @{}, target);
    if (target.length) {
        if (currentTargets.count > 1) {
            state = @"current_ambiguous";
            recoveryHint = @"resolve_to_pid";
            recommendedAction = @"Multiple live targets match this query. Run target.resolve and continue with the returned PID.";
        } else if (currentTargets.count == 1) {
            NSDictionary *current = currentTargets.firstObject;
            if ([current[@"current_agent"] boolValue]) {
                state = @"current";
                recoveryHint = @"target_health";
                recommendedAction = @"Run target.health for this live target before deeper inspection.";
            } else {
                state = @"stale_current";
                recoveryHint = springBoard ? @"springboard_stale_defer_refresh" : @"refresh_target";
                recommendedAction = springBoard
                    ? @"SpringBoard is live with a stale or unknown agent. Do not respring solely for diagnostics; refresh it only when the task otherwise requires it."
                    : @"Refresh this target process when appropriate so it loads the currently installed FlexUltraAgent, then run target.health.";
            }
        } else if (retainedMatchCount > 0) {
            state = @"recently_disconnected";
            if (springBoard) {
                recoveryHint = @"springboard_refresh_deferred";
                recommendedAction = @"SpringBoard was observed during this daemon lifetime but is no longer connected. Do not respring solely for diagnostics; refresh it only when the task otherwise requires it.";
            } else {
                NSString *bundleID = [latestEvidence[@"bundle_id"] isKindOfClass:[NSString class]] ? latestEvidence[@"bundle_id"] : @"";
                recoveryHint = bundleID.length ? @"app_launch" : @"start_or_refresh_target";
                recommendedAction = bundleID.length
                    ? [NSString stringWithFormat:@"If relaunch is appropriate and iCLI is available, use app.launch for %@, then run target.health.", bundleID]
                    : @"Start or refresh the target process when appropriate, then run target.health.";
            }
        } else {
            state = @"never_seen_since_daemon_start";
            recoveryHint = springBoard ? @"springboard_not_observed" : @"start_or_refresh_target";
            recommendedAction = springBoard
                ? @"SpringBoard has not registered since this daemon started. Do not respring solely for diagnostics; wait for or perform a task-required SpringBoard refresh."
                : @"This target has not registered since flexultrad started. Start or refresh it when appropriate, then rerun target.history and target.health.";
        }
    }

    return @{
        @"query": target.length ? target : NSNull.null,
        @"state": state,
        @"recovery_hint": recoveryHint,
        @"recommended_action": recommendedAction,
        @"daemon_started_at_unix_ms": @(daemonStarted),
        @"expected_agent_build": FU_EXPECTED_AGENT_BUILD_ID ?: @"",
        @"history_capacity": @(FUTargetHistoryCapacity),
        @"history_dropped": @(dropped),
        @"history_truncated": @(dropped > 0),
        @"retained_match_count": @(retainedMatchCount),
        @"reconnect_count_in_retained_history": @(connectedObservations > 0 ? connectedObservations - 1 : 0),
        @"limit": @(limit),
        @"current_targets": currentTargets,
        @"events": events,
    };
}

static NSArray<NSDictionary *> *FUTargets(void) {
    [FUStateLock lock];
    NSArray *agents = FUAgents.allValues.copy;
    [FUStateLock unlock];

    return [agents sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *aProcess = [a[@"process"] isKindOfClass:[NSString class]] ? a[@"process"] : @"";
        NSString *bProcess = [b[@"process"] isKindOfClass:[NSString class]] ? b[@"process"] : @"";
        NSComparisonResult result = [aProcess compare:bProcess options:NSCaseInsensitiveSearch];
        if (result != NSOrderedSame) return result;

        NSString *aBundle = [a[@"bundle_id"] isKindOfClass:[NSString class]] ? a[@"bundle_id"] : @"";
        NSString *bBundle = [b[@"bundle_id"] isKindOfClass:[NSString class]] ? b[@"bundle_id"] : @"";
        result = [aBundle compare:bBundle options:NSCaseInsensitiveSearch];
        if (result != NSOrderedSame) return result;

        return [[a[@"pid"] stringValue] compare:[b[@"pid"] stringValue] options:NSNumericSearch];
    }];
}

static NSDictionary *FUTargetResolutionError(NSString *code, NSString *message, NSArray<NSDictionary *> *candidates) {
    NSMutableDictionary *error = [FUErrorInfo(code, message) mutableCopy];
    if (candidates.count) {
        NSMutableArray *metadata = [NSMutableArray arrayWithCapacity:candidates.count];
        for (NSDictionary *candidate in candidates) {
            [metadata addObject:FUPublicTargetMetadata(candidate)];
        }
        error[@"candidates"] = metadata;
    }
    return error;
}

static NSDictionary *FUResolveAgent(NSString *target, NSString **matchKind, NSDictionary **errorInfo) {
    NSArray<NSDictionary *> *agents = FUTargets();
    if (target.length == 0) {
        if (agents.count == 1) {
            if (matchKind) *matchKind = @"unique";
            return agents.firstObject;
        }
        if (errorInfo) {
            *errorInfo = agents.count == 0
                ? FUErrorInfo(@"target_not_found", @"No FlexUltra agents are connected.")
                : FUTargetResolutionError(@"target_ambiguous", @"Multiple FlexUltra agents are connected. Pass a PID, bundle ID, or process name.", agents);
        }
        return nil;
    }

    NSMutableArray<NSDictionary *> *pidMatches = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *bundleMatches = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *processMatches = [NSMutableArray array];
    for (NSDictionary *agent in agents) {
        if ([target isEqualToString:[agent[@"pid"] stringValue]]) [pidMatches addObject:agent];
        NSString *bundleID = [agent[@"bundle_id"] isKindOfClass:[NSString class]] ? agent[@"bundle_id"] : nil;
        if (bundleID && [target isEqualToString:bundleID]) [bundleMatches addObject:agent];
        NSString *process = [agent[@"process"] isKindOfClass:[NSString class]] ? agent[@"process"] : @"";
        if ([target isEqualToString:process]) [processMatches addObject:agent];
    }

    NSArray<NSDictionary *> *matches = nil;
    NSString *kind = nil;
    if (pidMatches.count) {
        matches = pidMatches;
        kind = @"pid";
    } else if (bundleMatches.count) {
        matches = bundleMatches;
        kind = @"bundle_id";
    } else if (processMatches.count) {
        matches = processMatches;
        kind = @"process";
    }

    if (matches.count == 1) {
        if (matchKind) *matchKind = kind;
        return matches.firstObject;
    }
    if (matches.count > 1) {
        if (errorInfo) {
            *errorInfo = FUTargetResolutionError(
                @"target_ambiguous",
                [NSString stringWithFormat:@"Target '%@' matched multiple connected agents by %@. Use a PID to select one.", target, kind],
                matches);
        }
        return nil;
    }

    if (errorInfo) {
        *errorInfo = FUErrorInfo(@"target_not_found", [NSString stringWithFormat:@"No connected target matched '%@'.", target]);
    }
    return nil;
}

static NSDictionary *FUSanitizedAgentInfo(NSDictionary *hello, int fd) {
    id bundleID = hello[@"bundle_id"];
    if (![bundleID isKindOfClass:[NSString class]]) {
        bundleID = [NSNull null];
    }
    NSString *generation = [hello[@"generation"] isKindOfClass:[NSString class]] ? hello[@"generation"] : @"";
    NSString *agentBuild = [hello[@"agent_build"] isKindOfClass:[NSString class]] ? hello[@"agent_build"] : @"";

    [FUStateLock lock];
    unsigned long long connectionSequence = ++FUConnectionSequence;
    [FUStateLock unlock];

    return @{
        @"pid": hello[@"pid"] ?: @0,
        @"bundle_id": bundleID,
        @"process": hello[@"process"] ?: @"",
        @"generation": generation,
        @"agent_build": agentBuild,
        @"capabilities": hello[@"capabilities"] ?: @[],
        @"connected_at_unix_ms": @((unsigned long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
        @"connection_sequence": @(connectionSequence),
        @"fd": @(fd),
    };
}

static void FUHandleAgent(int fd, NSDictionary *hello) {
    NSDictionary *agent = FUSanitizedAgentInfo(hello, fd);
    NSNumber *fdKey = @(fd);

    [FUStateLock lock];
    FUAgents[fdKey] = agent;
    FUAppendTargetHistoryEventLocked(@"connected", agent, nil);
    [FUStateLock unlock];

    FUWriteLocked(fd, @{
        @"v": @(FUProtocolVersion),
        @"kind": @"hello_ack",
        @"ok": @YES,
    });

    while (YES) {
        NSDictionary *response = FUReadJSONLine(fd, nil);
        if (!response) {
            break;
        }

        NSString *routeID = [response[@"id"] isKindOfClass:[NSString class]] ? response[@"id"] : nil;
        if (!routeID) {
            continue;
        }

        [FUStateLock lock];
        NSDictionary *pending = FUPending[routeID];
        if (pending) {
            [FUPending removeObjectForKey:routeID];
        }
        [FUStateLock unlock];

        if (!pending) {
            continue;
        }

        NSMutableDictionary *forwarded = [response mutableCopy];
        forwarded[@"id"] = pending[@"client_id"] ?: @"";
        forwarded[@"target"] = FUPublicTargetMetadata(agent);
        if (![forwarded[@"ok"] boolValue] && [forwarded[@"error"] isKindOfClass:[NSDictionary class]]) {
            NSString *operation = [pending[@"operation"] isKindOfClass:[NSString class]] ? pending[@"operation"] : nil;
            forwarded[@"error"] = FUEnrichErrorInfo(forwarded[@"error"], operation);
        }
        FUWriteLocked([pending[@"client_fd"] intValue], forwarded);
    }

    [FUStateLock lock];
    [FUAgents removeObjectForKey:fdKey];
    FUAppendTargetHistoryEventLocked(@"disconnected", agent, @"transport_closed");
    [FUStateLock unlock];
}

static void FUHandleClient(int fd) {
    FUWriteLocked(fd, @{
        @"v": @(FUProtocolVersion),
        @"kind": @"hello_ack",
        @"ok": @YES,
    });

    while (YES) {
        NSDictionary *request = FUReadJSONLine(fd, nil);
        if (!request) {
            break;
        }

        NSString *requestID = [request[@"id"] isKindOfClass:[NSString class]] ? request[@"id"] : NSUUID.UUID.UUIDString;
        NSString *op = [request[@"op"] isKindOfClass:[NSString class]] ? request[@"op"] : @"";

        if ([op isEqualToString:@"targets"]) {
            NSMutableArray *targets = [NSMutableArray array];
            for (NSDictionary *agent in FUTargets()) {
                [targets addObject:FUPublicTargetMetadata(agent)];
            }
            FUWriteLocked(fd, FUResponse(requestID, YES, @{
                @"targets": targets,
                @"expected_agent_build": FU_EXPECTED_AGENT_BUILD_ID,
                @"daemon_memory_policy": FUDaemonMemoryPolicy ?: @{},
            }, nil));
            continue;
        }

        if ([op isEqualToString:@"target.resolve"]) {
            NSString *target = [request[@"target"] isKindOfClass:[NSString class]] ? request[@"target"] : @"";
            NSString *matchKind = nil;
            NSDictionary *resolutionError = nil;
            NSDictionary *agent = FUResolveAgent(target, &matchKind, &resolutionError);
            if (!agent) {
                FUWriteLocked(fd, FUResponse(requestID, NO, nil, resolutionError));
            } else {
                FUWriteLocked(fd, FUResponse(requestID, YES, @{
                    @"query": target,
                    @"match_kind": matchKind ?: @"unknown",
                    @"target": FUPublicTargetMetadata(agent),
                }, nil));
            }
            continue;
        }

        if ([op isEqualToString:@"target.history"]) {
            NSDictionary *historyError = nil;
            NSDictionary *historyResult = FUTargetHistoryResult(request, &historyError);
            FUWriteLocked(fd, historyResult
                ? FUResponse(requestID, YES, historyResult, nil)
                : FUResponse(requestID, NO, nil, historyError ?: FUErrorInfo(@"invalid_arguments", @"Invalid target.history request.")));
            continue;
        }

        if ([op hasPrefix:@"app."]) {
            NSDictionary *errorInfo = nil;
            id result = FUHandleAppOperation(op, request, &errorInfo);
            FUWriteLocked(fd, result
                ? FUResponse(requestID, YES, result, nil)
                : FUResponse(requestID, NO, nil, errorInfo ?: FUErrorInfo(@"dependency_failed", @"App lifecycle operation failed.")));
            continue;
        }

        if ([op hasPrefix:@"input."]) {
            NSDictionary *errorInfo = nil;
            id result = FUHandleInputOperation(op, request, &errorInfo);
            FUWriteLocked(fd, result
                ? FUResponse(requestID, YES, result, nil)
                : FUResponse(requestID, NO, nil, errorInfo ?: FUErrorInfo(@"dependency_failed", @"Physical input operation failed.")));
            continue;
        }

        NSString *target = [request[@"target"] isKindOfClass:[NSString class]] ? request[@"target"] : @"";
        NSString *matchKind = nil;
        NSDictionary *resolutionError = nil;
        NSDictionary *agent = FUResolveAgent(target, &matchKind, &resolutionError);
        if (!agent) {
            FUWriteLocked(fd, FUResponse(requestID, NO, nil, resolutionError));
            continue;
        }

        id expectedGenerationValue = request[@"expected_generation"];
        if (expectedGenerationValue) {
            if (![expectedGenerationValue isKindOfClass:[NSString class]] || [(NSString *)expectedGenerationValue length] == 0) {
                FUWriteLocked(fd, FUResponse(requestID, NO, nil, FUEnrichErrorInfo(
                    FUErrorInfo(@"invalid_arguments", @"expected_generation must be a non-empty string when provided."),
                    op)));
                continue;
            }

            NSString *expectedGeneration = (NSString *)expectedGenerationValue;
            NSString *currentGeneration = [agent[@"generation"] isKindOfClass:[NSString class]] ? agent[@"generation"] : @"";
            if (![currentGeneration isEqualToString:expectedGeneration]) {
                NSMutableDictionary *generationError = [FUErrorInfo(
                    @"target_generation_changed",
                    @"Target process generation changed since discovery.") mutableCopy];
                generationError[@"expected_generation"] = expectedGeneration;
                generationError[@"current_generation"] = currentGeneration;
                generationError[@"target"] = FUPublicTargetMetadata(agent);
                FUWriteLocked(fd, FUResponse(requestID, NO, nil, FUEnrichErrorInfo(generationError, op)));
                continue;
            }
        }

        NSString *routeID = NSUUID.UUID.UUIDString;
        NSMutableDictionary *forwarded = [request mutableCopy];
        forwarded[@"id"] = routeID;

        [FUStateLock lock];
        FUPending[routeID] = @{
            @"client_fd": @(fd),
            @"client_id": requestID,
            @"operation": op ?: @"",
        };
        [FUStateLock unlock];

        NSError *writeError = nil;
        [FUWriteLock lock];
        BOOL wrote = FUWriteJSONLine([agent[@"fd"] intValue], forwarded, &writeError);
        [FUWriteLock unlock];
        if (!wrote) {
            [FUStateLock lock];
            [FUPending removeObjectForKey:routeID];
            [FUStateLock unlock];
            FUWriteLocked(fd, FUResponse(requestID, NO, nil, FUErrorInfo(@"agent_unreachable", writeError.localizedDescription ?: @"Failed to send request to target.")));
        }
    }

    [FUStateLock lock];
    NSArray<NSString *> *pendingIDs = [FUPending keysOfEntriesPassingTest:^BOOL(NSString *key, NSDictionary *value, BOOL *stop) {
        return [value[@"client_fd"] intValue] == fd;
    }].allObjects;
    [FUPending removeObjectsForKeys:pendingIDs];
    [FUStateLock unlock];
}

static void *FUConnectionThread(void *context) {
    @autoreleasepool {
        int fd = (int)(intptr_t)context;
        NSDictionary *hello = FUReadJSONLine(fd, nil);
        if (!hello || ![hello[@"kind"] isEqual:@"hello"] || [hello[@"v"] unsignedIntegerValue] != FUProtocolVersion) {
            FUWriteLocked(fd, @{
                @"v": @(FUProtocolVersion),
                @"kind": @"hello_ack",
                @"ok": @NO,
                @"error": FUErrorInfo(@"protocol_mismatch", @"Expected a compatible hello message."),
            });
            close(fd);
            return NULL;
        }

        NSString *role = [hello[@"role"] isKindOfClass:[NSString class]] ? hello[@"role"] : @"";
        if ([role isEqualToString:@"agent"]) {
            FUHandleAgent(fd, hello);
        } else if ([role isEqualToString:@"cli"] || [role isEqualToString:@"mcp"]) {
            FUHandleClient(fd);
        } else {
            FUWriteLocked(fd, @{
                @"v": @(FUProtocolVersion),
                @"kind": @"hello_ack",
                @"ok": @NO,
                @"error": FUErrorInfo(@"invalid_role", @"Role must be agent, cli, or mcp."),
            });
        }

        close(fd);
    }
    return NULL;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        FUDaemonMemoryPolicy = FUConfigureDaemonMemoryPolicy();
        if (![FUDaemonMemoryPolicy[@"verified"] boolValue]) {
            NSLog(@"[FlexUltra] refusing to start without verified daemon memory policy: %@", FUDaemonMemoryPolicy);
            return 1;
        }

        FUStateLock = [NSLock new];
        FUWriteLock = [NSLock new];
        FUAgents = [NSMutableDictionary dictionary];
        FUPending = [NSMutableDictionary dictionary];
        FUTargetHistory = [NSMutableArray array];
        FUConnectionSequence = 0;
        FUTargetHistoryEventSequence = 0;
        FUDroppedTargetHistoryEvents = 0;
        FUDaemonStartedAtUnixMS = (unsigned long long)(NSDate.date.timeIntervalSince1970 * 1000.0);

        int server = socket(AF_INET, SOCK_STREAM, 0);
        if (server < 0) {
            NSLog(@"[FlexUltra] socket failed");
            return 1;
        }

        int reuse = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
#ifdef SO_NOSIGPIPE
        int noSigPipe = 1;
        setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
#endif

        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_port = htons(FUDaemonPort);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

        if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0) {
            NSLog(@"[FlexUltra] bind failed on 127.0.0.1:%u", FUDaemonPort);
            close(server);
            return 1;
        }
        if (listen(server, 32) != 0) {
            NSLog(@"[FlexUltra] listen failed");
            close(server);
            return 1;
        }

        NSLog(@"[FlexUltra] flexultrad listening on 127.0.0.1:%u", FUDaemonPort);
        while (YES) {
            int client = accept(server, NULL, NULL);
            if (client < 0) {
                continue;
            }

#ifdef SO_NOSIGPIPE
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
#endif

            pthread_t thread;
            if (pthread_create(&thread, NULL, FUConnectionThread, (void *)(intptr_t)client) == 0) {
                pthread_detach(thread);
            } else {
                close(client);
            }
        }
    }
}
