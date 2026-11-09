//
//  msgSend_hook.c
//  libobjsee
//
//  Created by Ethan Arbuckle on 11/30/24.
//

#include <objc/runtime.h>
#include <mach/mach.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <sched.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif
#include "selector_deny_list.h"
#include "class_name_cache.h"
#include "substrate_apis.h"
#include "event_handler.h"
#include "objc-internal.h"
#include "arg_capture.h"
#include "tracer.h"
#include "rebind.h"
#include "tsd.h"

#define LIKELY(x)   __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

extern void new_objc_msgSend(void);

static _Atomic(tracer_t *) g_tracer_ctx = NULL;
static _Atomic(uint32_t) g_tracer_readers = 0;
static _Atomic(uint64_t) g_message_interception_calls = 0;
static _Thread_local bool g_message_interception_thread_suppressed = false;

enum {
    OBJSEE_INTERCEPT_DIAG_TRACER_NULL = 0,
    OBJSEE_INTERCEPT_DIAG_TRACER_CHANGED,
    OBJSEE_INTERCEPT_DIAG_CONTEXT_NULL,
    OBJSEE_INTERCEPT_DIAG_STACK_DEPTH,
    OBJSEE_INTERCEPT_DIAG_IMPLAUSIBLE_SELF,
    OBJSEE_INTERCEPT_DIAG_IMPLAUSIBLE_CMD,
    OBJSEE_INTERCEPT_DIAG_SELECTOR_NULL,
    OBJSEE_INTERCEPT_DIAG_SELECTOR_DENIED,
    OBJSEE_INTERCEPT_DIAG_INVALID_CLASS,
    OBJSEE_INTERCEPT_DIAG_UNREALIZED_CLASS,
    OBJSEE_INTERCEPT_DIAG_POLICY_REJECTED,
    OBJSEE_INTERCEPT_DIAG_POLICY_ACCEPTED,
    OBJSEE_INTERCEPT_DIAG_COUNT,
};

static _Atomic(uint64_t) g_message_interception_diagnostics[OBJSEE_INTERCEPT_DIAG_COUNT] = {0};

void *g_original_objc_msgSend = NULL;
static int g_objc_msgSend_hooked = 0;
static int g_objc_msgSend_rebound = 0;

uint64_t objsee_message_interception_count(void) {
    return atomic_load_explicit(&g_message_interception_calls, memory_order_relaxed);
}

bool objsee_message_interception_set_thread_suppressed(bool suppressed) {
    bool previous = g_message_interception_thread_suppressed;
    g_message_interception_thread_suppressed = suppressed;
    return previous;
}

uint64_t objsee_message_interception_diagnostic_count(uint32_t index) {
    if (index >= OBJSEE_INTERCEPT_DIAG_COUNT) {
        return 0;
    }
    return atomic_load_explicit(&g_message_interception_diagnostics[index], memory_order_relaxed);
}

#define INTERCEPT_DIAG_INC(index) \
    atomic_fetch_add_explicit(&g_message_interception_diagnostics[(index)], 1, memory_order_relaxed)

// dlsym() returns authenticated function pointers on arm64e. ObjSee also uses
// these values as raw code addresses (for instruction snapshots/restores), and
// the assembly trampoline branches through g_original_objc_msgSend with a plain
// br/blr. Strip pointer-authentication bits before either use.
static inline void *canonical_code_pointer(void *pointer) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(pointer, ptrauth_key_function_pointer);
#else
    return pointer;
#endif
}

void clear_message_interception_context(tracer_t *tracer) {
    tracer_t *expected = tracer;
    if (atomic_compare_exchange_strong_explicit(&g_tracer_ctx,
                                                &expected,
                                                NULL,
                                                memory_order_acq_rel,
                                                memory_order_acquire)) {
        // A callback may have loaded the old tracer immediately before the
        // exchange. Wait until every callback that validated that pointer has
        // finished before the caller is allowed to destroy the tracer.
        while (atomic_load_explicit(&g_tracer_readers, memory_order_acquire) != 0) {
            sched_yield();
        }
    }
}

