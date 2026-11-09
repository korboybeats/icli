#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "FURuntime.h"
#import "FUProtocol.h"
#import "FUSwiftInspection.h"

static FURuntimeObjectReferenceProvider FURuntimeObjectReferenceProviderCallback = NULL;
static FURuntimePropertyEntryProvider FURuntimePropertyEntryProviderCallback = NULL;
static FURuntimeIvarEntryProvider FURuntimeIvarEntryProviderCallback = NULL;
static FURuntimeMethodEntryProvider FURuntimeMethodEntryProviderCallback = NULL;

void FURuntimeConfigure(
    FURuntimeObjectReferenceProvider objectReferenceProvider,
    FURuntimePropertyEntryProvider propertyEntryProvider,
    FURuntimeIvarEntryProvider ivarEntryProvider,
    FURuntimeMethodEntryProvider methodEntryProvider
) {
    FURuntimeObjectReferenceProviderCallback = objectReferenceProvider;
    FURuntimePropertyEntryProviderCallback = propertyEntryProvider;
    FURuntimeIvarEntryProviderCallback = ivarEntryProvider;
    FURuntimeMethodEntryProviderCallback = methodEntryProvider;
}

static NSDictionary *FURuntimeObjectReference(id object) {
    if (!object || !FURuntimeObjectReferenceProviderCallback) {
        return @{};
    }
    NSDictionary *reference = FURuntimeObjectReferenceProviderCallback(object);
    return [reference isKindOfClass:[NSDictionary class]] ? reference : @{};
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

static id FURuntimeObjectMessage(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static BOOL FURuntimeBoolMessage(id target, NSString *selectorName, BOOL fallback) {
    if (!target || selectorName.length == 0) return fallback;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSString *FURuntimeClassName(id object) {
    if (!object) return @"";
    if (object_isClass(object)) return NSStringFromClass((Class)object) ?: @"";
    return NSStringFromClass([object class]) ?: @"";
}

static BOOL FURuntimeQueryMatchesValue(id value, NSString *query) {
    if (!query.length) return YES;
    NSString *text = [value isKindOfClass:[NSString class]] ? value : [value description];
    return text.length && [text rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL FURuntimeMemberMatchesQuery(id member, NSString *declaringClass, NSString *query, BOOL method) {
    if (!query.length) return YES;
    if (FURuntimeQueryMatchesValue(FURuntimeObjectMessage(member, method ? @"selectorString" : @"name"), query) ||
        FURuntimeQueryMatchesValue(declaringClass, query)) {
        return YES;
    }
    if (method) {
        return FURuntimeQueryMatchesValue(FURuntimeObjectMessage(member, @"name"), query) ||
            FURuntimeQueryMatchesValue(FURuntimeObjectMessage(member, @"signatureString"), query);
    }
    return NO;
}

static id FURuntimeObjectExplorerForObject(id object) {
    Class explorerClass = NSClassFromString(@"FLEXObjectExplorer");
    SEL factory = NSSelectorFromString(@"forObject:");
    if (!explorerClass || ![explorerClass respondsToSelector:factory]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(explorerClass, factory, object);
}

static BOOL FUClassRespondsToClassSelector(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    return cls && [cls respondsToSelector:NSSelectorFromString(selectorName)];
}

static BOOL FUClassRespondsToInstanceSelector(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    return cls && [cls instancesRespondToSelector:NSSelectorFromString(selectorName)];
}

static id FUSafeClassObjectMessage(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSDictionary *FUOperationSupportEntry(BOOL supported,
                                             NSString *source,
                                             NSString *reason,
                                             NSArray<NSString *> *requirements,
                                             BOOL conditional,
                                             NSArray<NSString *> *limitations) {
    NSMutableDictionary *entry = [@{
        @"supported": @(supported),
        @"source": source.length ? source : @"native",
        @"requirements": requirements ?: @[],
    } mutableCopy];
    if (!supported && reason.length) entry[@"reason"] = reason;
    if (conditional) entry[@"conditional"] = @YES;
    if (limitations.count) entry[@"limitations"] = limitations;
    return entry;
}

static void FUSetOperationSupport(NSMutableDictionary<NSString *, NSDictionary *> *support,
                                  NSString *operation,
                                  BOOL supported,
                                  NSString *source,
                                  NSString *reason,
                                  NSArray<NSString *> *requirements,
                                  BOOL conditional,
                                  NSArray<NSString *> *limitations) {
    if (!operation.length) return;
    support[operation] = FUOperationSupportEntry(supported, source, reason, requirements, conditional, limitations);
}

static NSString *FUFlexSupportReason(BOOL flexLoaded, BOOL supported) {
    if (supported) return nil;
    return flexLoaded ? @"unsupported_flex" : @"flex_unavailable";
}

static NSDictionary<NSString *, NSDictionary *> *FUOperationSupportForCurrentRuntime(BOOL flexLoaded,
                                                                                      BOOL swiftInspectionAvailable) {
    NSMutableDictionary<NSString *, NSDictionary *> *support = [NSMutableDictionary dictionary];
    for (NSString *operation in FUAgentCapabilities()) {
        support[operation] = FUOperationSupportEntry(YES, @"native", nil, @[], NO, nil);
    }

    BOOL managerShared = flexLoaded && FUClassRespondsToClassSelector(@"FLEXManager", @"sharedManager");
    BOOL managerShow = managerShared && FUClassRespondsToInstanceSelector(@"FLEXManager", @"showExplorer");
    BOOL managerHide = managerShared && FUClassRespondsToInstanceSelector(@"FLEXManager", @"hideExplorer");
    FUSetOperationSupport(support, @"flex.show", managerShow, @"FLEX", FUFlexSupportReason(flexLoaded, managerShow),
                          @[@"FLEXManager.+sharedManager", @"FLEXManager.-showExplorer"], NO, nil);
    FUSetOperationSupport(support, @"flex.hide", managerHide, @"FLEX", FUFlexSupportReason(flexLoaded, managerHide),
                          @[@"FLEXManager.+sharedManager", @"FLEXManager.-hideExplorer"], NO, nil);

    id runtime = flexLoaded ? FUSafeClassObjectMessage(@"FLEXRuntimeClient", @"runtime") : nil;
    BOOL tokenAny = FUClassRespondsToClassSelector(@"FLEXSearchToken", @"any");
    BOOL tokenString = FUClassRespondsToClassSelector(@"FLEXSearchToken", @"string:options:");
    BOOL runtimeClasses = runtime && tokenAny && tokenString &&
        [runtime respondsToSelector:NSSelectorFromString(@"bundlePathsForToken:")] &&
        [runtime respondsToSelector:NSSelectorFromString(@"classesForToken:inBundles:")];
    BOOL runtimeImages = runtime &&
        [runtime respondsToSelector:NSSelectorFromString(@"imagePaths")] &&
        [runtime respondsToSelector:NSSelectorFromString(@"imageDisplayNames")];
    BOOL runtimeImageClasses = runtimeImages &&
        [runtime respondsToSelector:NSSelectorFromString(@"classNamesInImageAtPath:")];
    BOOL runtimeProtocols = runtime &&
        [runtime respondsToSelector:NSSelectorFromString(@"copyProtocolList")];
    BOOL runtimeMethods = runtime && tokenAny && tokenString &&
        [runtime respondsToSelector:NSSelectorFromString(@"methodsForToken:instance:inClasses:")];
    BOOL runtimeClass = flexLoaded;

    FUSetOperationSupport(support, @"runtime.classes", runtimeClasses, @"FLEX", FUFlexSupportReason(flexLoaded, runtimeClasses),
                          @[@"FLEXRuntimeClient.+runtime", @"FLEXSearchToken.+any", @"FLEXSearchToken.+string:options:", @"runtime.bundlePathsForToken:", @"runtime.classesForToken:inBundles:"], NO, nil);
    FUSetOperationSupport(support, @"runtime.class", runtimeClass, @"FLEX+ObjectiveCRuntime", FUFlexSupportReason(flexLoaded, runtimeClass),
                          @[@"FLEX loaded", @"Objective-C runtime"], NO, nil);
    FUSetOperationSupport(support, @"runtime.class_protocols", runtimeClass, @"FLEX+ObjectiveCRuntime", FUFlexSupportReason(flexLoaded, runtimeClass),
                          @[@"FLEX loaded", @"Objective-C runtime"], NO, nil);
    FUSetOperationSupport(support, @"runtime.images", runtimeImages, @"FLEX", FUFlexSupportReason(flexLoaded, runtimeImages),
                          @[@"FLEXRuntimeClient.+runtime", @"runtime.imagePaths", @"runtime.imageDisplayNames"], NO, nil);
    FUSetOperationSupport(support, @"runtime.image_classes", runtimeImageClasses, @"FLEX", FUFlexSupportReason(flexLoaded, runtimeImageClasses),
                          @[@"FLEXRuntimeClient.+runtime", @"runtime.imagePaths", @"runtime.imageDisplayNames", @"runtime.classNamesInImageAtPath:"], NO, nil);
    for (NSString *operation in @[@"runtime.protocols", @"runtime.protocol", @"runtime.protocol_classes"]) {
        FUSetOperationSupport(support, operation, runtimeProtocols, @"FLEX+ObjectiveCRuntime", FUFlexSupportReason(flexLoaded, runtimeProtocols),
                              @[@"FLEXRuntimeClient.+runtime", @"runtime.copyProtocolList"], NO, nil);
    }
    FUSetOperationSupport(support, @"runtime.methods", runtimeMethods, @"FLEX", FUFlexSupportReason(flexLoaded, runtimeMethods),
                          @[@"FLEXRuntimeClient.+runtime", @"FLEXSearchToken.+any", @"FLEXSearchToken.+string:options:", @"runtime.methodsForToken:instance:inClasses:"], NO, nil);

    BOOL objectExplorer = flexLoaded && FUClassRespondsToClassSelector(@"FLEXObjectExplorer", @"forObject:");
    BOOL explorerHierarchy = objectExplorer && FUClassRespondsToInstanceSelector(@"FLEXObjectExplorer", @"classHierarchyClasses");
    BOOL explorerProperties = explorerHierarchy && FUClassRespondsToInstanceSelector(@"FLEXObjectExplorer", @"allProperties");
    BOOL explorerIvars = explorerHierarchy && FUClassRespondsToInstanceSelector(@"FLEXObjectExplorer", @"allIvars");
    BOOL explorerMethods = explorerHierarchy &&
        FUClassRespondsToInstanceSelector(@"FLEXObjectExplorer", @"allMethods") &&
        FUClassRespondsToInstanceSelector(@"FLEXObjectExplorer", @"allClassMethods");
    BOOL objectInspect = explorerProperties && explorerIvars && explorerMethods;
    FUSetOperationSupport(support, @"runtime.properties", explorerProperties, @"FLEX", FUFlexSupportReason(flexLoaded, explorerProperties),
                          @[@"FLEXObjectExplorer.+forObject:", @"explorer.classHierarchyClasses", @"explorer.allProperties"], NO, nil);
    FUSetOperationSupport(support, @"runtime.ivars", explorerIvars, @"FLEX", FUFlexSupportReason(flexLoaded, explorerIvars),
                          @[@"FLEXObjectExplorer.+forObject:", @"explorer.classHierarchyClasses", @"explorer.allIvars"], NO, nil);
    FUSetOperationSupport(support, @"object.inspect", objectInspect, @"FLEX", FUFlexSupportReason(flexLoaded, objectInspect),
                          @[@"FLEXObjectExplorer.+forObject:", @"explorer.classHierarchyClasses", @"explorer.allProperties", @"explorer.allIvars", @"explorer.allMethods", @"explorer.allClassMethods"], NO, nil);
    FUSetOperationSupport(support, @"object.properties", explorerProperties, @"FLEX", FUFlexSupportReason(flexLoaded, explorerProperties),
                          @[@"FLEXObjectExplorer.+forObject:", @"explorer.classHierarchyClasses", @"explorer.allProperties"], NO, nil);
    FUSetOperationSupport(support, @"object.ivars", explorerIvars, @"FLEX", FUFlexSupportReason(flexLoaded, explorerIvars),
                          @[@"FLEXObjectExplorer.+forObject:", @"explorer.classHierarchyClasses", @"explorer.allIvars"], NO, nil);
    FUSetOperationSupport(support, @"object.methods", explorerMethods, @"FLEX", FUFlexSupportReason(flexLoaded, explorerMethods),
                          @[@"FLEXObjectExplorer.+forObject:", @"explorer.classHierarchyClasses", @"explorer.allMethods", @"explorer.allClassMethods"], NO, nil);
    BOOL objectGet = explorerProperties && explorerIvars;
    FUSetOperationSupport(support, @"object.get", objectGet, @"FLEX", FUFlexSupportReason(flexLoaded, objectGet),
                          @[@"FLEXObjectExplorer.+forObject:", @"explorer.classHierarchyClasses", @"explorer.allProperties|explorer.allIvars"], YES,
                          @[@"The requested property or ivar must exist on the resolved object."]);
    FUSetOperationSupport(support, @"object.set", objectGet, @"FLEX", FUFlexSupportReason(flexLoaded, objectGet),
                          @[@"FLEXObjectExplorer.+forObject:", @"explorer.classHierarchyClasses", @"explorer.allProperties|explorer.allIvars"], YES,
                          @[@"The requested member must be writable; scalar ivars additionally require FLEXRuntimeUtility numeric conversion support."]);

    Class heapClass = flexLoaded ? NSClassFromString(@"FLEXHeapEnumerator") : Nil;
    BOOL heapEnumerate = heapClass && [heapClass respondsToSelector:NSSelectorFromString(@"enumerateLiveObjectsUsingBlock:")];
    BOOL heapSnapshot = heapClass && ([heapClass respondsToSelector:NSSelectorFromString(@"generateHeapSnapshot")] || heapEnumerate);
    BOOL heapInstances = heapClass && [heapClass respondsToSelector:NSSelectorFromString(@"instancesOfClassWithName:retained:")];
    BOOL heapReferences = heapClass && (heapEnumerate || [heapClass respondsToSelector:NSSelectorFromString(@"objectsWithReferencesToObject:retained:")]);
    FUSetOperationSupport(support, @"heap.snapshot", heapSnapshot, @"FLEX", FUFlexSupportReason(flexLoaded, heapSnapshot),
                          @[@"FLEXHeapEnumerator.+generateHeapSnapshot|+enumerateLiveObjectsUsingBlock:"], NO, nil);
    FUSetOperationSupport(support, @"heap.instances", heapInstances, @"FLEX", FUFlexSupportReason(flexLoaded, heapInstances),
                          @[@"FLEXHeapEnumerator.+instancesOfClassWithName:retained:"], NO, nil);
    for (NSString *operation in @[@"heap.references", @"heap.reference_graph"]) {
        FUSetOperationSupport(support, operation, heapReferences, @"FLEX", FUFlexSupportReason(flexLoaded, heapReferences),
                              @[@"FLEXHeapEnumerator.+enumerateLiveObjectsUsingBlock:|+objectsWithReferencesToObject:retained:"], NO, nil);
    }
    support[@"heap.subclasses"] = FUOperationSupportEntry(YES, @"ObjectiveCRuntime", nil, @[], YES,
                                                            @[@"FLEXRuntimeUtility subclass lookup is used when available; Objective-C runtime enumeration is the fallback."]);

    BOOL bookmarks = flexLoaded && FUClassRespondsToClassSelector(@"FLEXBookmarkManager", @"bookmarks");
    for (NSString *operation in @[@"bookmarks.list", @"bookmarks.add", @"bookmarks.remove"]) {
        FUSetOperationSupport(support, operation, bookmarks, @"FLEX", FUFlexSupportReason(flexLoaded, bookmarks),
                              @[@"FLEXBookmarkManager.+bookmarks"], YES,
                              @[@"Mutation operations also require the returned bookmarks collection to be mutable."]);
    }

    id recorder = flexLoaded ? FUSafeClassObjectMessage(@"FLEXNetworkRecorder", @"defaultRecorder") : nil;
    BOOL networkHTTP = recorder && [recorder respondsToSelector:NSSelectorFromString(@"orderedHTTPTransactions")];
    BOOL networkWS = recorder && [recorder respondsToSelector:NSSelectorFromString(@"orderedWSTransactions")];
    BOOL networkFirebase = recorder && [recorder respondsToSelector:NSSelectorFromString(@"orderedFirebaseTransactions")];
    BOOL network = networkHTTP || networkWS || networkFirebase;
    NSMutableArray<NSString *> *networkLimitations = [NSMutableArray array];
    if (network && !networkHTTP) [networkLimitations addObject:@"HTTP transaction history is unavailable in this FLEX build."];
    if (network && !networkWS) [networkLimitations addObject:@"WebSocket transaction history is unavailable in this FLEX build."];
    if (network && !networkFirebase) [networkLimitations addObject:@"Firebase transaction history is unavailable in this FLEX build."];
    FUSetOperationSupport(support, @"network.transactions", network, @"FLEX", FUFlexSupportReason(flexLoaded, network),
                          @[@"FLEXNetworkRecorder.+defaultRecorder", @"at least one ordered transaction selector"],
                          networkLimitations.count > 0, networkLimitations);

    id logController = flexLoaded ? FUSafeClassObjectMessage(@"FLEXOSLogController", @"sharedLogController") : nil;
    BOOL logs = logController &&
        [logController respondsToSelector:NSSelectorFromString(@"persistent")] &&
        [logController respondsToSelector:NSSelectorFromString(@"setPersistent:")] &&
        [logController respondsToSelector:NSSelectorFromString(@"startMonitoring")] &&
        [logController respondsToSelector:NSSelectorFromString(@"messages")];
    FUSetOperationSupport(support, @"logs.messages", logs, @"FLEX", FUFlexSupportReason(flexLoaded, logs),
                          @[@"FLEXOSLogController.+sharedLogController", @"controller.persistent", @"controller.setPersistent:", @"controller.startMonitoring", @"controller.messages"], NO, nil);

    BOOL globals = flexLoaded && FUClassRespondsToClassSelector(@"FLEXGlobalsViewController", @"defaultGlobalSections");
    FUSetOperationSupport(support, @"globals.entries", globals, @"FLEX", FUFlexSupportReason(flexLoaded, globals),
                          @[@"FLEXGlobalsViewController.+defaultGlobalSections"], YES,
                          @[@"Returned global sections must expose allRows."]);
    FUSetOperationSupport(support, @"globals.open", globals && managerShow, @"FLEX", FUFlexSupportReason(flexLoaded, globals && managerShow),
                          @[@"FLEXGlobalsViewController.+defaultGlobalSections", @"FLEXManager.+sharedManager", @"FLEXManager.-showExplorer"], YES,
                          @[@"The selected global entry must expose a viewControllerFuture."]);
    BOOL globalsInvoke = globals && FUClassRespondsToInstanceSelector(@"FLEXGlobalsViewController", @"init");
    FUSetOperationSupport(support, @"globals.invoke", globalsInvoke, @"FLEX", FUFlexSupportReason(flexLoaded, globalsInvoke),
                          @[@"FLEXGlobalsViewController.+defaultGlobalSections", @"FLEXGlobalsViewController.-init"], YES,
                          @[@"The selected global entry must expose a rowAction."]);

    BOOL defaultsEntries = flexLoaded &&
        FUClassRespondsToClassSelector(@"FLEXDefaultsContentSection", @"standard") &&
        FUClassRespondsToInstanceSelector(@"FLEXDefaultsContentSection", @"unexcludedDefaults") &&
        FUClassRespondsToInstanceSelector(@"FLEXDefaultsContentSection", @"setOnlyShowKeysForAppPrefs:");
    FUSetOperationSupport(support, @"defaults.entries", defaultsEntries, @"FLEX", FUFlexSupportReason(flexLoaded, defaultsEntries),
                          @[@"FLEXDefaultsContentSection.+standard", @"section.-unexcludedDefaults", @"section.-setOnlyShowKeysForAppPrefs:"], NO, nil);

    BOOL keychainItems = flexLoaded && FUClassRespondsToClassSelector(@"FLEXKeychain", @"allAccounts");
    BOOL keychainItem = keychainItems && FUClassRespondsToInstanceSelector(@"FLEXKeychainQuery", @"fetch:");
    FUSetOperationSupport(support, @"keychain.items", keychainItems, @"FLEX", FUFlexSupportReason(flexLoaded, keychainItems),
                          @[@"FLEXKeychain.+allAccounts"], NO, nil);
    FUSetOperationSupport(support, @"keychain.item", keychainItem, @"FLEX", FUFlexSupportReason(flexLoaded, keychainItem),
                          @[@"FLEXKeychain.+allAccounts", @"FLEXKeychainQuery.-fetch:"], YES,
                          @[@"Access-group selection is applied only when the loaded FLEX query implementation supports it."]);

    BOOL sqliteBase = flexLoaded && FUClassRespondsToClassSelector(@"FLEXSQLiteDatabaseManager", @"managerForDatabase:");
    BOOL sqliteTables = sqliteBase && FUClassRespondsToInstanceSelector(@"FLEXSQLiteDatabaseManager", @"queryAllTables");
    BOOL sqliteColumns = sqliteTables && FUClassRespondsToInstanceSelector(@"FLEXSQLiteDatabaseManager", @"queryAllColumnsOfTable:");
    BOOL sqliteRows = sqliteColumns && FUClassRespondsToInstanceSelector(@"FLEXSQLiteDatabaseManager", @"queryAllDataInTable:");
    FUSetOperationSupport(support, @"database.sqlite.tables", sqliteTables, @"FLEX", FUFlexSupportReason(flexLoaded, sqliteTables),
                          @[@"FLEXSQLiteDatabaseManager.+managerForDatabase:", @"manager.-queryAllTables"], NO, nil);
    FUSetOperationSupport(support, @"database.sqlite.columns", sqliteColumns, @"FLEX", FUFlexSupportReason(flexLoaded, sqliteColumns),
                          @[@"FLEXSQLiteDatabaseManager.+managerForDatabase:", @"manager.-queryAllTables", @"manager.-queryAllColumnsOfTable:"], NO, nil);
    FUSetOperationSupport(support, @"database.sqlite.rows", sqliteRows, @"FLEX", FUFlexSupportReason(flexLoaded, sqliteRows),
                          @[@"FLEXSQLiteDatabaseManager.+managerForDatabase:", @"manager.-queryAllTables", @"manager.-queryAllColumnsOfTable:", @"manager.-queryAllDataInTable:"], NO, nil);

    BOOL realmRuntime = NSClassFromString(@"RLMRealm") != Nil;
    BOOL realmBase = flexLoaded && realmRuntime && FUClassRespondsToClassSelector(@"FLEXRealmDatabaseManager", @"managerForDatabase:");
    BOOL realmTables = realmBase && FUClassRespondsToInstanceSelector(@"FLEXRealmDatabaseManager", @"queryAllTables");
    BOOL realmColumns = realmTables && FUClassRespondsToInstanceSelector(@"FLEXRealmDatabaseManager", @"queryAllColumnsOfTable:");
    BOOL realmRows = realmColumns && FUClassRespondsToInstanceSelector(@"FLEXRealmDatabaseManager", @"queryAllDataInTable:");
    NSString *(^realmReason)(BOOL) = ^NSString *(BOOL supported) {
        if (supported) return (NSString *)nil;
        if (!flexLoaded) return @"flex_unavailable";
        if (!realmRuntime) return @"realm_runtime_unavailable";
        return @"unsupported_flex";
    };
    FUSetOperationSupport(support, @"database.realm.tables", realmTables, @"FLEX+Realm", realmReason(realmTables),
                          @[@"RLMRealm loaded", @"FLEXRealmDatabaseManager.+managerForDatabase:", @"manager.-queryAllTables"], NO, nil);
    FUSetOperationSupport(support, @"database.realm.columns", realmColumns, @"FLEX+Realm", realmReason(realmColumns),
                          @[@"RLMRealm loaded", @"FLEXRealmDatabaseManager.+managerForDatabase:", @"manager.-queryAllTables", @"manager.-queryAllColumnsOfTable:"], NO, nil);
    FUSetOperationSupport(support, @"database.realm.rows", realmRows, @"FLEX+Realm", realmReason(realmRows),
                          @[@"RLMRealm loaded", @"FLEXRealmDatabaseManager.+managerForDatabase:", @"manager.-queryAllTables", @"manager.-queryAllColumnsOfTable:", @"manager.-queryAllDataInTable:"], NO, nil);

    BOOL uiDeepInspect = objectInspect;
    FUSetOperationSupport(support, @"ui.deep_inspect", uiDeepInspect, @"UIKit+FLEX", FUFlexSupportReason(flexLoaded, uiDeepInspect),
                          @[@"UIKit", @"object.inspect FLEX surface"], NO, nil);

    BOOL swiftMetadata = swiftInspectionAvailable &&
        FUClassRespondsToClassSelector(@"FLEXSwiftMetadataInspector", @"inspectClass:limit:");
    FUSetOperationSupport(support, @"swift.inspect", swiftMetadata, @"ReflexMetadata",
                          swiftMetadata ? nil : @"reflex_unavailable",
                          @[@"FLEXSwiftMetadataInspector.+inspectClass:limit:", @"metadata-only Swift class descriptors"], YES,
                          @[@"Swift field values, mangled-type resolution, protocol conformances, and FLEXSwiftMirror remain disabled."]);

    BOOL investigateScreen = uiDeepInspect;
    FUSetOperationSupport(support, @"investigate.screen", investigateScreen, @"UIKit+FLEX", FUFlexSupportReason(flexLoaded, investigateScreen),
                          @[@"ui.snapshot", @"ui.deep_inspect"], YES,
                          @[@"Swift metadata is optional and may be unavailable without failing the investigation."]);
    BOOL investigateElement = investigateScreen && objectInspect && runtimeClass && runtimeMethods && explorerProperties && explorerIvars;
    FUSetOperationSupport(support, @"investigate.element", investigateElement, @"UIKit+FLEX+ObjectiveCRuntime", FUFlexSupportReason(flexLoaded, investigateElement),
                          @[@"investigate.screen", @"object.inspect", @"runtime.class", @"runtime.methods", @"runtime.properties", @"runtime.ivars"], YES,
                          @[@"Reverse-reference graph discovery is optional and may degrade independently when heap support is unavailable or times out."]);

    return support;
}

NSDictionary *FUFlexStatus(BOOL loadIfNeeded) {
    BOOL wasLoaded = NSClassFromString(@"FLEXManager") != Nil;
    NSString *loadedPath = nil;
    BOOL swiftInspectionAvailable = FUSwiftInspectionAvailable();

    if (!wasLoaded && loadIfNeeded) {
        NSArray<NSString *> *paths = @[
            @"/var/jb/usr/lib/flexultra/libFLEX.dylib",
            @"/usr/lib/flexultra/libFLEX.dylib",
            @"/var/jb/Library/MobileSubstrate/DynamicLibraries/libFLEX.dylib",
            @"/Library/MobileSubstrate/DynamicLibraries/libFLEX.dylib",
        ];

        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *path in paths) {
            if (![fm fileExistsAtPath:path]) {
                continue;
            }
            if (dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
                loadedPath = path;
                break;
            }
        }
    }

    if (loadIfNeeded && swiftInspectionAvailable && NSClassFromString(@"FLEXSwiftMetadataInspector") == Nil) {
        NSArray<NSString *> *reflexPaths = @[
            @"/var/jb/Library/MobileSubstrate/DynamicLibraries/libreflex.dylib",
            @"/Library/MobileSubstrate/DynamicLibraries/libreflex.dylib",
        ];
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *path in reflexPaths) {
            if ([fm fileExistsAtPath:path]) {
                dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
                break;
            }
        }
    }

    BOOL loaded = NSClassFromString(@"FLEXManager") != Nil;
    BOOL reflex = NO;
    Class explorer = NSClassFromString(@"FLEXObjectExplorer");
    SEL reflexSelector = NSSelectorFromString(@"reflexAvailable");
    SEL setReflexSelector = NSSelectorFromString(@"setReflexAvailable:");
    if (explorer && [explorer respondsToSelector:setReflexSelector]) {
        // Keep FLEXObjectExplorer's automatic Reflex integration off. It can
        // construct FLEXSwiftMirror for arbitrary objects, which is the
        // crash-prone path FlexUltra is deliberately avoiding.
        ((void (*)(id, SEL, BOOL))objc_msgSend)(explorer, setReflexSelector, NO);
    }
    if (explorer && [explorer respondsToSelector:reflexSelector]) {
        reflex = ((BOOL (*)(id, SEL))objc_msgSend)(explorer, reflexSelector);
    }

    id runtime = loaded ? FUSafeClassObjectMessage(@"FLEXRuntimeClient", @"runtime") : nil;
    BOOL manager = loaded && FUClassRespondsToClassSelector(@"FLEXManager", @"sharedManager");
    BOOL runtimeCatalog = loaded && runtime &&
        FUClassRespondsToClassSelector(@"FLEXSearchToken", @"any") &&
        FUClassRespondsToClassSelector(@"FLEXSearchToken", @"string:options:") &&
        [runtime respondsToSelector:NSSelectorFromString(@"bundlePathsForToken:")] &&
        [runtime respondsToSelector:NSSelectorFromString(@"classesForToken:inBundles:")] &&
        [runtime respondsToSelector:NSSelectorFromString(@"imagePaths")] &&
        [runtime respondsToSelector:NSSelectorFromString(@"imageDisplayNames")] &&
        [runtime respondsToSelector:NSSelectorFromString(@"classNamesInImageAtPath:")] &&
        [runtime respondsToSelector:NSSelectorFromString(@"copyProtocolList")];
    BOOL runtimeMethodSearch = runtimeCatalog &&
        [runtime respondsToSelector:NSSelectorFromString(@"methodsForToken:instance:inClasses:")];
    BOOL objectExplorer = loaded && FUClassRespondsToClassSelector(@"FLEXObjectExplorer", @"forObject:");
    BOOL bookmarks = loaded && FUClassRespondsToClassSelector(@"FLEXBookmarkManager", @"bookmarks");

    id recorder = loaded ? FUSafeClassObjectMessage(@"FLEXNetworkRecorder", @"defaultRecorder") : nil;
    BOOL networkHistory = recorder &&
        [recorder respondsToSelector:NSSelectorFromString(@"orderedHTTPTransactions")] &&
        [recorder respondsToSelector:NSSelectorFromString(@"orderedWSTransactions")] &&
        [recorder respondsToSelector:NSSelectorFromString(@"orderedFirebaseTransactions")];

    id logController = loaded ? FUSafeClassObjectMessage(@"FLEXOSLogController", @"sharedLogController") : nil;
    BOOL osLogHistory = logController &&
        [logController respondsToSelector:NSSelectorFromString(@"persistent")] &&
        [logController respondsToSelector:NSSelectorFromString(@"setPersistent:")] &&
        [logController respondsToSelector:NSSelectorFromString(@"startMonitoring")] &&
        [logController respondsToSelector:NSSelectorFromString(@"messages")];

    BOOL globals = loaded && FUClassRespondsToClassSelector(@"FLEXGlobalsViewController", @"defaultGlobalSections");
    Class heapClass = loaded ? NSClassFromString(@"FLEXHeapEnumerator") : Nil;
    BOOL heap = heapClass && (
        [heapClass respondsToSelector:NSSelectorFromString(@"generateHeapSnapshot")] ||
        [heapClass respondsToSelector:NSSelectorFromString(@"enumerateLiveObjectsUsingBlock:")]
    );
    BOOL swiftMirror = reflex && FUClassRespondsToInstanceSelector(@"FLEXSwiftMirror", @"initWithSubject:");
    BOOL swiftMetadata = FUClassRespondsToClassSelector(@"FLEXSwiftMetadataInspector", @"inspectClass:limit:");

    NSDictionary *features = @{
        @"manager": @(manager),
        @"runtime_catalog": @(runtimeCatalog),
        @"runtime_method_search": @(runtimeMethodSearch),
        @"object_explorer": @(objectExplorer),
        @"heap": @(heap),
        @"bookmarks": @(bookmarks),
        @"network_history": @(networkHistory),
        @"os_log_history": @(osLogHistory),
        @"globals": @(globals),
        @"reflex": @(reflex),
        @"swift_mirror": @(swiftMirror),
        @"swift_metadata": @(swiftMetadata),
    };

    NSDictionary *operationSupport = FUOperationSupportForCurrentRuntime(loaded, swiftInspectionAvailable);
    NSMutableArray<NSString *> *supportedOperations = [NSMutableArray array];
    NSMutableArray<NSString *> *unsupportedOperations = [NSMutableArray array];
    for (NSString *operation in FUAgentCapabilities()) {
        NSDictionary *entry = operationSupport[operation];
        if ([entry[@"supported"] boolValue]) [supportedOperations addObject:operation];
        else [unsupportedOperations addObject:operation];
    }

    NSMutableDictionary *status = [@{
        @"available": @(loaded),
        @"loaded": @(loaded),
        @"was_loaded": @(wasLoaded),
        @"reflex": @(reflex),
        @"features": features,
        @"operation_support": operationSupport,
        @"supported_operations": supportedOperations,
        @"unsupported_operations": unsupportedOperations,
        @"feature_requirements": @{
            @"manager": @[@"FLEXManager.+sharedManager"],
            @"runtime_catalog": @[@"FLEXRuntimeClient.+runtime", @"FLEXSearchToken.+any", @"FLEXSearchToken.+string:options:", @"runtime.bundlePathsForToken:", @"runtime.classesForToken:inBundles:", @"runtime.imagePaths", @"runtime.imageDisplayNames", @"runtime.classNamesInImageAtPath:", @"runtime.copyProtocolList"],
            @"runtime_method_search": @[@"runtime.methodsForToken:instance:inClasses:"],
            @"object_explorer": @[@"FLEXObjectExplorer.+forObject:"],
            @"heap": @[@"FLEXHeapEnumerator.+generateHeapSnapshot|+enumerateLiveObjectsUsingBlock:"],
            @"bookmarks": @[@"FLEXBookmarkManager.+bookmarks"],
            @"network_history": @[@"FLEXNetworkRecorder.+defaultRecorder", @"recorder.orderedHTTPTransactions", @"recorder.orderedWSTransactions", @"recorder.orderedFirebaseTransactions"],
            @"os_log_history": @[@"FLEXOSLogController.+sharedLogController", @"controller.persistent", @"controller.setPersistent:", @"controller.startMonitoring", @"controller.messages"],
            @"globals": @[@"FLEXGlobalsViewController.+defaultGlobalSections"],
            @"reflex": @[@"FLEXObjectExplorer.+reflexAvailable"],
            @"swift_mirror": @[@"reflex", @"FLEXSwiftMirror.-initWithSubject:"],
            @"swift_metadata": @[@"FLEXSwiftMetadataInspector.+inspectClass:limit:"],
        },
    } mutableCopy];
    if (loadedPath) {
        status[@"loaded_path"] = loadedPath;
    }

    return status;
}

NSDictionary<NSString *, NSDictionary *> *FUOperationSupport(BOOL loadIfNeeded) {
    NSDictionary *status = FUFlexStatus(loadIfNeeded);
    NSDictionary *support = [status[@"operation_support"] isKindOfClass:[NSDictionary class]] ? status[@"operation_support"] : @{};
    return support;
}

id FUFlexManager(void) {
    FUFlexStatus(YES);
    Class managerClass = NSClassFromString(@"FLEXManager");
    SEL shared = NSSelectorFromString(@"sharedManager");
    if (!managerClass || ![managerClass respondsToSelector:shared]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(managerClass, shared);
}

NSDictionary *FUHandleFlexVisibility(NSString *requestID, BOOL show) {
    id manager = FUFlexManager();
    if (!manager) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEXManager is unavailable. Reinstall FlexUltra so its private FLEX runtime is present, then relaunch the target process."));
    }

    SEL selector = NSSelectorFromString(show ? @"showExplorer" : @"hideExplorer");
    if (![manager respondsToSelector:selector]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose the requested manager method."));
    }

    void (^action)(void) = ^{
        ((void (*)(id, SEL))objc_msgSend)(manager, selector);
    };
    if (NSThread.isMainThread) {
        action();
    } else {
        dispatch_sync(dispatch_get_main_queue(), action);
    }

    return FUResponse(requestID, YES, @{ @"visible": @(show) }, nil);
}

NSDictionary *FURuntimeClasses(NSString *requestID, NSDictionary *request) {
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for runtime class search."));
    }

    Class runtimeClass = NSClassFromString(@"FLEXRuntimeClient");
    Class tokenClass = NSClassFromString(@"FLEXSearchToken");
    if (!runtimeClass || !tokenClass) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEXRuntimeClient or FLEXSearchToken is unavailable in the loaded FLEX build."));
    }

    SEL runtimeSEL = NSSelectorFromString(@"runtime");
    id runtime = ((id (*)(id, SEL))objc_msgSend)(runtimeClass, runtimeSEL);
    id anyToken = ((id (*)(id, SEL))objc_msgSend)(tokenClass, NSSelectorFromString(@"any"));

    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    id classToken = anyToken;
    if (query.length > 0) {
        // FLEXSearchToken wildcard prefix | suffix = 2 | 4.
        classToken = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(
            tokenClass,
            NSSelectorFromString(@"string:options:"),
            query,
            (NSUInteger)6
        );
    }

    NSMutableArray *bundlePaths = ((id (*)(id, SEL, id))objc_msgSend)(
        runtime,
        NSSelectorFromString(@"bundlePathsForToken:"),
        anyToken
    );
    NSArray<NSString *> *classes = ((id (*)(id, SEL, id, id))objc_msgSend)(
        runtime,
        NSSelectorFromString(@"classesForToken:inBundles:"),
        classToken,
        bundlePaths
    );

    NSUInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"limit"] unsignedIntegerValue] : 100;
    NSUInteger limit = MIN(MAX(requestedLimit, (NSUInteger)1), (NSUInteger)500);
    NSUInteger count = MIN(classes.count, limit);
    NSArray *page = count == 0 ? @[] : [classes subarrayWithRange:NSMakeRange(0, count)];

    return FUResponse(requestID, YES, @{
        @"source": @"FLEXRuntimeClient",
        @"query": query,
        @"classes": page,
        @"total": @(classes.count),
        @"truncated": @(classes.count > count),
    }, nil);
}

NSDictionary *FURuntimeClass(NSString *requestID, NSDictionary *request) {
    NSString *name = [request[@"name"] isKindOfClass:[NSString class]] ? request[@"name"] : @"";
    if (name.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_class_name", @"runtime.class requires an exact Objective-C class name."));
    }

    // Load FLEX before registering the class so the returned handle can be
    // passed directly into the FLEX-backed object inspection surface.
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for runtime class resolution."));
    }

    Class cls = NSClassFromString(name);
    if (!cls) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"class_not_found", [NSString stringWithFormat:@"Objective-C class '%@' is not loaded in the target process.", name]));
    }

    NSMutableDictionary *result = [@{
        @"source": @"ObjectiveCRuntime",
        @"name": NSStringFromClass(cls) ?: name,
        @"class_object": FURuntimeObjectReference(cls),
        @"instance_size": @(class_getInstanceSize(cls)),
    } mutableCopy];

    Class superclass = class_getSuperclass(cls);
    if (superclass) {
        result[@"superclass"] = NSStringFromClass(superclass) ?: @"";
    } else {
        result[@"superclass"] = NSNull.null;
    }

    const char *imageName = class_getImageName(cls);
    if (imageName) {
        result[@"image"] = [NSString stringWithUTF8String:imageName] ?: @"";
    }

    NSBundle *bundle = [NSBundle bundleForClass:cls];
    if (bundle) {
        result[@"bundle"] = @{
            @"identifier": bundle.bundleIdentifier ?: NSNull.null,
            @"path": bundle.bundlePath ?: @"",
        };
    }

    return FUResponse(requestID, YES, result, nil);
}

