// Records this process's unified log for logs.messages, in place of FLEX's
// FLEXOSLogController, with the same four selectors the original handler calls.
//
// FLEX reads os_activity_stream entries with a layout older than iOS 17. On
// 17.1.1 an entry has 8 more bytes after proc_id, so its log message starts at
// entry+56, not +48; at +48 os_log_copy_formatted_message answers "<compose
// failure [corrupt log]>" for every message and the dates are garbage
// (measured with a dump injected into the ContainerFixture). The offset is
// chosen per entry by the one whose wall-clock time is near now, not by iOS
// version, since only 17.1.1 was measured. A FLEX tweak such as FLEXing loads
// its own FLEX into every app, so this has to live in the agent, not in FLEX.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <malloc/malloc.h>
#import <sys/time.h>
#import <unistd.h>

typedef void *ICLIActivityStream;
typedef bool (^ICLIActivityEntryBlock)(void *entry, int error);

enum {
    ICLIStreamProcessOnly = 0x1, // OS_ACTIVITY_STREAM_PROCESS_ONLY
    ICLIStreamHistorical = 0x8,  // OS_ACTIVITY_STREAM_HISTORICAL, as FLEX asks
    ICLIEntryLogMessage = 0x400,
    ICLIEntryLegacyLogMessage = 0x480,
};
// Messages kept, oldest dropped first.
static const NSUInteger ICLIOSLogLimit = 10000;

@interface ICLIOSLogController : NSObject
@property (nonatomic) BOOL persistent;
@property (nonatomic, readonly) NSMutableArray *messages;
+ (instancetype)sharedLogController;
- (BOOL)startMonitoring;
@end

@implementation ICLIOSLogController {
    ICLIActivityStream _stream;
}

+ (instancetype)sharedLogController {
    static ICLIOSLogController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) _messages = [NSMutableArray array];
    return self;
}

// The log message inside an entry: the candidate whose tv_gmt (40 bytes in)
// is within a day of now. NULL when neither is, so nothing corrupt is kept.
static char *ICLILogMessage(void *entry, time_t now) {
    for (size_t offset = 56; offset >= 48; offset -= 8) {
        char *message = (char *)entry + offset;
        time_t seconds = ((struct timeval *)(message + 40))->tv_sec;
        if (seconds > now - 86400 && seconds < now + 86400) return message;
    }
    return NULL;
}

- (BOOL)startMonitoring {
    if (_stream) return YES;
    void *handle = dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW);
    ICLIActivityStream (*forPID)(pid_t, uint32_t, ICLIActivityEntryBlock) = handle ? dlsym(handle, "os_activity_stream_for_pid") : NULL;
    void (*resume)(ICLIActivityStream) = handle ? dlsym(handle, "os_activity_stream_resume") : NULL;
    char *(*format)(void *) = handle ? dlsym(handle, "os_log_copy_formatted_message") : NULL;
    Class messageClass = NSClassFromString(@"FLEXSystemLogMessage");
    SEL make = NSSelectorFromString(@"logMessageFromDate:text:");
    if (!forPID || !resume || !format || ![messageClass respondsToSelector:make]) return NO;

    _stream = forPID(getpid(), ICLIStreamProcessOnly | ICLIStreamHistorical, ^bool(void *entry, int error) {
        if (error || !entry) return true;
        uint32_t type = *(uint32_t *)entry;
        if (type != ICLIEntryLogMessage && type != ICLIEntryLegacyLogMessage) return true;
        struct timeval now;
        gettimeofday(&now, NULL);
        char *message = ICLILogMessage(entry, now.tv_sec);
        if (!message) return true;
        struct timeval gmt = *(struct timeval *)(message + 40);
        char *text = format(message);
        NSString *string = text ? [[NSString alloc] initWithBytes:text length:strlen(text) encoding:NSUTF8StringEncoding] : nil;
        // Freed only when it came from malloc, which a "copy" result should.
        if (text && malloc_size(text)) free(text);
        if (!string) string = text ? @"<message not UTF-8>" : @"";
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:gmt.tv_sec + gmt.tv_usec / 1e6];
        // The original handler snapshots messages on the main queue.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.persistent) return;
            id logMessage = ((id (*)(id, SEL, id, id))objc_msgSend)(messageClass, make, date, string);
            if (!logMessage) return;
            [self.messages addObject:logMessage];
            if (self.messages.count > ICLIOSLogLimit) [self.messages removeObjectAtIndex:0];
        });
        return true;
    });
    if (!_stream) return NO;
    resume(_stream);
    return YES;
}

@end
