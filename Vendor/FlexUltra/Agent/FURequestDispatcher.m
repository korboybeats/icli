#import "FURequestDispatcher.h"

#import "FUProtocol.h"
#import "FUDefaults.h"
#import "FUExperiments.h"
#import "FUFlexTools.h"
#import "FUHeap.h"
#import "FUInvestigation.h"
#import "FUKeychain.h"
#import "FUObjectInspection.h"
#import "FUObjectRegistry.h"
#import "FURuntime.h"
#import "FUStorage.h"
#import "FUSwiftInspection.h"
#import "FUTrace.h"
#import "FUUI.h"

#import <unistd.h>

NSDictionary *FUDispatchRequest(NSDictionary *request,
                                NSString *agentBuildID,
                                FURequestTargetHealthProvider targetHealthProvider) {
    NSString *requestID = [request[@"id"] isKindOfClass:[NSString class]] ? request[@"id"] : @"";
    NSString *op = [request[@"op"] isKindOfClass:[NSString class]] ? request[@"op"] : @"";
    NSString *buildID = agentBuildID.length ? agentBuildID : @"unknown";

    if ([op isEqualToString:@"ping"]) {
        return FUResponse(requestID, YES, @{
            @"pid": @(getpid()),
            @"bundle_id": NSBundle.mainBundle.bundleIdentifier ?: [NSNull null],
            @"process": NSProcessInfo.processInfo.processName ?: @"",
            @"generation": FUCurrentObjectGeneration(),
            @"agent_build": buildID,
        }, nil);
    }
    if ([op isEqualToString:@"agent.info"]) {
        return FUResponse(requestID, YES, @{
            @"pid": @(getpid()),
            @"bundle_id": NSBundle.mainBundle.bundleIdentifier ?: [NSNull null],
            @"process": NSProcessInfo.processInfo.processName ?: @"",
            @"generation": FUCurrentObjectGeneration(),
            @"agent_build": buildID,
            @"flex": FUFlexStatus(NO),
        }, nil);
    }
    if ([op isEqualToString:@"target.health"]) {
        if (targetHealthProvider) {
            return targetHealthProvider(requestID);
        }
        return FUResponse(requestID,
                          NO,
                          nil,
                          FUErrorInfo(@"target_health_unavailable", @"Target health provider is unavailable."));
    }
    if ([op isEqualToString:@"flex.status"]) {
        return FUResponse(requestID, YES, FUFlexStatus(YES), nil);
    }
    if ([op isEqualToString:@"flex.show"]) {
        return FUHandleFlexVisibility(requestID, YES);
    }
    if ([op isEqualToString:@"flex.hide"]) {
        return FUHandleFlexVisibility(requestID, NO);
    }
    if ([op isEqualToString:@"experiment.begin"]) {
        return FUHandleExperimentBegin(requestID);
    }
    if ([op isEqualToString:@"experiment.status"]) {
        return FUHandleExperimentStatus(requestID);
    }
    if ([op isEqualToString:@"experiment.rollback"]) {
        return FUHandleExperimentRollback(requestID);
    }
    if ([op isEqualToString:@"experiment.commit"]) {
        return FUHandleExperimentCommit(requestID);
    }
    if ([op isEqualToString:@"trace.start"]) {
        return FUHandleTraceStart(requestID, request);
    }
    if ([op isEqualToString:@"trace.status"]) {
        return FUHandleTraceStatus(requestID);
    }
    if ([op isEqualToString:@"trace.events"]) {
        return FUHandleTraceEvents(requestID, request);
    }
    if ([op isEqualToString:@"trace.stop"]) {
        return FUHandleTraceStop(requestID);
    }
    if ([op isEqualToString:@"runtime.classes"]) {
        return FURuntimeClasses(requestID, request);
    }
    if ([op isEqualToString:@"runtime.class"]) {
        return FURuntimeClass(requestID, request);
    }
    if ([op isEqualToString:@"runtime.class_protocols"]) {
        return FURuntimeClassProtocols(requestID, request);
    }
    if ([op isEqualToString:@"runtime.images"]) {
        return FURuntimeImages(requestID, request);
    }
    if ([op isEqualToString:@"runtime.image_classes"]) {
        return FURuntimeImageClasses(requestID, request);
    }
    if ([op isEqualToString:@"runtime.protocols"]) {
        return FURuntimeProtocols(requestID, request);
    }
    if ([op isEqualToString:@"runtime.protocol"]) {
        return FURuntimeProtocol(requestID, request);
    }
    if ([op isEqualToString:@"runtime.protocol_classes"]) {
        return FURuntimeProtocolClasses(requestID, request);
    }
    if ([op isEqualToString:@"runtime.methods"]) {
        return FURuntimeMethods(requestID, request);
    }
    if ([op isEqualToString:@"runtime.properties"]) {
        return FURuntimeProperties(requestID, request);
    }
    if ([op isEqualToString:@"runtime.ivars"]) {
        return FURuntimeIvars(requestID, request);
    }
    if ([op isEqualToString:@"heap.snapshot"]) {
        return FUHandleHeapSnapshot(requestID, request);
    }
    if ([op isEqualToString:@"heap.instances"]) {
        return FUHandleHeapInstances(requestID, request);
    }
    if ([op isEqualToString:@"heap.subclasses"]) {
        return FUHandleHeapSubclasses(requestID, request);
    }
    if ([op isEqualToString:@"heap.references"]) {
        return FUHandleHeapReferences(requestID, request);
    }
    if ([op isEqualToString:@"heap.reference_graph"]) {
        return FUHandleHeapReferenceGraph(requestID, request);
    }
    if ([op isEqualToString:@"bookmarks.list"]) {
        return FUHandleBookmarksList(requestID, request);
    }
    if ([op isEqualToString:@"bookmarks.add"]) {
        return FUHandleBookmarksAdd(requestID, request);
    }
    if ([op isEqualToString:@"bookmarks.remove"]) {
        return FUHandleBookmarksRemove(requestID, request);
    }
    if ([op isEqualToString:@"network.transactions"]) {
        return FUHandleNetworkTransactions(requestID, request);
    }
    if ([op isEqualToString:@"logs.messages"]) {
        return FUHandleLogMessages(requestID, request);
    }
    if ([op isEqualToString:@"globals.entries"]) {
        return FUHandleGlobalsEntries(requestID, request);
    }
    if ([op isEqualToString:@"globals.open"]) {
        return FUHandleGlobalsOpen(requestID, request);
    }
    if ([op isEqualToString:@"globals.invoke"]) {
        return FUHandleGlobalsInvoke(requestID, request);
    }
    if ([op isEqualToString:@"defaults.entries"]) {
        return FUHandleDefaultsEntries(requestID, request);
    }
    if ([op isEqualToString:@"defaults.get"]) {
        return FUHandleDefaultsGet(requestID, request);
    }
    if ([op isEqualToString:@"defaults.set"]) {
        return FUHandleDefaultsSet(requestID, request);
    }
    if ([op isEqualToString:@"defaults.remove"]) {
        return FUHandleDefaultsRemove(requestID, request);
    }
    if ([op isEqualToString:@"keychain.items"]) {
        return FUHandleKeychainItems(requestID, request);
    }
    if ([op isEqualToString:@"keychain.item"]) {
        return FUHandleKeychainItem(requestID, request);
    }
    if ([op isEqualToString:@"database.sqlite.tables"]) {
        return FUHandleSQLiteTables(requestID, request);
    }
    if ([op isEqualToString:@"database.sqlite.columns"]) {
        return FUHandleSQLiteColumns(requestID, request);
    }
    if ([op isEqualToString:@"database.sqlite.rows"]) {
        return FUHandleSQLiteRows(requestID, request);
    }
    if ([op isEqualToString:@"database.realm.tables"]) {
        return FUHandleRealmTables(requestID, request);
    }
    if ([op isEqualToString:@"database.realm.columns"]) {
        return FUHandleRealmColumns(requestID, request);
    }
    if ([op isEqualToString:@"database.realm.rows"]) {
        return FUHandleRealmRows(requestID, request);
    }
    if ([op isEqualToString:@"filesystem.list"]) {
        return FUHandleFilesystemList(requestID, request);
    }
    if ([op isEqualToString:@"filesystem.stat"]) {
        return FUHandleFilesystemStat(requestID, request);
    }
    if ([op isEqualToString:@"filesystem.read"]) {
        return FUHandleFilesystemRead(requestID, request);
    }
    if ([op isEqualToString:@"filesystem.search"]) {
        return FUHandleFilesystemSearch(requestID, request);
    }
    if ([op isEqualToString:@"ui.windows"]) {
        return FUHandleUIWindows(requestID);
    }
    if ([op isEqualToString:@"ui.key_window"]) {
        return FUHandleUIKeyWindow(requestID);
    }
    if ([op isEqualToString:@"ui.hierarchy"]) {
        return FUHandleUIHierarchy(requestID, request);
    }
    if ([op isEqualToString:@"ui.find"]) {
        return FUHandleUIFind(requestID, request);
    }
    if ([op isEqualToString:@"ui.resolve"]) {
        return FUHandleUIResolve(requestID, request);
    }
    if ([op isEqualToString:@"ui.wait"]) {
        return FUHandleUIWait(requestID, request);
    }
    if ([op isEqualToString:@"ui.activate"]) {
        return FUHandleUIActivate(requestID, request);
    }
    if ([op isEqualToString:@"ui.select"]) {
        return FUHandleUISelect(requestID, request);
    }
    if ([op isEqualToString:@"ui.back"]) {
        return FUHandleUIBack(requestID, request);
    }
    if ([op isEqualToString:@"ui.dismiss"]) {
        return FUHandleUIDismiss(requestID, request);
    }
    if ([op isEqualToString:@"ui.first_responder"]) {
        return FUHandleUIFirstResponder(requestID);
    }
    if ([op isEqualToString:@"ui.dismiss_keyboard"]) {
        return FUHandleUIDismissKeyboard(requestID);
    }
    if ([op isEqualToString:@"ui.alert"]) {
        return FUHandleUIAlert(requestID);
    }
    if ([op isEqualToString:@"ui.alert_action"]) {
        return FUHandleUIAlertAction(requestID, request);
    }
    if ([op isEqualToString:@"ui.hit_test"]) {
        return FUHandleUIHitTest(requestID, request);
    }
    if ([op isEqualToString:@"ui.tap"]) {
        return FUHandleUITap(requestID, request);
    }
    if ([op isEqualToString:@"ui.set_text"]) {
        return FUHandleUISetText(requestID, request);
    }
    if ([op isEqualToString:@"ui.set_value"]) {
        return FUHandleUISetValue(requestID, request);
    }
    if ([op isEqualToString:@"ui.scroll"]) {
        return FUHandleUIScroll(requestID, request);
    }
    if ([op isEqualToString:@"ui.screenshot"]) {
        return FUHandleUIScreenshot(requestID, request);
    }
    if ([op isEqualToString:@"ui.snapshot"]) {
        return FUHandleUISnapshot(requestID, request);
    }
    if ([op isEqualToString:@"ui.snapshot_save"]) {
        return FUHandleUISnapshotSave(requestID, request);
    }
    if ([op isEqualToString:@"ui.snapshot_diff"]) {
        return FUHandleUISnapshotDiff(requestID, request);
    }
    if ([op isEqualToString:@"ui.deep_inspect"]) {
        return FUHandleUIDeepInspect(requestID, request);
    }
    if ([op isEqualToString:@"swift.inspect"]) {
        return FUHandleSwiftInspect(requestID, request);
    }
    if ([op isEqualToString:@"investigate.screen"]) {
        return FUHandleInvestigateScreen(requestID, request);
    }
    if ([op isEqualToString:@"investigate.element"]) {
        return FUHandleInvestigateElement(requestID, request);
    }
    if ([op isEqualToString:@"object.inspect"]) {
        return FUHandleObjectInspect(requestID, request);
    }
    if ([op isEqualToString:@"object.properties"]) {
        return FUHandleObjectList(requestID, request, @"properties");
    }
    if ([op isEqualToString:@"object.ivars"]) {
        return FUHandleObjectList(requestID, request, @"ivars");
    }
    if ([op isEqualToString:@"object.methods"]) {
        return FUHandleObjectList(requestID, request, @"methods");
    }
    if ([op isEqualToString:@"object.get"]) {
        return FUHandleObjectGetSet(requestID, request, NO);
    }
    if ([op isEqualToString:@"object.set"]) {
        return FUHandleObjectGetSet(requestID, request, YES);
    }
    if ([op isEqualToString:@"object.pin"]) {
        return FUHandleObjectPin(requestID, request);
    }
    if ([op isEqualToString:@"object.unpin"]) {
        return FUHandleObjectUnpin(requestID, request);
    }
    if ([op isEqualToString:@"object.call"]) {
        return FUHandleObjectCall(requestID, request);
    }

    return FUResponse(requestID, NO, nil, FUErrorInfo(@"unknown_operation", [NSString stringWithFormat:@"Unknown operation: %@", op]));
}
