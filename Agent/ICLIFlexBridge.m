#import "ICLIFlexBridge.h"
#import <dlfcn.h>
#import <ptrauth.h>

NSDictionary *icli_full_flex_request(NSDictionary *request) {
    static char *(*evaluate)(const char *);
    if (!evaluate) {
        Dl_info info = {0};
        dladdr(ptrauth_strip((void *)icli_full_flex_request, ptrauth_key_function_pointer), &info);
        NSString *parent = info.dli_fname ? [@(info.dli_fname) stringByDeletingLastPathComponent] : @"";
        NSString *path = [parent stringByAppendingPathComponent:@"icli/libicli-flexultra.dylib"];
        void *library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (library) evaluate = dlsym(library, "icli_flexultra_request_json");
        if (!evaluate) {
            const char *detail = dlerror();
            return @{@"ok": @NO, @"error": @{@"code": @"engine_unavailable", @"message": [NSString stringWithFormat:@"Cannot load icli's FlexUltra engine: %s", detail ?: "missing entry point"]}};
        }
    }
    NSMutableDictionary *identified = [request mutableCopy];
    identified[@"_icli_generation"] = icli_probe_agent_generation();
    NSData *data = [NSJSONSerialization dataWithJSONObject:identified options:0 error:nil];
    char *reply = evaluate([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    NSDictionary *answer = nil;
    if (reply) {
        answer = [NSJSONSerialization JSONObjectWithData:[@(reply) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        free(reply);
    }
    if ([answer[@"generation"] isKindOfClass:NSString.class]) {
        icli_probe_agent_update_identity(@{@"generation": answer[@"generation"]});
    }
    return answer ?: @{@"ok": @NO, @"error": @{@"code": @"invalid_response", @"message": @"The FlexUltra engine returned no JSON response."}};
}
