#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "FUProtocol.h"
#import "FUObjectInspection.h"
#import "FUObjectSerialization.h"
#import "FURuntime.h"
#import "FUSwiftInspection.h"

BOOL FUSwiftInspectionAvailable(void) {
    // Swift inspection is restricted to the metadata-only bridge implemented
    // by FLEXSwiftMetadataInspector. FLEXSwiftMirror remains disabled because
    // installed-device validation showed its live-object reflection path can
    // terminate the target process.
    return YES;
}

NSString *FUSwiftInspectionUnavailableReason(void) {
    if (FUSwiftInspectionAvailable()) return nil;
    return @"Swift metadata inspection is unavailable.";
}

BOOL FUSwiftValueInspectionAvailable(void) {
    return NO;
}

NSString *FUSwiftValueInspectionUnavailableReason(void) {
    if (FUSwiftValueInspectionAvailable()) return nil;
    return @"Swift value reads are disabled in metadata-only safe mode.";
}

static id FUObjectMessage(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

NSDictionary *FUHandleSwiftInspect(NSString *requestID, NSDictionary *request) {
    if (!FUSwiftInspectionAvailable()) {
        return FUResponse(
            requestID,
            NO,
            nil,
            FUErrorInfo(@"swift_runtime_unsafe", FUSwiftInspectionUnavailableReason())
        );
    }

    NSString *targetSource = nil;
    NSString *resolvedBy = nil;
    NSDictionary *targetError = nil;
    id object = FUObjectTargetFromRequest(requestID, request, nil, &targetSource, &resolvedBy, &targetError);
    if (!object) return targetError;

    NSDictionary *flex = FUFlexStatus(YES);
    if (![flex[@"available"] boolValue]) {
        return FUResponse(requestID, NO, nil, FUErrorInfo(@"flex_unavailable", @"FLEX is required for Swift inspection."));
    }
    NSUInteger requestedLimit = [request[@"limit"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"limit"] unsignedIntegerValue] : 200;
    NSUInteger limit = MIN(MAX(requestedLimit, (NSUInteger)1), (NSUInteger)500);
    BOOL valuesRequested = ![request[@"include_values"] respondsToSelector:@selector(boolValue)] || [request[@"include_values"] boolValue];
    BOOL swiftValuesAvailable = FUSwiftValueInspectionAvailable();
    NSUInteger maxClasses = 32;

    __block NSDictionary *response = nil;
    void (^work)(void) = ^{
        @try {
            Class inspectorClass = NSClassFromString(@"FLEXSwiftMetadataInspector");
            SEL inspectSelector = NSSelectorFromString(@"inspectClass:limit:");
            if (!inspectorClass || ![inspectorClass respondsToSelector:inspectSelector]) {
                response = FUResponse(requestID, NO, nil, FUErrorInfo(@"reflex_unavailable", @"The loaded Reflex build does not expose the metadata-only Swift inspector."));
                return;
            }

            NSMutableArray *ivars = [NSMutableArray array];
            NSMutableArray *metadataChain = [NSMutableArray array];
            NSUInteger fieldsTotal = 0;
            NSUInteger depth = 0;
            BOOL sawSwiftMetadata = NO;
            Class currentClass = object_isClass(object) ? (Class)object : [object class];
            while (currentClass && depth < maxClasses) {
                NSUInteger remaining = ivars.count < limit ? limit - ivars.count : 1;
                NSDictionary *metadata = ((id (*)(id, SEL, Class, NSInteger))objc_msgSend)(
                    (id)inspectorClass,
                    inspectSelector,
                    currentClass,
                    (NSInteger)remaining
                );
                if (![metadata isKindOfClass:[NSDictionary class]]) {
                    response = FUResponse(requestID, NO, nil, FUErrorInfo(@"inspection_failed", @"Swift metadata inspector returned an invalid response."));
                    return;
                }

                BOOL isSwiftClass = [metadata[@"is_swift_class"] boolValue];
                if (isSwiftClass) sawSwiftMetadata = YES;
                NSNumber *fieldCount = [metadata[@"field_count"] isKindOfClass:[NSNumber class]] ? metadata[@"field_count"] : @0;
                fieldsTotal += fieldCount.unsignedIntegerValue;

                NSArray *fields = [metadata[@"fields"] isKindOfClass:[NSArray class]] ? metadata[@"fields"] : @[];
                if (ivars.count < limit && fields.count) {
                    NSUInteger appendCount = MIN(fields.count, limit - ivars.count);
                    [ivars addObjectsFromArray:[fields subarrayWithRange:NSMakeRange(0, appendCount)]];
                }
                [metadataChain addObject:metadata];

                // Once the Swift metadata chain reaches an Objective-C class,
                // the remaining hierarchy is better covered by the existing
                // FLEX/Objective-C operations.
                if (!isSwiftClass) break;

                currentClass = class_getSuperclass(currentClass);
                depth++;
            }

            NSMutableDictionary *result = [FUObjectReference(object) mutableCopy];
            result[@"source"] = @"FLEXSwiftMetadataInspector";
            result[@"mode"] = @"metadata_only";
            result[@"supported"] = @YES;
            result[@"reflex"] = @YES;
            result[@"class_name"] = FUClassName(object);
            result[@"is_class"] = @(object_isClass(object));
            result[@"swift_metadata_available"] = @(sawSwiftMetadata);
            result[@"swift_protocols_available"] = @NO;
            result[@"properties"] = @[];
            result[@"class_properties"] = @[];
            result[@"ivars"] = ivars;
            result[@"methods"] = @[];
            result[@"class_methods"] = @[];
            result[@"protocols"] = @[];
            result[@"metadata_chain"] = metadataChain;
            result[@"include_values"] = @NO;
            result[@"values_requested"] = @(valuesRequested);
            result[@"swift_values_available"] = @(swiftValuesAvailable);
            if (valuesRequested && !swiftValuesAvailable) {
                result[@"value_suppression_reason"] = @"metadata_only_safe_mode";
                result[@"value_suppression_detail"] = FUSwiftValueInspectionUnavailableReason();
            }
            result[@"target_source"] = targetSource ?: @"handle";
            if (resolvedBy.length) result[@"resolved_by"] = resolvedBy;
            result[@"limits"] = @{ @"fields": @(limit), @"class_depth": @(maxClasses) };
            result[@"truncated"] = @{
                @"ivars": @(ivars.count < fieldsTotal),
                @"metadata_chain": @(currentClass != Nil && depth >= maxClasses),
            };
            response = FUResponse(requestID, YES, result, nil);
        } @catch (NSException *exception) {
            response = FUResponse(requestID, NO, nil, FUErrorInfo(@"inspection_failed", FUTruncatedString(exception.reason ?: exception.name, 1024)));
        }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}
