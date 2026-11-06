#import <Foundation/Foundation.h>

#include "IcliProbe.h"

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
// It is injected per launch, through the DYLD_INSERT_LIBRARIES that
// `icli app launch --probe` sets, and it does nothing at all unless
// ICLI_PROBE_SOCKET names where to listen. An app icli did not launch this
// way carries no agent, so an idle device runs no extra code.
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

/// How long a request waits for the app's main thread before it is abandoned,
/// unless the request asks for its own. A launch animation or a network call
/// on the main thread can hold it for a while, and a script that waits is
/// better than one that fails.
static const double IcliProbeAgentDefaultTimeout = 30.0;

/// What one request may be, so a peer that never sends a newline cannot grow
/// the app's memory until it is killed: 8 MiB of script is far past anything
/// a probe sends.
static const size_t IcliProbeAgentRequestLimit = 8u << 20;

/// One evaluation handed to the main queue. The serving thread waits for it,
/// but gives up after the timeout: `abandoned` says which side owns what is
/// in here, so a late answer is freed rather than written into a response
/// nobody is waiting for.
typedef struct {
    pthread_mutex_t lock;
    bool abandoned;
    char *result;
    char *error;
    char *output;
} IcliProbeAgentCall;

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

/// Evaluate `source` on the app's main thread and answer in the shape
/// `icli probe` answers in: ok with result, or ok false with error, and
/// whatever the script printed either way.
static NSDictionary *icli_probe_agent_evaluate(NSString *source, double timeout) {
    // The block outlives this scope when the main thread is slow, so it gets
    // its own copy of the script rather than a pointer into an autoreleased
    // buffer.
    char *script = strdup(source.UTF8String ?: "");
    if (!script) return @{@"ok": @NO, @"error": @"out of memory", @"output": @""};

    IcliProbeAgentCall *call = calloc(1, sizeof(*call));
    if (!call) {
        free(script);
        return @{@"ok": @NO, @"error": @"out of memory", @"output": @""};
    }
    pthread_mutex_init(&call->lock, NULL);
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        char *error = NULL;
        char *output = NULL;
        char *result = icli_probe_evaluate(script, &error, &output);
        free(script);
        pthread_mutex_lock(&call->lock);
        if (call->abandoned) {
            // Nobody is waiting: this call's memory is ours to release, and
            // the lock is ours to destroy.
            pthread_mutex_unlock(&call->lock);
            free(result);
            free(error);
            free(output);
            pthread_mutex_destroy(&call->lock);
            free(call);
            return;
        }
        call->result = result;
        call->error = error;
        call->output = output;
        pthread_mutex_unlock(&call->lock);
        dispatch_semaphore_signal(answered);
    });

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(answered, deadline) != 0) {
        pthread_mutex_lock(&call->lock);
        call->abandoned = true;
        pthread_mutex_unlock(&call->lock);
        return @{
            @"ok": @NO,
            @"error": [NSString stringWithFormat:@"the app's main thread did not answer within %g s; "
                                                 @"it is busy or blocked, and the script may still run later",
                                                 timeout],
            @"output": @"",
        };
    }

    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"output"] = @(call->output ?: "");
    if (call->result) {
        response[@"ok"] = @YES;
        response[@"result"] = @(call->result);
    } else {
        response[@"ok"] = @NO;
        response[@"error"] = @(call->error ?: "Unknown error");
    }
    free(call->result);
    free(call->error);
    free(call->output);
    pthread_mutex_destroy(&call->lock);
    free(call);
    return response;
}

/// The answer to one request object.
static NSDictionary *icli_probe_agent_answer(NSDictionary *request) {
    NSString *operation = [request[@"op"] isKindOfClass:[NSString class]] ? request[@"op"] : @"evaluate";
    if ([operation isEqualToString:@"ping"]) {
        return @{
            @"ok": @YES,
            @"pid": @(getpid()),
            @"bundle_id": NSBundle.mainBundle.bundleIdentifier ?: [NSNull null],
            @"process": NSProcessInfo.processInfo.processName ?: @"",
            @"javascriptcore": @(icli_probe_available()),
        };
    }
    if (![operation isEqualToString:@"evaluate"]) {
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"unknown op '%@'", operation], @"output": @""};
    }
    if (![request[@"source"] isKindOfClass:[NSString class]]) {
        return @{@"ok": @NO, @"error": @"a request needs a 'source' string", @"output": @""};
    }
    double timeout = IcliProbeAgentDefaultTimeout;
    if ([request[@"timeout"] isKindOfClass:[NSNumber class]]) {
        double asked = [request[@"timeout"] doubleValue];
        if (asked > 0 && asked <= 600) timeout = asked;
    }
    return icli_probe_agent_evaluate(request[@"source"], timeout);
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

/// Bind `path` and answer on it for the life of the process. A path already
/// there is a socket from a launch that is gone, since the one live agent for
/// an app is this process.
static void *icli_probe_agent_listen(void *context) {
    pthread_setname_np("com.icli.probe-agent");
    char *path = context;
    int server = -1;
    @autoreleasepool {
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        if (strlen(path) >= sizeof(address.sun_path)) {
            NSLog(@"[icli probe agent] the socket path is longer than %zu characters: %s",
                  sizeof(address.sun_path) - 1, path);
            free(path);
            return NULL;
        }
        strlcpy(address.sun_path, path, sizeof(address.sun_path));
        server = socket(AF_UNIX, SOCK_STREAM, 0);
        if (server < 0) {
            NSLog(@"[icli probe agent] socket failed: %s", strerror(errno));
            free(path);
            return NULL;
        }
        unlink(path);
        if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0) {
            NSLog(@"[icli probe agent] cannot bind %s: %s", path, strerror(errno));
            close(server);
            free(path);
            return NULL;
        }
        if (listen(server, 8) != 0) {
            NSLog(@"[icli probe agent] cannot listen on %s: %s", path, strerror(errno));
            close(server);
            free(path);
            return NULL;
        }
        free(path);
        icli_probe_set_api_handler(icli_probe_agent_api);
    }

    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            break;
        }
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

__attribute__((constructor)) static void icli_probe_agent_start(void) {
    @autoreleasepool {
        const char *socketPath = getenv(IcliProbeAgentSocketVariable);
        if (!socketPath || !*socketPath) return;
        if (!icli_probe_agent_is_app()) return;
        char *owned = strdup(socketPath);
        if (!owned) return;
        pthread_t thread;
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&thread, &attributes, icli_probe_agent_listen, owned) != 0) free(owned);
        pthread_attr_destroy(&attributes);
    }
}
