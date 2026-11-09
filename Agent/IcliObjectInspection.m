#import "IcliObjectInspection.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import <ptrauth.h>
#include <unistd.h>

// Adapted to icli's request transport from the FLEXObjectExplorer approach in
// FlexUltra's FUObjectInspection.m. FLEX itself is shipped unchanged under
// Vendor/FLEX, with its original license and upstream revision.

static NSDictionary *failure(NSString *message) {
    return @{@"ok": @NO, @"error": message, @"output": @""};
}

static id member(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static NSUInteger number(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(object, selector) : 0;
}

static NSString *shortString(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    return value.length <= 2048 ? value : [[value substringToIndex:2048] stringByAppendingString:@"…"];
}

static NSDictionary *reference(id object) {
    return @{@"class": @(class_getName(object_getClass(object))),
             @"address": [NSString stringWithFormat:@"%p", (__bridge void *)object]};
}

static id jsonValue(id value) {
    if (!value || value == NSNull.null) return NSNull.null;
    if ([value isKindOfClass:NSString.class]) return shortString(value);
    if ([value isKindOfClass:NSNumber.class]) return isfinite([value doubleValue]) ? value : [value description];
    // Never walk an arbitrary collection or describe an app-defined object.
    // Relationships are references, so cycles cannot expand the reply.
    if ([value isKindOfClass:NSValue.class]) return shortString([value description]);
    return reference(value);
}

static NSString *loadFLEX(void) {
    if (NSClassFromString(@"FLEXObjectExplorer")) return nil;
    Dl_info image = {0};
    const void *address = ptrauth_strip((void *)icli_probe_inspect_object, ptrauth_key_function_pointer);
    if (!dladdr(address, &image) || !image.dli_fname) return @"cannot locate the probe agent's private FLEX runtime";
    NSString *directory = [@(image.dli_fname) stringByDeletingLastPathComponent];
    NSString *path = [directory stringByAppendingPathComponent:@"icli/libFLEX.dylib"];
    // Keep the handle for the app's lifetime: the explorer and categories are
    // Objective-C classes and cannot be unloaded while the app still uses them.
    if (!dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL)) {
        const char *detail = dlerror();
        return [NSString stringWithFormat:@"cannot load FLEX at %@: %s", path, detail ?: "unknown loader error"];
    }
    return NSClassFromString(@"FLEXObjectExplorer") ? nil : @"the loaded runtime has no FLEXObjectExplorer";
}

static UIWindow *keyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    // All supported devices run iOS 15+, so UIWindowScene is available.
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && !window.hidden) return window;
        }
    }
    return nil;
}

static NSArray *members(id explorer, id target, NSString *groupsName, NSString *kind,
                        NSUInteger offset, NSUInteger limit, BOOL values, NSUInteger *total) {
    NSArray *groups = member(explorer, groupsName);
    NSArray *classes = member(explorer, @"classHierarchyClasses");
    if (![groups isKindOfClass:NSArray.class] || ![classes isKindOfClass:NSArray.class]) {
        [NSException raise:@"UnsupportedFLEX" format:@"FLEXObjectExplorer does not expose %@", groupsName];
    }
    NSMutableArray *result = [NSMutableArray array];
    NSUInteger position = 0;
    for (NSUInteger scope = 0; scope < groups.count; scope++) {
        for (id item in groups[scope]) {
            NSUInteger index = position++;
            if (index < offset || result.count >= limit) continue;
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"declaring_class"] = scope < classes.count ? NSStringFromClass(classes[scope]) : @"";
            BOOL method = [kind isEqualToString:@"method"];
            entry[@"name"] = member(item, method ? @"selectorString" : @"name") ?: @"";
            if ([kind isEqualToString:@"property"]) {
                id attributes = member(item, @"attributes");
                entry[@"type_encoding"] = member(attributes, @"typeEncoding") ?: @"";
                entry[@"description"] = shortString(member(item, @"fullDescription"));
                entry[@"getter"] = member(item, @"likelyGetterString") ?: @"";
                entry[@"setter"] = member(item, @"likelySetterString") ?: @"";
                SEL readonly = NSSelectorFromString(@"isReadOnly");
                entry[@"readonly"] = ([attributes respondsToSelector:readonly] && ((BOOL (*)(id, SEL))objc_msgSend)(attributes, readonly)) ? @YES : @NO;
            } else {
                entry[@"type_encoding"] = member(item, @"typeEncoding") ?: @"";
                if (method) {
                    entry[@"signature"] = member(item, @"signatureString") ?: @"";
                    entry[@"arguments"] = @(number(item, @"numberOfArguments"));
                } else {
                    entry[@"offset"] = @(number(item, @"offset"));
                    entry[@"size"] = @(number(item, @"size"));
                }
            }
            if (values && !method) {
                @try {
                    SEL getter = NSSelectorFromString(@"getPotentiallyUnboxedValue:");
                    if (![item respondsToSelector:getter]) entry[@"value_error"] = @"this FLEX runtime cannot read the member";
                    else entry[@"value"] = jsonValue(((id (*)(id, SEL, id))objc_msgSend)(item, getter, target));
                } @catch (NSException *exception) {
                    entry[@"value_error"] = shortString(exception.reason ?: exception.name);
                }
            }
            [result addObject:entry];
        }
    }
    *total = position;
    return result;
}

