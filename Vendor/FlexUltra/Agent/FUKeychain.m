#import <Foundation/Foundation.h>
#import <objc/message.h>

#import "FUKeychain.h"
#import "FUObjectSerialization.h"
#import "FUProtocol.h"
#import "FURuntime.h"

static BOOL FUKeychainRequestPagination(NSDictionary *request, NSUInteger *offset, NSUInteger *limit) {
    NSInteger requestedOffset = [request[@"offset"] respondsToSelector:@selector(integerValue)] ? [request[@"offset"] integerValue] : 0;
    NSInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(integerValue)] ? [request[@"limit"] integerValue] : 100;
    if (requestedOffset < 0 || requestedLimit <= 0) {
        return NO;
    }
    *offset = (NSUInteger)requestedOffset;
    *limit = MIN((NSUInteger)requestedLimit, (NSUInteger)1000);
    return YES;
}

static id FUKeychainJSONValue(id value) {
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
            [result addObject:FUKeychainJSONValue(item) ?: NSNull.null];
        }
        return result;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)value count]];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id item, BOOL *stop) {
            (void)stop;
            if (![key isKindOfClass:[NSString class]]) return;
            result[key] = FUKeychainJSONValue(item) ?: NSNull.null;
        }];
        return result;
    }
    return FUJSONValue(value);
}

static NSString *FUKeychainString(id value) {
    if (!value || value == NSNull.null) return @"";
    if ([value isKindOfClass:[NSString class]]) return value;
    return [value description] ?: @"";
}

static NSDictionary *FUKeychainItemMetadata(NSDictionary *attributes) {
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"service"] = FUKeychainString(attributes[@"svce"]);
    item[@"account"] = FUKeychainString(attributes[@"acct"]);
    item[@"access_group"] = FUKeychainString(attributes[@"agrp"]);
    item[@"label"] = FUKeychainString(attributes[@"labl"]);
    item[@"description"] = FUKeychainString(attributes[@"desc"]);
    if (attributes[@"cdat"]) item[@"created_at"] = FUKeychainJSONValue(attributes[@"cdat"]);
    if (attributes[@"mdat"]) item[@"modified_at"] = FUKeychainJSONValue(attributes[@"mdat"]);
    if (attributes[@"sync"]) item[@"synchronizable"] = FUKeychainJSONValue(attributes[@"sync"]);
    if (attributes[@"pdmn"]) item[@"accessibility"] = FUKeychainJSONValue(attributes[@"pdmn"]);
    item[@"raw_attributes"] = FUKeychainJSONValue(attributes);
    return item;
}

static NSArray<NSDictionary *> *FUKeychainSortedItems(NSArray *accounts) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (id value in accounts) {
        if ([value isKindOfClass:[NSDictionary class]]) {
            [items addObject:FUKeychainItemMetadata(value)];
        }
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        for (NSString *key in @[@"service", @"account", @"access_group", @"label"]) {
            NSString *lhs = FUKeychainString(left[key]);
            NSString *rhs = FUKeychainString(right[key]);
            NSComparisonResult folded = [lhs caseInsensitiveCompare:rhs];
            if (folded != NSOrderedSame) return folded;
            NSComparisonResult literal = [lhs compare:rhs options:NSLiteralSearch];
            if (literal != NSOrderedSame) return literal;
        }
        return NSOrderedSame;
    }];
}

