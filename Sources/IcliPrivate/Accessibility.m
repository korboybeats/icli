#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <stdlib.h>
#import <unistd.h>
#import <stdatomic.h>

// libSystem exports it; the SDK ships no libproc.h.
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

// AXRuntime numeric attributes: verified on the rootless TestHost and compared
// with witchan/ios-mcp (8f46b68). String AX attributes are absent on this runtime.
typedef CFTypeRef AXElement;
static AXElement (*createApp)(pid_t);
static int (*copyAttribute)(AXElement, CFStringRef, CFTypeRef *);
static int (*setTimeout)(AXElement, float);
static Boolean (*getAXValue)(CFTypeRef, int, void *);
static int (*hitTest)(AXElement, AXElement *, float, float);
static int (*performAction)(AXElement, uint32_t);
static Boolean (*applicationEnabled)(void);
static void (*setApplicationEnabled)(Boolean);
static Boolean (*automationEnabled)(void);
static void (*setAutomationEnabled)(Boolean);

// Both switches are system-wide and persist: every app launched while they are on
// loads the accessibility bundles and reports automation. A query needs them, so
// they go on before a query and back to their old values when icli exits, or
// when a long-running host calls icli_ax_restore_switches. They stay on between
// queries, because `ui wait` polls in a loop and flipping a system-wide switch
// on every poll churns every app on the device. Each query reads them again: a
// host outlives the user or another tool turning them off in the meantime.
static BOOL turnedOnApplication;
static BOOL turnedOnAutomation;
static os_unfair_lock switchLock = OS_UNFAIR_LOCK_INIT;

void icli_ax_restore_switches(void) {
    os_unfair_lock_lock(&switchLock);
    if (turnedOnAutomation && setAutomationEnabled) setAutomationEnabled(false);
    if (turnedOnApplication && setApplicationEnabled) setApplicationEnabled(false);
    turnedOnAutomation = turnedOnApplication = NO;
    os_unfair_lock_unlock(&switchLock);
}

// Answers YES when this call turned a switch on, so the caller knows the target
// app is only now being told to load its accessibility bundles. A switch whose
// current value cannot be read is left alone: turning one off at exit that the
// device's owner had turned on, for VoiceOver say, would be worse than not
// reading the tree.
static BOOL enableSwitches(void) {
    os_unfair_lock_lock(&switchLock);
    BOOL application = applicationEnabled && setApplicationEnabled && !applicationEnabled();
    BOOL automation = automationEnabled && setAutomationEnabled && !automationEnabled();
    if (application || automation) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ atexit(icli_ax_restore_switches); });
        if (application) { setApplicationEnabled(true); turnedOnApplication = YES; }
        if (automation) { setAutomationEnabled(true); turnedOnAutomation = YES; }
    }
    os_unfair_lock_unlock(&switchLock);
    return application || automation;
}

static void *accessibilitySymbol(const char *name) {
    void *library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
    return library ? dlsym(library, name) : NULL;
}

char *icli_accessibility_json(void) {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    icli_as_mobile_user(^{
        CFStringRef (*copyCategory)(void) = accessibilitySymbol("_AXSCopyPreferredContentSizeCategoryName");
        NSString *category = copyCategory ? CFBridgingRelease(copyCategory()) : nil;
        // Nothing is stored until the size is first changed: the default is Large.
        settings[@"text_size"] = category.length ? category : UIContentSizeCategoryLarge;
        Boolean (*reduceMotion)(void) = accessibilitySymbol("_AXSReduceMotionEnabled");
        Boolean (*reduceTransparency)(void) = accessibilitySymbol("_AXSEnhanceBackgroundContrastEnabled");
        settings[@"reduce_motion"] = @((BOOL)(reduceMotion ? reduceMotion() != 0 : UIAccessibilityIsReduceMotionEnabled()));
        settings[@"reduce_transparency"] = @((BOOL)(reduceTransparency ? reduceTransparency() != 0 : UIAccessibilityIsReduceTransparencyEnabled()));
        settings[@"increase_contrast"] = @((BOOL)UIAccessibilityDarkerSystemColorsEnabled());
    });
    return icli_json(settings);
}

bool icli_accessibility_set_flag(const char *name, bool on) {
    const char *setter = strcmp(name, "reduce_motion") == 0 ? "_AXSSetReduceMotionEnabled"
        : strcmp(name, "increase_contrast") == 0 ? "_AXSSetDarkenSystemColors"
        : strcmp(name, "reduce_transparency") == 0 ? "_AXSSetEnhanceBackgroundContrastEnabled" : NULL;
    void (*set)(Boolean) = setter ? accessibilitySymbol(setter) : NULL;
    if (!set) return false;
    icli_as_mobile_user(^{ set(on); });
    return true;
}

