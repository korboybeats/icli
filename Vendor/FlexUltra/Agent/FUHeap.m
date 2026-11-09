#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#import <stdlib.h>
#import <string.h>

#import "FUHeap.h"
#import "FUProtocol.h"

static FUHeapFlexStatusProvider FUHeapFlexStatusProviderCallback = NULL;
static FUHeapObjectReferenceProvider FUHeapObjectReferenceProviderCallback = NULL;
static FUHeapObjectTargetProvider FUHeapObjectTargetProviderCallback = NULL;

void FUHeapConfigure(FUHeapFlexStatusProvider flexStatusProvider,
                     FUHeapObjectReferenceProvider objectReferenceProvider,
                     FUHeapObjectTargetProvider objectTargetProvider) {
    FUHeapFlexStatusProviderCallback = flexStatusProvider;
    FUHeapObjectReferenceProviderCallback = objectReferenceProvider;
    FUHeapObjectTargetProviderCallback = objectTargetProvider;
}

static NSDictionary *FUHeapFlexStatus(BOOL loadIfNeeded) {
    if (!FUHeapFlexStatusProviderCallback) {
        return @{ @"available": @NO };
    }
    NSDictionary *status = FUHeapFlexStatusProviderCallback(loadIfNeeded);
    return [status isKindOfClass:[NSDictionary class]] ? status : @{ @"available": @NO };
}

static NSDictionary *FUHeapObjectReference(id object) {
    if (!object || !FUHeapObjectReferenceProviderCallback) {
        return @{};
    }
    NSDictionary *reference = FUHeapObjectReferenceProviderCallback(object);
    return [reference isKindOfClass:[NSDictionary class]] ? reference : @{};
}

static id FUHeapObjectTargetFromRequest(NSString *requestID, NSDictionary *request, NSString **resolvedHandle, NSString **targetSource, NSString **resolvedBy, NSDictionary **errorResponse) {
    if (!FUHeapObjectTargetProviderCallback) {
        if (errorResponse) {
            *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"heap_unconfigured", @"Heap inspection is not configured in this target process."));
        }
        return nil;
    }
    return FUHeapObjectTargetProviderCallback(requestID, request, resolvedHandle, targetSource, resolvedBy, errorResponse);
}

static BOOL FURequestPagination(NSDictionary *request, NSUInteger *offset, NSUInteger *limit) {
    NSInteger requestedOffset = [request[@"offset"] respondsToSelector:@selector(integerValue)] ? [request[@"offset"] integerValue] : 0;
    NSInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(integerValue)] ? [request[@"limit"] integerValue] : 100;
    if (requestedOffset < 0 || requestedLimit <= 0) {
        return NO;
    }
    *offset = (NSUInteger)requestedOffset;
    *limit = MIN((NSUInteger)requestedLimit, (NSUInteger)1000);
    return YES;
}

static id FUObjectMessage(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSString *FUClassName(id object) {
    if (!object) {
        return @"";
    }
    if (object_isClass(object)) {
        return NSStringFromClass((Class)object) ?: @"";
    }
    return NSStringFromClass([object class]) ?: @"";
}

static NSString *FUTruncatedString(NSString *string, NSUInteger limit) {
    if (![string isKindOfClass:[NSString class]]) {
        return @"";
    }
    if (string.length <= limit) {
        return string;
    }
    return [[string substringToIndex:limit] stringByAppendingString:@"…"];
}

static Class FUHeapEnumeratorClass(NSString *requestID, NSDictionary **errorResponse) {
    if (![FUHeapFlexStatus(YES)[@"available"] boolValue]) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for heap discovery."));
        return Nil;
    }

    Class heapClass = NSClassFromString(@"FLEXHeapEnumerator");
    if (!heapClass) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXHeapEnumerator."));
        return Nil;
    }
    return heapClass;
}

static id FUHeapUnderlyingObject(id item) {
    if (!item) {
        return nil;
    }

    Class refClass = NSClassFromString(@"FLEXObjectRef");
    if (refClass && [item isKindOfClass:refClass]) {
        return FUObjectMessage(item, @"object");
    }
    return item;
}

typedef struct {
    ptrdiff_t offset;
    const char *name;
} FUHeapIvarSlot;

typedef struct {
    NSUInteger count;
    FUHeapIvarSlot *slots;
} FUHeapIvarLayout;

static BOOL FUHeapTypeEncodingIsObjectOrClass(const char *encoding) {
    if (!encoding) return NO;
    while (*encoding == 'r' || *encoding == 'n' || *encoding == 'N' || *encoding == 'o' ||
           *encoding == 'O' || *encoding == 'R' || *encoding == 'V') {
        encoding++;
    }
    return *encoding == '@' || *encoding == '#';
}

static FUHeapIvarLayout *FUCreateHeapIvarLayout(Class actualClass) {
    if (!actualClass) return NULL;

    FUHeapIvarLayout *layout = calloc(1, sizeof(FUHeapIvarLayout));
    if (!layout) return NULL;

    NSUInteger capacity = 0;
    for (Class cls = actualClass; cls; cls = class_getSuperclass(cls)) {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        for (unsigned int index = 0; index < ivarCount; index++) {
            Ivar ivar = ivars[index];
            if (!FUHeapTypeEncodingIsObjectOrClass(ivar_getTypeEncoding(ivar))) {
                continue;
            }

            if (layout->count == capacity) {
                NSUInteger nextCapacity = capacity ? capacity * 2 : 8;
                FUHeapIvarSlot *resized = realloc(layout->slots, nextCapacity * sizeof(FUHeapIvarSlot));
                if (!resized) {
                    free(ivars);
                    free(layout->slots);
                    free(layout);
                    return NULL;
                }
                layout->slots = resized;
                capacity = nextCapacity;
            }

            layout->slots[layout->count++] = (FUHeapIvarSlot){
                .offset = ivar_getOffset(ivar),
                .name = ivar_getName(ivar) ?: "???",
            };
        }
        free(ivars);
    }
    return layout;
}

