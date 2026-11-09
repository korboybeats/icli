#import "FUStorage.h"

#import <objc/message.h>
#import <sys/stat.h>
#import <math.h>

#import "FUProtocol.h"

static FUStorageFlexStatusProvider FUStorageFlexStatusProviderFunction = NULL;
static FUStorageJSONValueProvider FUStorageJSONValueProviderFunction = NULL;

void FUStorageConfigure(FUStorageFlexStatusProvider flexStatusProvider, FUStorageJSONValueProvider jsonValueProvider) {
    FUStorageFlexStatusProviderFunction = flexStatusProvider;
    FUStorageJSONValueProviderFunction = jsonValueProvider;
}

static BOOL FUStorageRequestPagination(NSDictionary *request, NSUInteger *offset, NSUInteger *limit) {
    NSInteger requestedOffset = [request[@"offset"] respondsToSelector:@selector(integerValue)] ? [request[@"offset"] integerValue] : 0;
    NSInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(integerValue)] ? [request[@"limit"] integerValue] : 100;
    if (requestedOffset < 0 || requestedLimit <= 0) {
        return NO;
    }
    *offset = (NSUInteger)requestedOffset;
    *limit = MIN((NSUInteger)requestedLimit, (NSUInteger)1000);
    return YES;
}

static NSString *FUStorageTruncatedString(NSString *string, NSUInteger limit) {
    if (![string isKindOfClass:[NSString class]]) {
        return @"";
    }
    if (string.length <= limit) {
        return string;
    }
    return [[string substringToIndex:limit] stringByAppendingString:@"…"];
}

static id FUStorageJSONFloatingNumber(double value) {
    return isfinite(value) ? @(value) : NSNull.null;
}

static NSDictionary *FUStorageFlexStatus(BOOL loadIfNeeded) {
    if (FUStorageFlexStatusProviderFunction) {
        NSDictionary *status = FUStorageFlexStatusProviderFunction(loadIfNeeded);
        if ([status isKindOfClass:[NSDictionary class]]) {
            return status;
        }
    }
    return @{ @"available": @NO };
}

static id FUStorageJSONValue(id value) {
    if (FUStorageJSONValueProviderFunction) {
        id encoded = FUStorageJSONValueProviderFunction(value);
        return encoded ?: NSNull.null;
    }
    return value ?: NSNull.null;
}

static BOOL FUFilesystemPathIsInsideRoot(NSString *path, NSString *root) {
    if ([path isEqualToString:root]) return YES;
    NSString *prefix = [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

static NSDictionary *FUFilesystemResolvePath(
    NSString *requestID,
    NSDictionary *request,
    NSString **rootNameOut,
    NSString **rootPathOut,
    NSString **relativePathOut,
    NSString **pathOut
) {
    id rootValue = request[@"root"];
    if (rootValue && ![rootValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_root", @"root must be \"home\" or \"bundle\"."));
    }
    NSString *rootName = [rootValue isKindOfClass:[NSString class]] ? rootValue : @"home";
    NSString *basePath = nil;
    if ([rootName isEqualToString:@"home"]) {
        basePath = NSHomeDirectory();
    } else if ([rootName isEqualToString:@"bundle"]) {
        basePath = NSBundle.mainBundle.bundlePath;
    } else {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_root", @"root must be \"home\" or \"bundle\"."));
    }

    id pathValue = request[@"path"];
    if (pathValue && ![pathValue isKindOfClass:[NSString class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_path", @"path must be a relative string."));
    }
    NSString *relative = [pathValue isKindOfClass:[NSString class]] ? pathValue : @".";
    if (relative.length == 0) relative = @".";
    if ([relative hasPrefix:@"/"] || [relative rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_path", @"path must be a relative path without NUL characters."));
    }

    NSString *standardRoot = [basePath stringByStandardizingPath];
    NSString *candidate = [[standardRoot stringByAppendingPathComponent:relative] stringByStandardizingPath];
    if (!FUFilesystemPathIsInsideRoot(candidate, standardRoot)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"path_outside_root", @"path escapes the selected filesystem root."));
    }

    NSString *canonicalRoot = [[standardRoot stringByResolvingSymlinksInPath] stringByStandardizingPath];
    NSString *canonicalCandidate = [[candidate stringByResolvingSymlinksInPath] stringByStandardizingPath];
    if (!FUFilesystemPathIsInsideRoot(canonicalCandidate, canonicalRoot)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"path_outside_root", @"path resolves outside the selected filesystem root."));
    }

    NSString *normalizedRelative = @".";
    if (![candidate isEqualToString:standardRoot]) {
        normalizedRelative = [candidate substringFromIndex:MIN(candidate.length, standardRoot.length + 1)];
    }
    if (rootNameOut) *rootNameOut = rootName;
    if (rootPathOut) *rootPathOut = standardRoot;
    if (relativePathOut) *relativePathOut = normalizedRelative;
    if (pathOut) *pathOut = candidate;
    return nil;
}