__attribute__((aligned(16), always_inline, hot))
static inline struct tracer_thread_context_t *get_thread_context(void) {
    struct tracer_thread_context_t *ctx = (struct tracer_thread_context_t *)_get_tracer_thread_context();
    if (UNLIKELY(ctx == NULL)) {
        tracer_t *tracer = atomic_load_explicit(&g_tracer_ctx, memory_order_acquire);
        if (UNLIKELY(tracer == NULL)) {
            return NULL;
        }

        ctx = (struct tracer_thread_context_t *)calloc(1, sizeof(struct tracer_thread_context_t));
        if (UNLIKELY(ctx == NULL)) {
            tracer_set_error(tracer, "get_thread_context: Failed to allocate thread context");
            return NULL;
        }
        
        ctx->stack_depth = 0;
        ctx->trace_depth = 0;
        ctx->capture_arguments = tracer->config.format.args != TRACER_ARG_FORMAT_NONE;
        ctx->stack_base = NULL;
        if (ctx->capture_arguments) {
            ctx->stack_base = pthread_get_stackaddr_np(pthread_self());
        }
        
        uint64_t thread_id = 0;
        pthread_threadid_np(pthread_self(), &thread_id);
        ctx->thread_id = (uint16_t)(thread_id ^ (thread_id >> 32));
        
        set_tracer_thread_context((void *)ctx);
    }
    
    return ctx;
}

__attribute__((always_inline))
static inline bool selector_has_arguments(const char *sel_name) {
    while (*sel_name) {
        if (*sel_name++ == ':') {
            return true;
        }
    }
    return false;
}

static void free_event_arguments(tracer_event_t *event) {
    if (LIKELY(event->method_signature != NULL)) {
        free((void *)event->method_signature);
        event->method_signature = NULL;
    }
    
    if (LIKELY(event->arguments != NULL)) {
        for (size_t i = 0; i < event->argument_count; i++) {
            tracer_argument_t *arg = &event->arguments[i];
            if (LIKELY(arg->type_encoding != NULL)) {
                free((void *)arg->type_encoding);
                arg->type_encoding = NULL;
            }
            
            if (LIKELY(arg->description != NULL)) {
                free((void *)arg->description);
                arg->description = NULL;
            }
            
            if (UNLIKELY(arg->block_signature != NULL)) {
                free((void *)arg->block_signature);
                arg->block_signature = NULL;
            }
            
            if (LIKELY(arg->objc_class_name != NULL)) {
                free((void *)arg->objc_class_name);
                arg->objc_class_name = NULL;
            }
        }
        
        free(event->arguments);
        event->arguments = NULL;
    }
    
    event->argument_count = 0;
    event->formatted_output = NULL;
    event->class_name = NULL;
    event->method_name = NULL;
    event->image_path = NULL;
    event->thread_id = 0;
    event->trace_depth = 0;
    event->real_depth = 0;
    event->is_class_method = false;
}

static void populate_event_caller_info(struct tracer_thread_context_t *ctx, int stack_depth_on_entry, tracer_event_t *event) {
    if (stack_depth_on_entry > 0) {
        // If current depth is > 0, the caller is the previous frame
        struct tracer_thread_context_frame_t *caller_frame = &ctx->frames[stack_depth_on_entry - 1];
        event->caller.class_name = caller_frame->self_class_name;
        event->caller.method_name = caller_frame->selector_name;
    }
    else {
        // This is the first captured call in this thread.
        // Use backtrace() and dladdr() to get caller info
        const char *bt_frames[5];
        int bt_size = backtrace((void **)bt_frames, 5);
        
        if (bt_size >= 3) {
            Dl_info info;
            if (dladdr(bt_frames[2], &info) != 0) {
                if (info.dli_sname != NULL) {
                    event->caller.class_name = info.dli_sname;
                }
                else {
                    // Fallback to file offset
                    static __thread char addr_buf[32];
                    uintptr_t offset = (uintptr_t)bt_frames[2] - (uintptr_t)info.dli_fbase;
                    snprintf(addr_buf, sizeof(addr_buf), "0x%lx", offset);
                    event->caller.class_name = addr_buf;
                }
                
                if (info.dli_fname != NULL) {
                    event->caller.method_name = info.dli_fname;
                }
            }
        }
    }
}

