#ifndef ECHO_ATOMIC_COMPAT_H
#define ECHO_ATOMIC_COMPAT_H

#include <stdint.h>

intptr_t echo_atomicLoadIntSeqCst(const intptr_t *ptr);
intptr_t echo_atomicLoadIntRelaxed(const intptr_t *ptr);
void echo_atomicStoreIntRelease(intptr_t *ptr, intptr_t value);

#endif /* ECHO_ATOMIC_COMPAT_H */
