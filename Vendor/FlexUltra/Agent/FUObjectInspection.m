#import "FUObjectInspection.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdlib.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

#import "FUProtocol.h"
#import "FURuntime.h"
#import "FUObjectRegistry.h"
#import "FUObjectSerialization.h"
#import "FUUI.h"

static id FUObjectMessage(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static BOOL FUBoolMessage(id target, NSString *selectorName, BOOL fallback) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSUInteger FUUnsignedMessage(id target, NSString *selectorName, NSUInteger fallback) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return fallback;
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(target, selector);
}

static BOOL FUObjectRequestPagination(NSDictionary *request, NSUInteger *offset, NSUInteger *limit) {
    NSInteger requestedOffset = [request[@"offset"] respondsToSelector:@selector(integerValue)] ? [request[@"offset"] integerValue] : 0;
    NSInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(integerValue)] ? [request[@"limit"] integerValue] : 100;
    if (requestedOffset < 0 || requestedLimit <= 0) return NO;
    *offset = (NSUInteger)requestedOffset;
    *limit = MIN((NSUInteger)requestedLimit, (NSUInteger)1000);
    return YES;
}

static void FUAppendInvocationMetadata(NSMutableDictionary *entry);

static NSString *FUPointerString(const void *pointer) {
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)pointer];
}

static IMP FUMethodImplementation(id method) {
    SEL selector = NSSelectorFromString(@"implementation");
    if (!method || ![method respondsToSelector:selector]) return NULL;
    return ((IMP (*)(id, SEL))objc_msgSend)(method, selector);
}

static const void *FUCanonicalMethodImplementationAddress(IMP implementation) {
    const void *address = (const void *)implementation;
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(address, ptrauth_key_function_pointer);
#else
    return address;
#endif
}

static NSString *FUExactMethodDeclaringClass(id method, NSString *fallbackClass) {
    if (!fallbackClass.length) return @"";

    NSString *selectorName = FUObjectMessage(method, @"selectorString") ?: FUObjectMessage(method, @"name");
    if (!selectorName.length) return fallbackClass;
    SEL selector = NSSelectorFromString(selectorName);
    BOOL isInstanceMethod = FUBoolMessage(method, @"isInstanceMethod", YES);
    Class cls = NSClassFromString(fallbackClass);

    for (Class current = cls; current; current = class_getSuperclass(current)) {
        Class methodClass = isInstanceMethod ? current : object_getClass(current);
        unsigned int count = 0;
        Method *methods = methodClass ? class_copyMethodList(methodClass, &count) : NULL;
        BOOL declaresSelector = NO;
        for (unsigned int index = 0; index < count; index++) {
            if (method_getName(methods[index]) == selector) {
                declaresSelector = YES;
                break;
            }
        }
        free(methods);
        if (declaresSelector) return NSStringFromClass(current) ?: fallbackClass;
    }

    return fallbackClass;
}

static void FUAppendMethodImplementationProvenance(NSMutableDictionary *entry, id method) {
    IMP implementation = FUMethodImplementation(method);
    if (!implementation) return;

    const void *address = FUCanonicalMethodImplementationAddress(implementation);
    entry[@"implementation_address"] = FUPointerString(address);

    Dl_info info = {0};
    if (dladdr(address, &info) == 0) return;

    if (info.dli_fname) {
        NSString *imagePath = [NSString stringWithUTF8String:info.dli_fname];
        if (imagePath.length) entry[@"implementation_image_path"] = imagePath;
    }
    if (info.dli_fbase) {
        entry[@"implementation_image_base"] = FUPointerString(info.dli_fbase);
        uintptr_t addressValue = (uintptr_t)address;
        uintptr_t baseValue = (uintptr_t)info.dli_fbase;
        if (addressValue >= baseValue) {
            entry[@"implementation_image_offset"] = @((unsigned long long)(addressValue - baseValue));
        }
    }
    if (info.dli_sname) {
        NSString *symbolName = [NSString stringWithUTF8String:info.dli_sname];
        if (symbolName.length) entry[@"implementation_symbol_name"] = symbolName;
    }
    if (info.dli_saddr) {
        entry[@"implementation_symbol_address"] = FUPointerString(info.dli_saddr);
        uintptr_t addressValue = (uintptr_t)address;
        uintptr_t symbolValue = (uintptr_t)info.dli_saddr;
        if (addressValue >= symbolValue) {
            entry[@"implementation_symbol_offset"] = @((unsigned long long)(addressValue - symbolValue));
        }
    }
}

NSArray *FUClassHierarchyNames(id explorer) {
    NSArray *classes = FUObjectMessage(explorer, @"classHierarchyClasses");
    if (![classes isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:classes.count];
    for (id cls in classes) {
        [names addObject:FUClassName(cls)];
    }
    return names;
}

NSMutableDictionary *FUPropertyEntry(id property, id target, NSString *declaringClass, BOOL includeValue) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"name"] = FUObjectMessage(property, @"name") ?: @"";
    entry[@"declaring_class"] = declaringClass ?: @"";
    entry[@"description"] = FUTruncatedString(FUObjectMessage(property, @"fullDescription"), 1024);
    id attributes = FUObjectMessage(property, @"attributes");
    NSString *typeEncoding = FUObjectMessage(attributes, @"typeEncoding");
    if (typeEncoding) entry[@"type_encoding"] = typeEncoding;
    NSString *getter = FUObjectMessage(property, @"likelyGetterString");
    NSString *setter = FUObjectMessage(property, @"likelySetterString");
    if (getter) entry[@"getter"] = getter;
    if (setter) entry[@"setter"] = setter;
    entry[@"readonly"] = @(FUBoolMessage(attributes, @"isReadOnly", NO));
    entry[@"getter_exists"] = @(FUBoolMessage(property, @"likelyGetterExists", YES));
    entry[@"setter_exists"] = @(FUBoolMessage(property, @"likelySetterExists", ![entry[@"readonly"] boolValue]));

    if (includeValue) {
        @try {
            SEL getterSEL = NSSelectorFromString(@"getPotentiallyUnboxedValue:");
            if ([property respondsToSelector:getterSEL]) {
                id value = ((id (*)(id, SEL, id))objc_msgSend)(property, getterSEL, target);
                entry[@"value"] = FUJSONValue(value);
            }
        } @catch (NSException *exception) {
            entry[@"value_error"] = FUTruncatedString(exception.reason ?: exception.name, 512);
        }
    }
    return entry;
}

NSMutableDictionary *FUIvarEntry(id ivar, id target, NSString *declaringClass, BOOL includeValue) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"name"] = FUObjectMessage(ivar, @"name") ?: @"";
    entry[@"declaring_class"] = declaringClass ?: @"";
    entry[@"type_encoding"] = FUObjectMessage(ivar, @"typeEncoding") ?: @"";
    entry[@"details"] = FUTruncatedString(FUObjectMessage(ivar, @"details"), 1024);
    entry[@"offset"] = @((NSInteger)FUUnsignedMessage(ivar, @"offset", 0));
    entry[@"size"] = @(FUUnsignedMessage(ivar, @"size", 0));

    if (includeValue) {
        @try {
            SEL getterSEL = NSSelectorFromString(@"getPotentiallyUnboxedValue:");
            if ([ivar respondsToSelector:getterSEL]) {
                id value = ((id (*)(id, SEL, id))objc_msgSend)(ivar, getterSEL, target);
                entry[@"value"] = FUJSONValue(value);
            }
        } @catch (NSException *exception) {
            entry[@"value_error"] = FUTruncatedString(exception.reason ?: exception.name, 512);
        }
    }
    return entry;
}