static NSString *FUFilesystemTypeForMode(mode_t mode) {
    if (S_ISREG(mode)) return @"file";
    if (S_ISDIR(mode)) return @"directory";
    if (S_ISLNK(mode)) return @"symlink";
    return @"other";
}

static NSDictionary *FUFilesystemEntry(NSString *absolutePath, NSString *relativePath, NSString *name) {
    struct stat st = {0};
    if (lstat(absolutePath.fileSystemRepresentation, &st) != 0) return nil;
    double modified = (double)st.st_mtimespec.tv_sec + ((double)st.st_mtimespec.tv_nsec / 1000000000.0);
    return @{
        @"name": name ?: absolutePath.lastPathComponent ?: @"",
        @"path": relativePath ?: @".",
        @"type": FUFilesystemTypeForMode(st.st_mode),
        @"size": @((unsigned long long)MAX((off_t)0, st.st_size)),
        @"modification_time": FUStorageJSONFloatingNumber(modified),
        @"posix_permissions": @((NSUInteger)(st.st_mode & 0777)),
    };
}

static NSArray<NSString *> *FUFilesystemSortedNames(NSArray<NSString *> *names) {
    return [names sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSComparisonResult folded = [left caseInsensitiveCompare:right];
        return folded != NSOrderedSame ? folded : [left compare:right options:NSLiteralSearch];
    }];
}

NSDictionary *FUHandleFilesystemList(NSString *requestID, NSDictionary *request) {
    NSUInteger offset = 0, limit = 100;
    if (!FUStorageRequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }
    NSString *rootName = nil, *rootPath = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *pathError = FUFilesystemResolvePath(requestID, request, &rootName, &rootPath, &relativePath, &absolutePath);
    if (pathError) return pathError;

    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"The requested filesystem path does not exist."));
    }
    if (!isDirectory) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"wrong_type", @"filesystem.list requires a directory."));
    }

    NSError *error = nil;
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:absolutePath error:&error];
    if (!names) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"filesystem_failed", FUStorageTruncatedString(error.localizedDescription ?: @"Directory listing failed.", 1024)));
    }
    names = FUFilesystemSortedNames(names);
    NSMutableArray *entries = [NSMutableArray array];
    NSUInteger end = MIN(names.count, offset + limit);
    for (NSUInteger index = MIN(offset, names.count); index < end; index++) {
        NSString *name = names[index];
        NSString *childAbsolute = [absolutePath stringByAppendingPathComponent:name];
        NSString *childRelative = [relativePath isEqualToString:@"."] ? name : [relativePath stringByAppendingPathComponent:name];
        NSDictionary *entry = FUFilesystemEntry(childAbsolute, childRelative, name);
        if (entry) [entries addObject:entry];
    }
    return FUResponse(requestID, YES, @{
        @"root": rootName,
        @"root_path": rootPath,
        @"path": relativePath,
        @"entries": entries,
        @"offset": @(offset),
        @"limit": @(limit),
        @"total": @(names.count),
        @"has_more": (offset + entries.count < names.count ? @YES : @NO),
    }, nil);
}

NSDictionary *FUHandleFilesystemStat(NSString *requestID, NSDictionary *request) {
    NSString *rootName = nil, *rootPath = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *pathError = FUFilesystemResolvePath(requestID, request, &rootName, &rootPath, &relativePath, &absolutePath);
    if (pathError) return pathError;
    NSDictionary *entry = FUFilesystemEntry(absolutePath, relativePath, [relativePath isEqualToString:@"."] ? @"." : absolutePath.lastPathComponent);
    if (!entry) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"The requested filesystem path does not exist."));
    }
    NSMutableDictionary *result = [entry mutableCopy];
    result[@"root"] = rootName;
    result[@"root_path"] = rootPath;
    result[@"absolute_path"] = absolutePath;
    return FUResponse(requestID, YES, result, nil);
}

