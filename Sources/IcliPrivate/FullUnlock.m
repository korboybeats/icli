// Standalone full unlock. No installed tweak or dylib payload: an owned,
// temporary pthread invokes SpringBoard's existing Objective-C methods using
// Mach exception replies. The passcode is only copied into task memory.
#import "IcliPrivate.h"
#import "IcliJSON.h"
#import "MachExceptions/IcliMachExceptionServer.h"
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/error.h>
#import <mach/notify.h>
#import <mach/arm/thread_status.h>
#import <notify.h>
#import <ptrauth.h>
#import <pthread.h>
#import <sched.h>
#import <signal.h>
#import <stdatomic.h>
#import <sys/sysctl.h>
#import <time.h>
#import <unistd.h>

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#if defined(__arm64__) && !TARGET_OS_TV
#define REGION_SIZE ((vm_size_t)0x40000)
#define DATA_OFFSET ((vm_address_t)0x20000)
#define CALL_TIMEOUT_MS 5000

typedef struct {
    task_t task;
    thread_t mainThread, worker;
    mach_port_t exceptions;
    mach_port_name_t remoteWaitPort;
    vm_address_t region, nextData, idleHeader;
    uint64_t remotePthread, pool, secretObject;
    uintptr_t msgSend, selector, getClass, receive, pthreadExit;
    uintptr_t stack;
    char error[240];
    bool attempted, workerCreated, uncertain;
    uint64_t secretBytes;
    size_t secretLength;
} FullUnlock;

typedef struct {
    FullUnlock *session;
    thread_t thread;
    bool owned, received, faulted;
    uint64_t value;
    arm_thread_state64_t resume;
    arm_neon_state64_t neon;
} ActiveCall;

static ActiveCall *activeCall;
static pthread_mutex_t callLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned pendingSignals;
static const int deferredSignals[] = {SIGINT, SIGTERM, SIGHUP};
static struct sigaction previousSignalActions[3];
static _Thread_local bool ownsSignalGuard;
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Signal deferral requires lock-free atomics.");
static void deferSignal(int number) {
    for (unsigned i = 0; i < 3; i++) if (number == deferredSignals[i])
        atomic_fetch_or_explicit(&pendingSignals, 1u << i, memory_order_relaxed);
}

static double monotonic(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static bool fail(FullUnlock *s, const char *message) {
    if (!s->error[0]) strlcpy(s->error, message, sizeof(s->error));
    return false;
}
static bool portDead(mach_port_t port) {
    mach_port_type_t type = 0;
    return MACH_PORT_VALID(port) && mach_port_type(mach_task_self(), port, &type) == KERN_SUCCESS &&
        (type & MACH_PORT_TYPE_DEAD_NAME);
}
static bool consumeNotification(mach_msg_header_t *header, thread_t watched, bool *exited) {
    if (header->msgh_bits & MACH_MSGH_BITS_COMPLEX) return false;
    if (header->msgh_id == MACH_NOTIFY_SEND_ONCE &&
        header->msgh_size == offsetof(mach_send_once_notification_t, trailer)) return true;
    if (header->msgh_id != MACH_NOTIFY_DEAD_NAME ||
        header->msgh_size != offsetof(mach_dead_name_notification_t, trailer)) return false;
    mach_dead_name_notification_t *notification = (void *)header;
    if (notification->not_port == watched && portDead(watched)) *exited = true;
    // A delivered dead-name notification owns one additional dead-name uref.
    mach_port_deallocate(mach_task_self(), notification->not_port);
    return true;
}
static bool observeExit(FullUnlock *s, thread_t thread) {
    mach_port_t previous = MACH_PORT_NULL;
    kern_return_t result = mach_port_request_notification(mach_task_self(), thread, MACH_NOTIFY_DEAD_NAME, 0,
        s->exceptions, MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous);
    if (result != KERN_SUCCESS) return fail(s, "Cannot observe target thread exit; nothing was redirected.");
    if (MACH_PORT_VALID(previous)) {
        // Never take over another consumer's observer in an embedding process.
        mach_port_t replaced = MACH_PORT_NULL;
        result = mach_port_request_notification(mach_task_self(), thread, MACH_NOTIFY_DEAD_NAME, 0,
            previous, MACH_MSG_TYPE_MOVE_SEND_ONCE, &replaced);
        if (MACH_PORT_VALID(replaced)) mach_port_deallocate(mach_task_self(), replaced);
        if (result != KERN_SUCCESS) mach_port_deallocate(mach_task_self(), previous);
        return fail(s, "The target thread already has an exit observer; nothing was redirected.");
    }
    return true;
}
static void stopObservingExit(FullUnlock *s, thread_t thread) {
    if (portDead(thread)) return;
    mach_port_t canceled = MACH_PORT_NULL;
    kern_return_t result = mach_port_request_notification(mach_task_self(), thread, MACH_NOTIFY_DEAD_NAME, 0,
        MACH_PORT_NULL, MACH_MSG_TYPE_MAKE_SEND_ONCE, &canceled);
    if (MACH_PORT_VALID(canceled)) mach_port_deallocate(mach_task_self(), canceled);
    if (result != KERN_SUCCESS && !portDead(thread)) {
        s->uncertain = true;
        fail(s, "Cannot remove the temporary thread-exit observer.");
    }
}
static bool readTask(FullUnlock *s, uint64_t address, void *out, size_t size) {
    vm_size_t actual = 0;
    return vm_read_overwrite(s->task, address, size, (vm_address_t)out, &actual) == KERN_SUCCESS && actual == size;
}
static bool writeTask(FullUnlock *s, uint64_t address, const void *bytes, size_t size) {
    return vm_write(s->task, address, (vm_offset_t)bytes, (mach_msg_type_number_t)size) == KERN_SUCCESS;
}
static uintptr_t strip(void *pointer) {
    return (uintptr_t)ptrauth_strip(pointer, ptrauth_key_function_pointer);
}
static void *callable(uintptr_t pointer) {
    return ptrauth_sign_unauthenticated((void *)pointer, ptrauth_key_function_pointer, 0);
}
static uintptr_t symbol(FullUnlock *s, const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p) { fail(s, "A required system symbol is unavailable."); return 0; }
    uintptr_t address = strip(p);
    uint8_t bytes[16];
    // Cross-process pointers are used only after verifying the same shared
    // cache code is mapped there. Never assume an ASLR slide or patch code.
    if (!readTask(s, address, bytes, sizeof(bytes)) || memcmp(bytes, (void *)address, sizeof(bytes))) {
        snprintf(s->error, sizeof(s->error), "Cannot validate system symbol %s in the target process.", name);
        return 0;
    }
    return address;
}
static uint64_t data(FullUnlock *s, const void *bytes, size_t length) {
    uint64_t address = s->nextData;
    if (!address || address + length > s->region + REGION_SIZE) {
        fail(s, "Unlock request exceeds its bounded memory region."); return 0;
    }
    if (!writeTask(s, address, bytes, length)) { fail(s, "Cannot write unlock request memory."); return 0; }
    s->nextData = (address + length + 7) & ~7ULL;
    return address;
}
static uint64_t text(FullUnlock *s, const char *string) { return data(s, string, strlen(string) + 1); }

