#import "FUTrace.h"

#import <dispatch/dispatch.h>

#import "FUProtocol.h"
#import "tracer.h"
#import "tracer_types.h"

static NSObject *FUTraceLock;
static tracer_t *FUTraceTracer = NULL;
static NSMutableArray<NSDictionary *> *FUTraceEvents;
static NSDictionary *FUTraceFilters;
static NSString *FUTraceArgumentDetail;
static NSString *FUTraceSessionID;
static NSUInteger FUTraceMaxEvents = 500;
static NSUInteger FUTraceMaxDurationMs = 30000;
static uint64_t FUTraceMaxTotalEvents = 5000;
static uint64_t FUTraceNextSequence = 1;
static uint64_t FUTraceTotalSeen = 0;
static uint64_t FUTraceDropped = 0;
static uint64_t FUTraceInterceptionBaseline = 0;
static uint64_t FUTraceInterceptionDiagnosticBaseline[12] = {0};
static NSTimeInterval FUTraceStartedAt = 0;
static NSTimeInterval FUTraceStoppedAt = 0;
static NSString *FUTraceStopReason;
static BOOL FUTraceActive = NO;
static BOOL FUTraceAutoStopScheduled = NO;
static dispatch_queue_t FUTraceControlQueue;
static _Thread_local BOOL FUTraceInCallback = NO;

extern uint64_t objsee_message_interception_count(void);
extern uint64_t objsee_message_interception_diagnostic_count(uint32_t index);
extern bool objsee_message_interception_set_thread_suppressed(bool suppressed);

static NSString *FUTraceTruncatedString(NSString *string, NSUInteger limit) {
    if (![string isKindOfClass:[NSString class]]) {
        return @"";
    }
    if (string.length <= limit) {
        return string;
    }
    return [[string substringToIndex:limit] stringByAppendingString:@"…"];
}

static NSArray<NSString *> *FUTraceInterceptionDiagnosticNames(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[
            @"tracer_null",
            @"tracer_changed",
            @"context_null",
            @"stack_depth",
            @"implausible_self",
            @"implausible_cmd",
            @"selector_null",
            @"selector_denied",
            @"invalid_class",
            @"unrealized_class",
            @"policy_rejected",
            @"policy_accepted",
        ];
    });
    return names;
}

static NSDictionary *FUTraceInterceptionDiagnostics(void) {
    NSArray<NSString *> *names = FUTraceInterceptionDiagnosticNames();
    NSMutableDictionary *diagnostics = [NSMutableDictionary dictionaryWithCapacity:names.count];
    for (NSUInteger index = 0; index < names.count; index++) {
        uint64_t current = objsee_message_interception_diagnostic_count((uint32_t)index);
        diagnostics[names[index]] = @(current - FUTraceInterceptionDiagnosticBaseline[index]);
    }
    return diagnostics;
}

static void FUInitializeTraceState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FUTraceLock = [NSObject new];
        FUTraceEvents = [NSMutableArray array];
        FUTraceFilters = @{};
        FUTraceArgumentDetail = @"none";
        FUTraceControlQueue = dispatch_queue_create("moe.waru.flexultra.trace-control", DISPATCH_QUEUE_SERIAL);
    });
}

static NSString *FUTraceCString(const char *value, NSUInteger limit) {
    if (!value) return @"";
    NSString *string = [NSString stringWithUTF8String:value];
    if (!string) return @"";
    return FUTraceTruncatedString(string, limit);
}

// Caller must hold FUTraceLock. Auto-stop work is always dispatched away from
// ObjSee's output callback so tracer_stop/tracer_cleanup cannot tear down the
// tracer while that callback is still consuming one of its events.
static BOOL FUTraceStopLocked(NSString *reason, NSString **errorMessage) {
    if (!FUTraceTracer || !FUTraceActive) return NO;
    tracer_t *tracer = FUTraceTracer;
    tracer_result_t stopResult = tracer_stop(tracer);
    if (stopResult != TRACER_SUCCESS) {
        if (errorMessage) {
            NSString *message = FUTraceCString(tracer_get_last_error(tracer), 1024);
            *errorMessage = message.length ? message : @"ObjSee failed to stop tracing.";
        }
        return NO;
    }
    FUTraceActive = NO;
    FUTraceTracer = NULL;
    FUTraceStoppedAt = NSDate.date.timeIntervalSince1970;
    FUTraceStopReason = reason.length ? [reason copy] : @"explicit";
    FUTraceAutoStopScheduled = NO;
    tracer_cleanup(tracer);
    return YES;
}

