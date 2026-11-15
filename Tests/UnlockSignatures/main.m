#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    char error[512];
    uint64_t secretBytes, secretLength, secretObject;
    bool attempted;
} FullUnlock;

static NSMethodSignature *factorySignature, *unlockSignature;
static bool hasFactory, hasModern, hasLegacy, readable;
static int factoryCalls, invocationCalls, secretCopies;
static bool fail(FullUnlock *s, const char *text) {
    if (!s->error[0]) strlcpy(s->error, text, sizeof(s->error));
    return false;
}
static bool readTask(FullUnlock *s, uint64_t address, void *out, size_t size) {
    (void)s;
    if (!readable) return false;
    memcpy(out, (void *)(uintptr_t)address, size);
    return true;
}
static uint64_t sel(FullUnlock *s, const char *name) {
    (void)s;
    return (uintptr_t)name;
}
static uint64_t klass(FullUnlock *s, const char *name) {
    (void)s;
    return !strcmp(name, "SBLockScreenManager") ? 1 : 2;
}
static uint64_t message(FullUnlock *s, uint64_t object, const char *name,
                        uint64_t a0, uint64_t a1, uint64_t a2) {
    (void)s; (void)a1; (void)a2;
    if (!object) return 0;
    if (object == 1) {
        if (!strcmp(name, "respondsToSelector:")) return hasFactory;
        if (!strcmp(name, "methodSignatureForSelector:")) return (uintptr_t)(__bridge void *)factorySignature;
        if (!strcmp(name, "sharedInstance")) { factoryCalls++; return 3; }
    } else if (object == 3) {
        if (!strcmp(name, "respondsToSelector:")) {
            return !strcmp((const char *)(uintptr_t)a0, "attemptUnlockWithPasscode:") ? hasLegacy : hasModern;
        }
        if (!strcmp(name, "methodSignatureForSelector:")) return (uintptr_t)(__bridge void *)unlockSignature;
    } else if (object == 2) {
        if (!strcmp(name, "invocationWithMethodSignature:")) { invocationCalls++; return 4; }
    } else if (object != 4) {
        NSMethodSignature *sig = (__bridge NSMethodSignature *)(void *)(uintptr_t)object;
        if (!strcmp(name, "numberOfArguments")) return sig.numberOfArguments;
        if (!strcmp(name, "methodReturnType")) return (uintptr_t)sig.methodReturnType;
        if (!strcmp(name, "getArgumentTypeAtIndex:")) return (uintptr_t)[sig getArgumentTypeAtIndex:a0];
    }
    return 0;
}
static uint64_t data(FullUnlock *s, const void *bytes, size_t size) {
    (void)s; (void)bytes; (void)size;
    secretCopies++;
    return 0; // Stop before preparing or invoking any supplied credential.
}
static uintptr_t symbol(FullUnlock *s, const char *name) { (void)s; (void)name; return 0; }
static bool call(FullUnlock *s, uintptr_t function, uint64_t *value,
                 uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                 uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7) {
    (void)s; (void)function; (void)value; (void)a0; (void)a1; (void)a2; (void)a3;
    (void)a4; (void)a5; (void)a6; (void)a7;
    return false;
}

#include "unlock-signature-production.inc"

static void check(const char *factory, const char *unlock, bool modern, bool accepted) {
    factorySignature = factory ? [NSMethodSignature signatureWithObjCTypes:factory] : nil;
    unlockSignature = unlock ? [NSMethodSignature signatureWithObjCTypes:unlock] : nil;
    hasFactory = true; hasModern = modern; hasLegacy = !modern; readable = true;
    factoryCalls = invocationCalls = secretCopies = 0;
    FullUnlock state = {0};
    bool result = invokeUnlock(&state, (const uint8_t *)"fixture", 7);
    assert(!result && !state.attempted);
    assert(invocationCalls == (accepted ? 1 : 0));
    assert(secretCopies == (accepted ? 1 : 0));
}

int main(void) {
    @autoreleasepool {
        check("@16@0:8", "v40@0:8@16B24B28@?32", true, true);
        check("@16@0:8", "v40@0:8@16c24c28@32", true, true);
        check("r@16@0:8", "v40@0:8r@16rB24rB28@?32", true, true);
        check("@16@0:8", "B24@0:8@16", false, true);
        check("q16@0:8", "v40@0:8@16B24B28@?32", true, false);
        assert(factoryCalls == 0);
        check("@?16@0:8", "v40@0:8@16B24B28@?32", true, false);
        assert(factoryCalls == 0);
        check(NULL, "v40@0:8@16B24B28@?32", true, false);
        check("@24@0:8@16", "v40@0:8@16B24B28@?32", true, false);
        check("@16@0:8", "v40@0:8q16B24B28@?32", true, false);
        check("@16@0:8", "v40@0:8@?16B24B28@?32", true, false);
        check("@16@0:8", "v40@0:8@16@24B28@?32", true, false);
        check("@16@0:8", "v40@0:8@16B24q28@?32", true, false);
        check("@16@0:8", "v40@0:8@16B24B28^v32", true, false);
        check("@16@0:8", "B24@0:8q16", false, false);
        check("@16@0:8", "v24@0:8@16", true, false);
        check("@16@0:8", NULL, true, false);
        hasFactory = false;
        FullUnlock missing = {0};
        factoryCalls = invocationCalls = secretCopies = 0;
        assert(!invokeUnlock(&missing, (const uint8_t *)"fixture", 7));
        assert(!factoryCalls && !invocationCalls && !secretCopies);
        hasFactory = true; readable = false;
        FullUnlock unreadable = {0};
        assert(!invokeUnlock(&unreadable, (const uint8_t *)"fixture", 7));
        assert(!factoryCalls && !invocationCalls && !secretCopies);
        puts("PASS: native unlock factory and argument signatures; incompatible APIs rejected before secret preparation");
    }
}
