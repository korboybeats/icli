#import <Foundation/Foundation.h>
#include <assert.h>

int icli_cc_silent_get(void);
int icli_cc_silent_set(bool);

@interface AVSystemController : NSObject
@property(nonatomic) BOOL muted;
@property(nonatomic) NSString *behavior;
@property(nonatomic) NSUInteger writes;
@property(nonatomic) NSUInteger callbacks;
+ (instancetype)sharedAVSystemController;
@end

@implementation AVSystemController
+ (instancetype)sharedAVSystemController {
    static AVSystemController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [self new]; });
    return controller;
}
- (BOOL)respondsToSelector:(SEL)selector {
    if ([self.behavior isEqual:@"missing-get"] && selector == @selector(getSilentMode:error:)) return NO;
    if ([self.behavior isEqual:@"missing-set"] && selector == @selector(setSilentMode:untilTime:reason:clientType:)) return NO;
    return [super respondsToSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if ([self.behavior isEqual:@"wrong-get-abi"] && selector == @selector(getSilentMode:error:))
        return [NSMethodSignature signatureWithObjCTypes:"B@:^f^@"];
    if ([self.behavior isEqual:@"wrong-set-abi"] && selector == @selector(setSilentMode:untilTime:reason:clientType:))
        return [NSMethodSignature signatureWithObjCTypes:"v@:B@@Q"];
    return [super methodSignatureForSelector:selector];
}
- (BOOL)getSilentMode:(BOOL *)muted error:(NSError **)error {
    if ([self.behavior isEqual:@"throw-get"]) [NSException raise:@"fixture" format:@"getter exception"];
    assert(muted && error);
    *muted = self.muted;
    if ([self.behavior isEqual:@"zero-error"]) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:0 userInfo:nil];
    }
    if ([self.behavior isEqual:@"error-get"] || ([self.behavior isEqual:@"lost-state"] && self.writes)) {
        *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
        return NO;
    }
    return YES;
}
- (BOOL)setSilentMode:(BOOL)muted untilTime:(NSDate *)until reason:(NSString *)reason clientType:(unsigned int)client {
    self.writes++;
    assert(until == nil && [reason isEqual:@"icli cc silent"] && client == 2);
    if ([self.behavior isEqual:@"throw-set"]) [NSException raise:@"fixture" format:@"setter exception"];
    if ([self.behavior isEqual:@"reject"]) return NO;
    if ([self.behavior isEqual:@"never"] || [self.behavior isEqual:@"lost-state"]) return YES;
    if ([self.behavior isEqual:@"immediate"]) { self.muted = muted; return YES; }
    [NSTimer scheduledTimerWithTimeInterval:0.015 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        self.muted = muted;
        self.callbacks++;
    }];
    return YES;
}
@end

static AVSystemController *reset(NSString *behavior) {
    AVSystemController *controller = [AVSystemController sharedAVSystemController];
    controller.muted = NO;
    controller.behavior = behavior;
    controller.writes = 0;
    controller.callbacks = 0;
    return controller;
}

int main(void) {
    @autoreleasepool {
        for (NSString *behavior in @[@"immediate", @"callback", @"zero-error"]) {
            AVSystemController *c = reset(behavior);
            assert(icli_cc_silent_get() == 0);
            assert(icli_cc_silent_set(false) == 0 && c.writes == 0);
            assert(icli_cc_silent_set(true) == 0 && icli_cc_silent_get() == 1 && c.writes == 1);
            assert(icli_cc_silent_set(true) == 0 && c.writes == 1);
            assert(icli_cc_silent_set(false) == 0 && icli_cc_silent_get() == 0 && c.writes == 2);
            assert(icli_cc_silent_set(false) == 0 && c.writes == 2);
            assert(c.callbacks == ([behavior isEqual:@"immediate"] ? 0u : 2u));
        }
        for (NSString *behavior in @[@"missing-get", @"wrong-get-abi", @"error-get", @"throw-get"]) {
            AVSystemController *c = reset(behavior);
            assert(icli_cc_silent_get() == -1);
            assert(icli_cc_silent_set(true) == -1 && c.writes == 0);
        }
        for (NSString *behavior in @[@"missing-set", @"wrong-set-abi"]) {
            AVSystemController *c = reset(behavior);
            assert(icli_cc_silent_set(true) == -1 && c.writes == 0);
        }
        for (NSString *behavior in @[@"reject", @"throw-set"]) {
            AVSystemController *c = reset(behavior);
            assert(icli_cc_silent_set(true) == -3 && c.writes == 1 && !c.muted);
        }
        reset(@"lost-state");
        assert(icli_cc_silent_set(true) == -1);
        AVSystemController *c = reset(@"never");
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        assert(icli_cc_silent_set(true) == -2);
        assert(NSProcessInfo.processInfo.systemUptime - start >= 3);
        assert(c.writes == 1 && !c.muted);
        puts("PASS Silent mode: both directions, run-loop callback completion, idempotence, missing/wrong ABI, getter errors, rejection, exceptions, lost state, accepted-but-unconfirmed timeout");
    }
}