// Thread-state pointers are signed with the owning task's keys. Translate
// through the kernel before using the SDK accessors in this process, and
// translate back before setting state or replying to an exception. This
// avoids sharing pointer-authentication keys or spawning another process.
static kern_return_t convertState(thread_t thread, int direction,
    const arm_thread_state64_t *input, arm_thread_state64_t *output) {
    typedef kern_return_t (*Convert)(thread_t, int, thread_state_flavor_t,
        thread_state_t, mach_msg_type_number_t, thread_state_t, mach_msg_type_number_t *);
    Convert convert = dlsym(RTLD_DEFAULT, "thread_convert_thread_state");
    if (!convert) return KERN_NOT_SUPPORTED;
    arm_thread_state64_t copy = *input;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t result = convert(thread, direction, ARM_THREAD_STATE64,
        (thread_state_t)&copy, ARM_THREAD_STATE64_COUNT, (thread_state_t)output, &count);
    return result == KERN_SUCCESS && count != ARM_THREAD_STATE64_COUNT ? KERN_INVALID_ARGUMENT : result;
}
static kern_return_t localThreadState(thread_t thread, arm_thread_state64_t *state) {
    arm_thread_state64_t target;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t result = thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&target, &count);
    if (result != KERN_SUCCESS) return result;
    return convertState(thread, THREAD_CONVERT_THREAD_STATE_TO_SELF, &target, state);
}

static bool idle(thread_t thread, arm_thread_state64_t *state) {
    if (localThreadState(thread, state)) return false;
    thread_basic_info_data_t basic;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&basic, &count) || basic.run_state != TH_STATE_WAITING)
        return false;
    // Only a still-pending, receive-only Mach trap may be restarted. Never
    // replay a send or redirect an arbitrary runnable instruction.
    if (!(state->__x[1] & MACH_RCV_MSG) || (state->__x[1] & MACH_SEND_MSG)) return false;
    Dl_info info;
    uintptr_t pc = __darwin_arm_thread_state64_get_pc(*state);
    if (!dladdr((void *)pc, &info) || !info.dli_sname || pc <= (uintptr_t)info.dli_saddr) return false;
    bool receiveTrap = !strcmp(info.dli_sname, "mach_msg2_trap") || !strcmp(info.dli_sname, "mach_msg_trap") ||
        !strcmp(info.dli_sname, "mach_msg_overwrite_trap");
    return receiveTrap && *(const uint32_t *)(pc - 4) == 0xd4001001; // verified svc #0x80
}

static thread_t findMain(FullUnlock *s) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(s->task, &threads, &count)) return MACH_PORT_NULL;
    thread_t found = MACH_PORT_NULL;
    uintptr_t mainQueue = (uintptr_t)dispatch_get_main_queue();
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_identifier_info_data_t info;
        mach_msg_type_number_t size = THREAD_IDENTIFIER_INFO_COUNT;
        uint64_t queue = 0;
        if (!thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&info, &size) &&
            info.dispatch_qaddr && readTask(s, info.dispatch_qaddr, &queue, sizeof(queue)) && queue == mainQueue) {
            if (found) { // Ambiguous identity fails closed.
                mach_port_deallocate(mach_task_self(), found); found = MACH_PORT_NULL;
                for (mach_msg_type_number_t j = i; j < count; j++) mach_port_deallocate(mach_task_self(), threads[j]);
                break;
            }
            found = threads[i];
        } else {
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    return found;
}

static void idleState(FullUnlock *s, arm_thread_state64_t *state) {
    __darwin_arm_thread_state64_set_pc_fptr(*state, callable(s->receive));
    __darwin_arm_thread_state64_set_lr_fptr(*state, callable(s->pthreadExit));
    __darwin_arm_thread_state64_set_sp(*state, (void *)s->stack);
    memset(state->__x, 0, sizeof(state->__x));
    state->__x[0] = s->idleHeader;
}

