#import <Foundation/Foundation.h>

#import "FUObjectRegistry.h"
#import "FUProtocol.h"

@interface FUWeakObjectBox : NSObject
@property (nonatomic, weak) id object;
@property (nonatomic, strong) NSValue *addressKey;
@end

@implementation FUWeakObjectBox
@end

static NSMutableDictionary<NSString *, FUWeakObjectBox *> *FUHandleToObject;
static NSMutableDictionary<NSValue *, NSString *> *FUObjectAddressToHandle;
static NSMutableDictionary<NSString *, id> *FUPinnedObjects;
static NSObject *FUObjectRegistryLock;
static uint64_t FUObjectHandleCounter = 1;
static NSString *FUObjectGeneration;

static void FUInitializeObjectRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FUObjectGeneration = [[[NSUUID UUID].UUIDString lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
        FUHandleToObject = [NSMutableDictionary dictionary];
        FUObjectAddressToHandle = [NSMutableDictionary dictionary];
        FUPinnedObjects = [NSMutableDictionary dictionary];
        FUObjectRegistryLock = [NSObject new];
    });
}

static NSValue *FUObjectAddressKey(id object) {
    return [NSValue valueWithPointer:(__bridge const void *)object];
}

static void FURemoveExpiredRegistryEntry(NSString *handle, FUWeakObjectBox *box) {
    if (handle.length == 0 || !box) {
        return;
    }

    [FUHandleToObject removeObjectForKey:handle];
    if (box.addressKey && [FUObjectAddressToHandle[box.addressKey] isEqualToString:handle]) {
        [FUObjectAddressToHandle removeObjectForKey:box.addressKey];
    }
}

NSString *FUCurrentObjectGeneration(void) {
    FUInitializeObjectRegistry();
    return FUObjectGeneration ?: @"";
}

NSString *FUObjectGenerationFromHandle(NSString *handle) {
    if (![handle isKindOfClass:[NSString class]] || ![handle hasPrefix:@"obj_"]) {
        return nil;
    }

    NSString *suffix = [handle substringFromIndex:4];
    NSRange separator = [suffix rangeOfString:@"_" options:NSBackwardsSearch];
    if (separator.location == NSNotFound || separator.location == 0 || NSMaxRange(separator) >= suffix.length) {
        return nil;
    }

    NSString *generation = [suffix substringToIndex:separator.location];
    NSString *counter = [suffix substringFromIndex:NSMaxRange(separator)];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (counter.length == 0 || [counter rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        return nil;
    }
    return generation.length ? generation : nil;
}

BOOL FUObjectHandleIsStale(NSString *handle) {
    NSString *handleGeneration = FUObjectGenerationFromHandle(handle);
    return handleGeneration.length > 0 && ![handleGeneration isEqualToString:FUCurrentObjectGeneration()];
}

NSDictionary *FUObjectHandleErrorInfo(NSString *handle, NSString *notFoundMessage) {
    NSString *handleGeneration = FUObjectGenerationFromHandle(handle);
    NSString *currentGeneration = FUCurrentObjectGeneration();
    if (FUObjectHandleIsStale(handle)) {
        NSMutableDictionary *error = [FUErrorInfo(@"stale_handle", @"The object handle belongs to a previous target process generation. Resolve a stable selector or obtain a new handle from the current process.") mutableCopy];
        error[@"handle_generation"] = handleGeneration;
        error[@"current_generation"] = currentGeneration;
        return error;
    }
    return FUErrorInfo(@"object_not_found", notFoundMessage ?: @"The object handle is unknown or the object has expired.");
}

void FUObjectHandleErrorParts(NSString *handle,
                              NSString *notFoundMessage,
                              NSString **errorCode,
                              NSString **errorMessage) {
    NSDictionary *error = FUObjectHandleErrorInfo(handle, notFoundMessage);
    if (errorCode) *errorCode = error[@"code"];
    if (errorMessage) *errorMessage = error[@"message"];
}

NSString *FURegisterObject(id object) {
    if (!object) {
        return nil;
    }

    FUInitializeObjectRegistry();
    @synchronized (FUObjectRegistryLock) {
        NSValue *addressKey = FUObjectAddressKey(object);
        NSString *existing = FUObjectAddressToHandle[addressKey];
        if (existing) {
            FUWeakObjectBox *existingBox = FUHandleToObject[existing];
            id existingObject = existingBox.object;
            if (existingObject == object) {
                return existing;
            }

            // Weak handles deliberately do not retain inspected objects. Remove
            // an expired entry before reusing an address that the Objective-C
            // allocator may have assigned to a different object.
            FURemoveExpiredRegistryEntry(existing, existingBox);
        }

        NSString *handle = [NSString stringWithFormat:@"obj_%@_%llu", FUCurrentObjectGeneration(), FUObjectHandleCounter++];
        FUWeakObjectBox *box = [FUWeakObjectBox new];
        box.object = object;
        box.addressKey = addressKey;
        FUHandleToObject[handle] = box;
        FUObjectAddressToHandle[addressKey] = handle;
        return handle;
    }
}

id FUObjectForHandle(NSString *handle) {
    if (handle.length == 0) {
        return nil;
    }

    FUInitializeObjectRegistry();
    @synchronized (FUObjectRegistryLock) {
        FUWeakObjectBox *box = FUHandleToObject[handle];
        id object = box.object;
        if (!object) {
            FURemoveExpiredRegistryEntry(handle, box);
        }
        return object;
    }
}

NSString *FUPinObject(id object) {
    if (!object) {
        return nil;
    }

    NSString *handle = FURegisterObject(object);
    if (!handle) {
        return nil;
    }

    FUInitializeObjectRegistry();
    @synchronized (FUObjectRegistryLock) {
        FUPinnedObjects[handle] = object;
    }
    return handle;
}

BOOL FUUnpinObjectHandle(NSString *handle) {
    if (handle.length == 0) {
        return NO;
    }

    FUInitializeObjectRegistry();
    @synchronized (FUObjectRegistryLock) {
        BOOL wasPinned = FUPinnedObjects[handle] != nil;
        [FUPinnedObjects removeObjectForKey:handle];
        return wasPinned;
    }
}
