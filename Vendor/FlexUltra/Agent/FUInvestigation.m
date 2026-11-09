#import <Foundation/Foundation.h>

#import "FUHeap.h"
#import "FUObjectInspection.h"
#import "FUProtocol.h"
#import "FURuntime.h"
#import "FUSwiftInspection.h"
#import "FUUI.h"
#import "FUInvestigation.h"

static NSDictionary *FUInvestigationSection(NSDictionary *response) {
    if (![response isKindOfClass:[NSDictionary class]]) {
        return @{
            @"available": @NO,
            @"error": FUErrorInfo(@"invalid_response", @"The investigation sub-operation returned no response."),
        };
    }
    if ([response[@"ok"] boolValue]) {
        id result = response[@"result"] ?: NSNull.null;
        return @{ @"available": @YES, @"result": result };
    }
    NSDictionary *error = [response[@"error"] isKindOfClass:[NSDictionary class]] ? response[@"error"] : FUErrorInfo(@"unknown_error", @"The investigation sub-operation failed.");
    return @{ @"available": @NO, @"error": error };
}

static NSDictionary *FUInvestigationResult(NSDictionary *section) {
    if (![section isKindOfClass:[NSDictionary class]] || ![section[@"available"] boolValue]) return nil;
    return [section[@"result"] isKindOfClass:[NSDictionary class]] ? section[@"result"] : nil;
}

static NSDictionary *FUInvestigationNextAction(NSString *operation,
                                               NSDictionary *arguments,
                                               NSDictionary *operationSupport,
                                               NSString *reason) {
    NSMutableDictionary *action = [@{
        @"op": operation ?: @"",
        @"arguments": arguments ?: @{},
    } mutableCopy];
    NSDictionary *support = [operationSupport[operation] isKindOfClass:[NSDictionary class]] ? operationSupport[operation] : nil;
    BOOL supported = support ? [support[@"supported"] boolValue] : YES;
    action[@"supported"] = @(supported);
    action[@"available"] = @(supported);
    if (support[@"reason"]) action[@"support_reason"] = support[@"reason"];
    if (support[@"conditional"]) action[@"conditional"] = support[@"conditional"];
    if (support[@"limitations"]) action[@"limitations"] = support[@"limitations"];
    if (reason.length) action[@"reason"] = reason;
    return action;
}

static NSDictionary *FUInvestigationSnapshotEntry(NSDictionary *snapshot, NSString *handle) {
    if (handle.length == 0) return nil;
    NSArray *elements = [snapshot[@"elements"] isKindOfClass:[NSArray class]] ? snapshot[@"elements"] : @[];
    for (id item in elements) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *identifier = [item[@"id"] isKindOfClass:[NSString class]] ? item[@"id"] : nil;
        if ([identifier isEqualToString:handle]) return item;
    }
    NSDictionary *root = [snapshot[@"root"] isKindOfClass:[NSDictionary class]] ? snapshot[@"root"] : nil;
    return [[root[@"id"] description] isEqualToString:handle] ? root : nil;
}

static void FUAddClassCandidate(NSMutableArray *candidates,
                                NSMutableSet<NSString *> *seen,
                                NSDictionary *reference,
                                NSString *relation,
                                NSDictionary *extra) {
    if (![reference isKindOfClass:[NSDictionary class]]) return;
    NSString *className = [reference[@"class"] isKindOfClass:[NSString class]] ? reference[@"class"] : @"";
    if (className.length == 0 || relation.length == 0) return;
    NSString *key = [NSString stringWithFormat:@"%@|%@", relation, className];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSMutableDictionary *candidate = [@{
        @"class_name": className,
        @"relation": relation,
    } mutableCopy];
    for (NSString *field in @[@"id", @"image"]) {
        if (reference[field]) candidate[field] = reference[field];
    }
    if ([extra isKindOfClass:[NSDictionary class]]) [candidate addEntriesFromDictionary:extra];
    [candidates addObject:candidate];
}