bool icli_accessibility_set_text_size(const char *category) {
    void (*set)(CFStringRef) = accessibilitySymbol("_AXSSetPreferredContentSizeCategoryName");
    if (!set) return false;
    icli_as_mobile_user(^{ set((__bridge CFStringRef)@(category)); });
    return true;
}

static BOOL prepareAX(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *ax = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
        void *accessibility = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        if (accessibility) {
            applicationEnabled = dlsym(accessibility, "_AXSApplicationAccessibilityEnabled");
            setApplicationEnabled = dlsym(accessibility, "_AXSApplicationAccessibilitySetEnabled");
            automationEnabled = dlsym(accessibility, "_AXSAutomationEnabled");
            setAutomationEnabled = dlsym(accessibility, "_AXSSetAutomationEnabled");
        }
        if (!ax) return;
        void (*client)(uint32_t) = dlsym(ax, "__AXSetRequestingClient");
        if (client) client(2);
        uint64_t (*override)(uint64_t) = dlsym(ax, "_AXOverrideRequestingClientType");
        if (override) override(2);
        createApp = dlsym(ax, "_AXUIElementCreateAppElementWithPid");
        copyAttribute = dlsym(ax, "AXUIElementCopyAttributeValue");
        setTimeout = dlsym(ax, "AXUIElementSetMessagingTimeout");
        getAXValue = dlsym(ax, "AXValueGetValue");
        hitTest = dlsym(ax, "AXUIElementCopyElementAtPosition");
        performAction = dlsym(ax, "AXUIElementPerformAction");
    });
    return createApp && copyAttribute && getAXValue;
}

static id attribute(AXElement element, uint32_t key) {
    CFTypeRef value = NULL;
    int error = copyAttribute(element, (CFStringRef)(uintptr_t)key, &value);
    if (error) { if (value) CFRelease(value); return nil; }
    return CFBridgingRelease(value);
}

// SpringBoard reports frames in the fixed (portrait) space; apps report them
// in the upright interface, which is what taps and screenshots use.
static BOOL framesInFixedSpace(pid_t pid) {
    char path[4096] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    return strcmp(path, "/System/Library/CoreServices/SpringBoard.app/SpringBoard") == 0;
}

static CGRect interfaceRect(CGRect fixed) {
    double x1, y1, x2, y2;
    icli_screen_fixed_to_point(CGRectGetMinX(fixed), CGRectGetMinY(fixed), &x1, &y1);
    icli_screen_fixed_to_point(CGRectGetMaxX(fixed), CGRectGetMaxY(fixed), &x2, &y2);
    return CGRectStandardize(CGRectMake(x1, y1, x2 - x1, y2 - y1));
}

static NSDictionary *serializeElement(AXElement element, BOOL fixedSpace) {
    if (setTimeout) setTimeout(element, 0.25f);
    id value = attribute(element, 2003);
    CGRect frame = CGRectZero;
    if (!value
        || !getAXValue((__bridge CFTypeRef)value, 3, &frame)
        || !isfinite(frame.origin.x)
        || !isfinite(frame.origin.y)
        || !isfinite(frame.size.width)
        || !isfinite(frame.size.height))
        return nil;
    id label = attribute(element, 2001);
    id text = attribute(element, 2006);
    id identifier = attribute(element, 5019);
    id traitsValue = attribute(element, 2004);
    uint64_t traits = [traitsValue respondsToSelector:@selector(unsignedLongLongValue)]
        ? [traitsValue unsignedLongLongValue]
        : 0;
    BOOL enabled = (traits & UIAccessibilityTraitNotEnabled) == 0;
    BOOL clickable = enabled
        && frame.size.width > 0
        && frame.size.height > 0
        && ((traits & (UIAccessibilityTraitButton | UIAccessibilityTraitLink | UIAccessibilityTraitAdjustable)) != 0
            || (traits & UIAccessibilityTraitStaticText) == 0);
    NSString *role = (traits & UIAccessibilityTraitButton)
        ? @"button"
        : ((traits & UIAccessibilityTraitStaticText) ? @"text" : @"element");
    IcliScreenMetrics metrics = icli_screen_metrics();
    CGRect screen = CGRectMake(0, 0, metrics.width, metrics.height);
    CGPoint point = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    // An element can report a NaN activation point; NSJSONSerialization throws on
    // one, which takes down a host such as vphoned. Keep the frame's centre then.
    id pointValue = attribute(element, 2007);
    CGPoint activation;
    if (pointValue && getAXValue((__bridge CFTypeRef)pointValue, 1, &activation)
        && isfinite(activation.x) && isfinite(activation.y)) point = activation;
    if (fixedSpace) {
        frame = interfaceRect(frame);
        double x, y;
        icli_screen_fixed_to_point(point.x, point.y, &x, &y);
        point = CGPointMake(x, y);
    }
    return @{
        @"label": [label isKindOfClass:NSString.class] ? label : @"",
        @"identifier": [identifier isKindOfClass:NSString.class] ? identifier : @"",
        @"value": [text isKindOfClass:NSString.class]
            || ([text isKindOfClass:NSNumber.class] && isfinite([text doubleValue])) ? text : @"",
        @"role": role,
        @"traits": @(traits),
        @"enabled": @(enabled),
        @"clickable": @(clickable),
        @"visible": @(!CGRectIsEmpty(CGRectIntersection(frame, screen))),
        @"frame": @{
            @"x": @(frame.origin.x),
            @"y": @(frame.origin.y),
            @"width": @(frame.size.width),
            @"height": @(frame.size.height)
        },
        @"x": @(point.x),
        @"y": @(point.y)
    };
}

