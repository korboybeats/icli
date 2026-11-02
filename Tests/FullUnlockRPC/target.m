#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <signal.h>
#import <unistd.h>
static NSString *resultPath;
static unsigned callCount;
static const char *failureMode;
static int gate[2];
static void releaseGate(int number) { char byte = 1; (void)write(gate[1], &byte, 1); }
__attribute__((noinline, used, visibility("default")))
uint64_t icli_fixture_read_byte(uint64_t address) { return *(volatile uint8_t *)(uintptr_t)address; }
@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
#if ICLI_RPC_SIMPLE_UNLOCK
- (void)attemptUnlockWithPasscode:(NSString *)code;
#else
- (void)attemptUnlockWithPasscode:(NSString *)code mesa:(BOOL)mesa finishUIUnlock:(BOOL)finish completion:(id)completion;
#endif
@end
@implementation SBLockScreenManager
+ (instancetype)sharedInstance {
    static id manager; static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [self new]; });
    return manager;
}
#if ICLI_RPC_SIMPLE_UNLOCK
- (void)attemptUnlockWithPasscode:(NSString *)code {
    BOOL argumentsCorrect = YES;
#else
- (void)attemptUnlockWithPasscode:(NSString *)code mesa:(BOOL)mesa finishUIUnlock:(BOOL)finish completion:(id)completion {
    BOOL argumentsCorrect = !mesa && finish && !completion;
#endif
    // Fixture only. Never print or persist the supplied string.
    BOOL correct = [NSThread isMainThread] && [code isEqualToString:@"fixture-passcode"] && argumentsCorrect;
    if (failureMode && !strcmp(failureMode, "exit")) _exit(0);
    if (failureMode && !strcmp(failureMode, "signal")) {
        (void)write(STDOUT_FILENO, "GATE_WAITING\n", 13);
        char byte;
        while (read(gate[0], &byte, 1) < 0 && errno == EINTR) {}
    }
    callCount++;
    [[NSString stringWithFormat:@"%@ exact selector, arguments and main thread; count=%u", correct ? @"PASS" : @"FAIL", callCount]
        writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
@end
static void keepAlive(void *info) {}
static void wakeTimer(CFRunLoopTimerRef timer, void *info) {}
int main(int argc, char **argv) {
    @autoreleasepool {
        resultPath = @(argv[1]);
        failureMode = argc > 2 ? argv[2] : NULL;
        if (pipe(gate)) return 2;
        struct sigaction release = {.sa_handler = releaseGate};
        sigemptyset(&release.sa_mask);
        if (sigaction(SIGUSR1, &release, NULL)) return 2;
        CFRunLoopSourceContext context = {.perform = keepAlive};
        CFRunLoopSourceRef source = CFRunLoopSourceCreate(NULL, 0, &context);
        CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopDefaultMode);
        // Exercise receive restoration while the main run loop receives work,
        // rather than testing only a permanently idle target.
#if !ICLI_RPC_QUIET
        CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 0.001, 0, 0, wakeTimer, NULL);
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopDefaultMode);
#endif
        dispatch_async(dispatch_get_main_queue(), ^{ puts("READY"); fflush(stdout); });
        CFRunLoopRun();
#if !ICLI_RPC_QUIET
        CFRelease(timer);
#endif
        CFRelease(source);
    }
    return 0;
}