__attribute__((aligned(16), always_inline, hot))
bool pre_objc_msgSend_callback(__unsafe_unretained id self, SEL _cmd, uintptr_t lr, void *stack_ptr) {
    atomic_fetch_add_explicit(&g_message_interception_calls, 1, memory_order_relaxed);

    if (UNLIKELY(g_message_interception_thread_suppressed)) {
        return false;
    }

    tracer_t *tracer = atomic_load_explicit(&g_tracer_ctx, memory_order_acquire);
    if (LIKELY(tracer == NULL)) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_TRACER_NULL);
        return false;
    }

    atomic_fetch_add_explicit(&g_tracer_readers, 1, memory_order_acquire);
    if (UNLIKELY(atomic_load_explicit(&g_tracer_ctx, memory_order_acquire) != tracer)) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_TRACER_CHANGED);
        atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
        return false;
    }

    struct tracer_thread_context_t *ctx = get_thread_context();
    if (UNLIKELY(ctx == NULL)) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_CONTEXT_NULL);
        atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
        return false;
    }

    ctx->capture_arguments = tracer->config.format.args != TRACER_ARG_FORMAT_NONE;
    if (ctx->capture_arguments && ctx->stack_base == NULL) {
        ctx->stack_base = pthread_get_stackaddr_np(pthread_self());
    }
    
    int stack_depth_on_entry = ctx->stack_depth;
    if (UNLIKELY(stack_depth_on_entry >= INITIAL_STACK_FRAMES)) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_STACK_DEPTH);
        tracer_set_error(tracer, "stack depth exceeded limit");
        atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
        return false;
    }
    
    if (!PTR_PLAUSIBLE(self)) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_IMPLAUSIBLE_SELF);
        atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
        return false;
    }

    if (!PTR_PLAUSIBLE(_cmd)) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_IMPLAUSIBLE_CMD);
        atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
        return false;
    }
    
    const char *selector_name = sel_getName(_cmd);
    if (selector_name == NULL) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_SELECTOR_NULL);
        atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
        return false;
    }

    if (should_skip_selector_name(selector_name)) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_SELECTOR_DENIED);
        atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
        return false;
    }

    Class self_class = object_getClass(self);
    if (UNLIKELY(!PTR_PLAUSIBLE(self_class))) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_INVALID_CLASS);
        atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
        return false;
    }

    if (UNLIKELY(!is_class_realized(self_class))) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_UNREALIZED_CLASS);
        atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
        return false;
    }

    struct tracer_thread_context_frame_t *frame = &ctx->frames[stack_depth_on_entry];
    frame->_cmd = _cmd;
    frame->self_class = self_class;
    frame->selector_name = selector_name;

    // Resolve and cache class info
    // These details will be needed by filters later on and could have interest by an API user.
    if (UNLIKELY(ctx->last_class_cache.cls == self_class)) {
        frame->self_class_name = ctx->last_class_cache.name;
        frame->selector_is_class_method = ctx->last_class_cache.is_meta;
    }
    else {
        const char *class_name = class_name_cache_get(self_class);
        frame->self_class_name = class_name;

        bool class_is_meta = class_isMetaClass(self_class);
        frame->selector_is_class_method = class_is_meta;
        
        ctx->last_class_cache.cls = self_class;
        ctx->last_class_cache.name = class_name;
        ctx->last_class_cache.is_meta = class_is_meta;
    }
    
    bool should_trace = tracer_evaluate_trace_policy(tracer, frame);
    bool tracking_callers = tracer->config.format.include_caller_info;
    if (!should_trace) {
        INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_POLICY_REJECTED);
        // When caller-tracking is enabled, all frames need to be recorded regardless of whether they are traced
        if (tracking_callers) {
            frame->lr = lr;
            ctx->stack_depth++;

            // true will make the trampoline call post_objc_msgSend_callback() (stack depth decrement)
            atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
            return true;
        }
        
        // Not tracing this call, skip the stack decrement callback
        atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
        return false;
    }

    INTERCEPT_DIAG_INC(OBJSEE_INTERCEPT_DIAG_POLICY_ACCEPTED);

    tracer_event_t event = {
        .class_name = frame->self_class_name,
        .method_name = selector_name,
        .is_class_method = frame->selector_is_class_method,
        .image_path = frame->image_path,
        .thread_id = ctx->thread_id,
        .trace_depth = ctx->trace_depth,
        .real_depth = ctx->stack_depth,
        .arguments = NULL,
        .argument_count = 0,
        .method_signature = NULL,
    };
    
    if (tracking_callers) {
        populate_event_caller_info(ctx, stack_depth_on_entry, &event);
    }
    
    bool should_capture_args = ctx->capture_arguments && ctx->stack_depth <= 32 && selector_has_arguments(selector_name);
    if (LIKELY(should_capture_args)) {
        // Make a copy of the stack so that memory doesn't change out from under us while interpreting argument values
        char local_stack_copy_buffer[1024];
        size_t stack_buffer_size = sizeof(local_stack_copy_buffer);
        size_t bytes_to_copy = stack_buffer_size;
        
        uintptr_t current_sp = (uintptr_t)stack_ptr;
        uintptr_t stack_base = (uintptr_t)ctx->stack_base;
        if (LIKELY(current_sp < stack_base)) {
            // Don't read past the end of the stack (primarily applicable to armv7)
            size_t available_bytes = stack_base - current_sp;
            if (UNLIKELY(bytes_to_copy > available_bytes)) {
                bytes_to_copy = available_bytes;
            }
        }
        
        if (LIKELY(bytes_to_copy > 0)) {
            memcpy(local_stack_copy_buffer, stack_ptr, bytes_to_copy);
        }
        
        if (UNLIKELY(bytes_to_copy < stack_buffer_size)) {
            memset(local_stack_copy_buffer + bytes_to_copy, 0, stack_buffer_size - bytes_to_copy);
        }

        capture_arguments(tracer, frame, local_stack_copy_buffer, &event);
    }
    
    tracer_handle_event(tracer, &event);
    
    if (LIKELY(should_capture_args)) {
        if (LIKELY(event.arguments != NULL)) {
            free_event_arguments(&event);
        }
    }
    
    ctx->trace_depth++;
    ctx->stack_depth++;
    frame->traced = true;
    frame->lr = lr;
    
    atomic_fetch_sub_explicit(&g_tracer_readers, 1, memory_order_release);
    return true;
}