// How deep an element sits: its parent chain (attribute 5002, what -[AXElement parent]
// reads in AXRuntime 17.1.1) up to the application, which is depth 0. Elements share
// their containers, so each container's depth is looked up once per query.
static NSInteger elementDepth(AXElement element, CFMutableDictionaryRef depths, int levels) {
    CFNumberRef known = CFDictionaryGetValue(depths, element);
    if (known) return [(__bridge NSNumber *)known integerValue];
    NSInteger depth = 0;
    CFTypeRef parent = NULL;
    if (levels > 0 && copyAttribute(element, (CFStringRef)(uintptr_t)5002, &parent) == 0 && parent
        && CFGetTypeID(parent) == CFGetTypeID(element) && !CFEqual(parent, element)) {
        if (setTimeout) setTimeout(parent, 0.25f);
        depth = elementDepth(parent, depths, levels - 1) + 1;
    }
    if (parent) CFRelease(parent);
    CFDictionarySetValue(depths, element, (__bridge CFNumberRef)@(depth));
    return depth;
}

static NSDictionary *elementsResultForTarget(int pid, int max_elements, NSString *identifier, AXElement *target,
                                             BOOL hierarchy) {
    AXElement root = createApp(pid);
    if (!root) return @{@"error": @"AX application unavailable"};
    if (setTimeout) setTimeout(root, 0.5f);
    CFTypeRef value = NULL;
    int error = copyAttribute(root, (CFStringRef)(uintptr_t)3015, &value);
    CFRelease(root);
    if (error || !value || CFGetTypeID(value) != CFArrayGetTypeID()) {
        if (value) CFRelease(value);
        return @{
            @"error": [NSString stringWithFormat:@"AX element query failed (%d)", error],
            @"pid": @(pid)
        };
    }
    NSArray *elements = CFBridgingRelease(value);
    NSMutableArray *rows = [NSMutableArray array];
    BOOL fixedSpace = framesInFixedSpace(pid);
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
    BOOL truncated = NO;
    AXElement chosen = NULL;
    NSUInteger matches = 0;
    CFMutableDictionaryRef depths = hierarchy
        ? CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
        : NULL;
    for (id element in elements) {
        if (rows.count >= (NSUInteger)max_elements || NSProcessInfo.processInfo.systemUptime >= deadline) {
            truncated = YES;
            break;
        }
        NSDictionary *node = serializeElement((__bridge AXElement)element, fixedSpace);
        if (node && depths) {
            NSMutableDictionary *nested = [node mutableCopy];
            nested[@"depth"] = @(elementDepth((__bridge AXElement)element, depths, 64));
            node = nested;
        }
        if (node) [rows addObject:node];
        if (target && [node[@"visible"] boolValue] && [node[@"identifier"] isEqual:identifier]) {
            matches++;
            if (!chosen) chosen = CFRetain((__bridge AXElement)element);
        }
    }
    if (depths) CFRelease(depths);
    if (target && matches == 1 && !truncated) *target = chosen;
    else if (chosen) CFRelease(chosen);
    return @{
        @"source": @"ax",
        @"pid": @(pid),
        @"elements": rows,
        @"count": @(rows.count),
        @"truncated": @(truncated)
    };
}