// Generated MIG stubs validate the exception message layout. No ad-hoc Mach
// packet offsets and no spinning return gadget in the target process.
kern_return_t icli_full_unlock_catch_raise(mach_port_t port, mach_port_t thread, mach_port_t task,
    exception_type_t exception, mach_exception_data_t code, mach_msg_type_number_t count) {
    mach_port_deallocate(mach_task_self(), thread);
    mach_port_deallocate(mach_task_self(), task);
    return KERN_FAILURE;
}
kern_return_t icli_full_unlock_catch_raise_state(mach_port_t port, exception_type_t exception,
    const mach_exception_data_t code, mach_msg_type_number_t count, int *flavor,
    const thread_state_t old, mach_msg_type_number_t oldCount, thread_state_t next, mach_msg_type_number_t *nextCount) {
    return KERN_FAILURE;
}
kern_return_t icli_full_unlock_catch_raise_state_identity(mach_port_t port, mach_port_t thread, mach_port_t task,
    exception_type_t exception, mach_exception_data_t code, mach_msg_type_number_t count, int *flavor,
    thread_state_t old, mach_msg_type_number_t oldCount, thread_state_t next, mach_msg_type_number_t *nextCount) {
    ActiveCall *call = activeCall;
    bool matches = call && thread == call->thread && task == call->session->task &&
        *flavor == ARM_THREAD_STATE64 && oldCount == ARM_THREAD_STATE64_COUNT;
    if (!matches) {
        mach_port_deallocate(mach_task_self(), thread); mach_port_deallocate(mach_task_self(), task);
        return KERN_FAILURE;
    }
    arm_thread_state64_t *returned = (arm_thread_state64_t *)old;
    arm_thread_state64_t localFault;
    // A data access to the return page is a fault inside the callee, not a
    // completed call. Only instruction fetch at the return address completes it.
    bool expected = exception == EXC_BAD_ACCESS && count >= 2 && (uint64_t)code[1] == call->session->region &&
        convertState(thread, THREAD_CONVERT_THREAD_STATE_TO_SELF, returned, &localFault) == KERN_SUCCESS &&
        __darwin_arm_thread_state64_get_pc(localFault) == call->session->region;
    call->value = returned->__x[0];
    call->faulted = !expected;
    call->received = true;
    // Restore the existing main thread in full. The owned worker instead
    // blocks on its private Mach receive port between calls.
    if (!call->owned && thread_set_state(thread, ARM_NEON_STATE64, (thread_state_t)&call->neon, ARM_NEON_STATE64_COUNT)) {
        call->faulted = true;
    }
    arm_thread_state64_t resume = call->resume;
#if __has_feature(ptrauth_calls)
    // Exception replies require this exception's random PC/LR diversifier.
    // The saved local pointers still use the ordinary thread-state schema;
    // convertState authenticates that input, then signs the target output
    // with the preserved diversifier. Do not re-sign locally after this merge.
    resume.__opaque_flags = (resume.__opaque_flags & ~__DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK) |
        (returned->__opaque_flags & __DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK);
#endif
    kern_return_t conversion = convertState(thread, THREAD_CONVERT_THREAD_STATE_FROM_SELF,
        &resume, (arm_thread_state64_t *)next);
    if (conversion != KERN_SUCCESS) {
        call->faulted = true;
        mach_port_deallocate(mach_task_self(), thread); mach_port_deallocate(mach_task_self(), task);
        return KERN_FAILURE;
    }
    *nextCount = ARM_THREAD_STATE64_COUNT;
    mach_port_deallocate(mach_task_self(), thread); mach_port_deallocate(mach_task_self(), task);
    return KERN_SUCCESS;
}

