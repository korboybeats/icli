#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <math.h>

#import "FUFlexTools.h"
#import "FUProtocol.h"
#import "FURuntime.h"
#import "FUObjectRegistry.h"
#import "FUObjectSerialization.h"
#import "FUObjectInspection.h"

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

static BOOL FUBoolMessage(id target, NSString *selectorName, BOOL fallback) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) {
        return fallback;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSInteger FUSignedMessage(id target, NSString *selectorName, NSInteger fallback) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) {
        return fallback;
    }
    return ((NSInteger (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSMutableArray *FUFlexBookmarks(NSString *requestID, NSDictionary **errorResponse) {
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for bookmarks."));
        return nil;
    }

    Class managerClass = NSClassFromString(@"FLEXBookmarkManager");
    SEL bookmarksSelector = NSSelectorFromString(@"bookmarks");
    if (!managerClass || ![managerClass respondsToSelector:bookmarksSelector]) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXBookmarkManager.bookmarks."));
        return nil;
    }

    id bookmarks = ((id (*)(id, SEL))objc_msgSend)(managerClass, bookmarksSelector);
    if (![bookmarks isKindOfClass:[NSMutableArray class]]) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"bookmarks_unavailable", @"FLEXBookmarkManager.bookmarks did not return a mutable array."));
        return nil;
    }
    return bookmarks;
}

static BOOL FUBookmarkMatchesQuery(id object, NSString *query) {
    if (query.length == 0) return YES;
    NSString *needle = query.lowercaseString;
    for (NSString *value in @[FUClassName(object), FUSafeSummary(object)]) {
        if ([value.lowercaseString containsString:needle]) return YES;
    }
    return NO;
}