static void FUTraceStopSessionIfActive(NSString *sessionID, NSString *reason) {
    FUInitializeTraceState();
    @synchronized (FUTraceLock) {
        if (!FUTraceActive || !FUTraceTracer || ![FUTraceSessionID isEqualToString:sessionID]) return;
        if (!FUTraceStopLocked(reason, NULL)) {
            // Permit a later matching event or explicit stop to retry if ObjSee
            // transiently refuses an automatic stop.
            FUTraceAutoStopScheduled = NO;
        }
    }
}

static void FUTraceScheduleEventBudgetStopLocked(void) {
    if (FUTraceAutoStopScheduled || !FUTraceActive || !FUTraceTracer || FUTraceSessionID.length == 0) return;
    FUTraceAutoStopScheduled = YES;
    NSString *sessionID = [FUTraceSessionID copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_MSEC)), FUTraceControlQueue, ^{
        FUTraceStopSessionIfActive(sessionID, @"max_total_events");
    });
}

static NSDictionary *FUTraceStatusLocked(void) {
    NSNumber *firstSequence = FUTraceEvents.count ? FUTraceEvents.firstObject[@"sequence"] : nil;
    NSNumber *lastSequence = FUTraceEvents.count ? FUTraceEvents.lastObject[@"sequence"] : nil;
    NSMutableDictionary *status = [@{
        @"active": @(FUTraceActive),
        @"session_id": FUTraceSessionID ?: @"",
        @"argument_detail": FUTraceArgumentDetail ?: @"none",
        @"max_events": @(FUTraceMaxEvents),
        @"max_duration_ms": @(FUTraceMaxDurationMs),
        @"max_total_events": @(FUTraceMaxTotalEvents),
        @"total_seen": @(FUTraceTotalSeen),
        @"recorded": @(FUTraceEvents.count),
        @"dropped": @(FUTraceDropped),
        @"intercepted_calls": @(objsee_message_interception_count() - FUTraceInterceptionBaseline),
        @"interception_diagnostics": FUTraceInterceptionDiagnostics(),
        @"filters": FUTraceFilters ?: @{},
    } mutableCopy];
    if (FUTraceStartedAt > 0) {
        NSTimeInterval endedAt = FUTraceActive ? NSDate.date.timeIntervalSince1970 : (FUTraceStoppedAt > 0 ? FUTraceStoppedAt : NSDate.date.timeIntervalSince1970);
        status[@"started_at_unix_ms"] = @((uint64_t)(FUTraceStartedAt * 1000.0));
        status[@"duration_ms"] = @((uint64_t)(MAX(0.0, endedAt - FUTraceStartedAt) * 1000.0));
    }
    if (FUTraceStoppedAt > 0) status[@"stopped_at_unix_ms"] = @((uint64_t)(FUTraceStoppedAt * 1000.0));
    if (FUTraceStopReason.length) status[@"stop_reason"] = FUTraceStopReason;
    if (firstSequence) status[@"first_sequence"] = firstSequence;
    if (lastSequence) status[@"last_sequence"] = lastSequence;
    return status;
}

NSDictionary *FUTraceStatusSnapshot(void) {
    FUInitializeTraceState();
    @synchronized (FUTraceLock) {
        return FUTraceStatusLocked();
    }
}

