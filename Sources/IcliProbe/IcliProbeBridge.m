#import "IcliProbeBridge.h"

#import <objc/runtime.h>

#include <math.h>

// Reflection is the point of the probe: without it a script can only do
// arithmetic, and the frameworks a device keeps to itself are exactly what
// there is no other way to reach. NSInvocation covers every method the runtime
// can describe, which is every method but a variadic one. Ported from
// vphoned's bridge; the JavaScriptCore classes come from the Class objects the
// context file resolves, so this file links without the framework.

Class IcliProbeContextClass;
Class IcliProbeValueClass;

static bool icli_probe_is_kind(id object, Class kind);
static bool icli_probe_is_value(id object);

/// Whether the method returns an object ARC has not accounted for, by the
/// same rule the compiler uses: a selector whose first word is alloc, new,
/// copy, mutableCopy or init belongs to that family. The word has to end
/// there, so `copyWithZone:` is in the family and `copyingProgress` is not —
/// taking ownership of a borrowed object would over-release it. Leading
/// underscores do not count, so the private `_initWithURL:` a probe is most
/// likely to call is an initializer too.
static bool icli_probe_in_family(NSString *name, NSString *family) {
    NSUInteger start = 0;
    while (start < name.length && [name characterAtIndex:start] == '_') start++;
    NSString *word = [name substringFromIndex:start];
    if (![word hasPrefix:family]) return false;
    if (word.length == family.length) return true;
    unichar next = [word characterAtIndex:family.length];
    return next < 'a' || next > 'z';
}

static bool icli_probe_returns_retained(SEL selector) {
    NSString *name = NSStringFromSelector(selector);
    for (NSString *family in @[@"alloc", @"new", @"copy", @"mutableCopy", @"init"]) {
        if (icli_probe_in_family(name, family)) return true;
    }
    return false;
}

/// An allocated object is not yet an object: NSString's allocation is a
/// placeholder that raises on anything but an initializer, and asking JSC to
/// convert it as a string would be one such message. It is handed back as a
/// handle, whatever it claims to be a kind of.
static bool icli_probe_returns_placeholder(SEL selector) {
    return icli_probe_in_family(NSStringFromSelector(selector), @"alloc");
}