static NSDictionary *elementsResult(int pid, int max_elements, BOOL hierarchy) {
    return elementsResultForTarget(pid, max_elements, nil, NULL, hierarchy);
}

static NSDictionary *elementAtResult(int pid, double x, double y) {
    AXElement root = createApp(pid), hit = NULL;
    if (!root) return @{@"error": @"AX application unavailable"};
    if (setTimeout) setTimeout(root, 0.5f);
    double fx = x, fy = y;
    icli_screen_point_to_fixed(x, y, &fx, &fy);
    int error = hitTest(root, &hit, (float)fx, (float)fy);
    CFRelease(root);
    if (error) {
        if (hit) CFRelease(hit);
        return @{@"error": [NSString stringWithFormat:@"AX hit testing failed (%d)", error]};
    }
    NSDictionary *node = hit ? serializeElement(hit, framesInFixedSpace(pid)) : nil;
    if (hit) CFRelease(hit);
    return @{@"source": @"ax", @"element": node ?: @{}, @"x": @(x), @"y": @(y)};
}

// An app running while the switches were off loads its accessibility bundles only
// once they turn on, so the query that turned them on can arrive before the app
// answers. Only that first query waits and asks again.
static const useconds_t kBundleLoadWait = 400000;

char *icli_ax_elements_json(int pid, int max_elements) {
    return icli_ax_elements_hierarchy_json(pid, max_elements, false);
}

char *icli_ax_elements_hierarchy_json(int pid, int max_elements, bool hierarchy) {
    if (pid <= 0 || max_elements < 1 || max_elements > 2000) return icli_json(@{@"error": @"invalid AX query"});
    if (!prepareAX()) return icli_json(@{@"error": @"AX runtime unavailable"});
    BOOL enabled = enableSwitches();
    NSDictionary *result = elementsResult(pid, max_elements, hierarchy);
    if (enabled && [result[@"count"] unsignedIntegerValue] == 0) {
        usleep(kBundleLoadWait);
        result = elementsResult(pid, max_elements, hierarchy);
    }
    // An app in the middle of loading a screen answers -25216, then recovers.
    for (int retry = 0; retry < 15 && [result[@"error"] hasSuffix:@"(-25216)"]; retry++) {
        usleep(100000);
        result = elementsResult(pid, max_elements, hierarchy);
    }
    return icli_json(result);
}

char *icli_ax_element_at_json(int pid, double x, double y) {
    if (pid <= 0 || !prepareAX() || !hitTest) return icli_json(@{@"error": @"AX hit testing unavailable"});
    BOOL enabled = enableSwitches();
    NSDictionary *result = elementAtResult(pid, x, y);
    if (enabled && ((NSDictionary *)result[@"element"]).count == 0) {
        usleep(kBundleLoadWait);
        result = elementAtResult(pid, x, y);
    }
    return icli_json(result);
}

// The actions VoiceOver's three-finger swipes use, read from AXRuntime 17.1.1
// (-[AXElement scrollAncestorForScrollAction:]): each has an attribute naming the
// nearest ancestor that can scroll that way, nil at the end of the content or
// where accessibility cannot scroll the view. Attribute 2057 is an element's frame
// clipped to what its scroll views and bars leave visible; action 2003 scrolls the
// element into view.
static const struct { const char *name; uint32_t action, ancestor; } kScrollDirections[] = {
    {"down", 2006, 2109}, {"up", 2007, 2108}, {"left", 2008, 2106}, {"right", 2009, 2107},
};

static BOOL isElement(id value) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) != CFArrayGetTypeID();
}

// The scroll view the first page of a search moved.
static id sPagedView;