static void FUTraceEventHandler(const tracer_event_t *event, void *context) {
    (void)context;
    if (!event || FUTraceInCallback) return;
    FUTraceInCallback = YES;
    bool previousSuppression = objsee_message_interception_set_thread_suppressed(true);
    @try {
        @autoreleasepool {
            FUInitializeTraceState();
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            NSString *className = FUTraceCString(event->class_name, 512);
            NSString *methodName = FUTraceCString(event->method_name, 1024);
            if (className.length) entry[@"class"] = className;
            if (methodName.length) entry[@"method"] = methodName;
            entry[@"is_class_method"] = @(event->is_class_method);
            entry[@"thread_id"] = @(event->thread_id);
            entry[@"trace_depth"] = @(event->trace_depth);
            entry[@"real_depth"] = @(event->real_depth);
            NSString *imagePath = FUTraceCString(event->image_path, 2048);
            if (imagePath.length) entry[@"image"] = imagePath;
            NSString *signature = FUTraceCString(event->method_signature, 1024);
            if (signature.length) entry[@"signature"] = signature;

            if (event->caller.class_name || event->caller.method_name || event->caller.image_path) {
                NSMutableDictionary *caller = [NSMutableDictionary dictionary];
                NSString *callerClass = FUTraceCString(event->caller.class_name, 512);
                NSString *callerMethod = FUTraceCString(event->caller.method_name, 1024);
                NSString *callerImage = FUTraceCString(event->caller.image_path, 2048);
                if (callerClass.length) caller[@"class"] = callerClass;
                if (callerMethod.length) caller[@"method"] = callerMethod;
                if (callerImage.length) caller[@"image"] = callerImage;
                caller[@"is_class_method"] = @(event->caller.is_class_method);
                entry[@"caller"] = caller;
            }

            if (event->argument_count > 0 && event->arguments) {
                NSUInteger count = MIN((NSUInteger)event->argument_count, (NSUInteger)16);
                NSMutableArray *arguments = [NSMutableArray arrayWithCapacity:count];
                for (NSUInteger index = 0; index < count; index++) {
                    tracer_argument_t *argument = &event->arguments[index];
                    NSMutableDictionary *item = [@{
                        @"index": @(index),
                        @"address": [NSString stringWithFormat:@"%p", argument->address],
                        @"size": @((uint64_t)argument->size),
                    } mutableCopy];
                    NSString *typeEncoding = FUTraceCString(argument->type_encoding, 256);
                    NSString *objcClass = FUTraceCString(argument->objc_class_name, 512);
                    NSString *blockSignature = FUTraceCString(argument->block_signature, 512);
                    if (typeEncoding.length) item[@"type_encoding"] = typeEncoding;
                    if (objcClass.length) item[@"objc_class"] = objcClass;
                    if (blockSignature.length) item[@"block_signature"] = blockSignature;
                    [arguments addObject:item];
                }
                entry[@"arguments"] = arguments;
                entry[@"argument_count"] = @((uint64_t)event->argument_count);
                if ((NSUInteger)event->argument_count > count) entry[@"arguments_truncated"] = @YES;
            }

            @synchronized (FUTraceLock) {
                if (FUTraceActive) {
                    if (FUTraceTotalSeen < FUTraceMaxTotalEvents) {
                        entry[@"sequence"] = @(FUTraceNextSequence++);
                        FUTraceTotalSeen++;
                        if (FUTraceEvents.count >= FUTraceMaxEvents) {
                            [FUTraceEvents removeObjectAtIndex:0];
                            FUTraceDropped++;
                        }
                        [FUTraceEvents addObject:entry];
                    }
                    if (FUTraceTotalSeen >= FUTraceMaxTotalEvents) FUTraceScheduleEventBudgetStopLocked();
                }
            }
        }
    } @catch (__unused NSException *exception) {
    } @finally {
        objsee_message_interception_set_thread_suppressed(previousSuppression);
        FUTraceInCallback = NO;
    }
}

static NSArray<NSString *> *FUTraceStringArray(NSDictionary *request, NSString *key, NSString **error) {
    id value = request[key];
    if (!value) return @[];
    if (![value isKindOfClass:[NSArray class]]) {
        if (error) *error = [NSString stringWithFormat:@"%@ must be an array of non-empty strings.", key];
        return nil;
    }
    NSMutableArray *result = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:[NSString class]] || [item length] == 0) {
            if (error) *error = [NSString stringWithFormat:@"%@ must contain only non-empty strings.", key];
            return nil;
        }
        [result addObject:item];
    }
    return result;
}

static NSArray<NSDictionary *> *FUTracePatternArray(NSDictionary *request, NSString *key, NSString **error) {
    id value = request[key];
    if (!value) return @[];
    if (![value isKindOfClass:[NSArray class]]) {
        if (error) *error = [NSString stringWithFormat:@"%@ must be an array of {class, method} objects.", key];
        return nil;
    }
    NSMutableArray *result = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        NSString *classPattern = [item isKindOfClass:[NSDictionary class]] && [item[@"class"] isKindOfClass:[NSString class]] ? item[@"class"] : nil;
        NSString *methodPattern = [item isKindOfClass:[NSDictionary class]] && [item[@"method"] isKindOfClass:[NSString class]] ? item[@"method"] : nil;
        if (classPattern.length == 0 || methodPattern.length == 0) {
            if (error) *error = [NSString stringWithFormat:@"%@ entries require non-empty class and method strings.", key];
            return nil;
        }
        [result addObject:@{ @"class": classPattern, @"method": methodPattern }];
    }
    return result;
}

NSDictionary *FUHandleTraceStatus(NSString *requestID) {
    return FUResponse(requestID, YES, FUTraceStatusSnapshot(), nil);
}

