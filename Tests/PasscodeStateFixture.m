#include <assert.h>
#include <stdio.h>
#include <string.h>

extern int icli_passcode_set(void);

static Class selected;
static unsigned factoryCalls, getterCalls;

Class fixturePasscodeClass(NSString *name) {
    assert([name isEqualToString:@"MCProfileConnection"]);
    return selected;
}

void *fixturePasscodeFramework(const char *path, int flags) {
    assert(!strcmp(path, "/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration"));
    assert(flags == RTLD_NOW);
    return NULL;
}

@interface Configured : NSObject
+ (id)sharedConnection;
- (BOOL)isPasscodeSet;
@end
@implementation Configured
+ (id)sharedConnection { factoryCalls++; return [self new]; }
- (BOOL)isPasscodeSet { getterCalls++; return YES; }
@end

@interface NotConfigured : Configured @end
@implementation NotConfigured
- (BOOL)isPasscodeSet { getterCalls++; return NO; }
@end

@interface NilConnection : Configured @end
@implementation NilConnection
+ (id)sharedConnection { factoryCalls++; return nil; }
@end

@interface WrongFactory : NSObject
+ (BOOL)sharedConnection;
@end
@implementation WrongFactory
+ (BOOL)sharedConnection { factoryCalls++; return YES; }
@end

@interface WrongGetter : NSObject
+ (id)sharedConnection;
- (NSInteger)isPasscodeSet;
@end
@implementation WrongGetter
+ (id)sharedConnection { factoryCalls++; return [self new]; }
- (NSInteger)isPasscodeSet { getterCalls++; return 1; }
@end

@interface MissingGetter : NSObject
+ (id)sharedConnection;
@end
@implementation MissingGetter
+ (id)sharedConnection { factoryCalls++; return [self new]; }
@end

@interface WrongFactoryArguments : Configured @end
@implementation WrongFactoryArguments
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return selector == @selector(sharedConnection)
        ? [NSMethodSignature signatureWithObjCTypes:"@@:@"]
        : [super methodSignatureForSelector:selector];
}
@end

@interface WrongGetterArguments : Configured @end
@implementation WrongGetterArguments
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return selector == @selector(isPasscodeSet)
        ? [NSMethodSignature signatureWithObjCTypes:"B@:@"]
        : [super methodSignatureForSelector:selector];
}
@end

static void check(Class cls, int expected, unsigned factories, unsigned getters) {
    selected = cls;
    factoryCalls = getterCalls = 0;
    assert(icli_passcode_set() == expected);
    assert(factoryCalls == factories);
    assert(getterCalls == getters);
}

int main(void) {
    @autoreleasepool {
        check(Nil, -1, 0, 0);
        check(NSObject.class, -1, 0, 0);
        check(Configured.class, 1, 1, 1);
        check(NotConfigured.class, 0, 1, 1);
        check(NilConnection.class, -1, 1, 0);
        check(MissingGetter.class, -1, 1, 0);
        check(WrongFactory.class, -1, 0, 0);
        check(WrongGetter.class, -1, 1, 0);
        check(WrongFactoryArguments.class, -1, 0, 0);
        check(WrongGetterArguments.class, -1, 1, 0);
    }
    puts("PASS passcode configuration: 10 native bridge cases");
}