char *icli_ax_scroll_page_json(int pid, double x, double y, const char *direction, bool sameView) {
    uint32_t action = 0, ancestorKey = 0;
    for (size_t i = 0; direction && i < sizeof(kScrollDirections) / sizeof(*kScrollDirections); i++) {
        if (strcmp(direction, kScrollDirections[i].name) == 0) {
            action = kScrollDirections[i].action;
            ancestorKey = kScrollDirections[i].ancestor;
        }
    }
    if (pid <= 0 || !action || !prepareAX() || !hitTest || !performAction) {
        return icli_json(@{@"error": @"AX scrolling unavailable"});
    }
    enableSwitches();
    AXElement root = createApp(pid), hit = NULL;
    if (!root) return icli_json(@{@"error": @"AX application unavailable"});
    if (setTimeout) setTimeout(root, 0.5f);
    double fx = x, fy = y;
    icli_screen_point_to_fixed(x, y, &fx, &fy);
    hitTest(root, &hit, (float)fx, (float)fy);
    NSMutableArray *candidates = [NSMutableArray array];
    if (hit) [candidates addObject:(__bridge_transfer id)hit];
    // The scroll view this direction, if it is the one already being paged: past the
    // end of a list an element can name another, such as one in SpringBoard.
    if (!sameView) sPagedView = nil;
    id (^usable)(id) = ^id(id element) {
        id candidate = attribute((__bridge AXElement)element, ancestorKey);
        if (!isElement(candidate)) return nil;
        if (sameView && !(sPagedView && CFEqual((__bridge CFTypeRef)candidate, (__bridge CFTypeRef)sPagedView))) return nil;
        return candidate;
    };
    id ancestor = hit ? usable(candidates[0]) : nil;
    if (!ancestor) {
        // The point can fall between rows or on something outside the list:
        // the nearest elements tell which scroll view is meant.
        BOOL fixedSpace = framesInFixedSpace(pid);
        CGPoint point = fixedSpace ? CGPointMake(fx, fy) : CGPointMake(x, y);
        NSMutableArray<NSArray *> *near = [NSMutableArray array];
        id elements = attribute(root, 3015);
        for (id element in [elements isKindOfClass:NSArray.class] ? elements : @[]) {
            id value = attribute((__bridge AXElement)element, 2003);
            CGRect frame;
            if (!value || !getAXValue((__bridge CFTypeRef)value, 3, &frame)) continue;
            double dx = MAX(MAX(CGRectGetMinX(frame) - point.x, point.x - CGRectGetMaxX(frame)), 0);
            double dy = MAX(MAX(CGRectGetMinY(frame) - point.y, point.y - CGRectGetMaxY(frame)), 0);
            [near addObject:@[@(hypot(dx, dy)), element]];
        }
        [near sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
        for (NSUInteger i = 0; i < near.count && i < 8; i++) [candidates addObject:near[i][1]];
        for (NSUInteger i = hit ? 1 : 0; i < candidates.count && !ancestor; i++) ancestor = usable(candidates[i]);
    }
    CFRelease(root);
    if (isElement(ancestor)) {
        int error = performAction((__bridge AXElement)ancestor, action);
        if (error == 0) sPagedView = ancestor;
        return icli_json(@{@"moved": @(error == 0), @"ancestor": @YES, @"ax_error": @(error)});
    }
    // No page this way. A scroll view that pages some other way still says how
    // big it is, so a touch stroke can be kept short enough not to skip anything.
    NSMutableDictionary *result = [@{@"moved": @NO, @"ancestor": @NO} mutableCopy];
    for (id element in candidates) {
        for (size_t i = 0; i < sizeof(kScrollDirections) / sizeof(*kScrollDirections); i++) {
            id other = attribute((__bridge AXElement)element, kScrollDirections[i].ancestor);
            id value = isElement(other) ? attribute((__bridge AXElement)other, 2057) : nil;
            CGRect visible;
            if (value && getAXValue((__bridge CFTypeRef)value, 3, &visible) && !CGRectIsEmpty(visible)) {
                result[@"viewport_width"] = @(visible.size.width);
                result[@"viewport_height"] = @(visible.size.height);
                return icli_json(result);
            }
        }
    }
    return icli_json(result);
}

char *icli_ax_reveal_json(int pid, const char *label, const char *identifier, double x, double y) {
    if (pid <= 0 || !label || !identifier || !prepareAX() || !performAction) {
        return icli_json(@{@"error": @"AX scrolling unavailable"});
    }
    enableSwitches();
    AXElement root = createApp(pid);
    if (!root) return icli_json(@{@"error": @"AX application unavailable"});
    if (setTimeout) setTimeout(root, 0.5f);
    id elements = attribute(root, 3015);
    CFRelease(root);
    BOOL fixedSpace = framesInFixedSpace(pid);
    NSString *wantLabel = @(label), *wantIdentifier = @(identifier);
    for (id element in [elements isKindOfClass:NSArray.class] ? elements : @[]) {
        AXElement target = (__bridge AXElement)element;
        NSDictionary *node = serializeElement(target, fixedSpace);
        if (![node[@"label"] isEqual:wantLabel] || ![node[@"identifier"] isEqual:wantIdentifier]
            || fabs([node[@"x"] doubleValue] - x) > 1 || fabs([node[@"y"] doubleValue] - y) > 1) {
            continue;
        }
        id visibleValue = attribute(target, 2057), frameValue = attribute(target, 2003), pointValue = attribute(target, 2007);
        CGRect visible, frame;
        if (!visibleValue || !getAXValue((__bridge CFTypeRef)visibleValue, 3, &visible) || CGRectIsEmpty(visible)
            || !frameValue || !getAXValue((__bridge CFTypeRef)frameValue, 3, &frame)) {
            return icli_json(@{@"found": @YES, @"clipped": @NO});
        }
        CGPoint point = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame)), activation;
        if (pointValue && getAXValue((__bridge CFTypeRef)pointValue, 1, &activation)
            && isfinite(activation.x) && isfinite(activation.y)) point = activation;
        if (CGRectContainsPoint(visible, point)) return icli_json(@{@"found": @YES, @"clipped": @NO});
        int error = performAction(target, 2003);
        return icli_json(@{@"found": @YES, @"clipped": @YES, @"revealed": @(error == 0), @"ax_error": @(error)});
    }
    return icli_json(@{@"found": @NO});
}