NSDictionary *FUHandleTraceStart(NSString *requestID, NSDictionary *request) {
    FUInitializeTraceState();
    NSString *validationError = nil;
    NSArray *includeClasses = FUTraceStringArray(request, @"include_classes", &validationError);
    NSArray *includeMethods = FUTraceStringArray(request, @"include_methods", &validationError);
    NSArray *includeImages = FUTraceStringArray(request, @"include_images", &validationError);
    NSArray *includePatterns = FUTracePatternArray(request, @"include_patterns", &validationError);
    NSArray *excludeClasses = FUTraceStringArray(request, @"exclude_classes", &validationError);
    NSArray *excludeMethods = FUTraceStringArray(request, @"exclude_methods", &validationError);
    NSArray *excludeImages = FUTraceStringArray(request, @"exclude_images", &validationError);
    NSArray *excludePatterns = FUTracePatternArray(request, @"exclude_patterns", &validationError);
    if (validationError) return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", validationError));
    NSUInteger includeCount = includeClasses.count + includeMethods.count + includeImages.count + includePatterns.count;
    NSUInteger filterCount = includeCount + excludeClasses.count + excludeMethods.count + excludeImages.count + excludePatterns.count;
    if (includeCount == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"include_filter_required", @"trace.start requires at least one include class, method, image, or class+method pattern."));
    }
    if (filterCount > TRACER_MAX_FILTERS) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"too_many_filters", [NSString stringWithFormat:@"ObjSee supports at most %d total trace filters.", TRACER_MAX_FILTERS]));
    }
    NSString *argumentDetail = [request[@"argument_detail"] isKindOfClass:[NSString class]] ? request[@"argument_detail"] : @"none";
    tracer_argument_format_t argumentFormat = TRACER_ARG_FORMAT_NONE;
    if ([argumentDetail isEqualToString:@"basic"]) argumentFormat = TRACER_ARG_FORMAT_BASIC;
    else if ([argumentDetail isEqualToString:@"class"]) argumentFormat = TRACER_ARG_FORMAT_CLASS;
    else if (![argumentDetail isEqualToString:@"none"]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_argument_detail", @"argument_detail must be none, basic, or class."));
    }
    NSInteger requestedMax = [request[@"max_events"] respondsToSelector:@selector(integerValue)] ? [request[@"max_events"] integerValue] : 500;
    NSUInteger maxEvents = (NSUInteger)MIN(MAX(requestedMax, 100), 5000);
    NSInteger requestedDuration = [request[@"max_duration_ms"] respondsToSelector:@selector(integerValue)] ? [request[@"max_duration_ms"] integerValue] : 30000;
    NSUInteger maxDurationMs = (NSUInteger)MIN(MAX(requestedDuration, 100), 300000);
    long long requestedTotal = [request[@"max_total_events"] respondsToSelector:@selector(longLongValue)] ? [request[@"max_total_events"] longLongValue] : 5000;
    uint64_t maxTotalEvents = (uint64_t)MIN(MAX(requestedTotal, 1LL), 50000LL);

    @synchronized (FUTraceLock) {
        if (FUTraceActive || FUTraceTracer) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"trace_already_active", @"Only one ObjSee trace session may run in a process at a time."));
        }

        tracer_error_t *createError = NULL;
        tracer_config_t tracerConfig = {0};
        // Modern arm64e processes can route Objective-C call sites around an
        // inline-patched objc_msgSend entry. Rebind each image's imported
        // objc_msgSend pointer instead so FlexUltra observes those call sites.
        tracerConfig.use_symbol_rebinding = true;
        tracer_t *tracer = tracer_create_with_config(tracerConfig, &createError);
        if (!tracer) {
            NSString *message = createError ? FUTraceCString(createError->message, 1024) : @"ObjSee could not create a tracer.";
            if (createError) free_error(createError);
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"trace_create_failed", message));
        }
        if (createError) free_error(createError);

        tracer_format_options_t format = {0};
        format.include_event_json = true;
        format.output_as_json = true;
        format.include_caller_info = true;
        format.args = argumentFormat;
        tracer_set_format_options(tracer, format);
        tracer_set_output_handler(tracer, FUTraceEventHandler, NULL);

        for (NSString *pattern in includeClasses) tracer_include_class(tracer, pattern.UTF8String);
        for (NSString *pattern in includeMethods) tracer_include_method(tracer, pattern.UTF8String);
        for (NSString *pattern in includeImages) tracer_include_image(tracer, pattern.UTF8String);
        for (NSDictionary *pattern in includePatterns) tracer_include_pattern(tracer, [pattern[@"class"] UTF8String], [pattern[@"method"] UTF8String]);
        for (NSString *pattern in excludeClasses) tracer_exclude_class(tracer, pattern.UTF8String);
        for (NSString *pattern in excludeMethods) tracer_exclude_method(tracer, pattern.UTF8String);
        for (NSString *pattern in excludeImages) tracer_exclude_image(tracer, pattern.UTF8String);
        for (NSDictionary *pattern in excludePatterns) tracer_exclude_pattern(tracer, [pattern[@"class"] UTF8String], [pattern[@"method"] UTF8String]);

        FUTraceMaxEvents = maxEvents;
        FUTraceMaxDurationMs = maxDurationMs;
        FUTraceMaxTotalEvents = maxTotalEvents;
        FUTraceArgumentDetail = argumentDetail;
        FUTraceSessionID = NSUUID.UUID.UUIDString;
        FUTraceNextSequence = 1;
        FUTraceTotalSeen = 0;
        FUTraceDropped = 0;
        FUTraceStartedAt = NSDate.date.timeIntervalSince1970;
        FUTraceStoppedAt = 0;
        FUTraceStopReason = nil;
        FUTraceAutoStopScheduled = NO;
        [FUTraceEvents removeAllObjects];
        FUTraceFilters = @{
            @"include_classes": includeClasses, @"include_methods": includeMethods, @"include_images": includeImages, @"include_patterns": includePatterns,
            @"exclude_classes": excludeClasses, @"exclude_methods": excludeMethods, @"exclude_images": excludeImages, @"exclude_patterns": excludePatterns,
        };
        FUTraceTracer = tracer;
        tracer_result_t startResult = tracer_start(tracer);
        if (startResult != TRACER_SUCCESS) {
            NSString *message = FUTraceCString(tracer_get_last_error(tracer), 1024);
            FUTraceTracer = NULL;
            tracer_cleanup(tracer);
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"trace_start_failed", message.length ? message : @"ObjSee failed to start tracing."));
        }
        FUTraceInterceptionBaseline = objsee_message_interception_count();
        for (NSUInteger index = 0; index < 12; index++) {
            FUTraceInterceptionDiagnosticBaseline[index] = objsee_message_interception_diagnostic_count((uint32_t)index);
        }
        FUTraceActive = YES;
        NSString *sessionID = [FUTraceSessionID copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FUTraceMaxDurationMs * NSEC_PER_MSEC)), FUTraceControlQueue, ^{
            FUTraceStopSessionIfActive(sessionID, @"max_duration");
        });
        return FUResponse(requestID, YES, FUTraceStatusLocked(), nil);
    }
}

