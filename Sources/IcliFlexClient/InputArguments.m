// Adapted by icli: namespaced symbols and private on-demand transport.
#import "ICLIFlexHost.h"
#import <math.h>
static id IcliFURunICLI(NSArray *arguments, NSDictionary **error) {
    (void)error;
    return @{@"argv": arguments};
}
static BOOL IcliFUInputNumber(id value, double *result, BOOL normalized) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    double number = [value doubleValue];
    if (!isfinite(number) || number < 0.0 || (normalized && number > 1.0)) {
        return NO;
    }
    if (result) *result = number;
    return YES;
}

static BOOL IcliFUInputBoolean(id value, BOOL *result) {
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        return NO;
    }
    if (result) *result = [value boolValue];
    return YES;
}

static BOOL IcliFUInputPositiveInteger(id value, NSInteger *result) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    double number = [value doubleValue];
    NSInteger integer = [value integerValue];
    if (!isfinite(number) || number < 1.0 || number != (double)integer) {
        return NO;
    }
    if (result) *result = integer;
    return YES;
}

static NSString *IcliFUInputNumberString(double value) {
    return [NSString stringWithFormat:@"%.17g", value];
}

static NSString *IcliFUInputJSONString(id value) {
    if (![NSJSONSerialization isValidJSONObject:value]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static BOOL IcliFUInputCoordinatePair(NSDictionary *request, NSString *xKey, NSString *yKey, BOOL normalized, double *x, double *y) {
    return IcliFUInputNumber(request[xKey], x, normalized) && IcliFUInputNumber(request[yKey], y, normalized);
}

static id IcliFUHandleInputOperation(NSString *op, NSDictionary *request, NSDictionary **errorInfo) {
    if ([op isEqualToString:@"input.tap"] || [op isEqualToString:@"input.double_tap"] || [op isEqualToString:@"input.long_press"]) {
        double x = 0.0, y = 0.0;
        if (!IcliFUInputCoordinatePair(request, @"x", @"y", NO, &x, &y)) {
            if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"x and y must be finite non-negative numbers in screen points.");
            return nil;
        }
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObject:@"screen"];
        if ([op isEqualToString:@"input.tap"]) {
            [arguments addObjectsFromArray:@[@"tap", IcliFUInputNumberString(x), IcliFUInputNumberString(y)]];
        } else if ([op isEqualToString:@"input.double_tap"]) {
            [arguments addObjectsFromArray:@[@"double-tap", IcliFUInputNumberString(x), IcliFUInputNumberString(y)]];
            id intervalValue = request[@"interval"];
            if (intervalValue) {
                double interval = 0.0;
                if (!IcliFUInputNumber(intervalValue, &interval, NO)) {
                    if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"interval must be a finite non-negative number of seconds.");
                    return nil;
                }
                [arguments addObjectsFromArray:@[@"--interval", IcliFUInputNumberString(interval)]];
            }
        } else {
            [arguments addObjectsFromArray:@[@"long-press", IcliFUInputNumberString(x), IcliFUInputNumberString(y)]];
            id secondsValue = request[@"seconds"];
            if (secondsValue) {
                double seconds = 0.0;
                if (!IcliFUInputNumber(secondsValue, &seconds, NO)) {
                    if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"seconds must be a finite non-negative duration.");
                    return nil;
                }
                [arguments addObjectsFromArray:@[@"--seconds", IcliFUInputNumberString(seconds)]];
            }
        }
        return IcliFURunICLI(arguments, errorInfo);
    }

    if ([op isEqualToString:@"input.swipe"]) {
        double fromX = 0.0, fromY = 0.0, toX = 0.0, toY = 0.0;
        if (!IcliFUInputCoordinatePair(request, @"from_x", @"from_y", NO, &fromX, &fromY) ||
            !IcliFUInputCoordinatePair(request, @"to_x", @"to_y", NO, &toX, &toY)) {
            if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"from_x, from_y, to_x, and to_y must be finite non-negative screen coordinates.");
            return nil;
        }
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[
            @"screen", @"swipe",
            @"--from-x", IcliFUInputNumberString(fromX), @"--from-y", IcliFUInputNumberString(fromY),
            @"--to-x", IcliFUInputNumberString(toX), @"--to-y", IcliFUInputNumberString(toY),
        ]];
        id secondsValue = request[@"seconds"];
        if (secondsValue) {
            double seconds = 0.0;
            if (!IcliFUInputNumber(secondsValue, &seconds, NO)) {
                if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"seconds must be a finite non-negative duration.");
                return nil;
            }
            [arguments addObjectsFromArray:@[@"--seconds", IcliFUInputNumberString(seconds)]];
        }
        id stepsValue = request[@"steps"];
        if (stepsValue) {
            NSInteger steps = 0;
            if (!IcliFUInputPositiveInteger(stepsValue, &steps)) {
                if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"steps must be a positive integer.");
                return nil;
            }
            [arguments addObjectsFromArray:@[@"--steps", [NSString stringWithFormat:@"%ld", (long)steps]]];
        }
        return IcliFURunICLI(arguments, errorInfo);
    }

    if ([op isEqualToString:@"input.drag"]) {
        id pointsValue = request[@"points"];
        BOOL hasPoints = pointsValue != nil;
        BOOL hasAnyEndpoint = request[@"from_x"] || request[@"from_y"] || request[@"to_x"] || request[@"to_y"];
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"screen", @"drag", nil];
        if (hasPoints == hasAnyEndpoint) {
            if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"drag requires either points or all four endpoint coordinates, but not both.");
            return nil;
        }
        if (hasPoints) {
            if (![pointsValue isKindOfClass:[NSArray class]] || [(NSArray *)pointsValue count] < 2) {
                if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"points must be a JSON array containing at least two {x,y} objects.");
                return nil;
            }
            NSMutableArray *points = [NSMutableArray array];
            for (id rawPoint in (NSArray *)pointsValue) {
                if (![rawPoint isKindOfClass:[NSDictionary class]]) {
                    if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"each drag point must be an object with finite non-negative x and y values.");
                    return nil;
                }
                double x = 0.0, y = 0.0;
                if (!IcliFUInputCoordinatePair(rawPoint, @"x", @"y", NO, &x, &y)) {
                    if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"each drag point must have finite non-negative x and y values.");
                    return nil;
                }
                [points addObject:@{ @"x": @(x), @"y": @(y) }];
            }
            NSString *json = IcliFUInputJSONString(points);
            if (!json) {
                if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"points could not be encoded as JSON.");
                return nil;
            }
            [arguments addObjectsFromArray:@[@"--points", json]];
        } else {
            double fromX = 0.0, fromY = 0.0, toX = 0.0, toY = 0.0;
            if (!IcliFUInputCoordinatePair(request, @"from_x", @"from_y", NO, &fromX, &fromY) ||
                !IcliFUInputCoordinatePair(request, @"to_x", @"to_y", NO, &toX, &toY)) {
                if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"drag endpoint coordinates must be finite non-negative numbers.");
                return nil;
            }
            [arguments addObjectsFromArray:@[
                @"--from-x", IcliFUInputNumberString(fromX), @"--from-y", IcliFUInputNumberString(fromY),
                @"--to-x", IcliFUInputNumberString(toX), @"--to-y", IcliFUInputNumberString(toY),
            ]];
        }
        for (NSString *key in @[@"seconds", @"hold"]) {
            id value = request[key];
            if (!value) continue;
            double number = 0.0;
            if (!IcliFUInputNumber(value, &number, NO)) {
                if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", [NSString stringWithFormat:@"%@ must be a finite non-negative duration.", key]);
                return nil;
            }
            [arguments addObjectsFromArray:@[[NSString stringWithFormat:@"--%@", key], IcliFUInputNumberString(number)]];
        }
        id stepsValue = request[@"steps"];
        if (stepsValue) {
            NSInteger steps = 0;
            if (!IcliFUInputPositiveInteger(stepsValue, &steps)) {
                if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"steps must be a positive integer.");
                return nil;
            }
            [arguments addObjectsFromArray:@[@"--steps", [NSString stringWithFormat:@"%ld", (long)steps]]];
        }
        return IcliFURunICLI(arguments, errorInfo);
    }

    BOOL normalized = NO;
    id normalizedValue = request[@"normalized"];
    if (normalizedValue && !IcliFUInputBoolean(normalizedValue, &normalized)) {
        if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"normalized must be a boolean.");
        return nil;
    }

    if ([op isEqualToString:@"input.touch"]) {
        NSString *phase = [request[@"phase"] isKindOfClass:[NSString class]] ? request[@"phase"] : nil;
        if (![@[@"down", @"move", @"up"] containsObject:phase ?: @""]) {
            if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"phase must be down, move, or up.");
            return nil;
        }
        double x = 0.0, y = 0.0;
        if (!IcliFUInputCoordinatePair(request, @"x", @"y", normalized, &x, &y)) {
            NSString *message = normalized ? @"normalized x and y must be finite numbers from 0 through 1." : @"x and y must be finite non-negative screen coordinates.";
            if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", message);
            return nil;
        }
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[@"screen", @"touch", phase, IcliFUInputNumberString(x), IcliFUInputNumberString(y)]];
        if (normalized) [arguments addObject:@"--normalized"];
        return IcliFURunICLI(arguments, errorInfo);
    }

    if ([op isEqualToString:@"input.touch_sequence"]) {
        id eventsValue = request[@"events"];
        if (![eventsValue isKindOfClass:[NSArray class]] || [(NSArray *)eventsValue count] == 0) {
            if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"events must be a non-empty JSON array of touch events.");
            return nil;
        }
        NSMutableArray *events = [NSMutableArray array];
        for (id rawEvent in (NSArray *)eventsValue) {
            if (![rawEvent isKindOfClass:[NSDictionary class]]) {
                if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"each touch event must be an object with phase, x, y, and delay_ms.");
                return nil;
            }
            NSString *phase = [rawEvent[@"phase"] isKindOfClass:[NSString class]] ? rawEvent[@"phase"] : nil;
            double x = 0.0, y = 0.0, delay = 0.0;
            if (![@[@"down", @"move", @"up"] containsObject:phase ?: @""] ||
                !IcliFUInputCoordinatePair(rawEvent, @"x", @"y", normalized, &x, &y) ||
                !IcliFUInputNumber(rawEvent[@"delay_ms"], &delay, NO)) {
                if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"each touch event requires phase down|move|up, valid x/y coordinates, and finite non-negative delay_ms.");
                return nil;
            }
            [events addObject:@{ @"phase": phase, @"x": @(x), @"y": @(y), @"delay_ms": @(delay) }];
        }
        NSString *json = IcliFUInputJSONString(events);
        if (!json) {
            if (errorInfo) *errorInfo = IcliFUErrorInfo(@"invalid_arguments", @"events could not be encoded as JSON.");
            return nil;
        }
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[@"screen", @"touch-sequence", @"--events", json]];
        if (normalized) [arguments addObject:@"--normalized"];
        return IcliFURunICLI(arguments, errorInfo);
    }

    if (errorInfo) {
        *errorInfo = IcliFUErrorInfo(@"invalid_arguments", [NSString stringWithFormat:@"Unknown input operation '%@'.", op]);
    }
    return nil;
}


char *icli_flex_input_arguments_json(const char *source) {
    @autoreleasepool {
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:[@(source) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSDictionary *error = nil;
        id result = IcliFUHandleInputOperation(request[@"op"], request, &error);
        id response = result ?: @{@"error": error ?: @{}};
        NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
        return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    }
}