NSDictionary *FUHandleBookmarksList(NSString *requestID, NSDictionary *request) {
    id queryValue = request[@"query"];
    if (queryValue && ![queryValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_query", @"query must be a string."));
    }
    NSString *query = [queryValue isKindOfClass:[NSString class]] ? queryValue : @"";

    NSUInteger offset = 0;
    NSUInteger limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            NSDictionary *bookmarksError = nil;
            NSMutableArray *bookmarks = FUFlexBookmarks(requestID, &bookmarksError);
            if (!bookmarks) {
                response = bookmarksError;
                return;
            }

            NSMutableArray *filtered = [NSMutableArray array];
            for (NSUInteger index = 0; index < bookmarks.count; index++) {
                id object = bookmarks[index];
                if (!object || !FUBookmarkMatchesQuery(object, query)) continue;
                NSMutableDictionary *entry = [FUObjectReference(object) mutableCopy];
                entry[@"index"] = @(index);
                [filtered addObject:entry];
            }

            NSArray *page = @[];
            if (offset < filtered.count) {
                NSUInteger count = MIN(limit, filtered.count - offset);
                page = [filtered subarrayWithRange:NSMakeRange(offset, count)];
            }
            NSMutableDictionary *result = [@{
                @"source": @"FLEXBookmarkManager",
                @"bookmarks": page,
                @"offset": @(offset),
                @"limit": @(limit),
                @"total": @(filtered.count),
                @"recorded_total": @(bookmarks.count),
                @"has_more": @(offset + page.count < filtered.count),
            } mutableCopy];
            if (query.length) result[@"query"] = query;
            response = FUResponse(requestID, YES, result, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"bookmarks_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleBookmarksAdd(NSString *requestID, NSDictionary *request) {
    NSString *resolvedHandle = nil;
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    id object = FUObjectTargetFromRequest(requestID, request, &resolvedHandle, &targetSource, &resolvedBy, &targetError);
    if (!object) return targetError;

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            NSDictionary *bookmarksError = nil;
            NSMutableArray *bookmarks = FUFlexBookmarks(requestID, &bookmarksError);
            if (!bookmarks) {
                response = bookmarksError;
                return;
            }
            NSUInteger index = bookmarks.count;
            [bookmarks addObject:object];
            NSMutableDictionary *result = [@{
                @"source": @"FLEXBookmarkManager",
                @"index": @(index),
                @"object": FUObjectReference(object),
                @"total": @(bookmarks.count),
                @"target_source": targetSource ?: @"handle",
            } mutableCopy];
            if (resolvedHandle.length) result[@"resolved_handle"] = resolvedHandle;
            if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
            response = FUResponse(requestID, YES, result, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"bookmarks_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleBookmarksRemove(NSString *requestID, NSDictionary *request) {
    id indexValue = request[@"index"];
    if (![indexValue respondsToSelector:@selector(integerValue)] || [indexValue integerValue] < 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"bookmarks.remove requires a nonnegative index."));
    }
    NSUInteger index = (NSUInteger)[indexValue integerValue];

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            NSDictionary *bookmarksError = nil;
            NSMutableArray *bookmarks = FUFlexBookmarks(requestID, &bookmarksError);
            if (!bookmarks) {
                response = bookmarksError;
                return;
            }
            if (index >= bookmarks.count) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"bookmark_out_of_range", @"The requested bookmark index is out of range."));
                return;
            }
            id object = bookmarks[index];
            NSDictionary *reference = FUObjectReference(object);
            [bookmarks removeObjectAtIndex:index];
            response = FUResponse(requestID, YES, @{
                @"source": @"FLEXBookmarkManager",
                @"index": @(index),
                @"object": reference,
                @"total": @(bookmarks.count),
            }, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"bookmarks_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

static NSDictionary *FUNetworkTransactionEntry(id transaction) {
    NSMutableDictionary *entry = [FUObjectReference(transaction) mutableCopy];
    NSString *primary = FUObjectMessage(transaction, @"primaryDescription");
    NSString *secondary = FUObjectMessage(transaction, @"secondaryDescription");
    NSString *tertiary = FUObjectMessage(transaction, @"tertiaryDescription");
    id startTime = FUObjectMessage(transaction, @"startTime");
    id error = FUObjectMessage(transaction, @"error");

    entry[@"primary_description"] = FUTruncatedString(primary, 2048);
    entry[@"secondary_description"] = FUTruncatedString(secondary, 2048);
    entry[@"tertiary_description"] = FUTruncatedString(tertiary, 2048);
    entry[@"start_time"] = FUJSONValue(startTime);
    entry[@"state"] = @(FUSignedMessage(transaction, @"state", 0));
    entry[@"received_data_length"] = @(FUSignedMessage(transaction, @"receivedDataLength", 0));
    entry[@"display_as_error"] = @(FUBoolMessage(transaction, @"displayAsError", NO));
    if (error) {
        entry[@"error"] = @{
            @"summary": FUSafeSummary(error),
            @"object": FUObjectReference(error),
        };
    } else {
        entry[@"error"] = NSNull.null;
    }
    return entry;
}

static BOOL FUNetworkTransactionMatchesQuery(id transaction, NSString *query) {
    if (query.length == 0) return YES;

    SEL selector = NSSelectorFromString(@"matchesQuery:");
    if ([transaction respondsToSelector:selector]) {
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(transaction, selector, query);
    }

    NSString *needle = query.lowercaseString;
    for (NSString *selectorName in @[@"primaryDescription", @"secondaryDescription", @"tertiaryDescription"]) {
        NSString *value = FUObjectMessage(transaction, selectorName);
        if ([value isKindOfClass:[NSString class]] && [value.lowercaseString containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

NSDictionary *FUHandleNetworkTransactions(NSString *requestID, NSDictionary *request) {
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for network history."));
    }

    Class recorderClass = NSClassFromString(@"FLEXNetworkRecorder");
    SEL defaultRecorderSelector = NSSelectorFromString(@"defaultRecorder");
    if (!recorderClass || ![recorderClass respondsToSelector:defaultRecorderSelector]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXNetworkRecorder.defaultRecorder."));
    }

    NSString *kind = [request[@"network_kind"] isKindOfClass:[NSString class]] ? request[@"network_kind"] : @"http";
    NSDictionary<NSString *, NSString *> *selectors = @{
        @"http": @"orderedHTTPTransactions",
        @"websocket": @"orderedWSTransactions",
        @"firebase": @"orderedFirebaseTransactions",
    };
    NSString *selectorName = selectors[kind];
    if (!selectorName) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_kind", @"network kind must be http, websocket, or firebase."));
    }

    id queryValue = request[@"query"];
    if (queryValue && ![queryValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_query", @"query must be a string."));
    }
    NSString *query = [queryValue isKindOfClass:[NSString class]] ? queryValue : @"";

    NSUInteger offset = 0;
    NSUInteger limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    @try {
        id recorder = ((id (*)(id, SEL))objc_msgSend)(recorderClass, defaultRecorderSelector);
        if (!recorder) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"network_recorder_unavailable", @"FLEXNetworkRecorder.defaultRecorder returned nil."));
        }

        SEL transactionsSelector = NSSelectorFromString(selectorName);
        if (![recorder respondsToSelector:transactionsSelector]) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", [NSString stringWithFormat:@"The loaded FLEX build does not expose %@.", selectorName]));
        }

        NSArray *recorded = ((id (*)(id, SEL))objc_msgSend)(recorder, transactionsSelector);
        if (![recorded isKindOfClass:[NSArray class]]) recorded = @[];

        NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:recorded.count];
        for (id transaction in recorded) {
            if (!transaction) continue;
            if (FUNetworkTransactionMatchesQuery(transaction, query)) {
                [filtered addObject:transaction];
            }
        }

        NSArray *pageObjects = @[];
        if (offset < filtered.count) {
            NSUInteger count = MIN(limit, filtered.count - offset);
            pageObjects = [filtered subarrayWithRange:NSMakeRange(offset, count)];
        }
        NSMutableArray *transactions = [NSMutableArray arrayWithCapacity:pageObjects.count];
        for (id transaction in pageObjects) {
            [transactions addObject:FUNetworkTransactionEntry(transaction)];
        }

        NSMutableDictionary *result = [@{
            @"source": @"FLEXNetworkRecorder",
            @"kind": kind,
            @"recorder": FUObjectReference(recorder),
            @"transactions": transactions,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(filtered.count),
            @"recorded_total": @(recorded.count),
            @"has_more": @(offset + transactions.count < filtered.count),
        } mutableCopy];
        if (query.length) result[@"query"] = query;
        return FUResponse(requestID, YES, result, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"network_history_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

static NSDictionary *FUSystemLogEntry(id message) {
    NSMutableDictionary *entry = [FUObjectReference(message) mutableCopy];
    id date = FUObjectMessage(message, @"date");
    id sender = FUObjectMessage(message, @"sender");
    id messageText = FUObjectMessage(message, @"messageText");

    entry[@"date"] = FUJSONValue(date);
    entry[@"sender"] = [sender isKindOfClass:[NSString class]]
        ? FUTruncatedString(sender, 2048)
        : FUJSONValue(sender);
    entry[@"message_text"] = FUTruncatedString(
        [messageText isKindOfClass:[NSString class]] ? messageText : [messageText description],
        4096
    );
    entry[@"message_id"] = @(FUSignedMessage(message, @"messageID", 0));
    return entry;
}

static BOOL FUSystemLogMessageMatchesQuery(id message, NSString *query) {
    if (query.length == 0) return YES;

    NSString *needle = query.lowercaseString;
    for (NSString *selectorName in @[@"messageText", @"sender"]) {
        id value = FUObjectMessage(message, selectorName);
        NSString *text = [value isKindOfClass:[NSString class]] ? value : [value description];
        if ([text.lowercaseString containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

NSDictionary *FUHandleLogMessages(NSString *requestID, NSDictionary *request) {
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for system log history."));
    }

    Class controllerClass = NSClassFromString(@"FLEXOSLogController");
    SEL sharedSelector = NSSelectorFromString(@"sharedLogController");
    NSArray<NSString *> *requiredSelectors = @[@"persistent", @"setPersistent:", @"startMonitoring", @"messages"];
    if (!controllerClass || ![controllerClass respondsToSelector:sharedSelector]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXOSLogController.sharedLogController."));
    }

    id queryValue = request[@"query"];
    if (queryValue && ![queryValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_query", @"query must be a string."));
    }
    NSString *query = [queryValue isKindOfClass:[NSString class]] ? queryValue : @"";

    NSUInteger offset = 0;
    NSUInteger limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    @try {
        __block id controller = nil;
        __block BOOL persistent = NO;
        __block BOOL monitoring = NO;
        __block NSArray *recorded = nil;
        __block NSString *missingSelectorName = nil;
        __block BOOL historyWasArray = NO;

        void (^snapshotLogs)(void) = ^{
            controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
            if (!controller) return;

            for (NSString *selectorName in requiredSelectors) {
                if (![controller respondsToSelector:NSSelectorFromString(selectorName)]) {
                    missingSelectorName = selectorName;
                    return;
                }
            }

            if (!FUBoolMessage(controller, @"persistent", NO)) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, NSSelectorFromString(@"setPersistent:"), YES);
            }
            persistent = FUBoolMessage(controller, @"persistent", NO);
            monitoring = FUBoolMessage(controller, @"startMonitoring", NO);

            id historyValue = FUObjectMessage(controller, @"messages");
            historyWasArray = [historyValue isKindOfClass:[NSArray class]];
            if (historyWasArray) {
                // FLEX updates this mutable collection asynchronously on the main queue.
                // Copy it while serialized with those updates, then inspect the stable
                // snapshot off-main without racing the controller.
                recorded = [historyValue copy];
            }
        };
        if (NSThread.isMainThread) snapshotLogs(); else dispatch_sync(dispatch_get_main_queue(), snapshotLogs);

        if (!controller) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"log_controller_unavailable", @"FLEXOSLogController.sharedLogController returned nil."));
        }
        if (missingSelectorName) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", [NSString stringWithFormat:@"The loaded FLEX build does not expose FLEXOSLogController.%@.", missingSelectorName]));
        }
        if (!historyWasArray) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"log_history_failed", @"FLEXOSLogController.messages did not return an array."));
        }

        NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:recorded.count];
        for (id message in recorded) {
            if (!message) continue;
            if (FUSystemLogMessageMatchesQuery(message, query)) {
                [filtered addObject:message];
            }
        }

        NSArray *pageObjects = @[];
        if (offset < filtered.count) {
            NSUInteger count = MIN(limit, filtered.count - offset);
            pageObjects = [filtered subarrayWithRange:NSMakeRange(offset, count)];
        }
        NSMutableArray *messages = [NSMutableArray arrayWithCapacity:pageObjects.count];
        for (id message in pageObjects) {
            [messages addObject:FUSystemLogEntry(message)];
        }

        NSMutableDictionary *result = [@{
            @"source": @"FLEXOSLogController",
            @"controller": FUObjectReference(controller),
            @"messages": messages,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(filtered.count),
            @"recorded_total": @(recorded.count),
            @"has_more": @(offset + messages.count < filtered.count),
            @"persistent": @(persistent),
            @"monitoring": @(monitoring),
        } mutableCopy];
        if (query.length) result[@"query"] = query;
        return FUResponse(requestID, YES, result, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"log_history_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleGlobalsEntries(NSString *requestID, NSDictionary *request) {
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for globals enumeration."));
    }

    Class globalsControllerClass = NSClassFromString(@"FLEXGlobalsViewController");
    SEL defaultSectionsSelector = NSSelectorFromString(@"defaultGlobalSections");
    if (!globalsControllerClass || ![globalsControllerClass respondsToSelector:defaultSectionsSelector]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXGlobalsViewController.defaultGlobalSections."));
    }

    id queryValue = request[@"query"];
    if (queryValue && ![queryValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_query", @"query must be a string."));
    }
    NSString *query = [queryValue isKindOfClass:[NSString class]] ? queryValue : @"";

    NSUInteger offset = 0;
    NSUInteger limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    @try {
        id sectionsValue = ((id (*)(id, SEL))objc_msgSend)(globalsControllerClass, defaultSectionsSelector);
        if (![sectionsValue isKindOfClass:[NSArray class]]) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"globals_unavailable", @"FLEXGlobalsViewController.defaultGlobalSections did not return an array."));
        }
        NSArray *sections = sectionsValue;
        NSMutableArray *allEntries = [NSMutableArray array];
        NSUInteger recordedTotal = 0;
        NSString *needle = query.lowercaseString;

        for (NSUInteger sectionIndex = 0; sectionIndex < sections.count; sectionIndex++) {
            id section = sections[sectionIndex];
            if (!section) continue;
            SEL allRowsSelector = NSSelectorFromString(@"allRows");
            if (![section respondsToSelector:allRowsSelector]) {
                return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build exposes a globals section without allRows."));
            }

            NSString *sectionTitle = FUObjectMessage(section, @"title");
            if (![sectionTitle isKindOfClass:[NSString class]]) sectionTitle = @"";
            id rowsValue = ((id (*)(id, SEL))objc_msgSend)(section, allRowsSelector);
            if (![rowsValue isKindOfClass:[NSArray class]]) {
                return FUResponse(requestID, NO, nil, FUErrorInfo(@"globals_unavailable", @"A FLEX globals section returned a non-array allRows value."));
            }
            NSArray *rows = rowsValue;
            recordedTotal += rows.count;
            NSDictionary *sectionReference = FUObjectReference(section);

            for (NSUInteger rowIndex = 0; rowIndex < rows.count; rowIndex++) {
                id entry = rows[rowIndex];
                if (!entry) continue;
                NSString *name = FUObjectMessage(entry, @"name");
                if (![name isKindOfClass:[NSString class]]) name = @"";
                if (needle.length) {
                    NSString *searchText = [NSString stringWithFormat:@"%@\n%@", sectionTitle, name].lowercaseString;
                    if (![searchText containsString:needle]) continue;
                }

                NSMutableDictionary *record = [FUObjectReference(entry) mutableCopy];
                record[@"section"] = sectionReference;
                record[@"section_title"] = FUTruncatedString(sectionTitle, 1024);
                record[@"section_index"] = @(sectionIndex);
                record[@"row_index"] = @(rowIndex);
                record[@"name"] = FUTruncatedString(name, 2048);
                record[@"has_row_action"] = [NSNumber numberWithBool:(FUObjectMessage(entry, @"rowAction") != nil)];
                record[@"has_view_controller_future"] = [NSNumber numberWithBool:(FUObjectMessage(entry, @"viewControllerFuture") != nil)];
                record[@"has_entry_name_future"] = [NSNumber numberWithBool:(FUObjectMessage(entry, @"entryNameFuture") != nil)];
                [allEntries addObject:record];
            }
        }

        NSArray *pageEntries = @[];
        if (offset < allEntries.count) {
            NSUInteger count = MIN(limit, allEntries.count - offset);
            pageEntries = [allEntries subarrayWithRange:NSMakeRange(offset, count)];
        }

        NSMutableDictionary *result = [@{
            @"source": @"FLEXGlobalsViewController",
            @"sections": @(sections.count),
            @"entries": pageEntries,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(allEntries.count),
            @"recorded_total": @(recordedTotal),
            @"has_more": @(offset + pageEntries.count < allEntries.count),
        } mutableCopy];
        if (query.length) result[@"query"] = query;
        return FUResponse(requestID, YES, result, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"globals_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

typedef void (^FUGlobalsRowAction)(UITableViewController *host);
typedef UIViewController * _Nullable (^FUGlobalsViewControllerFuture)(void);

static BOOL FURequestNonnegativeIndex(id value, NSUInteger *index) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    double raw = [value doubleValue];
    if (!isfinite(raw) || raw < 0 || raw != floor(raw) || [value compare:@(NSUIntegerMax)] == NSOrderedDescending) {
        return NO;
    }
    if (index) *index = (NSUInteger)raw;
    return YES;
}

