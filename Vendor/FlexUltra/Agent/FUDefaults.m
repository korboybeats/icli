#import "FUDefaults.h"

#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <unistd.h>

#import "FUExperiments.h"
#import "FUObjectSerialization.h"
#import "FUProtocol.h"
#import "FURuntime.h"

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


static NSString *FUDefaultsValueType(id value) {
    if (!value) return @"missing";
    if ([value isKindOfClass:[NSString class]]) return @"string";
    if ([value isKindOfClass:[NSNumber class]]) {
        return CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ? @"boolean" : @"number";
    }
    if ([value isKindOfClass:[NSArray class]]) return @"array";
    if ([value isKindOfClass:[NSDictionary class]]) return @"dictionary";
    if ([value isKindOfClass:[NSDate class]]) return @"date";
    if ([value isKindOfClass:[NSData class]]) return @"data";
    return FUClassName(value).length ? FUClassName(value) : @"unknown";
}

static id FUDefaultsJSONValue(id value) {
    if (!value) return NSNull.null;
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return FUJSONValue(value);
    if ([value isKindOfClass:[NSDate class]]) {
        return @{
            @"kind": @"date",
            @"time_interval_since_1970": FUJSONFloatingNumber([(NSDate *)value timeIntervalSince1970]),
        };
    }
    if ([value isKindOfClass:[NSData class]]) {
        return @{
            @"kind": @"data",
            @"base64": [(NSData *)value base64EncodedStringWithOptions:0] ?: @"",
        };
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id item in (NSArray *)value) {
            [result addObject:FUDefaultsJSONValue(item) ?: NSNull.null];
        }
        return result;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)value count]];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id item, BOOL *stop) {
            (void)stop;
            if (![key isKindOfClass:[NSString class]]) return;
            result[key] = FUDefaultsJSONValue(item) ?: NSNull.null;
        }];
        return result;
    }
    return FUJSONValue(value);
}

static BOOL FUDefaultsValueIsWritable(id value) {
    if (!value || value == NSNull.null) return NO;
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)value) {
            if (!FUDefaultsValueIsWritable(item)) return NO;
        }
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)value) {
            if (![key isKindOfClass:[NSString class]] || !FUDefaultsValueIsWritable([(NSDictionary *)value objectForKey:key])) {
                return NO;
            }
        }
    }
    return [NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListBinaryFormat_v1_0];
}

static NSMutableSet<NSString *> *FUDefaultsOwnedKeyAdditions;
static NSMutableSet<NSString *> *FUDefaultsOwnedKeyRemovals;
static NSObject *FUDefaultsOwnershipLock;

static void FUInitializeDefaultsOwnershipOverlay(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FUDefaultsOwnedKeyAdditions = [NSMutableSet set];
        FUDefaultsOwnedKeyRemovals = [NSMutableSet set];
        FUDefaultsOwnershipLock = [NSObject new];
    });
}

void FURecordDefaultsOwnership(NSString *key, BOOL owned) {
    if (key.length == 0) return;
    FUInitializeDefaultsOwnershipOverlay();
    @synchronized (FUDefaultsOwnershipLock) {
        if (owned) {
            [FUDefaultsOwnedKeyAdditions addObject:key];
            [FUDefaultsOwnedKeyRemovals removeObject:key];
        } else {
            [FUDefaultsOwnedKeyAdditions removeObject:key];
            [FUDefaultsOwnedKeyRemovals addObject:key];
        }
    }
}

static NSSet<NSString *> *FUDefaultsAppOwnedKeys(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (bundleID.length == 0) return [NSSet set];
    NSString *preferences = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
    NSString *path = [preferences stringByAppendingPathComponent:[bundleID stringByAppendingString:@".plist"]];
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:path];
    NSArray *keys = [stored isKindOfClass:[NSDictionary class]] ? stored.allKeys : @[];
    NSMutableSet<NSString *> *result = [NSMutableSet setWithArray:keys];
    FUInitializeDefaultsOwnershipOverlay();
    @synchronized (FUDefaultsOwnershipLock) {
        [result unionSet:FUDefaultsOwnedKeyAdditions];
        [result minusSet:FUDefaultsOwnedKeyRemovals];
    }
    return result;
}

static NSSet<NSString *> *FUDefaultsAppOwnedKeysWaitingForKey(NSString *key, BOOL shouldContain) {
    NSSet<NSString *> *keys = FUDefaultsAppOwnedKeys();
    if (key.length == 0) return keys;

    for (NSUInteger attempt = 0; attempt < 25 && ([keys containsObject:key] != shouldContain); attempt++) {
        usleep(20000);
        keys = FUDefaultsAppOwnedKeys();
    }
    return keys;
}

