#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

#import "FUUI.h"
#import "FUProtocol.h"
#import "FUObjectRegistry.h"
#import "FUObjectSerialization.h"
#import "FUObjectInspection.h"
#import "FURuntime.h"

static FUUIExperimentPrepareMutationCallback FUUIExperimentPrepareMutation;
static FUUIExperimentAbortMutationCallback FUUIExperimentAbortMutation;
static FUUIExperimentCommitMutationCallback FUUIExperimentCommitMutation;

static NSObject *FUSnapshotStoreLock;
static NSMutableDictionary<NSString *, NSDictionary *> *FUSavedSnapshots;
static NSMutableArray<NSString *> *FUSavedSnapshotOrder;
static uint64_t FUSnapshotCounter = 1;
static const NSUInteger FUMaxSavedSnapshots = 8;

void FUUIConfigureExperimentCallbacks(FUUIExperimentPrepareMutationCallback prepare,
                                      FUUIExperimentAbortMutationCallback abort,
                                      FUUIExperimentCommitMutationCallback commit) {
    FUUIExperimentPrepareMutation = prepare;
    FUUIExperimentAbortMutation = abort;
    FUUIExperimentCommitMutation = commit;
}

static BOOL FUExperimentPrepareMutation(NSDictionary *request, NSString **experimentID, NSDictionary **errorInfo) {
    if (FUUIExperimentPrepareMutation) {
        return FUUIExperimentPrepareMutation(request, experimentID, errorInfo);
    }
    if (![request.allKeys containsObject:@"experiment_id"]) {
        if (experimentID) *experimentID = nil;
        if (errorInfo) *errorInfo = nil;
        return YES;
    }
    if (errorInfo) *errorInfo = FUErrorInfo(@"experiment_unavailable", @"The UI experiment integration is not configured in this target process.");
    return NO;
}

static void FUExperimentAbortMutation(NSString *experimentID) {
    if (FUUIExperimentAbortMutation) FUUIExperimentAbortMutation(experimentID);
}

static BOOL FUExperimentCommitMutation(NSString *experimentID, NSDictionary *undoRecord, NSMutableDictionary *result, NSDictionary **errorInfo) {
    if (experimentID.length == 0) return YES;
    if (FUUIExperimentCommitMutation) {
        return FUUIExperimentCommitMutation(experimentID, undoRecord, result, errorInfo);
    }
    if (errorInfo) *errorInfo = FUErrorInfo(@"experiment_unavailable", @"The UI experiment integration is not configured in this target process.");
    return NO;
}

NSArray<UIWindow *> *FUAllWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *windows = [NSMutableOrderedSet orderedSet];

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [windows addObject:window];
        }
    }

    if (windows.count == 0) {
        NSArray<UIWindow *> *legacyWindows = ((id (*)(id, SEL))objc_msgSend)(application, NSSelectorFromString(@"windows"));
        for (UIWindow *window in legacyWindows) {
            [windows addObject:window];
        }
    }
    return windows.array;
}

UIWindow *FUKeyWindow(void) {
    NSArray<UIWindow *> *windows = FUAllWindows();
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) {
            return window;
        }
    }
    for (UIWindow *window in windows) {
        if (!window.hidden && window.alpha > 0.0) {
            return window;
        }
    }
    return windows.firstObject;
}

NSDictionary *FUWindowJSON(UIWindow *window) {
    NSMutableDictionary *json = [FUObjectReference(window) mutableCopy];
    json[@"key"] = @(window.isKeyWindow);
    json[@"hidden"] = @(window.hidden);
    json[@"alpha"] = FUJSONFloatingNumber(window.alpha);
    json[@"level"] = FUJSONFloatingNumber(window.windowLevel);
    json[@"frame"] = FURectJSON(window.frame);
    if (window.rootViewController) {
        json[@"root_view_controller"] = FUObjectReference(window.rootViewController);
    }
    if (window.windowScene) {
        json[@"scene_activation_state"] = @(window.windowScene.activationState);
    }
    return json;
}

NSDictionary *FUHandleUIWindows(NSString *requestID) {
    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        NSMutableArray *windows = [NSMutableArray array];
        for (UIWindow *window in FUAllWindows()) {
            [windows addObject:FUWindowJSON(window)];
        }
        response = FUResponse(requestID, YES, @{
            @"windows": windows,
            @"count": @(windows.count),
        }, nil);
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return response;
}

NSDictionary *FUHandleUIKeyWindow(NSString *requestID) {
    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIWindow *window = FUKeyWindow();
        if (!window) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"window_not_found", @"No UIWindow is currently available in the target process."));
            return;
        }
        response = FUResponse(requestID, YES, @{ @"window": FUWindowJSON(window) }, nil);
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return response;
}

static UIViewController *FUEffectiveViewController(UIViewController *root, UIViewController **latestPresentation) {
    UIViewController *current = root;
    UIViewController *presentation = nil;
    for (NSUInteger depth = 0; current && depth < 64; depth++) {
        UIViewController *presented = current.presentedViewController;
        if (presented && presented != current) {
            presentation = presented;
            current = presented;
            continue;
        }
        if ([current isKindOfClass:[UINavigationController class]]) {
            UIViewController *visible = ((UINavigationController *)current).visibleViewController ?: ((UINavigationController *)current).topViewController;
            if (visible && visible != current) {
                current = visible;
                continue;
            }
        }
        if ([current isKindOfClass:[UITabBarController class]]) {
            UIViewController *selected = ((UITabBarController *)current).selectedViewController;
            if (selected && selected != current) {
                current = selected;
                continue;
            }
        }
        if ([current isKindOfClass:[UISplitViewController class]]) {
            UIViewController *last = ((UISplitViewController *)current).viewControllers.lastObject;
            if (last && last != current) {
                current = last;
                continue;
            }
        }
        break;
    }
    if (latestPresentation) {
        *latestPresentation = presentation;
    }
    return current;
}

static BOOL FUViewIsVisibleInWindow(UIView *view, UIWindow *window) {
    if (!view || !window || view.window != window || view.hidden || view.alpha <= 0.01) {
        return NO;
    }
    UIView *cursor = view.superview;
    while (cursor && cursor != window) {
        if (cursor.hidden || cursor.alpha <= 0.01) {
            return NO;
        }
        cursor = cursor.superview;
    }
    CGRect frame = [view convertRect:view.bounds toView:window];
    return !CGRectIsNull(frame) && !CGRectIsEmpty(frame) && CGRectIntersectsRect(window.bounds, frame);
}

static UINavigationController *FUVisibleNavigationController(UIWindow *window, UIViewController *root) {
    UIViewController *effective = FUEffectiveViewController(root, nil);
    UINavigationController *navigation = [effective isKindOfClass:[UINavigationController class]]
        ? (UINavigationController *)effective
        : effective.navigationController;
    if (navigation && navigation.isViewLoaded && FUViewIsVisibleInWindow(navigation.viewIfLoaded, window)) {
        return navigation;
    }

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    NSHashTable<UINavigationController *> *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    UINavigationController *rootCandidate = nil;
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        UIResponder *responder = view.nextResponder;
        UINavigationController *candidate = nil;
        if ([responder isKindOfClass:[UINavigationController class]]) {
            candidate = (UINavigationController *)responder;
        } else if ([responder isKindOfClass:[UIViewController class]]) {
            candidate = ((UIViewController *)responder).navigationController;
        }
        if (candidate && ![seen containsObject:candidate]) {
            [seen addObject:candidate];
            if (candidate.isViewLoaded && FUViewIsVisibleInWindow(candidate.viewIfLoaded, window)) {
                if (candidate.viewControllers.count > 1) {
                    return candidate;
                }
                if (!rootCandidate) {
                    rootCandidate = candidate;
                }
            }
        }

        for (UIView *child in view.subviews) {
            [stack addObject:child];
        }
    }
    return rootCandidate;
}

static UIView *FUVisibleBackControl(UIWindow *window) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    UIView *labelCandidate = nil;
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (FUViewIsVisibleInWindow(view, window)) {
            NSString *identifier = view.accessibilityIdentifier ?: @"";
            NSString *label = view.accessibilityLabel ?: @"";
            BOOL identifierMatch = [identifier isEqualToString:@"BackButton"];
            BOOL labelMatch = [label caseInsensitiveCompare:@"Back"] == NSOrderedSame;
            if (identifierMatch || labelMatch) {
                CGRect frame = [view convertRect:view.bounds toView:window];
                BOOL inNavigationRegion = CGRectGetMidX(frame) <= CGRectGetWidth(window.bounds) * 0.5 &&
                    CGRectGetMidY(frame) <= MIN((CGFloat)220.0, CGRectGetHeight(window.bounds) * 0.3);
                BOOL activatable = NO;
                if ([view isKindOfClass:[UIControl class]]) {
                    activatable = ((UIControl *)view).enabled;
                } else if (view.isAccessibilityElement && (view.accessibilityTraits & UIAccessibilityTraitButton) != 0) {
                    activatable = YES;
                }
                if (inNavigationRegion && activatable) {
                    if (identifierMatch) {
                        return view;
                    }
                    if (!labelCandidate) {
                        labelCandidate = view;
                    }
                }
            }
        }

        for (UIView *child in view.subviews) {
            [stack addObject:child];
        }
    }
    return labelCandidate;
}

static BOOL FUActivateBackControl(UIView *view, NSString **strategy) {
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        if (!control.enabled) {
            return NO;
        }
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        if (strategy) *strategy = @"control_touch_up_inside";
        return YES;
    }
    if ([view accessibilityActivate]) {
        if (strategy) *strategy = @"accessibility";
        return YES;
    }
    return NO;
}

NSDictionary *FUHandleUIBack(NSString *requestID, NSDictionary *request) {
    BOOL animated = [request[@"animated"] boolValue];
    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIWindow *window = FUKeyWindow();
        UIViewController *root = window.rootViewController;
        if (!root) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"navigation_unavailable", @"The key window has no root view controller."));
            return;
        }

        UINavigationController *navigation = FUVisibleNavigationController(window, root);
        NSUInteger depthBefore = navigation ? navigation.viewControllers.count : 0;
        if (!navigation || depthBefore <= 1) {
            UIView *backControl = FUVisibleBackControl(window);
            if (backControl) {
                @try {
                    NSString *strategy = nil;
                    if (!FUActivateBackControl(backControl, &strategy)) {
                        response = FUResponse(requestID, NO, nil, FUErrorInfo(@"navigation_failed", @"The visible back control did not accept semantic activation."));
                        return;
                    }
                    response = FUResponse(requestID, YES, @{
                        @"action": @"activate_back_control",
                        @"animated": @(animated),
                        @"animation_controlled": @NO,
                        @"strategy": strategy ?: @"unknown",
                        @"control": FUObjectReference(backControl),
                        @"navigation_controller": navigation ? FUObjectReference(navigation) : NSNull.null,
                        @"depth_before": navigation ? @(depthBefore) : NSNull.null,
                    }, nil);
                } @catch (NSException *exception) {
                    response = FUResponse(requestID, NO, nil, FUErrorInfo(@"navigation_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
                }
                return;
            }
            if (!navigation) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"navigation_unavailable", @"No visible UINavigationController or back control is active in the target app."));
            } else {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"nothing_to_go_back_to", @"The active navigation controller is already at its root view controller."));
            }
            return;
        }

        UIViewController *before = navigation.topViewController;
        @try {
            UIViewController *popped = [navigation popViewControllerAnimated:animated];
            UIViewController *after = navigation.topViewController;
            response = FUResponse(requestID, YES, @{
                @"action": @"pop",
                @"animated": @(animated),
                @"navigation_controller": FUObjectReference(navigation),
                @"popped": popped ? FUObjectReference(popped) : NSNull.null,
                @"before": before ? FUObjectReference(before) : NSNull.null,
                @"after": after ? FUObjectReference(after) : NSNull.null,
                @"depth_before": @(depthBefore),
                @"depth_after": @(navigation.viewControllers.count),
            }, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"navigation_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleUIDismiss(NSString *requestID, NSDictionary *request) {
    BOOL animated = [request[@"animated"] boolValue];
    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIWindow *window = FUKeyWindow();
        UIViewController *root = window.rootViewController;
        if (!root) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"nothing_to_dismiss", @"The key window has no presented view controller."));
            return;
        }

        UIViewController *presentation = nil;
        UIViewController *before = FUEffectiveViewController(root, &presentation);
        if (!presentation) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"nothing_to_dismiss", @"No presented view controller is active in the target app."));
            return;
        }
        UIViewController *presenter = presentation.presentingViewController;

        @try {
            [presentation dismissViewControllerAnimated:animated completion:nil];
            UIViewController *after = FUEffectiveViewController(root, nil);
            response = FUResponse(requestID, YES, @{
                @"action": @"dismiss",
                @"dismissed": @YES,
                @"animated": @(animated),
                @"presentation": FUObjectReference(presentation),
                @"presenter": presenter ? FUObjectReference(presenter) : NSNull.null,
                @"before": before ? FUObjectReference(before) : NSNull.null,
                @"after": after ? FUObjectReference(after) : NSNull.null,
            }, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"dismiss_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

static NSDictionary *FUViewNode(UIView *view, NSUInteger depth, NSUInteger maxDepth, NSUInteger maxChildren, NSUInteger maxNodes, NSUInteger *nodeCount, BOOL *truncated) {
    (*nodeCount)++;
    NSMutableDictionary *node = [FUObjectReference(view) mutableCopy];
    node[@"frame"] = FURectJSON(view.frame);
    node[@"bounds"] = FURectJSON(view.bounds);
    node[@"hidden"] = @(view.hidden);
    node[@"alpha"] = FUJSONFloatingNumber(view.alpha);
    node[@"user_interaction_enabled"] = @(view.userInteractionEnabled);
    node[@"child_count"] = @(view.subviews.count);

    if (view.accessibilityIdentifier.length) {
        node[@"accessibility_identifier"] = view.accessibilityIdentifier;
    }
    if (view.accessibilityLabel.length) {
        node[@"accessibility_label"] = FUTruncatedString(view.accessibilityLabel, 512);
    }
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = ((UILabel *)view).text;
        if (text) node[@"text"] = FUTruncatedString(text, 1024);
    } else if ([view isKindOfClass:[UITextField class]]) {
        NSString *text = ((UITextField *)view).text;
        if (text) node[@"text"] = FUTruncatedString(text, 1024);
    } else if ([view isKindOfClass:[UITextView class]]) {
        NSString *text = ((UITextView *)view).text;
        if (text) node[@"text"] = FUTruncatedString(text, 1024);
    } else if ([view isKindOfClass:[UIButton class]]) {
        NSString *title = [((UIButton *)view) titleForState:UIControlStateNormal];
        if (title) node[@"title"] = FUTruncatedString(title, 1024);
    }

    UIResponder *responder = view.nextResponder;
    if ([responder isKindOfClass:[UIViewController class]]) {
        node[@"view_controller"] = FUObjectReference(responder);
    }

    if (depth >= maxDepth || *nodeCount >= maxNodes) {
        if (view.subviews.count > 0) {
            node[@"children_truncated"] = @YES;
            *truncated = YES;
        }
        return node;
    }

    NSMutableArray *children = [NSMutableArray array];
    NSUInteger childLimit = MIN(view.subviews.count, maxChildren);
    for (NSUInteger index = 0; index < childLimit; index++) {
        if (*nodeCount >= maxNodes) {
            *truncated = YES;
            break;
        }
        [children addObject:FUViewNode(view.subviews[index], depth + 1, maxDepth, maxChildren, maxNodes, nodeCount, truncated)];
    }
    if (view.subviews.count > childLimit || children.count < childLimit) {
        node[@"children_truncated"] = @YES;
        *truncated = YES;
    }
    node[@"children"] = children;
    return node;
}

NSDictionary *FUHandleUIHierarchy(NSString *requestID, NSDictionary *request) {
    NSString *rootHandle = [request[@"root"] isKindOfClass:[NSString class]] ? request[@"root"] : nil;
    NSUInteger maxDepth = [request[@"max_depth"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"max_depth"] unsignedIntegerValue] : 8;
    NSUInteger maxChildren = [request[@"max_children"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"max_children"] unsignedIntegerValue] : 50;
    NSUInteger maxNodes = [request[@"max_nodes"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"max_nodes"] unsignedIntegerValue] : 500;
    maxDepth = MIN(MAX(maxDepth, (NSUInteger)1), (NSUInteger)32);
    maxChildren = MIN(MAX(maxChildren, (NSUInteger)1), (NSUInteger)200);
    maxNodes = MIN(MAX(maxNodes, (NSUInteger)1), (NSUInteger)5000);

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        id rootObject = rootHandle.length ? FUObjectForHandle(rootHandle) : FUKeyWindow();
        if (rootHandle.length && !rootObject) {
            response = FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(rootHandle, @"The requested root handle is unknown or the object has expired."));
            return;
        }

        UIView *rootView = nil;
        if ([rootObject isKindOfClass:[UIViewController class]]) {
            rootView = ((UIViewController *)rootObject).view;
        } else if ([rootObject isKindOfClass:[UIView class]]) {
            rootView = rootObject;
        }
        if (!rootView) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_root", @"ui.hierarchy requires a UIView or UIViewController handle, or an available key window."));
            return;
        }

        NSUInteger nodeCount = 0;
        BOOL truncated = NO;
        NSDictionary *tree = FUViewNode(rootView, 0, maxDepth, maxChildren, maxNodes, &nodeCount, &truncated);
        response = FUResponse(requestID, YES, @{
            @"root": tree,
            @"node_count": @(nodeCount),
            @"truncated": @(truncated),
            @"limits": @{
                @"max_depth": @(maxDepth),
                @"max_children": @(maxChildren),
                @"max_nodes": @(maxNodes),
            },
        }, nil);
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return response;
}

