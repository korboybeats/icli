#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

#import "FUObjectRegistry.h"
#import "FUObjectSerialization.h"

NSString *FUAddressOfObject(id object) {
    return object ? [NSString stringWithFormat:@"%p", (__bridge void *)object] : nil;
}

NSString *FUClassName(id object) {
    if (!object) {
        return @"";
    }
    if (object_isClass(object)) {
        return NSStringFromClass((Class)object) ?: @"";
    }
    return NSStringFromClass([object class]) ?: @"";
}

NSString *FUTruncatedString(NSString *string, NSUInteger limit) {
    if (![string isKindOfClass:[NSString class]]) {
        return @"";
    }
    if (string.length <= limit) {
        return string;
    }
    return [[string substringToIndex:limit] stringByAppendingString:@"…"];
}

NSString *FUSafeSummary(id object) {
    if (!object) {
        return @"nil";
    }
    // Never invoke an arbitrary object's -description while serializing an
    // inspection result. Custom descriptions can execute application code,
    // assert, recurse, or stack-overflow outside Objective-C exception
    // handling. NSString itself is already the value we want to display.
    if ([object isKindOfClass:[NSString class]]) {
        return FUTruncatedString((NSString *)object, 512);
    }
    return [NSString stringWithFormat:@"<%@: %@>", FUClassName(object), FUAddressOfObject(object) ?: @"0x0"];
}

NSDictionary *FUObjectReference(id object) {
    if (!object) {
        return @{};
    }
    return @{
        @"id": FURegisterObject(object) ?: @"",
        @"class": FUClassName(object),
        @"address": FUAddressOfObject(object) ?: @"",
        @"summary": FUSafeSummary(object),
    };
}

id FUJSONValue(id value) {
    if (!value || value == NSNull.null) {
        return NSNull.null;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return FUTruncatedString(value, 2048);
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        double numericValue = [value doubleValue];
        if (!isfinite(numericValue)) {
            NSString *spelling = isnan(numericValue) ? @"nan" : (numericValue > 0.0 ? @"infinity" : @"-infinity");
            return @{
                @"kind": @"non_finite_number",
                @"value": spelling,
            };
        }
        return value;
    }
    if ([value isKindOfClass:[NSURL class]]) {
        return [(NSURL *)value absoluteString] ?: @"";
    }
    if ([value isKindOfClass:[NSDate class]]) {
        return @{
            @"kind": @"date",
            @"time_interval_since_1970": @([(NSDate *)value timeIntervalSince1970]),
        };
    }
    if ([value isKindOfClass:[NSUUID class]]) {
        return [(NSUUID *)value UUIDString] ?: @"";
    }
    if ([value isKindOfClass:[NSValue class]]) {
        return @{
            @"kind": @"value",
            @"class": FUClassName(value),
            @"summary": FUSafeSummary(value),
            @"object": FUObjectReference(value),
        };
    }
    return @{
        @"kind": @"object",
        @"object": FUObjectReference(value),
    };
}

id FUJSONFloatingNumber(CGFloat value) {
    if (!isfinite((double)value)) {
        return NSNull.null;
    }
    return @(value);
}

NSDictionary *FURectJSON(CGRect rect) {
    return @{
        @"x": FUJSONFloatingNumber(rect.origin.x),
        @"y": FUJSONFloatingNumber(rect.origin.y),
        @"width": FUJSONFloatingNumber(rect.size.width),
        @"height": FUJSONFloatingNumber(rect.size.height),
    };
}

NSDictionary *FUPointJSON(CGPoint point) {
    return @{
        @"x": FUJSONFloatingNumber(point.x),
        @"y": FUJSONFloatingNumber(point.y),
    };
}

NSDictionary *FUSizeJSON(CGSize size) {
    return @{
        @"width": FUJSONFloatingNumber(size.width),
        @"height": FUJSONFloatingNumber(size.height),
    };
}