NSMutableDictionary *FUMethodEntry(id method, NSString *declaringClass) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"name"] = FUObjectMessage(method, @"selectorString") ?: FUObjectMessage(method, @"name") ?: @"";
    entry[@"declaring_class"] = FUExactMethodDeclaringClass(method, declaringClass);
    entry[@"type_encoding"] = FUObjectMessage(method, @"typeEncoding") ?: @"";
    NSString *signature = FUObjectMessage(method, @"signatureString");
    if (signature) entry[@"signature"] = signature;
    entry[@"arguments"] = @(FUUnsignedMessage(method, @"numberOfArguments", 0));
    NSString *imagePath = FUObjectMessage(method, @"imagePath");
    if (imagePath.length) entry[@"image_path"] = imagePath;
    FUAppendMethodImplementationProvenance(entry, method);
    FUAppendInvocationMetadata(entry);
    return entry;
}

static BOOL FUQueryMatchesValue(id value, NSString *query) {
    if (!query.length) {
        return YES;
    }
    NSString *text = [value isKindOfClass:[NSString class]] ? value : [value description];
    return text.length && [text rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL FUMemberMatchesQuery(id member, NSString *declaringClass, NSString *query, BOOL method) {
    if (!query.length) {
        return YES;
    }
    if (FUQueryMatchesValue(FUObjectMessage(member, method ? @"selectorString" : @"name"), query) ||
        FUQueryMatchesValue(declaringClass, query)) {
        return YES;
    }
    if (method) {
        return FUQueryMatchesValue(FUObjectMessage(member, @"name"), query) ||
            FUQueryMatchesValue(FUObjectMessage(member, @"signatureString"), query);
    }
    return NO;
}

NSArray *FUPropertyMetadata(id explorer, id target, BOOL includeValues, NSUInteger offset, NSUInteger limit, NSString *query, NSUInteger *total) {
    NSArray *groups = FUObjectMessage(explorer, @"allProperties");
    NSArray *classes = FUObjectMessage(explorer, @"classHierarchyClasses");
    if (![groups isKindOfClass:[NSArray class]]) {
        if (total) *total = 0;
        return @[];
    }

    NSMutableArray *result = [NSMutableArray array];
    NSUInteger position = 0;
    for (NSUInteger scope = 0; scope < groups.count; scope++) {
        NSArray *items = [groups[scope] isKindOfClass:[NSArray class]] ? groups[scope] : @[];
        NSString *declaringClass = scope < classes.count ? FUClassName(classes[scope]) : @"";
        for (id property in items) {
            if (!FUMemberMatchesQuery(property, declaringClass, query, NO)) {
                continue;
            }
            NSUInteger matchPosition = position++;
            if (matchPosition < offset || result.count >= limit) {
                continue;
            }
            [result addObject:FUPropertyEntry(property, target, declaringClass, includeValues)];
        }
    }
    if (total) *total = position;
    return result;
}

NSArray *FUIvarMetadata(id explorer, id target, BOOL includeValues, NSUInteger offset, NSUInteger limit, NSString *query, NSUInteger *total) {
    NSArray *groups = FUObjectMessage(explorer, @"allIvars");
    NSArray *classes = FUObjectMessage(explorer, @"classHierarchyClasses");
    if (![groups isKindOfClass:[NSArray class]]) {
        if (total) *total = 0;
        return @[];
    }

    NSMutableArray *result = [NSMutableArray array];
    NSUInteger position = 0;
    for (NSUInteger scope = 0; scope < groups.count; scope++) {
        NSArray *items = [groups[scope] isKindOfClass:[NSArray class]] ? groups[scope] : @[];
        NSString *declaringClass = scope < classes.count ? FUClassName(classes[scope]) : @"";
        for (id ivar in items) {
            if (!FUMemberMatchesQuery(ivar, declaringClass, query, NO)) {
                continue;
            }
            NSUInteger matchPosition = position++;
            if (matchPosition < offset || result.count >= limit) {
                continue;
            }
            [result addObject:FUIvarEntry(ivar, target, declaringClass, includeValues)];
        }
    }
    if (total) *total = position;
    return result;
}

NSArray *FUMethodMetadata(id explorer, NSString *groupsSelector, NSUInteger offset, NSUInteger limit, NSString *query, NSUInteger *total) {
    NSArray *groups = FUObjectMessage(explorer, groupsSelector);
    NSArray *classes = FUObjectMessage(explorer, @"classHierarchyClasses");
    if (![groups isKindOfClass:[NSArray class]]) {
        if (total) *total = 0;
        return @[];
    }

    NSMutableArray *result = [NSMutableArray array];
    NSUInteger position = 0;
    for (NSUInteger scope = 0; scope < groups.count; scope++) {
        NSArray *items = [groups[scope] isKindOfClass:[NSArray class]] ? groups[scope] : @[];
        NSString *declaringClass = scope < classes.count ? FUClassName(classes[scope]) : @"";
        for (id method in items) {
            if (!FUMemberMatchesQuery(method, declaringClass, query, YES)) {
                continue;
            }
            NSUInteger matchPosition = position++;
            if (matchPosition < offset || result.count >= limit) {
                continue;
            }
            [result addObject:FUMethodEntry(method, declaringClass)];
        }
    }
    if (total) *total = position;
    return result;
}

id FUObjectExplorerForObject(id object) {
    Class explorerClass = NSClassFromString(@"FLEXObjectExplorer");
    SEL factory = NSSelectorFromString(@"forObject:");
    if (!explorerClass || ![explorerClass respondsToSelector:factory]) {
        return nil;
    }
    return ((id (*)(id, SEL, id))objc_msgSend)(explorerClass, factory, object);
}

static NSDictionary *FUFindMember(id explorer, NSString *name, NSString *kind) {
    NSArray<NSString *> *selectors = [kind isEqualToString:@"property"] ? @[@"allProperties"] :
        ([kind isEqualToString:@"ivar"] ? @[@"allIvars"] : @[@"allProperties", @"allIvars"]);
    NSArray *classes = FUObjectMessage(explorer, @"classHierarchyClasses");

    for (NSString *selectorName in selectors) {
        NSArray *groups = FUObjectMessage(explorer, selectorName);
        for (NSUInteger scope = 0; scope < groups.count; scope++) {
            NSArray *items = [groups[scope] isKindOfClass:[NSArray class]] ? groups[scope] : @[];
            for (id member in items) {
                if ([[FUObjectMessage(member, @"name") description] isEqualToString:name]) {
                    return @{
                        @"member": member,
                        @"kind": [selectorName isEqualToString:@"allProperties"] ? @"property" : @"ivar",
                        @"declaring_class": scope < classes.count ? FUClassName(classes[scope]) : @"",
                    };
                }
            }
        }
    }
    return nil;
}

id FUObjectTargetFromRequest(NSString *requestID, NSDictionary *request, NSString **resolvedHandle, NSString **targetSource, NSString **resolvedBy, NSDictionary **errorResponse) {
    NSString *handle = [request[@"handle"] isKindOfClass:[NSString class]] ? request[@"handle"] : @"";
    NSDictionary *uiSelector = [request[@"ui_selector"] isKindOfClass:[NSDictionary class]] ? request[@"ui_selector"] : nil;
    if (handle.length && uiSelector) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_target", @"Provide either handle or ui_selector, not both."));
        return nil;
    }

    if (handle.length) {
        id object = FUObjectForHandle(handle);
        if (!object) {
            if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(handle, @"The object handle is unknown or the object has expired."));
            return nil;
        }
        if (resolvedHandle) *resolvedHandle = handle;
        if (targetSource) *targetSource = @"handle";
        return object;
    }

    if (!uiSelector) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_target", @"A process-scoped handle or stable ui_selector is required."));
        return nil;
    }

    NSMutableDictionary *resolveRequest = [request mutableCopy];
    resolveRequest[@"selector"] = uiSelector;
    [resolveRequest removeObjectForKey:@"ui_selector"];
    NSDictionary *resolveResponse = FUHandleUIResolve(requestID, resolveRequest);
    if (![resolveResponse[@"ok"] boolValue]) {
        if (errorResponse) *errorResponse = resolveResponse;
        return nil;
    }

    NSDictionary *result = [resolveResponse[@"result"] isKindOfClass:[NSDictionary class]] ? resolveResponse[@"result"] : @{};
    NSDictionary *match = [result[@"match"] isKindOfClass:[NSDictionary class]] ? result[@"match"] : @{};
    NSString *selectorHandle = [match[@"id"] isKindOfClass:[NSString class]] ? match[@"id"] : @"";
    id object = selectorHandle.length ? FUObjectForHandle(selectorHandle) : nil;
    if (!object) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"object_not_found", @"The stable selector resolved, but its object handle is no longer live."));
        return nil;
    }

    if (resolvedHandle) *resolvedHandle = selectorHandle;
    if (targetSource) *targetSource = @"ui_selector";
    if (resolvedBy) *resolvedBy = [result[@"resolved_by"] isKindOfClass:[NSString class]] ? result[@"resolved_by"] : nil;
    return object;
}