NSDictionary *FURuntimeClassProtocols(NSString *requestID, NSDictionary *request) {
    NSString *className = [request[@"class_name"] isKindOfClass:[NSString class]] ? request[@"class_name"] : @"";
    if (className.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_class_name", @"runtime.class_protocols requires an exact loaded Objective-C class name."));
    }

    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for runtime class/protocol browsing."));
    }

    Class cls = NSClassFromString(className);
    if (!cls) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"class_not_found", [NSString stringWithFormat:@"Objective-C class '%@' is not loaded in the target process.", className]));
    }

    NSUInteger offset = 0, limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    BOOL includeInherited = request[@"include_inherited"] ? [request[@"include_inherited"] boolValue] : YES;
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    NSMutableArray<NSString *> *hierarchy = [NSMutableArray array];

    Class current = cls;
    while (current) {
        NSString *declaringClass = NSStringFromClass(current) ?: @"";
        [hierarchy addObject:declaringClass];

        unsigned int protocolCount = 0;
        Protocol *__unsafe_unretained *protocols = class_copyProtocolList(current, &protocolCount);
        for (unsigned int index = 0; index < protocolCount; index++) {
            const char *nameCString = protocol_getName(protocols[index]);
            if (!nameCString) continue;
            NSString *protocolName = [NSString stringWithUTF8String:nameCString] ?: @"";
            if (query.length > 0 && [protocolName rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            [matches addObject:@{
                @"name": protocolName,
                @"declaring_class": declaringClass,
                @"inherited": @((BOOL)(current != cls)),
            }];
        }
        free(protocols);

        if (!includeInherited) break;
        current = class_getSuperclass(current);
    }

    [matches sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult nameResult = [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
        if (nameResult != NSOrderedSame) return nameResult;
        return [left[@"declaring_class"] localizedCaseInsensitiveCompare:right[@"declaring_class"]];
    }];

    NSUInteger start = MIN(offset, matches.count);
    NSUInteger end = MIN(start + limit, matches.count);
    NSArray *page = end > start ? [matches subarrayWithRange:NSMakeRange(start, end - start)] : @[];
    return FUResponse(requestID, YES, @{
        @"source": @"FLEX+ObjectiveCRuntime",
        @"class_name": NSStringFromClass(cls) ?: className,
        @"query": query,
        @"include_inherited": @(includeInherited),
        @"hierarchy": hierarchy,
        @"protocols": page,
        @"total": @(matches.count),
        @"offset": @(offset),
        @"limit": @(limit),
        @"has_more": @(end < matches.count),
    }, nil);
}

id FURuntimeClientInstance(NSString *requestID, NSDictionary **errorResponse) {
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        if (errorResponse) {
            *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for runtime browsing."));
        }
        return nil;
    }

    Class runtimeClass = NSClassFromString(@"FLEXRuntimeClient");
    SEL runtimeSEL = NSSelectorFromString(@"runtime");
    if (!runtimeClass || ![runtimeClass respondsToSelector:runtimeSEL]) {
        if (errorResponse) {
            *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEXRuntimeClient +runtime is unavailable in the loaded FLEX build."));
        }
        return nil;
    }

    id runtime = ((id (*)(id, SEL))objc_msgSend)(runtimeClass, runtimeSEL);
    if (!runtime && errorResponse) {
        *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEXRuntimeClient returned no runtime instance."));
    }
    return runtime;
}

