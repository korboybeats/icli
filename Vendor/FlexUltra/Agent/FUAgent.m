#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <math.h>

#import <arpa/inet.h>
#import <dlfcn.h>
#import <malloc/malloc.h>
#import <netinet/in.h>
#import <sys/stat.h>
#import <sys/socket.h>
#import <unistd.h>

#import "FUProtocol.h"
#import "FURequestDispatcher.h"
#import "FUHeap.h"
#import "FUObjectRegistry.h"
#import "FUObjectSerialization.h"
#import "FUObjectInspection.h"
#import "FUSwiftInspection.h"
#import "FUInvestigation.h"
#import "FUFlexTools.h"
#import "FUDefaults.h"
#import "FUExperiments.h"
#import "FUKeychain.h"
#import "FURuntime.h"
#import "FUStorage.h"
#import "FUTrace.h"
#import "FUUI.h"

#ifndef FU_AGENT_BUILD_ID
#define FU_AGENT_BUILD_ID @"unknown"
#endif
static NSString *const FUSnapchatBundleID = @"com.toyopagroup.picaboo";
static const NSUInteger FUAgentStartupDelayMs = 750;


static NSObject *FUAgentConnectionLock;
static int FUAgentConnectionFD = -1;
static uint64_t FUAgentConnectionGeneration = 0;

static NSObject *FUHeapWorkerLock;
static dispatch_queue_t FUHeapWorkerQueue;
static dispatch_queue_t FUHeapExecutionQueue;
static BOOL FUHeapWorkerBusy = NO;

static NSObject *FUHealthUILock;
static NSDictionary *FUHealthUICache;

static NSObject *FUKeychainWorkerLock;
static dispatch_queue_t FUKeychainWorkerQueue;
static dispatch_queue_t FUKeychainExecutionQueue;
static BOOL FUKeychainWorkerBusy = NO;
static const NSInteger FUKeychainHardTimeoutMS = 5000;

extern bool objsee_message_interception_set_thread_suppressed(bool suppressed);

static void FUInitializeAgentConcurrency(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FUAgentConnectionLock = [NSObject new];
        FUHeapWorkerLock = [NSObject new];
        FUHeapWorkerQueue = dispatch_queue_create("moe.waru.flexultra.heap", DISPATCH_QUEUE_SERIAL);
        FUHeapExecutionQueue = dispatch_queue_create("moe.waru.flexultra.heap.execution", DISPATCH_QUEUE_SERIAL);
        FUHealthUILock = [NSObject new];
        FUKeychainWorkerLock = [NSObject new];
        FUKeychainWorkerQueue = dispatch_queue_create("moe.waru.flexultra.keychain", DISPATCH_QUEUE_SERIAL);
        FUKeychainExecutionQueue = dispatch_queue_create("moe.waru.flexultra.keychain.execution", DISPATCH_QUEUE_SERIAL);
    });
}

static NSDictionary *FUCurrentHealthUISample(void) {
    __block NSUInteger windowCount = 0;
    __block NSDictionary *keyWindowJSON = nil;
    void (^sampleUI)(void) = ^{
        NSArray<UIWindow *> *windows = FUAllWindows();
        windowCount = windows.count;
        UIWindow *keyWindow = FUKeyWindow();
        if (keyWindow) keyWindowJSON = FUWindowJSON(keyWindow);
    };
    if (NSThread.isMainThread) sampleUI();
    else dispatch_sync(dispatch_get_main_queue(), sampleUI);

    NSMutableDictionary *ui = [@{
        @"available": windowCount > 0 ? @YES : @NO,
        @"window_count": @(windowCount),
        @"key_window_available": keyWindowJSON != nil ? @YES : @NO,
        @"hierarchy_supported": @YES,
        @"snapshot_supported": @YES,
        @"snapshot_diff_supported": @YES,
        @"sample_fresh": @YES,
        @"sample_deferred_due_to_heap": @NO,
    } mutableCopy];
    if (keyWindowJSON) ui[@"key_window"] = keyWindowJSON;

    NSDictionary *snapshot = [ui copy];
    FUInitializeAgentConcurrency();
    @synchronized (FUHealthUILock) {
        FUHealthUICache = snapshot;
    }
    return snapshot;
}

