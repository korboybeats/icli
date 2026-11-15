#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <string.h>

// Verified in iOS 17.1.1 MediaExperience; see
// docs/development/silent-mode-validation.md for addresses, ABI and constants.
// This is the system Silent mode property, independent of category volumes.
enum { SilentModeClientControlCenter = 2 };

// iOS 14-16 AXSpringBoardServer isRingerMuted sends this native read request.
// AXIPCMessage's key is a signed 32-bit int, not NSInteger.
enum { SilentModeRingerMutedMessage = 4020 };
@protocol IcliSilentModeMessage <NSObject>
- (instancetype)initWithKey:(int)key payload:(id)payload;
@end

static id silentController(void) {
#if TARGET_OS_TV
    return nil;
#else
    // The standalone native setter was introduced in iOS 17.
    if (@available(iOS 17.0, *)) {
        Class cls = NSClassFromString(@"AVSystemController");
        if (!cls) {
            dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_NOW);
            cls = NSClassFromString(@"AVSystemController");
        }
        SEL shared = @selector(sharedAVSystemController);
        if ([cls respondsToSelector:shared]) return ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    }
    return nil;
#endif
}

static const char *unqualified(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL signature(id object, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    if (![object respondsToSelector:selector]) return NO;
    NSMethodSignature *sig = [object methodSignatureForSelector:selector];
    if (!sig || sig.numberOfArguments != arguments.count + 2 ||
        strcmp(unqualified(sig.methodReturnType), result)) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp(unqualified([sig getArgumentTypeAtIndex:i + 2]), arguments[i].UTF8String)) return NO;
    }
    return YES;
}

static int silentState(id controller) {
    @try {
        SEL get = @selector(getSilentMode:error:);
        if (!signature(controller, get, @encode(BOOL), @[@(@encode(BOOL *)), @"^@"])) return -1;
        BOOL muted = NO;
        NSError *error = nil;
        BOOL ok = ((BOOL (*)(id, SEL, BOOL *, NSError **))objc_msgSend)(controller, get, &muted, &error);
        // iOS 17.1.1 fills NSError even on success, with OSStatus code zero.
        return ok && (!error || error.code == 0) ? (muted ? 1 : 0) : -1;
    } @catch (NSException *exception) { return -1; }
}

static int legacySilentState(void) {
#if TARGET_OS_TV
    return -1;
#else
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW);
    Class cls = NSClassFromString(@"AXSpringBoardServer");
    SEL shared = @selector(server);
    if (!signature(cls, shared, "@", @[])) return -1;
    id server = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    SEL get = @selector(sendSimpleMessageWithObjectResult:);
    if (!signature(server, @selector(isRingerMuted), @encode(BOOL), @[]) ||
        !signature(server, get, "@", @[@"@"])) return -1;

    Class messageClass = NSClassFromString(@"AXIPCMessage");
    id<IcliSilentModeMessage> allocated = [messageClass alloc];
    if (!signature(allocated, @selector(initWithKey:payload:), "@", @[@"i", @"@"])) return -1;
    id message = [allocated initWithKey:SilentModeRingerMutedMessage payload:nil];
    if (!message) return -1;
    // The BOOL wrapper sends this same request, but boolValue turns a missing
    // server reply into NO. Preserve the native NSNumber result so an absent
    // service, missing result or malformed reply cannot be reported as off.
    id result = ((id (*)(id, SEL, id))objc_msgSend)(server, get, message);
    if (![result isKindOfClass:NSNumber.class] ||
        (![result isEqual:@NO] && ![result isEqual:@YES])) return -1;
    return [result boolValue] ? 1 : 0;
#endif
}

int icli_cc_silent_get(void) {
    @try {
        id controller = silentController();
        return controller ? silentState(controller) : legacySilentState();
    }
    @catch (NSException *exception) { return -1; }
}

int icli_cc_silent_set(bool enabled) {
    @try {
        id controller = silentController();
        int before = silentState(controller);
        if (before < 0) return -1;
        if (before == (enabled ? 1 : 0)) return 0;
        SEL set = @selector(setSilentMode:untilTime:reason:clientType:);
        if (!signature(controller, set, @encode(BOOL), @[@(@encode(BOOL)), @"@", @"@", @"I"])) return -1;
        BOOL accepted = ((BOOL (*)(id, SEL, BOOL, id, id, unsigned int))objc_msgSend)(
            controller, set, enabled, nil, @"icli cc silent", SilentModeClientControlCenter);
        if (!accepted) return -3;

        // Acceptance is not completion. Service the calling thread's run loop
        // and read the native property until it agrees, or the deadline passes.
        // No subscription, timer or polling work survives this command.
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 3;
        for (;;) {
            int state = silentState(controller);
            if (state < 0) return -1;
            if (state == (enabled ? 1 : 0)) return 0;
            NSTimeInterval left = deadline - NSProcessInfo.processInfo.systemUptime;
            if (left <= 0) return -2;
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:MIN(left, 0.05)]];
        }
    } @catch (NSException *exception) { return -3; }
}