NSDictionary *FUHandleFilesystemRead(NSString *requestID, NSDictionary *request) {
    NSInteger requestedMaxBytes = [request[@"max_bytes"] respondsToSelector:@selector(integerValue)] ? [request[@"max_bytes"] integerValue] : 65536;
    if (requestedMaxBytes <= 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"max_bytes must be > 0."));
    }
    NSUInteger maxBytes = MIN((NSUInteger)requestedMaxBytes, (NSUInteger)(1024 * 1024));
    NSString *rootName = nil, *rootPath = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *pathError = FUFilesystemResolvePath(requestID, request, &rootName, &rootPath, &relativePath, &absolutePath);
    if (pathError) return pathError;

    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"The requested filesystem path does not exist."));
    }
    if (isDirectory) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"wrong_type", @"filesystem.read requires a file."));
    }

    @try {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:absolutePath];
        if (!handle) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"filesystem_failed", @"Unable to open the requested file."));
        }
        NSData *raw = [handle readDataOfLength:maxBytes + 1];
        [handle closeFile];
        BOOL truncated = raw.length > maxBytes;
        NSData *data = truncated ? [raw subdataWithRange:NSMakeRange(0, maxBytes)] : raw;
        struct stat st = {0};
        unsigned long long fileSize = lstat(absolutePath.fileSystemRepresentation, &st) == 0 ? (unsigned long long)MAX((off_t)0, st.st_size) : (unsigned long long)data.length;
        NSMutableDictionary *result = [@{
            @"root": rootName,
            @"root_path": rootPath,
            @"path": relativePath,
            @"byte_count": @(data.length),
            @"file_size": @(fileSize),
            @"max_bytes": @(maxBytes),
            @"truncated": (truncated ? @YES : @NO),
        } mutableCopy];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text) {
            result[@"encoding"] = @"utf-8";
            result[@"text"] = text;
        } else {
            result[@"encoding"] = @"base64";
            result[@"base64"] = [data base64EncodedStringWithOptions:0];
        }
        return FUResponse(requestID, YES, result, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"filesystem_failed", FUStorageTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleFilesystemSearch(NSString *requestID, NSDictionary *request) {
    id queryValue = request[@"query"];
    if (![queryValue isKindOfClass:[NSString class]] || [(NSString *)queryValue length] == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_query", @"filesystem.search requires a non-empty query string."));
    }
    NSUInteger offset = 0, limit = 100;
    if (!FUStorageRequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }
    NSInteger requestedMaxNodes = [request[@"max_nodes"] respondsToSelector:@selector(integerValue)] ? [request[@"max_nodes"] integerValue] : 5000;
    NSInteger requestedMaxDepth = [request[@"max_depth"] respondsToSelector:@selector(integerValue)] ? [request[@"max_depth"] integerValue] : 32;
    if (requestedMaxNodes <= 0 || requestedMaxDepth <= 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_search_bounds", @"max_nodes and max_depth must be > 0."));
    }
    NSUInteger maxNodes = MIN((NSUInteger)requestedMaxNodes, (NSUInteger)50000);
    NSUInteger maxDepth = MIN((NSUInteger)requestedMaxDepth, (NSUInteger)128);

    NSString *rootName = nil, *rootPath = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *pathError = FUFilesystemResolvePath(requestID, request, &rootName, &rootPath, &relativePath, &absolutePath);
    if (pathError) return pathError;
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"The requested filesystem path does not exist."));
    }
    if (!isDirectory) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"wrong_type", @"filesystem.search requires a directory."));
    }

    NSString *needle = [(NSString *)queryValue lowercaseString];
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray arrayWithObject:@{@"absolute": absolutePath, @"relative": relativePath, @"depth": @0}];
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    NSUInteger cursor = 0, visitedNodes = 0, unreadableDirectories = 0;
    BOOL traversalTruncated = NO;
    while (cursor < queue.count && !traversalTruncated) {
        NSDictionary *directory = queue[cursor++];
        NSUInteger depth = [directory[@"depth"] unsignedIntegerValue];
        if (depth >= maxDepth) continue;
        NSError *error = nil;
        NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory[@"absolute"] error:&error];
        if (!names) {
            unreadableDirectories++;
            continue;
        }
        for (NSString *name in FUFilesystemSortedNames(names)) {
            if (visitedNodes >= maxNodes) {
                traversalTruncated = YES;
                break;
            }
            visitedNodes++;
            NSString *childAbsolute = [directory[@"absolute"] stringByAppendingPathComponent:name];
            NSString *parentRelative = directory[@"relative"];
            NSString *childRelative = [parentRelative isEqualToString:@"."] ? name : [parentRelative stringByAppendingPathComponent:name];
            NSDictionary *entry = FUFilesystemEntry(childAbsolute, childRelative, name);
            if (!entry) continue;
            if ([name.lowercaseString containsString:needle]) [matches addObject:entry];
            if ([entry[@"type"] isEqualToString:@"directory"]) {
                [queue addObject:@{@"absolute": childAbsolute, @"relative": childRelative, @"depth": @(depth + 1)}];
            }
        }
    }
    [matches sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSString *leftPath = left[@"path"] ?: @"";
        NSString *rightPath = right[@"path"] ?: @"";
        NSComparisonResult folded = [leftPath caseInsensitiveCompare:rightPath];
        return folded != NSOrderedSame ? folded : [leftPath compare:rightPath options:NSLiteralSearch];
    }];
    NSUInteger total = matches.count;
    NSUInteger start = MIN(offset, total);
    NSUInteger end = MIN(total, start + limit);
    NSArray *page = [matches subarrayWithRange:NSMakeRange(start, end - start)];
    return FUResponse(requestID, YES, @{
        @"root": rootName,
        @"root_path": rootPath,
        @"path": relativePath,
        @"query": queryValue,
        @"matches": page,
        @"offset": @(offset),
        @"limit": @(limit),
        @"total": @(total),
        @"has_more": (end < total ? @YES : @NO),
        @"visited_nodes": @(visitedNodes),
        @"max_nodes": @(maxNodes),
        @"max_depth": @(maxDepth),
        @"traversal_truncated": (traversalTruncated ? @YES : @NO),
        @"unreadable_directories": @(unreadableDirectories),
    }, nil);
}