NSDictionary *FUHandleTraceEvents(NSString *requestID, NSDictionary *request) {
    FUInitializeTraceState();
    NSInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(integerValue)] ? [request[@"limit"] integerValue] : 100;
    if (requestedLimit <= 0) return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"limit must be greater than zero."));
    NSUInteger limit = (NSUInteger)MIN(requestedLimit, 500);
    NSInteger requestedOffset = [request[@"offset"] respondsToSelector:@selector(integerValue)] ? [request[@"offset"] integerValue] : 0;
    if (requestedOffset < 0) return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be zero or greater."));
    uint64_t afterSequence = [request[@"after_sequence"] respondsToSelector:@selector(unsignedLongLongValue)] ? [request[@"after_sequence"] unsignedLongLongValue] : 0;

    @synchronized (FUTraceLock) {
        NSMutableArray *matching = [NSMutableArray array];
        for (NSDictionary *event in FUTraceEvents) {
            if ([event[@"sequence"] unsignedLongLongValue] > afterSequence) [matching addObject:event];
        }
        NSUInteger offset = MIN((NSUInteger)requestedOffset, matching.count);
        NSUInteger count = MIN(limit, matching.count - offset);
        NSArray *events = count ? [matching subarrayWithRange:NSMakeRange(offset, count)] : @[];
        return FUResponse(requestID, YES, @{
            @"session_id": FUTraceSessionID ?: @"",
            @"events": events,
            @"offset": @(offset),
            @"limit": @(limit),
            @"matched": @(matching.count),
            @"has_more": @(offset + count < matching.count),
            @"status": FUTraceStatusLocked(),
        }, nil);
    }
}

NSDictionary *FUHandleTraceStop(NSString *requestID) {
    FUInitializeTraceState();
    @synchronized (FUTraceLock) {
        if (!FUTraceTracer || !FUTraceActive) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"trace_not_active", @"No ObjSee trace session is active in this process."));
        }
        NSString *message = nil;
        if (!FUTraceStopLocked(@"explicit", &message)) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"trace_stop_failed", message.length ? message : @"ObjSee failed to stop tracing."));
        }
        return FUResponse(requestID, YES, FUTraceStatusLocked(), nil);
    }
}