static NSString *FUViewTextValue(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) {
        return ((UILabel *)view).text ?: @"";
    }
    if ([view isKindOfClass:[UITextField class]]) {
        return ((UITextField *)view).text ?: @"";
    }
    if ([view isKindOfClass:[UITextView class]]) {
        return ((UITextView *)view).text ?: @"";
    }
    if ([view isKindOfClass:[UIButton class]]) {
        return [((UIButton *)view) titleForState:UIControlStateNormal] ?: @"";
    }
    return @"";
}

NSArray<NSNumber *> *FUViewPathFromRoot(UIView *view, UIView *rootView) {
    if (!view || !rootView) {
        return nil;
    }
    if (view == rootView) {
        return @[];
    }

    NSMutableArray<NSNumber *> *reversePath = [NSMutableArray array];
    UIView *cursor = view;
    while (cursor && cursor != rootView) {
        UIView *parent = cursor.superview;
        if (!parent) {
            return nil;
        }
        NSUInteger index = [parent.subviews indexOfObjectIdenticalTo:cursor];
        if (index == NSNotFound) {
            return nil;
        }
        [reversePath addObject:@(index)];
        cursor = parent;
    }
    if (cursor != rootView) {
        return nil;
    }
    return reversePath.reverseObjectEnumerator.allObjects;
}

NSDictionary *FUStableSelectorForView(UIView *view, UIView *rootView) {
    NSArray<NSNumber *> *path = FUViewPathFromRoot(view, rootView);
    NSMutableDictionary *selector = [@{
        @"version": @1,
        @"class": FUClassName(view),
        @"path": path ?: @[],
    } mutableCopy];

    if (view.accessibilityIdentifier.length) {
        selector[@"strategy"] = @"accessibility_identifier";
        selector[@"value"] = FUTruncatedString(view.accessibilityIdentifier, 512);
    } else if (view.accessibilityLabel.length) {
        selector[@"strategy"] = @"accessibility_label";
        selector[@"value"] = FUTruncatedString(view.accessibilityLabel, 512);
    } else {
        NSString *text = FUViewTextValue(view);
        if (text.length) {
            selector[@"strategy"] = @"text";
            selector[@"value"] = FUTruncatedString(text, 1024);
        } else {
            selector[@"strategy"] = @"path";
        }
    }
    return selector;
}

static UIView *FUViewAtStablePath(UIView *rootView, NSArray *path) {
    if (!rootView || ![path isKindOfClass:[NSArray class]]) {
        return nil;
    }
    UIView *cursor = rootView;
    for (id component in path) {
        if (![component isKindOfClass:[NSNumber class]]) {
            return nil;
        }
        NSInteger index = [component integerValue];
        if (index < 0 || (NSUInteger)index >= cursor.subviews.count) {
            return nil;
        }
        cursor = cursor.subviews[(NSUInteger)index];
    }
    return cursor;
}

static NSString *FUStableSelectorValueForView(UIView *view, NSString *strategy) {
    if ([strategy isEqualToString:@"accessibility_identifier"]) {
        return FUTruncatedString(view.accessibilityIdentifier ?: @"", 512);
    }
    if ([strategy isEqualToString:@"accessibility_label"]) {
        return FUTruncatedString(view.accessibilityLabel ?: @"", 512);
    }
    if ([strategy isEqualToString:@"text"]) {
        return FUTruncatedString(FUViewTextValue(view), 1024);
    }
    return @"";
}

static BOOL FUContainsCaseInsensitive(NSString *value, NSString *needle) {
    if (needle.length == 0) {
        return YES;
    }
    if (value.length == 0) {
        return NO;
    }
    return [value rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *FUSnapshotRole(UIView *view);
static NSArray<NSString *> *FUSnapshotActions(UIView *view);

static NSDictionary *FUViewSearchEntry(UIView *view, UIView *rootView) {
    NSMutableDictionary *entry = [FUObjectReference(view) mutableCopy];
    entry[@"role"] = FUSnapshotRole(view);
    entry[@"frame"] = FURectJSON(view.frame);
    if (rootView) {
        CGRect rootFrame = (view == rootView) ? rootView.bounds : [view convertRect:view.bounds toView:rootView];
        entry[@"root_frame"] = FURectJSON(rootFrame);
    }
    entry[@"bounds"] = FURectJSON(view.bounds);
    entry[@"hidden"] = @(view.hidden);
    entry[@"alpha"] = FUJSONFloatingNumber(view.alpha);
    entry[@"user_interaction_enabled"] = @(view.userInteractionEnabled);
    entry[@"child_count"] = @(view.subviews.count);
    entry[@"accessibility_traits"] = @((unsigned long long)view.accessibilityTraits);
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        entry[@"enabled"] = @(control.enabled);
        entry[@"selected"] = @(control.selected);
    }
    NSArray<NSString *> *actions = FUSnapshotActions(view);
    if (actions.count) entry[@"actions"] = actions;
    NSString *text = FUViewTextValue(view);
    if (text.length) entry[@"text"] = FUTruncatedString(text, 1024);
    if (view.accessibilityIdentifier.length) entry[@"accessibility_identifier"] = FUTruncatedString(view.accessibilityIdentifier, 512);
    if (view.accessibilityLabel.length) entry[@"accessibility_label"] = FUTruncatedString(view.accessibilityLabel, 512);
    entry[@"selector"] = FUStableSelectorForView(view, rootView);
    UIResponder *responder = view.nextResponder;
    if ([responder isKindOfClass:[UIViewController class]]) {
        entry[@"view_controller"] = FUObjectReference(responder);
    }
    return entry;
}

static UIView *FUFirstResponderInView(UIView *rootView) {
    if (!rootView) {
        return nil;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:rootView];
    NSUInteger cursor = 0;
    while (cursor < queue.count) {
        UIView *view = queue[cursor++];
        if (view.isFirstResponder) {
            return view;
        }
        for (UIView *child in view.subviews) {
            [queue addObject:child];
        }
    }
    return nil;
}

NSDictionary *FUHandleUIFirstResponder(NSString *requestID) {
    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIWindow *window = FUKeyWindow();
        if (!window) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"window_not_found", @"No UIWindow is currently available in the target process."));
            return;
        }
        UIView *responder = FUFirstResponderInView(window);
        response = FUResponse(requestID, YES, @{
            @"found": responder ? @YES : @NO,
            @"responder": responder ? FUViewSearchEntry(responder, window) : NSNull.null,
            @"window": FUWindowJSON(window),
        }, nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleUIDismissKeyboard(NSString *requestID) {
    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIWindow *window = FUKeyWindow();
        if (!window) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"window_not_found", @"No UIWindow is currently available in the target process."));
            return;
        }
        UIView *responder = FUFirstResponderInView(window);
        if (!responder) {
            response = FUResponse(requestID, YES, @{
                @"found": @NO,
                @"dismissed": @NO,
                @"resigned": @NO,
                @"no_op": @YES,
                @"before": NSNull.null,
                @"after": NSNull.null,
                @"window": FUWindowJSON(window),
            }, nil);
            return;
        }

        NSDictionary *before = FUViewSearchEntry(responder, window);
        @try {
            BOOL resignResult = [responder resignFirstResponder];
            if (!resignResult || responder.isFirstResponder) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"keyboard_dismiss_failed", @"The current first responder refused to resign."));
                return;
            }

            UIView *after = FUFirstResponderInView(window);
            if (after) {
                [window endEditing:YES];
                after = FUFirstResponderInView(window);
            }
            if (after) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"keyboard_dismiss_failed", @"A first responder remained active after ending editing in the key window."));
                return;
            }

            response = FUResponse(requestID, YES, @{
                @"found": @YES,
                @"dismissed": @YES,
                @"resigned": @YES,
                @"no_op": @NO,
                @"before": before,
                @"after": NSNull.null,
                @"window": FUWindowJSON(window),
            }, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"keyboard_dismiss_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

static NSString *FUAlertControllerStyleString(UIAlertControllerStyle style) {
    return style == UIAlertControllerStyleActionSheet ? @"action_sheet" : @"alert";
}

static NSString *FUAlertActionStyleString(UIAlertActionStyle style) {
    switch (style) {
        case UIAlertActionStyleCancel:
            return @"cancel";
        case UIAlertActionStyleDestructive:
            return @"destructive";
        case UIAlertActionStyleDefault:
        default:
            return @"default";
    }
}

static UIAlertController *FUActiveAlertController(UIWindow *window) {
    UIViewController *root = window.rootViewController;
    if (!root) {
        return nil;
    }
    UIViewController *effective = FUEffectiveViewController(root, nil);
    return [effective isKindOfClass:[UIAlertController class]] ? (UIAlertController *)effective : nil;
}

static NSDictionary *FUAlertActionJSON(UIAlertAction *action, NSUInteger index, UIAlertAction *preferredAction) {
    NSMutableDictionary *entry = [FUObjectReference(action) mutableCopy];
    entry[@"index"] = @(index);
    entry[@"title"] = action.title ?: NSNull.null;
    entry[@"style"] = FUAlertActionStyleString(action.style);
    entry[@"enabled"] = action.enabled ? @YES : @NO;
    entry[@"preferred"] = action == preferredAction ? @YES : @NO;
    return entry;
}

static NSDictionary *FUAlertJSON(UIAlertController *alert, UIWindow *window) {
    NSMutableArray *actions = [NSMutableArray arrayWithCapacity:alert.actions.count];
    for (NSUInteger index = 0; index < alert.actions.count; index++) {
        [actions addObject:FUAlertActionJSON(alert.actions[index], index, alert.preferredAction)];
    }

    NSMutableArray *textFields = [NSMutableArray arrayWithCapacity:alert.textFields.count];
    for (UITextField *textField in alert.textFields ?: @[]) {
        [textFields addObject:FUViewSearchEntry(textField, window)];
    }

    NSInteger preferredIndex = NSNotFound;
    if (alert.preferredAction) {
        preferredIndex = [alert.actions indexOfObjectIdenticalTo:alert.preferredAction];
    }

    return @{
        @"found": @YES,
        @"style": FUAlertControllerStyleString(alert.preferredStyle),
        @"title": alert.title ?: NSNull.null,
        @"message": alert.message ?: NSNull.null,
        @"controller": FUObjectReference(alert),
        @"actions": actions,
        @"text_fields": textFields,
        @"preferred_action_index": preferredIndex == NSNotFound ? NSNull.null : @(preferredIndex),
        @"window": FUWindowJSON(window),
    };
}

NSDictionary *FUHandleUIAlert(NSString *requestID) {
    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIWindow *window = FUKeyWindow();
        if (!window) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"window_not_found", @"No UIWindow is currently available in the target process."));
            return;
        }
        UIAlertController *alert = FUActiveAlertController(window);
        if (!alert) {
            response = FUResponse(requestID, YES, @{
                @"found": @NO,
                @"style": NSNull.null,
                @"title": NSNull.null,
                @"message": NSNull.null,
                @"controller": NSNull.null,
                @"actions": @[],
                @"text_fields": @[],
                @"preferred_action_index": NSNull.null,
                @"window": FUWindowJSON(window),
            }, nil);
            return;
        }
        response = FUResponse(requestID, YES, FUAlertJSON(alert, window), nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

static UIView *FUAlertActivatableAncestor(UIView *view, UIView *alertRoot) {
    SEL invokeInterfaceAction = NSSelectorFromString(@"invokeInterfaceAction");
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UIControl class]]) {
            UIControl *control = (UIControl *)candidate;
            if (control.enabled && !control.hidden && control.alpha > 0.01) {
                return candidate;
            }
        }
        if (candidate.isAccessibilityElement &&
            (candidate.accessibilityTraits & UIAccessibilityTraitButton) != 0 &&
            !candidate.hidden && candidate.alpha > 0.01) {
            return candidate;
        }
        if ([candidate respondsToSelector:invokeInterfaceAction] &&
            !candidate.hidden && candidate.alpha > 0.01) {
            return candidate;
        }
        if (candidate == alertRoot) {
            break;
        }
    }
    return nil;
}

static NSArray<UIView *> *FUAlertActionViews(UIAlertController *alert, NSString *title) {
    if (title.length == 0 || !alert.view) {
        return @[];
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:alert.view];
    NSMutableArray<UIView *> *matches = [NSMutableArray array];
    NSHashTable<UIView *> *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSUInteger cursor = 0;
    while (cursor < queue.count) {
        UIView *view = queue[cursor++];
        NSString *text = FUViewTextValue(view);
        NSString *label = view.accessibilityLabel;
        if ((text.length && [text isEqualToString:title]) || (label.length && [label isEqualToString:title])) {
            UIView *activatable = FUAlertActivatableAncestor(view, alert.view);
            if (activatable && ![seen containsObject:activatable]) {
                [seen addObject:activatable];
                [matches addObject:activatable];
            }
        }
        for (UIView *child in view.subviews) {
            [queue addObject:child];
        }
    }
    return matches;
}

static BOOL FUInvokeVisibleInterfaceAction(UIView *actionView, UIView *alertRoot) {
    if (!actionView) {
        return NO;
    }

    SEL actionSelector = NSSelectorFromString(@"action");
    SEL invokeHandler = NSSelectorFromString(@"_invokeHandlerWithCompletionBlock:");
    Class interfaceActionClass = NSClassFromString(@"UIInterfaceAction");

    // Older UIKit alert action views are accessibility buttons but refuse
    // accessibilityActivate. Their immediate visible representation owns a
    // UIInterfaceAction which is what UIKit's selection-tracking controller
    // ultimately invokes. Start at the superview so we never fall through to
    // _UIAlertControllerActionView.action, which returns UIAlertAction.
    for (UIView *candidate = actionView.superview; candidate; candidate = candidate.superview) {
        if (![candidate isHidden] && candidate.alpha > 0.01 && [candidate respondsToSelector:actionSelector]) {
            id interfaceAction = ((id (*)(id, SEL))objc_msgSend)(candidate, actionSelector);
            BOOL isInterfaceAction = interfaceActionClass &&
                interfaceAction &&
                [interfaceAction isKindOfClass:interfaceActionClass];
            if (isInterfaceAction && [interfaceAction respondsToSelector:invokeHandler]) {
                // UIKit invokes this completion after the alert dismissal
                // transition. iOS 16 does not tolerate a nil block here.
                void (^completion)(void) = ^{};
                ((void (*)(id, SEL, id))objc_msgSend)(interfaceAction, invokeHandler, completion);
                return YES;
            }
        }
        if (candidate == alertRoot) {
            break;
        }
    }
    return NO;
}

static BOOL FUAlertControllerWasDismissed(UIAlertController *alert) {
    BOOL (^isDismissed)(void) = ^BOOL{
        return !alert.presentingViewController || !alert.view.window;
    };

    if (NSThread.isMainThread) {
        if (isDismissed()) {
            return YES;
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
        while (!isDismissed() && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        return isDismissed();
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
    while (deadline.timeIntervalSinceNow > 0) {
        __block BOOL dismissed = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            dismissed = isDismissed();
        });
        if (dismissed) {
            return YES;
        }
        [NSThread sleepForTimeInterval:0.01];
    }

    __block BOOL dismissed = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        dismissed = isDismissed();
    });
    return dismissed;
}