static bool rpc(FullUnlock *s, thread_t thread, bool owned, uintptr_t function, const uint64_t args[8], uint64_t *value) {
    if (s->error[0]) return false;
    if (!function) return fail(s, "A required remote call is unavailable.");
    arm_thread_state64_t seed;
    double deadline = monotonic() + CALL_TIMEOUT_MS / 1000.0;
    while (!idle(thread, &seed)) {
        if (monotonic() >= deadline) return fail(s, "The target thread is not at a safe IPC wait; nothing was redirected.");
        sched_yield();
    }
    if (thread_suspend(thread)) return fail(s, "Cannot suspend the target thread for its call.");
    if (!idle(thread, &seed)) {
        thread_resume(thread); return fail(s, "The target left its safe IPC wait; nothing was redirected.");
    }
    ActiveCall call = {.session = s, .thread = thread, .owned = owned, .resume = seed};
    // thread_abort_safely cancels the pending receive. Restoring a snapshot
    // after that cancellation can return a bogus result into CFRunLoop.
    // Preserve the original receive arguments and restart its verified SVC.
    if (!owned) {
        uintptr_t receiveInstruction = __darwin_arm_thread_state64_get_pc(seed) - 4;
        __darwin_arm_thread_state64_set_pc_fptr(call.resume, callable(receiveInstruction));
        // A kernel-signed LR can be replaced with the exception's LR on reply.
        // Preserve IB-signed return addresses as-is; make any other LR an
        // ordinary user-signed pointer before saving the restoration state.
        void *lr = __darwin_arm_thread_state64_get_lr_fptr(call.resume);
        if (lr) __darwin_arm_thread_state64_set_lr_fptr(call.resume, lr);
    } else {
        idleState(s, &call.resume);
    }
    arm_thread_state64_t invoke = seed, targetInvoke, targetResume;
    __darwin_arm_thread_state64_set_pc_fptr(invoke, callable(function));
    __darwin_arm_thread_state64_set_lr_fptr(invoke, callable(s->region));
    __darwin_arm_thread_state64_set_sp(invoke, (void *)(s->region + 0x18000));
    memcpy(invoke.__x, args, 8 * sizeof(uint64_t));
    kern_return_t conversion = convertState(thread, THREAD_CONVERT_THREAD_STATE_FROM_SELF, &invoke, &targetInvoke);
    if (conversion == KERN_SUCCESS)
        conversion = convertState(thread, THREAD_CONVERT_THREAD_STATE_FROM_SELF, &call.resume, &targetResume);
    if (conversion != KERN_SUCCESS) {
        thread_resume(thread);
        snprintf(s->error, sizeof(s->error), "Cannot translate temporary thread state: %s (Mach %d); target not redirected.",
            mach_error_string(conversion), conversion);
        return false;
    }
    if (thread_abort_safely(thread)) {
        thread_resume(thread); return fail(s, "Cannot safely abort the pending receive.");
    }
    mach_msg_type_number_t size = ARM_NEON_STATE64_COUNT;
    if (!owned && thread_get_state(thread, ARM_NEON_STATE64, (thread_state_t)&call.neon, &size)) {
        thread_resume(thread); return fail(s, "Cannot preserve the main thread vector registers.");
    }
    exception_mask_t masks[EXC_TYPES_COUNT]; mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT]; thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t handlers = EXC_TYPES_COUNT;
    exception_mask_t mask = EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT;
    if (thread_swap_exception_ports(thread, mask, s->exceptions, EXCEPTION_STATE_IDENTITY | MACH_EXCEPTION_CODES,
            ARM_THREAD_STATE64, masks, &handlers, ports, behaviors, flavors)) {
        thread_resume(thread); return fail(s, "Cannot establish the temporary exception reply channel.");
    }
    bool observed = observeExit(s, thread);
    kern_return_t stateError = observed ? thread_set_state(thread, ARM_THREAD_STATE64,
        (thread_state_t)&targetInvoke, ARM_THREAD_STATE64_COUNT) : KERN_FAILURE;
    bool started = observed && stateError == KERN_SUCCESS;
    activeCall = &call;
    thread_resume(thread);
    bool transport = started;
    kern_return_t transportCode = KERN_SUCCESS;
    mach_msg_id_t receivedID = 0;
    if (started) {
        union { mach_msg_header_t header; uint8_t bytes[16384]; } request, reply;
        // Once a target call has started, never abandon its exception port:
        // a late return must still receive the reply that restores its state.
        // Waiting here consumes no target CPU. Signals are deferred until the
        // call is safely unwound by the outer entry point.
        while (!call.received) {
            kern_return_t kr = mach_msg(&request.header, MACH_RCV_MSG, 0, sizeof(request),
                s->exceptions, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
            if (kr == MACH_RCV_INTERRUPTED) continue;
            transportCode = kr;
            if (kr != KERN_SUCCESS) { transport = false; break; }
            bool exited = false;
            if (consumeNotification(&request.header, thread, &exited)) {
                if (!exited) continue;
                s->uncertain = true;
                fail(s, "The target thread exited before its call completed; no unlock was retried.");
                transport = false;
                break;
            }
            receivedID = request.header.msgh_id;
            if (!icli_full_unlock_exception_server(&request.header, &reply.header)) {
                mach_msg_destroy(&request.header); transport = false; break;
            }
            kr = mach_msg(&reply.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, reply.header.msgh_size,
                0, MACH_PORT_NULL, CALL_TIMEOUT_MS, MACH_PORT_NULL);
            transport = kr == KERN_SUCCESS;
            transportCode = kr;
            // These send errors pseudo-receive the unsent message back to
            // us. Release its returned rights, as mach_msg_server does.
            if (kr == MACH_SEND_INVALID_DEST || kr == MACH_SEND_TIMED_OUT || kr == MACH_SEND_INTERRUPTED)
                mach_msg_destroy(&reply.header);
            if (!transport) break;
        }
    }
    activeCall = NULL;
    if (observed) stopObservingExit(s, thread);
    for (mach_msg_type_number_t i = 0; i < handlers; i++) {
        // The swap returns every replaced mask, including empty handlers.
        // Restore those exact masks without an intervening blanket clear.
        if (!portDead(thread)) {
            kern_return_t restored = thread_set_exception_ports(thread, masks[i], ports[i], behaviors[i], flavors[i]);
            // Restoration is idempotent; retrying it never repeats a call.
            if (restored != KERN_SUCCESS && !portDead(thread))
                restored = thread_set_exception_ports(thread, masks[i], ports[i], behaviors[i], flavors[i]);
            if (restored != KERN_SUCCESS && !portDead(thread)) {
                s->uncertain = true;
                fail(s, "Cannot restore the target thread's previous exception handler.");
            }
        }
        if (MACH_PORT_VALID(ports[i])) mach_port_deallocate(mach_task_self(), ports[i]);
    }
    if (s->error[0]) return false;
    if (!started) {
        if (!s->error[0]) snprintf(s->error, sizeof(s->error), "thread_set_state failed: %s (Mach %d); no unlock attempted.",
            mach_error_string(stateError), stateError);
        return false;
    }
    if (!transport || !call.received) {
        s->uncertain = true;
        Dl_info info = {0}; dladdr((void *)function, &info);
        if (!s->error[0]) snprintf(s->error, sizeof(s->error), "Call %s did not return through its reply channel (Mach %x, message %d, received %d, owned %d); no retry.",
            info.dli_sname ?: "unknown", transportCode, receivedID, call.received, owned);
        return false;
    }
    if (call.faulted) { s->uncertain = true; return fail(s, "The temporary call raised an unexpected exception; no unlock was retried."); }
    if (value) *value = call.value;
    return true;
}

