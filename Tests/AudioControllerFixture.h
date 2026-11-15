#import <Foundation/Foundation.h>

// Host Foundation may already load Apple's AVSystemController. Keep the fake
// class distinct and redirect only the native bridge's class lookup in tests.
static inline Class IcliFixtureClassFromString(NSString *name) {
    if ([name isEqualToString:@"AVSystemController"]) name = @"IcliFixtureAVSystemController";
    if ([name isEqualToString:@"AXSpringBoardServer"]) name = @"IcliFixtureAXSpringBoardServer";
    if ([name isEqualToString:@"AXIPCMessage"]) name = @"IcliFixtureAXIPCMessage";
    return NSClassFromString(name);
}
#define NSClassFromString IcliFixtureClassFromString
#define AVSystemController IcliFixtureAVSystemController
#define AXSpringBoardServer IcliFixtureAXSpringBoardServer
#define AXIPCMessage IcliFixtureAXIPCMessage