NSDictionary *FUHandleUIAlertAction(NSString *requestID, NSDictionary *request) {
    id indexValue = request[@"index"];
    id titleValue = request[@"title"];
    BOOL hasIndex = indexValue != nil;
    BOOL hasTitle = titleValue != nil;
    if (hasIndex == hasTitle) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"ui.alert_action requires exactly one of index or title."));
    }

    __block NSInteger requestedIndex = NSNotFound;
    __block NSString *requestedTitle = nil;
    if (hasIndex) {
        if (![indexValue isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)indexValue) == CFBooleanGetTypeID()) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"index must be a non-negative integer."));
        }
        double rawIndex = [indexValue doubleValue];
        if (!isfinite(rawIndex) || rawIndex < 0 || rawIndex != floor(rawIndex) || [indexValue compare:@(NSIntegerMax)] == NSOrderedDescending) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"index must be a non-negative integer."));
        }
        requestedIndex = (NSInteger)rawIndex;
    } else {
        if (![titleValue isKindOfClass:[NSString class]] || [titleValue length] == 0) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"title must be a non-empty string."));
        }
        requestedTitle = titleValue;
    }

    __block NSDictionary *response = nil;
    __block UIAlertController *activatedAlert = nil;
    __block NSDictionary *activatedResult = nil;
    void (^work)(void) = ^{
        UIWindow *window = FUKeyWindow();
        if (!window) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"window_not_found", @"No UIWindow is currently available in the target process."));
            return;
        }
        UIAlertController *alert = FUActiveAlertController(window);
        if (!alert) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"no_alert", @"No UIAlertController is currently presented in the target app."));
            return;
        }

        NSUInteger selectedIndex = NSNotFound;
        if (hasIndex) {
            if ((NSUInteger)requestedIndex >= alert.actions.count) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"action_not_found", @"The requested alert action index is out of range."));
                return;
            }
            selectedIndex = (NSUInteger)requestedIndex;
        } else {
            NSMutableArray<NSNumber *> *matchingIndexes = [NSMutableArray array];
            for (NSUInteger index = 0; index < alert.actions.count; index++) {
                NSString *title = alert.actions[index].title;
                if (title && [title isEqualToString:requestedTitle]) {
                    [matchingIndexes addObject:@(index)];
                }
            }
            if (matchingIndexes.count == 0) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"action_not_found", @"No alert action has the requested title."));
                return;
            }
            if (matchingIndexes.count > 1) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"action_ambiguous", @"Multiple alert actions have the requested title; select by index instead."));
                return;
            }
            selectedIndex = matchingIndexes.firstObject.unsignedIntegerValue;
        }

        UIAlertAction *action = alert.actions[selectedIndex];
        if (!action.enabled) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"action_disabled", @"The requested alert action is disabled."));
            return;
        }
        NSString *actionTitle = action.title ?: @"";
        if (actionTitle.length == 0) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"alert_action_failed", @"The requested alert action has no visible title to map to UIKit."));
            return;
        }

        NSArray<UIView *> *actionViews = FUAlertActionViews(alert, actionTitle);
        NSUInteger sameTitleOrdinal = 0;
        for (NSUInteger index = 0; index < selectedIndex; index++) {
            if ([alert.actions[index].title isEqualToString:actionTitle]) {
                sameTitleOrdinal++;
            }
        }
        if (sameTitleOrdinal >= actionViews.count) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"alert_action_failed", @"Could not map the requested UIAlertAction to a visible UIKit control."));
            return;
        }

        UIView *actionView = actionViews[sameTitleOrdinal];
        NSString *strategy = nil;
        BOOL activated = NO;
        @try {
            if ([actionView accessibilityActivate]) {
                activated = YES;
                strategy = @"accessibility";
            } else if ([actionView isKindOfClass:[UIControl class]]) {
                [(UIControl *)actionView sendActionsForControlEvents:UIControlEventTouchUpInside];
                activated = YES;
                strategy = @"control_touch_up_inside";
            } else {
                SEL invokeInterfaceAction = NSSelectorFromString(@"invokeInterfaceAction");
                if ([actionView respondsToSelector:invokeInterfaceAction]) {
                    ((void (*)(id, SEL))objc_msgSend)(actionView, invokeInterfaceAction);
                    activated = YES;
                    strategy = @"interface_action";
                } else if (FUInvokeVisibleInterfaceAction(actionView, alert.view)) {
                    activated = YES;
                    strategy = @"interface_action_handler";
                }
            }
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"alert_action_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
            return;
        }
        if (!activated) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"alert_action_failed", @"The visible alert action control did not accept activation."));
            return;
        }

        activatedAlert = alert;
        activatedResult = @{
            @"selected": FUAlertActionJSON(action, selectedIndex, alert.preferredAction),
            @"strategy": strategy,
            @"activated": @YES,
        };
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    if (response) {
        return response;
    }
    if (!activatedAlert || !activatedResult) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"alert_action_failed", @"The alert action activation did not produce a result."));
    }

    BOOL dismissed = FUAlertControllerWasDismissed(activatedAlert);
    if (!dismissed) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"alert_action_failed", @"The alert action was activated but the original UIAlertController remained presented."));
    }
    NSMutableDictionary *result = [activatedResult mutableCopy];
    result[@"dismissed"] = @YES;
    return FUResponse(requestID, YES, result, nil);
}

NSDictionary *FUHandleUIFind(NSString *requestID, NSDictionary *request) {
    NSString *rootHandle = [request[@"root"] isKindOfClass:[NSString class]] ? request[@"root"] : nil;
    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    NSString *classFilter = [request[@"class"] isKindOfClass:[NSString class]] ? request[@"class"] : @"";
    NSString *textFilter = [request[@"text"] isKindOfClass:[NSString class]] ? request[@"text"] : @"";
    NSString *identifierFilter = [request[@"accessibility_identifier"] isKindOfClass:[NSString class]] ? request[@"accessibility_identifier"] : @"";
    NSString *labelFilter = [request[@"accessibility_label"] isKindOfClass:[NSString class]] ? request[@"accessibility_label"] : @"";
    NSInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(integerValue)] ? [request[@"limit"] integerValue] : 100;
    NSInteger requestedMaxNodes = [request[@"max_nodes"] respondsToSelector:@selector(integerValue)] ? [request[@"max_nodes"] integerValue] : 5000;
    if (requestedLimit <= 0 || requestedMaxNodes <= 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_search_bounds", @"limit and max_nodes must be greater than zero."));
    }
    NSUInteger limit = MIN((NSUInteger)requestedLimit, (NSUInteger)500);
    NSUInteger maxNodes = MIN((NSUInteger)requestedMaxNodes, (NSUInteger)10000);
    BOOL includeHidden = [request[@"include_hidden"] boolValue];

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        id rootObject = rootHandle.length ? FUObjectForHandle(rootHandle) : FUKeyWindow();
        if (rootHandle.length && !rootObject) {
            response = FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(rootHandle, @"The requested root handle is unknown or the object has expired."));
            return;
        }

        UIView *rootView = nil;
        if ([rootObject isKindOfClass:[UIViewController class]]) {
            rootView = ((UIViewController *)rootObject).view;
        } else if ([rootObject isKindOfClass:[UIView class]]) {
            rootView = rootObject;
        }
        if (!rootView) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_root", @"ui.find root must resolve to a UIView or UIViewController."));
            return;
        }

        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:rootView];
        NSMutableArray *matches = [NSMutableArray array];
        NSUInteger cursor = 0;
        NSUInteger scanned = 0;
        BOOL truncated = NO;

        while (cursor < queue.count && scanned < maxNodes && matches.count < limit) {
            UIView *view = queue[cursor++];
            scanned++;

            NSString *className = FUClassName(view);
            NSString *text = FUViewTextValue(view);
            NSString *identifier = view.accessibilityIdentifier ?: @"";
            NSString *label = view.accessibilityLabel ?: @"";
            BOOL visibleEnough = includeHidden || (!view.hidden && view.alpha > 0.0);
            BOOL queryMatch = query.length == 0 ||
                FUContainsCaseInsensitive(className, query) ||
                FUContainsCaseInsensitive(text, query) ||
                FUContainsCaseInsensitive(identifier, query) ||
                FUContainsCaseInsensitive(label, query);
            BOOL matchesFilters = visibleEnough &&
                queryMatch &&
                FUContainsCaseInsensitive(className, classFilter) &&
                FUContainsCaseInsensitive(text, textFilter) &&
                FUContainsCaseInsensitive(identifier, identifierFilter) &&
                FUContainsCaseInsensitive(label, labelFilter);
            if (matchesFilters) {
                [matches addObject:FUViewSearchEntry(view, rootView)];
            }

            for (UIView *child in view.subviews) {
                [queue addObject:child];
            }
        }

        if (cursor < queue.count || scanned >= maxNodes) {
            truncated = YES;
        }
        response = FUResponse(requestID, YES, @{
            @"root": FUObjectReference(rootView),
            @"matches": matches,
            @"count": @(matches.count),
            @"scanned": @(scanned),
            @"limit": @(limit),
            @"max_nodes": @(maxNodes),
            @"truncated": @(truncated),
            @"include_hidden": @(includeHidden),
        }, nil);
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return response;
}

NSDictionary *FUHandleUIResolve(NSString *requestID, NSDictionary *request) {
    NSDictionary *selector = [request[@"selector"] isKindOfClass:[NSDictionary class]] ? request[@"selector"] : nil;
    if (!selector) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_selector", @"ui.resolve requires a selector object returned by ui.find or ui.snapshot."));
    }

    NSNumber *version = [selector[@"version"] isKindOfClass:[NSNumber class]] ? selector[@"version"] : nil;
    NSString *strategy = [selector[@"strategy"] isKindOfClass:[NSString class]] ? selector[@"strategy"] : @"";
    NSString *className = [selector[@"class"] isKindOfClass:[NSString class]] ? selector[@"class"] : @"";
    NSString *value = [selector[@"value"] isKindOfClass:[NSString class]] ? selector[@"value"] : nil;
    NSArray *path = [selector[@"path"] isKindOfClass:[NSArray class]] ? selector[@"path"] : nil;
    if (version.integerValue != 1 || className.length == 0 || ![@[@"accessibility_identifier", @"accessibility_label", @"text", @"path"] containsObject:strategy] || !path) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_selector", @"ui.resolve selector must contain version 1, class, strategy, and path."));
    }
    if (![strategy isEqualToString:@"path"] && value.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_selector", @"Semantic ui.resolve selectors require a non-empty value."));
    }

    NSInteger requestedMaxNodes = [request[@"max_nodes"] respondsToSelector:@selector(integerValue)] ? [request[@"max_nodes"] integerValue] : 5000;
    if (requestedMaxNodes <= 0 || requestedMaxNodes > 10000) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_search_bounds", @"ui.resolve max_nodes must be between 1 and 10000."));
    }
    BOOL includeHidden = [request[@"include_hidden"] boolValue];
    NSString *rootHandle = [request[@"root"] isKindOfClass:[NSString class]] ? request[@"root"] : nil;

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        id rootObject = rootHandle.length ? FUObjectForHandle(rootHandle) : FUKeyWindow();
        if (rootHandle.length && !rootObject) {
            response = FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(rootHandle, @"The requested root handle is unknown or the object has expired."));
            return;
        }
        UIView *rootView = nil;
        if ([rootObject isKindOfClass:[UIViewController class]]) rootView = ((UIViewController *)rootObject).view;
        else if ([rootObject isKindOfClass:[UIView class]]) rootView = rootObject;
        if (!rootView) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_root", @"ui.resolve root must resolve to a UIView or UIViewController."));
            return;
        }

        UIView *pathCandidate = FUViewAtStablePath(rootView, path);
        BOOL pathClassMatches = pathCandidate && [FUClassName(pathCandidate) isEqualToString:className];
        BOOL pathVisible = pathCandidate && (includeHidden || (!pathCandidate.hidden && pathCandidate.alpha > 0.0));
        UIView *resolved = nil;
        NSString *resolvedBy = nil;
        NSUInteger scanned = 0;
        NSUInteger candidateCount = 0;

        if ([strategy isEqualToString:@"path"]) {
            if (pathClassMatches && pathVisible) {
                resolved = pathCandidate;
                resolvedBy = @"path";
                candidateCount = 1;
            }
        } else {
            NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:rootView];
            NSMutableArray<UIView *> *candidates = [NSMutableArray array];
            NSUInteger cursor = 0;
            while (cursor < queue.count && scanned < (NSUInteger)requestedMaxNodes) {
                UIView *view = queue[cursor++];
                scanned++;
                BOOL visibleEnough = includeHidden || (!view.hidden && view.alpha > 0.0);
                if (visibleEnough &&
                    [FUClassName(view) isEqualToString:className] &&
                    [FUStableSelectorValueForView(view, strategy) isEqualToString:value]) {
                    [candidates addObject:view];
                }
                for (UIView *child in view.subviews) [queue addObject:child];
            }
            candidateCount = candidates.count;
            if (candidates.count == 1) {
                resolved = candidates.firstObject;
                resolvedBy = strategy;
            } else if (candidates.count > 1 && pathClassMatches && pathVisible && [candidates containsObject:pathCandidate]) {
                resolved = pathCandidate;
                resolvedBy = @"path_disambiguated";
            } else if (candidates.count == 0 && pathClassMatches && pathVisible) {
                resolved = pathCandidate;
                resolvedBy = @"path_fallback";
            } else if (candidates.count > 1) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"selector_ambiguous", [NSString stringWithFormat:@"ui.resolve matched %lu views and the selector path did not disambiguate them.", (unsigned long)candidates.count]));
                return;
            }
        }

        if (!resolved) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"selector_not_found", @"ui.resolve could not resolve the selector in the current UIKit hierarchy."));
            return;
        }
        response = FUResponse(requestID, YES, @{
            @"selector": selector,
            @"resolved_by": resolvedBy ?: strategy,
            @"candidate_count": @(candidateCount),
            @"scanned": @(scanned),
            @"match": FUViewSearchEntry(resolved, rootView),
        }, nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleUIWait(NSString *requestID, NSDictionary *request) {
    NSString *state = [request[@"state"] isKindOfClass:[NSString class]] ? [request[@"state"] lowercaseString] : @"exists";
    if (![@[@"exists", @"gone"] containsObject:state]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_state", @"ui.wait state must be exists or gone."));
    }

    NSInteger timeoutMS = [request[@"timeout_ms"] respondsToSelector:@selector(integerValue)] ? [request[@"timeout_ms"] integerValue] : 5000;
    NSInteger pollMS = [request[@"poll_interval_ms"] respondsToSelector:@selector(integerValue)] ? [request[@"poll_interval_ms"] integerValue] : 100;
    if (timeoutMS < 0 || timeoutMS > 30000 || pollMS < 25 || pollMS > 5000) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_wait_bounds", @"ui.wait requires timeout_ms between 0 and 30000 and poll_interval_ms between 25 and 5000."));
    }

    NSMutableDictionary *findRequest = [request mutableCopy];
    findRequest[@"limit"] = @1;
    [findRequest removeObjectForKey:@"state"];
    [findRequest removeObjectForKey:@"timeout_ms"];
    [findRequest removeObjectForKey:@"poll_interval_ms"];

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSUInteger polls = 0;
    while (YES) {
        polls++;
        NSDictionary *findResponse = FUHandleUIFind(requestID, findRequest);
        if (![findResponse[@"ok"] boolValue]) return findResponse;

        NSDictionary *findResult = [findResponse[@"result"] isKindOfClass:[NSDictionary class]] ? findResponse[@"result"] : @{};
        NSArray *matches = [findResult[@"matches"] isKindOfClass:[NSArray class]] ? findResult[@"matches"] : @[];
        BOOL found = matches.count > 0;
        BOOL satisfied = [state isEqualToString:@"exists"] ? found : !found;
        NSTimeInterval elapsedMS = (CFAbsoluteTimeGetCurrent() - started) * 1000.0;
        if (satisfied) {
            NSMutableDictionary *result = [@{
                @"state": state,
                @"satisfied": @YES,
                @"polls": @(polls),
                @"elapsed_ms": FUJSONFloatingNumber(elapsedMS),
                @"scanned": findResult[@"scanned"] ?: @0,
            } mutableCopy];
            if (found) result[@"match"] = matches.firstObject;
            return FUResponse(requestID, YES, result, nil);
        }

        if (elapsedMS >= timeoutMS) {
            return FUResponse(requestID, NO, nil, FUErrorInfo(@"wait_timeout", [NSString stringWithFormat:@"ui.wait timed out after %ld ms waiting for state '%@'.", (long)timeoutMS, state]));
        }
        [NSThread sleepForTimeInterval:MIN((NSTimeInterval)pollMS / 1000.0, MAX(0.0, ((NSTimeInterval)timeoutMS - elapsedMS) / 1000.0))];
    }
}

UIView *FUViewForActionHandle(NSString *handle) {
    id object = FUObjectForHandle(handle);
    if ([object isKindOfClass:[UIViewController class]]) {
        return ((UIViewController *)object).view;
    }
    return [object isKindOfClass:[UIView class]] ? object : nil;
}