static BOOL FUResolveGlobalSelection(NSString *requestID, NSDictionary *request, id *sectionOut, id *entryOut, NSUInteger *sectionIndexOut, NSUInteger *rowIndexOut, NSDictionary **errorResponse) {
    NSUInteger sectionIndex = 0;
    NSUInteger rowIndex = 0;
    if (!FURequestNonnegativeIndex(request[@"section_index"], &sectionIndex) || !FURequestNonnegativeIndex(request[@"row_index"], &rowIndex)) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"section_index and row_index must be non-negative integers."));
        return NO;
    }

    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for globals access."));
        return NO;
    }

    Class globalsControllerClass = NSClassFromString(@"FLEXGlobalsViewController");
    SEL defaultSectionsSelector = NSSelectorFromString(@"defaultGlobalSections");
    if (!globalsControllerClass || ![globalsControllerClass respondsToSelector:defaultSectionsSelector]) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXGlobalsViewController.defaultGlobalSections."));
        return NO;
    }

    id sectionsValue = ((id (*)(id, SEL))objc_msgSend)(globalsControllerClass, defaultSectionsSelector);
    if (![sectionsValue isKindOfClass:[NSArray class]]) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"globals_unavailable", @"FLEXGlobalsViewController.defaultGlobalSections did not return an array."));
        return NO;
    }
    NSArray *sections = sectionsValue;
    if (sectionIndex >= sections.count) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_section_out_of_range", [NSString stringWithFormat:@"section_index %lu is outside the %lu available default FLEX sections.", (unsigned long)sectionIndex, (unsigned long)sections.count]));
        return NO;
    }

    id section = sections[sectionIndex];
    id rowsValue = FUObjectMessage(section, @"allRows");
    if (![rowsValue isKindOfClass:[NSArray class]]) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"globals_unavailable", @"The selected FLEX globals section did not expose an allRows array."));
        return NO;
    }
    NSArray *rows = rowsValue;
    if (rowIndex >= rows.count) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_row_out_of_range", [NSString stringWithFormat:@"row_index %lu is outside the %lu entries in section %lu.", (unsigned long)rowIndex, (unsigned long)rows.count, (unsigned long)sectionIndex]));
        return NO;
    }

    id entry = rows[rowIndex];
    if (!entry) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_unavailable", @"The selected FLEX global entry is unavailable."));
        return NO;
    }

    if (sectionOut) *sectionOut = section;
    if (entryOut) *entryOut = entry;
    if (sectionIndexOut) *sectionIndexOut = sectionIndex;
    if (rowIndexOut) *rowIndexOut = rowIndex;
    return YES;
}

