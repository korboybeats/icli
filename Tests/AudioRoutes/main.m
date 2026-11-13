#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <math.h>

char *icli_cc_audio_list_json(void);
char *icli_cc_audio_select_json(const char *, double);

// Export the same notification constants for the production dlsym lookup.
NSString * const AVSystemController_ActiveAudioRouteDidChangeNotification = @"test.active-route";
NSString * const AVSystemController_PickableRoutesDidChangeNotification = @"test.pickable-routes";
NSString * const AVSystemController_SubscribeToNotificationsAttribute = @"test.subscribe";
static NSInteger subscriptionCount = 0;
static BOOL subscriptionAvailable = YES;

@interface AVSystemController : NSObject
@property(nonatomic) NSArray *routes;
@property(nonatomic) NSString *behavior;
@property(nonatomic) NSDictionary *received;
@property(nonatomic) NSUInteger calls;
@property(nonatomic) BOOL subscribed;
@end

static NSDictionary *route(NSString *uid, NSString *name, BOOL selected) {
    NSMutableDictionary *result = [@{@"RouteUID": uid, @"RouteName": name, @"AVAudioRouteName": @"Native type",
                                     @"OpaqueNativeKey": @"preserve me"} mutableCopy];
    if (selected) result[@"RouteCurrentlyPicked"] = @YES;
    return result;
}

@implementation AVSystemController
- (void)dealloc {
    if (_subscribed) subscriptionCount--;
}
- (BOOL)setAttribute:(id)value forKey:(NSString *)key error:(NSError **)error {
    (void)error;
    assert([key isEqual:AVSystemController_SubscribeToNotificationsAttribute]);
    assert([value containsObject:AVSystemController_ActiveAudioRouteDidChangeNotification]);
    assert([value containsObject:AVSystemController_PickableRoutesDidChangeNotification]);
    assert(self != [AVSystemController sharedAVSystemController]);
    if (!subscriptionAvailable) return NO;
    self.subscribed = YES;
    subscriptionCount++;
    return YES;
}
+ (instancetype)sharedAVSystemController {
    static AVSystemController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [self new]; });
    return controller;
}
- (NSArray *)pickableRoutesForCategory:(NSString *)category {
    assert([category isEqual:@"Audio/Video"]);
    return self.routes;
}
- (BOOL)setPickedRouteWithPassword:(NSDictionary *)picked withPassword:(NSString *)password {
    self.calls++;
    self.received = picked;
    assert([password isEqual:@""]);
    assert([picked[@"OpaqueNativeKey"] isEqual:@"preserve me"]);
    if ([self.behavior isEqual:@"reject"]) return NO;
    if ([self.behavior isEqual:@"throw"]) [NSException raise:@"test" format:@"native failure"];
    if ([self.behavior isEqual:@"never"]) return YES;
    NSString *uid = picked[@"RouteUID"];
    void (^update)(void) = ^{
        NSMutableArray *after = [NSMutableArray array];
        for (NSDictionary *r in self.routes) {
            if ([self.behavior isEqual:@"disappear"] && [r[@"RouteUID"] isEqual:uid]) continue;
            NSMutableDictionary *copy = [r mutableCopy];
            copy[@"RouteCurrentlyPicked"] = @([r[@"RouteUID"] isEqual:uid]);
            [after addObject:copy];
        }
        self.routes = after;
    };
    if ([self.behavior isEqual:@"immediate"]) { update(); return YES; }
    // Timer on the calling thread proves the wait services that thread's loop.
    [NSTimer scheduledTimerWithTimeInterval:0.015 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        update();
        if (subscriptionCount > 0) {
            [NSNotificationCenter.defaultCenter postNotificationName:AVSystemController_ActiveAudioRouteDidChangeNotification object:self];
        }
    }];
    return YES;
}
@end

static NSDictionary *decode(char *raw) {
    assert(subscriptionCount == 0); // no event client remains after any return
    assert(raw);
    NSData *data = [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding];
    free(raw);
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    assert(result);
    return result;
}

static AVSystemController *reset(NSString *behavior) {
    subscriptionAvailable = ![behavior isEqual:@"no-event"];
    AVSystemController *controller = [AVSystemController sharedAVSystemController];
    // Deliberately unlike device UIDs and duplicate display names.
    controller.routes = @[route(@"local-1", @"Same name", YES), route(@"wireless-2", @"Same name", NO)];
    controller.behavior = behavior;
    controller.calls = 0;
    controller.received = nil;
    return controller;
}