/// A method encoding carries qualifiers the type itself does not: `const char *`
/// arrives as `r*`, and in, out and inout parameters are prefixed as well.
/// None of them change how the value is passed.
static const char *icli_probe_unqualified(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

@implementation IcliProbeObjCHandle

+ (instancetype)handleFor:(id)target {
    if (!target) return nil;
    IcliProbeObjCHandle *handle = [IcliProbeObjCHandle new];
    handle->_target = target;
    return handle;
}

- (BOOL)objcHandle {
    return YES;
}

- (NSString *)className {
    Class owner = object_isClass(_target) ? _target : [_target class];
    return NSStringFromClass(owner);
}

- (BOOL)isClassHandle {
    return object_isClass(_target);
}

- (JSValue *)plainValue {
    JSContext *context = [IcliProbeContextClass currentContext];
    if (icli_probe_is_value(_target) || icli_probe_is_kind(_target, [NSArray class]) ||
        icli_probe_is_kind(_target, [NSDictionary class])) {
        return [IcliProbeValueClass valueWithObject:_target inContext:context];
    }
    return [IcliProbeValueClass valueWithObject:[self toString] inContext:context];
}

- (NSString *)toString {
    NSString *description = nil;
    @try {
        description = [_target description];
    } @catch (NSException *exception) {
        description = [NSString stringWithFormat:@"<%@: description threw %@>", self.className, exception.name];
    }
    return description ?: [NSString stringWithFormat:@"<%@>", self.className];
}

// MARK: - Dispatch

/// Whether `object` is a `kind`, asked of the runtime rather than of the
/// object: a proxy forwards isKindOfClass: to whatever it stands for, and a
/// bare NSProxy raises, which would take the process with it.
static bool icli_probe_is_kind(id object, Class kind) {
    for (Class owner = object_getClass(object); owner; owner = class_getSuperclass(owner)) {
        if (owner == kind) return true;
    }
    return false;
}

/// Whether JSC's own conversion carries everything the object is: a string, a
/// number, a date and null are values, and so is a collection of them.
static bool icli_probe_is_value(id object) {
    return icli_probe_is_kind(object, [NSString class]) || icli_probe_is_kind(object, [NSNumber class]) ||
           icli_probe_is_kind(object, [NSDate class]) || icli_probe_is_kind(object, [NSNull class]);
}

/// A script sees a string, a number, a date or null where ObjC returned one,
/// and a handle for everything else, collections included: converting an
/// NSArray would hand back a copy, and a script that asked for a mutable one
/// wants the object. `$value` converts when that is what was wanted.
static JSValue *icli_probe_result(id object, JSContext *context) {
    if (!object) return [IcliProbeValueClass valueWithNullInContext:context];
    if (icli_probe_is_value(object)) return [IcliProbeValueClass valueWithObject:object inContext:context];
    return [IcliProbeValueClass valueWithObject:[IcliProbeObjCHandle handleFor:object] inContext:context];
}

void icli_probe_throw(JSContext *context, NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    context.exception = [IcliProbeValueClass valueWithNewErrorFromMessage:message inContext:context];
}

/// The target object behind a JS value: a handle for anything the bridge
/// returned, and JSC's own conversion for a string, number, array or object.
static id icli_probe_argument_object(JSValue *value) {
    if (value.isUndefined || value.isNull) return nil;
    id object = [value toObject];
    if ([object isKindOfClass:[IcliProbeObjCHandle class]]) return ((IcliProbeObjCHandle *)object).target;
    return object;
}

/// The method's signature as the object reports it or, where it reports none,
/// as the runtime describes the method, which is what a class whose metaclass
/// resolves methods lazily needs. NSProxy's own method raises instead of
/// answering nil, and nil is what it means.
static NSMethodSignature *icli_probe_signature(id target, SEL selector) {
    NSMethodSignature *signature = nil;
    @try {
        signature = [target methodSignatureForSelector:selector];
    } @catch (NSException *exception) {
    }
    if (signature) return signature;
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    return types ? [NSMethodSignature signatureWithObjCTypes:types] : nil;
}

// MARK: - Structs

/// A struct the bridge carries, described by the fields a script sees. Only
/// the geometry UIKit hands back and takes is here, since a view's frame is
/// the reason the probe needs structs at all. A struct this table does not
/// name keeps the clear refusal rather than being read from its layout alone:
/// CGRect and UIEdgeInsets are the same four doubles, so a layout cannot say
/// which one it is or what to call its fields.
typedef enum {
    IcliProbeStructDoubles,
    IcliProbeStructIntegers,
} IcliProbeStructKind;

typedef struct {
    const char *name;
    IcliProbeStructKind kind;
    unsigned count;
    const char *fields[4];
} IcliProbeStructLayout;

static const IcliProbeStructLayout icli_probe_struct_layouts[] = {
    {"CGPoint", IcliProbeStructDoubles, 2, {"x", "y"}},
    {"CGVector", IcliProbeStructDoubles, 2, {"dx", "dy"}},
    {"CGSize", IcliProbeStructDoubles, 2, {"width", "height"}},
    {"CGRect", IcliProbeStructDoubles, 4, {"x", "y", "width", "height"}},
    {"UIEdgeInsets", IcliProbeStructDoubles, 4, {"top", "left", "bottom", "right"}},
    {"NSDirectionalEdgeInsets", IcliProbeStructDoubles, 4, {"top", "leading", "bottom", "trailing"}},
    {"_NSRange", IcliProbeStructIntegers, 2, {"location", "length"}},
};

/// Every struct in the table is a run of 8-byte fields, so one storage holds
/// any of them and an invocation can be handed its address directly.
union IcliProbeStructStorage {
    double asDoubles[4];
    unsigned long asIntegers[4];
};

/// The field names a script has to supply, for the message that says so.
static NSString *icli_probe_field_list(const IcliProbeStructLayout *layout) {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:layout->count];
    for (unsigned index = 0; index < layout->count; index++) [names addObject:@(layout->fields[index])];
    return [names componentsJoinedByString:@", "];
}