static void FUFreeHeapIvarLayouts(CFMutableDictionaryRef layouts) {
    if (!layouts) return;
    CFIndex count = CFDictionaryGetCount(layouts);
    if (count > 0) {
        const void **values = calloc((size_t)count, sizeof(void *));
        if (values) {
            CFDictionaryGetKeysAndValues(layouts, NULL, values);
            for (CFIndex index = 0; index < count; index++) {
                FUHeapIvarLayout *layout = (FUHeapIvarLayout *)values[index];
                if (layout) {
                    free(layout->slots);
                    free(layout);
                }
            }
            free(values);
        }
    }
    CFRelease(layouts);
}

static const NSInteger FUHeapTimeoutDefaultMS = 60000;
static const NSInteger FUHeapTimeoutMaxMS = 110000;

typedef struct {
    CFAbsoluteTime started;
    CFAbsoluteTime deadline;
    NSInteger timeoutMS;
} FUHeapDeadline;

static BOOL FUHeapDeadlineFromRequest(NSString *requestID,
                                      NSDictionary *request,
                                      FUHeapDeadline *deadlineOut,
                                      NSDictionary **errorResponse) {
    id timeoutValue = request[@"timeout_ms"];
    if (timeoutValue && ![timeoutValue respondsToSelector:@selector(integerValue)]) {
        if (errorResponse) {
            *errorResponse = FUResponse(requestID, NO, nil,
                                        FUErrorInfo(@"invalid_heap_timeout",
                                                    @"timeout_ms must be an integer between 1 and 110000."));
        }
        return NO;
    }

    NSInteger timeoutMS = timeoutValue ? [timeoutValue integerValue] : FUHeapTimeoutDefaultMS;
    if (timeoutMS < 1 || timeoutMS > FUHeapTimeoutMaxMS) {
        if (errorResponse) {
            *errorResponse = FUResponse(requestID, NO, nil,
                                        FUErrorInfo(@"invalid_heap_timeout",
                                                    @"timeout_ms must be between 1 and 110000."));
        }
        return NO;
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    if (deadlineOut) {
        deadlineOut->started = started;
        deadlineOut->deadline = started + ((CFTimeInterval)timeoutMS / 1000.0);
        deadlineOut->timeoutMS = timeoutMS;
    }
    return YES;
}

static BOOL FUHeapDeadlineExpired(const FUHeapDeadline *deadline) {
    return deadline && CFAbsoluteTimeGetCurrent() >= deadline->deadline;
}

static NSDictionary *FUHeapTimeoutResponse(NSString *requestID,
                                           NSString *operation,
                                           const FUHeapDeadline *deadline) {
    NSTimeInterval elapsed = deadline ? MAX(0.0, CFAbsoluteTimeGetCurrent() - deadline->started) : 0.0;
    NSInteger elapsedMS = (NSInteger)(elapsed * 1000.0);
    NSInteger timeoutMS = deadline ? deadline->timeoutMS : FUHeapTimeoutDefaultMS;
    NSMutableDictionary *error = [FUErrorInfo(
        @"heap_timeout",
        [NSString stringWithFormat:@"%@ exceeded its %ld ms heap time budget.",
                                   operation.length ? operation : @"Heap request",
                                   (long)timeoutMS]) mutableCopy];
    error[@"operation"] = operation ?: @"heap";
    error[@"timeout_ms"] = @(timeoutMS);
    error[@"elapsed_ms"] = @(elapsedMS);
    return FUResponse(requestID, NO, nil, error);
}

static NSArray<NSDictionary *> *FUHeapReferencesOptimized(Class heapClass, id target, BOOL retained,
                                                           NSUInteger offset, NSUInteger limit,
                                                           NSUInteger *totalOut,
                                                           NSMutableArray *matchedObjectsOut,
                                                           const FUHeapDeadline *deadline,
                                                           BOOL *timedOutOut) {
    SEL enumerateSelector = NSSelectorFromString(@"enumerateLiveObjectsUsingBlock:");
    if (![heapClass respondsToSelector:enumerateSelector]) {
        return nil;
    }

    CFMutableDictionaryRef layouts = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    if (!layouts) return nil;

    uintptr_t targetPointer = (uintptr_t)(__bridge void *)target;
    NSMutableArray<NSDictionary *> *references = [NSMutableArray arrayWithCapacity:limit];
    NSMutableArray *retainers = retained ? [NSMutableArray array] : nil;
    __block NSUInteger total = 0;
    __block NSUInteger enumerated = 0;
    __block BOOL timedOut = NO;

    @try {
        void (^enumeratorBlock)(__unsafe_unretained id, __unsafe_unretained Class) =
        ^(__unsafe_unretained id tryObject, __unsafe_unretained Class actualClass) {
            if (timedOut) return;
            if (((enumerated++) & 0xFF) == 0 && FUHeapDeadlineExpired(deadline)) {
                timedOut = YES;
                return;
            }
            if (!tryObject || !actualClass) return;

            const void *classKey = (__bridge const void *)actualClass;
            FUHeapIvarLayout *layout = (FUHeapIvarLayout *)CFDictionaryGetValue(layouts, classKey);
            if (!layout) {
                layout = FUCreateHeapIvarLayout(actualClass);
                if (!layout) return;
                CFDictionarySetValue(layouts, classKey, layout);
            }
            if (layout->count == 0) return;

            size_t allocationSize = malloc_size((__bridge const void *)tryObject);
            if (allocationSize < sizeof(uintptr_t)) return;

            uintptr_t base = (uintptr_t)(__bridge void *)tryObject;
            const char *matchedIvar = NULL;
            for (NSUInteger index = 0; index < layout->count; index++) {
                ptrdiff_t ivarOffset = layout->slots[index].offset;
                if (ivarOffset < 0 || (size_t)ivarOffset + sizeof(uintptr_t) > allocationSize) {
                    continue;
                }

                uintptr_t fieldValue = 0;
                memcpy(&fieldValue, (const void *)(base + (uintptr_t)ivarOffset), sizeof(fieldValue));
                if (fieldValue == targetPointer) {
                    matchedIvar = layout->slots[index].name;
                    break;
                }
            }

            if (!matchedIvar) return;
            NSUInteger matchIndex = total++;
            if (matchIndex < offset || references.count >= limit) return;

            if (retained) {
                [retainers addObject:tryObject];
            }
            NSMutableDictionary *reference = [FUHeapObjectReference(tryObject) mutableCopy];
            reference[@"flex_reference"] = [NSString stringWithFormat:@"%@ %s", FUClassName(tryObject), matchedIvar];
            [references addObject:reference];
            if (matchedObjectsOut) {
                [matchedObjectsOut addObject:tryObject];
            }
        };

        ((void (*)(id, SEL, id))objc_msgSend)(heapClass, enumerateSelector, enumeratorBlock);
    } @finally {
        FUFreeHeapIvarLayouts(layouts);
    }

    if (FUHeapDeadlineExpired(deadline)) timedOut = YES;
    if (timedOutOut) *timedOutOut = timedOut;
    if (totalOut) *totalOut = total;
    return references;
}

static NSDictionary<NSString *, NSArray<NSDictionary *> *> *FUHeapReferenceFrontierOptimized(
    Class heapClass,
    NSArray<NSDictionary *> *targets,
    BOOL retained,
    NSUInteger perTargetLimit,
    NSDictionary<NSString *, NSNumber *> **totalsOut,
    const FUHeapDeadline *deadline,
    BOOL *timedOutOut) {
    SEL enumerateSelector = NSSelectorFromString(@"enumerateLiveObjectsUsingBlock:");
    if (![heapClass respondsToSelector:enumerateSelector]) {
        return nil;
    }

    CFMutableDictionaryRef layouts = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    CFMutableDictionaryRef targetIDsByPointer = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    if (!layouts || !targetIDsByPointer) {
        if (layouts) FUFreeHeapIvarLayouts(layouts);
        if (targetIDsByPointer) CFRelease(targetIDsByPointer);
        return nil;
    }

    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *matchesByTarget = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *totalsByTarget = [NSMutableDictionary dictionary];
    NSMutableArray *retainers = retained ? [NSMutableArray array] : nil;
    __block NSUInteger enumerated = 0;
    __block BOOL timedOut = NO;

    for (NSDictionary *target in targets) {
        id object = target[@"object"];
        NSString *targetID = [target[@"id"] isKindOfClass:[NSString class]] ? target[@"id"] : @"";
        if (!object || targetID.length == 0) continue;
        CFDictionarySetValue(targetIDsByPointer, (__bridge const void *)object, (__bridge const void *)targetID);
        matchesByTarget[targetID] = [NSMutableArray arrayWithCapacity:perTargetLimit];
        totalsByTarget[targetID] = @0;
    }

    @try {
        void (^enumeratorBlock)(__unsafe_unretained id, __unsafe_unretained Class) =
        ^(__unsafe_unretained id tryObject, __unsafe_unretained Class actualClass) {
            if (timedOut) return;
            if (((enumerated++) & 0xFF) == 0 && FUHeapDeadlineExpired(deadline)) {
                timedOut = YES;
                return;
            }
            if (!tryObject || !actualClass) return;

            const void *classKey = (__bridge const void *)actualClass;
            FUHeapIvarLayout *layout = (FUHeapIvarLayout *)CFDictionaryGetValue(layouts, classKey);
            if (!layout) {
                layout = FUCreateHeapIvarLayout(actualClass);
                if (!layout) return;
                CFDictionarySetValue(layouts, classKey, layout);
            }
            if (layout->count == 0) return;

            size_t allocationSize = malloc_size((__bridge const void *)tryObject);
            if (allocationSize < sizeof(uintptr_t)) return;

            uintptr_t base = (uintptr_t)(__bridge void *)tryObject;
            NSMutableSet<NSString *> *matchedTargetIDs = nil;
            for (NSUInteger index = 0; index < layout->count; index++) {
                ptrdiff_t ivarOffset = layout->slots[index].offset;
                if (ivarOffset < 0 || (size_t)ivarOffset + sizeof(uintptr_t) > allocationSize) {
                    continue;
                }

                uintptr_t fieldValue = 0;
                memcpy(&fieldValue, (const void *)(base + (uintptr_t)ivarOffset), sizeof(fieldValue));
                NSString *targetID = (__bridge NSString *)CFDictionaryGetValue(targetIDsByPointer, (const void *)fieldValue);
                if (!targetID.length) continue;
                if (!matchedTargetIDs) matchedTargetIDs = [NSMutableSet set];
                if ([matchedTargetIDs containsObject:targetID]) continue;
                [matchedTargetIDs addObject:targetID];

                NSUInteger total = totalsByTarget[targetID].unsignedIntegerValue + 1;
                totalsByTarget[targetID] = @(total);

                NSMutableArray<NSDictionary *> *matches = matchesByTarget[targetID];
                if (!matches || matches.count >= perTargetLimit) continue;

                if (retained) {
                    [retainers addObject:tryObject];
                }
                NSMutableDictionary *reference = [FUHeapObjectReference(tryObject) mutableCopy];
                reference[@"flex_reference"] = [NSString stringWithFormat:@"%@ %s", FUClassName(tryObject), layout->slots[index].name];
                [matches addObject:@{
                    @"object": tryObject,
                    @"reference": reference,
                }];
            }
        };

        ((void (*)(id, SEL, id))objc_msgSend)(heapClass, enumerateSelector, enumeratorBlock);
    } @finally {
        FUFreeHeapIvarLayouts(layouts);
        CFRelease(targetIDsByPointer);
    }

    if (FUHeapDeadlineExpired(deadline)) timedOut = YES;
    if (timedOutOut) *timedOutOut = timedOut;
    if (totalsOut) *totalsOut = [totalsByTarget copy];
    return [matchesByTarget copy];
}

static NSArray<NSString *> *FUObjectiveCRuntimeSubclassNames(Class baseClass) {
    if (!baseClass) {
        return @[];
    }

    __unsafe_unretained Class *classes = NULL;
    int count = 0;
    int actual = 0;
    do {
        count = objc_getClassList(NULL, 0);
        if (count <= 0) {
            free(classes);
            return @[];
        }
        __unsafe_unretained Class *resized = (__unsafe_unretained Class *)realloc(classes, (size_t)count * sizeof(Class));
        if (!resized) {
            free(classes);
            return @[];
        }
        classes = resized;
        actual = objc_getClassList(classes, count);
    } while (actual > count);

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int index = 0; index < actual; index++) {
        Class candidate = classes[index];
        if (!candidate || candidate == baseClass || class_isMetaClass(candidate)) {
            continue;
        }

        Class superclass = class_getSuperclass(candidate);
        while (superclass) {
            if (superclass == baseClass) {
                NSString *candidateName = NSStringFromClass(candidate);
                if (candidateName.length) {
                    [names addObject:candidateName];
                }
                break;
            }
            superclass = class_getSuperclass(superclass);
        }
    }
    free(classes);
    [names sortUsingSelector:@selector(compare:)];
    return names;
}