static NSString *FUActionHandleFromRequest(NSString *requestID, NSDictionary *request, NSString **targetSource, NSString **resolvedBy, NSDictionary **errorResponse) {
    NSString *handle = [request[@"handle"] isKindOfClass:[NSString class]] ? request[@"handle"] : @"";
    NSDictionary *selector = [request[@"selector"] isKindOfClass:[NSDictionary class]] ? request[@"selector"] : nil;
    if (handle.length && selector) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_target", @"Provide either handle or selector, not both."));
        return nil;
    }
    if (handle.length) {
        id object = FUObjectForHandle(handle);
        if (!object) {
            if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(handle, @"The requested handle is unknown or the object has expired."));
            return nil;
        }
        if (targetSource) *targetSource = @"handle";
        return handle;
    }
    if (!selector) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_target", @"A process-scoped handle or stable selector is required."));
        return nil;
    }

    NSDictionary *resolveResponse = FUHandleUIResolve(requestID, request);
    if (![resolveResponse[@"ok"] boolValue]) {
        if (errorResponse) *errorResponse = resolveResponse;
        return nil;
    }
    NSDictionary *result = [resolveResponse[@"result"] isKindOfClass:[NSDictionary class]] ? resolveResponse[@"result"] : @{};
    NSDictionary *match = [result[@"match"] isKindOfClass:[NSDictionary class]] ? result[@"match"] : @{};
    NSString *resolvedHandle = [match[@"id"] isKindOfClass:[NSString class]] ? match[@"id"] : @"";
    if (resolvedHandle.length == 0) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"selector_not_found", @"The stable selector did not resolve to a live object handle."));
        return nil;
    }
    if (targetSource) *targetSource = @"selector";
    if (resolvedBy) *resolvedBy = [result[@"resolved_by"] isKindOfClass:[NSString class]] ? result[@"resolved_by"] : nil;
    return resolvedHandle;
}

