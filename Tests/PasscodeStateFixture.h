#import <Foundation/Foundation.h>
#include <dlfcn.h>

Class fixturePasscodeClass(NSString *name);
void *fixturePasscodeFramework(const char *path, int flags);

#define NSClassFromString fixturePasscodeClass
#define dlopen fixturePasscodeFramework
