#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/message.h>
#include <string.h>

// locationd's simulation client (the one Xcode's location simulation uses).
// The simulated location lives in locationd and outlives this connection;
// one manager per process lets a long-running host keep its session.
static id simulationManager(void) {
    static id manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [NSClassFromString(@"CLSimulationManager") new]; });
    return manager;
}

static NSString *sendAll(id manager, NSArray<NSString *> *selectors, CLLocation *location) {
    if (!manager) return @"CoreLocation's location simulation is unavailable on this device";
    for (NSString *name in selectors) {
        if (![manager respondsToSelector:NSSelectorFromString(name)])
            return [NSString stringWithFormat:@"CoreLocation's location simulation does not support %@", name];
    }
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if ([name hasSuffix:@":"]) ((void (*)(id, SEL, id))objc_msgSend)(manager, selector, location);
        else ((void (*)(id, SEL))objc_msgSend)(manager, selector);
    }
    return nil;
}

char *icli_location_simulate_json(
    double latitude,
    double longitude,
    double altitude,
    double horizontal_accuracy,
    double vertical_accuracy,
    double speed,
    double course
) {
    // Without Location Services the read-back that confirms a simulation can
    // only fail, so the caller would wait for a clear before hearing why.
    if (![CLLocationManager locationServicesEnabled])
        return icli_json(@{@"error": @"Location Services are turned off"});
    CLLocation *location = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                                                         altitude:altitude
                                               horizontalAccuracy:horizontal_accuracy
                                                 verticalAccuracy:vertical_accuracy
                                                           course:course
                                                            speed:speed
                                                        timestamp:[NSDate date]];
    NSString *error = sendAll(
        simulationManager(),
        @[
            @"stopLocationSimulation",
            @"clearSimulatedLocations",
            @"appendSimulatedLocation:",
            @"flush",
            @"startLocationSimulation"
        ],
        location
    );
    return icli_json(error ? @{@"error": error} : @{});
}

char *icli_location_clear_json(void) {
    id manager = simulationManager();
    NSString *error = sendAll(
        manager,
        @[@"stopLocationSimulation", @"clearSimulatedLocations", @"flush"],
        nil
    );
    if (error) return icli_json(@{@"error": error});
    // The newer caller waits for location readback before exiting.
    if (@available(iOS 15.0, tvOS 15.0, *)) return icli_json(@{});
    @try {
        SEL getter = NSSelectorFromString(@"connection");
        NSMethodSignature *signature = [manager methodSignatureForSelector:getter];
        if (!signature || signature.numberOfArguments != 2 || strcmp(signature.methodReturnType, @encode(id)))
            return icli_json(@{@"error": @"location simulation connection is unavailable"});
        NSXPCConnection *connection = ((id (*)(id, SEL))objc_msgSend)(manager, getter);
        if (![connection isKindOfClass:NSClassFromString(@"NSXPCConnection")])
            return icli_json(@{@"error": @"location simulation connection is unavailable"});
        // This public iOS 13+ barrier confirms sending, not receipt or stop
        // completion. Keep the legacy result unknown.
        dispatch_semaphore_t sent = dispatch_semaphore_create(0);
        [connection scheduleSendBarrierBlock:^{ dispatch_semaphore_signal(sent); }];
        if (dispatch_semaphore_wait(sent, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)))
            error = @"location simulation request delivery did not finish";
    } @catch (NSException *exception) {
        error = @"location simulation connection is unavailable";
    }
    return icli_json(error ? @{@"error": error} : @{});
}

@interface IcliLocationReader : NSObject <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocation *latest;
@property (nonatomic, strong) NSError *error;
@end

@implementation IcliLocationReader
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    self.latest = locations.lastObject;
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error { self.error = error; }
@end

