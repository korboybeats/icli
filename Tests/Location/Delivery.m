#include <assert.h>
#include <stdio.h>

extern char *icli_location_clear_json(void);
static BOOL modern, dropBarrier, sent;
static id selected;
static unsigned getters, barriers, passed;
static NSMutableArray *actions;

id simulationManager(void) { return selected; }
BOOL fixtureSourceInformationAvailable(void) { return modern; }

@interface FixtureConnection : NSObject
- (void)scheduleSendBarrierBlock:(void (^)(void))block;
@end
@implementation FixtureConnection
- (void)scheduleSendBarrierBlock:(void (^)(void))block {
    barriers++;
    if (!dropBarrier) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        sent = YES;
        block();
    });
}
@end

Class fixtureConnectionClass(NSString *name) {
    assert([name isEqualToString:@"NSXPCConnection"]);
    return FixtureConnection.class;
}

@interface FixtureSimulation : NSObject
@property id outputConnection;
@end
@implementation FixtureSimulation
- (void)stopLocationSimulation { [actions addObject:@"stop"]; }
- (void)clearSimulatedLocations { [actions addObject:@"clear"]; }
- (void)flush { [actions addObject:@"flush"]; }
- (id)connection { getters++; return self.outputConnection; }
@end

@interface WrongSignature : FixtureSimulation @end
@implementation WrongSignature
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return selector == @selector(connection) ? [NSMethodSignature signatureWithObjCTypes:"q@:"]
                                            : [super methodSignatureForSelector:selector];
}
@end

@interface WrongArity : FixtureSimulation @end
@implementation WrongArity
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return selector == @selector(connection) ? [NSMethodSignature signatureWithObjCTypes:"@@:@"]
                                            : [super methodSignatureForSelector:selector];
}
@end

@interface MissingGetter : FixtureSimulation @end
@implementation MissingGetter
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return selector == @selector(connection) ? nil : [super methodSignatureForSelector:selector];
}
@end

@interface ThrowingGetter : FixtureSimulation @end
@implementation ThrowingGetter
- (id)connection { getters++; @throw [NSException exceptionWithName:@"fixture" reason:@"connection refused" userInfo:nil]; }
@end

static NSDictionary *run(Class cls, BOOL newer, BOOL nilConnection, BOOL wrongConnection) {
    selected = [cls new];
    [(FixtureSimulation *)selected setOutputConnection:nilConnection ? nil : wrongConnection ? [NSObject new] : [FixtureConnection new]];
    modern = newer; sent = NO; getters = barriers = 0; actions = [NSMutableArray array];
    char *raw = icli_location_clear_json();
    assert(raw);
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:raw length:strlen(raw)] options:0 error:nil];
    free(raw);
    assert(([actions isEqual:@[@"stop", @"clear", @"flush"]]));
    return result;
}

int main(void) {
    @autoreleasepool {
        NSDictionary *result = run(FixtureSimulation.class, NO, NO, NO);
        assert(!result[@"error"] && barriers == 1 && getters == 1 && sent); passed++;
        result = run(FixtureSimulation.class, YES, NO, NO);
        assert(!result[@"error"] && !barriers && !getters); passed++;
        for (Class cls in @[WrongSignature.class, WrongArity.class, MissingGetter.class]) {
            result = run(cls, NO, NO, NO);
            assert(result[@"error"] && !barriers && !getters); passed++;
        }
        result = run(FixtureSimulation.class, NO, YES, NO);
        assert(result[@"error"] && !barriers && getters == 1); passed++;
        result = run(FixtureSimulation.class, NO, NO, YES);
        assert(result[@"error"] && !barriers && getters == 1); passed++;
        result = run(ThrowingGetter.class, NO, NO, NO);
        assert(result[@"error"] && !barriers && getters == 1); passed++;
        dropBarrier = YES;
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        result = run(FixtureSimulation.class, NO, NO, NO);
        NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - start;
        assert([result[@"error"] isEqual:@"location simulation request delivery did not finish"]);
        assert(barriers == 1 && !sent && elapsed >= 2.9 && elapsed < 8); passed++;
        printf("%u native location delivery checks passed\n", passed);
    }
}
