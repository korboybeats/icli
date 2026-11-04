#import "IcliPrivate.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <pthread.h>
#import <time.h>

// Frames the display shows, so a wait looks again only when the screen changed.
// IOMobileFramebuffer's CRC notification arrives once per frame on screen and
// never while the screen holds still: on iOS 17.1.1 (A17 Pro) a swipe gave 150
// callbacks for the render server's 150 frames, idle seconds gave none, and an
// AX query or a screenshot draws no frame of its own. Its VSync notification
// never fired for this second client, and accessibility notifications skip
// plain view changes (UIKit's setHidden: posts none), so neither can drive a wait.
//
// The notification stays off between waits: icli_frames_begin turns it on for
// the first waiter and icli_frames_end off after the last. One thread, started
// on the first wait, receives the frames; it sleeps in mach_msg in between.
typedef void *IcliFramebuffer;
static IcliFramebuffer framebuffer;
static int (*enableCRC)(IcliFramebuffer, void *, void *);
static int (*disableCRC)(IcliFramebuffer);
static pthread_mutex_t frameLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t frameArrived = PTHREAD_COND_INITIALIZER;
static uint64_t frameCount;
static int frameWatchers;

static void frameShown(IcliFramebuffer fb, uint32_t frame, uint32_t crc0, uint32_t crc1, void *refcon) {
    pthread_mutex_lock(&frameLock);
    frameCount++;
    pthread_cond_broadcast(&frameArrived);
    pthread_mutex_unlock(&frameLock);
}

static void *receiveFrames(void *source) {
    CFRunLoopAddSource(CFRunLoopGetCurrent(), (CFRunLoopSourceRef)source, kCFRunLoopDefaultMode);
    for (;;) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1e10, false);
    return NULL;
}

static bool prepareFrames(void) {
    static bool ready;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *iomfb = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW);
        if (!iomfb) return;
        int (*mainDisplay)(IcliFramebuffer *) = dlsym(iomfb, "IOMobileFramebufferGetMainDisplay");
        CFRunLoopSourceRef (*crcSource)(IcliFramebuffer) = dlsym(iomfb, "IOMobileFramebufferGetCRCRunLoopSource");
        enableCRC = dlsym(iomfb, "IOMobileFramebufferEnableCRCNotifications");
        disableCRC = dlsym(iomfb, "IOMobileFramebufferDisableCRCNotifications");
        if (!mainDisplay || !crcSource || !enableCRC || !disableCRC) return;
        if (mainDisplay(&framebuffer) != 0 || !framebuffer) return;
        CFRunLoopSourceRef source = crcSource(framebuffer);
        if (!source) return;
        pthread_t thread;
        if (pthread_create(&thread, NULL, receiveFrames, (void *)source) != 0) return;
        pthread_detach(thread);
        ready = true;
    });
    return ready;
}

bool icli_frames_begin(void) {
    if (!prepareFrames()) return false;
    pthread_mutex_lock(&frameLock);
    bool on = frameWatchers > 0 || enableCRC(framebuffer, frameShown, NULL) == 0;
    if (on) frameWatchers++;
    pthread_mutex_unlock(&frameLock);
    return on;
}

void icli_frames_end(void) {
    pthread_mutex_lock(&frameLock);
    if (frameWatchers > 0 && --frameWatchers == 0) disableCRC(framebuffer);
    pthread_mutex_unlock(&frameLock);
}

uint64_t icli_frames_count(void) {
    pthread_mutex_lock(&frameLock);
    uint64_t count = frameCount;
    pthread_mutex_unlock(&frameLock);
    return count;
}

uint64_t icli_frames_wait(uint64_t seen, double timeout) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    double seconds = timeout > 0 ? timeout : 0;
    deadline.tv_sec += (time_t)seconds;
    deadline.tv_nsec += (long)((seconds - (double)(time_t)seconds) * 1e9);
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&frameLock);
    while (frameCount == seen && pthread_cond_timedwait(&frameArrived, &frameLock, &deadline) == 0) {}
    uint64_t count = frameCount;
    pthread_mutex_unlock(&frameLock);
    return count;
}