static NSDictionary *FUSQLiteResolveDatabase(
    NSString *requestID,
    NSDictionary *request,
    NSString **rootNameOut,
    NSString **relativePathOut,
    NSString **absolutePathOut
) {
    NSString *rootName = nil, *rootPath = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *pathError = FUFilesystemResolvePath(
        requestID, request, &rootName, &rootPath, &relativePath, &absolutePath
    );
    if (pathError) return pathError;

    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"The requested SQLite database does not exist."));
    }
    struct stat st = {0};
    if (isDirectory || stat(absolutePath.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"wrong_type", @"SQLite inspection requires a regular file."));
    }

    if (![FUStorageFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for SQLite inspection."));
    }
    Class managerClass = NSClassFromString(@"FLEXSQLiteDatabaseManager");
    SEL factory = NSSelectorFromString(@"managerForDatabase:");
    if (!managerClass || ![managerClass respondsToSelector:factory]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXSQLiteDatabaseManager."));
    }

    if (rootNameOut) *rootNameOut = rootName;
    if (relativePathOut) *relativePathOut = relativePath;
    if (absolutePathOut) *absolutePathOut = absolutePath;
    return nil;
}

static id FUSQLiteManagerForPath(NSString *absolutePath) {
    Class managerClass = NSClassFromString(@"FLEXSQLiteDatabaseManager");
    SEL factory = NSSelectorFromString(@"managerForDatabase:");
    return managerClass && [managerClass respondsToSelector:factory]
        ? ((id (*)(id, SEL, id))objc_msgSend)(managerClass, factory, absolutePath)
        : nil;
}

static NSArray *FUSQLiteArrayResult(id manager, NSString *selectorName, NSString *table) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!manager || ![manager respondsToSelector:selector]) return nil;
    id value = table
        ? ((id (*)(id, SEL, id))objc_msgSend)(manager, selector, table)
        : ((id (*)(id, SEL))objc_msgSend)(manager, selector);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static void FUSQLiteClose(id manager) {
    SEL closeSelector = NSSelectorFromString(@"close");
    if (manager && [manager respondsToSelector:closeSelector]) {
        ((BOOL (*)(id, SEL))objc_msgSend)(manager, closeSelector);
    }
}