NSDictionary *icli_probe_inspect_object(NSDictionary *request) {
    @try {
        if (!NSThread.isMainThread) return failure(@"object inspection must run on the app's main thread");
        NSString *kind = request[@"target"];
        if (![kind isKindOfClass:NSString.class] || ![@[@"window", @"root-controller", @"point"] containsObject:kind])
            return failure(@"inspect target must be window, root-controller, or x,y");
        NSNumber *limit = request[@"limit"] ?: @100, *offset = request[@"offset"] ?: @0;
        if (![limit isKindOfClass:NSNumber.class] || ![offset isKindOfClass:NSNumber.class] ||
            limit.doubleValue != limit.integerValue || offset.doubleValue != offset.integerValue ||
            limit.integerValue < 1 || limit.integerValue > 500 || offset.integerValue < 0)
            return failure(@"inspection limit must be 1–500 and offset must be a nonnegative integer");
        UIWindow *window = keyWindow();
        if (!window) return failure(@"the app has no foreground key window");
        id target = window;
        if ([kind isEqualToString:@"root-controller"]) target = window.rootViewController;
        if ([kind isEqualToString:@"point"]) {
            NSNumber *x = request[@"x"], *y = request[@"y"];
            if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] ||
                !isfinite(x.doubleValue) || !isfinite(y.doubleValue)) return failure(@"inspection coordinates must be finite numbers");
            CGPoint point = [window convertPoint:CGPointMake(x.doubleValue, y.doubleValue)
                            fromCoordinateSpace:window.screen.coordinateSpace];
            target = [window hitTest:point withEvent:nil];
        }
        if (!target) return failure(@"no live object matches that target");
        NSString *error = loadFLEX();
        if (error) return failure(error);
        Class explorerClass = NSClassFromString(@"FLEXObjectExplorer");
        SEL factory = NSSelectorFromString(@"forObject:");
        if (![explorerClass respondsToSelector:factory]) return failure(@"the loaded FLEX runtime has no object explorer factory");
        id explorer = ((id (*)(id, SEL, id))objc_msgSend)(explorerClass, factory, target);
        if (!explorer) return failure(@"FLEX could not inspect this object");
        NSMutableDictionary *result = [reference(target) mutableCopy];
        result[@"engine"] = @"FLEXObjectExplorer";
        result[@"runtime_image"] = @(class_getImageName(explorerClass) ?: "");
        result[@"pid"] = @(getpid());
        result[@"bundle_id"] = NSBundle.mainBundle.bundleIdentifier ?: @"";
        result[@"target"] = kind;
        result[@"include_values"] = @([request[@"values"] boolValue]);
        result[@"offset"] = offset;
        result[@"limit"] = limit;
        NSMutableArray *hierarchy = [NSMutableArray array];
        for (Class cls in member(explorer, @"classHierarchyClasses")) [hierarchy addObject:NSStringFromClass(cls)];
        result[@"class_hierarchy"] = hierarchy;
        NSMutableDictionary *totals = [NSMutableDictionary dictionary], *truncated = [NSMutableDictionary dictionary];
        NSArray *keys = @[@"properties", @"ivars", @"methods", @"class_methods"];
        NSArray *selectors = @[@"allProperties", @"allIvars", @"allMethods", @"allClassMethods"];
        for (NSUInteger i = 0; i < keys.count; i++) {
            NSUInteger total = 0;
            NSArray *page = members(explorer, target, selectors[i], i == 0 ? @"property" : (i == 1 ? @"ivar" : @"method"),
                                    offset.unsignedIntegerValue, limit.unsignedIntegerValue, [request[@"values"] boolValue], &total);
            result[keys[i]] = page;
            totals[keys[i]] = @(total);
            truncated[keys[i]] = (offset.unsignedIntegerValue < total && page.count < total - offset.unsignedIntegerValue) ? @YES : @NO;
        }
        result[@"totals"] = totals;
        result[@"truncated"] = truncated;
        return @{@"ok": @YES, @"result": result, @"output": @""};
    } @catch (NSException *exception) {
        return failure([NSString stringWithFormat:@"object inspection failed: %@", shortString(exception.reason ?: exception.name)]);
    }
}