// locationd defers authorization for a bare executable until it names a
// bundle, so icli reads as one of the System Services location bundles,
// which are authorized unless turned off in Settings.
static CLLocationManager *systemServiceManager(NSString **bundlePath) {
    // iOS 15 has no initWithEffectiveBundlePath:, only the NSBundle form.
    SEL byPath = NSSelectorFromString(@"initWithEffectiveBundlePath:");
    SEL byBundle = NSSelectorFromString(@"initWithEffectiveBundle:");
    BOOL hasPath = [CLLocationManager instancesRespondToSelector:byPath];
    if (!hasPath && ![CLLocationManager instancesRespondToSelector:byBundle]) return nil;
    for (NSString *name in @[@"SystemCustomization", @"TimeZone", @"CompassCalibration"]) {
        NSString *path = [NSString stringWithFormat:@"/System/Library/LocationBundles/%@.bundle", name];
        id argument = hasPath ? path : [NSBundle bundleWithPath:path];
        if (!argument) continue;
        CLLocationManager *manager = ((id (*)(id, SEL, id))objc_msgSend)(
            [CLLocationManager alloc],
            hasPath ? byPath : byBundle,
            argument
        );
        CLAuthorizationStatus status = manager.authorizationStatus;
        if (status == kCLAuthorizationStatusAuthorizedAlways || status == kCLAuthorizationStatusAuthorizedWhenInUse) {
            *bundlePath = path;
            return manager;
        }
    }
    return nil;
}

char *icli_location_read_json(double timeout, bool match, double latitude, double longitude) {
    if (![CLLocationManager locationServicesEnabled])
        return icli_json(@{@"error": @"Location Services are turned off"});
    NSString *bundlePath = nil;
    CLLocationManager *manager = systemServiceManager(&bundlePath);
    if (!manager)
        return icli_json(@{@"error": @"no System Services location bundle is authorized to read the location"});
    IcliLocationReader *reader = [IcliLocationReader new];
    manager.delegate = reader;
    manager.desiredAccuracy = kCLLocationAccuracyBest;
    manager.distanceFilter = kCLDistanceFilterNone;
    NSDate *start = [NSDate date];
    NSDate *deadline = [start dateByAddingTimeInterval:timeout];
    // A fresh fix carries a timestamp from this read; locationd first hands
    // out its last known location, which may be much older.
    BOOL (^fresh)(CLLocation *) = ^BOOL(CLLocation *location) {
        return location && [location.timestamp timeIntervalSinceDate:start] >= -1;
    };
    BOOL (^satisfied)(CLLocation *) = ^BOOL(CLLocation *location) {
        return fresh(location)
            && (!match
                || (fabs(location.coordinate.latitude - latitude) < 1e-7
                    && fabs(location.coordinate.longitude - longitude) < 1e-7));
    };
#if TARGET_OS_TV
    // tvOS headers offer only the one-shot request; the shared CoreLocation
    // class may still answer the continuous one, which a match needs.
    SEL updating = NSSelectorFromString(@"startUpdatingLocation");
    if ([manager respondsToSelector:updating]) ((void (*)(id, SEL))objc_msgSend)(manager, updating);
    else [manager requestLocation];
#else
    [manager startUpdatingLocation];
#endif
    while (!satisfied(reader.latest) && reader.error.code != kCLErrorDenied && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:MIN(0.1, deadline.timeIntervalSinceNow)]];
    }
    [manager stopUpdatingLocation];
    manager.delegate = nil;
    CLLocation *location = reader.latest ?: manager.location;
    if (reader.error.code == kCLErrorDenied)
        return icli_json(@{@"error": @"locationd denied access to the location"});
    if (!location)
        return icli_json(@{@"error": [NSString stringWithFormat:@"no location within %g s", timeout]});
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions |= NSISO8601DateFormatWithFractionalSeconds;
    id simulated = NSNull.null;
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        simulated = @(location.sourceInformation.isSimulatedBySoftware);
    }
    return icli_json(@{
        @"latitude": @(location.coordinate.latitude),
        @"longitude": @(location.coordinate.longitude),
        @"altitude": @(location.altitude),
        @"horizontal_accuracy": @(location.horizontalAccuracy),
        @"vertical_accuracy": @(location.verticalAccuracy),
        @"speed": @(location.speed),
        @"course": @(location.course),
        @"timestamp": [formatter stringFromDate:location.timestamp],
        @"age_seconds": @(MAX(0, -location.timestamp.timeIntervalSinceNow)),
        @"fresh": @(fresh(location)),
        @"simulated": simulated,
        @"client": bundlePath,
    });
}