/// Append the scalar field codes inside a struct body to `out`, flattening a
/// nested struct: CGRect's body is two structs, and what it is in memory is
/// four doubles. False when the body holds more fields than `capacity` or a
/// nested struct never closes, which leaves the encoding unsupported rather
/// than half-read.
static bool icli_probe_flatten_fields(const char *body, char *out, size_t capacity, size_t *length) {
    const char *cursor = body;
    while (*cursor && *cursor != '}' && *cursor != ')') {
        if (*cursor == '{' || *cursor == '(') {
            const char *equals = strchr(cursor, '=');
            if (!equals) return false;
            if (!icli_probe_flatten_fields(equals + 1, out, capacity, length)) return false;
            int depth = 0;
            bool closed = false;
            while (*cursor) {
                if (*cursor == '{' || *cursor == '(') {
                    depth++;
                } else if (*cursor == '}' || *cursor == ')') {
                    if (--depth == 0) {
                        cursor++;
                        closed = true;
                        break;
                    }
                }
                cursor++;
            }
            if (!closed) return false;
            continue;
        }
        if (*length >= capacity) return false;
        out[(*length)++] = *cursor++;
    }
    return true;
}

/// The layout for an encoding like `{CGRect={CGPoint=dd}{CGSize=dd}}`, or NULL
/// where the bridge does not carry that struct. The name picks the entry and
/// its flattened fields then have to agree with it, so a build whose struct is
/// not the shape this table was written against is refused instead of being
/// written through with the wrong one.
static const IcliProbeStructLayout *icli_probe_struct_layout(const char *type) {
    if (type[0] != '{') return NULL;
    const char *equals = strchr(type, '=');
    if (!equals || equals == type + 1) return NULL;
    size_t nameLength = (size_t)(equals - type) - 1;
    for (size_t entry = 0; entry < sizeof(icli_probe_struct_layouts) / sizeof(*icli_probe_struct_layouts); entry++) {
        const IcliProbeStructLayout *layout = &icli_probe_struct_layouts[entry];
        if (strlen(layout->name) != nameLength || strncmp(layout->name, type + 1, nameLength) != 0) continue;
        char fields[8];
        size_t length = 0;
        if (!icli_probe_flatten_fields(equals + 1, fields, sizeof(fields), &length)) return NULL;
        if (length != layout->count) return NULL;
        for (size_t field = 0; field < length; field++) {
            // A 64-bit device is the only target, so each field is 8 bytes:
            // CGFloat is a double, and NSUInteger and NSInteger are 'Q' and
            // 'q'. Anything else is a layout this table cannot write.
            if (layout->kind == IcliProbeStructDoubles ? fields[field] != 'd'
                                                       : !strchr("QqLl", fields[field])) {
                return NULL;
            }
        }
        return layout;
    }
    return NULL;
}

/// Fill `storage` from a script's plain object, one property per field. False
/// once the context's exception is set.
static bool icli_probe_fill_struct(union IcliProbeStructStorage *storage, const IcliProbeStructLayout *layout,
                                   JSValue *value, JSContext *context) {
    if (!value.isObject) {
        icli_probe_throw(context, @"Expected an object with %@ for the %s argument",
                         icli_probe_field_list(layout), layout->name);
        return false;
    }
    for (unsigned index = 0; index < layout->count; index++) {
        JSValue *field = value[@(layout->fields[index])];
        if (!field || field.isUndefined || field.isNull) {
            icli_probe_throw(context, @"The %s argument needs %@; %s is missing", layout->name,
                             icli_probe_field_list(layout), layout->fields[index]);
            return false;
        }
        // A string or a boolean converts to a number JSC's own way, which
        // would write a quiet zero or a NaN into the struct instead.
        if (!field.isNumber) {
            icli_probe_throw(context, @"The %s argument needs a number for %s", layout->name, layout->fields[index]);
            return false;
        }
        double number = [field toDouble];
        if (!isfinite(number)) {
            icli_probe_throw(context, @"The %s argument needs a finite %s", layout->name, layout->fields[index]);
            return false;
        }
        if (layout->kind == IcliProbeStructDoubles) {
            storage->asDoubles[index] = number;
        } else {
            storage->asIntegers[index] = (unsigned long)(long long)number;
        }
    }
    return true;
}