static bool call(FullUnlock *s, uintptr_t function, uint64_t *value, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                 uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7) {
    uint64_t args[] = {a0,a1,a2,a3,a4,a5,a6,a7};
    return rpc(s, s->worker ?: s->mainThread, s->worker != MACH_PORT_NULL, function, args, value);
}
static uint64_t sel(FullUnlock *s, const char *name) {
    uint64_t result = 0, string = text(s, name);
    if (string) call(s, s->selector, &result, string,0,0,0,0,0,0,0);
    return result;
}
static uint64_t message(FullUnlock *s, uint64_t object, const char *name, uint64_t a0, uint64_t a1, uint64_t a2) {
    uint64_t result = 0, method = sel(s, name);
    if (method && object) call(s, s->msgSend, &result, object,method,a0,a1,a2,0,0,0);
    return result;
}
static uint64_t klass(FullUnlock *s, const char *name) {
    uint64_t result = 0, string = text(s, name);
    if (string) call(s, s->getClass, &result, string,0,0,0,0,0,0,0);
    return result;
}

static bool prepareContext(FullUnlock *s, bool checkOnly) {
    s->msgSend = symbol(s, "objc_msgSend");
    s->selector = symbol(s, "sel_registerName");
    s->getClass = symbol(s, "objc_getClass");
    s->receive = symbol(s, "mach_msg_receive");
    s->pthreadExit = symbol(s, "pthread_exit");
    if (s->error[0]) return false;
    s->mainThread = findMain(s);
    if (!s->mainThread) return fail(s, "Cannot unambiguously identify the target's main dispatch thread.");
    arm_thread_state64_t state;
    kern_return_t conversion = localThreadState(s->mainThread, &state);
    if (conversion != KERN_SUCCESS) {
        snprintf(s->error, sizeof(s->error), "Cannot translate target thread state for this caller: %s (Mach %d); target not modified.",
            mach_error_string(conversion), conversion);
        return false;
    }
    if (checkOnly) return true;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &s->exceptions) ||
        mach_port_insert_right(mach_task_self(), s->exceptions, s->exceptions, MACH_MSG_TYPE_MAKE_SEND))
        return fail(s, "Cannot allocate the exception reply channel.");
    if (vm_allocate(s->task, &s->region, REGION_SIZE, VM_FLAGS_ANYWHERE))
        return fail(s, "Cannot allocate temporary target memory.");
    if (vm_protect(s->task, s->region, vm_page_size, false, VM_PROT_NONE))
        return fail(s, "Cannot protect the controlled exception return page.");
    s->nextData = s->region + DATA_OFFSET;
    s->stack = s->region + 0x18000;
    uint64_t remoteTask = 0;
    if (!readTask(s, (uintptr_t)&mach_task_self_, &remoteTask, sizeof(mach_port_t)))
        return fail(s, "Cannot read the target task identity.");
    uint64_t zero = 0, portOut = data(s, &zero, sizeof(zero)), result = 0;
    if (!call(s, symbol(s, "mach_port_allocate"), &result, remoteTask,MACH_PORT_RIGHT_RECEIVE,portOut,0,0,0,0,0) || result ||
        !readTask(s, portOut, &s->remoteWaitPort, sizeof(s->remoteWaitPort)))
        return fail(s, "Cannot allocate the owned thread wait port.");
    mach_msg_header_t header = {.msgh_size = sizeof(header), .msgh_local_port = s->remoteWaitPort};
    s->idleHeader = data(s, &header, sizeof(header));
    uint64_t startName = text(s, "mach_msg_receive"), start = 0;
    if (!call(s, symbol(s, "dlsym"), &start, (uint64_t)RTLD_DEFAULT,startName,0,0,0,0,0,0) || !start)
        return fail(s, "Cannot resolve the owned thread entry point in its own process.");
    uint64_t pthreadOut = data(s, &zero, sizeof(zero));
    if (!call(s, symbol(s, "pthread_create"), &result, pthreadOut,0,start,s->idleHeader,0,0,0,0) || result)
        return fail(s, "Cannot create the temporary target pthread.");
    s->workerCreated = true;
    if (!readTask(s, pthreadOut, &s->remotePthread, sizeof(s->remotePthread)))
        return fail(s, "Cannot read the temporary target pthread identity.");
    uint64_t threadIDOut = data(s, &zero, sizeof(zero)), threadID = 0;
    if (!call(s, symbol(s, "pthread_threadid_np"), &result, s->remotePthread,threadIDOut,0,0,0,0,0,0) || result ||
        !readTask(s, threadIDOut, &threadID, sizeof(threadID)) || !threadID)
        return fail(s, "Cannot identify the owned target thread.");
    // Direct extraction of the thread-self right failed on the tested iOS.
    // Ask task_threads for control rights, and match only the
    // kernel's unique id for the pthread this invocation created.
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    kern_return_t threadError = task_threads(s->task, &threads, &count);
    if (threadError != KERN_SUCCESS) return fail(s, "Cannot enumerate the owned target thread.");
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_identifier_info_data_t info;
        mach_msg_type_number_t size = THREAD_IDENTIFIER_INFO_COUNT;
        if (!thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&info, &size) && info.thread_id == threadID)
            s->worker = threads[i];
        else
            mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    if (!s->worker) return fail(s, "Cannot obtain the owned target thread port by its unique id.");
    if (!call(s, symbol(s, "objc_autoreleasePoolPush"), &s->pool, 0,0,0,0,0,0,0,0)) return false;
    return true;
}