static NSArray<NSDictionary *> *FUKeychainAllItems(NSString *requestID, NSDictionary **errorOut) {
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        if (errorOut) *errorOut = FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for Keychain inspection."));
        return nil;
    }
    Class keychainClass = NSClassFromString(@"FLEXKeychain");
    SEL selector = NSSelectorFromString(@"allAccounts");
    if (!keychainClass || ![keychainClass respondsToSelector:selector]) {
        if (errorOut) *errorOut = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXKeychain.allAccounts."));
        return nil;
    }
    @try {
        id accounts = ((id (*)(id, SEL))objc_msgSend)(keychainClass, selector);
        if (![accounts isKindOfClass:[NSArray class]]) {
            if (errorOut) *errorOut = FUResponse(requestID, NO, nil, FUErrorInfo(@"keychain_failed", @"FLEXKeychain did not return an account array."));
            return nil;
        }
        return FUKeychainSortedItems(accounts);
    } @catch (NSException *exception) {
        if (errorOut) *errorOut = FUResponse(requestID, NO, nil, FUErrorInfo(@"keychain_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        return nil;
    }
}

NSDictionary *FUHandleKeychainItems(NSString *requestID, NSDictionary *request) {
    id queryValue = request[@"query"];
    if (queryValue && ![queryValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_query", @"query must be a string."));
    }
    NSUInteger offset = 0, limit = 100;
    if (!FUKeychainRequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }
    NSDictionary *keychainError = nil;
    NSArray<NSDictionary *> *allItems = FUKeychainAllItems(requestID, &keychainError);
    if (!allItems) return keychainError;

    NSString *query = [queryValue isKindOfClass:[NSString class]] ? queryValue : @"";
    NSString *needle = query.lowercaseString;
    NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
    for (NSDictionary *item in allItems) {
        if (needle.length) {
            NSString *searchText = [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n%@",
                FUKeychainString(item[@"service"]), FUKeychainString(item[@"account"]),
                FUKeychainString(item[@"access_group"]), FUKeychainString(item[@"label"]),
                FUKeychainString(item[@"description"])];
            if (![searchText.lowercaseString containsString:needle]) continue;
        }
        [filtered addObject:item];
    }

    NSUInteger start = MIN(offset, filtered.count);
    NSUInteger end = MIN(filtered.count, start + limit);
    NSArray *page = [filtered subarrayWithRange:NSMakeRange(start, end - start)];
    NSMutableDictionary *result = [@{
        @"source": @"FLEXKeychain",
        @"scope": @"generic_password_items_accessible_to_target",
        @"items": page,
        @"offset": @(offset),
        @"limit": @(limit),
        @"total": @(filtered.count),
        @"recorded_total": @(allItems.count),
        @"has_more": (end < filtered.count ? @YES : @NO),
    } mutableCopy];
    if (query.length) result[@"query"] = query;
    return FUResponse(requestID, YES, result, nil);
}

NSDictionary *FUHandleKeychainItem(NSString *requestID, NSDictionary *request) {
    NSString *service = [request[@"service"] isKindOfClass:[NSString class]] ? request[@"service"] : nil;
    NSString *account = [request[@"account"] isKindOfClass:[NSString class]] ? request[@"account"] : nil;
    id accessGroupValue = request[@"access_group"];
    if (accessGroupValue && ![accessGroupValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"access_group must be a string when provided."));
    }
    NSString *accessGroup = [accessGroupValue isKindOfClass:[NSString class]] ? accessGroupValue : nil;
    if (service.length == 0 || account.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"keychain.item requires non-empty service and account strings."));
    }

    NSDictionary *keychainError = nil;
    NSArray<NSDictionary *> *allItems = FUKeychainAllItems(requestID, &keychainError);
    if (!allItems) return keychainError;
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (NSDictionary *item in allItems) {
        if (![FUKeychainString(item[@"service"]) isEqualToString:service]) continue;
        if (![FUKeychainString(item[@"account"]) isEqualToString:account]) continue;
        if (accessGroup && ![FUKeychainString(item[@"access_group"]) isEqualToString:accessGroup]) continue;
        [matches addObject:item];
    }
    if (matches.count == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"No accessible generic-password Keychain item matched the requested selector."));
    }
    if (!accessGroup && matches.count > 1) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"ambiguous_item", @"Multiple Keychain items matched service/account; provide access_group to disambiguate."));
    }

    NSDictionary *selected = matches.firstObject;
    NSString *selectedGroup = FUKeychainString(selected[@"access_group"]);
    Class queryClass = NSClassFromString(@"FLEXKeychainQuery");
    SEL fetchSelector = NSSelectorFromString(@"fetch:");
    if (!queryClass || ![queryClass instancesRespondToSelector:fetchSelector]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXKeychainQuery.fetch:."));
    }
    @try {
        id query = [queryClass new];
        [query setValue:service forKey:@"service"];
        [query setValue:account forKey:@"account"];
        if (selectedGroup.length && [query respondsToSelector:NSSelectorFromString(@"setAccessGroup:")]) {
            [query setValue:selectedGroup forKey:@"accessGroup"];
        }
        NSError *error = nil;
        BOOL fetched = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(query, fetchSelector, &error);
        if (!fetched) {
            NSString *message = error.localizedDescription.length ? error.localizedDescription : @"FLEXKeychainQuery failed to fetch the selected item.";
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"keychain_failed", FUTruncatedString(message, 1024)));
        }
        id passwordValue = [query valueForKey:@"passwordData"];
        NSMutableDictionary *result = [selected mutableCopy];
        result[@"source"] = @"FLEXKeychainQuery";
        result[@"scope"] = @"generic_password_item_accessible_to_target";
        if ([passwordValue isKindOfClass:[NSData class]]) {
            NSData *passwordData = passwordValue;
            result[@"password_byte_count"] = @(passwordData.length);
            NSString *password = [[NSString alloc] initWithData:passwordData encoding:NSUTF8StringEncoding];
            if (password) {
                result[@"password_encoding"] = @"utf-8";
                result[@"password"] = password;
            } else {
                result[@"password_encoding"] = @"base64";
                result[@"password_base64"] = [passwordData base64EncodedStringWithOptions:0] ?: @"";
            }
        } else {
            result[@"password_byte_count"] = @0;
            result[@"password_encoding"] = @"none";
        }
        return FUResponse(requestID, YES, result, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"keychain_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}
