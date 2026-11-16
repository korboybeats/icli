#import "IcliLaunchPrivate.h"
#import <Foundation/Foundation.h>
#import <errno.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

// Client for the Parallel broker (package com.korboy.parallel), which runs in
// SpringBoard and owns hidden app sessions. One JSON object per line each way
// over a Unix socket; the broker closes the connection after its reply.
static const char *const kParallelSocket = "/var/mobile/Library/Parallel/broker.sock";

static char *jsonError(NSString *code, NSString *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"ok": @NO, @"error": code, @"detail": message}
                                                   options:0 error:nil];
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String ?: "{}");
}

char *icli_parallel_request_json(const char *request_json, double timeout) {
    @autoreleasepool {
        if (access(kParallelSocket, F_OK) != 0)
            return jsonError(@"parallel_unavailable", @"Parallel is not installed or SpringBoard has not loaded it");
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return jsonError(@"parallel_unavailable", @(strerror(errno)));
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, kParallelSocket, sizeof(address.sun_path));
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        struct timeval limit = {(time_t)timeout, (suseconds_t)((timeout - (time_t)timeout) * 1e6)};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof(limit));
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
            int error = errno;
            close(fd);
            return jsonError(@"parallel_unavailable",
                             [NSString stringWithFormat:@"%s (is Parallel loaded in SpringBoard?)", strerror(error)]);
        }
        size_t length = strlen(request_json);
        const char *bytes = request_json;
        BOOL sent = YES;
        while (length) {
            ssize_t n = write(fd, bytes, length);
            if (n <= 0) { sent = NO; break; }
            bytes += n; length -= n;
        }
        if (sent) sent = write(fd, "\n", 1) == 1;
        NSMutableData *reply = [NSMutableData data];
        char buffer[16384];
        ssize_t n = 0;
        while (sent && (n = read(fd, buffer, sizeof(buffer))) > 0) [reply appendBytes:buffer length:(NSUInteger)n];
        int error = errno;
        close(fd);
        if (!sent) return jsonError(@"parallel_disconnected", @"the broker closed the connection");
        if (n < 0) return jsonError(error == EAGAIN ? @"timed_out" : @"parallel_disconnected", @(strerror(error)));
        if (!reply.length) return jsonError(@"parallel_disconnected", @"the broker sent no reply");
        [reply appendBytes:"" length:1];
        return strdup(reply.bytes);
    }
}

NSSet<NSString *> *icli_parallel_session_bundles(void) {
    if (access(kParallelSocket, F_OK) != 0) return [NSSet set];
    char *raw = icli_parallel_request_json("{\"op\":\"list\"}", 1);
    NSData *data = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil;
    free(raw);
    NSDictionary *reply = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableSet *bundles = [NSMutableSet set];
    if (![reply isKindOfClass:[NSDictionary class]] || ![reply[@"sessions"] isKindOfClass:[NSArray class]]) return bundles;
    for (NSDictionary *session in reply[@"sessions"])
        if ([session isKindOfClass:[NSDictionary class]] && [session[@"bundle"] isKindOfClass:[NSString class]])
            [bundles addObject:session[@"bundle"]];
    return bundles;
}
