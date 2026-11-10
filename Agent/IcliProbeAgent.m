#import <Foundation/Foundation.h>

#include "IcliProbe.h"
#import "IcliObjectInspection.h"
#import "ICLIFlexBridge.h"
#include "ICLIFlexBuild.h"

#include <dispatch/dispatch.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// The probe agent: `icli probe` inside somebody else's app.
//
// `icli probe` reaches every Objective-C class, but only in icli's own
// process, where a UIView is a class and never an instance. A script that
// wants the button a tap would hit has to run where that button is. This
// dylib is that: the same JavaScriptCore engine and the same ObjC bridge,
// loaded into an app and reachable over a socket, so `icli probe --app`
// answers with one JSON line in the shape `icli probe` already answers in.
//
// Loaded on demand by `icli probe --app`, or at launch by --probe.
// Merely loading the library does nothing unless a socket is requested.
// There is no global tweak filter and no resident broker.
//
// Everything a script touches belongs to the app's main thread: a UIView read
// from any other thread is a race, and UIKit says so. So the socket is served
// on its own thread and every evaluation is handed to the main queue, which
// also keeps the one shared JSContext on one thread for its whole life. A main
// thread that never answers is the app's own fault and must not become a
// permanently wedged agent, so a request that outlives its timeout is
// abandoned: its answer is freed by whoever finally produces it.

/// Where to listen. Absent means this process was not asked to serve, which
/// is every process but the one icli launched with `--probe`.
static const char *const IcliProbeAgentSocketVariable = "ICLI_PROBE_SOCKET";
static NSString *IcliProbeIdentityPath;
static NSMutableDictionary *IcliProbeIdentity;
NSString *icli_probe_agent_generation(void) {
    static NSString *generation;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ generation = [[NSUUID.UUID.UUIDString lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""]; });
    return generation;
}

void icli_probe_agent_update_identity(NSDictionary *metadata) {
    @synchronized (NSBundle.mainBundle) {
        if (!IcliProbeIdentityPath) return;
        if (!IcliProbeIdentity) {
            IcliProbeIdentity = [@{@"pid": @(getpid()),
                @"bundle_id": NSBundle.mainBundle.bundleIdentifier ?: @"",
                @"process": NSProcessInfo.processInfo.processName,
                @"flexultra_build": @ICLI_FULL_FLEX_BUILD,
                @"generation": icli_probe_agent_generation(),
                @"connected_at_unix_ms": @(NSDate.date.timeIntervalSince1970 * 1000)} mutableCopy];
        }
        [IcliProbeIdentity addEntriesFromDictionary:metadata];
        NSData *data = [NSJSONSerialization dataWithJSONObject:IcliProbeIdentity options:0 error:nil];
        [data writeToFile:IcliProbeIdentityPath options:NSDataWritingAtomic error:nil];
    }
}

/// How long a request waits for the app's main thread before it is abandoned,
/// unless the request asks for its own. A launch animation or a network call
/// on the main thread can hold it for a while, and a script that waits is
/// better than one that fails.
static const double IcliProbeAgentDefaultTimeout = 30.0;

/// What one request may be, so a peer that never sends a newline cannot grow
/// the app's memory until it is killed: 8 MiB of script is far past anything
/// a probe sends.
static const size_t IcliProbeAgentRequestLimit = 8u << 20;

// MARK: - Serving One Request

/// api() in an app has no icli behind it: the capabilities it answers are
/// icli's own process's. Say so, rather than leaving the engine's bare "no api
/// handler" to explain it.
static char *icli_probe_agent_api(const char *request) {
    (void)request;
    return strdup("{\"error\":{\"code\":\"unavailable\",\"message\":"
                  "\"api() reaches icli's own capabilities and is not available inside an app; "
                  "run that part as a plain `icli probe` and pass what it answers into this script\"}}");
}

