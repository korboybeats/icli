#include "AtomicCompat.h"
#include <stdatomic.h>

intptr_t echo_atomicLoadIntSeqCst(const intptr_t *ptr) {
    return atomic_load_explicit((const _Atomic(intptr_t) *)ptr, memory_order_seq_cst);
}

intptr_t echo_atomicLoadIntRelaxed(const intptr_t *ptr) {
    return atomic_load_explicit((const _Atomic(intptr_t) *)ptr, memory_order_relaxed);
}

void echo_atomicStoreIntRelease(intptr_t *ptr, intptr_t value) {
    atomic_store_explicit((_Atomic(intptr_t) *)ptr, value, memory_order_release);
}