/// The struct an invocation left behind, as a plain object with one property
/// per field.
static JSValue *icli_probe_struct_return(NSInvocation *invocation, const IcliProbeStructLayout *layout,
                                         JSContext *context) {
    union IcliProbeStructStorage storage = {.asDoubles = {0}};
    // The layout says every field is 8 bytes, so a return of any other length
    // is not the struct the table describes and reading it would overrun.
    if (invocation.methodSignature.methodReturnLength != (NSUInteger)layout->count * sizeof(double)) {
        icli_probe_throw(context, @"%s is not the %u fields this build expects", layout->name, layout->count);
        return [IcliProbeValueClass valueWithUndefinedInContext:context];
    }
    [invocation getReturnValue:&storage];
    NSMutableDictionary<NSString *, NSNumber *> *fields = [NSMutableDictionary dictionaryWithCapacity:layout->count];
    for (unsigned index = 0; index < layout->count; index++) {
        fields[@(layout->fields[index])] = layout->kind == IcliProbeStructDoubles
            ? @(storage.asDoubles[index])
            : @(storage.asIntegers[index]);
    }
    return [IcliProbeValueClass valueWithObject:fields inContext:context];
}

/// One argument slot, large enough for every scalar an invocation takes.
union IcliProbeArgumentSlot {
    bool asBool;
    char asChar;
    unsigned char asUnsignedChar;
    short asShort;
    unsigned short asUnsignedShort;
    int asInt;
    unsigned int asUnsignedInt;
    long asLong;
    unsigned long asUnsignedLong;
    long long asLongLong;
    unsigned long long asUnsignedLongLong;
    float asFloat;
    double asDouble;
    void *asPointer;
    const char *asCString;
    Class asClass;
    SEL asSelector;
    __unsafe_unretained id asObject;
    union IcliProbeStructStorage asStruct;
};

