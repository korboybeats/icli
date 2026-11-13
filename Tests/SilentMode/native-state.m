// Read-only physical-test oracle. No setters, playback or UI operations.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *encoding(id object, const char *selector) {
    Method method = class_getInstanceMethod(object_getClass(object), sel_registerName(selector));
    const char *type = method ? method_getTypeEncoding(method) : NULL;
    return type ? @(type) : @"missing";
}

int main(void) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW);
        Class av = NSClassFromString(@"AVSystemController");
        SEL shared = sel_registerName("sharedAVSystemController");
        id controller = [av respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(av, shared) : nil;
        NSMutableDictionary *volumes = [NSMutableDictionary dictionary];
        BOOL ok = controller != nil;
        SEL getVolume = sel_registerName("getVolume:forCategory:");
        for (NSString *category in @[@"Audio/Video", @"Ringtone", @"Alarm", @"Siri"]) {
            float value = -1;
            BOOL read = [controller respondsToSelector:getVolume] &&
                ((BOOL (*)(id, SEL, float *, id))objc_msgSend)(controller, getVolume, &value, category);
            volumes[category] = @{@"available": @(read), @"volume": @(value)};
            ok = ok && read && value >= 0 && value <= 1;
        }
        Class observerClass = NSClassFromString(@"AFDeviceRingerSwitchObserver");
        SEL sharedObserver = sel_registerName("sharedObserver");
        id observer = [observerClass respondsToSelector:sharedObserver] ?
            ((id (*)(id, SEL))objc_msgSend)(observerClass, sharedObserver) : nil;
        SEL state = sel_registerName("state");
        NSUInteger rawState = [observer respondsToSelector:state] ?
            ((NSUInteger (*)(id, SEL))objc_msgSend)(observer, state) : 0;
        ok = ok && (rawState == 1 || rawState == 2);
        // IDA: AXSpringBoardServer's BOOL getter sends message 4020 to the
        // SpringBoard server, which reads SBRingerControl on its access queue.
        // Never invoke an unknown ABI. Both directions are checked against
        // the independent AF observer, so a missing reply cannot pass as off.
        Class serverClass = NSClassFromString(@"AXSpringBoardServer");
        SEL sharedServer = sel_registerName("server");
        id server = [serverClass respondsToSelector:sharedServer] ?
            ((id (*)(id, SEL))objc_msgSend)(serverClass, sharedServer) : nil;
        SEL ringerMuted = sel_registerName("isRingerMuted");
        NSMethodSignature *sig = [server methodSignatureForSelector:ringerMuted];
        BOOL canReadSpringBoard = sig && sig.numberOfArguments == 2 && !strcmp(sig.methodReturnType, @encode(BOOL));
        BOOL sbMuted = canReadSpringBoard && ((BOOL (*)(id, SEL))objc_msgSend)(server, ringerMuted);
        ok = ok && canReadSpringBoard;
        NSDictionary *result = @{
            @"ok": @(ok), @"volumes": volumes, @"ringer_observer_state": @(rawState),
            @"ringer_observer_encoding": encoding(observer, "state"),
            @"get_encoding": encoding(controller, "getSilentMode:error:"),
            @"set_encoding": encoding(controller, "setSilentMode:untilTime:reason:clientType:"),
            @"springboard_muted": @(sbMuted), @"springboard_encoding": encoding(server, "isRingerMuted"),
            @"volume_encoding": encoding(controller, "getVolume:forCategory:")
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        return ok ? 0 : 1;
    }
}