NSDictionary *FUHandleUIActivate(NSString *requestID, NSDictionary *request) {
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    NSString *handle = FUActionHandleFromRequest(requestID, request, &targetSource, &resolvedBy, &targetError);
    if (!handle) return targetError;

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIView *view = FUViewForActionHandle(handle);
        if (!view) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_view", @"The requested handle is unknown, expired, or does not resolve to a UIView."));
            return;
        }

        BOOL activated = NO;
        NSString *strategy = @"accessibility";
        @try {
            if ([view isKindOfClass:[UITextField class]] || [view isKindOfClass:[UITextView class]]) {
                activated = [view becomeFirstResponder];
                strategy = @"first_responder";
            } else if ([view isKindOfClass:[UIControl class]]) {
                UIControl *control = (UIControl *)view;
                if (!control.enabled) {
                    response = FUResponse(requestID, NO, nil, FUErrorInfo(@"control_disabled", @"The requested UIControl is disabled."));
                    return;
                }
                [control sendActionsForControlEvents:UIControlEventTouchUpInside];
                activated = YES;
                strategy = @"control_touch_up_inside";
            } else {
                activated = [view accessibilityActivate];
            }
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"activation_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
            return;
        }

        if (!activated) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"activation_failed", @"The view did not accept UIControl or accessibility activation."));
            return;
        }
        NSMutableDictionary *result = [@{
            @"activated": @YES,
            @"strategy": strategy,
            @"view": FUObjectReference(view),
            @"target_source": targetSource ?: @"handle",
        } mutableCopy];
        if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
        response = FUResponse(requestID, YES, result, nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

static UIScrollView *FUOwningListViewForCell(UIView *cell) {
    BOOL tableCell = [cell isKindOfClass:[UITableViewCell class]];
    BOOL collectionCell = [cell isKindOfClass:[UICollectionViewCell class]];
    if (!tableCell && !collectionCell) return nil;

    UIView *cursor = cell.superview;
    while (cursor) {
        if (tableCell && [cursor isKindOfClass:[UITableView class]]) return (UITableView *)cursor;
        if (collectionCell && [cursor isKindOfClass:[UICollectionView class]]) return (UICollectionView *)cursor;
        cursor = cursor.superview;
    }
    return nil;
}

static NSIndexPath *FUIndexPathForListCell(UIView *cell, UIScrollView *owner) {
    if ([cell isKindOfClass:[UITableViewCell class]] && [owner isKindOfClass:[UITableView class]]) {
        return [(UITableView *)owner indexPathForCell:(UITableViewCell *)cell];
    }
    if ([cell isKindOfClass:[UICollectionViewCell class]] && [owner isKindOfClass:[UICollectionView class]]) {
        return [(UICollectionView *)owner indexPathForCell:(UICollectionViewCell *)cell];
    }
    return nil;
}

static BOOL FUListCellCanSelect(UIView *cell) {
    if (!cell.userInteractionEnabled) return NO;
    UIScrollView *owner = FUOwningListViewForCell(cell);
    if (!owner || !FUIndexPathForListCell(cell, owner)) return NO;
    if ([owner isKindOfClass:[UITableView class]]) {
        UITableView *table = (UITableView *)owner;
        return table.allowsSelection && (!table.editing || table.allowsSelectionDuringEditing);
    }
    if ([owner isKindOfClass:[UICollectionView class]]) {
        return ((UICollectionView *)owner).allowsSelection;
    }
    return NO;
}

NSDictionary *FUHandleUISelect(NSString *requestID, NSDictionary *request) {
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    NSString *handle = FUActionHandleFromRequest(requestID, request, &targetSource, &resolvedBy, &targetError);
    if (!handle) return targetError;

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIView *cell = FUViewForActionHandle(handle);
        if (!cell) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_view", @"The requested handle is unknown, expired, or does not resolve to a UIView."));
            return;
        }
        BOOL tableCell = [cell isKindOfClass:[UITableViewCell class]];
        BOOL collectionCell = [cell isKindOfClass:[UICollectionViewCell class]];
        if (!tableCell && !collectionCell) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_cell", @"ui.select requires a UITableViewCell or UICollectionViewCell."));
            return;
        }
        if (!cell.userInteractionEnabled) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"selection_disallowed", @"The requested cell has user interaction disabled."));
            return;
        }

        UIScrollView *owner = FUOwningListViewForCell(cell);
        if (!owner) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"owner_not_found", @"The requested cell is not attached to an owning UITableView or UICollectionView."));
            return;
        }
        NSIndexPath *indexPath = FUIndexPathForListCell(cell, owner);
        if (!indexPath) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"index_path_not_found", @"UIKit did not report an index path for the requested cell."));
            return;
        }

        NSString *kind = nil;
        NSString *strategy = nil;
        @try {
            if ([owner isKindOfClass:[UITableView class]]) {
                UITableView *table = (UITableView *)owner;
                if (!table.allowsSelection || (table.editing && !table.allowsSelectionDuringEditing)) {
                    response = FUResponse(requestID, NO, nil, FUErrorInfo(@"selection_disallowed", @"Selection is disabled for the owning UITableView."));
                    return;
                }
                SEL userSelectCell = NSSelectorFromString(@"_userSelectCell:");
                if (![table respondsToSelector:userSelectCell]) {
                    response = FUResponse(requestID, NO, nil, FUErrorInfo(@"selection_failed", @"The owning UITableView does not expose a supported UIKit user-selection path."));
                    return;
                }
                ((void (*)(id, SEL, id))objc_msgSend)(table, userSelectCell, cell);
                kind = @"table";
                strategy = @"table_user_select_cell";
            } else {
                UICollectionView *collection = (UICollectionView *)owner;
                if (!collection.allowsSelection) {
                    response = FUResponse(requestID, NO, nil, FUErrorInfo(@"selection_disallowed", @"Selection is disabled for the owning UICollectionView."));
                    return;
                }
                SEL userSelectAnimated = NSSelectorFromString(@"_userSelectItemAtIndexPath:animatedSelection:");
                SEL userSelect = NSSelectorFromString(@"_userSelectItemAtIndexPath:");
                if ([collection respondsToSelector:userSelectAnimated]) {
                    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(collection, userSelectAnimated, indexPath, NO);
                    strategy = @"collection_user_select_item_animated";
                } else if ([collection respondsToSelector:userSelect]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(collection, userSelect, indexPath);
                    strategy = @"collection_user_select_item";
                } else {
                    response = FUResponse(requestID, NO, nil, FUErrorInfo(@"selection_failed", @"The owning UICollectionView does not expose a supported UIKit user-selection path."));
                    return;
                }
                kind = @"collection";
            }
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"selection_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
            return;
        }

        NSMutableDictionary *result = [@{
            @"selected": @YES,
            @"kind": kind,
            @"index_path": @{
                @"section": @(indexPath.section),
                @"row": @(indexPath.row),
                @"item": @(indexPath.item),
            },
            @"cell": FUObjectReference(cell),
            @"owner": FUObjectReference(owner),
            @"strategy": strategy,
            @"target_source": targetSource ?: @"handle",
        } mutableCopy];
        if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
        response = FUResponse(requestID, YES, result, nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleUIHitTest(NSString *requestID, NSDictionary *request) {
    if (![request[@"x"] respondsToSelector:@selector(doubleValue)] || ![request[@"y"] respondsToSelector:@selector(doubleValue)]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"ui.hit_test requires numeric x and y coordinates."));
    }
    double x = [request[@"x"] doubleValue];
    double y = [request[@"y"] doubleValue];
    if (!isfinite(x) || !isfinite(y)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"ui.hit_test coordinates must be finite numbers."));
    }
    NSString *rootHandle = [request[@"root"] isKindOfClass:[NSString class]] ? request[@"root"] : nil;
    if (rootHandle.length && !FUObjectForHandle(rootHandle)) {
        return FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(rootHandle, @"The requested root handle is unknown or the object has expired."));
    }

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIView *rootView = rootHandle.length ? FUViewForActionHandle(rootHandle) : FUKeyWindow();
        if (!rootView) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_root", @"ui.hit_test requires a UIView/UIViewController root handle or an available key window."));
            return;
        }

        CGPoint point = CGPointMake((CGFloat)x, (CGFloat)y);
        if (!CGRectContainsPoint(rootView.bounds, point)) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"point_out_of_bounds", @"ui.hit_test coordinates are outside the selected root view bounds."));
            return;
        }

        UIView *hitView = [rootView hitTest:point withEvent:nil];
        if (!hitView) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"hit_test_failed", @"No UIKit view accepted the requested point."));
            return;
        }

        @try {
            NSMutableArray *ancestors = [NSMutableArray array];
            UIView *candidate = hitView;
            NSUInteger depth = 0;
            while (candidate && depth < 128) {
                NSMutableDictionary *entry = [FUViewSearchEntry(candidate, rootView) mutableCopy];
                entry[@"root_frame"] = FURectJSON([candidate convertRect:candidate.bounds toView:rootView]);
                entry[@"depth"] = @(depth);
                [ancestors addObject:entry];
                if (candidate == rootView) break;
                candidate = candidate.superview;
                depth += 1;
            }

            CGPoint pointInHit = [hitView convertPoint:point fromView:rootView];
            response = FUResponse(requestID, YES, @{
                @"point": FUPointJSON(point),
                @"point_in_hit": FUPointJSON(pointInHit),
                @"root": FUObjectReference(rootView),
                @"hit": ancestors.firstObject ?: FUObjectReference(hitView),
                @"ancestors": ancestors,
            }, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"hit_test_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleUITap(NSString *requestID, NSDictionary *request) {
    if (![request[@"x"] respondsToSelector:@selector(doubleValue)] || ![request[@"y"] respondsToSelector:@selector(doubleValue)]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"ui.tap requires numeric x and y coordinates."));
    }
    double x = [request[@"x"] doubleValue];
    double y = [request[@"y"] doubleValue];
    if (!isfinite(x) || !isfinite(y)) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"ui.tap coordinates must be finite numbers."));
    }
    NSString *rootHandle = [request[@"root"] isKindOfClass:[NSString class]] ? request[@"root"] : nil;
    if (rootHandle.length && !FUObjectForHandle(rootHandle)) {
        return FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(rootHandle, @"The requested root handle is unknown or the object has expired."));
    }

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIView *rootView = rootHandle.length ? FUViewForActionHandle(rootHandle) : FUKeyWindow();
        if (!rootView) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_root", @"ui.tap requires a UIView/UIViewController root handle or an available key window."));
            return;
        }

        CGPoint point = CGPointMake((CGFloat)x, (CGFloat)y);
        if (!CGRectContainsPoint(rootView.bounds, point)) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"point_out_of_bounds", @"ui.tap coordinates are outside the selected root view bounds."));
            return;
        }

        UIView *hitView = [rootView hitTest:point withEvent:nil];
        if (!hitView) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"hit_test_failed", @"No UIKit view accepted the requested point."));
            return;
        }

        UIView *activatedView = nil;
        NSString *strategy = nil;
        @try {
            for (UIView *candidate = hitView; candidate; candidate = candidate.superview) {
                if ([candidate isKindOfClass:[UITextField class]] || [candidate isKindOfClass:[UITextView class]]) {
                    if ([candidate becomeFirstResponder]) {
                        activatedView = candidate;
                        strategy = @"first_responder";
                        break;
                    }
                }

                if ([candidate isKindOfClass:[UIControl class]]) {
                    UIControl *control = (UIControl *)candidate;
                    if (control.enabled) {
                        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
                        activatedView = candidate;
                        strategy = @"control_touch_up_inside";
                        break;
                    }
                }

                BOOL tableCell = [candidate isKindOfClass:[UITableViewCell class]];
                BOOL collectionCell = [candidate isKindOfClass:[UICollectionViewCell class]];
                if ((tableCell || collectionCell) && FUListCellCanSelect(candidate)) {
                    UIScrollView *owner = FUOwningListViewForCell(candidate);
                    NSIndexPath *indexPath = FUIndexPathForListCell(candidate, owner);
                    if (tableCell && [owner isKindOfClass:[UITableView class]]) {
                        SEL userSelectCell = NSSelectorFromString(@"_userSelectCell:");
                        if ([owner respondsToSelector:userSelectCell]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(owner, userSelectCell, candidate);
                            activatedView = candidate;
                            strategy = @"table_user_select_cell";
                            break;
                        }
                    } else if (collectionCell && [owner isKindOfClass:[UICollectionView class]] && indexPath) {
                        SEL userSelectAnimated = NSSelectorFromString(@"_userSelectItemAtIndexPath:animatedSelection:");
                        SEL userSelect = NSSelectorFromString(@"_userSelectItemAtIndexPath:");
                        if ([owner respondsToSelector:userSelectAnimated]) {
                            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(owner, userSelectAnimated, indexPath, NO);
                            activatedView = candidate;
                            strategy = @"collection_user_select_item_animated";
                            break;
                        }
                        if ([owner respondsToSelector:userSelect]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(owner, userSelect, indexPath);
                            activatedView = candidate;
                            strategy = @"collection_user_select_item";
                            break;
                        }
                    }
                }

                if ([candidate accessibilityActivate]) {
                    activatedView = candidate;
                    strategy = @"accessibility";
                    break;
                }

                if (candidate == rootView) break;
            }
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"tap_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
            return;
        }

        if (!activatedView || !strategy.length) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"tap_failed", @"The hit-tested view hierarchy did not expose an actionable UIKit target."));
            return;
        }

        response = FUResponse(requestID, YES, @{
            @"tapped": @YES,
            @"point": FUPointJSON(point),
            @"strategy": strategy,
            @"root": FUObjectReference(rootView),
            @"hit_view": FUObjectReference(hitView),
            @"activated_view": FUObjectReference(activatedView),
        }, nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleUISetText(NSString *requestID, NSDictionary *request) {
    NSString *text = [request[@"text"] isKindOfClass:[NSString class]] ? request[@"text"] : nil;
    if (!text) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"ui.set_text requires a string text field."));
    }
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    NSString *handle = FUActionHandleFromRequest(requestID, request, &targetSource, &resolvedBy, &targetError);
    if (!handle) return targetError;
    BOOL submit = [request[@"submit"] boolValue];
    BOOL notify = request[@"notify"] ? [request[@"notify"] boolValue] : YES;

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        id object = FUObjectForHandle(handle);
        if (!object) {
            response = FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(handle, @"The requested handle is unknown or the object has expired."));
            return;
        }

        NSString *oldText = @"";
        NSString *kind = nil;
        if ([object isKindOfClass:[UITextField class]]) {
            oldText = ((UITextField *)object).text ?: @"";
            kind = @"text_field";
        } else if ([object isKindOfClass:[UITextView class]]) {
            oldText = ((UITextView *)object).text ?: @"";
            kind = @"text_view";
        } else if ([object isKindOfClass:[UISearchBar class]]) {
            oldText = ((UISearchBar *)object).text ?: @"";
            kind = @"search_bar";
        } else {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_view", @"ui.set_text currently supports UITextField, UITextView, and UISearchBar handles."));
            return;
        }

        NSString *experimentID = nil;
        NSDictionary *experimentError = nil;
        if (!FUExperimentPrepareMutation(request, &experimentID, &experimentError)) {
            response = FUResponse(requestID, NO, nil, experimentError);
            return;
        }

        @try {
            if ([kind isEqualToString:@"text_field"]) {
                UITextField *field = object;
                field.text = text;
                if (notify) [field sendActionsForControlEvents:UIControlEventEditingChanged];
                if (submit) [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
            } else if ([kind isEqualToString:@"text_view"]) {
                UITextView *textView = object;
                textView.text = text;
                if (notify) {
                    [NSNotificationCenter.defaultCenter postNotificationName:UITextViewTextDidChangeNotification object:textView];
                }
            } else {
                UISearchBar *searchBar = object;
                searchBar.text = text;
                id<UISearchBarDelegate> delegate = searchBar.delegate;
                if (notify && [delegate respondsToSelector:@selector(searchBar:textDidChange:)]) {
                    [delegate searchBar:searchBar textDidChange:text];
                }
                if (submit && [delegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) {
                    [delegate searchBarSearchButtonClicked:searchBar];
                }
            }
        } @catch (NSException *exception) {
            FUExperimentAbortMutation(experimentID);
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"text_update_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
            return;
        }

        NSMutableDictionary *result = [@{
            @"updated": @YES,
            @"kind": kind ?: @"",
            @"id": handle,
            @"old_text": FUTruncatedString(oldText, 2048),
            @"text": FUTruncatedString(text, 2048),
            @"submitted": @(submit),
            @"target_source": targetSource ?: @"handle",
        } mutableCopy];
        if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
        if (experimentID.length) {
            NSDictionary *undoRecord = @{
                @"mutation": @"ui.set_text",
                @"object": object,
                @"kind": kind,
                @"old_text": oldText,
            };
            if (!FUExperimentCommitMutation(experimentID, undoRecord, result, &experimentError)) {
                response = FUResponse(requestID, NO, nil, experimentError);
                return;
            }
        }
        response = FUResponse(requestID, YES, result, nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleUISetValue(NSString *requestID, NSDictionary *request) {
    id requestedValue = request[@"value"];
    if (![requestedValue isKindOfClass:[NSNumber class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"ui.set_value requires a boolean or numeric value."));
    }
    BOOL valueIsBoolean = CFGetTypeID((__bridge CFTypeRef)requestedValue) == CFBooleanGetTypeID();

    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    NSString *handle = FUActionHandleFromRequest(requestID, request, &targetSource, &resolvedBy, &targetError);
    if (!handle) return targetError;

    BOOL notify = request[@"notify"] ? [request[@"notify"] boolValue] : YES;
    BOOL animated = [request[@"animated"] boolValue];

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        id object = FUObjectForHandle(handle);
        if (!object) {
            response = FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(handle, @"The requested handle is unknown or the object has expired."));
            return;
        }
        if (![object isKindOfClass:[UIControl class]]) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_view", @"ui.set_value requires a supported UIControl handle."));
            return;
        }

        UIControl *control = object;
        if (!control.enabled) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"control_disabled", @"The requested UIControl is disabled."));
            return;
        }

        NSNumber *value = requestedValue;
        NSString *kind = nil;
        NSNumber *oldValue = nil;

        if ([control isKindOfClass:[UISwitch class]]) {
            if (!valueIsBoolean) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"UISwitch requires a boolean value."));
                return;
            }
            kind = @"switch";
            oldValue = @(((UISwitch *)control).isOn);
        } else if ([control isKindOfClass:[UISlider class]]) {
            if (valueIsBoolean) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"UISlider requires a numeric value."));
                return;
            }
            UISlider *slider = (UISlider *)control;
            double requested = value.doubleValue;
            if (!isfinite(requested)) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"ui.set_value requires a finite numeric value."));
                return;
            }
            if (requested < slider.minimumValue || requested > slider.maximumValue) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"value_out_of_range", [NSString stringWithFormat:@"UISlider value must be between %.17g and %.17g.", slider.minimumValue, slider.maximumValue]));
                return;
            }
            kind = @"slider";
            oldValue = @(slider.value);
        } else if ([control isKindOfClass:[UIStepper class]]) {
            if (valueIsBoolean) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"UIStepper requires a numeric value."));
                return;
            }
            UIStepper *stepper = (UIStepper *)control;
            double requested = value.doubleValue;
            if (!isfinite(requested)) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"ui.set_value requires a finite numeric value."));
                return;
            }
            if (requested < stepper.minimumValue || requested > stepper.maximumValue) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"value_out_of_range", [NSString stringWithFormat:@"UIStepper value must be between %.17g and %.17g.", stepper.minimumValue, stepper.maximumValue]));
                return;
            }
            kind = @"stepper";
            oldValue = @(stepper.value);
        } else if ([control isKindOfClass:[UISegmentedControl class]]) {
            if (valueIsBoolean) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"UISegmentedControl requires an integer selected-segment index."));
                return;
            }
            UISegmentedControl *segmented = (UISegmentedControl *)control;
            double requested = value.doubleValue;
            NSInteger index = value.integerValue;
            if (!isfinite(requested) || requested != (double)index) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"UISegmentedControl requires an integer selected-segment index."));
                return;
            }
            NSInteger upperBound = (NSInteger)segmented.numberOfSegments - 1;
            if (index < UISegmentedControlNoSegment || index > upperBound) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"value_out_of_range", [NSString stringWithFormat:@"UISegmentedControl index must be between %ld and %ld.", (long)UISegmentedControlNoSegment, (long)upperBound]));
                return;
            }
            kind = @"segmented_control";
            oldValue = @(segmented.selectedSegmentIndex);
        } else {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_view", @"ui.set_value supports UISwitch, UISlider, UIStepper, and UISegmentedControl."));
            return;
        }

        NSString *experimentID = nil;
        NSDictionary *experimentError = nil;
        if (!FUExperimentPrepareMutation(request, &experimentID, &experimentError)) {
            response = FUResponse(requestID, NO, nil, experimentError);
            return;
        }

        NSMutableDictionary *result = [@{
            @"updated": @YES,
            @"id": handle,
            @"notified": @(notify),
            @"animated": @(animated),
            @"target_source": targetSource ?: @"handle",
        } mutableCopy];

        @try {
            if ([control isKindOfClass:[UISwitch class]]) {
                UISwitch *toggle = (UISwitch *)control;
                BOOL after = value.boolValue;
                [toggle setOn:after animated:animated];
                if (notify) [toggle sendActionsForControlEvents:UIControlEventValueChanged];
                result[@"kind"] = @"switch";
                result[@"old_value"] = oldValue;
                result[@"value"] = @(toggle.isOn);
            } else if ([control isKindOfClass:[UISlider class]]) {
                UISlider *slider = (UISlider *)control;
                double requested = value.doubleValue;
                [slider setValue:(float)requested animated:animated];
                if (notify) [slider sendActionsForControlEvents:UIControlEventValueChanged];
                result[@"kind"] = @"slider";
                result[@"old_value"] = FUJSONFloatingNumber(oldValue.doubleValue);
                result[@"value"] = FUJSONFloatingNumber(slider.value);
                result[@"minimum_value"] = FUJSONFloatingNumber(slider.minimumValue);
                result[@"maximum_value"] = FUJSONFloatingNumber(slider.maximumValue);
            } else if ([control isKindOfClass:[UIStepper class]]) {
                UIStepper *stepper = (UIStepper *)control;
                double requested = value.doubleValue;
                stepper.value = requested;
                if (notify) [stepper sendActionsForControlEvents:UIControlEventValueChanged];
                result[@"kind"] = @"stepper";
                result[@"old_value"] = FUJSONFloatingNumber(oldValue.doubleValue);
                result[@"value"] = FUJSONFloatingNumber(stepper.value);
                result[@"minimum_value"] = FUJSONFloatingNumber(stepper.minimumValue);
                result[@"maximum_value"] = FUJSONFloatingNumber(stepper.maximumValue);
                result[@"step_value"] = FUJSONFloatingNumber(stepper.stepValue);
            } else if ([control isKindOfClass:[UISegmentedControl class]]) {
                UISegmentedControl *segmented = (UISegmentedControl *)control;
                NSInteger index = value.integerValue;
                segmented.selectedSegmentIndex = index;
                if (notify) [segmented sendActionsForControlEvents:UIControlEventValueChanged];
                result[@"kind"] = @"segmented_control";
                result[@"old_value"] = oldValue;
                result[@"value"] = @(segmented.selectedSegmentIndex);
                result[@"segment_count"] = @(segmented.numberOfSegments);
            }
        } @catch (NSException *exception) {
            FUExperimentAbortMutation(experimentID);
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"value_update_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
            return;
        }

        if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
        if (experimentID.length) {
            NSDictionary *undoRecord = @{
                @"mutation": @"ui.set_value",
                @"object": object,
                @"kind": kind,
                @"old_value": oldValue,
            };
            if (!FUExperimentCommitMutation(experimentID, undoRecord, result, &experimentError)) {
                response = FUResponse(requestID, NO, nil, experimentError);
                return;
            }
        }
        response = FUResponse(requestID, YES, result, nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

NSDictionary *FUHandleUIScroll(NSString *requestID, NSDictionary *request) {
    BOOL hasDX = [request[@"dx"] respondsToSelector:@selector(doubleValue)];
    BOOL hasDY = [request[@"dy"] respondsToSelector:@selector(doubleValue)];
    if (!hasDX && !hasDY) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_arguments", @"ui.scroll requires at least one of dx or dy."));
    }
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    NSString *handle = FUActionHandleFromRequest(requestID, request, &targetSource, &resolvedBy, &targetError);
    if (!handle) return targetError;
    CGFloat dx = hasDX ? [request[@"dx"] doubleValue] : 0.0;
    CGFloat dy = hasDY ? [request[@"dy"] doubleValue] : 0.0;
    BOOL animated = [request[@"animated"] boolValue];

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        id object = FUObjectForHandle(handle);
        if (!object) {
            response = FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(handle, @"The requested handle is unknown or the object has expired."));
            return;
        }
        if (![object isKindOfClass:[UIScrollView class]]) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_view", @"ui.scroll requires a UIScrollView handle."));
            return;
        }
        UIScrollView *scrollView = object;
        CGPoint before = scrollView.contentOffset;
        UIEdgeInsets insets = scrollView.adjustedContentInset;
        CGFloat minX = -insets.left;
        CGFloat minY = -insets.top;
        CGFloat maxX = MAX(minX, scrollView.contentSize.width - scrollView.bounds.size.width + insets.right);
        CGFloat maxY = MAX(minY, scrollView.contentSize.height - scrollView.bounds.size.height + insets.bottom);
        CGPoint after = CGPointMake(MIN(MAX(before.x + dx, minX), maxX), MIN(MAX(before.y + dy, minY), maxY));
        NSString *experimentID = nil;
        NSDictionary *experimentError = nil;
        if (!FUExperimentPrepareMutation(request, &experimentID, &experimentError)) {
            response = FUResponse(requestID, NO, nil, experimentError);
            return;
        }
        @try {
            [scrollView setContentOffset:after animated:animated];
        } @catch (NSException *exception) {
            FUExperimentAbortMutation(experimentID);
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"scroll_failed", FUTruncatedString(exception.reason ?: exception.name, 512)));
            return;
        }
        NSMutableDictionary *result = [@{
            @"scrolled": @YES,
            @"id": handle,
            @"before": FUPointJSON(before),
            @"after": FUPointJSON(after),
            @"content_size": FUSizeJSON(scrollView.contentSize),
            @"bounds": FURectJSON(scrollView.bounds),
            @"animated": @(animated),
            @"target_source": targetSource ?: @"handle",
        } mutableCopy];
        if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
        if (experimentID.length) {
            NSDictionary *undoRecord = @{
                @"mutation": @"ui.scroll",
                @"object": scrollView,
                @"x": @(before.x),
                @"y": @(before.y),
            };
            if (!FUExperimentCommitMutation(experimentID, undoRecord, result, &experimentError)) {
                response = FUResponse(requestID, NO, nil, experimentError);
                return;
            }
        }
        response = FUResponse(requestID, YES, result, nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

static id FUObjectMessage(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSString *FULayoutAttributeName(NSLayoutAttribute attribute) {
    switch (attribute) {
        case NSLayoutAttributeLeft: return @"left";
        case NSLayoutAttributeRight: return @"right";
        case NSLayoutAttributeTop: return @"top";
        case NSLayoutAttributeBottom: return @"bottom";
        case NSLayoutAttributeLeading: return @"leading";
        case NSLayoutAttributeTrailing: return @"trailing";
        case NSLayoutAttributeWidth: return @"width";
        case NSLayoutAttributeHeight: return @"height";
        case NSLayoutAttributeCenterX: return @"center_x";
        case NSLayoutAttributeCenterY: return @"center_y";
        case NSLayoutAttributeLastBaseline: return @"last_baseline";
        case NSLayoutAttributeFirstBaseline: return @"first_baseline";
        case NSLayoutAttributeLeftMargin: return @"left_margin";
        case NSLayoutAttributeRightMargin: return @"right_margin";
        case NSLayoutAttributeTopMargin: return @"top_margin";
        case NSLayoutAttributeBottomMargin: return @"bottom_margin";
        case NSLayoutAttributeLeadingMargin: return @"leading_margin";
        case NSLayoutAttributeTrailingMargin: return @"trailing_margin";
        case NSLayoutAttributeCenterXWithinMargins: return @"center_x_within_margins";
        case NSLayoutAttributeCenterYWithinMargins: return @"center_y_within_margins";
        case NSLayoutAttributeNotAnAttribute: return @"none";
    }
    return [NSString stringWithFormat:@"unknown_%ld", (long)attribute];
}

static NSString *FULayoutRelationName(NSLayoutRelation relation) {
    switch (relation) {
        case NSLayoutRelationLessThanOrEqual: return @"less_than_or_equal";
        case NSLayoutRelationEqual: return @"equal";
        case NSLayoutRelationGreaterThanOrEqual: return @"greater_than_or_equal";
    }
    return [NSString stringWithFormat:@"unknown_%ld", (long)relation];
}

static NSString *FUImagePathForObject(id object) {
    if (!object) return nil;
    Class cls = object_isClass(object) ? (Class)object : [object class];
    const char *image = class_getImageName(cls);
    return image ? [NSString stringWithUTF8String:image] : nil;
}

static UIViewController *FUOwningViewController(UIView *view) {
    UIResponder *cursor = view;
    for (NSUInteger depth = 0; cursor && depth < 128; depth++) {
        if ([cursor isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)cursor;
        }
        cursor = cursor.nextResponder;
    }
    return nil;
}

static UIView *FUDeepInspectRootView(UIView *view, NSDictionary *request) {
    NSString *rootHandle = [request[@"root"] isKindOfClass:[NSString class]] ? request[@"root"] : nil;
    UIView *root = rootHandle.length ? FUViewForActionHandle(rootHandle) : nil;
    if (root && FUViewPathFromRoot(view, root)) {
        return root;
    }
    root = view;
    for (NSUInteger depth = 0; root.superview && depth < 256; depth++) {
        root = root.superview;
    }
    return root;
}

static NSDictionary *FUAffineTransformJSON(CGAffineTransform transform) {
    return @{
        @"a": FUJSONFloatingNumber(transform.a),
        @"b": FUJSONFloatingNumber(transform.b),
        @"c": FUJSONFloatingNumber(transform.c),
        @"d": FUJSONFloatingNumber(transform.d),
        @"tx": FUJSONFloatingNumber(transform.tx),
        @"ty": FUJSONFloatingNumber(transform.ty),
    };
}

static NSDictionary *FUDeepViewState(UIView *view, UIView *rootView) {
    NSMutableDictionary *result = [@{
        @"frame": FURectJSON(view.frame),
        @"bounds": FURectJSON(view.bounds),
        @"center": FUPointJSON(view.center),
        @"transform": FUAffineTransformJSON(view.transform),
        @"alpha": FUJSONFloatingNumber(view.alpha),
        @"hidden": @(view.hidden),
        @"user_interaction_enabled": @(view.userInteractionEnabled),
        @"clips_to_bounds": @(view.clipsToBounds),
        @"content_mode": @(view.contentMode),
        @"has_ambiguous_layout": @(view.hasAmbiguousLayout),
        @"translates_autoresizing_mask_into_constraints": @(view.translatesAutoresizingMaskIntoConstraints),
    } mutableCopy];
    if (rootView) {
        @try {
            result[@"root_frame"] = FURectJSON(view == rootView ? view.bounds : [view convertRect:view.bounds toView:rootView]);
            result[@"selector"] = FUStableSelectorForView(view, rootView);
        } @catch (__unused NSException *exception) {
        }
    }
    return result;
}

static NSDictionary *FUDeepLayerMetadata(CALayer *layer) {
    NSMutableDictionary *result = [FUObjectReference(layer) mutableCopy];
    result[@"frame"] = FURectJSON(layer.frame);
    result[@"bounds"] = FURectJSON(layer.bounds);
    result[@"position"] = FUPointJSON(layer.position);
    result[@"anchor_point"] = FUPointJSON(layer.anchorPoint);
    result[@"z_position"] = FUJSONFloatingNumber(layer.zPosition);
    result[@"opacity"] = FUJSONFloatingNumber(layer.opacity);
    result[@"hidden"] = @(layer.hidden);
    result[@"masks_to_bounds"] = @(layer.masksToBounds);
    result[@"corner_radius"] = FUJSONFloatingNumber(layer.cornerRadius);
    result[@"border_width"] = FUJSONFloatingNumber(layer.borderWidth);
    result[@"contents_scale"] = FUJSONFloatingNumber(layer.contentsScale);
    if (layer.backgroundColor) {
        @try {
            result[@"background_color"] = FUTruncatedString([[UIColor colorWithCGColor:layer.backgroundColor] description], 256);
        } @catch (__unused NSException *exception) {
        }
    }
    return result;
}

static NSDictionary *FUDeepAccessibilityMetadata(UIView *view) {
    NSMutableDictionary *result = [@{
        @"is_accessibility_element": @(view.isAccessibilityElement),
        @"traits": @((unsigned long long)view.accessibilityTraits),
        @"frame": FURectJSON(view.accessibilityFrame),
    } mutableCopy];
    if (view.accessibilityIdentifier.length) result[@"identifier"] = FUTruncatedString(view.accessibilityIdentifier, 512);
    if (view.accessibilityLabel.length) result[@"label"] = FUTruncatedString(view.accessibilityLabel, 1024);
    if (view.accessibilityValue.length) result[@"value"] = FUTruncatedString(view.accessibilityValue, 1024);
    if (view.accessibilityHint.length) result[@"hint"] = FUTruncatedString(view.accessibilityHint, 1024);
    return result;
}

static NSDictionary *FUDeepConstraintEntry(NSLayoutConstraint *constraint) {
    NSMutableDictionary *entry = [FUObjectReference(constraint) mutableCopy];
    entry[@"first_attribute"] = FULayoutAttributeName(constraint.firstAttribute);
    entry[@"second_attribute"] = FULayoutAttributeName(constraint.secondAttribute);
    entry[@"relation"] = FULayoutRelationName(constraint.relation);
    entry[@"multiplier"] = FUJSONFloatingNumber(constraint.multiplier);
    entry[@"constant"] = FUJSONFloatingNumber(constraint.constant);
    entry[@"priority"] = FUJSONFloatingNumber(constraint.priority);
    entry[@"active"] = @(constraint.active);
    if (constraint.identifier.length) entry[@"identifier"] = FUTruncatedString(constraint.identifier, 512);
    if (constraint.firstItem) entry[@"first_item"] = FUObjectReference(constraint.firstItem);
    if (constraint.secondItem) entry[@"second_item"] = FUObjectReference(constraint.secondItem);
    return entry;
}

static NSArray *FUDeepConstraints(UIView *view, NSUInteger limit, BOOL *truncated) {
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    NSMutableSet<NSLayoutConstraint *> *seen = [NSMutableSet set];
    void (^appendConstraint)(NSLayoutConstraint *) = ^(NSLayoutConstraint *constraint) {
        if (!constraint || [seen containsObject:constraint]) return;
        [seen addObject:constraint];
        [constraints addObject:constraint];
    };

    @try {
        for (NSLayoutConstraint *constraint in [view constraintsAffectingLayoutForAxis:UILayoutConstraintAxisHorizontal]) appendConstraint(constraint);
        for (NSLayoutConstraint *constraint in [view constraintsAffectingLayoutForAxis:UILayoutConstraintAxisVertical]) appendConstraint(constraint);
    } @catch (__unused NSException *exception) {
    }

    UIView *cursor = view;
    for (NSUInteger depth = 0; cursor && depth < 128; depth++, cursor = cursor.superview) {
        for (NSLayoutConstraint *constraint in cursor.constraints) {
            if (constraint.firstItem == view || constraint.secondItem == view) {
                appendConstraint(constraint);
            }
        }
    }

    if (truncated) *truncated = constraints.count > limit;
    NSUInteger count = MIN(constraints.count, limit);
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [result addObject:FUDeepConstraintEntry(constraints[index])];
    }
    return result;
}

static NSArray *FUDeepSuperviewChain(UIView *view, UIView *rootView, NSUInteger limit, BOOL *truncated) {
    NSMutableArray *result = [NSMutableArray array];
    UIView *cursor = view.superview;
    while (cursor && result.count < limit) {
        NSMutableDictionary *entry = [FUObjectReference(cursor) mutableCopy];
        entry[@"frame"] = FURectJSON(cursor.frame);
        if (rootView) {
            @try {
                entry[@"root_frame"] = FURectJSON(cursor == rootView ? cursor.bounds : [cursor convertRect:cursor.bounds toView:rootView]);
                entry[@"selector"] = FUStableSelectorForView(cursor, rootView);
            } @catch (__unused NSException *exception) {
            }
        }
        NSString *image = FUImagePathForObject(cursor);
        if (image.length) entry[@"image"] = image;
        [result addObject:entry];
        cursor = cursor.superview;
    }
    if (truncated) *truncated = cursor != nil;
    return result;
}

static NSArray *FUDeepResponderChain(UIResponder *responder, NSUInteger limit, BOOL *truncated) {
    NSMutableArray *result = [NSMutableArray array];
    UIResponder *cursor = responder;
    while (cursor && result.count < limit) {
        NSMutableDictionary *entry = [FUObjectReference(cursor) mutableCopy];
        NSString *image = FUImagePathForObject(cursor);
        if (image.length) entry[@"image"] = image;
        [result addObject:entry];
        cursor = cursor.nextResponder;
    }
    if (truncated) *truncated = cursor != nil;
    return result;
}

static NSArray *FUDeepGestureTargets(UIGestureRecognizer *gesture, NSUInteger limit, BOOL *truncated) {
    NSMutableArray *result = [NSMutableArray array];
    NSArray *records = nil;
    @try {
        id value = [gesture valueForKey:@"_targets"];
        if ([value isKindOfClass:[NSArray class]]) records = value;
    } @catch (__unused NSException *exception) {
    }
    for (id record in records ?: @[]) {
        if (result.count >= limit) break;
        id target = nil;
        id action = nil;
        @try { target = [record valueForKey:@"target"]; } @catch (__unused NSException *exception) {}
        if (!target) {
            @try { target = [record valueForKey:@"_target"]; } @catch (__unused NSException *exception) {}
        }
        @try { action = [record valueForKey:@"action"]; } @catch (__unused NSException *exception) {}
        if (!action) {
            @try { action = [record valueForKey:@"_action"]; } @catch (__unused NSException *exception) {}
        }
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        if (target) entry[@"target"] = FUObjectReference(target);
        if (action) entry[@"action"] = FUTruncatedString([action description], 512);
        if (entry.count) [result addObject:entry];
    }
    if (truncated) *truncated = records.count > result.count;
    return result;
}

static NSDictionary *FUDeepGestureEntry(UIGestureRecognizer *gesture, NSUInteger targetLimit) {
    NSMutableDictionary *entry = [FUObjectReference(gesture) mutableCopy];
    entry[@"state"] = @(gesture.state);
    entry[@"enabled"] = @(gesture.enabled);
    entry[@"cancels_touches_in_view"] = @(gesture.cancelsTouchesInView);
    entry[@"delays_touches_began"] = @(gesture.delaysTouchesBegan);
    entry[@"delays_touches_ended"] = @(gesture.delaysTouchesEnded);
    if (gesture.view) entry[@"view"] = FUObjectReference(gesture.view);
    BOOL targetsTruncated = NO;
    NSArray *targets = FUDeepGestureTargets(gesture, targetLimit, &targetsTruncated);
    if (targets.count) entry[@"targets"] = targets;
    if (targetsTruncated) entry[@"targets_truncated"] = @YES;
    return entry;
}

static NSArray *FUDeepGestures(UIView *view, NSUInteger limit, BOOL *truncated) {
    NSArray<UIGestureRecognizer *> *gestures = view.gestureRecognizers ?: @[];
    if (truncated) *truncated = gestures.count > limit;
    NSUInteger count = MIN(gestures.count, limit);
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [result addObject:FUDeepGestureEntry(gestures[index], MIN((NSUInteger)16, limit))];
    }
    return result;
}

