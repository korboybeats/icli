#import "ICLIFlexPaths.h"
#import <dlfcn.h>
#import <ptrauth.h>
NSString *ICLIFlexPrivatePath(NSString *name) {
    Dl_info info = {0};
    dladdr(ptrauth_strip((void *)ICLIFlexPrivatePath, ptrauth_key_function_pointer), &info);
    NSString *path = info.dli_fname ? @(info.dli_fname) : @"";
    return [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:name];
}
