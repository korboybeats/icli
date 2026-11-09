#import <Foundation/Foundation.h>

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

#import "FUProtocol.h"
#import "FUMCPTools.h"

static NSString *FUServerInstructions(void) {
    return @"FlexUltra gives an AI live inspection and control of injected jailbroken iOS processes. "
            "Start with flexultra_targets and prefer targets whose build_status is current. If a requested target is missing or stale, call flexultra_target_history to distinguish a live stale agent, a recent transport disconnect, and a target never observed during the current daemon lifetime before choosing a recovery action. If a bundle or process name could match more than one agent, call flexultra_target_resolve and then use the returned PID for subsequent calls. Retain the returned generation and pass it as expected_generation on target-routed calls, including flexultra_target_health. A target_generation_changed error means the process identity changed after discovery; rediscover it, resolve the exact PID, rerun health, and reacquire process-scoped state before continuing. Then consult result.operation_support before choosing an operation. Each entry reports supported, source, requirements, and when relevant reason, conditional, and limitations. result.supported_operations and result.unsupported_operations are compact indexes; result.capabilities and result.flex.features remain broad compatibility summaries. "
            "When health passes, flexultra_investigate_screen is the preferred first full inspection: it returns a bounded UIKit snapshot, focused FLEX metadata, optional Reflex/Swift metadata, an optional screenshot, and suggested follow-ups. "
            "Use flexultra_ui_deep_inspect, flexultra_object_inspect/properties/ivars/methods/get, runtime tools, and heap tools to narrow the investigation before mutating state. Call flexultra_swift_inspect only when target_health.capabilities.swift_inspection is true. On iOS 26 and newer the current Reflex/Echo mirror constructor is disabled for target-process safety; use Objective-C/FLEX object, runtime, UI, and heap tools instead. "
            "Stable UIKit selectors survive ordinary handle churn within the same UI structure; object handles, snapshot IDs, trace sessions, and experiment IDs are process-generation scoped. After a target restart or stale_handle error, rediscover targets, rerun target_health, and resolve fresh handles. "
            "Every failed FlexUltra request includes error.category, retryable, recovery_hint, recommended_action, and suggested_operations in addition to code/message and any operation-specific metadata. Follow the recovery guidance before retrying. If retryable is false, do not repeat the same request unchanged; select another supported operation or repair the reported capability, dependency, request, or protocol issue first. "
            "Prefer tools whose annotations mark readOnlyHint=true until a state change is required. For supported reversible mutations, begin flexultra_experiment_begin, pass its experiment_id to defaults.set/defaults.remove/ui.set_text/ui.set_value/ui.scroll, inspect the result, and rollback unless the requested task requires keeping it. Experiments do not make physical input, UI activation, object.set, object.call, app lifecycle, or arbitrary FLEX global actions reversible. "
            "For behavioral tracing, use narrow class/method/image filters and small max_total_events/max_duration_ms budgets, poll trace.events with after_sequence, and stop the trace when finished. "
            "heap.reference_graph can be expensive, so begin with small depth/node limits. Keychain and filesystem results may contain sensitive app data; request only what the investigation needs.";
}

static BOOL FUWriteStdoutJSON(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return NO;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    return YES;
}

