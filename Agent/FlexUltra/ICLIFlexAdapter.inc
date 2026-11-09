
// icli owns selection and transport. Initialize the original callback graph
// only after an explicit full-engine request, never from a constructor.
extern void ICLIFlexAdoptGeneration(NSString *generation);

static void ICLIFlexInitialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FUInitializeAgentConcurrency();
        FUUIConfigureExperimentCallbacks(FUExperimentPrepareMutation, FUExperimentAbortMutation, FUExperimentCommitMutation);
        FURuntimeConfigure(FUObjectReference, FUPropertyEntry, FUIvarEntry, FUMethodEntry);
        FUStorageConfigure(FUFlexStatus, FUJSONValue);
        FUHeapConfigure(FUFlexStatus, FUObjectReference, FUObjectTargetFromRequest);
    });
}

static NSDictionary *ICLIFlexPerform(NSDictionary *request) {
    ICLIFlexInitialize();
    static dispatch_once_t generationOnce;
    dispatch_once(&generationOnce, ^{ ICLIFlexAdoptGeneration(request[@"_icli_generation"]); });
    NSString *requestID = request[@"id"] ?: @"";
    id expected = request[@"expected_generation"];
    if (expected && (![expected isKindOfClass:NSString.class] || ![expected length]))
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"expected_generation must be a non-empty string."));
    if (expected && ![expected isEqual:FUCurrentObjectGeneration()]) {
        NSMutableDictionary *error = [FUErrorInfo(@"target_generation_changed", @"The app process changed; discover it again and acquire fresh handles.") mutableCopy];
        error[@"expected_generation"] = expected;
        error[@"actual_generation"] = FUCurrentObjectGeneration();
        return FUResponse(requestID, NO, nil, error);
    }
    NSString *op = [request[@"op"] isKindOfClass:NSString.class] ? request[@"op"] : @"";
    BOOL heap = FUOperationUsesHeapWorker(op), keychain = [op hasPrefix:@"keychain."];
    if (heap || keychain) {
        BOOL began = heap ? FUBeginHeapWorker() : FUBeginKeychainWorker();
        if (!began) return FUResponse(requestID, NO, nil, FUErrorInfo(heap ? @"heap_busy" : @"keychain_busy", @"A previous request is still running in this app."));
        dispatch_semaphore_t completed = dispatch_semaphore_create(0);
        NSObject *lock = [NSObject new];
        __block NSDictionary *answer = nil;
        dispatch_queue_t queue = heap ? FUHeapExecutionQueue : FUKeychainExecutionQueue;
        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        dispatch_async(queue, ^{
            @autoreleasepool {
                @try {
                    NSDictionary *reply = FUHandleRequest(request);
                    @synchronized (lock) { answer = reply; }
                } @catch (NSException *exception) {
                    @synchronized (lock) { answer = FUResponse(requestID, NO, nil, FUErrorInfo(@"operation_failed", exception.reason ?: exception.name)); }
                } @finally {
                    if (heap) FUEndHeapWorker(); else FUEndKeychainWorker();
                    dispatch_semaphore_signal(completed);
                }
            }
        });
        NSInteger timeout = heap ? FUHeapHardTimeoutMS(request) : FUKeychainHardTimeoutMS;
        dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout * NSEC_PER_MSEC));
        @synchronized (lock) { if (answer) return answer; }
        return heap ? FUHeapHardTimeoutResponse(requestID, op, timeout, started) : FUKeychainHardTimeoutResponse(requestID, op, started);
    }
    BOOL suppress = [op hasPrefix:@"trace."];
    bool previous = suppress ? objsee_message_interception_set_thread_suppressed(true) : false;
    @try { return FUHandleRequest(request); }
    @finally { if (suppress) objsee_message_interception_set_thread_suppressed(previous); }
}

__attribute__((visibility("default"))) char *icli_flexultra_request_json(const char *source) {
    @autoreleasepool {
        NSDictionary *request = nil, *response = nil;
        @try {
            request = [NSJSONSerialization JSONObjectWithData:[@(source) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (![request isKindOfClass:NSDictionary.class]) response = FUResponse(@"", NO, nil, FUErrorInfo(@"invalid_request", @"One request object is required."));
            else response = ICLIFlexPerform(request);
        } @catch (NSException *exception) {
            response = FUResponse(request[@"id"] ?: @"", NO, nil, FUErrorInfo(@"operation_failed", exception.reason ?: exception.name));
        }
        if ([response isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *identified = [response mutableCopy];
            identified[@"generation"] = FUCurrentObjectGeneration();
            identified[@"agent_build"] = FU_AGENT_BUILD_ID;
            response = identified;
        }
        NSData *data = nil;
        @try {
            if ([NSJSONSerialization isValidJSONObject:response])
                data = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingSortedKeys error:nil];
        } @catch (NSException *exception) { (void)exception; }
        if (!data) {
            response = FUResponse(request[@"id"] ?: @"", NO, nil, FUErrorInfo(@"response_serialization_failed", @"The operation returned non-JSON data."));
            data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
        }
        return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    }
}
