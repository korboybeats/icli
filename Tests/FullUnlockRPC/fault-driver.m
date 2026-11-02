// Fault tests run the actual public bridge against the fixture. Only process
// discovery is replaced; VM, thread, exception and signal operations are real.
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <stdatomic.h>
#import <signal.h>
#import <pthread.h>
#import <unistd.h>
#import <sched.h>

static pid_t fixturePID;
static const char *testMode;
static _Atomic int regionReleased, signalBeforeCleanup, signalCount;
static vm_address_t retainedRegion;
static task_t fixtureTask;
static mach_port_t priorHandler;
static bool replyInjected, restoreInjected;
static mach_port_t failedReplyPort;
static mach_msg_return_t failedReplyResult;

mach_msg_return_t injectReply(mach_msg_header_t *message, mach_msg_option_t options, mach_msg_size_t sendSize,
    mach_msg_size_t receiveSize, mach_port_name_t receiveName, mach_msg_timeout_t timeout, mach_port_name_t notify) {
    if (testMode && !strcmp(testMode, "reply") && !replyInjected && (options & MACH_SEND_MSG)) {
        replyInjected = true;
        // A real kernel send failure: terminate our disposable target after
        // receiving its exception but before sending the restoration reply.
        if (kill(fixturePID, SIGKILL)) return MACH_SEND_INVALID_DEST;
        mach_port_type_t type = 0;
        while (mach_port_type(mach_task_self(), fixtureTask, &type) == KERN_SUCCESS &&
            !(type & MACH_PORT_TYPE_DEAD_NAME)) sched_yield();
        failedReplyResult = mach_msg(message, options, sendSize, receiveSize, receiveName, timeout, notify);
        failedReplyPort = message->msgh_remote_port;
        return failedReplyResult;
    }
    return mach_msg(message, options, sendSize, receiveSize, receiveName, timeout, notify);
}
kern_return_t injectRestore(thread_t thread, exception_mask_t mask, mach_port_t port,
    exception_behavior_t behavior, thread_state_flavor_t flavor) {
    if (testMode && (!strcmp(testMode, "restore") || !strcmp(testMode, "restore-denied")) &&
        port == priorHandler && (!restoreInjected || !strcmp(testMode, "restore-denied"))) {
        restoreInjected = true;
        return KERN_FAILURE;
    }
    return thread_set_exception_ports(thread, mask, port, behavior, flavor);
}

int fixtureSysctl(int *mib, u_int count, void *old, size_t *size, void *next, size_t nextSize) {
    if (count != 3 || mib[0] != CTL_KERN || mib[1] != KERN_PROC || mib[2] != KERN_PROC_ALL) {
        errno = EINVAL; return -1;
    }
    if (old) {
        if (*size < sizeof(struct kinfo_proc)) { errno = ENOMEM; return -1; }
        struct kinfo_proc process = {0};
        process.kp_proc.p_pid = fixturePID;
        strlcpy(process.kp_proc.p_comm, "SpringBoard", sizeof(process.kp_proc.p_comm));
        memcpy(old, &process, sizeof(process));
    }
    *size = sizeof(struct kinfo_proc);
    return 0;
}
int fixtureProcPath(int pid, void *buffer, uint32_t size) {
    if (pid != fixturePID) return 0;
    return (int)strlcpy(buffer, "/System/Library/CoreServices/SpringBoard.app/SpringBoard", size);
}
kern_return_t observeDeallocate(vm_map_t task, vm_address_t address, vm_size_t size) {
    if (task != mach_task_self() && size == 0x40000 && testMode && !strcmp(testMode, "deallocate")) {
        retainedRegion = address;
        return KERN_FAILURE;
    }
    kern_return_t result = vm_deallocate(task, address, size);
    if (task != mach_task_self() && size == 0x40000 && result == KERN_SUCCESS)
        atomic_store(&regionReleased, 1);
    return result;
}
#define sysctl fixtureSysctl
#define proc_pidpath fixtureProcPath
#define vm_deallocate observeDeallocate
#define mach_msg injectReply
#define thread_set_exception_ports injectRestore
#import "../../Sources/IcliPrivate/FullUnlock.m"
#undef sysctl
#undef proc_pidpath
#undef vm_deallocate
#undef mach_msg
#undef thread_set_exception_ports

