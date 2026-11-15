#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#include <assert.h>

static dispatch_semaphore_t flushAllowed;
static void testSetValue(xpc_object_t dictionary, const char *key, xpc_object_t value) {
    xpc_dictionary_set_value(dictionary, key, value);
    if (!strcmp(key, "fd") && !value && flushAllowed) dispatch_semaphore_signal(flushAllowed);
}

// Exercise the production adapter with a separate bootstrap table. Nothing
// reaches the host's launchd. Releasing the request fd lets the fake daemon
// finish flushing, which makes the reply-before-flush case deterministic.
#define _os_alloc_once_table testAllocOnceTable
#define xpc_dictionary_set_value testSetValue
#import "../../Sources/IcliSystemPrivate/Launchd.m"
#undef xpc_dictionary_set_value
#undef _os_alloc_once_table
struct _os_alloc_once_s testAllocOnceTable[2];

static NSData *payload;
static uint64_t expectedRoutine;
static int nativeError;
static int requests;

static int sendLegacy(xpc_object_t pipe, xpc_object_t message, xpc_object_t __strong *reply, uint64_t flags) {
    assert(pipe && flags == 0);
    assert(xpc_dictionary_get_uint64(message, "type") == DomainSystem);
    assert(xpc_dictionary_get_uint64(message, "handle") == 0);
    assert(xpc_dictionary_get_uint64(message, "routine") == expectedRoutine);
    assert(xpc_dictionary_get_uint64(message, "subsystem") ==
           (expectedRoutine == RoutineKickstart || expectedRoutine == RoutinePrintService ? 2 : 3));
    requests++;
    if (nativeError) return nativeError;
    *reply = xpc_dictionary_create(NULL, NULL, 0);
    if (!xpc_dictionary_get_value(message, "fd")) return 0;
    int fd = xpc_dictionary_dup_fd(message, "fd");
    assert(fd >= 0);
    NSData *bytes = payload;
    dispatch_semaphore_t allowed = flushAllowed;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        assert(dispatch_semaphore_wait(allowed, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        FILE *stream = fdopen(fd, "a");
        assert(stream);
        assert(fwrite(bytes.bytes, 1, bytes.length, stream) == bytes.length);
        assert(fclose(stream) == 0);
    });
    return 0;
}

int main(void) {
    @autoreleasepool {
        loadPipeRoutines();
        interfaceRoutine = NULL;
        legacyRoutine = sendLegacy;
        struct xpc_global_data globals = {0};
        globals.xpc_bootstrap_pipe = xpc_dictionary_create(NULL, NULL, 0);
        testAllocOnceTable[1].ptr = &globals;
        uint64_t routines[] = {702, 708, 800, 801, 808, 809, 812, 813, 814, 815, 816, 819, 820, 828};
        for (size_t i = 0; i < sizeof(routines) / sizeof(*routines); i++) {
            expectedRoutine = routines[i];
            xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0), reply = NULL;
            assert(launchdRoutine(expectedRoutine, DomainSystem, 0, message, &reply) == 0 && reply);
        }
        assert(requests == 14);
        expectedRoutine = RoutinePrintService;
        for (NSUInteger length = 7; length < 2 * 0x100000; length += 0x180000) {
            payload = [[@"x" stringByPaddingToLength:length withString:@"x" startingAtIndex:0]
                       dataUsingEncoding:NSUTF8StringEncoding];
            flushAllowed = dispatch_semaphore_create(0);
            NSString *text = nil;
            xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
            assert(launchdPrint(expectedRoutine, DomainSystem, 0, message, &text) == 0);
            assert(text.length == MIN(length, 0x100000UL));
            assert([text isEqualToString:[@"x" stringByPaddingToLength:text.length withString:@"x" startingAtIndex:0]]);
        }
        flushAllowed = nil;
        nativeError = EACCES;
        NSString *text = nil;
        xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
        assert(launchdPrint(expectedRoutine, DomainSystem, 0, message, &text) == EACCES);
        legacyRoutine = NULL;
        assert(launchdPrint(expectedRoutine, DomainSystem, 0, message, &text) == ENOTSUP);
        puts("PASS legacy launchd subsystem mapping, reply-before-flush, pipe capacity, output bound and errors");
    }
}