NSDictionary *FUHandleSQLiteTables(NSString *requestID, NSDictionary *request) {
    NSUInteger offset = 0, limit = 100;
    if (!FUStorageRequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }
    NSString *rootName = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *resolveError = FUSQLiteResolveDatabase(
        requestID, request, &rootName, &relativePath, &absolutePath
    );
    if (resolveError) return resolveError;

    id manager = nil;
    @try {
        manager = FUSQLiteManagerForPath(absolutePath);
        NSArray *tables = FUSQLiteArrayResult(manager, @"queryAllTables", nil);
        if (!tables) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX failed to enumerate SQLite tables."));
        }
        NSUInteger total = tables.count;
        NSUInteger start = MIN(offset, total);
        NSUInteger end = MIN(total, start + limit);
        NSArray *page = [tables subarrayWithRange:NSMakeRange(start, end - start)];
        return FUResponse(requestID, YES, @{
            @"source": @"FLEXSQLiteDatabaseManager",
            @"root": rootName,
            @"path": relativePath,
            @"tables": page,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(total),
            @"has_more": (end < total ? @YES : @NO),
        }, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", FUStorageTruncatedString(exception.reason ?: exception.name, 1024)));
    } @finally {
        FUSQLiteClose(manager);
    }
}

NSDictionary *FUHandleSQLiteColumns(NSString *requestID, NSDictionary *request) {
    id tableValue = request[@"table"];
    if (![tableValue isKindOfClass:[NSString class]] || [(NSString *)tableValue length] == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"table must be a non-empty string."));
    }
    NSString *rootName = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *resolveError = FUSQLiteResolveDatabase(
        requestID, request, &rootName, &relativePath, &absolutePath
    );
    if (resolveError) return resolveError;

    id manager = nil;
    @try {
        manager = FUSQLiteManagerForPath(absolutePath);
        NSArray *tables = FUSQLiteArrayResult(manager, @"queryAllTables", nil);
        if (!tables) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX failed to enumerate SQLite tables."));
        }
        if (![tables containsObject:tableValue]) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"The requested SQLite table does not exist."));
        }
        NSArray *columns = FUSQLiteArrayResult(manager, @"queryAllColumnsOfTable:", tableValue);
        if (!columns) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX failed to enumerate SQLite columns."));
        }
        return FUResponse(requestID, YES, @{
            @"source": @"FLEXSQLiteDatabaseManager",
            @"root": rootName,
            @"path": relativePath,
            @"table": tableValue,
            @"columns": columns,
        }, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", FUStorageTruncatedString(exception.reason ?: exception.name, 1024)));
    } @finally {
        FUSQLiteClose(manager);
    }
}

NSDictionary *FUHandleSQLiteRows(NSString *requestID, NSDictionary *request) {
    id tableValue = request[@"table"];
    if (![tableValue isKindOfClass:[NSString class]] || [(NSString *)tableValue length] == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"table must be a non-empty string."));
    }
    NSUInteger offset = 0, limit = 100;
    if (!FUStorageRequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }
    NSString *rootName = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *resolveError = FUSQLiteResolveDatabase(
        requestID, request, &rootName, &relativePath, &absolutePath
    );
    if (resolveError) return resolveError;

    id manager = nil;
    @try {
        manager = FUSQLiteManagerForPath(absolutePath);
        NSArray *tables = FUSQLiteArrayResult(manager, @"queryAllTables", nil);
        if (!tables) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX failed to enumerate SQLite tables."));
        }
        if (![tables containsObject:tableValue]) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"The requested SQLite table does not exist."));
        }
        NSArray *columns = FUSQLiteArrayResult(manager, @"queryAllColumnsOfTable:", tableValue);
        NSArray *rows = FUSQLiteArrayResult(manager, @"queryAllDataInTable:", tableValue);
        if (!columns || !rows) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX failed to read the requested SQLite table."));
        }
        NSUInteger total = rows.count;
        NSUInteger start = MIN(offset, total);
        NSUInteger end = MIN(total, start + limit);
        NSArray *page = [rows subarrayWithRange:NSMakeRange(start, end - start)];
        return FUResponse(requestID, YES, @{
            @"source": @"FLEXSQLiteDatabaseManager",
            @"root": rootName,
            @"path": relativePath,
            @"table": tableValue,
            @"columns": columns,
            @"rows": page,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(total),
            @"has_more": (end < total ? @YES : @NO),
        }, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", FUStorageTruncatedString(exception.reason ?: exception.name, 1024)));
    } @finally {
        FUSQLiteClose(manager);
    }
}