static NSDictionary *FUHealthUISampleForHeapState(BOOL heapBusy) {
    FUInitializeAgentConcurrency();
    if (!heapBusy) {
        return FUCurrentHealthUISample();
    }

    NSDictionary *cached = nil;
    @synchronized (FUHealthUILock) {
        cached = FUHealthUICache;
    }

    NSMutableDictionary *ui = cached ? [cached mutableCopy] : [@{
        @"available": @NO,
        @"window_count": @0,
        @"key_window_available": @NO,
        @"hierarchy_supported": @YES,
        @"snapshot_supported": @YES,
        @"snapshot_diff_supported": @YES,
    } mutableCopy];
    ui[@"sample_fresh"] = @NO;
    ui[@"sample_deferred_due_to_heap"] = @YES;
    return ui;
}

static uint64_t FUActivateAgentConnection(int fd) {
    FUInitializeAgentConcurrency();
    @synchronized (FUAgentConnectionLock) {
        FUAgentConnectionFD = fd;
        FUAgentConnectionGeneration++;
        return FUAgentConnectionGeneration;
    }
}

static void FUCloseAgentConnection(int fd, uint64_t generation) {
    FUInitializeAgentConcurrency();
    @synchronized (FUAgentConnectionLock) {
        if (FUAgentConnectionFD == fd && FUAgentConnectionGeneration == generation) {
            FUAgentConnectionFD = -1;
            FUAgentConnectionGeneration++;
        }
        close(fd);
    }
}

static BOOL FUWriteAgentJSONLine(int fd, uint64_t generation, NSDictionary *object, NSError **error) {
    FUInitializeAgentConcurrency();
    @synchronized (FUAgentConnectionLock) {
        if (FUAgentConnectionFD != fd || FUAgentConnectionGeneration != generation) {
            return NO;
        }
        return FUWriteJSONLine(fd, object, error);
    }
}

static BOOL FUWriteAgentResponse(int fd,
                                 uint64_t generation,
                                 NSString *operation,
                                 NSString *requestID,
                                 NSDictionary *response) {
    NSError *error = nil;
    if (FUWriteAgentJSONLine(fd, generation, response, &error)) {
        return YES;
    }
    if (!error) {
        return NO;
    }

    NSString *responseOperation = operation.length ? operation : @"unknown";
    NSString *message = [NSString stringWithFormat:@"FlexUltra could not serialize the %@ response as JSON: %@",
                         responseOperation,
                         error.localizedDescription ?: @"unknown serialization error"];
    NSDictionary *fallback = FUResponse(requestID ?: @"",
                                        NO,
                                        nil,
                                        FUErrorInfo(@"response_serialization_failed", message));
    return FUWriteAgentJSONLine(fd, generation, fallback, nil);
}

static BOOL FUBeginHeapWorker(void) {
    FUInitializeAgentConcurrency();
    @synchronized (FUHeapWorkerLock) {
        if (FUHeapWorkerBusy) {
            return NO;
        }
        FUHeapWorkerBusy = YES;
        return YES;
    }
}

static void FUEndHeapWorker(void) {
    FUInitializeAgentConcurrency();
    @synchronized (FUHeapWorkerLock) {
        FUHeapWorkerBusy = NO;
    }
}

static BOOL FUBeginKeychainWorker(void) {
    FUInitializeAgentConcurrency();
    @synchronized (FUKeychainWorkerLock) {
        if (FUKeychainWorkerBusy) {
            return NO;
        }
        FUKeychainWorkerBusy = YES;
        return YES;
    }
}

static void FUEndKeychainWorker(void) {
    FUInitializeAgentConcurrency();
    @synchronized (FUKeychainWorkerLock) {
        FUKeychainWorkerBusy = NO;
    }
}