/// Fill `slot` from `value` for one argument. `holds` keeps anything the
/// invocation borrows a pointer into alive until it returns. False once the
/// context's exception is set.
static bool icli_probe_fill(union IcliProbeArgumentSlot *slot, const char *type, JSValue *value,
                            NSMutableArray *holds, JSContext *context) {
    type = icli_probe_unqualified(type);
    switch (type[0]) {
    case '@': {
        // A block is called, not read, and a converted function is a
        // dictionary: the method would jump into it.
        if (type[1] == '?' && !(value.isNull || value.isUndefined)) {
            icli_probe_throw(context, @"Only null may be passed for the block argument");
            return false;
        }
        id object = icli_probe_argument_object(value);
        if (object) [holds addObject:object];
        slot->asObject = object;
        return true;
    }
    case '#': {
        id object = icli_probe_argument_object(value);
        if (object && !object_isClass(object)) {
            icli_probe_throw(context, @"Expected a class argument, got %@", [object class]);
            return false;
        }
        slot->asClass = object;
        return true;
    }
    case ':': {
        NSString *name = [value toString];
        slot->asSelector = name.length ? NSSelectorFromString(name) : NULL;
        return true;
    }
    case '*': {
        if (value.isNull || value.isUndefined) {
            slot->asCString = NULL;
            return true;
        }
        // A lone surrogate, half of an emoji, leaves a string no C form.
        NSString *text = [value toString];
        const char *bytes = text.UTF8String;
        if (!bytes) {
            icli_probe_throw(context, @"Expected a string argument with a UTF-8 form");
            return false;
        }
        [holds addObject:text];
        slot->asCString = bytes;
        return true;
    }
    case 'B': slot->asBool = [value toBool]; return true;
    case 'c': slot->asChar = (char)[value toInt32]; return true;
    case 'C': slot->asUnsignedChar = (unsigned char)[value toUInt32]; return true;
    case 's': slot->asShort = (short)[value toInt32]; return true;
    case 'S': slot->asUnsignedShort = (unsigned short)[value toUInt32]; return true;
    case 'i': slot->asInt = [value toInt32]; return true;
    case 'I': slot->asUnsignedInt = [value toUInt32]; return true;
    case 'l': slot->asLong = (long)[value toDouble]; return true;
    case 'L': slot->asUnsignedLong = (unsigned long)[value toDouble]; return true;
    case 'q': slot->asLongLong = (long long)[value toDouble]; return true;
    case 'Q': slot->asUnsignedLongLong = (unsigned long long)[value toDouble]; return true;
    case 'f': slot->asFloat = (float)[value toDouble]; return true;
    case 'd': slot->asDouble = [value toDouble]; return true;
    case '{': {
        const IcliProbeStructLayout *layout = icli_probe_struct_layout(type);
        if (!layout) {
            icli_probe_throw(context, @"Arguments of type '%s' are not supported", type);
            return false;
        }
        return icli_probe_fill_struct(&slot->asStruct, layout, value, context);
    }
    case '^':
        // A script has no way to make a valid pointer, and letting it invent
        // one would only turn a typo into a crash.
        if (value.isNull || value.isUndefined) {
            slot->asPointer = NULL;
            return true;
        }
        icli_probe_throw(context, @"Only null may be passed for the pointer argument '%s'", type);
        return false;
    default:
        icli_probe_throw(context, @"Arguments of type '%s' are not supported", type);
        return false;
    }
}

/// Read the return value an invocation left behind.
static JSValue *icli_probe_return(NSInvocation *invocation, const char *type, SEL selector, JSContext *context) {
    type = icli_probe_unqualified(type);
    switch (type[0]) {
    case 'v': return [IcliProbeValueClass valueWithUndefinedInContext:context];
    case '@': {
        void *raw = NULL;
        [invocation getReturnValue:&raw];
        id object = icli_probe_returns_retained(selector) ? (__bridge_transfer id)raw : (__bridge id)raw;
        if (object && icli_probe_returns_placeholder(selector)) {
            return [IcliProbeValueClass valueWithObject:[IcliProbeObjCHandle handleFor:object] inContext:context];
        }
        return icli_probe_result(object, context);
    }
    case '#': {
        Class result = Nil;
        [invocation getReturnValue:&result];
        return icli_probe_result(result, context);
    }
    case ':': {
        SEL result = NULL;
        [invocation getReturnValue:&result];
        return result ? [IcliProbeValueClass valueWithObject:NSStringFromSelector(result) inContext:context]
                      : [IcliProbeValueClass valueWithNullInContext:context];
    }
    case '*': {
        const char *result = NULL;
        [invocation getReturnValue:&result];
        return result ? [IcliProbeValueClass valueWithObject:@(result) inContext:context]
                      : [IcliProbeValueClass valueWithNullInContext:context];
    }
#define ICLI_PROBE_SCALAR_RETURN(encoding, kind)                                      \
    case encoding: {                                                                  \
        kind result = 0;                                                              \
        [invocation getReturnValue:&result];                                          \
        return [IcliProbeValueClass valueWithDouble:(double)result inContext:context];\
    }
        ICLI_PROBE_SCALAR_RETURN('c', char)
        ICLI_PROBE_SCALAR_RETURN('C', unsigned char)
        ICLI_PROBE_SCALAR_RETURN('s', short)
        ICLI_PROBE_SCALAR_RETURN('S', unsigned short)
        ICLI_PROBE_SCALAR_RETURN('i', int)
        ICLI_PROBE_SCALAR_RETURN('I', unsigned int)
        ICLI_PROBE_SCALAR_RETURN('l', long)
        ICLI_PROBE_SCALAR_RETURN('L', unsigned long)
        ICLI_PROBE_SCALAR_RETURN('q', long long)
        ICLI_PROBE_SCALAR_RETURN('Q', unsigned long long)
        ICLI_PROBE_SCALAR_RETURN('f', float)
        ICLI_PROBE_SCALAR_RETURN('d', double)
#undef ICLI_PROBE_SCALAR_RETURN
    case 'B': {
        bool result = false;
        [invocation getReturnValue:&result];
        return [IcliProbeValueClass valueWithBool:result inContext:context];
    }
    case '{': {
        const IcliProbeStructLayout *layout = icli_probe_struct_layout(type);
        if (!layout) break;
        return icli_probe_struct_return(invocation, layout, context);
    }
    case '^': {
        void *result = NULL;
        [invocation getReturnValue:&result];
        // The address is worth reading; nothing can be done with it here.
        return result ? [IcliProbeValueClass valueWithDouble:(double)(uintptr_t)result inContext:context]
                      : [IcliProbeValueClass valueWithNullInContext:context];
    }
    default:
        break;
    }
    icli_probe_throw(context, @"Return values of type '%s' are not supported", type);
    return [IcliProbeValueClass valueWithUndefinedInContext:context];
}