static NSDictionary *FURealmResolveDatabase(
    NSString *requestID,
    NSDictionary *request,
    NSString **rootNameOut,
    NSString **relativePathOut,
    NSString **absolutePathOut
) {
    NSString *rootName = nil, *rootPath = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *pathError = FUFilesystemResolvePath(
        requestID, request, &rootName, &rootPath, &relativePath, &absolutePath
    );
    if (pathError) return pathError;

    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"The requested Realm database does not exist."));
    }
    struct stat st = {0};
    if (isDirectory || stat(absolutePath.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"wrong_type", @"Realm inspection requires a regular file."));
    }

    if (![FUStorageFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for Realm inspection."));
    }
    Class managerClass = NSClassFromString(@"FLEXRealmDatabaseManager");
    SEL factory = NSSelectorFromString(@"managerForDatabase:");
    if (!managerClass || ![managerClass respondsToSelector:factory]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXRealmDatabaseManager."));
    }
    if (!NSClassFromString(@"RLMRealm")) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"realm_unavailable", @"The target process does not have the Realm Objective-C runtime loaded."));
    }

    if (rootNameOut) *rootNameOut = rootName;
    if (relativePathOut) *relativePathOut = relativePath;
    if (absolutePathOut) *absolutePathOut = absolutePath;
    return nil;
}

static id FURealmManagerForPath(NSString *absolutePath) {
    Class managerClass = NSClassFromString(@"FLEXRealmDatabaseManager");
    SEL factory = NSSelectorFromString(@"managerForDatabase:");
    return managerClass && [managerClass respondsToSelector:factory]
        ? ((id (*)(id, SEL, id))objc_msgSend)(managerClass, factory, absolutePath)
        : nil;
}

static NSArray *FURealmArrayResult(id manager, NSString *selectorName, NSString *table) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!manager || ![manager respondsToSelector:selector]) return nil;
    id value = table
        ? ((id (*)(id, SEL, id))objc_msgSend)(manager, selector, table)
        : ((id (*)(id, SEL))objc_msgSend)(manager, selector);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static id FURealmJSONValue(id value) {
    if (!value || value == NSNull.null) return NSNull.null;
    if ([value isKindOfClass:[NSString class]]) return FUStorageTruncatedString(value, 2048);
    if ([value isKindOfClass:[NSNumber class]]) return FUStorageJSONValue(value);
    if ([value isKindOfClass:[NSDate class]]) {
        return @{
            @"kind": @"date",
            @"time_interval_since_1970": FUStorageJSONFloatingNumber([(NSDate *)value timeIntervalSince1970]),
            @"description": FUStorageTruncatedString([value description] ?: @"", 512),
        };
    }
    if ([value isKindOfClass:[NSData class]]) {
        return @{
            @"kind": @"data",
            @"byte_count": @([(NSData *)value length]),
            @"base64": [(NSData *)value base64EncodedStringWithOptions:0] ?: @"",
        };
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id item in (NSArray *)value) {
            [result addObject:FURealmJSONValue(item) ?: NSNull.null];
        }
        return result;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)value count]];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id item, BOOL *stop) {
            (void)stop;
            if (![key isKindOfClass:[NSString class]]) return;
            result[key] = FURealmJSONValue(item) ?: NSNull.null;
        }];
        return result;
    }
    return FUStorageJSONValue(value);
}

static NSArray *FURealmJSONRows(NSArray *rows) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:rows.count];
    for (id rowValue in rows) {
        if (![rowValue isKindOfClass:[NSArray class]]) {
            [result addObject:@[FURealmJSONValue(rowValue) ?: NSNull.null]];
            continue;
        }
        NSMutableArray *row = [NSMutableArray arrayWithCapacity:[(NSArray *)rowValue count]];
        for (id value in (NSArray *)rowValue) {
            [row addObject:FURealmJSONValue(value) ?: NSNull.null];
        }
        [result addObject:row];
    }
    return result;
}