static void FUAddHookCandidate(NSMutableArray *candidates,
                               NSMutableDictionary<NSString *, NSMutableDictionary *> *byKey,
                               NSString *className,
                               NSString *selector,
                               NSDictionary *evidence,
                               NSString *rationale) {
    if (className.length == 0 || selector.length == 0 || ![evidence isKindOfClass:[NSDictionary class]]) return;
    NSString *key = [NSString stringWithFormat:@"%@|%@", className, selector];
    NSMutableDictionary *candidate = byKey[key];
    if (!candidate) {
        candidate = [@{
            @"kind": @"method",
            @"class_name": className,
            @"selector": selector,
            @"method_kind": @"instance",
            @"evidence": [NSMutableArray array],
            @"rationale": rationale ?: @"Observed runtime evidence links this selector to the inspected element.",
        } mutableCopy];
        byKey[key] = candidate;
        [candidates addObject:candidate];
    }
    NSMutableArray *evidenceList = candidate[@"evidence"];
    if (evidenceList.count < 16) [evidenceList addObject:evidence];
}

static NSDictionary *FUElementTweakTargets(NSDictionary *focus,
                                            NSDictionary *snapshot,
                                            NSDictionary *deep,
                                            NSDictionary *referenceGraph,
                                            BOOL includeTraceRecipe) {
    NSMutableArray *classCandidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seenClasses = [NSMutableSet set];
    NSMutableArray *hookCandidates = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *hookCandidatesByKey = [NSMutableDictionary dictionary];

    NSDictionary *selected = [deep[@"selected"] isKindOfClass:[NSDictionary class]] ? deep[@"selected"] : focus;
    FUAddClassCandidate(classCandidates, seenClasses, selected, @"selected", nil);
    FUAddClassCandidate(classCandidates, seenClasses, deep[@"view_controller"], @"owning_view_controller", nil);

    for (id item in [deep[@"responder_chain"] isKindOfClass:[NSArray class]] ? deep[@"responder_chain"] : @[]) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        FUAddClassCandidate(classCandidates, seenClasses, item, @"responder_chain", nil);
        if (classCandidates.count >= 40) break;
    }
    for (id item in [deep[@"superviews"] isKindOfClass:[NSArray class]] ? deep[@"superviews"] : @[]) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        FUAddClassCandidate(classCandidates, seenClasses, item, @"superview", nil);
        if (classCandidates.count >= 40) break;
    }

    for (id item in [deep[@"control_actions"] isKindOfClass:[NSArray class]] ? deep[@"control_actions"] : @[]) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *target = [item[@"target"] isKindOfClass:[NSDictionary class]] ? item[@"target"] : @{};
        NSString *className = [target[@"class"] isKindOfClass:[NSString class]] ? target[@"class"] : @"";
        NSString *selector = [item[@"action"] isKindOfClass:[NSString class]] ? item[@"action"] : @"";
        NSMutableDictionary *evidence = [@{ @"source": @"ui.deep_inspect.control_actions" } mutableCopy];
        if (item[@"event"]) evidence[@"event"] = item[@"event"];
        if (item[@"event_mask"]) evidence[@"event_mask"] = item[@"event_mask"];
        if (target.count) evidence[@"target"] = target;
        FUAddHookCandidate(hookCandidates, hookCandidatesByKey, className, selector, evidence,
                           @"UIKit reported this exact target/action pair for the selected control.");
    }

    for (id gesture in [deep[@"gestures"] isKindOfClass:[NSArray class]] ? deep[@"gestures"] : @[]) {
        if (![gesture isKindOfClass:[NSDictionary class]]) continue;
        for (id item in [gesture[@"targets"] isKindOfClass:[NSArray class]] ? gesture[@"targets"] : @[]) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *target = [item[@"target"] isKindOfClass:[NSDictionary class]] ? item[@"target"] : @{};
            NSString *className = [target[@"class"] isKindOfClass:[NSString class]] ? target[@"class"] : @"";
            NSString *selector = [item[@"action"] isKindOfClass:[NSString class]] ? item[@"action"] : @"";
            NSMutableDictionary *evidence = [@{ @"source": @"ui.deep_inspect.gestures.targets" } mutableCopy];
            if (gesture[@"id"]) evidence[@"gesture"] = gesture[@"id"];
            if (target.count) evidence[@"target"] = target;
            FUAddHookCandidate(hookCandidates, hookCandidatesByKey, className, selector, evidence,
                               @"UIKit gesture metadata reported this exact target/action pair for a recognizer attached to the selected view.");
        }
    }

    NSArray *graphNodes = [referenceGraph[@"nodes"] isKindOfClass:[NSArray class]] ? referenceGraph[@"nodes"] : @[];
    NSUInteger ownerCount = 0;
    for (id item in graphNodes) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSUInteger depth = [item[@"depth"] respondsToSelector:@selector(unsignedIntegerValue)] ? [item[@"depth"] unsignedIntegerValue] : 0;
        if (depth == 0) continue;
        FUAddClassCandidate(classCandidates, seenClasses, item, @"reverse_reference", @{ @"depth": @(depth) });
        if (++ownerCount >= 20 || classCandidates.count >= 60) break;
    }

    NSString *focusHandle = [selected[@"id"] isKindOfClass:[NSString class]] ? selected[@"id"] : nil;
    NSDictionary *viewState = [deep[@"view_state"] isKindOfClass:[NSDictionary class]] ? deep[@"view_state"] : nil;
    NSDictionary *stableSelector = [viewState[@"selector"] isKindOfClass:[NSDictionary class]] ? viewState[@"selector"] : nil;
    if (!stableSelector) {
        NSDictionary *snapshotEntry = FUInvestigationSnapshotEntry(snapshot, focusHandle);
        stableSelector = [snapshotEntry[@"selector"] isKindOfClass:[NSDictionary class]] ? snapshotEntry[@"selector"] : nil;
    }
    NSString *selectedClass = [selected[@"class"] isKindOfClass:[NSString class]] ? selected[@"class"] : nil;

    NSMutableDictionary *result = [@{
        @"selected_class": selectedClass ?: @"",
        @"class_candidates": classCandidates,
        @"hook_candidates": hookCandidates,
        @"candidate_policy": @"hook_candidates are emitted only from observed UIKit target/action metadata; class_candidates report observed runtime relationships without inventing selectors.",
    } mutableCopy];
    if (stableSelector) result[@"stable_selector"] = stableSelector;
    if ([deep[@"view_controller"] isKindOfClass:[NSDictionary class]]) result[@"owning_view_controller"] = deep[@"view_controller"];
    if (includeTraceRecipe && selectedClass.length) {
        result[@"trace_recipe"] = @{
            @"op": @"trace.start",
            @"arguments": @{
                @"include_classes": @[selectedClass],
                @"max_events": @500,
                @"max_total_events": @5000,
                @"max_duration_ms": @30000,
                @"argument_detail": @"class",
            },
            @"purpose": @"Collect live selector evidence for the selected class before choosing additional method hooks.",
        };
    }
    return result;
}