NSDictionary *FUHandleObjectList(NSString *requestID, NSDictionary *request, NSString *kind) {
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    id object = FUObjectTargetFromRequest(requestID, request, nil, &targetSource, &resolvedBy, &targetError);
    if (!object) return targetError;
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for object inspection."));
    }

    NSUInteger offset = 0;
    NSUInteger limit = 100;
    if (!FUObjectRequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }
    id queryValue = request[@"query"];
    if (queryValue && ![queryValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_query", @"query must be a string."));
    }
    NSString *query = [queryValue isKindOfClass:[NSString class]] ? queryValue : @"";
    BOOL includeValues = ![request[@"include_values"] respondsToSelector:@selector(boolValue)] || [request[@"include_values"] boolValue];
    BOOL classMethods = [request[@"class_methods"] boolValue];

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            id explorer = FUObjectExplorerForObject(object);
            if (!explorer) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXObjectExplorer."));
                return;
            }

            NSUInteger total = 0;
            NSArray *items = nil;
            NSString *itemsKey = nil;
            if ([kind isEqualToString:@"properties"]) {
                items = FUPropertyMetadata(explorer, object, includeValues, offset, limit, query, &total);
                itemsKey = @"properties";
            } else if ([kind isEqualToString:@"ivars"]) {
                items = FUIvarMetadata(explorer, object, includeValues, offset, limit, query, &total);
                itemsKey = @"ivars";
            } else {
                items = FUMethodMetadata(explorer, classMethods ? @"allClassMethods" : @"allMethods", offset, limit, query, &total);
                itemsKey = @"methods";
            }

            NSMutableDictionary *result = [FUObjectReference(object) mutableCopy];
            result[itemsKey] = items ?: @[];
            result[@"offset"] = @(offset);
            result[@"limit"] = @(limit);
            result[@"total"] = @(total);
            result[@"has_more"] = @(offset + items.count < total);
            result[@"target_source"] = targetSource ?: @"handle";
            if (queryValue) result[@"query"] = query;
            if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
            if (![kind isEqualToString:@"methods"]) {
                result[@"include_values"] = @(includeValues);
            } else {
                result[@"method_kind"] = classMethods ? @"class" : @"instance";
            }
            response = FUResponse(requestID, YES, result, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"inspection_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return response;
}

static id FUBoxIvarValue(id value, NSString *typeEncoding) {
    if ([value isKindOfClass:[NSNull class]]) {
        return nil;
    }
    if ([typeEncoding hasPrefix:@"@"] || [typeEncoding hasPrefix:@"#"]) {
        return value;
    }
    if (![value isKindOfClass:[NSNumber class]] || typeEncoding.length == 0) {
        return nil;
    }

    const char *type = typeEncoding.UTF8String;
    if (type[0] == 'B' && type[1] == '\0') {
        BOOL booleanValue = [value boolValue];
        return [NSValue value:&booleanValue withObjCType:type];
    }

    Class utility = NSClassFromString(@"FLEXRuntimeUtility");
    SEL selector = NSSelectorFromString(@"valueForNumberWithObjCType:fromInputString:");
    if (!utility || ![utility respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL, const char *, id))objc_msgSend)(utility, selector, type, [value stringValue]);
}

static const char *FUSkipTypeQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) {
        type++;
    }
    return type;
}

static BOOL FUDecodeObjectSetValue(id incomingValue, NSString *typeEncoding, id *decodedValue, NSString **errorCode, NSString **errorMessage) {
    const char *type = FUSkipTypeQualifiers(typeEncoding.UTF8String);
    BOOL objectValued = type && (type[0] == '@' || type[0] == '#');

    if (incomingValue == NSNull.null) {
        if (!objectValued) {
            if (errorCode) *errorCode = @"invalid_value";
            if (errorMessage) *errorMessage = @"JSON null can only be assigned to object-valued members.";
            return NO;
        }
        if (decodedValue) *decodedValue = nil;
        return YES;
    }

    if ([incomingValue isKindOfClass:[NSDictionary class]]) {
        NSString *handle = [incomingValue[@"handle"] isKindOfClass:[NSString class]] ? incomingValue[@"handle"] : nil;
        if (handle.length == 0) {
            if (errorCode) *errorCode = @"unsupported_value";
            if (errorMessage) *errorMessage = @"object.set accepts JSON scalars or an object reference shaped as {\"handle\":\"obj_<generation>_<counter>\"}.";
            return NO;
        }
        if (!objectValued) {
            if (errorCode) *errorCode = @"invalid_value";
            if (errorMessage) *errorMessage = @"Object handles can only be assigned to object-valued members.";
            return NO;
        }
        id referenced = FUObjectForHandle(handle);
        if (!referenced) {
            FUObjectHandleErrorParts(handle, @"The assigned object handle is unknown or the object has expired.", errorCode, errorMessage);
            return NO;
        }
        if (type[0] == '#' && !object_isClass(referenced)) {
            if (errorCode) *errorCode = @"invalid_value";
            if (errorMessage) *errorMessage = @"Class-valued members require a class-object handle.";
            return NO;
        }
        if (decodedValue) *decodedValue = referenced;
        return YES;
    }

    if (![incomingValue isKindOfClass:[NSString class]] && ![incomingValue isKindOfClass:[NSNumber class]]) {
        if (errorCode) *errorCode = @"unsupported_value";
        if (errorMessage) *errorMessage = @"object.set accepts JSON null, booleans, numbers, strings, or an object handle reference.";
        return NO;
    }

    if (decodedValue) *decodedValue = incomingValue;
    return YES;
}

