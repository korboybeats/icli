#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <string.h>
#import "IcliJSON.h"
@class CLLocation;
id simulationManager(void);
BOOL fixtureSourceInformationAvailable(void);
Class fixtureConnectionClass(NSString *name);
#define NSClassFromString fixtureConnectionClass