static bool setup(FullUnlock *s, bool checkOnly) {
    if (geteuid() != 0) return fail(s, "Full unlock requires root.");
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL}; size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0)) return fail(s, "Cannot enumerate processes.");
    length += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = calloc(1, length);
    if (!processes) return fail(s, "Cannot allocate process information.");
    pid_t pid = 0;
    if (!sysctl(mib, 3, processes, &length, NULL, 0)) {
        for (size_t i = 0; i < length / sizeof(*processes); i++) {
            if (strcmp(processes[i].kp_proc.p_comm, "SpringBoard")) continue;
            char path[4096] = {0};
            pid_t candidate = processes[i].kp_proc.p_pid;
            if (proc_pidpath(candidate, path, sizeof(path)) > 0 &&
                !strcmp(path, "/System/Library/CoreServices/SpringBoard.app/SpringBoard")) { pid = candidate; break; }
        }
    } else {
        free(processes);
        return fail(s, "Cannot read the process table.");
    }
    free(processes);
    if (!pid) return fail(s, "Cannot identify SpringBoard by its executable path; no task-port request was made.");
    kern_return_t taskError = task_for_pid(mach_task_self(), pid, &s->task);
    if (taskError != KERN_SUCCESS) {
        // Distinguish an invalid caller port from a target control denial.
        // Read-only diagnostics never change the target's code-signing state,
        // thread state or memory, and do not send it a passcode.
        task_t ownTask = MACH_PORT_NULL, readTask = MACH_PORT_NULL;
        kern_return_t selfError = task_for_pid(mach_task_self(), getpid(), &ownTask);
        if (MACH_PORT_VALID(ownTask)) mach_port_deallocate(mach_task_self(), ownTask);
        kern_return_t (*readForPID)(mach_port_t, int, mach_port_t *) = dlsym(RTLD_DEFAULT, "task_read_for_pid");
        char readResult[24] = "unavailable";
        if (readForPID) {
            kern_return_t readError = readForPID(mach_task_self(), pid, &readTask);
            snprintf(readResult, sizeof(readResult), "%d", readError);
            if (MACH_PORT_VALID(readTask)) mach_port_deallocate(mach_task_self(), readTask);
        }
        uint32_t flags = 0;
        int flagsError = csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof(flags));
        snprintf(s->error, sizeof(s->error), "task_for_pid(SpringBoard pid %d) failed: %s (Mach %d); self=%d, read=%s, csops=%d, caller_csflags=0x%08x; no code executed.",
            pid, mach_error_string(taskError), taskError, selfError, readResult, flagsError, flags);
        return false;
    }
    return prepareContext(s, checkOnly);
}

static bool invokeUnlock(FullUnlock *s, const uint8_t *passcode, size_t length) {
    uint64_t managerClass = klass(s, "SBLockScreenManager");
    if (!managerClass) return fail(s, "SBLockScreenManager was not found in SpringBoard.");
    uint64_t manager = message(s, managerClass, "sharedInstance", 0,0,0);
    if (!manager) return fail(s, "SBLockScreenManager sharedInstance returned nil.");
    uint64_t unlock = sel(s, "attemptUnlockWithPasscode:mesa:finishUIUnlock:completion:");
    uint64_t argumentCount = 4;
    if (!message(s, manager, "respondsToSelector:", unlock,0,0)) {
        unlock = sel(s, "attemptUnlockWithPasscode:");
        argumentCount = 1;
        if (!message(s, manager, "respondsToSelector:", unlock,0,0))
            return fail(s, "SpringBoard does not provide either of UnlockHelper's unlock methods.");
    }
    uint64_t signature = message(s, manager, "methodSignatureForSelector:", unlock,0,0);
    if (message(s, signature, "numberOfArguments",0,0,0) != argumentCount + 2)
        return fail(s, "The lock-screen unlock method signature differs on this iOS version.");
    uint64_t invocation = message(s, klass(s, "NSInvocation"), "invocationWithMethodSignature:", signature,0,0);
    message(s, invocation, "setTarget:", manager,0,0);
    message(s, invocation, "setSelector:", unlock,0,0);
    uint64_t secretBytes = data(s, passcode, length), secret = 0;
    s->secretBytes = secretBytes;
    s->secretLength = length;
    if (!secretBytes || !call(s, symbol(s, "CFStringCreateWithBytes"), &secret, 0,secretBytes,length,kCFStringEncodingUTF8,0,0,0,0) || !secret)
        return fail(s, "Cannot prepare the supplied passcode in memory.");
    s->secretObject = secret;
    uint64_t values[] = {secret,0,1,0}; // passcode, mesa=NO, finishUIUnlock=YES, completion=nil
    uint64_t arguments = data(s, values, sizeof(values));
    for (uint64_t i = 0; i < argumentCount; i++) message(s, invocation, "setArgument:atIndex:", arguments + i*8,i+2,0);
    message(s, invocation, "retainArguments",0,0,0);
    if (s->error[0] || !invocation) return false;
    s->attempted = true;
    // Exactly UnlockHelper's call, on SpringBoard's main thread. The temporary
    // pthread is an implementation detail inside this one icli invocation.
    message(s, invocation, "performSelectorOnMainThread:withObject:waitUntilDone:", sel(s, "invoke"),0,1);
    return !s->error[0];
}

