#import <Foundation/Foundation.h>

// Host Foundation may already load Apple's AVSystemController. Keep the fake
// class distinct and redirect only the native bridge's class lookup in tests.
static inline Class IcliFixtureClassFromString(NSString *name) {
    return NSClassFromString([name isEqualToString:@"AVSystemController"]
        ? @"IcliFixtureAVSystemController" : name);
}
#define NSClassFromString IcliFixtureClassFromString
#define AVSystemController IcliFixtureAVSystemController