typedef NS_ENUM(NSUInteger, FUInvocationStructKind) {
    FUInvocationStructKindNone = 0,
    FUInvocationStructKindCGPoint,
    FUInvocationStructKindCGSize,
    FUInvocationStructKindCGRect,
    FUInvocationStructKindUIEdgeInsets,
    FUInvocationStructKindNSRange,
};

static FUInvocationStructKind FUInvocationStructKindForType(const char *rawType) {
    const char *type = FUSkipTypeQualifiers(rawType);
    if (!type || !*type) return FUInvocationStructKindNone;
    if (strcmp(type, @encode(CGPoint)) == 0) return FUInvocationStructKindCGPoint;
    if (strcmp(type, @encode(CGSize)) == 0) return FUInvocationStructKindCGSize;
    if (strcmp(type, @encode(CGRect)) == 0) return FUInvocationStructKindCGRect;
    if (strcmp(type, @encode(UIEdgeInsets)) == 0) return FUInvocationStructKindUIEdgeInsets;
    if (strcmp(type, @encode(NSRange)) == 0) return FUInvocationStructKindNSRange;
    return FUInvocationStructKindNone;
}

static NSString *FUInvocationStructName(FUInvocationStructKind kind) {
    switch (kind) {
        case FUInvocationStructKindCGPoint: return @"CGPoint";
        case FUInvocationStructKindCGSize: return @"CGSize";
        case FUInvocationStructKindCGRect: return @"CGRect";
        case FUInvocationStructKindUIEdgeInsets: return @"UIEdgeInsets";
        case FUInvocationStructKindNSRange: return @"NSRange";
        default: return nil;
    }
}

static BOOL FUInvocationStructDictionary(id value, FUInvocationStructKind kind, NSUInteger argumentIndex, NSDictionary **dictionary, NSString **errorCode, NSString **errorMessage) {
    NSString *expectedType = FUInvocationStructName(kind);
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (errorCode) *errorCode = @"invalid_argument";
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu must be a typed %@ JSON object.", (unsigned long)argumentIndex, expectedType ?: @"struct"];
        return NO;
    }
    NSString *declaredType = [value[@"type"] isKindOfClass:[NSString class]] ? value[@"type"] : nil;
    if (expectedType.length == 0 || ![declaredType isEqualToString:expectedType]) {
        if (errorCode) *errorCode = @"invalid_argument";
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu must declare type '%@'.", (unsigned long)argumentIndex, expectedType ?: @"unknown"];
        return NO;
    }
    if (dictionary) *dictionary = value;
    return YES;
}

static BOOL FUInvocationStructCGFloat(NSDictionary *dictionary, NSString *field, NSUInteger argumentIndex, NSString *structName, CGFloat *output, NSString **errorCode, NSString **errorMessage) {
    id raw = dictionary[field];
    if (![raw isKindOfClass:[NSNumber class]]) {
        if (errorCode) *errorCode = @"invalid_argument";
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu %@.%@ must be numeric.", (unsigned long)argumentIndex, structName, field];
        return NO;
    }
    double number = [raw doubleValue];
    if (!isfinite(number)) {
        if (errorCode) *errorCode = @"invalid_argument";
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu %@.%@ must be finite.", (unsigned long)argumentIndex, structName, field];
        return NO;
    }
    if (output) *output = (CGFloat)number;
    return YES;
}

static BOOL FUInvocationStructNSUInteger(NSDictionary *dictionary, NSString *field, NSUInteger argumentIndex, NSString *structName, NSUInteger *output, NSString **errorCode, NSString **errorMessage) {
    id raw = dictionary[field];
    if (![raw isKindOfClass:[NSNumber class]]) {
        if (errorCode) *errorCode = @"invalid_argument";
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu %@.%@ must be a non-negative integer.", (unsigned long)argumentIndex, structName, field];
        return NO;
    }
    double number = [raw doubleValue];
    if (!isfinite(number) || number < 0 || floor(number) != number || number > (double)NSUIntegerMax) {
        if (errorCode) *errorCode = @"invalid_argument";
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu %@.%@ must be a non-negative integer within NSUInteger range.", (unsigned long)argumentIndex, structName, field];
        return NO;
    }
    if (output) *output = (NSUInteger)[raw unsignedLongLongValue];
    return YES;
}

static BOOL FUInvocationTypeSupported(const char *rawType, BOOL allowVoid) {
    const char *type = FUSkipTypeQualifiers(rawType);
    if (!type || !*type) return NO;
    if (allowVoid && type[0] == 'v') return YES;
    if (type[0] == '@' && type[1] == '?') return NO;
    if (FUInvocationStructKindForType(type) != FUInvocationStructKindNone) return YES;
    return strchr("@#:BcCsSiIlLqQfd", type[0]) != NULL;
}

static NSString *FUInvocationEncodingString(const char *rawType) {
    const char *type = FUSkipTypeQualifiers(rawType);
    if (!type || !*type) return @"";
    return [NSString stringWithUTF8String:type] ?: @"";
}

static NSDictionary *FUInvocationStructShape(FUInvocationStructKind kind) {
    NSArray *fields = nil;
    switch (kind) {
        case FUInvocationStructKindCGPoint: fields = @[@"x", @"y"]; break;
        case FUInvocationStructKindCGSize: fields = @[@"width", @"height"]; break;
        case FUInvocationStructKindCGRect: fields = @[@"x", @"y", @"width", @"height"]; break;
        case FUInvocationStructKindUIEdgeInsets: fields = @[@"top", @"left", @"bottom", @"right"]; break;
        case FUInvocationStructKindNSRange: fields = @[@"location", @"length"]; break;
        default: return @{ @"kind": @"unsupported" };
    }
    return @{
        @"kind": @"struct",
        @"type": FUInvocationStructName(kind) ?: @"",
        @"fields": fields,
    };
}

