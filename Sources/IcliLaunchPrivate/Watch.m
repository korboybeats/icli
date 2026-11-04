#import "IcliLaunchPrivate.h"
#import <dispatch/dispatch.h>
#import <notify.h>
#import <stdlib.h>
#import <pthread.h>
#import <time.h>

// Counts Darwin notifications while a wait runs, for waits that used to poll.
// On iOS 17.1.1 com.apple.springboard.lockstate and hasBlankedScreen arrive
// 1.5-4 ms before a 5 ms poll of their state sees the change.
struct IcliWatch {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    uint64_t count;
    int tokens[8];
    int token_count;
};

static void watchBump(IcliWatch *watch) {
    pthread_mutex_lock(&watch->lock);
    watch->count++;
    pthread_cond_broadcast(&watch->changed);
    pthread_mutex_unlock(&watch->lock);
}

static IcliWatch *watchCreate(void) {
    IcliWatch *watch = calloc(1, sizeof(*watch));
    if (!watch) return NULL;
    pthread_mutex_init(&watch->lock, NULL);
    pthread_cond_init(&watch->changed, NULL);
    return watch;
}

static dispatch_queue_t watchQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("icli.watch", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

IcliWatch *icli_watch_notify(const char *const *names, int count) {
    if (count < 1 || count > 8) return NULL;
    IcliWatch *watch = watchCreate();
    if (!watch) return NULL;
    for (int i = 0; i < count; i++) {
        int token = 0;
        if (notify_register_dispatch(names[i], &token, watchQueue(), ^(int t) { watchBump(watch); }) != NOTIFY_STATUS_OK) {
            icli_watch_end(watch);
            return NULL;
        }
        watch->tokens[watch->token_count++] = token;
    }
    return watch;
}

uint64_t icli_watch_count(IcliWatch *watch) {
    pthread_mutex_lock(&watch->lock);
    uint64_t count = watch->count;
    pthread_mutex_unlock(&watch->lock);
    return count;
}

uint64_t icli_watch_wait(IcliWatch *watch, uint64_t seen, double timeout) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    double seconds = timeout > 0 ? timeout : 0;
    deadline.tv_sec += (time_t)seconds;
    deadline.tv_nsec += (long)((seconds - (double)(time_t)seconds) * 1e9);
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&watch->lock);
    while (watch->count == seen && pthread_cond_timedwait(&watch->changed, &watch->lock, &deadline) == 0) {}
    uint64_t count = watch->count;
    pthread_mutex_unlock(&watch->lock);
    return count;
}

// A handler already queued can still run after notify_cancel; the queue is
// serial, so an empty block run after the cancel waits that one out.
void icli_watch_end(IcliWatch *watch) {
    if (!watch) return;
    for (int i = 0; i < watch->token_count; i++) notify_cancel(watch->tokens[i]);
    dispatch_sync(watchQueue(), ^{});
    pthread_cond_destroy(&watch->changed);
    pthread_mutex_destroy(&watch->lock);
    free(watch);
}