NSDictionary *FUHandleInvestigateScreen(NSString *requestID, NSDictionary *request) {
    NSUInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"limit"] unsignedIntegerValue] : 40;
    NSUInteger limit = MIN(MAX(requestedLimit, (NSUInteger)1), (NSUInteger)200);

    NSMutableDictionary *snapshotRequest = [request mutableCopy];
    snapshotRequest[@"limit"] = @(limit);
    NSDictionary *snapshotResponse = FUHandleUISnapshot(requestID, snapshotRequest);
    if (![snapshotResponse[@"ok"] boolValue]) return snapshotResponse;

    NSDictionary *rawSnapshot = [snapshotResponse[@"result"] isKindOfClass:[NSDictionary class]] ? snapshotResponse[@"result"] : @{};
    NSMutableDictionary *snapshot = [rawSnapshot mutableCopy];
    [snapshot removeObjectForKey:@"data"];
    [snapshot removeObjectForKey:@"mime_type"];

    NSMutableDictionary *focusRequest = [request mutableCopy];
    focusRequest[@"limit"] = @(limit);
    NSDictionary *focus = nil;
    NSString *focusSource = nil;

    BOOL hasExplicitHandle = [request[@"handle"] isKindOfClass:[NSString class]] && [request[@"handle"] length] > 0;
    BOOL hasExplicitSelector = [request[@"ui_selector"] isKindOfClass:[NSDictionary class]];
    if (hasExplicitHandle || hasExplicitSelector) {
        focusSource = hasExplicitSelector ? @"ui_selector" : @"handle";
    } else {
        NSArray *elements = [rawSnapshot[@"elements"] isKindOfClass:[NSArray class]] ? rawSnapshot[@"elements"] : @[];
        NSDictionary *candidate = nil;
        for (id item in elements) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSArray *actions = [item[@"actions"] isKindOfClass:[NSArray class]] ? item[@"actions"] : nil;
            if (actions.count > 0 && [item[@"id"] isKindOfClass:[NSString class]] && [item[@"id"] length] > 0) {
                candidate = item;
                break;
            }
        }
        if (!candidate) {
            for (id item in elements) {
                if ([item isKindOfClass:[NSDictionary class]] && [item[@"id"] isKindOfClass:[NSString class]] && [item[@"id"] length] > 0) {
                    candidate = item;
                    break;
                }
            }
        }
        if (!candidate) {
            NSDictionary *root = [rawSnapshot[@"root"] isKindOfClass:[NSDictionary class]] ? rawSnapshot[@"root"] : nil;
            if ([root[@"id"] isKindOfClass:[NSString class]] && [root[@"id"] length] > 0) candidate = root;
        }
        if (candidate) {
            focus = candidate;
            focusRequest[@"handle"] = candidate[@"id"];
            [focusRequest removeObjectForKey:@"ui_selector"];
            focusSource = @"auto_snapshot";
        }
    }

    NSDictionary *deepResponse = FUHandleUIDeepInspect(requestID, focusRequest);
    NSDictionary *deepSection = FUInvestigationSection(deepResponse);
    if (!focus && [deepSection[@"available"] boolValue]) {
        NSDictionary *deepResult = [deepSection[@"result"] isKindOfClass:[NSDictionary class]] ? deepSection[@"result"] : nil;
        if ([deepResult[@"selected"] isKindOfClass:[NSDictionary class]]) focus = deepResult[@"selected"];
    }

    NSDictionary *swiftSection = nil;
    if (FUSwiftInspectionAvailable()) {
        // Aggregate investigation is a discovery primitive. Keep Swift
        // reflection metadata-first on runtimes where Reflex is process-safe.
        NSMutableDictionary *swiftRequest = [focusRequest mutableCopy];
        swiftRequest[@"include_values"] = @NO;
        NSDictionary *swiftResponse = FUHandleSwiftInspect(requestID, swiftRequest);
        swiftSection = FUInvestigationSection(swiftResponse);
    } else {
        swiftSection = @{
            @"available": @NO,
            @"error": FUErrorInfo(@"swift_runtime_unsafe", FUSwiftInspectionUnavailableReason()),
        };
    }
    NSDictionary *flex = FUFlexStatus(YES);
    NSDictionary *operationSupport = [flex[@"operation_support"] isKindOfClass:[NSDictionary class]] ? flex[@"operation_support"] : @{};

    NSString *focusHandle = [focus[@"id"] isKindOfClass:[NSString class]] ? focus[@"id"] : nil;
    if (!focusHandle.length && hasExplicitHandle) focusHandle = request[@"handle"];
    NSString *focusClass = [focus[@"class"] isKindOfClass:[NSString class]] ? focus[@"class"] : nil;
    NSMutableArray *nextActions = [NSMutableArray array];
    if (focusHandle.length) {
        [nextActions addObject:FUInvestigationNextAction(@"object.inspect", @{ @"handle": focusHandle, @"limit": @(limit) }, operationSupport, nil)];
        [nextActions addObject:FUInvestigationNextAction(@"object.methods", @{ @"handle": focusHandle, @"limit": @(MIN(limit, (NSUInteger)50)) }, operationSupport, nil)];
        [nextActions addObject:FUInvestigationNextAction(@"heap.references", @{ @"handle": focusHandle, @"limit": @(MIN(limit, (NSUInteger)50)) }, operationSupport, nil)];
        [nextActions addObject:FUInvestigationNextAction(@"swift.inspect", @{ @"handle": focusHandle, @"limit": @(MIN(limit, (NSUInteger)100)), @"include_values": @NO }, operationSupport, nil)];
    }
    if (focusClass.length) {
        [nextActions addObject:FUInvestigationNextAction(@"trace.start", @{
                @"include_classes": @[focusClass],
                @"max_events": @500,
                @"argument_detail": @"class",
            }, operationSupport, nil)];
    }
    if (nextActions.count > 5) [nextActions removeObjectsInRange:NSMakeRange(5, nextActions.count - 5)];

    NSDictionary *snapshotLimits = [rawSnapshot[@"limits"] isKindOfClass:[NSDictionary class]] ? rawSnapshot[@"limits"] : @{};
    NSMutableDictionary *result = [@{
        @"flex": flex ?: @{},
        @"snapshot": snapshot,
        @"focus": focus ?: @{},
        @"focus_source": focusSource ?: @"unresolved",
        @"deep_inspect": deepSection,
        @"swift": swiftSection,
        @"next_actions": nextActions,
        @"limits": @{
            @"members": @(limit),
            @"max_nodes": snapshotLimits[@"max_nodes"] ?: @750,
        },
        @"truncated": rawSnapshot[@"truncated"] ?: @NO,
    } mutableCopy];

    for (NSString *key in @[@"mime_type", @"data", @"byte_count", @"width", @"height", @"scale"]) {
        if (rawSnapshot[key]) result[key] = rawSnapshot[key];
    }
    return FUResponse(requestID, YES, result, nil);
}