static NSDictionary *FUInvocationTypeMetadata(const char *rawType, BOOL allowVoid, BOOL argument) {
    const char *type = FUSkipTypeQualifiers(rawType);
    NSString *encoding = FUInvocationEncodingString(type);
    BOOL supported = NO;
    NSString *mode = @"unsupported";
    NSDictionary *shape = @{ @"kind": @"unsupported" };

    if (type && *type) {
        if (allowVoid && type[0] == 'v') {
            supported = YES;
            mode = @"supported";
            shape = @{ @"kind": @"void" };
        } else if (type[0] == '@' && type[1] == '?') {
            if (argument) {
                supported = YES;
                mode = @"nil_only";
                shape = @{ @"kind": @"block", @"accepted": @[@"null"] };
            } else {
                shape = @{ @"kind": @"block" };
            }
        } else {
            FUInvocationStructKind structKind = FUInvocationStructKindForType(type);
            if (structKind != FUInvocationStructKindNone) {
                supported = YES;
                mode = @"supported";
                shape = FUInvocationStructShape(structKind);
            } else if (FUInvocationTypeSupported(type, allowVoid)) {
                supported = YES;
                mode = @"supported";
                switch (type[0]) {
                    case '@':
                        shape = argument ? @{ @"kind": @"object", @"accepted": @[@"json_value", @"object_handle", @"null"] } : @{ @"kind": @"object" };
                        break;
                    case '#':
                        shape = argument ? @{ @"kind": @"class", @"accepted": @[@"class_name", @"class_object_handle"] } : @{ @"kind": @"class" };
                        break;
                    case ':':
                        shape = argument ? @{ @"kind": @"selector", @"accepted": @[@"selector_string"] } : @{ @"kind": @"selector" };
                        break;
                    case 'B':
                        shape = argument ? @{ @"kind": @"boolean", @"accepted": @[@"boolean", @"number"] } : @{ @"kind": @"boolean" };
                        break;
                    case 'c': case 'C': case 's': case 'S': case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q':
                        shape = argument ? @{ @"kind": @"integer", @"accepted": @[@"number"] } : @{ @"kind": @"integer" };
                        break;
                    case 'f': case 'd':
                        shape = argument ? @{ @"kind": @"number", @"accepted": @[@"number"] } : @{ @"kind": @"number" };
                        break;
                    default:
                        supported = NO;
                        mode = @"unsupported";
                        shape = @{ @"kind": @"unsupported" };
                        break;
                }
            }
        }
    }

    return @{
        @"encoding": encoding,
        @"supported": @(supported),
        @"mode": mode,
        @"shape": shape,
    };
}

static void FUAppendInvocationMetadata(NSMutableDictionary *entry) {
    NSString *typeEncoding = [entry[@"type_encoding"] isKindOfClass:[NSString class]] ? entry[@"type_encoding"] : @"";
    NSMutableDictionary *metadata = [@{
        @"callable": @NO,
        @"argument_count": @0,
        @"return": FUInvocationTypeMetadata("", YES, NO),
        @"arguments": @[],
    } mutableCopy];
    if (typeEncoding.length == 0) {
        entry[@"invocation"] = metadata;
        return;
    }

    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:typeEncoding.UTF8String];
        if (!signature) {
            entry[@"invocation"] = metadata;
            return;
        }

        NSDictionary *returnMetadata = FUInvocationTypeMetadata(signature.methodReturnType, YES, NO);
        NSMutableArray *arguments = [NSMutableArray array];
        BOOL callable = [returnMetadata[@"supported"] boolValue];
        NSUInteger count = signature.numberOfArguments >= 2 ? signature.numberOfArguments - 2 : 0;
        for (NSUInteger index = 0; index < count; index++) {
            NSDictionary *argumentMetadata = FUInvocationTypeMetadata([signature getArgumentTypeAtIndex:index + 2], NO, YES);
            NSMutableDictionary *argumentEntry = [argumentMetadata mutableCopy];
            argumentEntry[@"index"] = @(index);
            [arguments addObject:argumentEntry];
            if (![argumentMetadata[@"supported"] boolValue]) callable = NO;
        }

        metadata[@"callable"] = @(callable);
        metadata[@"argument_count"] = @(count);
        metadata[@"return"] = returnMetadata;
        metadata[@"arguments"] = arguments;
    } @catch (__unused NSException *exception) {
    }
    entry[@"invocation"] = metadata;
}