/// Both scripts and inspections run on the same main queue. The block owns
/// its request and reply even when the serving thread stops waiting.
static NSDictionary *icli_probe_agent_on_main(NSDictionary *(^work)(void), double timeout) {
    NSObject *lock = [NSObject new];
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block NSDictionary *response = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSDictionary *reply = work();
            @synchronized (lock) {
                response = reply;
                dispatch_semaphore_signal(answered);
            }
        }
    });
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    dispatch_semaphore_wait(answered, deadline);
    @synchronized (lock) {
        if (response) return response;
    }
    return @{@"ok": @NO, @"error": [NSString stringWithFormat:
        @"the app's main thread did not answer within %g s; it is busy or blocked, and the request may still run later", timeout],
        @"output": @""};
}

static NSDictionary *icli_probe_agent_evaluate(NSString *source) {
    char *error = NULL, *output = NULL;
    char *value = icli_probe_evaluate(source.UTF8String, &error, &output);
    NSDictionary *response = value
        ? @{@"ok": @YES, @"result": @(value), @"output": @(output ?: "")}
        : @{@"ok": @NO, @"error": @(error ?: "Unknown error"), @"output": @(output ?: "")};
    free(value); free(error); free(output);
    return response;
}

/// The answer to one request object.
static NSDictionary *icli_probe_agent_answer(NSDictionary *request) {
    if (request[@"expected_pid"] && [request[@"expected_pid"] intValue] != getpid()) {
        return @{@"ok": @NO, @"error": @"the app restarted; open a new probe shell before sending more scripts", @"output": @""};
    }
    NSString *operation = [request[@"op"] isKindOfClass:[NSString class]] ? request[@"op"] : @"evaluate";
    if ([operation isEqualToString:@"ping"]) {
        return @{
            @"ok": @YES,
            @"pid": @(getpid()),
            @"bundle_id": NSBundle.mainBundle.bundleIdentifier ?: [NSNull null],
            @"process": NSProcessInfo.processInfo.processName ?: @"",
            @"javascriptcore": @(icli_probe_available()),
            @"object_inspection": @YES,
            @"flexultra_build": @ICLI_FULL_FLEX_BUILD,
            @"generation": icli_probe_agent_generation(),
        };
    }
    if ([operation isEqualToString:@"flexultra"]) {
        if (![request[@"request"] isKindOfClass:NSDictionary.class])
            return @{@"ok": @NO, @"error": @"a FlexUltra request object is required", @"output": @""};
        return icli_full_flex_request(request[@"request"]);
    }
    if (![operation isEqualToString:@"evaluate"] && ![operation isEqualToString:@"inspect"]) {
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"unknown op '%@'", operation], @"output": @""};
    }
    if ([operation isEqualToString:@"evaluate"] && ![request[@"source"] isKindOfClass:[NSString class]]) {
        return @{@"ok": @NO, @"error": @"a request needs a 'source' string", @"output": @""};
    }
    double timeout = IcliProbeAgentDefaultTimeout;
    if ([request[@"timeout"] isKindOfClass:[NSNumber class]]) {
        double asked = [request[@"timeout"] doubleValue];
        if (asked > 0 && asked <= 600) timeout = asked;
    }
    return icli_probe_agent_on_main(^NSDictionary *{
        return [operation isEqualToString:@"inspect"] ? icli_probe_inspect_object(request) : icli_probe_agent_evaluate(request[@"source"]);
    }, timeout);
}

// MARK: - The Socket

/// Read one newline-terminated request from `fd`. Nil at end of input, or
/// where the peer sent more than the limit without a newline.
static NSData *icli_probe_agent_read_line(int fd) {
    NSMutableData *line = [NSMutableData data];
    char buffer[4096];
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0) {
            if (errno == EINTR) continue;
            return nil;
        }
        if (count == 0) return line.length ? line : nil;
        char *newline = memchr(buffer, '\n', (size_t)count);
        if (newline) {
            [line appendBytes:buffer length:(size_t)(newline - buffer)];
            return line;
        }
        [line appendBytes:buffer length:(size_t)count];
        if (line.length > IcliProbeAgentRequestLimit) return nil;
    }
}

static bool icli_probe_agent_write(int fd, NSData *data) {
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    while (remaining) {
        ssize_t written = write(fd, bytes, remaining);
        if (written <= 0) {
            if (written < 0 && errno == EINTR) continue;
            return false;
        }
        bytes += written;
        remaining -= (size_t)written;
    }
    return true;
}