static NSDictionary *FUReadStdinJSON(void) {
    char *line = NULL;
    size_t capacity = 0;
    ssize_t count = getline(&line, &capacity, stdin);
    if (count < 0) {
        if (line) free(line);
        return nil;
    }
    while (count > 0 && (line[count - 1] == '\n' || line[count - 1] == '\r')) {
        count--;
    }
    NSData *data = [NSData dataWithBytes:line length:(NSUInteger)count];
    free(line);
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static int FUConnectBroker(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
#ifdef SO_NOSIGPIPE
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
#endif
    struct timeval timeout = { .tv_sec = 35, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(FUDaemonPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void FUSetReceiveTimeout(int fd, NSInteger seconds) {
    struct timeval timeout = { .tv_sec = (time_t)seconds, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
}

static NSInteger FUReceiveTimeoutForRequest(NSDictionary *request) {
    NSString *op = [request[@"op"] isKindOfClass:[NSString class]] ? request[@"op"] : @"";
    return FUReceiveTimeoutSecondsForOperation(op);
}

static NSDictionary *FUBrokerFailureResponse(NSDictionary *request, NSString *code, NSString *message) {
    NSString *operation = [request[@"op"] isKindOfClass:[NSString class]] ? request[@"op"] : nil;
    NSDictionary *errorInfo = FUEnrichErrorInfo(FUErrorInfo(code, message), operation);
    return FUResponse(request[@"id"] ?: @"", NO, nil, errorInfo);
}

static NSDictionary *FUSendBrokerRequest(NSDictionary *request) {
    int fd = FUConnectBroker();
    if (fd < 0) {
        return FUBrokerFailureResponse(request, @"broker_unavailable", @"Could not connect to flexultrad on the device loopback interface.");
    }
    NSDictionary *hello = @{
        @"v": @(FUProtocolVersion),
        @"kind": @"hello",
        @"role": @"mcp",
    };
    if (!FUWriteJSONLine(fd, hello, nil)) {
        close(fd);
        return FUBrokerFailureResponse(request, @"broker_unavailable", @"Failed to write the MCP broker handshake.");
    }
    NSDictionary *ack = FUReadJSONLine(fd, nil);
    if (![ack[@"ok"] boolValue]) {
        close(fd);
        return FUBrokerFailureResponse(request, @"broker_rejected", @"flexultrad rejected the MCP broker handshake.");
    }
    NSInteger responseTimeout = FUReceiveTimeoutForRequest(request);
    FUSetReceiveTimeout(fd, responseTimeout);
    if (!FUWriteJSONLine(fd, request, nil)) {
        close(fd);
        return FUBrokerFailureResponse(request, @"broker_unavailable", @"Failed to send the request to flexultrad.");
    }
    NSError *responseError = nil;
    NSDictionary *response = FUReadJSONLine(fd, &responseError);
    close(fd);
    if (response) return response;

    NSString *op = [request[@"op"] isKindOfClass:[NSString class]] ? request[@"op"] : @"request";
    if (responseError.code == EAGAIN || responseError.code == EWOULDBLOCK) {
        return FUBrokerFailureResponse(request, @"request_timeout", [NSString stringWithFormat:@"Timed out waiting for %@ after %ld seconds.", op, (long)responseTimeout]);
    }
    NSString *message = responseError.localizedDescription.length
        ? [NSString stringWithFormat:@"No response from flexultrad: %@", responseError.localizedDescription]
        : @"flexultrad closed the connection without a response.";
    return FUBrokerFailureResponse(request, @"broker_unavailable", message);
}

static NSString *FUPrettyJSON(id object) {
    if (!object) return @"null";
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : [object description];
}

static NSDictionary *FUToolResult(NSDictionary *response) {
    BOOL ok = [response[@"ok"] boolValue];
    id payload = ok ? response[@"result"] : response[@"error"];
    NSMutableArray *content = [NSMutableArray array];
    id structuredPayload = payload;
    if (ok && [payload isKindOfClass:[NSDictionary class]]) {
        NSString *mimeType = [payload[@"mime_type"] isKindOfClass:[NSString class]] ? payload[@"mime_type"] : nil;
        NSString *imageData = [payload[@"data"] isKindOfClass:[NSString class]] ? payload[@"data"] : nil;
        if ([mimeType hasPrefix:@"image/"] && imageData.length) {
            [content addObject:@{ @"type": @"image", @"data": imageData, @"mimeType": mimeType }];
            NSMutableDictionary *metadata = [payload mutableCopy];
            [metadata removeObjectForKey:@"data"];
            structuredPayload = metadata;
            [content addObject:@{ @"type": @"text", @"text": FUPrettyJSON(metadata) }];
        }
    }
    if (content.count == 0) {
        [content addObject:@{
            @"type": @"text",
            @"text": FUPrettyJSON(payload ?: NSNull.null),
        }];
    }
    NSMutableDictionary *result = [@{
        @"content": content,
        @"isError": ok ? @NO : @YES,
    } mutableCopy];
    if ([structuredPayload isKindOfClass:[NSDictionary class]]) {
        result[@"structuredContent"] = structuredPayload;
    }
    return result;
}

static NSDictionary *FURequestForTool(NSString *name, NSDictionary *arguments, NSString **error) {
    NSString *op = FUOperationForMCPTool(name);
    if ([name isEqualToString:@"flexultra_flex"]) {
        NSString *action = [arguments[@"action"] isKindOfClass:[NSString class]] ? arguments[@"action"] : @"";
        if (![@[@"status", @"show", @"hide"] containsObject:action]) {
            if (error) *error = @"action must be status, show, or hide";
            return nil;
        }
        op = [@"flex." stringByAppendingString:action];
    }
    if (!op) {
        if (error) *error = [NSString stringWithFormat:@"Unknown tool '%@'.", name ?: @""];
        return nil;
    }

    NSMutableDictionary *request = [arguments mutableCopy] ?: [NSMutableDictionary dictionary];
    [request removeObjectForKey:@"action"];
    if ([name isEqualToString:@"flexultra_network_transactions"] && [arguments[@"kind"] isKindOfClass:[NSString class]]) {
        request[@"network_kind"] = arguments[@"kind"];
    }
    request[@"v"] = @(FUProtocolVersion);
    request[@"kind"] = @"request";
    request[@"id"] = NSUUID.UUID.UUIDString;
    request[@"op"] = op;
    return request;
}

static NSDictionary *FUJSONRPCResult(id requestID, id result) {
    return @{
        @"jsonrpc": @"2.0",
        @"id": requestID ?: NSNull.null,
        @"result": result ?: @{},
    };
}

static NSDictionary *FUJSONRPCError(id requestID, NSInteger code, NSString *message) {
    return @{
        @"jsonrpc": @"2.0",
        @"id": requestID ?: NSNull.null,
        @"error": @{
            @"code": @(code),
            @"message": message ?: @"Unknown error",
        },
    };
}

static NSString *FUNegotiatedProtocolVersion(NSDictionary *params) {
    NSString *requested = [params[@"protocolVersion"] isKindOfClass:[NSString class]] ? params[@"protocolVersion"] : nil;
    NSArray *supported = @[@"2025-06-18", @"2025-03-26", @"2024-11-05"];
    return [supported containsObject:requested] ? requested : supported.firstObject;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        while (YES) {
            @autoreleasepool {
                NSDictionary *message = FUReadStdinJSON();
                if (!message) {
                    if (feof(stdin)) break;
                    continue;
                }
                NSString *method = [message[@"method"] isKindOfClass:[NSString class]] ? message[@"method"] : @"";
                id requestID = message[@"id"];
                NSDictionary *params = [message[@"params"] isKindOfClass:[NSDictionary class]] ? message[@"params"] : @{};

                if ([method isEqualToString:@"notifications/initialized"] || [method isEqualToString:@"notifications/cancelled"]) {
                    continue;
                }
                if ([method isEqualToString:@"initialize"]) {
                    FUWriteStdoutJSON(FUJSONRPCResult(requestID, @{
                        @"protocolVersion": FUNegotiatedProtocolVersion(params),
                        @"capabilities": @{ @"tools": @{} },
                        @"serverInfo": @{
                            @"name": @"FlexUltra",
                            @"version": @"0.1.0",
                        },
                        @"instructions": FUServerInstructions(),
                    }));
                    continue;
                }
                if ([method isEqualToString:@"ping"]) {
                    FUWriteStdoutJSON(FUJSONRPCResult(requestID, @{}));
                    continue;
                }
                if ([method isEqualToString:@"tools/list"]) {
                    FUWriteStdoutJSON(FUJSONRPCResult(requestID, @{ @"tools": FUMCPTools() }));
                    continue;
                }
                if ([method isEqualToString:@"tools/call"]) {
                    NSString *name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : @"";
                    NSDictionary *arguments = [params[@"arguments"] isKindOfClass:[NSDictionary class]] ? params[@"arguments"] : @{};
                    NSString *toolError = nil;
                    NSDictionary *brokerRequest = FURequestForTool(name, arguments, &toolError);
                    if (!brokerRequest) {
                        FUWriteStdoutJSON(FUJSONRPCError(requestID, -32602, toolError ?: @"Invalid tool arguments."));
                        continue;
                    }
                    NSDictionary *brokerResponse = FUSendBrokerRequest(brokerRequest);
                    FUWriteStdoutJSON(FUJSONRPCResult(requestID, FUToolResult(brokerResponse)));
                    continue;
                }
                if (requestID) {
                    FUWriteStdoutJSON(FUJSONRPCError(requestID, -32601, [NSString stringWithFormat:@"Method not found: %@", method]));
                }
            }
        }
    }
    return 0;
}