static UINavigationController *FUGlobalsNavigationController(UIViewController *root) {
    Class navigationClass = NSClassFromString(@"FLEXNavigationController");
    SEL factory = NSSelectorFromString(@"withRootViewController:");
    if (navigationClass && [navigationClass respondsToSelector:factory]) {
        id navigation = ((id (*)(id, SEL, id))objc_msgSend)(navigationClass, factory, root);
        if ([navigation isKindOfClass:[UINavigationController class]]) {
            return navigation;
        }
    }
    return [[UINavigationController alloc] initWithRootViewController:root];
}

static BOOL FUPresentGlobalsNavigation(UINavigationController *navigation, NSString **errorMessage) {
    id manager = FUFlexManager();
    SEL showSelector = NSSelectorFromString(@"showExplorer");
    if (!manager || ![manager respondsToSelector:showSelector]) {
        if (errorMessage) *errorMessage = @"FLEXManager cannot present the globals host.";
        return NO;
    }
    ((void (*)(id, SEL))objc_msgSend)(manager, showSelector);

    id presenter = FUObjectMessage(manager, @"explorerViewController");
    if (![presenter isKindOfClass:[UIViewController class]]) {
        UIWindow *explorerWindow = FUObjectMessage(manager, @"explorerWindow");
        presenter = [explorerWindow isKindOfClass:[UIWindow class]] ? explorerWindow.rootViewController : nil;
    }
    if (![presenter isKindOfClass:[UIViewController class]]) {
        if (errorMessage) *errorMessage = @"FLEXManager did not expose an explorer view controller.";
        return NO;
    }

    while ([presenter presentedViewController] && ![[presenter presentedViewController] isBeingDismissed]) {
        presenter = [presenter presentedViewController];
    }
    [(UIViewController *)presenter presentViewController:navigation animated:NO completion:nil];
    BOOL presented = navigation.presentingViewController != nil || [(UIViewController *)presenter presentedViewController] == navigation;
    if (!presented && errorMessage) *errorMessage = @"UIKit did not attach the FLEX globals navigation controller.";
    return presented;
}