static void cleanup(FullUnlock *s) {
    char original[sizeof(s->error)];
    strlcpy(original, s->error, sizeof(original));
    s->error[0] = 0;
    bool targetExited = portDead(s->task);
    if (targetExited) { s->workerCreated = false; s->uncertain = false; }
    // An unexpected exception could have interrupted a lock-holding routine.
    // Do not execute further target calls then, but overwriting the owned raw
    // request buffer does not execute code and must still erase those bytes.
    if (s->secretBytes && !targetExited) {
        uint8_t zeros[128] = {0};
        writeTask(s, s->secretBytes, zeros, s->secretLength);
    }
    if (s->worker && !s->uncertain && !targetExited) {
        uint64_t ignored;
        if (s->secretObject) call(s, symbol(s, "CFRelease"), &ignored, s->secretObject,0,0,0,0,0,0,0);
        if (s->pool) call(s, symbol(s, "objc_autoreleasePoolPop"), &ignored, s->pool,0,0,0,0,0,0,0);
        call(s, symbol(s, "pthread_detach"), &ignored, s->remotePthread,0,0,0,0,0,0,0);
        uint64_t remoteTask = 0;
        readTask(s, (uintptr_t)&mach_task_self_, &remoteTask, sizeof(mach_port_t));
        call(s, symbol(s, "mach_port_mod_refs"), &ignored, remoteTask,s->remoteWaitPort,MACH_PORT_RIGHT_RECEIVE,(uint64_t)-1,0,0,0,0);
        double deadline = monotonic() + 2;
        mach_port_type_t type;
        while (monotonic() < deadline && mach_port_type(mach_task_self(), s->worker, &type) == KERN_SUCCESS &&
            !(type & MACH_PORT_TYPE_DEAD_NAME)) sched_yield();
        if (mach_port_type(mach_task_self(), s->worker, &type) == KERN_SUCCESS && !(type & MACH_PORT_TYPE_DEAD_NAME)) {
            s->uncertain = true;
            fail(s, "The owned pthread exit was not confirmed; its target memory was retained for safety.");
        } else {
            s->workerCreated = false;
        }
    } else if (s->remoteWaitPort && !s->workerCreated && !s->uncertain && !targetExited) {
        uint64_t remoteTask = 0, ignored;
        readTask(s, (uintptr_t)&mach_task_self_, &remoteTask, sizeof(mach_port_t));
        call(s, symbol(s, "mach_port_mod_refs"), &ignored, remoteTask,s->remoteWaitPort,MACH_PORT_RIGHT_RECEIVE,(uint64_t)-1,0,0,0,0);
    }
    if (s->region && !s->workerCreated && !s->uncertain && !targetExited) {
        uint8_t zeros[4096] = {0};
        for (vm_address_t at = s->region + DATA_OFFSET; at < s->region + REGION_SIZE; at += sizeof(zeros))
            writeTask(s, at, zeros, sizeof(zeros));
        kern_return_t released = vm_deallocate(s->task, s->region, REGION_SIZE);
        if (released != KERN_SUCCESS) {
            s->uncertain = true;
            snprintf(s->error, sizeof(s->error), "Cannot release target request memory: %s (Mach %d).",
                mach_error_string(released), released);
        }
    }
    if (!s->error[0] && original[0]) strlcpy(s->error, original, sizeof(s->error));
    if (s->workerCreated || s->uncertain) {
        char summary[sizeof(s->error)];
        snprintf(summary, sizeof(summary), "%s Target cleanup was incomplete.", s->error);
        strlcpy(s->error, summary, sizeof(s->error));
    }
    if (s->worker) mach_port_deallocate(mach_task_self(), s->worker);
    if (s->mainThread) mach_port_deallocate(mach_task_self(), s->mainThread);
    if (s->exceptions) {
        union { mach_msg_header_t header; uint8_t bytes[16384]; } pending;
        while (mach_msg(&pending.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(pending),
                s->exceptions, 0, MACH_PORT_NULL) == KERN_SUCCESS) {
            bool ignored = false;
            if (!consumeNotification(&pending.header, MACH_PORT_NULL, &ignored)) mach_msg_destroy(&pending.header);
        }
        mach_port_mod_refs(mach_task_self(), s->exceptions, MACH_PORT_RIGHT_RECEIVE, -1);
        mach_port_deallocate(mach_task_self(), s->exceptions);
    }
    if (s->task) mach_port_deallocate(mach_task_self(), s->task);
}
#endif

bool icli_full_unlock_signals_begin(void) {
#if defined(__arm64__) && !TARGET_OS_TV
    if (ownsSignalGuard || pthread_mutex_trylock(&callLock)) return false;
    // Signal dispositions apply to the whole process. Blocking only this
    // thread lets a signal kill an unblocked Foundation/dispatch thread while
    // the target still depends on our exception reply channel.
    struct sigaction deferred = {.sa_handler = deferSignal};
    sigemptyset(&deferred.sa_mask);
    for (unsigned i = 0; i < 3; i++) sigaddset(&deferred.sa_mask, deferredSignals[i]);
    atomic_store_explicit(&pendingSignals, 0, memory_order_relaxed);
    for (unsigned i = 0; i < 3; i++) {
        if (sigaction(deferredSignals[i], &deferred, &previousSignalActions[i])) {
            for (unsigned restored = 0; restored < i; restored++) sigaction(deferredSignals[restored], &previousSignalActions[restored], NULL);
            unsigned pending = atomic_exchange_explicit(&pendingSignals, 0, memory_order_relaxed);
            pthread_mutex_unlock(&callLock);
            for (unsigned j = 0; j < 3; j++) if (pending & (1u << j)) raise(deferredSignals[j]);
            return false;
        }
    }
    ownsSignalGuard = true;
#endif
    return true;
}