NSDictionary *FURuntimeMethods(NSString *requestID, NSDictionary *request) {
    if (!FURuntimeMethodEntryProviderCallback) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"internal_configuration", @"Runtime method metadata provider is not configured."));
    }

    NSString *requestedClass = [request[@"class_name"] isKindOfClass:[NSString class]] ? request[@"class_name"] : @"";
    if (requestedClass.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_class_name", @"runtime.methods requires an exact loaded Objective-C class_name."));
    }

    Class cls = NSClassFromString(requestedClass);
    if (!cls) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"class_not_found", [NSString stringWithFormat:@"Objective-C class '%@' is not loaded in the target process.", requestedClass]));
    }
    NSString *className = NSStringFromClass(cls) ?: requestedClass;

    NSString *methodKind = [request[@"method_kind"] isKindOfClass:[NSString class]] ? request[@"method_kind"] : @"any";
    if (![@[@"any", @"instance", @"class"] containsObject:methodKind]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_method_kind", @"method_kind must be any, instance, or class."));
    }

    NSUInteger offset = 0, limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    NSDictionary *runtimeError = nil;
    id runtime = FURuntimeClientInstance(requestID, &runtimeError);
    if (!runtime) return runtimeError;

    SEL methodsSEL = NSSelectorFromString(@"methodsForToken:instance:inClasses:");
    Class tokenClass = NSClassFromString(@"FLEXSearchToken");
    SEL anySEL = NSSelectorFromString(@"any");
    SEL stringSEL = NSSelectorFromString(@"string:options:");
    if (!tokenClass || ![runtime respondsToSelector:methodsSEL] ||
        ![tokenClass respondsToSelector:anySEL] || ![tokenClass respondsToSelector:stringSEL]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose runtime method search."));
    }

    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    id token = nil;
    id onlyInstance = nil;
    if (query.length) {
        token = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(tokenClass, stringSEL, query, (NSUInteger)6);
    } else if ([methodKind isEqualToString:@"any"]) {
        token = ((id (*)(id, SEL))objc_msgSend)(tokenClass, anySEL);
    } else {
        token = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(tokenClass, stringSEL, @"", (NSUInteger)4);
        onlyInstance = @([methodKind isEqualToString:@"instance"]);
    }

    id groupedValue = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        runtime,
        methodsSEL,
        token,
        onlyInstance,
        @[className]
    );
    if (![groupedValue isKindOfClass:[NSArray class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEX returned an unexpected runtime method result."));
    }

    NSMutableArray *page = [NSMutableArray arrayWithCapacity:limit];
    NSUInteger total = 0;
    for (id group in (NSArray *)groupedValue) {
        if (![group isKindOfClass:[NSArray class]]) continue;
        for (id method in (NSArray *)group) {
            BOOL isInstance = FURuntimeBoolMessage(method, @"isInstanceMethod", YES);
            if ([methodKind isEqualToString:@"instance"] && !isInstance) continue;
            if ([methodKind isEqualToString:@"class"] && isInstance) continue;

            NSUInteger index = total++;
            if (index < offset || page.count >= limit) continue;

            NSMutableDictionary *entry = FURuntimeMethodEntryProviderCallback(method, className);
            if (![entry isKindOfClass:[NSMutableDictionary class]]) entry = [entry mutableCopy] ?: [NSMutableDictionary dictionary];
            entry[@"method_kind"] = isInstance ? @"instance" : @"class";
            NSString *imagePath = FURuntimeObjectMessage(method, @"imagePath");
            if (imagePath.length) entry[@"image_path"] = imagePath;
            [page addObject:entry];
        }
    }

    BOOL hasMore = offset < total && page.count < (total - offset);
    return FUResponse(requestID, YES, @{
        @"source": @"FLEXRuntimeClient",
        @"query": query,
        @"class_name": className,
        @"method_kind": methodKind,
        @"methods": page,
        @"total": @(total),
        @"offset": @(offset),
        @"limit": @(limit),
        @"has_more": @(hasMore),
    }, nil);
}

NSDictionary *FURuntimeProperties(NSString *requestID, NSDictionary *request) {
    if (!FURuntimePropertyEntryProviderCallback) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"internal_configuration", @"Runtime property metadata provider is not configured."));
    }

    NSString *requestedClass = [request[@"class_name"] isKindOfClass:[NSString class]] ? request[@"class_name"] : @"";
    if (requestedClass.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_class_name", @"runtime.properties requires an exact loaded Objective-C class_name."));
    }
    Class cls = NSClassFromString(requestedClass);
    if (!cls) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"class_not_found", [NSString stringWithFormat:@"Objective-C class '%@' is not loaded in the target process.", requestedClass]));
    }
    NSString *className = NSStringFromClass(cls) ?: requestedClass;

    NSString *propertyKind = [request[@"property_kind"] isKindOfClass:[NSString class]] ? request[@"property_kind"] : @"any";
    if (![@[@"any", @"instance", @"class"] containsObject:propertyKind]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_property_kind", @"property_kind must be any, instance, or class."));
    }
    NSUInteger offset = 0, limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }
    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";

    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for runtime property inspection."));
    }

    id explorer = FURuntimeObjectExplorerForObject(cls);
    if (!explorer) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXObjectExplorer class metadata."));
    }

    NSMutableArray *matching = [NSMutableArray array];
    NSArray *classes = FURuntimeObjectMessage(explorer, @"classHierarchyClasses");
    NSArray<NSDictionary *> *sources = @[
        @{ @"selector": @"allProperties", @"kind": @"instance" },
        @{ @"selector": @"allClassProperties", @"kind": @"class" },
    ];
    for (NSDictionary *source in sources) {
        NSString *kind = source[@"kind"];
        if (![propertyKind isEqualToString:@"any"] && ![propertyKind isEqualToString:kind]) continue;
        NSArray *groups = FURuntimeObjectMessage(explorer, source[@"selector"]);
        if (![groups isKindOfClass:[NSArray class]]) {
            if ([kind isEqualToString:@"class"]) continue;
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEXObjectExplorer returned unexpected property metadata."));
        }
        for (NSUInteger scope = 0; scope < groups.count; scope++) {
            NSArray *items = [groups[scope] isKindOfClass:[NSArray class]] ? groups[scope] : @[];
            NSString *declaringClass = scope < classes.count ? FURuntimeClassName(classes[scope]) : @"";
            for (id property in items) {
                if (!FURuntimeMemberMatchesQuery(property, declaringClass, query, NO)) continue;
                [matching addObject:@{ @"property": property, @"declaring_class": declaringClass, @"kind": kind }];
            }
        }
    }

    NSUInteger total = matching.count;
    NSMutableArray *page = [NSMutableArray arrayWithCapacity:MIN(limit, total)];
    for (NSUInteger index = offset; index < total && page.count < limit; index++) {
        NSDictionary *item = matching[index];
        NSMutableDictionary *entry = FURuntimePropertyEntryProviderCallback(item[@"property"], cls, item[@"declaring_class"], NO);
        if (![entry isKindOfClass:[NSMutableDictionary class]]) entry = [entry mutableCopy] ?: [NSMutableDictionary dictionary];
        entry[@"property_kind"] = item[@"kind"];
        [page addObject:entry];
    }
    BOOL hasMore = offset < total && page.count < (total - offset);
    return FUResponse(requestID, YES, @{
        @"source": @"FLEXObjectExplorer",
        @"query": query,
        @"class_name": className,
        @"property_kind": propertyKind,
        @"properties": page,
        @"total": @(total),
        @"offset": @(offset),
        @"limit": @(limit),
        @"has_more": @(hasMore),
    }, nil);
}