static NSInteger FUHeapHardTimeoutMS(NSDictionary *request) {
    id timeoutValue = request[@"timeout_ms"];
    if (![timeoutValue isKindOfClass:[NSNumber class]]) {
        return 60000;
    }

    NSInteger timeoutMS = [timeoutValue integerValue];
    if (timeoutMS < 1 || timeoutMS > 110000) {
        // FUHeap validates the field and will promptly return the protocol-level
        // invalid_heap_timeout error. Use the normal budget here so this outer
        // guard does not replace that more specific response.
        return 60000;
    }
    return timeoutMS;
}

static NSDictionary *FUHeapHardTimeoutResponse(NSString *requestID,
                                                NSString *operation,
                                                NSInteger timeoutMS,
                                                CFAbsoluteTime started) {
    NSTimeInterval elapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - started);
    NSMutableDictionary *error = [FUErrorInfo(
        @"heap_timeout",
        [NSString stringWithFormat:@"%@ exceeded its %ld ms heap time budget.",
                                   operation.length ? operation : @"Heap request",
                                   (long)timeoutMS]) mutableCopy];
    error[@"operation"] = operation.length ? operation : @"heap";
    error[@"timeout_ms"] = @(timeoutMS);
    error[@"elapsed_ms"] = @((NSInteger)(elapsed * 1000.0));
    return FUResponse(requestID ?: @"", NO, nil, error);
}

static NSDictionary *FUKeychainHardTimeoutResponse(NSString *requestID,
                                                    NSString *operation,
                                                    CFAbsoluteTime started) {
    NSTimeInterval elapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - started);
    NSMutableDictionary *error = [FUErrorInfo(
        @"keychain_timeout",
        [NSString stringWithFormat:@"%@ exceeded the %ld ms Keychain time budget.",
                                   operation.length ? operation : @"Keychain request",
                                   (long)FUKeychainHardTimeoutMS]) mutableCopy];
    error[@"operation"] = operation.length ? operation : @"keychain";
    error[@"timeout_ms"] = @(FUKeychainHardTimeoutMS);
    error[@"elapsed_ms"] = @((NSInteger)(elapsed * 1000.0));
    return FUResponse(requestID ?: @"", NO, nil, error);
}

static id FUObjectMessage(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static BOOL FUBoolMessage(id target, NSString *selectorName, BOOL fallback) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) {
        return fallback;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSUInteger FUUnsignedMessage(id target, NSString *selectorName, NSUInteger fallback) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) {
        return fallback;
    }
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSInteger FUSignedMessage(id target, NSString *selectorName, NSInteger fallback) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) {
        return fallback;
    }
    return ((NSInteger (*)(id, SEL))objc_msgSend)(target, selector);
}