static NSMutableDictionary *FUGlobalSelectionResult(id section, id entry, NSUInteger sectionIndex, NSUInteger rowIndex) {
    NSString *sectionTitle = FUObjectMessage(section, @"title");
    if (![sectionTitle isKindOfClass:[NSString class]]) sectionTitle = @"";
    NSString *name = FUObjectMessage(entry, @"name");
    if (![name isKindOfClass:[NSString class]]) name = @"";
    return [@{
        @"source": @"FLEXGlobalsViewController",
        @"section_index": @(sectionIndex),
        @"row_index": @(rowIndex),
        @"section_title": FUTruncatedString(sectionTitle, 1024),
        @"name": FUTruncatedString(name, 2048),
        @"section": FUObjectReference(section),
        @"entry": FUObjectReference(entry),
    } mutableCopy];
}

NSDictionary *FUHandleGlobalsOpen(NSString *requestID, NSDictionary *request) {
    id presentValue = request[@"present"];
    if (presentValue && CFGetTypeID((__bridge CFTypeRef)presentValue) != CFBooleanGetTypeID()) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"present must be a boolean."));
    }
    BOOL present = [presentValue boolValue];

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            id section = nil;
            id entry = nil;
            NSUInteger sectionIndex = 0;
            NSUInteger rowIndex = 0;
            NSDictionary *selectionError = nil;
            if (!FUResolveGlobalSelection(requestID, request, &section, &entry, &sectionIndex, &rowIndex, &selectionError)) {
                response = selectionError;
                return;
            }

            id rowAction = FUObjectMessage(entry, @"rowAction");
            id futureObject = FUObjectMessage(entry, @"viewControllerFuture");
            if (rowAction) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_requires_invoke", @"The selected FLEX global uses a row action. Use globals.invoke for this entry."));
                return;
            }
            if (!futureObject) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_controller_unavailable", @"The selected FLEX global does not expose a view-controller future."));
                return;
            }

            UIViewController *controller = ((FUGlobalsViewControllerFuture)futureObject)();
            if (![controller isKindOfClass:[UIViewController class]]) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_controller_unavailable", @"The selected FLEX global did not produce a view controller."));
                return;
            }
            NSString *controllerHandle = FUPinObject(controller);
            if (!controllerHandle) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_controller_unavailable", @"FlexUltra could not retain the FLEX global view controller."));
                return;
            }

            UINavigationController *navigation = nil;
            if (present) {
                navigation = FUGlobalsNavigationController(controller);
                NSString *presentationError = nil;
                if (!FUPresentGlobalsNavigation(navigation, &presentationError)) {
                    response = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_presentation_failed", presentationError ?: @"The FLEX global view controller could not be presented."));
                    return;
                }
            }

            NSMutableDictionary *result = FUGlobalSelectionResult(section, entry, sectionIndex, rowIndex);
            result[@"kind"] = @"view_controller";
            result[@"controller"] = FUObjectReference(controller);
            result[@"controller_handle"] = controllerHandle;
            result[@"pinned"] = @YES;
            result[@"presented"] = @(present);
            if (navigation) result[@"navigation"] = FUObjectReference(navigation);
            response = FUResponse(requestID, YES, result, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_open_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleGlobalsInvoke(NSString *requestID, NSDictionary *request) {
    id presentValue = request[@"present"];
    if (presentValue && CFGetTypeID((__bridge CFTypeRef)presentValue) != CFBooleanGetTypeID()) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"present must be a boolean."));
    }
    BOOL present = presentValue ? [presentValue boolValue] : YES;

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            id section = nil;
            id entry = nil;
            NSUInteger sectionIndex = 0;
            NSUInteger rowIndex = 0;
            NSDictionary *selectionError = nil;
            if (!FUResolveGlobalSelection(requestID, request, &section, &entry, &sectionIndex, &rowIndex, &selectionError)) {
                response = selectionError;
                return;
            }

            id actionObject = FUObjectMessage(entry, @"rowAction");
            id futureObject = FUObjectMessage(entry, @"viewControllerFuture");
            if (!actionObject) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(futureObject ? @"global_requires_open" : @"global_action_unavailable", futureObject ? @"The selected FLEX global exposes a view controller. Use globals.open for this entry." : @"The selected FLEX global does not expose a row action."));
                return;
            }

            Class globalsControllerClass = NSClassFromString(@"FLEXGlobalsViewController");
            id hostObject = [[globalsControllerClass alloc] init];
            if (![hostObject isKindOfClass:[UITableViewController class]]) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEXGlobalsViewController is not a UITableViewController in the loaded FLEX build."));
                return;
            }
            UITableViewController *host = hostObject;
            UINavigationController *navigation = FUGlobalsNavigationController(host);
            NSString *hostHandle = FUPinObject(host);
            NSString *navigationHandle = FUPinObject(navigation);
            if (!hostHandle || !navigationHandle) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_action_failed", @"FlexUltra could not retain the FLEX globals action host."));
                return;
            }

            if (present) {
                NSString *presentationError = nil;
                if (!FUPresentGlobalsNavigation(navigation, &presentationError)) {
                    response = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_presentation_failed", presentationError ?: @"The FLEX globals action host could not be presented."));
                    return;
                }
            }

            ((FUGlobalsRowAction)actionObject)(host);

            NSMutableDictionary *result = FUGlobalSelectionResult(section, entry, sectionIndex, rowIndex);
            result[@"kind"] = @"row_action";
            result[@"invoked"] = @YES;
            result[@"presented_host"] = @(present);
            result[@"host"] = FUObjectReference(host);
            result[@"host_handle"] = hostHandle;
            result[@"navigation"] = FUObjectReference(navigation);
            result[@"navigation_handle"] = navigationHandle;
            UIViewController *top = navigation.topViewController;
            if (top) result[@"top_view_controller"] = FUObjectReference(top);
            UIViewController *presented = host.presentedViewController;
            if (presented) result[@"presented_view_controller"] = FUObjectReference(presented);
            response = FUResponse(requestID, YES, result, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"global_invoke_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}