static NSArray<NSDictionary *> *FUControlEventDefinitions(void) {
    return @[
        @{ @"name": @"touch_down", @"value": @(UIControlEventTouchDown) },
        @{ @"name": @"touch_down_repeat", @"value": @(UIControlEventTouchDownRepeat) },
        @{ @"name": @"touch_drag_inside", @"value": @(UIControlEventTouchDragInside) },
        @{ @"name": @"touch_drag_outside", @"value": @(UIControlEventTouchDragOutside) },
        @{ @"name": @"touch_drag_enter", @"value": @(UIControlEventTouchDragEnter) },
        @{ @"name": @"touch_drag_exit", @"value": @(UIControlEventTouchDragExit) },
        @{ @"name": @"touch_up_inside", @"value": @(UIControlEventTouchUpInside) },
        @{ @"name": @"touch_up_outside", @"value": @(UIControlEventTouchUpOutside) },
        @{ @"name": @"touch_cancel", @"value": @(UIControlEventTouchCancel) },
        @{ @"name": @"value_changed", @"value": @(UIControlEventValueChanged) },
        @{ @"name": @"primary_action_triggered", @"value": @(UIControlEventPrimaryActionTriggered) },
        @{ @"name": @"editing_did_begin", @"value": @(UIControlEventEditingDidBegin) },
        @{ @"name": @"editing_changed", @"value": @(UIControlEventEditingChanged) },
        @{ @"name": @"editing_did_end", @"value": @(UIControlEventEditingDidEnd) },
        @{ @"name": @"editing_did_end_on_exit", @"value": @(UIControlEventEditingDidEndOnExit) },
    ];
}

static NSArray *FUDeepControlActions(UIControl *control, NSUInteger limit, BOOL *truncated) {
    if (!control) {
        if (truncated) *truncated = NO;
        return @[];
    }
    NSMutableArray *result = [NSMutableArray array];
    BOOL didTruncate = NO;
    UIControlEvents allEvents = control.allControlEvents;
    for (NSDictionary *definition in FUControlEventDefinitions()) {
        UIControlEvents event = [definition[@"value"] unsignedIntegerValue];
        if ((allEvents & event) == 0) continue;
        for (id target in control.allTargets) {
            NSArray<NSString *> *actions = [control actionsForTarget:target forControlEvent:event] ?: @[];
            for (NSString *action in actions) {
                if (result.count >= limit) {
                    didTruncate = YES;
                    break;
                }
                [result addObject:@{
                    @"event": definition[@"name"],
                    @"event_mask": @(event),
                    @"target": FUObjectReference(target),
                    @"action": action ?: @"",
                }];
            }
            if (didTruncate) break;
        }
        if (didTruncate) break;
    }
    if (truncated) *truncated = didTruncate;
    return result;
}

static NSDictionary *FUDeepFLEXMetadata(id object, NSUInteger limit, BOOL includeValues, NSDictionary **errorResponse, NSString *requestID) {
    id explorer = FUObjectExplorerForObject(object);
    if (!explorer) {
        if (errorResponse) *errorResponse = FUResponse(requestID, NO, nil, FUErrorInfo(@"unsupported_flex", @"The loaded FLEX build does not expose FLEXObjectExplorer."));
        return nil;
    }
    NSUInteger propertiesTotal = 0, ivarsTotal = 0, methodsTotal = 0, classMethodsTotal = 0;
    NSArray *properties = FUPropertyMetadata(explorer, object, includeValues, 0, limit, @"", &propertiesTotal);
    NSArray *ivars = FUIvarMetadata(explorer, object, includeValues, 0, limit, @"", &ivarsTotal);
    NSArray *methods = FUMethodMetadata(explorer, @"allMethods", 0, limit, @"", &methodsTotal);
    NSArray *classMethods = FUMethodMetadata(explorer, @"allClassMethods", 0, limit, @"", &classMethodsTotal);
    NSMutableDictionary *result = [@{
        @"class_hierarchy": FUClassHierarchyNames(explorer),
        @"properties": properties,
        @"ivars": ivars,
        @"methods": methods,
        @"class_methods": classMethods,
        @"include_values": @(includeValues),
        @"truncated": @{
            @"properties": @(properties.count < propertiesTotal),
            @"ivars": @(ivars.count < ivarsTotal),
            @"methods": @(methods.count < methodsTotal),
            @"class_methods": @(classMethods.count < classMethodsTotal),
        },
    } mutableCopy];
    NSString *summary = FUObjectMessage(explorer, @"objectDescription");
    if (summary.length) result[@"summary"] = FUTruncatedString(summary, 2048);
    return result;
}

NSDictionary *FUHandleUIDeepInspect(NSString *requestID, NSDictionary *request) {
    NSString *resolvedHandle = nil;
    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    id object = FUObjectTargetFromRequest(requestID, request, &resolvedHandle, &targetSource, &resolvedBy, &targetError);
    if (!object) return targetError;
    if (![object isKindOfClass:[UIView class]] && ![object isKindOfClass:[UIViewController class]]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_target", @"ui.deep_inspect requires a UIView or UIViewController target."));
    }
    if (![FUFlexStatus(YES)[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for ui.deep_inspect."));
    }

    NSString *rootHandle = [request[@"root"] isKindOfClass:[NSString class]] ? request[@"root"] : nil;
    if (rootHandle.length && !FUObjectForHandle(rootHandle)) {
        return FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(rootHandle, @"The requested root handle is unknown or the object has expired."));
    }

    NSUInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"limit"] unsignedIntegerValue] : 60;
    NSUInteger limit = MIN(MAX(requestedLimit, (NSUInteger)1), (NSUInteger)200);
    BOOL includeValues = ![request[@"include_values"] respondsToSelector:@selector(boolValue)] || [request[@"include_values"] boolValue];
    NSUInteger chainLimit = MIN(MAX(limit, (NSUInteger)8), (NSUInteger)64);
    NSUInteger relationshipLimit = MIN(MAX(limit, (NSUInteger)8), (NSUInteger)128);

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            UIViewController *controller = [object isKindOfClass:[UIViewController class]] ? object : nil;
            UIView *view = [object isKindOfClass:[UIView class]] ? object : controller.view;
            if (!view) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"view_not_found", @"The selected UIViewController does not currently expose a view."));
                return;
            }
            if (!controller) controller = FUOwningViewController(view);
            UIView *rootView = FUDeepInspectRootView(view, request);

            BOOL superviewsTruncated = NO;
            BOOL respondersTruncated = NO;
            BOOL constraintsTruncated = NO;
            BOOL gesturesTruncated = NO;
            BOOL actionsTruncated = NO;

            NSDictionary *flexError = nil;
            NSDictionary *flex = FUDeepFLEXMetadata(object, limit, includeValues, &flexError, requestID);
            if (!flex) {
                response = flexError;
                return;
            }

            NSMutableDictionary *runtime = [NSMutableDictionary dictionary];
            NSString *selectedImage = FUImagePathForObject(object);
            NSString *viewImage = FUImagePathForObject(view);
            NSString *controllerImage = FUImagePathForObject(controller);
            if (selectedImage.length) runtime[@"selected_image"] = selectedImage;
            if (viewImage.length) runtime[@"view_image"] = viewImage;
            if (controllerImage.length) runtime[@"controller_image"] = controllerImage;

            NSMutableDictionary *result = [@{
                @"selected": FUObjectReference(object),
                @"view": FUObjectReference(view),
                @"view_state": FUDeepViewState(view, rootView),
                @"superviews": FUDeepSuperviewChain(view, rootView, chainLimit, &superviewsTruncated),
                @"responder_chain": FUDeepResponderChain(view, chainLimit, &respondersTruncated),
                @"constraints": FUDeepConstraints(view, relationshipLimit, &constraintsTruncated),
                @"layer": FUDeepLayerMetadata(view.layer),
                @"gestures": FUDeepGestures(view, relationshipLimit, &gesturesTruncated),
                @"control_actions": [view isKindOfClass:[UIControl class]] ? FUDeepControlActions((UIControl *)view, relationshipLimit, &actionsTruncated) : @[],
                @"accessibility": FUDeepAccessibilityMetadata(view),
                @"runtime": runtime,
                @"flex": flex,
                @"target_source": targetSource ?: @"handle",
                @"resolved_handle": resolvedHandle ?: @"",
                @"limits": @{
                    @"members": @(limit),
                    @"chains": @(chainLimit),
                    @"relationships": @(relationshipLimit),
                },
                @"truncated": @{
                    @"superviews": @(superviewsTruncated),
                    @"responder_chain": @(respondersTruncated),
                    @"constraints": @(constraintsTruncated),
                    @"gestures": @(gesturesTruncated),
                    @"control_actions": @(actionsTruncated),
                },
            } mutableCopy];
            if (controller) result[@"view_controller"] = FUObjectReference(controller);
            if (rootView) result[@"root"] = FUObjectReference(rootView);
            if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
            response = FUResponse(requestID, YES, result, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"inspection_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

static NSDictionary *FUScreenshotPayloadForView(UIView *rootView, NSString *format, CGFloat quality, NSUInteger maxDimension, NSString **errorCode, NSString **errorMessage) {
    CGSize sourceSize = rootView.bounds.size;
    if (!isfinite((double)sourceSize.width) || !isfinite((double)sourceSize.height) || sourceSize.width <= 0.0 || sourceSize.height <= 0.0) {
        if (errorCode) *errorCode = @"invalid_size";
        if (errorMessage) *errorMessage = @"The requested view has invalid or empty bounds.";
        return nil;
    }

    CGFloat maxSide = MAX(sourceSize.width, sourceSize.height);
    CGFloat scale = MIN(1.0, ((CGFloat)maxDimension) / maxSide);
    CGSize renderSize = CGSizeMake(MAX(1.0, floor(sourceSize.width * scale)), MAX(1.0, floor(sourceSize.height * scale)));
    UIGraphicsImageRendererFormat *rendererFormat = [UIGraphicsImageRendererFormat defaultFormat];
    rendererFormat.scale = 1.0;
    rendererFormat.opaque = rootView.opaque;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:renderSize format:rendererFormat];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef context = rendererContext.CGContext;
        CGContextSaveGState(context);
        CGContextScaleCTM(context, scale, scale);
        BOOL drew = [rootView drawViewHierarchyInRect:rootView.bounds afterScreenUpdates:YES];
        if (!drew) [rootView.layer renderInContext:context];
        CGContextRestoreGState(context);
    }];
    NSData *data = [format isEqualToString:@"png"] ? UIImagePNGRepresentation(image) : UIImageJPEGRepresentation(image, quality);
    if (!data) {
        if (errorCode) *errorCode = @"capture_failed";
        if (errorMessage) *errorMessage = @"UIKit failed to encode the requested screenshot.";
        return nil;
    }

    return @{
        @"mime_type": [format isEqualToString:@"png"] ? @"image/png" : @"image/jpeg",
        @"data": [data base64EncodedStringWithOptions:0],
        @"byte_count": @(data.length),
        @"width": @((NSUInteger)renderSize.width),
        @"height": @((NSUInteger)renderSize.height),
        @"scale": FUJSONFloatingNumber(scale),
    };
}

