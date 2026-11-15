// Records this process's unified log for logs.messages, in place of FLEX's
// FLEXOSLogController, with the same four selectors the original handler calls.
//
// LoggingSupport's entry decoder uses log_message at +48 on iOS 14-16,
// +56 on 17/18, and +52 in the packed entry on 26/27. Its formatter still
// takes log_message, whose tv_gmt is at +40, on all of those layouts. Select
// only a qualified OS layout; copying the date also handles the packed
// entry's unaligned timeval. A FLEX tweak such as FLEXing loads its
// own FLEX into every app, so this lives in the agent, not in FLEX.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <malloc/malloc.h>
#import <string.h>
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

// The first and last supplied cache in each OS family were checked against
// _os_activity_stream_entry_decode. Unknown schemas must not be decoded.
static size_t ICLILogMessageOffset(NSInteger majorVersion) {
    switch (majorVersion) {
        case 14: case 15: case 16: return 48;
        case 17: case 18: return 56;
        case 26: case 27: return 52;
        default: return 0;
    }
}

// Validate only the selected layout's date; never use it to choose a layout.
static char *ICLILogMessage(void *entry, size_t offset, time_t now, struct timeval *gmt) {
    if (!offset) return NULL;
    char *message = (char *)entry + offset;
    struct timeval date;
    memcpy(&date, message + 40, sizeof(date));
    if (date.tv_sec <= now - 86400 || date.tv_sec >= now + 86400) return NULL;
    *gmt = date;
    return message;
}

- (BOOL)startMonitoring {
    if (_stream) return YES;
    size_t messageOffset = ICLILogMessageOffset(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion);
    if (!messageOffset) return NO;
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
        struct timeval gmt;
        char *message = ICLILogMessage(entry, messageOffset, now.tv_sec, &gmt);
        if (!message) return true;
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
