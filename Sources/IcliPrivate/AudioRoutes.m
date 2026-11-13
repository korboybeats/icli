#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <math.h>

// The Audio/Video route dictionaries and BOOL(id, id) setter were measured
// on iOS 17.1.1. Keep the original dictionary, including opaque native keys.
static id audioController(void) {
    Class cls = NSClassFromString(@"AVSystemController");
    if (!cls) {
        dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
        cls = NSClassFromString(@"AVSystemController");
    }
    SEL sel = @selector(sharedAVSystemController);
    return [cls respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(cls, sel) : nil;
}

static NSDictionary *failure(NSString *code, NSString *message) {
    return @{@"error": code, @"message": message};
}

static NSString *nonemptyString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

static NSArray<NSDictionary *> *readRoutes(id controller) {
    SEL sel = @selector(pickableRoutesForCategory:);
    if (![controller respondsToSelector:sel]) return nil;
    id routes = ((id (*)(id, SEL, id))objc_msgSend)(controller, sel, @"Audio/Video");
    if (![routes isKindOfClass:NSArray.class]) return nil;
    NSMutableSet *uids = [NSMutableSet set];
    for (id route in routes) {
        if (![route isKindOfClass:NSDictionary.class]) return nil;
        NSString *uid = nonemptyString(route[@"RouteUID"]);
        // iOS omits RouteCurrentlyPicked entirely for some unselected routes.
        id picked = route[@"RouteCurrentlyPicked"];
        if (!uid || [uids containsObject:uid] || (picked && ![picked isKindOfClass:NSNumber.class])) return nil;
        [uids addObject:uid];
    }
    return routes;
}

static NSDictionary *snapshot(NSArray<NSDictionary *> *routes) {
    NSMutableArray *outputs = [NSMutableArray array];
    NSString *selectedUID = nil;
    NSUInteger picked = 0;
    for (NSDictionary *route in routes) {
        NSString *uid = route[@"RouteUID"];
        NSString *name = nonemptyString(route[@"RouteName"]) ?: nonemptyString(route[@"AVAudioRouteName"]) ?: uid;
        BOOL selected = [route[@"RouteCurrentlyPicked"] boolValue];
        [outputs addObject:@{@"name": name, @"uid": uid, @"selected": @(selected)}];
        if (selected) { selectedUID = uid; picked++; }
    }
    return @{@"routes": outputs, @"selected_uid": picked == 1 ? (id)selectedUID : NSNull.null};
}

static NSDictionary *routeWithUID(NSArray<NSDictionary *> *routes, NSString *uid) {
    for (NSDictionary *route in routes) if ([route[@"RouteUID"] isEqualToString:uid]) return route;
    return nil;
}

static NSString *nativeString(const char *symbol) {
    NSString * __unsafe_unretained *value = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, symbol);
    return value && [*value isKindOfClass:NSString.class] ? *value : nil;
}

static void routeWake(void *info) { (void)info; }

static id subscribeRouteChanges(id controller, NSArray<NSString *> *names) {
    NSString *key = nativeString("AVSystemController_SubscribeToNotificationsAttribute");
    if (!key || !names.count) return nil;
    id client = nil;
    @try {
        // iOS 17.1.1 requires this subscription before posting route events.
        // Use a separate client so an IcliKit host's shared controller keeps
        // its own subscriptions. Releasing this client ends our subscription.
        client = [[controller class] new];
        SEL sel = @selector(setAttribute:forKey:error:);
        NSMethodSignature *sig = [client methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 5 || strcmp(sig.methodReturnType, @encode(BOOL)) ||
            strcmp([sig getArgumentTypeAtIndex:2], "@") || strcmp([sig getArgumentTypeAtIndex:3], "@") ||
            !strstr([sig getArgumentTypeAtIndex:4], "^@")) return nil;
        NSError *error = nil;
        BOOL accepted = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(client, sel, names, key, &error);
        return accepted && !error ? client : nil;
    } @catch (NSException *exception) {
        return nil; // Verification still works through bounded native rereads.
    }
}