NSDictionary *FURuntimeIvars(NSString *requestID, NSDictionary *request) {
    if (!FURuntimeIvarEntryProviderCallback) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"internal_configuration", @"Runtime ivar metadata provider is not configured."));
    }

    NSString *requestedClass = [request[@"class_name"] isKindOfClass:[NSString class]] ? request[@"class_name"] : @"";
    if (requestedClass.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_class_name", @"runtime.ivars requires an exact loaded Objective-C class_name."));
    }
    Class cls = NSClassFromString(requestedClass);
    if (!cls) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"class_not_found", [NSString stringWithFormat:@"Objective-C class '%@' is not loaded in the target process.", requestedClass]));
    }
    NSString *className = NSStringFromClass(cls) ?: requestedClass;
    NSUInteger offset = 0, limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }
    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for runtime ivar inspection."));
    }
    id explorer = FURuntimeObjectExplorerForObject(cls);
    if (!explorer) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXObjectExplorer class metadata."));
    }

    NSArray *groups = FURuntimeObjectMessage(explorer, @"allIvars");
    NSArray *classes = FURuntimeObjectMessage(explorer, @"classHierarchyClasses");
    if (![groups isKindOfClass:[NSArray class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEXObjectExplorer returned unexpected ivar metadata."));
    }

    NSMutableArray *ivars = [NSMutableArray arrayWithCapacity:limit];
    NSUInteger total = 0;
    for (NSUInteger scope = 0; scope < groups.count; scope++) {
        NSArray *items = [groups[scope] isKindOfClass:[NSArray class]] ? groups[scope] : @[];
        NSString *declaringClass = scope < classes.count ? FURuntimeClassName(classes[scope]) : @"";
        for (id ivar in items) {
            if (!FURuntimeMemberMatchesQuery(ivar, declaringClass, query, NO)) continue;
            NSUInteger index = total++;
            if (index < offset || ivars.count >= limit) continue;
            NSMutableDictionary *entry = FURuntimeIvarEntryProviderCallback(ivar, cls, declaringClass, NO);
            [ivars addObject:entry ?: @{}];
        }
    }

    BOOL hasMore = offset < total && ivars.count < (total - offset);
    return FUResponse(requestID, YES, @{
        @"source": @"FLEXObjectExplorer",
        @"query": query,
        @"class_name": className,
        @"ivars": ivars,
        @"total": @(total),
        @"offset": @(offset),
        @"limit": @(limit),
        @"has_more": @(hasMore),
    }, nil);
}

static BOOL FURuntimeImageCatalog(id runtime, NSArray **pathsOut, NSArray **namesOut) {
    SEL pathsSEL = NSSelectorFromString(@"imagePaths");
    SEL namesSEL = NSSelectorFromString(@"imageDisplayNames");
    if (![runtime respondsToSelector:pathsSEL] || ![runtime respondsToSelector:namesSEL]) {
        return NO;
    }

    id paths = ((id (*)(id, SEL))objc_msgSend)(runtime, pathsSEL);
    id names = ((id (*)(id, SEL))objc_msgSend)(runtime, namesSEL);
    if (![paths isKindOfClass:[NSArray class]] || ![names isKindOfClass:[NSArray class]]) {
        return NO;
    }

    if (pathsOut) *pathsOut = paths;
    if (namesOut) *namesOut = names;
    return YES;
}

NSDictionary *FURuntimeImages(NSString *requestID, NSDictionary *request) {
    NSDictionary *runtimeError = nil;
    id runtime = FURuntimeClientInstance(requestID, &runtimeError);
    if (!runtime) return runtimeError;

    NSArray *paths = nil;
    NSArray *displayNames = nil;
    if (!FURuntimeImageCatalog(runtime, &paths, &displayNames)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose imagePaths/imageDisplayNames."));
    }

    NSUInteger offset = 0, limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    NSMutableArray *matches = [NSMutableArray array];
    for (NSUInteger index = 0; index < paths.count; index++) {
        NSString *path = [paths[index] isKindOfClass:[NSString class]] ? paths[index] : [paths[index] description];
        NSString *name = index < displayNames.count && [displayNames[index] isKindOfClass:[NSString class]]
            ? displayNames[index]
            : path.lastPathComponent;
        if (query.length > 0 &&
            [name rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [path rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) {
            continue;
        }
        [matches addObject:@{ @"index": @(index), @"name": name ?: @"", @"path": path ?: @"" }];
    }

    NSUInteger start = MIN(offset, matches.count);
    NSUInteger end = MIN(start + limit, matches.count);
    NSArray *page = end > start ? [matches subarrayWithRange:NSMakeRange(start, end - start)] : @[];
    return FUResponse(requestID, YES, @{
        @"source": @"FLEXRuntimeClient",
        @"query": query,
        @"images": page,
        @"loaded_total": @(paths.count),
        @"total": @(matches.count),
        @"offset": @(offset),
        @"limit": @(limit),
        @"has_more": @(end < matches.count),
    }, nil);
}

NSDictionary *FURuntimeImageClasses(NSString *requestID, NSDictionary *request) {
    NSString *image = [request[@"image"] isKindOfClass:[NSString class]] ? request[@"image"] : @"";
    if (image.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_image", @"runtime.image_classes requires an image display name or exact image path."));
    }

    NSDictionary *runtimeError = nil;
    id runtime = FURuntimeClientInstance(requestID, &runtimeError);
    if (!runtime) return runtimeError;

    NSArray *paths = nil;
    NSArray *displayNames = nil;
    if (!FURuntimeImageCatalog(runtime, &paths, &displayNames)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose imagePaths/imageDisplayNames."));
    }

    NSInteger exactPathIndex = NSNotFound;
    NSMutableArray<NSNumber *> *nameMatches = [NSMutableArray array];
    for (NSUInteger index = 0; index < paths.count; index++) {
        NSString *path = [paths[index] isKindOfClass:[NSString class]] ? paths[index] : [paths[index] description];
        NSString *name = index < displayNames.count && [displayNames[index] isKindOfClass:[NSString class]]
            ? displayNames[index]
            : path.lastPathComponent;
        if ([path isEqualToString:image]) {
            exactPathIndex = (NSInteger)index;
            break;
        }
        if ([name compare:image options:NSCaseInsensitiveSearch] == NSOrderedSame) {
            [nameMatches addObject:@(index)];
        }
    }

    NSUInteger imageIndex = NSNotFound;
    if (exactPathIndex != NSNotFound) {
        imageIndex = (NSUInteger)exactPathIndex;
    } else if (nameMatches.count == 1) {
        imageIndex = nameMatches.firstObject.unsignedIntegerValue;
    } else if (nameMatches.count > 1) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"ambiguous_image", @"Multiple loaded images share that display name. Use the exact path returned by runtime.images."));
    } else {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"image_not_found", [NSString stringWithFormat:@"No loaded image matches '%@'.", image]));
    }

    SEL classesSEL = NSSelectorFromString(@"classNamesInImageAtPath:");
    if (![runtime respondsToSelector:classesSEL]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose classNamesInImageAtPath:."));
    }

    NSString *path = [paths[imageIndex] isKindOfClass:[NSString class]] ? paths[imageIndex] : [paths[imageIndex] description];
    NSString *name = imageIndex < displayNames.count && [displayNames[imageIndex] isKindOfClass:[NSString class]]
        ? displayNames[imageIndex]
        : path.lastPathComponent;
    id classNamesValue = ((id (*)(id, SEL, id))objc_msgSend)(runtime, classesSEL, path);
    if (![classNamesValue isKindOfClass:[NSArray class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEX returned an unexpected class list for the selected image."));
    }

    NSUInteger offset = 0, limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    for (id value in (NSArray *)classNamesValue) {
        NSString *className = [value isKindOfClass:[NSString class]] ? value : [value description];
        if (query.length > 0 && [className rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [matches addObject:className ?: @""];
    }
    [matches sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    NSUInteger start = MIN(offset, matches.count);
    NSUInteger end = MIN(start + limit, matches.count);
    NSArray *page = end > start ? [matches subarrayWithRange:NSMakeRange(start, end - start)] : @[];
    return FUResponse(requestID, YES, @{
        @"source": @"FLEXRuntimeClient",
        @"image": @{ @"index": @(imageIndex), @"name": name ?: @"", @"path": path ?: @"" },
        @"query": query,
        @"classes": page,
        @"loaded_total": @([(NSArray *)classNamesValue count]),
        @"total": @(matches.count),
        @"offset": @(offset),
        @"limit": @(limit),
        @"has_more": @(end < matches.count),
    }, nil);
}

NSDictionary *FURuntimeProtocols(NSString *requestID, NSDictionary *request) {
    NSDictionary *runtimeError = nil;
    id runtime = FURuntimeClientInstance(requestID, &runtimeError);
    if (!runtime) return runtimeError;

    SEL protocolsSEL = NSSelectorFromString(@"copyProtocolList");
    if (![runtime respondsToSelector:protocolsSEL]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose copyProtocolList."));
    }

    id protocolsValue = ((id (*)(id, SEL))objc_msgSend)(runtime, protocolsSEL);
    if (![protocolsValue isKindOfClass:[NSArray class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEX returned an unexpected protocol list."));
    }

    NSUInteger offset = 0, limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    for (id value in (NSArray *)protocolsValue) {
        Protocol *protocol = (Protocol *)value;
        const char *nameCString = protocol_getName(protocol);
        if (!nameCString) continue;
        NSString *name = [NSString stringWithUTF8String:nameCString];
        if (query.length > 0 && [name rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [matches addObject:name];
    }
    [matches sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    NSUInteger start = MIN(offset, matches.count);
    NSUInteger end = MIN(start + limit, matches.count);
    NSArray *page = end > start ? [matches subarrayWithRange:NSMakeRange(start, end - start)] : @[];
    return FUResponse(requestID, YES, @{
        @"source": @"FLEXRuntimeClient",
        @"query": query,
        @"protocols": page,
        @"loaded_total": @([(NSArray *)protocolsValue count]),
        @"total": @(matches.count),
        @"offset": @(offset),
        @"limit": @(limit),
        @"has_more": @(end < matches.count),
    }, nil);
}

NSDictionary *FURuntimeProtocolClasses(NSString *requestID, NSDictionary *request) {
    NSString *requestedName = [request[@"name"] isKindOfClass:[NSString class]] ? request[@"name"] : @"";
    if (requestedName.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_protocol_name", @"runtime.protocol_classes requires an exact loaded Objective-C protocol name."));
    }

    NSUInteger offset = 0, limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    NSDictionary *runtimeError = nil;
    id runtime = FURuntimeClientInstance(requestID, &runtimeError);
    if (!runtime) return runtimeError;

    SEL protocolsSEL = NSSelectorFromString(@"copyProtocolList");
    if (![runtime respondsToSelector:protocolsSEL]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose copyProtocolList."));
    }
    id protocolsValue = ((id (*)(id, SEL))objc_msgSend)(runtime, protocolsSEL);
    if (![protocolsValue isKindOfClass:[NSArray class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEX returned an unexpected protocol list."));
    }

    Protocol *selected = nil;
    for (id value in (NSArray *)protocolsValue) {
        Protocol *candidate = (Protocol *)value;
        const char *candidateName = protocol_getName(candidate);
        if (candidateName && [requestedName isEqualToString:[NSString stringWithUTF8String:candidateName]]) {
            selected = candidate;
            break;
        }
    }
    if (!selected) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"protocol_not_found", [NSString stringWithFormat:@"Objective-C protocol '%@' is not present in FLEX's loaded runtime catalog.", requestedName]));
    }

    int classCount = objc_getClassList(NULL, 0);
    if (classCount < 0) classCount = 0;
    Class __unsafe_unretained *classes = classCount > 0 ? (Class __unsafe_unretained *)calloc((size_t)classCount, sizeof(Class)) : NULL;
    int loadedCount = classes ? objc_getClassList(classes, classCount) : 0;
    if (loadedCount < 0) loadedCount = 0;
    if (loadedCount > classCount) loadedCount = classCount;

    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (int index = 0; index < loadedCount; index++) {
        Class cls = classes[index];
        if (!cls || !class_conformsToProtocol(cls, selected)) continue;

        NSString *className = NSStringFromClass(cls) ?: @"";
        if (query.length > 0 && [className rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;

        Class superclass = class_getSuperclass(cls);
        const char *imageName = class_getImageName(cls);
        [matches addObject:@{
            @"name": className,
            @"superclass": superclass ? (NSStringFromClass(superclass) ?: @"") : NSNull.null,
            @"image": imageName ? ([NSString stringWithUTF8String:imageName] ?: @"") : NSNull.null,
        }];
    }
    free(classes);

    [matches sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];

    NSUInteger start = MIN(offset, matches.count);
    NSUInteger end = MIN(start + limit, matches.count);
    NSArray *page = end > start ? [matches subarrayWithRange:NSMakeRange(start, end - start)] : @[];
    return FUResponse(requestID, YES, @{
        @"source": @"FLEXRuntimeClient+ObjectiveCRuntime",
        @"name": requestedName,
        @"query": query,
        @"classes": page,
        @"loaded_total": @(loadedCount),
        @"total": @(matches.count),
        @"offset": @(offset),
        @"limit": @(limit),
        @"has_more": @(end < matches.count),
    }, nil);
}

static NSDictionary *FUProtocolMethodEntry(struct objc_method_description description, BOOL required, BOOL instance) {
    NSString *name = description.name ? NSStringFromSelector(description.name) : @"";
    NSString *typeEncoding = description.types ? [NSString stringWithUTF8String:description.types] : @"";
    NSMutableDictionary *entry = [@{
        @"name": name ?: @"",
        @"type_encoding": typeEncoding ?: @"",
        @"requirement": required ? @"required" : @"optional",
        @"method_kind": instance ? @"instance" : @"class",
    } mutableCopy];

    if (description.types) {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:description.types];
        if (signature) {
            NSUInteger count = signature.numberOfArguments;
            entry[@"arguments"] = @(count >= 2 ? count - 2 : 0);
            const char *returnType = signature.methodReturnType;
            if (returnType) entry[@"return_type"] = [NSString stringWithUTF8String:returnType] ?: @"";
            NSMutableArray *argumentTypes = [NSMutableArray array];
            for (NSUInteger index = 2; index < count; index++) {
                const char *argumentType = [signature getArgumentTypeAtIndex:index];
                [argumentTypes addObject:argumentType ? ([NSString stringWithUTF8String:argumentType] ?: @"") : @""];
            }
            entry[@"argument_types"] = argumentTypes;
        }
    }
    return entry;
}

NSDictionary *FURuntimeProtocol(NSString *requestID, NSDictionary *request) {
    NSString *requestedName = [request[@"name"] isKindOfClass:[NSString class]] ? request[@"name"] : @"";
    if (requestedName.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_protocol_name", @"runtime.protocol requires an exact loaded Objective-C protocol name."));
    }

    NSString *methodKind = [request[@"method_kind"] isKindOfClass:[NSString class]] ? request[@"method_kind"] : @"any";
    if (![@[@"any", @"instance", @"class"] containsObject:methodKind]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_method_kind", @"method_kind must be any, instance, or class."));
    }
    NSString *requirement = [request[@"requirement"] isKindOfClass:[NSString class]] ? request[@"requirement"] : @"any";
    if (![@[@"any", @"required", @"optional"] containsObject:requirement]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_requirement", @"requirement must be any, required, or optional."));
    }

    NSUInteger offset = 0, limit = 100;
    if (!FURequestPagination(request, &offset, &limit)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_pagination", @"offset must be >= 0 and limit must be > 0."));
    }

    NSDictionary *runtimeError = nil;
    id runtime = FURuntimeClientInstance(requestID, &runtimeError);
    if (!runtime) return runtimeError;
    SEL protocolsSEL = NSSelectorFromString(@"copyProtocolList");
    if (![runtime respondsToSelector:protocolsSEL]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose copyProtocolList."));
    }
    id protocolsValue = ((id (*)(id, SEL))objc_msgSend)(runtime, protocolsSEL);
    if (![protocolsValue isKindOfClass:[NSArray class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"FLEX returned an unexpected protocol list."));
    }

    Protocol *selected = nil;
    for (id value in (NSArray *)protocolsValue) {
        Protocol *candidate = (Protocol *)value;
        const char *candidateName = protocol_getName(candidate);
        if (candidateName && [requestedName isEqualToString:[NSString stringWithUTF8String:candidateName]]) {
            selected = candidate;
            break;
        }
    }
    if (!selected) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"protocol_not_found", [NSString stringWithFormat:@"Objective-C protocol '%@' is not present in FLEX's loaded runtime catalog.", requestedName]));
    }

    NSMutableArray<NSString *> *adoptedProtocols = [NSMutableArray array];
    unsigned int adoptedCount = 0;
    Protocol *__unsafe_unretained *adopted = protocol_copyProtocolList(selected, &adoptedCount);
    for (unsigned int index = 0; index < adoptedCount; index++) {
        const char *nameCString = protocol_getName(adopted[index]);
        if (nameCString) [adoptedProtocols addObject:[NSString stringWithUTF8String:nameCString]];
    }
    free(adopted);
    [adoptedProtocols sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (NSNumber *requiredNumber in @[@YES, @NO]) {
        BOOL required = requiredNumber.boolValue;
        if ([requirement isEqualToString:@"required"] && !required) continue;
        if ([requirement isEqualToString:@"optional"] && required) continue;
        for (NSNumber *instanceNumber in @[@YES, @NO]) {
            BOOL instance = instanceNumber.boolValue;
            if ([methodKind isEqualToString:@"instance"] && !instance) continue;
            if ([methodKind isEqualToString:@"class"] && instance) continue;

            unsigned int methodCount = 0;
            struct objc_method_description *descriptions = protocol_copyMethodDescriptionList(selected, required, instance, &methodCount);
            for (unsigned int index = 0; index < methodCount; index++) {
                NSDictionary *entry = FUProtocolMethodEntry(descriptions[index], required, instance);
                if (query.length &&
                    [entry[@"name"] rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound &&
                    [entry[@"type_encoding"] rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) {
                    continue;
                }
                [matches addObject:entry];
            }
            free(descriptions);
        }
    }
    [matches sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult nameResult = [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
        if (nameResult != NSOrderedSame) return nameResult;
        NSComparisonResult kindResult = [left[@"method_kind"] compare:right[@"method_kind"]];
        if (kindResult != NSOrderedSame) return kindResult;
        return [left[@"requirement"] compare:right[@"requirement"]];
    }];

    NSUInteger start = MIN(offset, matches.count);
    NSUInteger end = MIN(start + limit, matches.count);
    NSArray *page = end > start ? [matches subarrayWithRange:NSMakeRange(start, end - start)] : @[];
    return FUResponse(requestID, YES, @{
        @"source": @"FLEXRuntimeClient+ObjectiveCRuntime",
        @"name": requestedName,
        @"adopted_protocols": adoptedProtocols,
        @"query": query,
        @"method_kind": methodKind,
        @"requirement": requirement,
        @"methods": page,
        @"total": @(matches.count),
        @"offset": @(offset),
        @"limit": @(limit),
        @"has_more": @(end < matches.count),
    }, nil);
}