/// Answer requests on one connection until the peer goes away. One at a time:
/// the engine keeps a single context, so a second concurrent script would be
/// sharing it.
static void icli_probe_agent_serve_connection(int fd) {
    for (;;) {
        NSData *line = icli_probe_agent_read_line(fd);
        if (!line) return;
        NSDictionary *response = nil;
        @autoreleasepool {
            id request = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            response = [request isKindOfClass:[NSDictionary class]]
                ? icli_probe_agent_answer(request)
                : @{@"ok": @NO, @"error": @"a request must be one JSON object on one line", @"output": @""};
            NSData *encoded = [NSJSONSerialization dataWithJSONObject:response
                                                              options:NSJSONWritingSortedKeys
                                                                error:nil];
            if (!encoded) encoded = [@"{\"ok\":false,\"error\":\"unencodable answer\",\"output\":\"\"}" dataUsingEncoding:NSUTF8StringEncoding];
            NSMutableData *out = [NSMutableData dataWithData:encoded];
            [out appendBytes:"\n" length:1];
            if (!icli_probe_agent_write(fd, out)) return;
        }
    }
}

/// Serve on the socket that start prepared before returning to the caller.
static void *icli_probe_agent_listen(void *context) {
    pthread_setname_np("com.korboy.icli.probe-agent");
    int server = (int)(intptr_t)context;

    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            break;
        }
        // Leaving a remote REPL or interrupting its client must not kill the
        // app when a script finally returns to a closed socket.
        int noSignal = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        @autoreleasepool {
            icli_probe_agent_serve_connection(client);
        }
        close(client);
    }
    close(server);
    return NULL;
}

/// Whether this process is the app itself. DYLD_INSERT_LIBRARIES reaches
/// anything the app spawns too, and a helper tool that inherited it would
/// otherwise race the app for the same socket.
static bool icli_probe_agent_is_app(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    if (![[bundle.bundlePath.pathExtension lowercaseString] isEqualToString:@"app"]) return false;
    // An extension lives inside an .app but is not the app, and has its own
    // process and its own main thread.
    return ![bundle.infoDictionary[@"NSExtension"] isKindOfClass:[NSDictionary class]];
}

/// Explicit entry point for attaching to an already-running app. Binding
/// happens before return, so the client needs no guessed startup delay.
int icli_probe_agent_attach(const char *path) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static bool started;
    pthread_mutex_lock(&lock);
    if (started) { pthread_mutex_unlock(&lock); return 0; }
    int error = 0, server = -1;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (!icli_probe_agent_is_app()) error = EINVAL;
    else if (!path || !*path || strlen(path) >= sizeof(address.sun_path)) error = ENAMETOOLONG;
    if (!error) {
        strlcpy(address.sun_path, path, sizeof(address.sun_path));
        server = socket(AF_UNIX, SOCK_STREAM, 0);
        if (server < 0) error = errno;
    }
    if (!error) {
        unlink(path);
        if (bind(server, (struct sockaddr *)&address, sizeof(address)) || listen(server, 8)) error = errno;
    }
    if (!error) {
        icli_probe_set_api_handler(icli_probe_agent_api);
        pthread_t thread;
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        error = pthread_create(&thread, &attributes, icli_probe_agent_listen, (void *)(intptr_t)server);
        pthread_attr_destroy(&attributes);
    }
    if (error && server >= 0) { close(server); unlink(path); }
    if (!error) {
        started = true;
        IcliProbeIdentityPath = [@(path) stringByAppendingString:@".info"];
        icli_probe_agent_update_identity(@{});
    }
    pthread_mutex_unlock(&lock);
    return error;
}

__attribute__((constructor)) static void icli_probe_agent_start(void) {
    @autoreleasepool {
        const char *path = getenv(IcliProbeAgentSocketVariable);
        if (path && *path) {
            int error = icli_probe_agent_attach(path);
            if (error) {
                // Constructor failures have no caller to answer. Keep them in
                // the app's own files, never its console.
                NSString *log = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/icli-probe-debug.log"];
                [[NSString stringWithFormat:@"agent start: %s\n", strerror(error)]
                    writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
    }
}