NSDictionary *FUHandleUIScreenshot(NSString *requestID, NSDictionary *request) {
    NSString *rootHandle = [request[@"root"] isKindOfClass:[NSString class]] ? request[@"root"] : nil;
    if (rootHandle.length && !FUObjectForHandle(rootHandle)) {
        return FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(rootHandle, @"The requested root handle is unknown or the object has expired."));
    }
    NSString *format = [request[@"format"] isKindOfClass:[NSString class]] ? [request[@"format"] lowercaseString] : @"jpeg";
    if (![@[@"jpeg", @"png"] containsObject:format]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_format", @"ui.screenshot format must be jpeg or png."));
    }
    NSInteger requestedMax = [request[@"max_dimension"] respondsToSelector:@selector(integerValue)] ? [request[@"max_dimension"] integerValue] : 1600;
    if (requestedMax < 128 || requestedMax > 2048) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_size", @"ui.screenshot max_dimension must be between 128 and 2048."));
    }
    CGFloat quality = [request[@"quality"] respondsToSelector:@selector(doubleValue)] ? [request[@"quality"] doubleValue] : 0.85;
    quality = MIN(MAX(quality, 0.1), 1.0);

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIView *rootView = rootHandle.length ? FUViewForActionHandle(rootHandle) : FUKeyWindow();
        if (!rootView) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_root", @"ui.screenshot requires a UIView/UIViewController handle or an available key window."));
            return;
        }
        NSString *errorCode = nil;
        NSString *errorMessage = nil;
        NSDictionary *image = FUScreenshotPayloadForView(rootView, format, quality, (NSUInteger)requestedMax, &errorCode, &errorMessage);
        if (!image) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(errorCode ?: @"capture_failed", errorMessage ?: @"Screenshot capture failed."));
            return;
        }
        NSMutableDictionary *result = [image mutableCopy];
        result[@"root"] = FUObjectReference(rootView);
        response = FUResponse(requestID, YES, result, nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

static NSString *FUSnapshotRole(UIView *view) {
    if ([view isKindOfClass:[UISearchBar class]]) return @"search_bar";
    if ([view isKindOfClass:[UITextField class]]) return @"text_field";
    if ([view isKindOfClass:[UITextView class]]) return @"text_view";
    if ([view isKindOfClass:[UIButton class]]) return @"button";
    if ([view isKindOfClass:[UISwitch class]]) return @"switch";
    if ([view isKindOfClass:[UISlider class]]) return @"slider";
    if ([view isKindOfClass:[UIStepper class]]) return @"stepper";
    if ([view isKindOfClass:[UISegmentedControl class]]) return @"segmented_control";
    if ([view isKindOfClass:[UITableView class]]) return @"table";
    if ([view isKindOfClass:[UICollectionView class]]) return @"collection";
    if ([view isKindOfClass:[UIScrollView class]]) return @"scroll_view";
    if ([view isKindOfClass:[UITableViewCell class]] || [view isKindOfClass:[UICollectionViewCell class]]) return @"cell";
    if ([view isKindOfClass:[UILabel class]]) return @"label";
    if ([view isKindOfClass:[UIImageView class]]) return @"image";
    if ([view isKindOfClass:[UIControl class]]) return @"control";
    if (view.isAccessibilityElement) return @"accessibility_element";
    return @"view";
}

static NSArray<NSString *> *FUSnapshotActions(UIView *view) {
    NSMutableArray<NSString *> *actions = [NSMutableArray array];
    if (([view isKindOfClass:[UITableViewCell class]] || [view isKindOfClass:[UICollectionViewCell class]]) && FUListCellCanSelect(view)) {
        [actions addObject:@"select"];
    }
    if ([view isKindOfClass:[UITextField class]] || [view isKindOfClass:[UITextView class]] || [view isKindOfClass:[UISearchBar class]]) {
        [actions addObject:@"set_text"];
        [actions addObject:@"activate"];
    } else if ([view isKindOfClass:[UIControl class]]) {
        if (((UIControl *)view).enabled) {
            [actions addObject:@"activate"];
            if ([view isKindOfClass:[UISwitch class]] ||
                [view isKindOfClass:[UISlider class]] ||
                [view isKindOfClass:[UIStepper class]] ||
                [view isKindOfClass:[UISegmentedControl class]]) {
                [actions addObject:@"set_value"];
            }
        }
    } else if (view.isAccessibilityElement && view.userInteractionEnabled) {
        [actions addObject:@"activate"];
    }
    if ([view isKindOfClass:[UIScrollView class]]) [actions addObject:@"scroll"];
    return actions;
}

static BOOL FUSnapshotMeaningfulView(UIView *view) {
    if ([view isKindOfClass:[UIControl class]] ||
        [view isKindOfClass:[UIScrollView class]] ||
        [view isKindOfClass:[UILabel class]] ||
        [view isKindOfClass:[UITextView class]] ||
        [view isKindOfClass:[UISearchBar class]] ||
        [view isKindOfClass:[UITableViewCell class]] ||
        [view isKindOfClass:[UICollectionViewCell class]]) {
        return YES;
    }
    if (view.isAccessibilityElement || view.accessibilityIdentifier.length || view.accessibilityLabel.length || view.accessibilityValue.length) {
        return YES;
    }
    return FUViewTextValue(view).length > 0;
}

static NSDictionary *FUSnapshotEntry(UIView *view, UIView *rootView, CGRect frame) {
    NSMutableDictionary *entry = [FUObjectReference(view) mutableCopy];
    entry[@"role"] = FUSnapshotRole(view);
    entry[@"frame"] = FURectJSON(frame);
    entry[@"bounds"] = FURectJSON(view.bounds);
    entry[@"hidden"] = @(view.hidden);
    entry[@"alpha"] = FUJSONFloatingNumber(view.alpha);
    entry[@"accessibility_traits"] = @((unsigned long long)view.accessibilityTraits);
    entry[@"user_interaction_enabled"] = @(view.userInteractionEnabled);
    NSArray<NSString *> *actions = FUSnapshotActions(view);
    if (actions.count) entry[@"actions"] = actions;
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        entry[@"enabled"] = @(control.enabled);
        entry[@"selected"] = @(control.selected);
    }
    if ([view isKindOfClass:[UISwitch class]]) {
        entry[@"value"] = @(((UISwitch *)view).isOn);
    } else if ([view isKindOfClass:[UISlider class]]) {
        UISlider *slider = (UISlider *)view;
        entry[@"value"] = FUJSONFloatingNumber(slider.value);
        entry[@"minimum_value"] = FUJSONFloatingNumber(slider.minimumValue);
        entry[@"maximum_value"] = FUJSONFloatingNumber(slider.maximumValue);
    } else if ([view isKindOfClass:[UIStepper class]]) {
        UIStepper *stepper = (UIStepper *)view;
        entry[@"value"] = FUJSONFloatingNumber(stepper.value);
        entry[@"minimum_value"] = FUJSONFloatingNumber(stepper.minimumValue);
        entry[@"maximum_value"] = FUJSONFloatingNumber(stepper.maximumValue);
        entry[@"step_value"] = FUJSONFloatingNumber(stepper.stepValue);
    } else if ([view isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *segmented = (UISegmentedControl *)view;
        entry[@"value"] = @(segmented.selectedSegmentIndex);
        entry[@"segment_count"] = @(segmented.numberOfSegments);
    }
    NSString *text = FUViewTextValue(view);
    if (text.length) entry[@"text"] = FUTruncatedString(text, 1024);
    if (view.accessibilityIdentifier.length) entry[@"accessibility_identifier"] = FUTruncatedString(view.accessibilityIdentifier, 512);
    if (view.accessibilityLabel.length) entry[@"accessibility_label"] = FUTruncatedString(view.accessibilityLabel, 512);
    if (view.accessibilityValue.length) entry[@"accessibility_value"] = FUTruncatedString(view.accessibilityValue, 512);
    entry[@"selector"] = FUStableSelectorForView(view, rootView);
    return entry;
}

NSDictionary *FUHandleUISnapshot(NSString *requestID, NSDictionary *request) {
    NSString *rootHandle = [request[@"root"] isKindOfClass:[NSString class]] ? request[@"root"] : nil;
    if (rootHandle.length && !FUObjectForHandle(rootHandle)) {
        return FUResponse(requestID, NO, nil, FUObjectHandleErrorInfo(rootHandle, @"The requested root handle is unknown or the object has expired."));
    }
    BOOL includeImage = request[@"include_image"] ? [request[@"include_image"] boolValue] : YES;
    NSString *format = [request[@"format"] isKindOfClass:[NSString class]] ? [request[@"format"] lowercaseString] : @"jpeg";
    if (![@[@"jpeg", @"png"] containsObject:format]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_format", @"ui.snapshot format must be jpeg or png."));
    }
    NSInteger requestedMaxDimension = [request[@"max_dimension"] respondsToSelector:@selector(integerValue)] ? [request[@"max_dimension"] integerValue] : 1200;
    if (requestedMaxDimension < 128 || requestedMaxDimension > 2048) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_size", @"ui.snapshot max_dimension must be between 128 and 2048."));
    }
    NSInteger requestedMaxNodes = [request[@"max_nodes"] respondsToSelector:@selector(integerValue)] ? [request[@"max_nodes"] integerValue] : 750;
    if (requestedMaxNodes <= 0 || requestedMaxNodes > 10000) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_search_bounds", @"ui.snapshot max_nodes must be between 1 and 10000."));
    }
    CGFloat quality = [request[@"quality"] respondsToSelector:@selector(doubleValue)] ? [request[@"quality"] doubleValue] : 0.8;
    quality = MIN(MAX(quality, 0.1), 1.0);

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        UIView *rootView = rootHandle.length ? FUViewForActionHandle(rootHandle) : FUKeyWindow();
        if (!rootView) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_root", @"ui.snapshot requires a UIView/UIViewController handle or an available key window."));
            return;
        }

        CGRect rootBounds = rootView.bounds;
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:rootView];
        NSMutableArray *elements = [NSMutableArray array];
        NSUInteger cursor = 0;
        NSUInteger scanned = 0;
        while (cursor < queue.count && scanned < (NSUInteger)requestedMaxNodes) {
            UIView *view = queue[cursor++];
            scanned++;
            BOOL visible = !view.hidden && view.alpha > 0.01;
            UIView *ancestor = view.superview;
            while (visible && ancestor && ancestor != rootView.superview) {
                if (ancestor.hidden || ancestor.alpha <= 0.01) visible = NO;
                if (ancestor == rootView) break;
                ancestor = ancestor.superview;
            }
            CGRect frame = (view == rootView) ? rootBounds : [view convertRect:view.bounds toView:rootView];
            BOOL intersects = !CGRectIsEmpty(frame) && !CGRectIsNull(CGRectIntersection(rootBounds, frame));
            if (visible && intersects && FUSnapshotMeaningfulView(view)) {
                [elements addObject:FUSnapshotEntry(view, rootView, frame)];
            }
            for (UIView *child in view.subviews) [queue addObject:child];
        }

        NSMutableDictionary *result = [@{
            @"root": FUObjectReference(rootView),
            @"screen": FUSizeJSON(rootBounds.size),
            @"elements": elements,
            @"element_count": @(elements.count),
            @"scanned": @(scanned),
            @"truncated": @(cursor < queue.count),
            @"limits": @{ @"max_nodes": @(requestedMaxNodes) },
            @"include_image": @(includeImage),
        } mutableCopy];
        UIWindow *window = rootView.window ?: ([rootView isKindOfClass:[UIWindow class]] ? (UIWindow *)rootView : nil);
        if (window) result[@"window"] = FUWindowJSON(window);

        if (includeImage) {
            NSString *errorCode = nil;
            NSString *errorMessage = nil;
            NSDictionary *image = FUScreenshotPayloadForView(rootView, format, quality, (NSUInteger)requestedMaxDimension, &errorCode, &errorMessage);
            if (!image) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(errorCode ?: @"capture_failed", errorMessage ?: @"Snapshot capture failed."));
                return;
            }
            [result addEntriesFromDictionary:image];
        }
        response = FUResponse(requestID, YES, result, nil);
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

static void FUInitializeSnapshotStore(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FUSnapshotStoreLock = [NSObject new];
        FUSavedSnapshots = [NSMutableDictionary dictionary];
        FUSavedSnapshotOrder = [NSMutableArray array];
    });
}

static NSString *FUSnapshotGenerationFromID(NSString *snapshotID) {
    if (![snapshotID isKindOfClass:[NSString class]] || ![snapshotID hasPrefix:@"snap_"]) {
        return nil;
    }
    NSString *suffix = [snapshotID substringFromIndex:5];
    NSRange separator = [suffix rangeOfString:@"_" options:NSBackwardsSearch];
    if (separator.location == NSNotFound || separator.location == 0 || NSMaxRange(separator) >= suffix.length) {
        return nil;
    }
    NSString *generation = [suffix substringToIndex:separator.location];
    NSString *counter = [suffix substringFromIndex:NSMaxRange(separator)];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (counter.length == 0 || [counter rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        return nil;
    }
    return generation.length ? generation : nil;
}

static NSString *FUSnapshotIdentityJSON(NSArray *parts) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:parts ?: @[] options:0 error:&error];
    if (!data || error) return @"[]";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"[]";
}

static NSString *FUSnapshotBaseIdentity(NSDictionary *entry) {
    NSDictionary *selector = [entry[@"selector"] isKindOfClass:[NSDictionary class]] ? entry[@"selector"] : @{};
    NSString *className = [entry[@"class"] isKindOfClass:[NSString class]] ? entry[@"class"] : @"";
    NSString *strategy = [selector[@"strategy"] isKindOfClass:[NSString class]] ? selector[@"strategy"] : @"path";
    NSString *value = [selector[@"value"] isKindOfClass:[NSString class]] ? selector[@"value"] : @"";
    NSArray *path = [selector[@"path"] isKindOfClass:[NSArray class]] ? selector[@"path"] : @[];

    if (([strategy isEqualToString:@"accessibility_identifier"] || [strategy isEqualToString:@"accessibility_label"]) && value.length) {
        return FUSnapshotIdentityJSON(@[@"semantic", className, strategy, value]);
    }
    return FUSnapshotIdentityJSON(@[@"path", className, path]);
}