static NSDictionary *FUDefaultsResultForValue(NSString *key, id value, NSSet<NSString *> *appOwnedKeys) {
    NSMutableDictionary *result = [@{
        @"source": @"NSUserDefaults.standardUserDefaults",
        @"key": key ?: @"",
        @"exists": (value ? @YES : @NO),
        @"app_owned": @([appOwnedKeys containsObject:key ?: @""]),
    } mutableCopy];
    if (value) {
        result[@"value"] = FUDefaultsJSONValue(value);
        result[@"value_type"] = FUDefaultsValueType(value);
    }
    return result;
}

static NSString *FUDefaultsKeyFromRequest(NSDictionary *request) {
    NSString *key = [request[@"key"] isKindOfClass:[NSString class]] ? request[@"key"] : nil;
    return key.length ? key : nil;
}

NSDictionary *FUHandleDefaultsEntries(NSString *requestID, NSDictionary *request) {
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for defaults enumeration."));
    }

    id queryValue = request[@"query"];
    if (queryValue && ![queryValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_query", @"query must be a string."));
    }
    NSString *query = [queryValue isKindOfClass:[NSString class]] ? queryValue : @"";

    id includeRegisteredValue = request[@"include_registered"];
    if (includeRegisteredValue && CFGetTypeID((__bridge CFTypeRef)includeRegisteredValue) != CFBooleanGetTypeID()) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"include_registered must be a boolean."));
    }
    BOOL includeRegistered = [includeRegisteredValue boolValue];

    NSUInteger offset = 0;
    NSUInteger limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    Class sectionClass = NSClassFromString(@"FLEXDefaultsContentSection");
    SEL standardSelector = NSSelectorFromString(@"standard");
    SEL unexcludedSelector = NSSelectorFromString(@"unexcludedDefaults");
    SEL includeSelector = NSSelectorFromString(@"setOnlyShowKeysForAppPrefs:");
    if (!sectionClass || ![sectionClass respondsToSelector:standardSelector]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXDefaultsContentSection.standard."));
    }

    @try {
        id section = ((id (*)(id, SEL))objc_msgSend)(sectionClass, standardSelector);
        if (!section || ![section respondsToSelector:unexcludedSelector] || ![section respondsToSelector:includeSelector]) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose the expected defaults section API."));
        }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(section, includeSelector, !includeRegistered);
        id defaultsValue = ((id (*)(id, SEL))objc_msgSend)(section, unexcludedSelector);
        if (![defaultsValue isKindOfClass:[NSDictionary class]]) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"defaults_failed", @"FLEXDefaultsContentSection did not return a defaults dictionary."));
        }
        NSDictionary *defaults = defaultsValue;
        NSSet<NSString *> *appOwnedKeys = FUDefaultsAppOwnedKeys();
        if (!includeRegistered) {
            NSDictionary *allDefaults = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
            NSMutableDictionary *effectiveDefaults = [NSMutableDictionary dictionaryWithCapacity:appOwnedKeys.count];
            for (NSString *key in appOwnedKeys) {
                id value = allDefaults[key];
                if (value) effectiveDefaults[key] = value;
            }
            defaults = effectiveDefaults;
        }
        NSArray<NSString *> *keys = [defaults.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        NSString *needle = query.lowercaseString;
        NSMutableArray<NSString *> *filteredKeys = [NSMutableArray array];
        for (id keyValue in keys) {
            if (![keyValue isKindOfClass:[NSString class]]) continue;
            NSString *key = keyValue;
            id value = defaults[key];
            if (needle.length) {
                NSString *searchText = [NSString stringWithFormat:@"%@\n%@", key, [value description] ?: @""];
                if (![searchText.lowercaseString containsString:needle]) continue;
            }
            [filteredKeys addObject:key];
        }

        NSMutableArray *entries = [NSMutableArray array];
        if (offset < filteredKeys.count) {
            NSUInteger end = MIN(filteredKeys.count, offset + limit);
            for (NSUInteger index = offset; index < end; index++) {
                NSString *key = filteredKeys[index];
                id value = defaults[key];
                [entries addObject:@{
                    @"key": key,
                    @"value": FUDefaultsJSONValue(value),
                    @"value_type": FUDefaultsValueType(value),
                    @"app_owned": @([appOwnedKeys containsObject:key]),
                }];
            }
        }

        NSMutableDictionary *result = [@{
            @"source": @"FLEXDefaultsContentSection",
            @"scope": includeRegistered ? @"all" : @"app_owned",
            @"entries": entries,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(filteredKeys.count),
            @"recorded_total": @(defaults.count),
            @"has_more": (offset + entries.count < filteredKeys.count ? @YES : @NO),
        } mutableCopy];
        if (query.length) result[@"query"] = query;
        return FUResponse(requestID, YES, result, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"defaults_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleDefaultsGet(NSString *requestID, NSDictionary *request) {
    NSString *key = FUDefaultsKeyFromRequest(request);
    if (!key) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"defaults.get requires a non-empty key."));
    }
    @try {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        return FUResponse(requestID, YES, FUDefaultsResultForValue(key, [defaults objectForKey:key], FUDefaultsAppOwnedKeys()), nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"defaults_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleDefaultsSet(NSString *requestID, NSDictionary *request) {
    NSString *key = FUDefaultsKeyFromRequest(request);
    if (!key || ![request.allKeys containsObject:@"value"]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"defaults.set requires a non-empty key and value."));
    }
    id value = request[@"value"];
    if (!FUDefaultsValueIsWritable(value)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_default_value", @"value must be a JSON-compatible property-list value and cannot contain null."));
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id previous = nil;
    id previousCopy = nil;
    BOOL previousOwned = NO;
    @try {
        previous = [defaults objectForKey:key];
        previousCopy = FUExperimentCopyPropertyListValue(previous);
        previousOwned = [FUDefaultsAppOwnedKeys() containsObject:key];
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"defaults_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }

    NSString *experimentID = nil;
    NSDictionary *experimentError = nil;
    if (!FUExperimentPrepareMutation(request, &experimentID, &experimentError)) {
        return FUResponse(requestID, NO, nil, experimentError);
    }

    @try {
        [defaults setObject:value forKey:key];
        BOOL synchronized = [defaults synchronize];
        FURecordDefaultsOwnership(key, YES);
        id stored = [defaults objectForKey:key];
        NSSet<NSString *> *appOwnedKeys = FUDefaultsAppOwnedKeysWaitingForKey(key, YES);
        NSMutableDictionary *result = [FUDefaultsResultForValue(key, stored, appOwnedKeys) mutableCopy];
        result[@"synchronized"] = @(synchronized);
        result[@"previous_exists"] = previous ? @YES : @NO;
        if (previous) {
            result[@"previous_value"] = FUDefaultsJSONValue(previous);
            result[@"previous_value_type"] = FUDefaultsValueType(previous);
        }
        if (experimentID.length) {
            NSMutableDictionary *undoRecord = [@{
                @"mutation": @"defaults",
                @"key": key,
                @"previous_exists": @(previous != nil),
                @"previous_owned": @(previousOwned),
            } mutableCopy];
            if (previousCopy) undoRecord[@"previous_value"] = previousCopy;
            if (!FUExperimentCommitMutation(experimentID, undoRecord, result, &experimentError)) {
                return FUResponse(requestID, NO, nil, experimentError);
            }
        }
        return FUResponse(requestID, YES, result, nil);
    } @catch (NSException *exception) {
        FUExperimentAbortMutation(experimentID);
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"defaults_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleDefaultsRemove(NSString *requestID, NSDictionary *request) {
    NSString *key = FUDefaultsKeyFromRequest(request);
    if (!key) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"defaults.remove requires a non-empty key."));
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id previous = nil;
    id previousCopy = nil;
    BOOL previousOwned = NO;
    @try {
        previous = [defaults objectForKey:key];
        previousCopy = FUExperimentCopyPropertyListValue(previous);
        previousOwned = [FUDefaultsAppOwnedKeys() containsObject:key];
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"defaults_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }

    NSString *experimentID = nil;
    NSDictionary *experimentError = nil;
    if (!FUExperimentPrepareMutation(request, &experimentID, &experimentError)) {
        return FUResponse(requestID, NO, nil, experimentError);
    }

    @try {
        [defaults removeObjectForKey:key];
        BOOL synchronized = [defaults synchronize];
        FURecordDefaultsOwnership(key, NO);
        NSSet<NSString *> *appOwnedKeys = FUDefaultsAppOwnedKeysWaitingForKey(key, NO);
        NSMutableDictionary *result = [FUDefaultsResultForValue(key, [defaults objectForKey:key], appOwnedKeys) mutableCopy];
        result[@"removed"] = previous ? @YES : @NO;
        result[@"synchronized"] = @(synchronized);
        if (previous) {
            result[@"previous_value"] = FUDefaultsJSONValue(previous);
            result[@"previous_value_type"] = FUDefaultsValueType(previous);
        }
        if (experimentID.length) {
            NSMutableDictionary *undoRecord = [@{
                @"mutation": @"defaults",
                @"key": key,
                @"previous_exists": @(previous != nil),
                @"previous_owned": @(previousOwned),
            } mutableCopy];
            if (previousCopy) undoRecord[@"previous_value"] = previousCopy;
            if (!FUExperimentCommitMutation(experimentID, undoRecord, result, &experimentError)) {
                return FUResponse(requestID, NO, nil, experimentError);
            }
        }
        return FUResponse(requestID, YES, result, nil);
    } @catch (NSException *exception) {
        FUExperimentAbortMutation(experimentID);
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"defaults_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