bool icli_full_unlock_signals_end(void) {
#if defined(__arm64__) && !TARGET_OS_TV
    if (!ownsSignalGuard) return false;
    bool restored = true;
    for (unsigned i = 0; i < 3; i++) {
        if (sigaction(deferredSignals[i], &previousSignalActions[i], NULL)) restored = false;
    }
    unsigned pending = atomic_exchange_explicit(&pendingSignals, 0, memory_order_relaxed);
    ownsSignalGuard = false;
    pthread_mutex_unlock(&callLock);
    // The policy caller ends this scope only after ledger persistence and
    // wiping its input, so default termination cannot skip that bookkeeping.
    for (unsigned i = 0; i < 3; i++) if (pending & (1u << i)) raise(deferredSignals[i]);
    return restored;
#else
    return true;
#endif
}

// Reuse the temporary-thread transport for the probe's one-time dlopen.
// This entry point never invokes any lock-screen or passcode operations.
char *icli_probe_attach_json(int pid, const char *executable, const char *dylib, const char *socketPath) {
#if defined(__arm64__) && !TARGET_OS_TV
    if (geteuid() || pid <= 1 || pid == getpid() || !executable || !dylib || !socketPath)
        return icli_json(@{@"error": @"Probe attachment requires root and a running app."});
    if (!icli_full_unlock_signals_begin())
        return icli_json(@{@"error": @"Another remote call is already active."});
    FullUnlock s = {0};
    char path[4096] = {0}, actual[4096] = {0}, expected[4096] = {0};
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &s.task);
    if (kr != KERN_SUCCESS) {
        snprintf(s.error, sizeof(s.error), "Cannot control app pid %d: %s (Mach %d).", pid, mach_error_string(kr), kr);
    } else if (proc_pidpath(pid, path, sizeof(path)) <= 0 ||
               !realpath(path, actual) || !realpath(executable, expected) || strcmp(actual, expected)) {
        fail(&s, "The target executable changed; no agent was loaded.");
    } else if (prepareContext(&s, false)) {
        uint64_t handle = 0, entry = 0, result = 0;
        uint64_t library = text(&s, dylib);
        if (library && call(&s, symbol(&s, "dlopen"), &handle, library,RTLD_NOW,0,0,0,0,0,0) && !handle)
            fail(&s, "The app's loader refused the probe agent.");
        uint64_t name = text(&s, "icli_probe_agent_attach");
        if (handle && name && call(&s, symbol(&s, "dlsym"), &entry, handle,name,0,0,0,0,0,0) && !entry)
            fail(&s, "The loaded probe agent has no attach entry point; restart the app to update it.");
        // dlsym's function pointer is signed in the target process. rpc signs
        // thread-state PC itself; only its stripped address crosses that API.
        uint64_t socket = text(&s, socketPath);
        if (entry && socket && call(&s, strip((void *)entry), &result, socket,0,0,0,0,0,0,0) && result)
            snprintf(s.error, sizeof(s.error), "The probe agent could not start: %s (errno %llu).", strerror((int)result), result);
    }
    cleanup(&s);
    bool restored = icli_full_unlock_signals_end();
    if (!restored) fail(&s, "Cannot restore the caller's signal handlers.");
    return icli_json(s.error[0] ? @{@"error": @(s.error)} : @{@"ok": @YES, @"pid": @(pid)});
#else
    return icli_json(@{@"error": @"Attaching a probe requires an arm64 iPhone or iPad; use app launch --probe on this platform."});
#endif
}

char *icli_full_unlock_json(const uint8_t *passcode, size_t length, bool checkOnly) {
#if defined(__arm64__) && !TARGET_OS_TV
    if (!passcode || length < 1 || length > 128 || memchr(passcode, 0, length))
        return icli_json(@{@"attempted": @NO, @"confirmed": @NO, @"ready": @NO, @"detail": @"Invalid passcode length or embedded NUL."});
    if (!ownsSignalGuard) return icli_json(@{@"attempted": @NO, @"confirmed": @NO, @"ready": @NO,
        @"detail": @"Full unlock requires the caller's protected signal scope."});
    FullUnlock s = {0};
    bool ready = setup(&s, checkOnly), confirmed = false;
    int lockToken = -1, blankToken = -1;
    if (ready && !checkOnly) {
        dispatch_semaphore_t changed = dispatch_semaphore_create(0);
        dispatch_queue_t queue = dispatch_queue_create("icli.unlock.confirm", DISPATCH_QUEUE_SERIAL);
        void (^signal)(void) = ^{
            IcliLockStatus state = icli_lock_status();
            if (!state.locked && !state.screen_off) dispatch_semaphore_signal(changed);
        };
        if (notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, queue, ^(int t) { signal(); }) ||
            notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &blankToken, queue, ^(int t) { signal(); })) {
            fail(&s, "Cannot observe lock-screen completion.");
        } else if (!icli_wake()) {
            fail(&s, "Cannot wake the phone.");
        } else if (invokeUnlock(&s, passcode, length)) {
            signal();
            dispatch_semaphore_wait(changed, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
            IcliLockStatus state = icli_lock_status();
            confirmed = !state.locked && !state.screen_off;
            if (!confirmed) fail(&s, "SpringBoard did not confirm lock-screen dismissal; no request was retried.");
        }
    }
    if (lockToken >= 0) notify_cancel(lockToken);
    if (blankToken >= 0) notify_cancel(blankToken);
    cleanup(&s);
    NSDictionary *report = @{@"attempted": @(s.attempted), @"confirmed": @(confirmed && !s.error[0]),
        @"ready": @(ready), @"detail": s.error[0] ? @(s.error) : (checkOnly ? @"Read-only preflight passed; no code was executed and no passcode was sent." : @"UnlockHelper's method executed directly in SpringBoard.")};
    return icli_json(report);
#else
    return icli_json(@{@"attempted": @NO, @"confirmed": @NO, @"ready": @NO, @"detail": @"Full unlock requires an arm64 iPhone or iPad."});
#endif
}