- (JSValue *)sendSelectorNamed:(NSString *)name arguments:(JSValue *)arguments {
    JSContext *context = [IcliProbeContextClass currentContext];
    JSValue *undefined = [IcliProbeValueClass valueWithUndefinedInContext:context];
    SEL selector = name.length ? NSSelectorFromString(name) : NULL;
    if (!selector) {
        icli_probe_throw(context, @"A selector is required");
        return undefined;
    }
    NSMethodSignature *signature = icli_probe_signature(_target, selector);
    if (!signature) {
        icli_probe_throw(context, @"%@ does not respond to %@", self.className, name);
        return undefined;
    }

    NSUInteger expected = signature.numberOfArguments - 2;
    NSUInteger given = [arguments[@"length"] toUInt32];
    if (given != expected) {
        icli_probe_throw(context, @"%@ takes %lu argument%s, got %lu", name,
                         (unsigned long)expected, expected == 1 ? "" : "s", (unsigned long)given);
        return undefined;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    invocation.target = _target;
    NSMutableArray *holds = [NSMutableArray array];
    union IcliProbeArgumentSlot slots[expected > 0 ? expected : 1];
    for (NSUInteger index = 0; index < expected; index++) {
        const char *type = [signature getArgumentTypeAtIndex:index + 2];
        if (!icli_probe_fill(&slots[index], type, [arguments valueAtIndex:(NSUInteger)index], holds, context)) {
            return undefined;
        }
        [invocation setArgument:&slots[index] atIndex:(NSInteger)(index + 2)];
    }

    // An initializer consumes its receiver: the caller hands over the
    // reference alloc gave it and gets back the one init returns. The alloc
    // handle keeps its own reference, so init is given a fresh one; without it
    // the object is released once more than it was retained. A class is never
    // an initializer's receiver. An init that raises leaks that reference,
    // which is the safe way to be wrong.
    if (!object_isClass(_target) && icli_probe_in_family(name, @"init")) (void)CFBridgingRetain(_target);
    @try {
        [invocation invoke];
    } @catch (NSException *exception) {
        icli_probe_throw(context, @"%@ raised %@: %@", name, exception.name, exception.reason ?: @"");
        return undefined;
    }
    if (signature.methodReturnLength == 0) return undefined;
    return icli_probe_return(invocation, signature.methodReturnType, selector, context);
}

@end