static NSArray<NSDictionary *> *FUObjectReferencePage(NSArray *objects, NSUInteger offset, NSUInteger limit) {
    if (![objects isKindOfClass:[NSArray class]] || offset >= objects.count) {
        return @[];
    }

    NSUInteger count = MIN(limit, objects.count - offset);
    NSMutableArray<NSDictionary *> *references = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = offset; index < offset + count; index++) {
        id wrapper = objects[index];
        __strong id object = FUHeapUnderlyingObject(wrapper);
        if (object) {
            NSMutableDictionary *reference = [FUHeapObjectReference(object) mutableCopy];
            if (wrapper != object) {
                NSString *flexReference = FUObjectMessage(wrapper, @"reference");
                if ([flexReference isKindOfClass:[NSString class]] && flexReference.length) {
                    reference[@"flex_reference"] = flexReference;
                }
            }
            [references addObject:reference];
        }
    }
    return references;
}

NSDictionary *FUHandleHeapSnapshot(NSString *requestID, NSDictionary *request) {
    id queryValue = request[@"query"];
    if (queryValue && ![queryValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_query", @"query must be a string."));
    }
    NSString *query = [queryValue isKindOfClass:[NSString class]] ? queryValue : @"";

    id sortValue = request[@"sort"];
    if (sortValue && ![sortValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_sort", @"sort must be name, count, or size."));
    }
    NSString *sort = [sortValue isKindOfClass:[NSString class]] ? [sortValue lowercaseString] : @"name";
    if (![@[@"name", @"count", @"size"] containsObject:sort]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_sort", @"sort must be name, count, or size."));
    }

    NSUInteger offset = 0;
    NSUInteger limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    FUHeapDeadline deadline = {0};
    NSDictionary *deadlineError = nil;
    if (!FUHeapDeadlineFromRequest(requestID, request, &deadline, &deadlineError)) return deadlineError;

    NSDictionary *heapError = nil;
    Class heapClass = FUHeapEnumeratorClass(requestID, &heapError);
    if (!heapClass) return heapError;
    if (FUHeapDeadlineExpired(&deadline)) return FUHeapTimeoutResponse(requestID, @"heap.snapshot", &deadline);

    @try {
        NSDictionary *counts = nil;
        NSDictionary *sizes = nil;
        SEL snapshotSelector = NSSelectorFromString(@"generateHeapSnapshot");
        if ([heapClass respondsToSelector:snapshotSelector]) {
            if (FUHeapDeadlineExpired(&deadline)) return FUHeapTimeoutResponse(requestID, @"heap.snapshot", &deadline);
            id snapshot = ((id (*)(id, SEL))objc_msgSend)(heapClass, snapshotSelector);
            if (FUHeapDeadlineExpired(&deadline)) return FUHeapTimeoutResponse(requestID, @"heap.snapshot", &deadline);
            counts = FUObjectMessage(snapshot, @"instanceCountsForClassNames");
            sizes = FUObjectMessage(snapshot, @"instanceSizesForClassNames");
        } else {
            SEL enumerateSelector = NSSelectorFromString(@"enumerateLiveObjectsUsingBlock:");
            if (![heapClass respondsToSelector:enumerateSelector]) {
                return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose heap snapshot or live-object enumeration APIs."));
            }

            NSMutableDictionary<NSString *, NSNumber *> *liveCounts = [NSMutableDictionary dictionary];
            NSMutableDictionary<NSString *, NSNumber *> *liveSizes = [NSMutableDictionary dictionary];
            __block NSUInteger enumerated = 0;
            __block BOOL timedOut = NO;
            void (^enumeratorBlock)(__unsafe_unretained id, __unsafe_unretained Class) =
            ^(__unsafe_unretained id object, __unsafe_unretained Class actualClass) {
                if (timedOut) return;
                if (((enumerated++) & 0xFF) == 0 && FUHeapDeadlineExpired(&deadline)) {
                    timedOut = YES;
                    return;
                }
                (void)object;
                if (!actualClass) return;
                NSString *className = NSStringFromClass(actualClass);
                if (className.length == 0) return;
                liveCounts[className] = @(liveCounts[className].unsignedLongLongValue + 1);
                if (!liveSizes[className]) {
                    liveSizes[className] = @(class_getInstanceSize(actualClass));
                }
            };
            ((void (*)(id, SEL, id))objc_msgSend)(heapClass, enumerateSelector, enumeratorBlock);
            if (timedOut || FUHeapDeadlineExpired(&deadline)) {
                return FUHeapTimeoutResponse(requestID, @"heap.snapshot", &deadline);
            }
            counts = [liveCounts copy];
            sizes = [liveSizes copy];
        }

        if (![counts isKindOfClass:[NSDictionary class]] || ![sizes isKindOfClass:[NSDictionary class]]) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"heap_snapshot_failed", @"FLEX returned an invalid heap snapshot."));
        }

        NSString *needle = query.lowercaseString;
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:counts.count];
        unsigned long long recordedInstances = 0;
        unsigned long long recordedEstimatedBytes = 0;
        unsigned long long filteredInstances = 0;
        unsigned long long filteredEstimatedBytes = 0;
        NSUInteger classIndex = 0;

        for (id key in counts) {
            if (((classIndex++) & 0xFF) == 0 && FUHeapDeadlineExpired(&deadline)) {
                return FUHeapTimeoutResponse(requestID, @"heap.snapshot", &deadline);
            }
            if (![key isKindOfClass:[NSString class]]) continue;
            NSNumber *countNumber = [counts[key] isKindOfClass:[NSNumber class]] ? counts[key] : nil;
            NSNumber *sizeNumber = [sizes[key] isKindOfClass:[NSNumber class]] ? sizes[key] : nil;
            if (!countNumber || !sizeNumber) continue;

            unsigned long long instanceCount = countNumber.unsignedLongLongValue;
            unsigned long long instanceSize = sizeNumber.unsignedLongLongValue;
            unsigned long long estimatedBytes = instanceCount * instanceSize;
            recordedInstances += instanceCount;
            recordedEstimatedBytes += estimatedBytes;

            NSString *className = key;
            if (needle.length && ![className.lowercaseString containsString:needle]) continue;

            filteredInstances += instanceCount;
            filteredEstimatedBytes += estimatedBytes;
            [rows addObject:@{
                @"name": className,
                @"instance_count": @(instanceCount),
                @"instance_size": @(instanceSize),
                @"estimated_bytes": @(estimatedBytes),
            }];
        }

        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            if ([sort isEqualToString:@"name"]) {
                return [left[@"name"] caseInsensitiveCompare:right[@"name"]];
            }

            NSString *metric = [sort isEqualToString:@"count"] ? @"instance_count" : @"estimated_bytes";
            NSComparisonResult comparison = [right[metric] compare:left[metric]];
            if (comparison != NSOrderedSame) return comparison;
            return [left[@"name"] caseInsensitiveCompare:right[@"name"]];
        }];
        if (FUHeapDeadlineExpired(&deadline)) return FUHeapTimeoutResponse(requestID, @"heap.snapshot", &deadline);

        NSArray *page = @[];
        if (offset < rows.count) {
            NSUInteger count = MIN(limit, rows.count - offset);
            page = [rows subarrayWithRange:NSMakeRange(offset, count)];
        }

        return FUResponse(requestID, YES, @{
            @"source": @"FLEXHeapEnumerator",
            @"query": query,
            @"sort": sort,
            @"classes": page,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(rows.count),
            @"recorded_total": @(counts.count),
            @"has_more": @(offset + page.count < rows.count),
            @"filtered_instances": @(filteredInstances),
            @"filtered_estimated_bytes": @(filteredEstimatedBytes),
            @"recorded_instances": @(recordedInstances),
            @"recorded_estimated_bytes": @(recordedEstimatedBytes),
        }, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"heap_snapshot_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleHeapInstances(NSString *requestID, NSDictionary *request) {
    NSString *name = [request[@"name"] isKindOfClass:[NSString class]] ? request[@"name"] : @"";
    if (name.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_class_name", @"heap.instances requires an exact Objective-C class name."));
    }
    if (!NSClassFromString(name)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"class_not_found", [NSString stringWithFormat:@"Objective-C class '%@' is not loaded in the target process.", name]));
    }

    NSUInteger offset = 0;
    NSUInteger limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    FUHeapDeadline deadline = {0};
    NSDictionary *deadlineError = nil;
    if (!FUHeapDeadlineFromRequest(requestID, request, &deadline, &deadlineError)) return deadlineError;

    NSDictionary *heapError = nil;
    Class heapClass = FUHeapEnumeratorClass(requestID, &heapError);
    if (!heapClass) return heapError;

    SEL selector = NSSelectorFromString(@"instancesOfClassWithName:retained:");
    if (![heapClass respondsToSelector:selector]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose instance heap enumeration."));
    }

    BOOL retained = [request[@"retained"] boolValue];
    @try {
        if (FUHeapDeadlineExpired(&deadline)) return FUHeapTimeoutResponse(requestID, @"heap.instances", &deadline);
        NSArray *objects = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(heapClass, selector, name, retained);
        if (FUHeapDeadlineExpired(&deadline)) return FUHeapTimeoutResponse(requestID, @"heap.instances", &deadline);
        if (![objects isKindOfClass:[NSArray class]]) objects = @[];
        NSArray *instances = FUObjectReferencePage(objects, offset, limit);
        if (FUHeapDeadlineExpired(&deadline)) return FUHeapTimeoutResponse(requestID, @"heap.instances", &deadline);
        return FUResponse(requestID, YES, @{
            @"source": @"FLEXHeapEnumerator",
            @"class": name,
            @"instances": instances,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(objects.count),
            @"has_more": @(offset + instances.count < objects.count),
            @"retained": @(retained),
        }, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"heap_enumeration_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleHeapSubclasses(NSString *requestID, NSDictionary *request) {
    NSString *name = [request[@"name"] isKindOfClass:[NSString class]] ? request[@"name"] : @"";
    if (name.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_class_name", @"heap.subclasses requires an exact Objective-C class name."));
    }
    Class requestedClass = NSClassFromString(name);
    if (!requestedClass) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"class_not_found", [NSString stringWithFormat:@"Objective-C class '%@' is not loaded in the target process.", name]));
    }

    NSUInteger offset = 0;
    NSUInteger limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    @try {
        NSMutableArray<NSString *> *names = nil;
        NSString *source = @"ObjectiveCRuntime";
        Class runtimeUtility = NSClassFromString(@"FLEXRuntimeUtility");
        SEL modernSelector = NSSelectorFromString(@"subclassesOfClassWithName:");
        if (runtimeUtility && [runtimeUtility respondsToSelector:modernSelector]) {
            NSArray *rawSubclasses = ((id (*)(id, SEL, id))objc_msgSend)(runtimeUtility, modernSelector, name);
            source = @"FLEXRuntimeUtility";
            if (![rawSubclasses isKindOfClass:[NSArray class]]) rawSubclasses = @[];
            names = [NSMutableArray arrayWithCapacity:rawSubclasses.count];
            for (id item in rawSubclasses) {
                NSString *subclassName = nil;
                if ([item isKindOfClass:[NSString class]]) {
                    subclassName = item;
                } else {
                    __strong id object = FUHeapUnderlyingObject(item);
                    if (object_isClass(object)) {
                        subclassName = NSStringFromClass((Class)object);
                    }
                }
                if (subclassName.length) [names addObject:subclassName];
            }
        } else {
            names = [FUObjectiveCRuntimeSubclassNames(requestedClass) mutableCopy];
        }

        NSArray *page = @[];
        if (offset < names.count) {
            NSUInteger count = MIN(limit, names.count - offset);
            page = [names subarrayWithRange:NSMakeRange(offset, count)];
        }
        return FUResponse(requestID, YES, @{
            @"source": source,
            @"class": name,
            @"subclasses": page,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(names.count),
            @"has_more": @(offset + page.count < names.count),
        }, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"heap_enumeration_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleHeapReferences(NSString *requestID, NSDictionary *request) {
    NSString *resolvedHandle = nil;
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    id target = FUHeapObjectTargetFromRequest(requestID, request, &resolvedHandle, &targetSource, &resolvedBy, &targetError);
    if (!target) return targetError;

    NSUInteger offset = 0;
    NSUInteger limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    FUHeapDeadline deadline = {0};
    NSDictionary *deadlineError = nil;
    if (!FUHeapDeadlineFromRequest(requestID, request, &deadline, &deadlineError)) return deadlineError;

    NSDictionary *heapError = nil;
    Class heapClass = FUHeapEnumeratorClass(requestID, &heapError);
    if (!heapClass) return heapError;

    BOOL retained = [request[@"retained"] boolValue];
    @try {
        NSUInteger total = 0;
        BOOL timedOut = NO;
        NSArray *references = FUHeapReferencesOptimized(heapClass, target, retained, offset, limit, &total, nil,
                                                        &deadline, &timedOut);
        if (timedOut || FUHeapDeadlineExpired(&deadline)) {
            return FUHeapTimeoutResponse(requestID, @"heap.references", &deadline);
        }
        NSString *strategy = @"cached_ivar_scan";
        if (!references) {
            SEL selector = NSSelectorFromString(@"objectsWithReferencesToObject:retained:");
            if (![heapClass respondsToSelector:selector]) {
                return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose reference heap enumeration."));
            }
            if (FUHeapDeadlineExpired(&deadline)) return FUHeapTimeoutResponse(requestID, @"heap.references", &deadline);
            NSArray *objects = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(heapClass, selector, target, retained);
            if (FUHeapDeadlineExpired(&deadline)) return FUHeapTimeoutResponse(requestID, @"heap.references", &deadline);
            if (![objects isKindOfClass:[NSArray class]]) objects = @[];
            references = FUObjectReferencePage(objects, offset, limit);
            if (FUHeapDeadlineExpired(&deadline)) return FUHeapTimeoutResponse(requestID, @"heap.references", &deadline);
            total = objects.count;
            strategy = @"flex_default";
        }
        NSMutableDictionary *result = [@{
            @"source": @"FLEXHeapEnumerator",
            @"strategy": strategy,
            @"target": FUHeapObjectReference(target),
            @"references": references,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(total),
            @"has_more": @(offset + references.count < total),
            @"retained": @(retained),
            @"target_source": targetSource ?: @"handle",
        } mutableCopy];
        if (resolvedHandle.length) result[@"resolved_handle"] = resolvedHandle;
        if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
        return FUResponse(requestID, YES, result, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"heap_enumeration_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleHeapReferenceGraph(NSString *requestID, NSDictionary *request) {
    NSString *resolvedHandle = nil;
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    id target = FUHeapObjectTargetFromRequest(requestID, request, &resolvedHandle, &targetSource, &resolvedBy, &targetError);
    if (!target) return targetError;

    NSInteger requestedDepth = [request[@"max_depth"] respondsToSelector:@selector(integerValue)]
        ? [request[@"max_depth"] integerValue] : 2;
    NSInteger requestedNodes = [request[@"max_nodes"] respondsToSelector:@selector(integerValue)]
        ? [request[@"max_nodes"] integerValue] : 100;
    NSInteger requestedPerNodeLimit = [request[@"per_node_limit"] respondsToSelector:@selector(integerValue)]
        ? [request[@"per_node_limit"] integerValue] : 50;
    if (requestedDepth <= 0 || requestedDepth > 5
        || requestedNodes <= 0 || requestedNodes > 500
        || requestedPerNodeLimit <= 0 || requestedPerNodeLimit > 200) {
        return FUResponse(requestID, NO, nil,
                          FUErrorInfo(@"invalid_graph_bounds",
                                      @"max_depth must be 1-5, max_nodes must be 1-500, and per_node_limit must be 1-200."));
    }

    FUHeapDeadline deadline = {0};
    NSDictionary *deadlineError = nil;
    if (!FUHeapDeadlineFromRequest(requestID, request, &deadline, &deadlineError)) return deadlineError;

    NSDictionary *heapError = nil;
    Class heapClass = FUHeapEnumeratorClass(requestID, &heapError);
    if (!heapClass) return heapError;

    NSUInteger maxDepth = (NSUInteger)requestedDepth;
    NSUInteger maxNodes = (NSUInteger)requestedNodes;
    NSUInteger perNodeLimit = (NSUInteger)requestedPerNodeLimit;
    BOOL retained = [request[@"retained"] boolValue];
    const NSUInteger maxEdges = MIN((NSUInteger)5000, MAX((NSUInteger)64, maxNodes * MIN(perNodeLimit, (NSUInteger)16)));

    @try {
        NSMutableDictionary *rootReference = [FUHeapObjectReference(target) mutableCopy];
        NSString *rootID = [rootReference[@"id"] isKindOfClass:[NSString class]] ? rootReference[@"id"] : @"";
        if (rootID.length == 0) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"heap_enumeration_failed", @"Unable to register the graph root object."));
        }
        rootReference[@"depth"] = @0;

        NSMutableArray<NSDictionary *> *nodes = [NSMutableArray arrayWithObject:rootReference];
        NSMutableArray<NSDictionary *> *edges = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *queue = [NSMutableArray arrayWithObject:@{
            @"object": target,
            @"id": rootID,
            @"depth": @0,
        }];
        NSMutableSet<NSString *> *visited = [NSMutableSet setWithObject:rootID];
        NSMutableSet<NSString *> *edgeKeys = [NSMutableSet set];
        NSMutableSet<NSString *> *omittedNodeIDs = [NSMutableSet set];
        NSMutableOrderedSet<NSString *> *strategies = [NSMutableOrderedSet orderedSet];

        NSUInteger queueIndex = 0;
        NSUInteger scannedNodes = 0;
        NSUInteger heapScans = 0;
        NSUInteger maxDepthReached = 0;
        NSUInteger fanoutTruncatedNodes = 0;
        BOOL edgesTruncated = NO;
        BOOL truncated = NO;

        while (queueIndex < queue.count) {
            if (FUHeapDeadlineExpired(&deadline)) {
                return FUHeapTimeoutResponse(requestID, @"heap.reference_graph", &deadline);
            }
            NSUInteger depth = [queue[queueIndex][@"depth"] unsignedIntegerValue];
            if (depth >= maxDepth) {
                queueIndex++;
                continue;
            }

            NSMutableArray<NSDictionary *> *frontier = [NSMutableArray array];
            while (queueIndex < queue.count) {
                NSDictionary *candidate = queue[queueIndex];
                if ([candidate[@"depth"] unsignedIntegerValue] != depth) break;
                queueIndex++;

                id candidateObject = candidate[@"object"];
                NSString *candidateID = [candidate[@"id"] isKindOfClass:[NSString class]] ? candidate[@"id"] : @"";
                if (!candidateObject || candidateID.length == 0) continue;
                [frontier addObject:candidate];
            }
            if (frontier.count == 0) continue;
            scannedNodes += frontier.count;

            NSDictionary<NSString *, NSNumber *> *totalsByTarget = nil;
            BOOL frontierTimedOut = NO;
            NSDictionary<NSString *, NSArray<NSDictionary *> *> *matchesByTarget =
                FUHeapReferenceFrontierOptimized(heapClass, frontier, retained, perNodeLimit, &totalsByTarget,
                                                 &deadline, &frontierTimedOut);
            if (frontierTimedOut || FUHeapDeadlineExpired(&deadline)) {
                return FUHeapTimeoutResponse(requestID, @"heap.reference_graph", &deadline);
            }
            NSString *frontierStrategy = @"cached_ivar_scan";
            if (matchesByTarget) {
                heapScans++;
            } else {
                SEL selector = NSSelectorFromString(@"objectsWithReferencesToObject:retained:");
                if (![heapClass respondsToSelector:selector]) {
                    return FUResponse(requestID, NO, nil,
                                      FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose reference heap enumeration."));
                }

                NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *fallbackMatches = [NSMutableDictionary dictionary];
                NSMutableDictionary<NSString *, NSNumber *> *fallbackTotals = [NSMutableDictionary dictionary];
                for (NSDictionary *current in frontier) {
                    if (FUHeapDeadlineExpired(&deadline)) {
                        return FUHeapTimeoutResponse(requestID, @"heap.reference_graph", &deadline);
                    }
                    id currentObject = current[@"object"];
                    NSString *currentID = [current[@"id"] isKindOfClass:[NSString class]] ? current[@"id"] : @"";
                    if (!currentObject || currentID.length == 0) continue;

                    heapScans++;
                    NSArray *objects = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(heapClass, selector, currentObject, retained);
                    if (FUHeapDeadlineExpired(&deadline)) {
                        return FUHeapTimeoutResponse(requestID, @"heap.reference_graph", &deadline);
                    }
                    if (![objects isKindOfClass:[NSArray class]]) objects = @[];
                    fallbackTotals[currentID] = @(objects.count);

                    NSUInteger count = MIN(perNodeLimit, objects.count);
                    NSMutableArray<NSDictionary *> *matches = [NSMutableArray arrayWithCapacity:count];
                    for (NSUInteger index = 0; index < count; index++) {
                        if ((index & 0x3F) == 0 && FUHeapDeadlineExpired(&deadline)) {
                            return FUHeapTimeoutResponse(requestID, @"heap.reference_graph", &deadline);
                        }
                        id wrapper = objects[index];
                        __strong id object = FUHeapUnderlyingObject(wrapper);
                        if (!object) continue;
                        NSMutableDictionary *reference = [FUHeapObjectReference(object) mutableCopy];
                        if (wrapper != object) {
                            NSString *flexReference = FUObjectMessage(wrapper, @"reference");
                            if ([flexReference isKindOfClass:[NSString class]] && flexReference.length) {
                                reference[@"flex_reference"] = flexReference;
                            }
                        }
                        [matches addObject:@{
                            @"object": object,
                            @"reference": reference,
                        }];
                    }
                    fallbackMatches[currentID] = matches;
                }
                matchesByTarget = fallbackMatches;
                totalsByTarget = fallbackTotals;
                frontierStrategy = @"flex_default";
            }
            [strategies addObject:frontierStrategy];

            for (NSDictionary *current in frontier) {
                if (FUHeapDeadlineExpired(&deadline)) {
                    return FUHeapTimeoutResponse(requestID, @"heap.reference_graph", &deadline);
                }
                NSString *currentID = [current[@"id"] isKindOfClass:[NSString class]] ? current[@"id"] : @"";
                if (currentID.length == 0) continue;

                NSArray<NSDictionary *> *matches = matchesByTarget[currentID] ?: @[];
                NSUInteger total = totalsByTarget[currentID].unsignedIntegerValue;
                if (total > matches.count) {
                    fanoutTruncatedNodes++;
                    truncated = YES;
                }

                for (NSDictionary *match in matches) {
                    if (FUHeapDeadlineExpired(&deadline)) {
                        return FUHeapTimeoutResponse(requestID, @"heap.reference_graph", &deadline);
                    }
                    id referrer = match[@"object"];
                    NSDictionary *reference = [match[@"reference"] isKindOfClass:[NSDictionary class]] ? match[@"reference"] : @{};
                    NSString *referrerID = [reference[@"id"] isKindOfClass:[NSString class]] ? reference[@"id"] : @"";
                    if (!referrer || referrerID.length == 0) continue;

                    NSString *flexReference = [reference[@"flex_reference"] isKindOfClass:[NSString class]]
                        ? reference[@"flex_reference"] : @"";
                    BOOL alreadyVisited = [visited containsObject:referrerID];
                    if (!alreadyVisited && nodes.count >= maxNodes) {
                        [omittedNodeIDs addObject:referrerID];
                        truncated = YES;
                        continue;
                    }

                    NSString *edgeKey = [NSString stringWithFormat:@"%@|%@|%@", referrerID, currentID, flexReference];
                    if (![edgeKeys containsObject:edgeKey]) {
                        if (edges.count >= maxEdges) {
                            edgesTruncated = YES;
                            truncated = YES;
                        } else {
                            NSMutableDictionary *edge = [@{
                                @"from": referrerID,
                                @"to": currentID,
                                @"direction": @"references",
                                @"depth": @(depth + 1),
                            } mutableCopy];
                            if (flexReference.length) edge[@"flex_reference"] = flexReference;
                            [edges addObject:edge];
                            [edgeKeys addObject:edgeKey];
                        }
                    }

                    if (alreadyVisited) continue;

                    [visited addObject:referrerID];
                    NSMutableDictionary *node = [reference mutableCopy];
                    node[@"depth"] = @(depth + 1);
                    [nodes addObject:node];
                    [queue addObject:@{
                        @"object": referrer,
                        @"id": referrerID,
                        @"depth": @(depth + 1),
                    }];
                    maxDepthReached = MAX(maxDepthReached, depth + 1);
                }
            }
        }

        if (FUHeapDeadlineExpired(&deadline)) {
            return FUHeapTimeoutResponse(requestID, @"heap.reference_graph", &deadline);
        }

        NSString *strategy = strategies.count == 1 ? strategies.firstObject : (strategies.count > 1 ? @"mixed" : @"cached_ivar_scan");
        NSMutableDictionary *result = [@{
            @"source": @"FLEXHeapEnumerator",
            @"strategy": strategy,
            @"strategies": strategies.array,
            @"root": rootReference,
            @"nodes": nodes,
            @"edges": edges,
            @"max_depth": @(maxDepth),
            @"max_nodes": @(maxNodes),
            @"per_node_limit": @(perNodeLimit),
            @"max_edges": @(maxEdges),
            @"visited_nodes": @(nodes.count),
            @"scanned_nodes": @(scannedNodes),
            @"heap_scans": @(heapScans),
            @"max_depth_reached": @(maxDepthReached),
            @"fanout_truncated_nodes": @(fanoutTruncatedNodes),
            @"omitted_nodes": @(omittedNodeIDs.count),
            @"edges_truncated": @(edgesTruncated),
            @"truncated": @(truncated),
            @"retained": @(retained),
            @"target_source": targetSource ?: @"handle",
        } mutableCopy];
        if (resolvedHandle.length) result[@"resolved_handle"] = resolvedHandle;
        if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
        return FUResponse(requestID, YES, result, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil,
                          FUErrorInfo(@"heap_enumeration_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}