bool icli_wake(void) { return true; }
IcliLockStatus icli_lock_status(void) { return (IcliLockStatus){0}; }
static void previousSignal(int number) {
    atomic_fetch_add(&signalCount, 1);
    if (!atomic_load(&regionReleased)) atomic_store(&signalBeforeCleanup, 1);
}
static void *otherThread(void *argument) {
    char byte;
    if (read(STDIN_FILENO, &byte, 1) == 1) {
        // raise() delivers on this unblocked thread before acknowledging.
        raise((int)(uintptr_t)argument);
        (void)write(STDOUT_FILENO, "SIGNAL_DELIVERED\n", 17);
    }
    return NULL;
}
static int rawFault(void) {
    FullUnlock session = {0};
    if (task_for_pid(mach_task_self(), fixturePID, &session.task)) return 2;
    bool prepared = prepareContext(&session, false);
    if (!prepared) { printf("FAIL setup: %s\n", session.error); cleanup(&session); return 2; }
    static const char synthetic[] = "fixture-passcode";
    session.secretBytes = data(&session, synthetic, sizeof(synthetic)-1);
    session.secretLength = sizeof(synthetic)-1;
    uint64_t remoteName = text(&session, "icli_fixture_read_byte"), function = 0, value = 0;
    bool resolved = call(&session, symbol(&session, "dlsym"), &function,
        (uint64_t)RTLD_DEFAULT, remoteName,0,0,0,0,0,0) && function;
    function = strip((void *)function);
    bool rawSecret = !strcmp(testMode, "secret");
    bool returned = resolved && call(&session, function, &value,
        rawSecret ? 1 : session.region,0,0,0,0,0,0,0);
    uint64_t secret = session.secretBytes;
    cleanup(&session);
    uint8_t bytes[sizeof(synthetic)-1]; vm_size_t actual = 0;
    bool readable = vm_read_overwrite(fixtureTask, secret, sizeof(bytes), (vm_address_t)bytes, &actual) == KERN_SUCCESS && actual == sizeof(bytes);
    bool wiped = readable;
    for (size_t i = 0; readable && i < sizeof(bytes); i++) if (bytes[i]) wiped = false;
    bool ok = resolved && !returned && (!rawSecret || wiped);
    printf("%s mode=%s resolved=%d rpc_returned=%d raw_secret_zeroed=%d detail=%s\n",
        ok ? "PASS" : "FAIL", testMode, resolved, returned, wiped, session.error);
    return ok ? 0 : 1;
}
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    fixturePID = atoi(argv[1]); testMode = argv[2];
    printf("DRIVER=%d\n", getpid()); fflush(stdout);
    @autoreleasepool {
        if (task_for_pid(mach_task_self(), fixturePID, &fixtureTask)) return 2;
        if (!strcmp(testMode, "data-fault") || !strcmp(testMode, "secret")) return rawFault();
        thread_t priorThread = MACH_PORT_NULL;
        if (!strcmp(testMode, "restore") || !strcmp(testMode, "restore-denied")) {
            FullUnlock identity = {.task = fixtureTask};
            priorThread = findMain(&identity);
            if (!priorThread || mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &priorHandler) ||
                mach_port_insert_right(mach_task_self(), priorHandler, priorHandler, MACH_MSG_TYPE_MAKE_SEND) ||
                thread_set_exception_ports(priorThread, EXC_MASK_BREAKPOINT, priorHandler,
                    EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES, THREAD_STATE_NONE)) return 2;
        }
        int number = !strcmp(testMode, "term") ? SIGTERM : !strcmp(testMode, "hup") ? SIGHUP : SIGINT;
        bool signalCase = !strcmp(testMode, "term") || !strcmp(testMode, "hup") || !strcmp(testMode, "int");
        pthread_t background;
        if (signalCase) {
            struct sigaction action = {.sa_handler = previousSignal};
            sigemptyset(&action.sa_mask);
            if (sigaction(number, &action, NULL) || pthread_create(&background, NULL, otherThread, (void *)(uintptr_t)number)) return 2;
        }
        if (!icli_full_unlock_signals_begin()) return 2;
        char *report = icli_full_unlock_json((const uint8_t *)"fixture-passcode", 16, false);
        bool restored = icli_full_unlock_signals_end();
        NSDictionary *answer = [NSJSONSerialization JSONObjectWithData:[@(report) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        bool confirmed = [answer[@"confirmed"] boolValue];
        bool ok = restored;
        if (signalCase) {
            pthread_join(background, NULL);
            ok = confirmed && !atomic_load(&signalBeforeCleanup) && atomic_load(&signalCount) == 1;
        } else if (!strcmp(testMode, "deallocate")) {
            uint8_t byte; vm_size_t size = 0;
            bool retained = retainedRegion && vm_read_overwrite(fixtureTask, retainedRegion+DATA_OFFSET, 1, (vm_address_t)&byte, &size) == KERN_SUCCESS;
            ok = [answer[@"attempted"] boolValue] && [answer[@"ready"] boolValue] &&
                !confirmed && retained && [answer[@"detail"] length] > 0;
            if (retainedRegion) vm_deallocate(fixtureTask, retainedRegion, REGION_SIZE);
        } else if (!strcmp(testMode, "exit")) {
            ok = !confirmed && [answer[@"detail"] length] > 0;
        } else if (!strcmp(testMode, "reply")) {
            mach_port_type_t type = 0;
            bool replyReleased = mach_port_type(mach_task_self(), failedReplyPort, &type) == KERN_INVALID_NAME;
            // A send-once reply to a dead receiver may be consumed with
            // success. Both kernel outcomes must release our reply right.
            ok = !confirmed && replyInjected &&
                (failedReplyResult == KERN_SUCCESS || failedReplyResult == MACH_SEND_INVALID_DEST) && replyReleased;
            printf("reply_result=%x reply_released=%d\n", failedReplyResult, replyReleased);
        } else if (!strcmp(testMode, "restore") || !strcmp(testMode, "restore-denied")) {
            exception_mask_t masks[EXC_TYPES_COUNT]; mach_port_t ports[EXC_TYPES_COUNT];
            exception_behavior_t behaviors[EXC_TYPES_COUNT]; thread_state_flavor_t flavors[EXC_TYPES_COUNT];
            mach_msg_type_number_t count = EXC_TYPES_COUNT;
            bool denied = !strcmp(testMode, "restore-denied");
            ok = (denied ? !confirmed && [answer[@"detail"] containsString:@"cleanup was incomplete"] : confirmed) &&
                restoreInjected && !thread_get_exception_ports(priorThread, EXC_MASK_BREAKPOINT,
                masks, &count, ports, behaviors, flavors);
            for (mach_msg_type_number_t i = 0; i < count; i++) {
                if (!denied && (masks[i] & EXC_MASK_BREAKPOINT) && ports[i] != priorHandler) ok = false;
                if (MACH_PORT_VALID(ports[i])) mach_port_deallocate(mach_task_self(), ports[i]);
            }
            thread_set_exception_ports(priorThread, EXC_MASK_BREAKPOINT, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
            mach_port_deallocate(mach_task_self(), priorThread);
            mach_port_mod_refs(mach_task_self(), priorHandler, MACH_PORT_RIGHT_RECEIVE, -1);
            mach_port_deallocate(mach_task_self(), priorHandler);
        }
        printf("%s mode=%s signal_before_cleanup=%d signal_count=%d report=%s\n",
            ok ? "PASS" : "FAIL", testMode, atomic_load(&signalBeforeCleanup), atomic_load(&signalCount), report ?: "null");
        free(report);
        mach_port_deallocate(mach_task_self(), fixtureTask);
        return ok ? 0 : 1;
    }
}