static BOOL FUSetInvocationArgument(NSInvocation *invocation, NSUInteger index, const char *rawType, id value, NSString **errorCode, NSString **errorMessage) {
    const char *type = FUSkipTypeQualifiers(rawType);
    if (type[0] == '@' && type[1] == '?') {
        if (value == NSNull.null) {
            id nilBlock = nil;
            [invocation setArgument:&nilBlock atIndex:index];
            return YES;
        }
        if (errorCode) *errorCode = @"unsupported_argument_type";
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu is an Objective-C block; only JSON null is supported for block parameters.", (unsigned long)(index - 2)];
        return NO;
    }
    if (!FUInvocationTypeSupported(type, NO)) {
        if (errorCode) *errorCode = @"unsupported_argument_type";
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu has unsupported Objective-C type '%s'.", (unsigned long)(index - 2), type];
        return NO;
    }

    FUInvocationStructKind structKind = FUInvocationStructKindForType(type);
    if (structKind != FUInvocationStructKindNone) {
        NSUInteger argumentIndex = index - 2;
        NSString *structName = FUInvocationStructName(structKind);
        NSDictionary *dictionary = nil;
        if (!FUInvocationStructDictionary(value, structKind, argumentIndex, &dictionary, errorCode, errorMessage)) return NO;
        switch (structKind) {
            case FUInvocationStructKindCGPoint: {
                CGPoint v = CGPointZero;
                if (!FUInvocationStructCGFloat(dictionary, @"x", argumentIndex, structName, &v.x, errorCode, errorMessage) ||
                    !FUInvocationStructCGFloat(dictionary, @"y", argumentIndex, structName, &v.y, errorCode, errorMessage)) return NO;
                [invocation setArgument:&v atIndex:index];
                return YES;
            }
            case FUInvocationStructKindCGSize: {
                CGSize v = CGSizeZero;
                if (!FUInvocationStructCGFloat(dictionary, @"width", argumentIndex, structName, &v.width, errorCode, errorMessage) ||
                    !FUInvocationStructCGFloat(dictionary, @"height", argumentIndex, structName, &v.height, errorCode, errorMessage)) return NO;
                [invocation setArgument:&v atIndex:index];
                return YES;
            }
            case FUInvocationStructKindCGRect: {
                CGRect v = CGRectZero;
                if (!FUInvocationStructCGFloat(dictionary, @"x", argumentIndex, structName, &v.origin.x, errorCode, errorMessage) ||
                    !FUInvocationStructCGFloat(dictionary, @"y", argumentIndex, structName, &v.origin.y, errorCode, errorMessage) ||
                    !FUInvocationStructCGFloat(dictionary, @"width", argumentIndex, structName, &v.size.width, errorCode, errorMessage) ||
                    !FUInvocationStructCGFloat(dictionary, @"height", argumentIndex, structName, &v.size.height, errorCode, errorMessage)) return NO;
                [invocation setArgument:&v atIndex:index];
                return YES;
            }
            case FUInvocationStructKindUIEdgeInsets: {
                UIEdgeInsets v = UIEdgeInsetsZero;
                if (!FUInvocationStructCGFloat(dictionary, @"top", argumentIndex, structName, &v.top, errorCode, errorMessage) ||
                    !FUInvocationStructCGFloat(dictionary, @"left", argumentIndex, structName, &v.left, errorCode, errorMessage) ||
                    !FUInvocationStructCGFloat(dictionary, @"bottom", argumentIndex, structName, &v.bottom, errorCode, errorMessage) ||
                    !FUInvocationStructCGFloat(dictionary, @"right", argumentIndex, structName, &v.right, errorCode, errorMessage)) return NO;
                [invocation setArgument:&v atIndex:index];
                return YES;
            }
            case FUInvocationStructKindNSRange: {
                NSRange v = NSMakeRange(0, 0);
                if (!FUInvocationStructNSUInteger(dictionary, @"location", argumentIndex, structName, &v.location, errorCode, errorMessage) ||
                    !FUInvocationStructNSUInteger(dictionary, @"length", argumentIndex, structName, &v.length, errorCode, errorMessage)) return NO;
                [invocation setArgument:&v atIndex:index];
                return YES;
            }
            default: break;
        }
    }

    if (type[0] == '@') {
        id objectValue = value == NSNull.null ? nil : value;
        if ([value isKindOfClass:[NSDictionary class]] && [value[@"handle"] isKindOfClass:[NSString class]]) {
            NSString *handle = value[@"handle"];
            objectValue = FUObjectForHandle(handle);
            if (!objectValue) {
                FUObjectHandleErrorParts(handle, [NSString stringWithFormat:@"Argument %lu references an unknown or expired object handle.", (unsigned long)(index - 2)], errorCode, errorMessage);
                return NO;
            }
        }
        [invocation setArgument:&objectValue atIndex:index];
        return YES;
    }
    if (type[0] == '#') {
        Class classValue = Nil;
        if ([value isKindOfClass:[NSString class]]) {
            classValue = NSClassFromString(value);
        } else if ([value isKindOfClass:[NSDictionary class]] && [value[@"handle"] isKindOfClass:[NSString class]]) {
            NSString *handle = value[@"handle"];
            id referenced = FUObjectForHandle(handle);
            if (referenced && object_isClass(referenced)) classValue = referenced;
            if (!referenced) {
                FUObjectHandleErrorParts(handle, [NSString stringWithFormat:@"Argument %lu references an unknown or expired class-object handle.", (unsigned long)(index - 2)], errorCode, errorMessage);
                return NO;
            }
        }
        if (!classValue) {
            if (errorCode) *errorCode = @"invalid_argument";
            if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu must be a valid class name or class-object handle.", (unsigned long)(index - 2)];
            return NO;
        }
        [invocation setArgument:&classValue atIndex:index];
        return YES;
    }
    if (type[0] == ':') {
        if (![value isKindOfClass:[NSString class]] || [value length] == 0) {
            if (errorCode) *errorCode = @"invalid_argument";
            if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu must be a selector string.", (unsigned long)(index - 2)];
            return NO;
        }
        SEL selectorValue = NSSelectorFromString(value);
        [invocation setArgument:&selectorValue atIndex:index];
        return YES;
    }
    if (![value isKindOfClass:[NSNumber class]]) {
        if (errorCode) *errorCode = @"invalid_argument";
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu must be numeric for Objective-C type '%c'.", (unsigned long)(index - 2), type[0]];
        return NO;
    }

    switch (type[0]) {
        case 'B': { BOOL v = [value boolValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'c': { char v = [value charValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'C': { unsigned char v = [value unsignedCharValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 's': { short v = [value shortValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'S': { unsigned short v = [value unsignedShortValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'i': { int v = [value intValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'I': { unsigned int v = [value unsignedIntValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'l': { long v = [value longValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'L': { unsigned long v = [value unsignedLongValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'q': { long long v = [value longLongValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'Q': { unsigned long long v = [value unsignedLongLongValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'f': { float v = [value floatValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'd': { double v = [value doubleValue]; [invocation setArgument:&v atIndex:index]; return YES; }
        default: break;
    }
    if (errorCode) *errorCode = @"unsupported_argument_type";
    if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Argument %lu has unsupported Objective-C type '%s'.", (unsigned long)(index - 2), type];
    return NO;
}

static id FUInvocationReturnValue(NSInvocation *invocation, NSMethodSignature *signature, BOOL pinResult, BOOL *didPin) {
    if (didPin) *didPin = NO;
    const char *type = FUSkipTypeQualifiers(signature.methodReturnType);
    switch (FUInvocationStructKindForType(type)) {
        case FUInvocationStructKindCGPoint: {
            CGPoint v = CGPointZero;
            [invocation getReturnValue:&v];
            return @{ @"type": @"CGPoint", @"x": FUJSONFloatingNumber(v.x), @"y": FUJSONFloatingNumber(v.y) };
        }
        case FUInvocationStructKindCGSize: {
            CGSize v = CGSizeZero;
            [invocation getReturnValue:&v];
            return @{ @"type": @"CGSize", @"width": FUJSONFloatingNumber(v.width), @"height": FUJSONFloatingNumber(v.height) };
        }
        case FUInvocationStructKindCGRect: {
            CGRect v = CGRectZero;
            [invocation getReturnValue:&v];
            return @{ @"type": @"CGRect", @"x": FUJSONFloatingNumber(v.origin.x), @"y": FUJSONFloatingNumber(v.origin.y), @"width": FUJSONFloatingNumber(v.size.width), @"height": FUJSONFloatingNumber(v.size.height) };
        }
        case FUInvocationStructKindUIEdgeInsets: {
            UIEdgeInsets v = UIEdgeInsetsZero;
            [invocation getReturnValue:&v];
            return @{ @"type": @"UIEdgeInsets", @"top": FUJSONFloatingNumber(v.top), @"left": FUJSONFloatingNumber(v.left), @"bottom": FUJSONFloatingNumber(v.bottom), @"right": FUJSONFloatingNumber(v.right) };
        }
        case FUInvocationStructKindNSRange: {
            NSRange v = NSMakeRange(0, 0);
            [invocation getReturnValue:&v];
            return @{ @"type": @"NSRange", @"location": @(v.location), @"length": @(v.length) };
        }
        default: break;
    }
    switch (type[0]) {
        case 'v': return NSNull.null;
        case '@': {
            __unsafe_unretained id value = nil;
            [invocation getReturnValue:&value];
            if (pinResult && value) {
                FUPinObject(value);
                if (didPin) *didPin = YES;
            }
            return FUJSONValue(value);
        }
        case '#': {
            __unsafe_unretained Class value = Nil;
            [invocation getReturnValue:&value];
            if (pinResult && value) {
                FUPinObject(value);
                if (didPin) *didPin = YES;
            }
            return value ? @{ @"kind": @"class", @"name": NSStringFromClass(value) ?: @"", @"object": FUObjectReference(value) } : NSNull.null;
        }
        case ':': {
            SEL value = NULL;
            [invocation getReturnValue:&value];
            return value ? NSStringFromSelector(value) : NSNull.null;
        }
        case 'B': { BOOL v = NO; [invocation getReturnValue:&v]; return @(v); }
        case 'c': { char v = 0; [invocation getReturnValue:&v]; return @(v); }
        case 'C': { unsigned char v = 0; [invocation getReturnValue:&v]; return @(v); }
        case 's': { short v = 0; [invocation getReturnValue:&v]; return @(v); }
        case 'S': { unsigned short v = 0; [invocation getReturnValue:&v]; return @(v); }
        case 'i': { int v = 0; [invocation getReturnValue:&v]; return @(v); }
        case 'I': { unsigned int v = 0; [invocation getReturnValue:&v]; return @(v); }
        case 'l': { long v = 0; [invocation getReturnValue:&v]; return @(v); }
        case 'L': { unsigned long v = 0; [invocation getReturnValue:&v]; return @(v); }
        case 'q': { long long v = 0; [invocation getReturnValue:&v]; return @(v); }
        case 'Q': { unsigned long long v = 0; [invocation getReturnValue:&v]; return @(v); }
        case 'f': { float v = 0; [invocation getReturnValue:&v]; return FUJSONFloatingNumber(v); }
        case 'd': { double v = 0; [invocation getReturnValue:&v]; return FUJSONFloatingNumber(v); }
        default: return NSNull.null;
    }
}

NSDictionary *FUHandleObjectCall(NSString *requestID, NSDictionary *request) {
    NSString *selectorName = [request[@"selector"] isKindOfClass:[NSString class]] ? request[@"selector"] : @"";
    NSString *methodKind = [request[@"method_kind"] isKindOfClass:[NSString class]] ? request[@"method_kind"] : @"instance";
    NSArray *arguments = [request[@"arguments"] isKindOfClass:[NSArray class]] ? request[@"arguments"] : @[];
    BOOL pinResult = [request[@"pin_result"] respondsToSelector:@selector(boolValue)] && [request[@"pin_result"] boolValue];
    if (![@[@"instance", @"class"] containsObject:methodKind]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_method_kind", @"method_kind must be instance or class."));
    }
    if (selectorName.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_selector", @"A selector is required."));
    }
    NSString *resolvedHandle = nil;
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    id object = FUObjectTargetFromRequest(requestID, request, &resolvedHandle, &targetSource, &resolvedBy, &targetError);
    if (!object) return targetError;

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            id receiver = object;
            if ([methodKind isEqualToString:@"class"]) {
                receiver = object_isClass(object) ? object : [object class];
            }
            SEL selector = NSSelectorFromString(selectorName);
            if (![receiver respondsToSelector:selector]) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"selector_not_found", [NSString stringWithFormat:@"%@ does not respond to selector '%@'.", FUClassName(receiver), selectorName]));
                return;
            }

            NSMethodSignature *signature = [receiver methodSignatureForSelector:selector];
            if (!signature) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"signature_unavailable", @"The target did not provide a method signature for the selector."));
                return;
            }
            NSUInteger expectedArguments = signature.numberOfArguments >= 2 ? signature.numberOfArguments - 2 : 0;
            if (arguments.count != expectedArguments) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"argument_count_mismatch", [NSString stringWithFormat:@"Selector '%@' expects %lu argument(s), but %lu were provided.", selectorName, (unsigned long)expectedArguments, (unsigned long)arguments.count]));
                return;
            }
            if (!FUInvocationTypeSupported(signature.methodReturnType, YES)) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_return_type", [NSString stringWithFormat:@"Selector '%@' returns unsupported Objective-C type '%s'.", selectorName, FUSkipTypeQualifiers(signature.methodReturnType)]));
                return;
            }

            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = receiver;
            invocation.selector = selector;
            for (NSUInteger i = 0; i < arguments.count; i++) {
                NSString *errorCode = nil;
                NSString *errorMessage = nil;
                if (!FUSetInvocationArgument(invocation, i + 2, [signature getArgumentTypeAtIndex:i + 2], arguments[i], &errorCode, &errorMessage)) {
                    response = FUResponse(requestID, NO, nil, FUErrorInfo(errorCode ?: @"invalid_argument", errorMessage ?: @"Unable to encode method argument."));
                    return;
                }
            }

            [invocation retainArguments];
            [invocation invoke];

            BOOL didPin = NO;
            id returnValue = FUInvocationReturnValue(invocation, signature, pinResult, &didPin);
            NSMutableDictionary *result = [@{
                @"id": resolvedHandle ?: @"",
                @"class": FUClassName(object),
                @"selector": selectorName,
                @"method_kind": methodKind,
                @"argument_count": @(arguments.count),
                @"return_type": [NSString stringWithUTF8String:FUSkipTypeQualifiers(signature.methodReturnType)] ?: @"",
                @"value": returnValue ?: NSNull.null,
                @"pin_result": @(pinResult),
                @"pinned": @(didPin),
                @"target_source": targetSource ?: @"handle",
            } mutableCopy];
            if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
            response = FUResponse(requestID, YES, result, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invocation_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return response;
}

NSDictionary *FUHandleObjectPin(NSString *requestID, NSDictionary *request) {
    NSString *resolvedHandle = nil;
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    id object = FUObjectTargetFromRequest(requestID, request, &resolvedHandle, &targetSource, &resolvedBy, &targetError);
    if (!object) return targetError;

    NSString *handle = FUPinObject(object);
    if (!handle) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"object_not_found", @"The object could not be retained."));
    }

    NSMutableDictionary *result = [@{
        @"id": handle,
        @"object": FUObjectReference(object),
        @"pinned": @YES,
        @"target_source": targetSource ?: @"handle",
    } mutableCopy];
    if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
    return FUResponse(requestID, YES, result, nil);
}

NSDictionary *FUHandleObjectUnpin(NSString *requestID, NSDictionary *request) {
    NSString *handle = [request[@"handle"] isKindOfClass:[NSString class]] ? request[@"handle"] : @"";
    if (handle.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"object.unpin requires a handle."));
    }

    id object = FUObjectForHandle(handle);
    if (!object) {
        return FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(handle, @"The object handle is unknown or the object has expired."));
    }

    NSDictionary *reference = FUObjectReference(object);
    BOOL wasPinned = FUUnpinObjectHandle(handle);

    return FUResponse(requestID, YES, @{
        @"id": handle,
        @"object": reference,
        @"pinned": @NO,
        @"released": @(wasPinned),
    }, nil);
}

NSDictionary *FUHandleObjectGetSet(NSString *requestID, NSDictionary *request, BOOL setValue) {
    NSString *name = [request[@"name"] isKindOfClass:[NSString class]] ? request[@"name"] : @"";
    NSString *kind = [request[@"member_kind"] isKindOfClass:[NSString class]] ? request[@"member_kind"] : @"auto";
    if (![@[@"auto", @"property", @"ivar"] containsObject:kind]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_member_kind", @"member_kind must be auto, property, or ivar."));
    }
    if (name.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_member", @"A property or ivar name is required."));
    }
    if (setValue && request[@"value"] == nil) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"missing_value", @"object.set requires a value field. Use JSON null to assign nil to an object member."));
    }
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    id object = FUObjectTargetFromRequest(requestID, request, nil, &targetSource, &resolvedBy, &targetError);
    if (!object) return targetError;
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for object inspection."));
    }

    id incomingValue = request[@"value"];

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            id explorer = FUObjectExplorerForObject(object);
            if (!explorer) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXObjectExplorer."));
                return;
            }
            NSDictionary *match = FUFindMember(explorer, name, kind);
            if (!match) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"member_not_found", [NSString stringWithFormat:@"No %@ named '%@' was found on this object.", [kind isEqualToString:@"auto"] ? @"property or ivar" : kind, name]));
                return;
            }

            id member = match[@"member"];
            NSString *resolvedKind = match[@"kind"];
            NSString *declaringClass = match[@"declaring_class"] ?: @"";
            NSString *typeEncoding = nil;
            id decodedValue = incomingValue;

            if ([resolvedKind isEqualToString:@"property"]) {
                id attributes = FUObjectMessage(member, @"attributes");
                typeEncoding = FUObjectMessage(attributes, @"typeEncoding") ?: @"";
                if (setValue) {
                    if (FUBoolMessage(attributes, @"isReadOnly", NO) || !FUBoolMessage(member, @"likelySetterExists", NO)) {
                        response = FUResponse(requestID, NO, nil, FUErrorInfo(@"member_readonly", @"The selected property does not expose a writable setter."));
                        return;
                    }
                    NSString *decodeErrorCode = nil;
                    NSString *decodeErrorMessage = nil;
                    if (!FUDecodeObjectSetValue(incomingValue, typeEncoding, &decodedValue, &decodeErrorCode, &decodeErrorMessage)) {
                        response = FUResponse(requestID, NO, nil, FUErrorInfo(decodeErrorCode ?: @"invalid_value", decodeErrorMessage ?: @"The value cannot be assigned to this property."));
                        return;
                    }
                    [object setValue:decodedValue forKey:name];
                }
            } else {
                typeEncoding = FUObjectMessage(member, @"typeEncoding") ?: @"";
                if (setValue) {
                    SEL setter = NSSelectorFromString(@"setValue:onObject:");
                    if (![member respondsToSelector:setter]) {
                        response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXIvar mutation."));
                        return;
                    }
                    NSString *decodeErrorCode = nil;
                    NSString *decodeErrorMessage = nil;
                    if (!FUDecodeObjectSetValue(incomingValue, typeEncoding, &decodedValue, &decodeErrorCode, &decodeErrorMessage)) {
                        response = FUResponse(requestID, NO, nil, FUErrorInfo(decodeErrorCode ?: @"invalid_value", decodeErrorMessage ?: @"The value cannot be assigned to this ivar."));
                        return;
                    }
                    id boxedValue = nil;
                    const char *rawType = FUSkipTypeQualifiers(typeEncoding.UTF8String);
                    if (rawType && (rawType[0] == '@' || rawType[0] == '#')) {
                        boxedValue = decodedValue;
                    } else {
                        boxedValue = FUBoxIvarValue(decodedValue, typeEncoding);
                        if (!boxedValue) {
                            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_type", [NSString stringWithFormat:@"FlexUltra cannot safely encode a JSON scalar for ivar type '%@'.", typeEncoding]));
                            return;
                        }
                    }
                    ((void (*)(id, SEL, id, id))objc_msgSend)(member, setter, boxedValue, object);
                }
            }

            SEL getter = NSSelectorFromString(@"getPotentiallyUnboxedValue:");
            id value = [member respondsToSelector:getter] ? ((id (*)(id, SEL, id))objc_msgSend)(member, getter, object) : nil;
            NSMutableDictionary *result = [FUObjectReference(object) mutableCopy];
            result[@"member_kind"] = resolvedKind;
            result[@"name"] = name;
            result[@"declaring_class"] = declaringClass;
            result[@"type_encoding"] = typeEncoding ?: @"";
            result[@"value"] = FUJSONValue(value);
            result[@"target_source"] = targetSource ?: @"handle";
            if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
            if (setValue) result[@"updated"] = @YES;
            response = FUResponse(requestID, YES, result, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(setValue ? @"mutation_failed" : @"read_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return response;
}

NSDictionary *FUHandleObjectInspect(NSString *requestID, NSDictionary *request) {
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    id object = FUObjectTargetFromRequest(requestID, request, nil, &targetSource, &resolvedBy, &targetError);
    if (!object) return targetError;
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for object inspection."));
    }

    NSUInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"limit"] unsignedIntegerValue] : 200;
    NSUInteger limit = MIN(MAX(requestedLimit, (NSUInteger)1), (NSUInteger)1000);
    BOOL includeValues = ![request[@"include_values"] respondsToSelector:@selector(boolValue)] || [request[@"include_values"] boolValue];

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            Class explorerClass = NSClassFromString(@"FLEXObjectExplorer");
            SEL factory = NSSelectorFromString(@"forObject:");
            if (!explorerClass || ![explorerClass respondsToSelector:factory]) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXObjectExplorer."));
                return;
            }

            id explorer = ((id (*)(id, SEL, id))objc_msgSend)(explorerClass, factory, object);
            if (!explorer) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"inspection_failed", @"FLEXObjectExplorer could not inspect the requested object."));
                return;
            }

            NSUInteger propertiesTotal = 0;
            NSUInteger ivarsTotal = 0;
            NSUInteger methodsTotal = 0;
            NSUInteger classMethodsTotal = 0;
            NSArray *properties = FUPropertyMetadata(explorer, object, includeValues, 0, limit, @"", &propertiesTotal);
            NSArray *ivars = FUIvarMetadata(explorer, object, includeValues, 0, limit, @"", &ivarsTotal);
            NSArray *methods = FUMethodMetadata(explorer, @"allMethods", 0, limit, @"", &methodsTotal);
            NSArray *classMethods = FUMethodMetadata(explorer, @"allClassMethods", 0, limit, @"", &classMethodsTotal);

            NSMutableDictionary *result = [FUObjectReference(object) mutableCopy];
            NSString *objectDescription = FUObjectMessage(explorer, @"objectDescription");
            if (objectDescription.length) {
                result[@"summary"] = FUTruncatedString(objectDescription, 2048);
            }
            result[@"class_hierarchy"] = FUClassHierarchyNames(explorer);
            result[@"properties"] = properties;
            result[@"ivars"] = ivars;
            result[@"methods"] = methods;
            result[@"class_methods"] = classMethods;
            result[@"reflex"] = FUFlexStatus(NO)[@"reflex"] ?: @NO;
            result[@"include_values"] = @(includeValues);
            result[@"target_source"] = targetSource ?: @"handle";
            if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
            result[@"truncated"] = @{
                @"properties": @(properties.count < propertiesTotal),
                @"ivars": @(ivars.count < ivarsTotal),
                @"methods": @(methods.count < methodsTotal),
                @"class_methods": @(classMethods.count < classMethodsTotal),
            };
            response = FUResponse(requestID, YES, result, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"inspection_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return response;
}