NSDictionary *FUHandleRealmTables(NSString *requestID, NSDictionary *request) {
    NSUInteger offset = 0, limit = 100;
    if (!FUStorageRequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }
    NSString *rootName = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *resolveError = FURealmResolveDatabase(
        requestID, request, &rootName, &relativePath, &absolutePath
    );
    if (resolveError) return resolveError;

    @try {
        id manager = FURealmManagerForPath(absolutePath);
        if (!manager) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX could not open the requested Realm database."));
        }
        NSArray *tables = FURealmArrayResult(manager, @"queryAllTables", nil);
        if (!tables) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX failed to enumerate Realm tables."));
        }
        NSUInteger total = tables.count;
        NSUInteger start = MIN(offset, total);
        NSUInteger end = MIN(total, start + limit);
        NSArray *page = [tables subarrayWithRange:NSMakeRange(start, end - start)];
        return FUResponse(requestID, YES, @{
            @"source": @"FLEXRealmDatabaseManager",
            @"root": rootName,
            @"path": relativePath,
            @"tables": page,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(total),
            @"has_more": (end < total ? @YES : @NO),
        }, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", FUStorageTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleRealmColumns(NSString *requestID, NSDictionary *request) {
    id tableValue = request[@"table"];
    if (![tableValue isKindOfClass:[NSString class]] || [(NSString *)tableValue length] == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"table must be a non-empty string."));
    }
    NSString *rootName = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *resolveError = FURealmResolveDatabase(
        requestID, request, &rootName, &relativePath, &absolutePath
    );
    if (resolveError) return resolveError;

    @try {
        id manager = FURealmManagerForPath(absolutePath);
        if (!manager) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX could not open the requested Realm database."));
        }
        NSArray *tables = FURealmArrayResult(manager, @"queryAllTables", nil);
        if (!tables) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX failed to enumerate Realm tables."));
        }
        if (![tables containsObject:tableValue]) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"The requested Realm table does not exist."));
        }
        NSArray *columns = FURealmArrayResult(manager, @"queryAllColumnsOfTable:", tableValue);
        if (!columns) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX failed to enumerate Realm columns."));
        }
        return FUResponse(requestID, YES, @{
            @"source": @"FLEXRealmDatabaseManager",
            @"root": rootName,
            @"path": relativePath,
            @"table": tableValue,
            @"columns": columns,
        }, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", FUStorageTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

NSDictionary *FUHandleRealmRows(NSString *requestID, NSDictionary *request) {
    id tableValue = request[@"table"];
    if (![tableValue isKindOfClass:[NSString class]] || [(NSString *)tableValue length] == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"table must be a non-empty string."));
    }
    NSUInteger offset = 0, limit = 100;
    if (!FUStorageRequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }
    NSString *rootName = nil, *relativePath = nil, *absolutePath = nil;
    NSDictionary *resolveError = FURealmResolveDatabase(
        requestID, request, &rootName, &relativePath, &absolutePath
    );
    if (resolveError) return resolveError;

    @try {
        id manager = FURealmManagerForPath(absolutePath);
        if (!manager) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX could not open the requested Realm database."));
        }
        NSArray *tables = FURealmArrayResult(manager, @"queryAllTables", nil);
        if (!tables) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX failed to enumerate Realm tables."));
        }
        if (![tables containsObject:tableValue]) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"not_found", @"The requested Realm table does not exist."));
        }
        NSArray *columns = FURealmArrayResult(manager, @"queryAllColumnsOfTable:", tableValue);
        if (!columns) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", @"FLEX failed to enumerate Realm columns."));
        }
        NSArray *rawRows = FURealmArrayResult(manager, @"queryAllDataInTable:", tableValue);
        NSArray *rows = rawRows ?: @[];
        NSUInteger total = rows.count;
        NSUInteger start = MIN(offset, total);
        NSUInteger end = MIN(total, start + limit);
        NSArray *page = FURealmJSONRows([rows subarrayWithRange:NSMakeRange(start, end - start)]);
        return FUResponse(requestID, YES, @{
            @"source": @"FLEXRealmDatabaseManager",
            @"root": rootName,
            @"path": relativePath,
            @"table": tableValue,
            @"columns": columns,
            @"rows": page,
            @"offset": @(offset),
            @"limit": @(limit),
            @"total": @(total),
            @"has_more": (end < total ? @YES : @NO),
        }, nil);
    } @catch (NSException *exception) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"database_failed", FUStorageTruncatedString(exception.reason ?: exception.name, 1024)));
    }
}