static NSArray<NSDictionary *> *FUCompactSnapshotElements(NSArray *elements, BOOL includeHandles) {
    NSMutableDictionary<NSString *, NSNumber *> *baseCounts = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *bases = [NSMutableArray arrayWithCapacity:elements.count];
    for (id candidate in elements) {
        NSDictionary *entry = [candidate isKindOfClass:[NSDictionary class]] ? candidate : @{};
        NSString *base = FUSnapshotBaseIdentity(entry);
        [bases addObject:base];
        baseCounts[base] = @([baseCounts[base] unsignedIntegerValue] + 1);
    }

    NSMutableDictionary<NSString *, NSNumber *> *ordinals = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *compact = [NSMutableArray arrayWithCapacity:elements.count];
    NSArray<NSString *> *fields = @[
        @"class", @"role", @"frame", @"bounds", @"hidden", @"alpha",
        @"user_interaction_enabled", @"actions", @"enabled", @"selected", @"value",
        @"minimum_value", @"maximum_value", @"step_value", @"segment_count", @"text",
        @"accessibility_identifier", @"accessibility_label", @"accessibility_value",
        @"accessibility_traits", @"selector"
    ];

    for (NSUInteger index = 0; index < elements.count; index++) {
        NSDictionary *entry = [elements[index] isKindOfClass:[NSDictionary class]] ? elements[index] : @{};
        NSString *base = bases[index];
        NSString *identity = base;
        if ([baseCounts[base] unsignedIntegerValue] > 1) {
            NSDictionary *selector = [entry[@"selector"] isKindOfClass:[NSDictionary class]] ? entry[@"selector"] : @{};
            NSArray *path = [selector[@"path"] isKindOfClass:[NSArray class]] ? selector[@"path"] : @[];
            identity = FUSnapshotIdentityJSON(@[base, path]);
            NSUInteger ordinal = [ordinals[identity] unsignedIntegerValue];
            ordinals[identity] = @(ordinal + 1);
            if (ordinal > 0) identity = FUSnapshotIdentityJSON(@[identity, @(ordinal)]);
        }

        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"identity"] = identity;
        if (includeHandles && [entry[@"id"] isKindOfClass:[NSString class]]) item[@"id"] = entry[@"id"];
        for (NSString *field in fields) {
            id value = entry[field];
            if (value) item[field] = value;
        }
        [compact addObject:item];
    }
    return compact;
}

static NSArray *FULimitedSnapshotDiffArray(NSArray *array, NSUInteger limit) {
    if (array.count <= limit) return array;
    return [array subarrayWithRange:NSMakeRange(0, limit)];
}

NSDictionary *FUHandleUISnapshotSave(NSString *requestID, NSDictionary *request) {
    NSMutableDictionary *captureRequest = [request mutableCopy] ?: [NSMutableDictionary dictionary];
    captureRequest[@"include_image"] = @NO;
    [captureRequest removeObjectForKey:@"format"];
    [captureRequest removeObjectForKey:@"quality"];
    [captureRequest removeObjectForKey:@"max_dimension"];

    NSDictionary *captureResponse = FUHandleUISnapshot(requestID, captureRequest);
    if (![captureResponse[@"ok"] boolValue]) return captureResponse;
    NSDictionary *snapshot = [captureResponse[@"result"] isKindOfClass:[NSDictionary class]] ? captureResponse[@"result"] : @{};
    NSArray *elements = [snapshot[@"elements"] isKindOfClass:[NSArray class]] ? snapshot[@"elements"] : @[];
    NSArray *compactElements = FUCompactSnapshotElements(elements, NO);
    NSString *generation = FUCurrentObjectGeneration();

    FUInitializeSnapshotStore();
    NSString *snapshotID = nil;
    NSString *evictedSnapshotID = nil;
    NSUInteger retainedCount = 0;
    @synchronized (FUSnapshotStoreLock) {
        snapshotID = [NSString stringWithFormat:@"snap_%@_%llu", generation, FUSnapshotCounter++];
        NSMutableDictionary *record = [@{
            @"snapshot_id": snapshotID,
            @"generation": generation,
            @"captured_at": @(NSDate.date.timeIntervalSince1970),
            @"elements": compactElements,
            @"screen": snapshot[@"screen"] ?: @{},
            @"element_count": @(compactElements.count),
            @"scanned": snapshot[@"scanned"] ?: @0,
            @"truncated": snapshot[@"truncated"] ?: @NO,
            @"limits": snapshot[@"limits"] ?: @{},
        } mutableCopy];
        if ([request[@"root"] isKindOfClass:[NSString class]] && [request[@"root"] length]) record[@"request_root"] = request[@"root"];
        FUSavedSnapshots[snapshotID] = record;
        [FUSavedSnapshotOrder addObject:snapshotID];
        while (FUSavedSnapshotOrder.count > FUMaxSavedSnapshots) {
            NSString *oldest = FUSavedSnapshotOrder.firstObject;
            if (!oldest) break;
            [FUSavedSnapshotOrder removeObjectAtIndex:0];
            [FUSavedSnapshots removeObjectForKey:oldest];
            evictedSnapshotID = oldest;
        }
        retainedCount = FUSavedSnapshotOrder.count;
    }

    NSMutableDictionary *result = [@{
        @"snapshot_id": snapshotID ?: @"",
        @"generation": generation,
        @"captured_at": @(NSDate.date.timeIntervalSince1970),
        @"screen": snapshot[@"screen"] ?: @{},
        @"element_count": @(compactElements.count),
        @"scanned": snapshot[@"scanned"] ?: @0,
        @"truncated": snapshot[@"truncated"] ?: @NO,
        @"limits": snapshot[@"limits"] ?: @{},
        @"storage": @{
            @"retained": @(retainedCount),
            @"max_saved_snapshots": @(FUMaxSavedSnapshots),
        },
    } mutableCopy];
    if (evictedSnapshotID) result[@"evicted_snapshot_id"] = evictedSnapshotID;
    return FUResponse(requestID, YES, result, nil);
}

NSDictionary *FUHandleUISnapshotDiff(NSString *requestID, NSDictionary *request) {
    NSString *snapshotID = [request[@"snapshot_id"] isKindOfClass:[NSString class]] ? request[@"snapshot_id"] : nil;
    if (snapshotID.length == 0) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_snapshot_id", @"ui.snapshot_diff requires snapshot_id."));
    }

    NSString *snapshotGeneration = FUSnapshotGenerationFromID(snapshotID);
    NSString *currentGeneration = FUCurrentObjectGeneration();
    if (snapshotGeneration.length && ![snapshotGeneration isEqualToString:currentGeneration]) {
        NSMutableDictionary *error = [FUErrorInfo(@"stale_snapshot", @"The saved UI snapshot belongs to a previous target process generation. Capture a new baseline snapshot.") mutableCopy];
        error[@"snapshot_generation"] = snapshotGeneration;
        error[@"current_generation"] = currentGeneration;
        return FUResponse(requestID, NO, nil, error);
    }

    NSInteger requestedMaxChanges = [request[@"max_changes"] respondsToSelector:@selector(integerValue)] ? [request[@"max_changes"] integerValue] : 200;
    if (requestedMaxChanges <= 0 || requestedMaxChanges > 1000) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"invalid_diff_bounds", @"ui.snapshot_diff max_changes must be between 1 and 1000."));
    }

    FUInitializeSnapshotStore();
    NSDictionary *baseline = nil;
    @synchronized (FUSnapshotStoreLock) {
        baseline = [FUSavedSnapshots[snapshotID] copy];
    }
    if (!baseline) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"snapshot_not_found", @"The saved UI snapshot is unknown or has been evicted. Capture a new baseline snapshot."));
    }
    if (![baseline[@"generation"] isEqualToString:currentGeneration]) {
        NSMutableDictionary *error = [FUErrorInfo(@"stale_snapshot", @"The saved UI snapshot belongs to a previous target process generation. Capture a new baseline snapshot.") mutableCopy];
        error[@"snapshot_generation"] = baseline[@"generation"] ?: @"";
        error[@"current_generation"] = currentGeneration;
        return FUResponse(requestID, NO, nil, error);
    }

    NSMutableDictionary *captureRequest = [request mutableCopy] ?: [NSMutableDictionary dictionary];
    captureRequest[@"include_image"] = @NO;
    [captureRequest removeObjectForKey:@"snapshot_id"];
    [captureRequest removeObjectForKey:@"max_changes"];
    [captureRequest removeObjectForKey:@"format"];
    [captureRequest removeObjectForKey:@"quality"];
    [captureRequest removeObjectForKey:@"max_dimension"];
    if (![captureRequest[@"root"] isKindOfClass:[NSString class]] && [baseline[@"request_root"] isKindOfClass:[NSString class]]) {
        captureRequest[@"root"] = baseline[@"request_root"];
    }
    if (![captureRequest[@"max_nodes"] respondsToSelector:@selector(integerValue)]) {
        NSDictionary *limits = [baseline[@"limits"] isKindOfClass:[NSDictionary class]] ? baseline[@"limits"] : @{};
        if ([limits[@"max_nodes"] respondsToSelector:@selector(integerValue)]) captureRequest[@"max_nodes"] = limits[@"max_nodes"];
    }

    NSDictionary *captureResponse = FUHandleUISnapshot(requestID, captureRequest);
    if (![captureResponse[@"ok"] boolValue]) return captureResponse;
    NSDictionary *currentSnapshot = [captureResponse[@"result"] isKindOfClass:[NSDictionary class]] ? captureResponse[@"result"] : @{};
    NSArray *currentRaw = [currentSnapshot[@"elements"] isKindOfClass:[NSArray class]] ? currentSnapshot[@"elements"] : @[];
    NSArray<NSDictionary *> *currentElements = FUCompactSnapshotElements(currentRaw, YES);
    NSArray<NSDictionary *> *baselineElements = [baseline[@"elements"] isKindOfClass:[NSArray class]] ? baseline[@"elements"] : @[];

    NSMutableDictionary<NSString *, NSDictionary *> *beforeByID = [NSMutableDictionary dictionaryWithCapacity:baselineElements.count];
    NSMutableDictionary<NSString *, NSDictionary *> *afterByID = [NSMutableDictionary dictionaryWithCapacity:currentElements.count];
    for (NSDictionary *entry in baselineElements) if ([entry[@"identity"] isKindOfClass:[NSString class]]) beforeByID[entry[@"identity"]] = entry;
    for (NSDictionary *entry in currentElements) if ([entry[@"identity"] isKindOfClass:[NSString class]]) afterByID[entry[@"identity"]] = entry;

    NSMutableArray *added = [NSMutableArray array];
    NSMutableArray *removed = [NSMutableArray array];
    NSMutableArray *moved = [NSMutableArray array];
    NSMutableArray *changed = [NSMutableArray array];

    for (NSDictionary *after in currentElements) {
        NSString *identity = after[@"identity"];
        if (identity.length && !beforeByID[identity]) [added addObject:after];
    }
    for (NSDictionary *before in baselineElements) {
        NSString *identity = before[@"identity"];
        if (identity.length && !afterByID[identity]) [removed addObject:before];
    }

    NSArray<NSString *> *semanticFields = @[
        @"role", @"hidden", @"alpha", @"user_interaction_enabled", @"actions", @"enabled", @"selected", @"value",
        @"minimum_value", @"maximum_value", @"step_value", @"segment_count", @"text", @"accessibility_identifier",
        @"accessibility_label", @"accessibility_value", @"accessibility_traits"
    ];
    for (NSDictionary *before in baselineElements) {
        NSString *identity = before[@"identity"];
        NSDictionary *after = identity.length ? afterByID[identity] : nil;
        if (!after) continue;

        id beforeFrame = before[@"frame"] ?: NSNull.null;
        id afterFrame = after[@"frame"] ?: NSNull.null;
        id beforeBounds = before[@"bounds"] ?: NSNull.null;
        id afterBounds = after[@"bounds"] ?: NSNull.null;
        NSDictionary *beforeSelector = [before[@"selector"] isKindOfClass:[NSDictionary class]] ? before[@"selector"] : @{};
        NSDictionary *afterSelector = [after[@"selector"] isKindOfClass:[NSDictionary class]] ? after[@"selector"] : @{};
        NSArray *beforePath = [beforeSelector[@"path"] isKindOfClass:[NSArray class]] ? beforeSelector[@"path"] : @[];
        NSArray *afterPath = [afterSelector[@"path"] isKindOfClass:[NSArray class]] ? afterSelector[@"path"] : @[];
        BOOL frameChanged = ![beforeFrame isEqual:afterFrame] || ![beforeBounds isEqual:afterBounds];
        BOOL pathChanged = ![beforePath isEqual:afterPath];
        if (frameChanged || pathChanged) {
            NSMutableDictionary *movement = [@{
                @"identity": identity,
                @"class": after[@"class"] ?: before[@"class"] ?: @"",
                @"selector": afterSelector,
                @"before_frame": beforeFrame,
                @"after_frame": afterFrame,
                @"before_bounds": beforeBounds,
                @"after_bounds": afterBounds,
                @"path_changed": @(pathChanged),
            } mutableCopy];
            if (after[@"id"]) movement[@"id"] = after[@"id"];
            if (pathChanged) movement[@"before_selector"] = beforeSelector;
            [moved addObject:movement];
        }

        NSMutableDictionary *fieldChanges = [NSMutableDictionary dictionary];
        for (NSString *field in semanticFields) {
            id beforeValue = before[field] ?: NSNull.null;
            id afterValue = after[field] ?: NSNull.null;
            if (![beforeValue isEqual:afterValue]) {
                fieldChanges[field] = @{ @"before": beforeValue, @"after": afterValue };
            }
        }
        if (fieldChanges.count) {
            NSMutableDictionary *change = [@{
                @"identity": identity,
                @"class": after[@"class"] ?: before[@"class"] ?: @"",
                @"selector": afterSelector,
                @"changes": fieldChanges,
            } mutableCopy];
            if (after[@"id"]) change[@"id"] = after[@"id"];
            [changed addObject:change];
        }
    }

    NSUInteger limit = (NSUInteger)requestedMaxChanges;
    NSDictionary *counts = @{
        @"added": @(added.count),
        @"removed": @(removed.count),
        @"moved": @(moved.count),
        @"changed": @(changed.count),
    };
    BOOL addedTruncated = added.count > limit;
    BOOL removedTruncated = removed.count > limit;
    BOOL movedTruncated = moved.count > limit;
    BOOL changedTruncated = changed.count > limit;
    NSDictionary *baselineScreen = [baseline[@"screen"] isKindOfClass:[NSDictionary class]] ? baseline[@"screen"] : @{};
    NSDictionary *currentScreen = [currentSnapshot[@"screen"] isKindOfClass:[NSDictionary class]] ? currentSnapshot[@"screen"] : @{};

    return FUResponse(requestID, YES, @{
        @"snapshot_id": snapshotID,
        @"generation": currentGeneration,
        @"baseline": @{
            @"captured_at": baseline[@"captured_at"] ?: @0,
            @"element_count": baseline[@"element_count"] ?: @(baselineElements.count),
            @"scanned": baseline[@"scanned"] ?: @0,
            @"truncated": baseline[@"truncated"] ?: @NO,
        },
        @"current": @{
            @"captured_at": @(NSDate.date.timeIntervalSince1970),
            @"element_count": @(currentElements.count),
            @"scanned": currentSnapshot[@"scanned"] ?: @0,
            @"truncated": currentSnapshot[@"truncated"] ?: @NO,
        },
        @"screen": @{
            @"before": baselineScreen,
            @"after": currentScreen,
            @"changed": @((BOOL)![baselineScreen isEqual:currentScreen]),
        },
        @"counts": counts,
        @"added": FULimitedSnapshotDiffArray(added, limit),
        @"removed": FULimitedSnapshotDiffArray(removed, limit),
        @"moved": FULimitedSnapshotDiffArray(moved, limit),
        @"changed": FULimitedSnapshotDiffArray(changed, limit),
        @"truncated": @{
            @"added": @(addedTruncated),
            @"removed": @(removedTruncated),
            @"moved": @(movedTruncated),
            @"changed": @(changedTruncated),
            @"any": @(addedTruncated || removedTruncated || movedTruncated || changedTruncated),
        },
        @"limits": @{
            @"max_changes_per_category": @(limit),
            @"max_nodes": [currentSnapshot[@"limits"] isKindOfClass:[NSDictionary class]] ? (currentSnapshot[@"limits"][@"max_nodes"] ?: @750) : @750,
        },
    }, nil);
}
