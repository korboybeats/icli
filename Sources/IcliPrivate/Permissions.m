#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

// tccd answers these for a caller with com.apple.private.tcc.manager, and
// locationd the location calls for one with
// com.apple.locationd.authorizeapplications (both verified on iOS 17.1.1). iOS
// stops a running app whose permissions change, as Settings does.
static void *tccSymbol(const char *name) {
    static void *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ library = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW); });
    return library ? dlsym(library, name) : NULL;
}

static Class locationManagerClass(void) {
    static Class manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/CoreLocation.framework/CoreLocation", RTLD_NOW);
        manager = NSClassFromString(@"CLLocationManager");
    });
    return manager;
}

char *icli_permissions_json(const char *bundle_path) {
    CFArrayRef (*copyInfo)(CFBundleRef) = tccSymbol("TCCAccessCopyInformationForBundle");
    if (!copyInfo || !bundle_path) return icli_json(@{@"error": @"TCC is unavailable"});
    NSURL *url = [NSURL fileURLWithPath:@(bundle_path)];
    CFBundleRef bundle = CFBundleCreate(NULL, (__bridge CFURLRef)url);
    if (!bundle) return icli_json(@{@"error": @"the app's bundle could not be opened"});
    NSArray *rows = CFBridgingRelease(copyInfo(bundle));
    CFRelease(bundle);
    NSMutableArray *entries = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *service = row[@"kTCCInfoService"];
        if (![service isKindOfClass:NSString.class]) continue;
        [entries addObject:@{@"service": service, @"granted": @([row[@"kTCCInfoGranted"] boolValue])}];
    }
    return icli_json(@{@"entries": entries});
}

bool icli_tcc_set(const char *service, const char *bundle_path, bool granted) {
    Boolean (*set)(CFStringRef, CFBundleRef, Boolean) = tccSymbol("TCCAccessSetForBundle");
    if (!set || !service || !bundle_path) return false;
    CFBundleRef bundle = CFBundleCreate(NULL, (__bridge CFURLRef)[NSURL fileURLWithPath:@(bundle_path)]);
    if (!bundle) return false;
    Boolean done = set((__bridge CFStringRef)@(service), bundle, granted);
    CFRelease(bundle);
    return done;
}

bool icli_tcc_reset(const char *service, const char *bundle_id) {
    Boolean (*reset)(CFStringRef, CFStringRef) = tccSymbol("TCCAccessResetForBundleId");
    if (!reset || !service || !bundle_id) return false;
    return reset((__bridge CFStringRef)@(service), (__bridge CFStringRef)@(bundle_id));
}

int icli_location_authorization_get(const char *bundle_id) {
    Class manager = locationManagerClass();
    SEL get = NSSelectorFromString(@"authorizationStatusForBundleIdentifier:");
    if (!bundle_id || ![manager respondsToSelector:get]) return -1;
    return ((int (*)(id, SEL, id))objc_msgSend)(manager, get, @(bundle_id));
}

bool icli_location_authorization_set(const char *bundle_id, int status) {
    Class manager = locationManagerClass();
    SEL set = NSSelectorFromString(@"setAuthorizationStatusByType:forBundleIdentifier:");
    if (!bundle_id || ![manager respondsToSelector:set]) return false;
    ((void (*)(id, SEL, int, id))objc_msgSend)(manager, set, status, @(bundle_id));
    return true;
}

// CoreFoundation's container preference calls, which reach cfprefsd for an
// app's data container: what the app itself reads, with no file edit behind
// cfprefsd's back and no cfprefsd restart.
static void *containerPreferencesSymbol(const char *name) {
    static void *library;
    if (!library) library = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
    return library ? dlsym(library, name) : NULL;
}

CFArrayRef icli_container_prefs_keys(CFStringRef domain, CFStringRef container) {
    CFArrayRef (*keys)(CFStringRef, CFStringRef, CFStringRef, CFStringRef) =
        containerPreferencesSymbol("_CFPreferencesCopyKeyListWithContainer");
    return keys ? keys(domain, CFSTR("mobile"), kCFPreferencesAnyHost, container) : NULL;
}

CFPropertyListRef icli_container_prefs_copy(CFStringRef key, CFStringRef domain, CFStringRef container) {
    CFPropertyListRef (*copy)(CFStringRef, CFStringRef, CFStringRef, CFStringRef, CFStringRef) =
        containerPreferencesSymbol("_CFPreferencesCopyValueWithContainer");
    return copy ? copy(key, domain, CFSTR("mobile"), kCFPreferencesAnyHost, container) : NULL;
}

bool icli_container_prefs_set(CFStringRef key, CFPropertyListRef value, CFStringRef domain, CFStringRef container) {
    void (*set)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef, CFStringRef) =
        containerPreferencesSymbol("_CFPreferencesSetValueWithContainer");
    Boolean (*sync)(CFStringRef, CFStringRef, CFStringRef, CFStringRef) =
        containerPreferencesSymbol("_CFPreferencesSynchronizeWithContainer");
    if (!set || !sync) return false;
    set(key, value, domain, CFSTR("mobile"), kCFPreferencesAnyHost, container);
    return sync(domain, CFSTR("mobile"), kCFPreferencesAnyHost, container);
}