static void tests(void) {
    AVSystemController *controller = reset(@"never");
    NSDictionary *list = decode(icli_cc_audio_list_json());
    assert([list[@"selected_uid"] isEqual:@"local-1"]);
    assert([list[@"routes"] count] == 2);
    assert([list[@"routes"][0][@"name"] isEqual:@"Same name"]);
    assert([list[@"routes"][0][@"selected"] boolValue]);
    assert(![list[@"routes"][1][@"selected"] boolValue]);

    NSDictionary *result = decode(icli_cc_audio_select_json("local-1", .1));
    assert(!result[@"error"] && ![result[@"changed"] boolValue] && controller.calls == 0);
    for (const char **uid = (const char *[]){"wireless", "WIRELESS-2", "Same name", "missing", NULL}; *uid; uid++) {
        result = decode(icli_cc_audio_select_json(*uid, .1));
        assert([result[@"error"] isEqual:@"route_unavailable"] && controller.calls == 0);
    }
    NSDictionary *target = controller.routes[1];
    result = decode(icli_cc_audio_select_json("wireless-2", .025));
    assert([result[@"error"] isEqual:@"timed_out"]);
    assert([result[@"selected_uid"] isEqual:@"local-1"]);
    assert(!result[@"changed"] && controller.calls == 1 && controller.received == target);

    for (NSString *behavior in @[@"immediate", @"event", @"no-event"]) {
        reset(behavior);
        result = decode(icli_cc_audio_select_json("wireless-2", .3));
        assert(!result[@"error"] && [result[@"changed"] boolValue]);
        assert([result[@"selected_uid"] isEqual:@"wireless-2"]);
        assert([result[@"previous_uid"] isEqual:@"local-1"]);
        // Restore direction uses its own discovered dictionary too.
        result = decode(icli_cc_audio_select_json("local-1", .3));
        assert(!result[@"error"] && [result[@"selected_uid"] isEqual:@"local-1"]);
    }
    reset(@"reject");
    assert([decode(icli_cc_audio_select_json("wireless-2", .1))[@"error"] isEqual:@"route_rejected"]);
    reset(@"disappear");
    assert([decode(icli_cc_audio_select_json("wireless-2", .1))[@"error"] isEqual:@"route_unavailable"]);
    reset(@"throw");
    assert([decode(icli_cc_audio_select_json("wireless-2", .1))[@"error"] isEqual:@"failed"]);
    // A notification after failure must not call a dangling observer/source.
    [NSNotificationCenter.defaultCenter postNotificationName:AVSystemController_ActiveAudioRouteDidChangeNotification object:nil];
    reset(@"never");
    for (NSNumber *seconds in @[@0, @(-1), @(NAN), @(INFINITY), @61]) {
        assert([decode(icli_cc_audio_select_json("wireless-2", seconds.doubleValue))[@"error"] isEqual:@"failed"]);
    }
    assert(controller.calls == 0);
    assert(decode(icli_cc_audio_select_json("", .1))[@"error"]);
    assert(decode(icli_cc_audio_select_json(NULL, .1))[@"error"]);
    controller.routes = @[];
    assert([decode(icli_cc_audio_list_json())[@"routes"] count] == 0);
    controller.routes = nil;
    assert([decode(icli_cc_audio_list_json())[@"error"] isEqual:@"unavailable"]);
    controller.routes = @[@{@"RouteName": @"missing UID"}];
    assert(decode(icli_cc_audio_list_json())[@"error"]);
    controller.routes = @[route(@"duplicate", @"A", YES), route(@"duplicate", @"B", NO)];
    assert(decode(icli_cc_audio_list_json())[@"error"]);
    controller.routes = @[route(@"local-1", @"A", YES), route(@"wireless-2", @"B", YES)];
    result = decode(icli_cc_audio_select_json("wireless-2", .025));
    assert([result[@"error"] isEqual:@"timed_out"]); // ambiguous selection is not proof
    controller.routes = @[@{@"RouteUID": @"fallback", @"AVAudioRouteName": @"Fallback name", @"RouteCurrentlyPicked": @YES}];
    assert([decode(icli_cc_audio_list_json())[@"routes"][0][@"name"] isEqual:@"Fallback name"]);
}

int main(void) {
    @autoreleasepool {
        tests();
        // Also exercise a host's worker without an existing run-loop source.
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            @autoreleasepool { tests(); }
            dispatch_semaphore_signal(done);
        });
        assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        puts("PASS audio routes: exact UIDs, native dictionary, async/event/fallback completion, both directions, no-op, rejection, disappearance, timeout, invalid data, worker run loop");
    }
}
