#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef struct { char error[240]; bool attempted; } FullUnlock;
static NSMutableArray *objects, *buffers, *operations;
static NSString *behavior;
static BOOL muted;
static unsigned writes;

@interface IcliRingerControl : NSObject
- (void)setRingerMuted:(BOOL)value;
@end
@implementation IcliRingerControl
- (BOOL)respondsToSelector:(SEL)selector {
    if ([behavior isEqual:@"missing-set"] && selector == @selector(setRingerMuted:)) return NO;
    return [super respondsToSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == @selector(setRingerMuted:)) {
        if ([behavior isEqual:@"wrong-set-result"]) return [NSMethodSignature signatureWithObjCTypes:"B@:B"];
        if ([behavior isEqual:@"wrong-set-argument"]) return [NSMethodSignature signatureWithObjCTypes:"v@:@"];
        if ([behavior isEqual:@"wrong-set-arity"]) return [NSMethodSignature signatureWithObjCTypes:"v@:"];
    }
    return [super methodSignatureForSelector:selector];
}
- (void)setRingerMuted:(BOOL)value {
    assert(NSThread.isMainThread);
    [operations addObject:@"setRingerMuted:"];
    muted = value;
    writes++;
}
@end

@interface IcliRingerWorkspace : NSObject
+ (instancetype)mainWorkspace;
+ (instancetype)sharedApplication;
- (id)ringerControl;
@end
@implementation IcliRingerWorkspace
+ (BOOL)respondsToSelector:(SEL)selector {
    if ([behavior isEqual:@"missing-workspace"] &&
        (selector == @selector(mainWorkspace) || selector == @selector(sharedApplication))) return NO;
    return [super respondsToSelector:selector];
}
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == @selector(mainWorkspace) || selector == @selector(sharedApplication)) {
        if ([behavior isEqual:@"wrong-factory"]) return [NSMethodSignature signatureWithObjCTypes:"q@:"];
        if ([behavior isEqual:@"block-factory"]) return [NSMethodSignature signatureWithObjCTypes:"@?@:"];
    }
    return [super methodSignatureForSelector:selector];
}
+ (instancetype)mainWorkspace {
    assert(NSThread.isMainThread);
    [operations addObject:@"mainWorkspace"];
    return [behavior isEqual:@"nil-workspace"] ? nil : [self new];
}
+ (instancetype)sharedApplication {
    assert(NSThread.isMainThread);
    [operations addObject:@"sharedApplication"];
    return [behavior isEqual:@"nil-workspace"] ? nil : [self new];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == @selector(ringerControl) && [behavior isEqual:@"wrong-control"])
        return [NSMethodSignature signatureWithObjCTypes:"q@:"];
    return [super methodSignatureForSelector:selector];
}
- (id)ringerControl {
    assert(NSThread.isMainThread);
    [operations addObject:@"ringerControl"];
    return [behavior isEqual:@"nil-control"] ? nil : [IcliRingerControl new];
}
@end

static bool fail(FullUnlock *s, const char *text) {
    if (!s->error[0]) strlcpy(s->error, text, sizeof(s->error));
    return false;
}
static bool readTask(FullUnlock *s, uint64_t address, void *out, size_t size) {
    if ([behavior isEqual:@"unreadable"]) return fail(s, "Unreadable fixture memory");
    memcpy(out, (void *)(uintptr_t)address, size);
    return true;
}
static uint64_t sel(FullUnlock *s, const char *name) {
    (void)s;
    return (uintptr_t)(void *)sel_registerName(name);
}
static uint64_t klass(FullUnlock *s, const char *name) {
    (void)s;
    if (!strcmp(name, "SBWorkspace") || !strcmp(name, "SpringBoard"))
        return [behavior isEqual:@"missing-class"] ? 0 : (uintptr_t)(__bridge void *)IcliRingerWorkspace.class;
    assert(!strcmp(name, "NSInvocation"));
    return (uintptr_t)(__bridge void *)NSInvocation.class;
}
static uint64_t data(FullUnlock *s, const void *bytes, size_t size) {
    if ([behavior isEqual:@"allocation-failure"]) { fail(s, "Allocation failure"); return 0; }
    NSMutableData *buffer = [NSMutableData dataWithBytes:bytes length:size];
    [buffers addObject:buffer];
    return (uintptr_t)buffer.mutableBytes;
}
// Replace only the cross-process call boundary; Foundation builds and invokes
// the actual NSInvocations produced by the native ringer implementation.
static uint64_t message(FullUnlock *s, uint64_t receiver, const char *name,
                        uint64_t a0, uint64_t a1, uint64_t a2) {
    if (s->error[0] || !receiver) return 0;
    id target = (__bridge id)(void *)(uintptr_t)receiver;
    SEL selector = sel_registerName(name);
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    assert(signature);
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    uint64_t arguments[] = {a0, a1, a2};
    assert(signature.numberOfArguments <= 5);
    for (NSUInteger i = 2; i < signature.numberOfArguments; i++)
        [invocation setArgument:&arguments[i - 2] atIndex:i];
    [invocation invoke];
    if (signature.methodReturnType[0] == '@') {
        __unsafe_unretained id result = nil;
        [invocation getReturnValue:&result];
        if (result) [objects addObject:result];
        return (uintptr_t)(__bridge void *)result;
    }
    uint64_t result = 0;
    assert(signature.methodReturnLength <= sizeof(result));
    if (signature.methodReturnLength) [invocation getReturnValue:&result];
    return result;
}

#include "ringer-production.inc"

int main(void) {
    @autoreleasepool {
        for (NSNumber *application in @[@NO, @YES]) {
            for (NSNumber *state in @[@NO, @YES]) {
                behavior = @"native";
                objects = [NSMutableArray new]; buffers = [NSMutableArray new]; operations = [NSMutableArray new];
                writes = 0;
                FullUnlock context = {0};
                assert(invokeRinger(&context, state.boolValue, application.boolValue));
                assert(context.attempted && !context.error[0] && writes == 1 && muted == state.boolValue);
                assert(([operations isEqual:@[application.boolValue ? @"sharedApplication" : @"mainWorkspace", @"ringerControl", @"setRingerMuted:"]]));
            }
            for (NSString *mode in @[@"missing-class", @"missing-workspace", @"wrong-factory", @"block-factory",
                                     @"nil-workspace", @"wrong-control", @"nil-control", @"missing-set",
                                     @"wrong-set-result", @"wrong-set-argument", @"wrong-set-arity",
                                     @"unreadable", @"allocation-failure"]) {
                behavior = mode;
                objects = [NSMutableArray new]; buffers = [NSMutableArray new]; operations = [NSMutableArray new];
                writes = 0;
                FullUnlock context = {0};
                assert(!invokeRinger(&context, true, application.boolValue));
                assert(!context.attempted && context.error[0] && writes == 0);
            }
        }
        puts("PASS native ringer: both BOOL values, main-thread object chain, signatures, missing/nil receivers, allocation/read failures rejected before writes");
    }
}
