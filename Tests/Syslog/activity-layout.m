#import <Foundation/Foundation.h>
#import "../../Agent/FlexUltra/ICLIOSLogController.m"

// Exercise the production reader with the layouts emitted by the cached
// LoggingSupport decoders, including the unaligned timeval on iOS 26/27.
int main(void) {
    @autoreleasepool {
        const time_t now = 1794762000;
        const struct { NSInteger major; size_t offset; } layouts[] = {
            {14, 48}, {15, 48}, {16, 48}, {17, 56}, {18, 56}, {26, 52}, {27, 52},
        };
        for (size_t i = 0; i < sizeof(layouts) / sizeof(layouts[0]); i++) {
            size_t offset = ICLILogMessageOffset(layouts[i].major);
            if (offset != layouts[i].offset) {
                fprintf(stderr, "FAIL iOS %ld layout\n", (long)layouts[i].major);
                return 1;
            }
            uint64_t entry[30] = {0};
            char *bytes = (char *)entry;
            struct timeval expected = {.tv_sec = now, .tv_usec = 123456};
            memcpy(bytes + offset + 40, &expected, sizeof(expected));
            struct timeval actual = {0};
            if (ICLILogMessage(entry, offset, now, &actual) != bytes + offset
                || actual.tv_sec != expected.tv_sec || actual.tv_usec != expected.tv_usec) {
                fprintf(stderr, "FAIL activity stream layout +%zu\n", offset);
                return 1;
            }
            // An entry from another layout cannot change the OS selection.
            size_t other = offset == 48 ? 56 : 48;
            if (ICLILogMessage(entry, other, now, &actual)) {
                fprintf(stderr, "FAIL activity stream guessed another layout\n");
                return 1;
            }
        }
        uint64_t empty[30] = {0};
        struct timeval date = {0};
        if (ICLILogMessage(empty, 48, now, &date)) {
            fprintf(stderr, "FAIL activity stream accepted a missing timestamp\n");
            return 1;
        }
        const NSInteger unknown[] = {13, 19, 25, 28};
        for (size_t i = 0; i < sizeof(unknown) / sizeof(unknown[0]); i++) {
            if (ICLILogMessageOffset(unknown[i]) || ICLILogMessage(empty, 0, now, &date)) {
                fprintf(stderr, "FAIL activity stream accepted an unqualified OS\n");
                return 1;
            }
        }
        for (size_t i = 0; i < sizeof(layouts) / sizeof(layouts[0]); i++) {
            uint64_t entry[30] = {0};
            struct timeval stale = {.tv_sec = now - 86401, .tv_usec = 123456};
            memcpy((char *)entry + layouts[i].offset + 40, &stale, sizeof(stale));
            if (ICLILogMessage(entry, layouts[i].offset, now, &date)) {
                fprintf(stderr, "FAIL activity stream accepted a stale timestamp\n");
                return 1;
            }
        }
        puts("Activity stream layouts +48/+56/+52 passed");
    }
    return 0;
}
