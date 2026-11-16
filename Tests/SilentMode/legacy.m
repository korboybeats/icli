#import <Foundation/Foundation.h>
#include <assert.h>

int icli_cc_silent_get(void);
int icli_cc_silent_set(bool);

static NSString *behavior;
static id reply;
static NSUInteger reads;
static NSUInteger messages;
static NSUInteger writes;
static BOOL modernAPI;

bool fixtureModernSilentAPI(void) { return modernAPI; }
int icli_springboard_ringer_set(bool enabled) {
    writes++;
    if ([behavior isEqual:@"reject"]) return -3;
    if ([behavior isEqual:@"unavailable"]) return -1;
    if ([behavior isEqual:@"lost-state"]) { reply = nil; return 0; }
    if ([behavior isEqual:@"never"]) return 0;
    if ([behavior isEqual:@"delayed"]) {
        [NSTimer scheduledTimerWithTimeInterval:0.015 repeats:NO block:^(NSTimer *timer) {
            (void)timer;
            reply = @(enabled);
        }];
    } else {
        reply = @(enabled);
    }
    return 0;
}

// Older systems have no qualified standalone AVSystemController silent client.
@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
@end
@implementation AVSystemController
+ (id)sharedAVSystemController { return nil; }
@end

@interface AXIPCMessage : NSObject
@property(nonatomic) int key;
- (instancetype)initWithKey:(int)key payload:(id)payload;
@end
@implementation AXIPCMessage
- (BOOL)respondsToSelector:(SEL)selector {
    if ([behavior isEqual:@"missing-init"] && selector == @selector(initWithKey:payload:)) return NO;
    return [super respondsToSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if ([behavior isEqual:@"wrong-init-abi"] && selector == @selector(initWithKey:payload:))
        return [NSMethodSignature signatureWithObjCTypes:"@@:q@"];
    return [super methodSignatureForSelector:selector];
}
- (instancetype)initWithKey:(int)key payload:(id)payload {
    if ([behavior isEqual:@"throw-init"]) [NSException raise:@"fixture" format:@"initializer exception"];
    if ([behavior isEqual:@"nil-message"]) return nil;
    assert(key == 4020 && payload == nil);
    self = [super init];
    if (self) { _key = key; messages++; }
    return self;
}
@end

@interface AXSpringBoardServer : NSObject
+ (instancetype)server;
@end
@implementation AXSpringBoardServer
+ (BOOL)respondsToSelector:(SEL)selector {
    if ([behavior isEqual:@"missing-server"] && selector == @selector(server)) return NO;
    return [super respondsToSelector:selector];
}
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if ([behavior isEqual:@"wrong-server-abi"] && selector == @selector(server))
        return [NSMethodSignature signatureWithObjCTypes:"q@:"];
    return [super methodSignatureForSelector:selector];
}
+ (instancetype)server {
    if ([behavior isEqual:@"throw-server"]) [NSException raise:@"fixture" format:@"server exception"];
    if ([behavior isEqual:@"nil-server"]) return nil;
    static AXSpringBoardServer *server;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ server = [self new]; });
    return server;
}
- (BOOL)respondsToSelector:(SEL)selector {
    if ([behavior isEqual:@"missing-get"] && selector == @selector(isRingerMuted)) return NO;
    if ([behavior isEqual:@"missing-object-get"] && selector == @selector(sendSimpleMessageWithObjectResult:)) return NO;
    return [super respondsToSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if ([behavior isEqual:@"wrong-get-abi"] && selector == @selector(isRingerMuted))
        return [NSMethodSignature signatureWithObjCTypes:"q@:"];
    if ([behavior isEqual:@"wrong-object-get-abi"] && selector == @selector(sendSimpleMessageWithObjectResult:))
        return [NSMethodSignature signatureWithObjCTypes:"B@:@"];
    return [super methodSignatureForSelector:selector];
}
- (BOOL)isRingerMuted {
    assert(!"The native BOOL wrapper must not hide a missing server reply");
    return NO;
}
- (id)sendSimpleMessageWithObjectResult:(AXIPCMessage *)message {
    assert(message.key == 4020);
    reads++;
    if ([behavior isEqual:@"throw-get"]) [NSException raise:@"fixture" format:@"getter exception"];
    return reply;
}
@end

static void reset(NSString *mode, id result) {
    behavior = mode;
    reply = result;
    reads = 0;
    messages = 0;
    writes = 0;
    modernAPI = NO;
}

int main(void) {
    @autoreleasepool {
        for (NSNumber *state in @[@NO, @YES]) {
            reset(@"native", state);
            assert(icli_cc_silent_get() == state.intValue);
            assert(reads == 1 && messages == 1);
            assert(icli_cc_silent_set(state.boolValue) == 0 && writes == 0);
            assert(icli_cc_silent_set(!state.boolValue) == 0 && writes == 1);
            assert(icli_cc_silent_get() == !state.boolValue);
        }
        for (NSString *mode in @[@"missing-server", @"wrong-server-abi", @"nil-server", @"throw-server",
                                 @"missing-get", @"wrong-get-abi", @"missing-object-get", @"wrong-object-get-abi",
                                 @"missing-init", @"wrong-init-abi", @"nil-message", @"throw-init"]) {
            reset(mode, @YES);
            assert(icli_cc_silent_get() == -1);
            assert(reads == 0);
            int expected = [mode hasPrefix:@"throw-"] ? -3 : -1;
            assert(icli_cc_silent_set(false) == expected && writes == 0);
        }
        reset(@"throw-get", @YES);
        assert(icli_cc_silent_get() == -1 && reads == 1);
        for (id invalid in @[NSNull.null, @"0", @"1", @2, @(-1), @{}, @[]]) {
            reset(@"native", invalid);
            assert(icli_cc_silent_get() == -1 && reads == 1);
            assert(icli_cc_silent_set(true) == -1 && writes == 0);
        }
        reset(@"native", nil);
        assert(icli_cc_silent_get() == -1 && reads == 1);
        assert(icli_cc_silent_set(true) == -1 && writes == 0);
        reset(@"delayed", @NO);
        assert(icli_cc_silent_set(true) == 0 && writes == 1 && reads > 2);
        reset(@"reject", @NO);
        assert(icli_cc_silent_set(true) == -3 && writes == 1 && reads == 1);
        reset(@"unavailable", @NO);
        assert(icli_cc_silent_set(true) == -1 && writes == 1 && reads == 1);
        reset(@"lost-state", @NO);
        assert(icli_cc_silent_set(true) == -1 && writes == 1 && reads == 2);
        reset(@"never", @NO);
        assert(icli_cc_silent_set(true) == -2 && writes == 1 && reads > 2);
        reset(@"native", @NO);
        modernAPI = YES;
        assert(icli_cc_silent_set(true) == -1 && writes == 0 && reads == 0);
        puts("PASS legacy Silent mode: off/on, idempotence, delayed confirmation, timeout, native failures, invalid/absent state, exceptions, modern policy preserved");
    }
}