struct IcliAXActivationTarget {
    AXElement element;
    int pid;
    atomic_bool attempted;
};

void icli_ax_activation_target_free(IcliAXActivationTarget *target) {
    if (!target) return;
    if (target->element) CFRelease(target->element);
    free(target);
}

IcliAXActivationTarget *icli_ax_activation_target_create(int pid, const char *identifier, char **report) {
    if (report) *report = NULL;
    NSDictionary *failure = @{@"error": @"direct AX activation unavailable"};
    IcliAXActivationTarget *target = NULL;
    AXElement element = NULL;
    if (pid > 0 && identifier && identifier[0] && prepareAX() && performAction && hitTest) {
        enableSwitches();
        NSDictionary *result = elementsResultForTarget(pid, 2000, @(identifier), &element, NO);
        failure = result[@"error"] ? result : @{@"error": @"direct activation target missing, ambiguous or truncated"};
        if (element) {
            NSDictionary *node = serializeElement(element, framesInFixedSpace(pid));
            // iOS 17.1.1: AXElement.canPerformActivate reads 2019. It is only
            // an advertisement, not a guarantee that the handler returns YES.
            id capable = attribute(element, 2019);
            if (![node[@"enabled"] boolValue] || ![node[@"clickable"] boolValue]
                || ![node[@"visible"] boolValue] || ![capable isKindOfClass:NSNumber.class] || ![capable boolValue]) {
                failure = @{@"error": @"target does not advertise enabled direct activation"};
            } else {
                target = calloc(1, sizeof(*target));
                if (target) {
                    target->element = element;
                    target->pid = pid;
                    atomic_init(&target->attempted, false);
                    if (report) *report = icli_json(@{@"element":node});
                    return target;
                }
                failure = @{@"error": @"activation target allocation failed"};
            }
            CFRelease(element);
        }
    }
    if (report) *report = icli_json(failure);
    return NULL;
}

char *icli_ax_activation_target_hit_json(IcliAXActivationTarget *target, double x, double y) {
    if (!target || !hitTest || !isfinite(x) || !isfinite(y))
        return icli_json(@{@"error": @"activation hit test unavailable"});
    AXElement root = createApp(target->pid), hit = NULL;
    if (!root) return icli_json(@{@"error": @"AX application unavailable"});
    if (setTimeout) setTimeout(root, 0.5f);
    double fx, fy;
    icli_screen_point_to_fixed(x, y, &fx, &fy);
    int error = hitTest(root, &hit, (float)fx, (float)fy);
    CFRelease(root);
    BOOL same = !error && hit && CFEqual(hit, target->element);
    NSDictionary *row = same ? serializeElement(hit, framesInFixedSpace(target->pid)) : nil;
    if (hit) CFRelease(hit);
    return icli_json(row ? @{@"element":row} : @{@"error": @"retained activation target changed or occluded"});
}

int icli_ax_activation_target_perform(IcliAXActivationTarget *target) {
    if (!target || !performAction || atomic_exchange(&target->attempted, true)) return -25201;
    if (setTimeout) setTimeout(target->element, 0.5f);
    // Traced in 21B91: _performActivate sends 2010; the app-side action
    // handler calls accessibilityActivate. AXElement.press instead can send
    // system action 5008 (a coordinate event), so it must never be used here.
    return performAction(target->element, 2010);
}