NSDictionary *FUHandleInvestigateElement(NSString *requestID, NSDictionary *request) {
    NSUInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"limit"] unsignedIntegerValue] : 80;
    if (requestedLimit < 1 || requestedLimit > 200) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_investigation_bounds", @"limit must be between 1 and 200."));
    }
    NSUInteger limit = requestedLimit;

    NSInteger heapDepth = [request[@"heap_max_depth"] respondsToSelector:@selector(integerValue)] ? [request[@"heap_max_depth"] integerValue] : 2;
    NSInteger heapNodes = [request[@"heap_max_nodes"] respondsToSelector:@selector(integerValue)] ? [request[@"heap_max_nodes"] integerValue] : 80;
    NSInteger heapPerNode = [request[@"heap_per_node_limit"] respondsToSelector:@selector(integerValue)] ? [request[@"heap_per_node_limit"] integerValue] : 30;
    NSInteger heapTimeoutMS = [request[@"heap_timeout_ms"] respondsToSelector:@selector(integerValue)] ? [request[@"heap_timeout_ms"] integerValue] : 20000;
    if (heapDepth < 1 || heapDepth > 5 || heapNodes < 1 || heapNodes > 500 || heapPerNode < 1 || heapPerNode > 200 || heapTimeoutMS < 1 || heapTimeoutMS > 110000) {
        return FUResponse(requestID, NO, nil,
                          FUErrorInfo(@"invalid_investigation_bounds",
                                      @"heap_max_depth must be 1-5, heap_max_nodes 1-500, heap_per_node_limit 1-200, and heap_timeout_ms 1-110000."));
    }

    NSMutableDictionary *screenRequest = [request mutableCopy];
    screenRequest[@"limit"] = @(limit);
    screenRequest[@"include_image"] = @NO;
    NSDictionary *screenResponse = FUHandleInvestigateScreen(requestID, screenRequest);
    if (![screenResponse[@"ok"] boolValue]) return screenResponse;
    NSDictionary *screen = [screenResponse[@"result"] isKindOfClass:[NSDictionary class]] ? screenResponse[@"result"] : @{};
    NSDictionary *focus = [screen[@"focus"] isKindOfClass:[NSDictionary class]] ? screen[@"focus"] : @{};
    NSDictionary *snapshot = [screen[@"snapshot"] isKindOfClass:[NSDictionary class]] ? screen[@"snapshot"] : @{};
    NSDictionary *deepSection = [screen[@"deep_inspect"] isKindOfClass:[NSDictionary class]] ? screen[@"deep_inspect"] : @{};
    NSDictionary *deep = FUInvestigationResult(deepSection) ?: @{};

    NSString *focusHandle = [focus[@"id"] isKindOfClass:[NSString class]] ? focus[@"id"] : nil;
    if (focusHandle.length == 0) {
        NSDictionary *selected = [deep[@"selected"] isKindOfClass:[NSDictionary class]] ? deep[@"selected"] : nil;
        focusHandle = [selected[@"id"] isKindOfClass:[NSString class]] ? selected[@"id"] : nil;
    }
    if (focusHandle.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"focus_unresolved", @"The investigation could not resolve a live object handle for the focused element."));
    }

    NSMutableDictionary *objectRequest = [request mutableCopy];
    objectRequest[@"handle"] = focusHandle;
    [objectRequest removeObjectForKey:@"ui_selector"];
    objectRequest[@"limit"] = @(limit);
    NSDictionary *objectSection = FUInvestigationSection(FUHandleObjectInspect(requestID, objectRequest));
    NSDictionary *objectResult = FUInvestigationResult(objectSection) ?: @{};

    NSString *className = [objectResult[@"class"] isKindOfClass:[NSString class]] ? objectResult[@"class"] : nil;
    if (className.length == 0) {
        NSDictionary *selected = [deep[@"selected"] isKindOfClass:[NSDictionary class]] ? deep[@"selected"] : focus;
        className = [selected[@"class"] isKindOfClass:[NSString class]] ? selected[@"class"] : nil;
    }

    NSDictionary *classSection = @{ @"available": @NO, @"error": FUErrorInfo(@"class_unresolved", @"The focused object did not report an Objective-C class name.") };
    NSDictionary *methodsSection = classSection;
    NSDictionary *propertiesSection = classSection;
    NSDictionary *ivarsSection = classSection;
    if (className.length) {
        NSDictionary *classRequest = @{ @"name": className };
        classSection = FUInvestigationSection(FURuntimeClass(requestID, classRequest));
        NSDictionary *catalogRequest = @{ @"class_name": className, @"offset": @0, @"limit": @(limit) };
        methodsSection = FUInvestigationSection(FURuntimeMethods(requestID, catalogRequest));
        propertiesSection = FUInvestigationSection(FURuntimeProperties(requestID, catalogRequest));
        ivarsSection = FUInvestigationSection(FURuntimeIvars(requestID, catalogRequest));
    }

    BOOL includeReferenceGraph = ![request[@"include_reference_graph"] respondsToSelector:@selector(boolValue)] || [request[@"include_reference_graph"] boolValue];
    NSDictionary *referenceSection = nil;
    if (includeReferenceGraph) {
        NSDictionary *heapRequest = @{
            @"handle": focusHandle,
            @"max_depth": @(heapDepth),
            @"max_nodes": @(heapNodes),
            @"per_node_limit": @(heapPerNode),
            @"timeout_ms": @(heapTimeoutMS),
        };
        referenceSection = FUInvestigationSection(FUHandleHeapReferenceGraph(requestID, heapRequest));
    } else {
        referenceSection = @{
            @"available": @NO,
            @"skipped": @YES,
            @"reason": @"disabled",
        };
    }
    NSDictionary *referenceGraph = FUInvestigationResult(referenceSection) ?: @{};
    BOOL includeTraceRecipe = ![request[@"include_trace_recipe"] respondsToSelector:@selector(boolValue)] || [request[@"include_trace_recipe"] boolValue];
    NSDictionary *tweakTargets = FUElementTweakTargets(focus, snapshot, deep, referenceGraph, includeTraceRecipe);

    NSMutableArray *nextActions = [NSMutableArray array];
    NSDictionary *screenFlex = [screen[@"flex"] isKindOfClass:[NSDictionary class]] ? screen[@"flex"] : @{};
    NSDictionary *operationSupport = [screenFlex[@"operation_support"] isKindOfClass:[NSDictionary class]]
        ? screenFlex[@"operation_support"]
        : @{};
    NSDictionary *referenceError = [referenceSection[@"error"] isKindOfClass:[NSDictionary class]] ? referenceSection[@"error"] : nil;
    if (![referenceSection[@"available"] boolValue] && [referenceError[@"code"] isEqualToString:@"heap_timeout"]) {
        NSInteger retryTimeoutMS = MAX(heapTimeoutMS, 60000);
        if (retryTimeoutMS > 110000) retryTimeoutMS = 110000;
        [nextActions addObject:FUInvestigationNextAction(@"heap.reference_graph", @{
                @"handle": focusHandle,
                @"max_depth": @1,
                @"max_nodes": @(MIN(heapNodes, 12)),
                @"per_node_limit": @(MIN(heapPerNode, 4)),
                @"timeout_ms": @(retryTimeoutMS),
            }, operationSupport, @"reference_graph_timeout")];
    }
    NSArray *screenActions = [screen[@"next_actions"] isKindOfClass:[NSArray class]] ? screen[@"next_actions"] : @[];
    [nextActions addObjectsFromArray:screenActions];
    if (className.length) {
        [nextActions addObject:FUInvestigationNextAction(@"runtime.class_protocols", @{ @"class_name": className, @"include_inherited": @YES, @"limit": @(limit) }, operationSupport, nil)];
    }
    if (nextActions.count > 8) [nextActions removeObjectsInRange:NSMakeRange(8, nextActions.count - 8)];

    NSMutableDictionary *result = [@{
        @"flex": screen[@"flex"] ?: @{},
        @"snapshot": snapshot,
        @"focus": focus,
        @"focus_source": screen[@"focus_source"] ?: @"unresolved",
        @"deep_inspect": deepSection,
        @"swift": screen[@"swift"] ?: @{},
        @"object_inspect": objectSection,
        @"runtime_class": classSection,
        @"runtime_methods": methodsSection,
        @"runtime_properties": propertiesSection,
        @"runtime_ivars": ivarsSection,
        @"reference_graph": referenceSection,
        @"tweak_targets": tweakTargets,
        @"next_actions": nextActions,
        @"limits": @{
            @"members": @(limit),
            @"heap_max_depth": @(heapDepth),
            @"heap_max_nodes": @(heapNodes),
            @"heap_per_node_limit": @(heapPerNode),
            @"heap_timeout_ms": @(heapTimeoutMS),
        },
        @"truncated": screen[@"truncated"] ?: @NO,
    } mutableCopy];
    return FUResponse(requestID, YES, result, nil);
}