static NSDictionary *selectRoute(id controller, NSString *uid, double timeout) {
    NSArray *routes = readRoutes(controller);
    if (!routes) return failure(@"unavailable", @"Audio outputs cannot be read on this device.");
    NSMutableDictionary *result = [snapshot(routes) mutableCopy];
    result[@"requested_uid"] = uid;
    result[@"previous_uid"] = result[@"selected_uid"];
    NSDictionary *route = routeWithUID(routes, uid);
    if (!route) {
        [result addEntriesFromDictionary:failure(@"route_unavailable", @"The exact route UID is not available; run 'icli cc audio list'.")];
        return result;
    }
    if ([result[@"selected_uid"] isEqual:uid]) {
        result[@"changed"] = @NO;
        return result;
    }
    SEL setter = @selector(setPickedRouteWithPassword:withPassword:);
    NSMethodSignature *sig = [controller methodSignatureForSelector:setter];
    if (!sig || sig.numberOfArguments != 4 || strcmp(sig.methodReturnType, @encode(BOOL)) ||
        strcmp([sig getArgumentTypeAtIndex:2], "@") || strcmp([sig getArgumentTypeAtIndex:3], "@")) {
        [result addEntriesFromDictionary:failure(@"unavailable", @"Native audio-output selection is unavailable on this device.")];
        return result;
    }

    // Register before the request so a synchronous event cannot be lost.
    // A run-loop source also works on worker threads with no existing sources.
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    CFRunLoopSourceContext context = {0};
    context.perform = routeWake;
    CFRunLoopSourceRef source = CFRunLoopSourceCreate(NULL, 0, &context);
    id sourceLifetime = CFBridgingRelease(CFRetain(source));
    id loopLifetime = CFBridgingRelease(CFRetain(loop));
    CFRunLoopAddSource(loop, source, kCFRunLoopDefaultMode);
    NSMutableArray *observers = [NSMutableArray array];
    NSMutableArray *notificationNames = [NSMutableArray array];
    __attribute__((objc_precise_lifetime)) id eventClient = nil;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    @try {
        for (NSString *symbol in @[@"AVSystemController_ActiveAudioRouteDidChangeNotification",
                                   @"AVSystemController_PickableRoutesDidChangeNotification"]) {
            NSString *name = nativeString(symbol.UTF8String);
            if (!name) continue;
            [notificationNames addObject:name];
            id observer = [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                (void)note;
                CFRunLoopSourceSignal((__bridge CFRunLoopSourceRef)sourceLifetime);
                CFRunLoopWakeUp((__bridge CFRunLoopRef)loopLifetime);
            }];
            [observers addObject:observer];
        }
        eventClient = subscribeRouteChanges(controller, notificationNames);
        // Acceptance is only a receipt. Completion requires a fresh native read.
        BOOL accepted = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(controller, setter, route, @"");
        if (!accepted) {
            [result addEntriesFromDictionary:failure(@"route_rejected", @"The native audio service refused the route selection.")];
            return result;
        }
        double deadline = NSProcessInfo.processInfo.systemUptime + timeout;
        for (;;) {
            routes = readRoutes(controller);
            if (!routes) {
                [result addEntriesFromDictionary:failure(@"unavailable", @"Audio outputs became unreadable while verifying selection.")];
                return result;
            }
            [result addEntriesFromDictionary:snapshot(routes)];
            if ([result[@"selected_uid"] isEqual:uid]) {
                result[@"changed"] = @YES;
                return result;
            }
            if (!routeWithUID(routes, uid)) {
                [result addEntriesFromDictionary:failure(@"route_unavailable", @"The requested audio output disappeared before selection was confirmed.")];
                return result;
            }
            double remaining = deadline - NSProcessInfo.processInfo.systemUptime;
            if (remaining <= 0) {
                [result addEntriesFromDictionary:failure(@"timed_out", @"The requested audio output was not selected before the timeout; the native request was accepted but not confirmed.")];
                return result;
            }
            // Events wake this immediately. Bounded rereads cover missing events
            // and events arriving before the native route cache has updated.
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, fmin(remaining, 0.1), true);
        }
    } @catch (NSException *exception) {
        // Catch in this scope so ARC releases the local clients even when the
        // host builds without -fobjc-arc-exceptions.
        [result addEntriesFromDictionary:failure(@"failed", @"The native audio service failed during selection; the selected output is unconfirmed.")];
        return result;
    } @finally {
        for (id observer in observers) [center removeObserver:observer];
        eventClient = nil;
        CFRunLoopSourceInvalidate(source);
        CFRunLoopRemoveSource(loop, source, kCFRunLoopDefaultMode);
        CFRelease(source);
    }
}

char *icli_cc_audio_list_json(void) {
    @autoreleasepool {
        @try {
            NSArray *routes = readRoutes(audioController());
            return icli_json(routes ? snapshot(routes) : failure(@"unavailable", @"Audio outputs cannot be read on this device."));
        } @catch (NSException *exception) {
            return icli_json(failure(@"unavailable", @"The native audio service could not read the available outputs."));
        }
    }
}

char *icli_cc_audio_select_json(const char *routeUID, double timeout) {
    // Also drain temporary native clients in long-lived icli sessions/hosts.
    @autoreleasepool {
        @try {
            NSString *uid = routeUID ? [NSString stringWithUTF8String:routeUID] : nil;
            if (!uid.length || !isfinite(timeout) || timeout <= 0 || timeout > 60) {
                return icli_json(failure(@"failed", @"Selection requires a nonempty route UID and a finite timeout greater than 0 and at most 60 seconds."));
            }
            return icli_json(selectRoute(audioController(), uid, timeout));
        } @catch (NSException *exception) {
            return icli_json(failure(@"failed", @"The native audio service failed during selection; the selected output is unconfirmed."));
        }
    }
}