__attribute__((aligned(16), always_inline, hot))
uintptr_t post_objc_msgSend_callback(void) {
    struct tracer_thread_context_t *ctx = get_thread_context();
    size_t stack_depth_on_entry = ctx->stack_depth - 1;
    
    ctx->stack_depth -= 1;
    if (LIKELY(ctx->trace_depth > 0)) {
        ctx->trace_depth -= 1;
    }
    
    struct tracer_thread_context_frame_t *frame = &ctx->frames[stack_depth_on_entry];
    return frame->lr;
}

tracer_result_t init_message_interception(tracer_t *tracer) {
    if (tracer == NULL) {
        tracer_set_error(g_tracer_ctx, "tracer is NULL");
        return TRACER_ERROR_INVALID_ARGUMENT;
    }
    
    tracer_t *existing_tracer = atomic_load_explicit(&g_tracer_ctx, memory_order_acquire);
    if (existing_tracer != NULL) {
        if (existing_tracer == tracer) {
            // Cannot initialize the same tracer twice (without cleaning up first)
            tracer_set_error(existing_tracer, "tracer_cleanup() must be called before reinitializing the same tracer");
            return TRACER_ERROR_ALREADY_INITIALIZED;
        }
        
        if (existing_tracer->running) {
            // A different tracer is already running
            tracer_set_error(existing_tracer, "A tracer is already running");
            return TRACER_ERROR_ALREADY_INITIALIZED;
        }
        
        // Tear down the previous tracer
        if (tracer_cleanup(existing_tracer) != TRACER_SUCCESS) {
            tracer_set_error(existing_tracer, "Failed to clean up previous tracer");
            return TRACER_ERROR_INITIALIZATION;
        }
        
        tracer_set_error(tracer, "Previous tracer cleaned up");
    }

    atomic_store_explicit(&g_tracer_ctx, tracer, memory_order_release);
    
    if (tracer->config.use_symbol_rebinding) {
        // Install import interposition only once. Trace stop/start only swaps
        // the published tracer context; the process-lifetime rebinding stays.
        if (g_objc_msgSend_rebound == 0) {
            g_original_objc_msgSend = canonical_code_pointer(dlsym(RTLD_DEFAULT, "objc_msgSend"));
            struct symbol_rebinding_diagnostics_t diagnostics = {0};
            struct symbol_rebinding_t *rebinding = hook_function("objc_msgSend", new_objc_msgSend, &diagnostics);
            if (rebinding == NULL) {
                clear_message_interception_context(tracer);
                tracer_set_error(tracer,
                                 "Failed to hook objc_msgSend: scanned=%u eligible=%u matches=%u protect_failures=%u kern=%d",
                                 diagnostics.images_scanned,
                                 diagnostics.images_eligible,
                                 diagnostics.symbol_matches,
                                 diagnostics.protection_failures,
                                 diagnostics.last_error);
                return TRACER_ERROR_INITIALIZATION;
            }

            free(rebinding);
            g_objc_msgSend_rebound = 1;
        }
    }
    else {
        void *objc_msgSend = canonical_code_pointer(dlsym(RTLD_DEFAULT, "objc_msgSend"));
        if (g_objc_msgSend_hooked == 0) {
            // Hook objc_msgSend using MSHookFunction
            kern_return_t ret = objsee_MSHookFunction(objc_msgSend, new_objc_msgSend, (void **)&g_original_objc_msgSend);
            if (ret != KERN_SUCCESS) {
                clear_message_interception_context(tracer);
                tracer_set_error(tracer, "Failed to hook objc_msgSend using MSHookFunction");
                return TRACER_ERROR_INITIALIZATION;
            }
            g_original_objc_msgSend = canonical_code_pointer(g_original_objc_msgSend);
            g_objc_msgSend_hooked = 1;
        }
    }

    return TRACER_SUCCESS;
}

tracer_result_t disable_message_interception(tracer_t *tracer) {
    if (tracer == NULL || atomic_load_explicit(&g_tracer_ctx, memory_order_acquire) != tracer) {
        tracer_set_error(tracer, "disable_message_interception: tracer not active");
        return TRACER_ERROR_INVALID_ARGUMENT;
    }
        
    // Keep either interception strategy installed for the process lifetime.
    // Rewriting libobjc text or rebinding every image back and forth during
    // trace.stop is unsafe on modern arm64e mappings and is unnecessary: with
    // no published tracer context new_objc_msgSend takes the fast path and
    // immediately forwards to the preserved original objc_msgSend.

    clear_message_interception_context(tracer);
    
    return TRACER_SUCCESS;
}