static BOOL FUIsEligibleProcess(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *bundleID = bundle.bundleIdentifier;
    if ([bundleID isEqualToString:FUSnapchatBundleID]) {
        return NO;
    }

    NSString *executable = NSProcessInfo.processInfo.arguments.firstObject ?: @"";
    if ([executable hasSuffix:@"/SpringBoard"] || [NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
        return YES;
    }

    // The substrate filter intentionally stays broad so arbitrary UIKit apps can
    // be inspected. Keep the active agent out of extensions, XPC services, and
    // helper executables that happen to live below an .app directory.
    NSString *bundlePath = bundle.bundlePath ?: @"";
    if (![[bundlePath.pathExtension lowercaseString] isEqualToString:@"app"]) {
        return NO;
    }

    NSDictionary *info = bundle.infoDictionary ?: @{};
    if ([info[@"NSExtension"] isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSString *packageType = [info[@"CFBundlePackageType"] isKindOfClass:[NSString class]] ? info[@"CFBundlePackageType"] : @"";
    if (packageType.length > 0 && ![packageType isEqualToString:@"APPL"]) {
        return NO;
    }

    NSString *bundleExecutable = bundle.executablePath ?: @"";
    if (bundleExecutable.length > 0) {
        NSString *actualPath = executable.stringByStandardizingPath;
        NSString *expectedPath = bundleExecutable.stringByStandardizingPath;
        if (![actualPath isEqualToString:expectedPath]) {
            return NO;
        }
    }

    return executable.length > 0;
}
















static NSDictionary *FUHandleTargetHealth(NSString *requestID) {
    NSString *generation = FUCurrentObjectGeneration();
    FUInitializeAgentConcurrency();
    BOOL heapBusy = NO;
    @synchronized (FUHeapWorkerLock) {
        heapBusy = FUHeapWorkerBusy;
    }
    BOOL keychainBusy = NO;
    @synchronized (FUKeychainWorkerLock) {
        keychainBusy = FUKeychainWorkerBusy;
    }

    NSDictionary *flex = FUFlexStatus(YES);
    NSDictionary *ui = FUHealthUISampleForHeapState(heapBusy);
    NSDictionary *traceStatus = FUTraceStatusSnapshot();
    NSDictionary *experimentStatus = FUExperimentStatusSnapshot();

    BOOL generationConsistent = generation.length > 0 && [generation isEqualToString:FUCurrentObjectGeneration()];
    BOOL flexAvailable = [flex[@"available"] boolValue];
    NSDictionary *operationSupport = [flex[@"operation_support"] isKindOfClass:[NSDictionary class]] ? flex[@"operation_support"] : @{};
    BOOL (^operationSupported)(NSString *) = ^BOOL(NSString *operation) {
        NSDictionary *entry = [operationSupport[operation] isKindOfClass:[NSDictionary class]] ? operationSupport[operation] : nil;
        return [entry[@"supported"] boolValue];
    };
    BOOL runtimeInspection = operationSupported(@"runtime.classes") &&
        operationSupported(@"runtime.methods") &&
        operationSupported(@"runtime.properties") &&
        operationSupported(@"runtime.ivars");
    BOOL objectInspection = operationSupported(@"object.inspect");
    BOOL heapInspection = operationSupported(@"heap.snapshot");
    BOOL swiftInspection = operationSupported(@"swift.inspect");
    BOOL swiftValueInspection = swiftInspection && FUSwiftValueInspectionAvailable();
    BOOL uiAvailable = [ui[@"available"] boolValue];
    BOOL healthy = generationConsistent && flexAvailable && uiAvailable;

    return FUResponse(requestID, YES, @{
        @"healthy": [NSNumber numberWithBool:healthy],
        @"identity": @{
            @"pid": @(getpid()),
            @"bundle_id": NSBundle.mainBundle.bundleIdentifier ?: [NSNull null],
            @"process": NSProcessInfo.processInfo.processName ?: @"",
            @"generation": generation,
            @"agent_build": FU_AGENT_BUILD_ID,
        },
        @"agent_responsive": @YES,
        @"generation_consistent": [NSNumber numberWithBool:generationConsistent],
        @"current_generation": FUCurrentObjectGeneration(),
        @"flex": flex,
        @"operation_support": operationSupport,
        @"supported_operations": flex[@"supported_operations"] ?: @[],
        @"unsupported_operations": flex[@"unsupported_operations"] ?: @[],
        @"ui": ui,
        @"state": @{
            @"experiment": experimentStatus ?: @{},
            @"trace": traceStatus ?: @{},
            @"heap_busy": [NSNumber numberWithBool:heapBusy],
            @"keychain_busy": [NSNumber numberWithBool:keychainBusy],
        },
        @"capabilities": @{
            @"runtime_inspection": [NSNumber numberWithBool:runtimeInspection],
            @"ui_inspection": [NSNumber numberWithBool:operationSupported(@"ui.snapshot")],
            @"heap_inspection": [NSNumber numberWithBool:heapInspection],
            @"object_inspection": [NSNumber numberWithBool:objectInspection],
            @"swift_inspection": [NSNumber numberWithBool:swiftInspection],
            @"swift_value_inspection": [NSNumber numberWithBool:swiftValueInspection],
            @"tracing": @YES,
            @"reversible_experiments": @YES,
            @"investigate_screen": [NSNumber numberWithBool:operationSupported(@"investigate.screen")],
        },
    }, nil);
}

static NSDictionary *FUHandleRequest(NSDictionary *request) {
    return FUDispatchRequest(request, FU_AGENT_BUILD_ID, FUHandleTargetHealth);
}

static int FUConnectToDaemon(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

#ifdef SO_NOSIGPIPE
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
#endif

    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(FUDaemonPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void FUAgentLoop(void) {
    while (YES) {
        @autoreleasepool {
            int fd = FUConnectToDaemon();
            if (fd < 0) {
                [NSThread sleepForTimeInterval:2.0];
                continue;
            }
            uint64_t connectionGeneration = FUActivateAgentConnection(fd);

            NSDictionary *hello = @{
                @"v": @(FUProtocolVersion),
                @"kind": @"hello",
                @"role": @"agent",
                @"pid": @(getpid()),
                @"bundle_id": NSBundle.mainBundle.bundleIdentifier ?: [NSNull null],
                @"process": NSProcessInfo.processInfo.processName ?: @"",
                @"generation": FUCurrentObjectGeneration(),
                @"agent_build": FU_AGENT_BUILD_ID,
                @"capabilities": FUAgentCapabilities(),
            };

            if (!FUWriteAgentJSONLine(fd, connectionGeneration, hello, nil)) {
                FUCloseAgentConnection(fd, connectionGeneration);
                [NSThread sleepForTimeInterval:1.0];
                continue;
            }

            NSError *error = nil;
            NSDictionary *ack = FUReadJSONLine(fd, &error);
            if (![ack[@"ok"] boolValue]) {
                FUCloseAgentConnection(fd, connectionGeneration);
                [NSThread sleepForTimeInterval:1.0];
                continue;
            }

            while (YES) {
                @autoreleasepool {
                    NSDictionary *request = FUReadJSONLine(fd, &error);
                    if (!request) {
                        break;
                    }
                    NSString *operation = [request[@"op"] isKindOfClass:[NSString class]] ? request[@"op"] : @"";
                    NSString *requestID = [request[@"id"] isKindOfClass:[NSString class]] ? request[@"id"] : @"";

                    BOOL usesHeapWorker = FUOperationUsesHeapWorker(operation);
                    if (usesHeapWorker) {
                        if (!FUBeginHeapWorker()) {
                            NSDictionary *busyResponse = FUResponse(requestID,
                                                                    NO,
                                                                    nil,
                                                                    FUErrorInfo(@"heap_busy", @"A heap enumeration is already running in this target."));
                            if (!FUWriteAgentResponse(fd, connectionGeneration, operation, requestID, busyResponse)) {
                                break;
                            }
                            continue;
                        }

                        NSDictionary *heapRequest = [request copy];
                        NSInteger hardTimeoutMS = FUHeapHardTimeoutMS(heapRequest);
                        CFAbsoluteTime heapStarted = CFAbsoluteTimeGetCurrent();
                        dispatch_async(FUHeapWorkerQueue, ^{
                            @autoreleasepool {
                                dispatch_semaphore_t completed = dispatch_semaphore_create(0);
                                __block NSDictionary *response = nil;

                                dispatch_async(FUHeapExecutionQueue, ^{
                                    @autoreleasepool {
                                        @try {
                                            response = FUHandleRequest(heapRequest);
                                        } @catch (NSException *exception) {
                                            response = FUResponse(requestID,
                                                                  NO,
                                                                  nil,
                                                                  FUErrorInfo(@"heap_enumeration_failed",
                                                                              FUTruncatedString(exception.reason ?: exception.name, 1024)));
                                        } @finally {
                                            // A FLEX heap primitive may be monolithic and therefore
                                            // outlive the caller's deadline. Keep heap_busy asserted
                                            // until that primitive really unwinds so a timeout cannot
                                            // create overlapping malloc-zone scans in the target.
                                            FUEndHeapWorker();
                                            dispatch_semaphore_signal(completed);
                                        }
                                    }
                                });

                                dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
                                                                         (int64_t)hardTimeoutMS * NSEC_PER_MSEC);
                                if (dispatch_semaphore_wait(completed, deadline) == 0) {
                                    FUWriteAgentResponse(fd, connectionGeneration, operation, requestID, response ?: @{});
                                } else {
                                    NSDictionary *timeoutResponse = FUHeapHardTimeoutResponse(requestID,
                                                                                              operation,
                                                                                              hardTimeoutMS,
                                                                                              heapStarted);
                                    FUWriteAgentResponse(fd, connectionGeneration, operation, requestID, timeoutResponse);
                                }
                            }
                        });
                        continue;
                    }

                    BOOL usesKeychainWorker = [operation hasPrefix:@"keychain."];
                    if (usesKeychainWorker) {
                        if (!FUBeginKeychainWorker()) {
                            NSDictionary *busyResponse = FUResponse(requestID,
                                                                    NO,
                                                                    nil,
                                                                    FUErrorInfo(@"keychain_busy", @"A Keychain request is already running in this target."));
                            if (!FUWriteAgentResponse(fd, connectionGeneration, operation, requestID, busyResponse)) {
                                break;
                            }
                            continue;
                        }

                        NSDictionary *keychainRequest = [request copy];
                        CFAbsoluteTime keychainStarted = CFAbsoluteTimeGetCurrent();
                        dispatch_async(FUKeychainWorkerQueue, ^{
                            @autoreleasepool {
                                dispatch_semaphore_t completed = dispatch_semaphore_create(0);
                                __block NSDictionary *response = nil;

                                dispatch_async(FUKeychainExecutionQueue, ^{
                                    @autoreleasepool {
                                        @try {
                                            response = FUHandleRequest(keychainRequest);
                                        } @catch (NSException *exception) {
                                            response = FUResponse(requestID,
                                                                  NO,
                                                                  nil,
                                                                  FUErrorInfo(@"keychain_failed",
                                                                              FUTruncatedString(exception.reason ?: exception.name, 1024)));
                                        } @finally {
                                            // FLEXKeychain can block inside Security.framework on
                                            // some runtimes. Keep the gate asserted until the
                                            // underlying call really unwinds so later requests
                                            // cannot stack more blocked Keychain workers.
                                            FUEndKeychainWorker();
                                            dispatch_semaphore_signal(completed);
                                        }
                                    }
                                });

                                dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
                                                                         (int64_t)FUKeychainHardTimeoutMS * NSEC_PER_MSEC);
                                if (dispatch_semaphore_wait(completed, deadline) == 0) {
                                    FUWriteAgentResponse(fd, connectionGeneration, operation, requestID, response ?: @{});
                                } else {
                                    NSDictionary *timeoutResponse = FUKeychainHardTimeoutResponse(requestID,
                                                                                                  operation,
                                                                                                  keychainStarted);
                                    FUWriteAgentResponse(fd, connectionGeneration, operation, requestID, timeoutResponse);
                                }
                            }
                        });
                        continue;
                    }

                    BOOL suppressTraceManagement = [operation hasPrefix:@"trace."];
                    bool previousSuppression = false;
                    if (suppressTraceManagement) {
                        previousSuppression = objsee_message_interception_set_thread_suppressed(true);
                    }
                    NSDictionary *response = FUHandleRequest(request);
                    if (suppressTraceManagement) {
                        objsee_message_interception_set_thread_suppressed(previousSuppression);
                    }
                    if (!FUWriteAgentResponse(fd, connectionGeneration, operation, requestID, response)) {
                        break;
                    }
                }
            }

            FUCloseAgentConnection(fd, connectionGeneration);
        }

        [NSThread sleepForTimeInterval:1.0];
    }
}

__attribute__((constructor)) static void FUAgentInitialize(void) {
    @autoreleasepool {
        if (!FUIsEligibleProcess()) {
            return;
        }

        FUUIConfigureExperimentCallbacks(FUExperimentPrepareMutation, FUExperimentAbortMutation, FUExperimentCommitMutation);
        FURuntimeConfigure(FUObjectReference, FUPropertyEntry, FUIvarEntry, FUMethodEntry);
        FUStorageConfigure(FUFlexStatus, FUJSONValue);
        FUHeapConfigure(FUFlexStatus, FUObjectReference, FUObjectTargetFromRequest);

        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FUAgentStartupDelayMs * NSEC_PER_MSEC)), queue, ^{
            @autoreleasepool {
                // Re-check after launch settles in case the injected image was
                // loaded while bundle/process state was still being established.
                if (FUIsEligibleProcess()) {
                    FUAgentLoop();
                }
            }
        });
    }
}
