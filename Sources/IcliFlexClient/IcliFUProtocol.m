// Adapted by icli: namespaced symbols and private on-demand transport.
#import "IcliFUProtocol.h"

#import <errno.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <sys/socket.h>
#import <unistd.h>

const NSUInteger IcliFUProtocolVersion = 1;
const uint16_t IcliFUDaemonPort = 38477;
NSString *const IcliFUProtocolErrorDomain = @"moe.waru.flexultra.protocol";

static NSDictionary<NSString *, id> *IcliFUOperation(NSString *operation,
                                                  NSString *mcpTool,
                                                  IcliFUOperationFlags flags) {
    NSMutableDictionary<NSString *, id> *metadata = [@{
        @"operation": operation,
        @"flags": @(flags),
    } mutableCopy];
    if (mcpTool.length) {
        metadata[@"mcp_tool"] = mcpTool;
    }
    return metadata;
}

NSArray<NSDictionary<NSString *, id> *> *IcliFUOperationCatalog(void) {
    static NSArray<NSDictionary<NSString *, id> *> *catalog;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        catalog = @[
            IcliFUOperation(@"targets", @"flexultra_targets", IcliFUOperationFlagDaemonLocal),
            IcliFUOperation(@"target.resolve", @"flexultra_target_resolve", IcliFUOperationFlagDaemonLocal),
            IcliFUOperation(@"target.history", @"flexultra_target_history", IcliFUOperationFlagDaemonLocal),
            IcliFUOperation(@"app.list", @"flexultra_app_list", IcliFUOperationFlagDaemonLocal),
            IcliFUOperation(@"app.running", @"flexultra_app_running", IcliFUOperationFlagDaemonLocal),
            IcliFUOperation(@"app.frontmost", @"flexultra_app_frontmost", IcliFUOperationFlagDaemonLocal),
            IcliFUOperation(@"app.launch", @"flexultra_app_launch", IcliFUOperationFlagDaemonLocal | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"app.kill", @"flexultra_app_kill", IcliFUOperationFlagDaemonLocal | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"input.tap", @"flexultra_input_tap", IcliFUOperationFlagDaemonLocal | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"input.double_tap", @"flexultra_input_double_tap", IcliFUOperationFlagDaemonLocal | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"input.long_press", @"flexultra_input_long_press", IcliFUOperationFlagDaemonLocal | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"input.swipe", @"flexultra_input_swipe", IcliFUOperationFlagDaemonLocal | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"input.drag", @"flexultra_input_drag", IcliFUOperationFlagDaemonLocal | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"input.touch", @"flexultra_input_touch", IcliFUOperationFlagDaemonLocal | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"input.touch_sequence", @"flexultra_input_touch_sequence", IcliFUOperationFlagDaemonLocal | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"agent.info", nil, IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ping", @"flexultra_ping", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"target.health", @"flexultra_target_health", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"flex.status", nil, IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"flex.show", nil, IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPIdempotent),
            IcliFUOperation(@"flex.hide", nil, IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPIdempotent),
            IcliFUOperation(@"experiment.begin", @"flexultra_experiment_begin", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging),
            IcliFUOperation(@"experiment.status", @"flexultra_experiment_status", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"experiment.rollback", @"flexultra_experiment_rollback", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging),
            IcliFUOperation(@"experiment.commit", @"flexultra_experiment_commit", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive),
            IcliFUOperation(@"trace.start", @"flexultra_trace_start", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging),
            IcliFUOperation(@"trace.status", @"flexultra_trace_status", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"trace.events", @"flexultra_trace_events", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"trace.stop", @"flexultra_trace_stop", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging),
            IcliFUOperation(@"runtime.classes", @"flexultra_runtime_classes", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"runtime.class", @"flexultra_runtime_class", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"runtime.class_protocols", @"flexultra_runtime_class_protocols", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"runtime.images", @"flexultra_runtime_images", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"runtime.image_classes", @"flexultra_runtime_image_classes", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"runtime.protocols", @"flexultra_runtime_protocols", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"runtime.protocol", @"flexultra_runtime_protocol", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"runtime.protocol_classes", @"flexultra_runtime_protocol_classes", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"runtime.methods", @"flexultra_runtime_methods", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"runtime.properties", @"flexultra_runtime_properties", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"runtime.ivars", @"flexultra_runtime_ivars", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"heap.snapshot", @"flexultra_heap_snapshot", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagHeapWorker | IcliFUOperationFlagLongTimeout),
            IcliFUOperation(@"heap.instances", @"flexultra_heap_instances", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagHeapWorker | IcliFUOperationFlagLongTimeout),
            IcliFUOperation(@"heap.subclasses", @"flexultra_heap_subclasses", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagLongTimeout),
            IcliFUOperation(@"heap.references", @"flexultra_heap_references", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagHeapWorker | IcliFUOperationFlagLongTimeout),
            IcliFUOperation(@"heap.reference_graph", @"flexultra_heap_reference_graph", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagHeapWorker | IcliFUOperationFlagLongTimeout),
            IcliFUOperation(@"bookmarks.list", @"flexultra_bookmarks_list", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"bookmarks.add", @"flexultra_bookmarks_add", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging),
            IcliFUOperation(@"bookmarks.remove", @"flexultra_bookmarks_remove", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging),
            IcliFUOperation(@"network.transactions", @"flexultra_network_transactions", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"logs.messages", @"flexultra_logs_messages", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"globals.entries", @"flexultra_globals_entries", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"globals.open", @"flexultra_globals_open", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"globals.invoke", @"flexultra_globals_invoke", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"defaults.entries", @"flexultra_defaults_entries", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"defaults.get", @"flexultra_defaults_get", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"defaults.set", @"flexultra_defaults_set", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPIdempotent),
            IcliFUOperation(@"defaults.remove", @"flexultra_defaults_remove", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPIdempotent),
            IcliFUOperation(@"keychain.items", @"flexultra_keychain_items", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"keychain.item", @"flexultra_keychain_item", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"database.sqlite.tables", @"flexultra_database_sqlite_tables", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"database.sqlite.columns", @"flexultra_database_sqlite_columns", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"database.sqlite.rows", @"flexultra_database_sqlite_rows", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"database.realm.tables", @"flexultra_database_realm_tables", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"database.realm.columns", @"flexultra_database_realm_columns", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"database.realm.rows", @"flexultra_database_realm_rows", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"filesystem.list", @"flexultra_filesystem_list", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"filesystem.stat", @"flexultra_filesystem_stat", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"filesystem.read", @"flexultra_filesystem_read", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"filesystem.search", @"flexultra_filesystem_search", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.windows", @"flexultra_ui_windows", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.key_window", @"flexultra_ui_key_window", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.hierarchy", @"flexultra_ui_hierarchy", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.find", @"flexultra_ui_find", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.resolve", @"flexultra_ui_resolve", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.wait", @"flexultra_ui_wait", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.activate", @"flexultra_ui_activate", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"ui.select", @"flexultra_ui_select", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"ui.back", @"flexultra_ui_back", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"ui.dismiss", @"flexultra_ui_dismiss", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"ui.first_responder", @"flexultra_ui_first_responder", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.dismiss_keyboard", @"flexultra_ui_dismiss_keyboard", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPIdempotent),
            IcliFUOperation(@"ui.alert", @"flexultra_ui_alert", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.alert_action", @"flexultra_ui_alert_action", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"ui.hit_test", @"flexultra_ui_hit_test", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.tap", @"flexultra_ui_tap", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"ui.set_text", @"flexultra_ui_set_text", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"ui.set_value", @"flexultra_ui_set_value", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPOpenWorld),
            IcliFUOperation(@"ui.scroll", @"flexultra_ui_scroll", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging),
            IcliFUOperation(@"ui.screenshot", @"flexultra_ui_screenshot", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.snapshot", @"flexultra_ui_snapshot", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.snapshot_save", @"flexultra_ui_snapshot_save", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging),
            IcliFUOperation(@"ui.snapshot_diff", @"flexultra_ui_snapshot_diff", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"ui.deep_inspect", @"flexultra_ui_deep_inspect", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"object.inspect", @"flexultra_object_inspect", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"swift.inspect", @"flexultra_swift_inspect", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"investigate.screen", @"flexultra_investigate_screen", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"investigate.element", @"flexultra_investigate_element", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagHeapWorker | IcliFUOperationFlagLongTimeout),
            IcliFUOperation(@"object.properties", @"flexultra_object_properties", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"object.ivars", @"flexultra_object_ivars", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"object.methods", @"flexultra_object_methods", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"object.get", @"flexultra_object_get", IcliFUOperationFlagAgentCapability),
            IcliFUOperation(@"object.set", @"flexultra_object_set", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive),
            IcliFUOperation(@"object.pin", @"flexultra_object_pin", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging),
            IcliFUOperation(@"object.unpin", @"flexultra_object_unpin", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging),
            IcliFUOperation(@"object.call", @"flexultra_object_call", IcliFUOperationFlagAgentCapability | IcliFUOperationFlagMCPStateChanging | IcliFUOperationFlagMCPDestructive | IcliFUOperationFlagMCPOpenWorld),
        ];
    });
    return catalog;
}

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *IcliFUOperationMetadataByName(void) {
    static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *byName;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *index = [NSMutableDictionary dictionary];
        for (NSDictionary<NSString *, id> *metadata in IcliFUOperationCatalog()) {
            NSString *operation = metadata[@"operation"];
            if (operation.length) {
                index[operation] = metadata;
            }
        }
        byName = [index copy];
    });
    return byName;
}

NSArray<NSString *> *IcliFUAgentCapabilities(void) {
    static NSArray<NSString *> *capabilities;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *items = [NSMutableArray array];
        for (NSDictionary<NSString *, id> *metadata in IcliFUOperationCatalog()) {
            IcliFUOperationFlags flags = [metadata[@"flags"] unsignedIntegerValue];
            if ((flags & IcliFUOperationFlagAgentCapability) != 0) {
                [items addObject:metadata[@"operation"]];
            }
        }
        capabilities = [items copy];
    });
    return capabilities;
}

NSString *IcliFUOperationForMCPTool(NSString *toolName) {
    if (!toolName.length) return nil;
    static NSDictionary<NSString *, NSString *> *mapping;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, NSString *> *items = [NSMutableDictionary dictionary];
        for (NSDictionary<NSString *, id> *metadata in IcliFUOperationCatalog()) {
            NSString *mcpTool = metadata[@"mcp_tool"];
            NSString *operation = metadata[@"operation"];
            if (mcpTool.length && operation.length) {
                items[mcpTool] = operation;
            }
        }
        mapping = [items copy];
    });
    return mapping[toolName];
}

static NSDictionary<NSString *, NSNumber *> *IcliFUMCPAnnotationsForFlags(IcliFUOperationFlags flags) {
    BOOL stateChanging = (flags & IcliFUOperationFlagMCPStateChanging) != 0;
    return @{
        @"readOnlyHint": [NSNumber numberWithBool:!stateChanging],
        @"destructiveHint": [NSNumber numberWithBool:(flags & IcliFUOperationFlagMCPDestructive) != 0],
        @"idempotentHint": [NSNumber numberWithBool:!stateChanging || (flags & IcliFUOperationFlagMCPIdempotent) != 0],
        @"openWorldHint": [NSNumber numberWithBool:(flags & IcliFUOperationFlagMCPOpenWorld) != 0],
    };
}

NSDictionary<NSString *, NSNumber *> *IcliFUMCPToolAnnotations(NSString *toolName) {
    if (!toolName.length) return nil;

    NSString *operation = IcliFUOperationForMCPTool(toolName);
    if (operation.length) {
        NSDictionary<NSString *, id> *metadata = IcliFUOperationMetadataByName()[operation];
        return IcliFUMCPAnnotationsForFlags([metadata[@"flags"] unsignedIntegerValue]);
    }

    // flexultra_flex dynamically dispatches to flex.status/show/hide. Aggregate
    // those catalog entries conservatively so the composite tool cannot drift.
    if ([toolName isEqualToString:@"flexultra_flex"]) {
        NSArray<NSString *> *operations = @[@"flex.status", @"flex.show", @"flex.hide"];
        BOOL stateChanging = NO;
        BOOL destructive = NO;
        BOOL idempotent = YES;
        BOOL openWorld = NO;
        for (NSString *candidate in operations) {
            IcliFUOperationFlags flags = [IcliFUOperationMetadataByName()[candidate][@"flags"] unsignedIntegerValue];
            BOOL candidateStateChanging = (flags & IcliFUOperationFlagMCPStateChanging) != 0;
            stateChanging = stateChanging || candidateStateChanging;
            destructive = destructive || (flags & IcliFUOperationFlagMCPDestructive) != 0;
            idempotent = idempotent && (!candidateStateChanging || (flags & IcliFUOperationFlagMCPIdempotent) != 0);
            openWorld = openWorld || (flags & IcliFUOperationFlagMCPOpenWorld) != 0;
        }
        return @{
            @"readOnlyHint": [NSNumber numberWithBool:!stateChanging],
            @"destructiveHint": [NSNumber numberWithBool:destructive],
            @"idempotentHint": [NSNumber numberWithBool:idempotent],
            @"openWorldHint": [NSNumber numberWithBool:openWorld],
        };
    }

    return nil;
}

BOOL IcliFUOperationUsesHeapWorker(NSString *operation) {
    NSDictionary<NSString *, id> *metadata = IcliFUOperationMetadataByName()[operation ?: @""];
    return ([metadata[@"flags"] unsignedIntegerValue] & IcliFUOperationFlagHeapWorker) != 0;
}

BOOL IcliFUOperationIsDaemonLocal(NSString *operation) {
    NSDictionary<NSString *, id> *metadata = IcliFUOperationMetadataByName()[operation ?: @""];
    return ([metadata[@"flags"] unsignedIntegerValue] & IcliFUOperationFlagDaemonLocal) != 0;
}

NSInteger IcliFUReceiveTimeoutSecondsForOperation(NSString *operation) {
    NSDictionary<NSString *, id> *metadata = IcliFUOperationMetadataByName()[operation ?: @""];
    IcliFUOperationFlags flags = [metadata[@"flags"] unsignedIntegerValue];
    // Preserve the historical timeout policy for future/unknown heap operations.
    return ((flags & IcliFUOperationFlagLongTimeout) != 0 || [operation hasPrefix:@"heap."]) ? 120 : 35;
}

static NSError *IcliFUProtocolError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:IcliFUProtocolErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Protocol error"}];
}

static NSString *IcliFUInvalidJSONValueDescription(id value, NSString *path, NSUInteger depth) {
    if (depth > 64) {
        return [NSString stringWithFormat:@"%@ exceeds the JSON diagnostic nesting limit", path];
    }
    if (!value || value == NSNull.null || [value isKindOfClass:[NSString class]]) {
        return nil;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        double number = [value doubleValue];
        if (!isfinite(number)) {
            NSString *spelling = isnan(number) ? @"NaN" : (number > 0.0 ? @"+Infinity" : @"-Infinity");
            return [NSString stringWithFormat:@"%@ contains non-finite NSNumber %@ (%@)", path, spelling, NSStringFromClass([value class])];
        }
        return nil;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = value;
        for (NSUInteger index = 0; index < array.count; index++) {
            NSString *childPath = [NSString stringWithFormat:@"%@[%lu]", path, (unsigned long)index];
            NSString *detail = IcliFUInvalidJSONValueDescription(array[index], childPath, depth + 1);
            if (detail) return detail;
        }
        return nil;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = value;
        for (id key in dictionary) {
            if (![key isKindOfClass:[NSString class]]) {
                return [NSString stringWithFormat:@"%@ contains non-string dictionary key of type %@", path, NSStringFromClass([key class])];
            }
            NSString *childPath = [NSString stringWithFormat:@"%@.%@", path, key];
            NSString *detail = IcliFUInvalidJSONValueDescription(dictionary[key], childPath, depth + 1);
            if (detail) return detail;
        }
        return nil;
    }
    return [NSString stringWithFormat:@"%@ contains unsupported JSON value of type %@", path, NSStringFromClass([value class])];
}

NSDictionary *IcliFUReadJSONLine(int fd, NSError **error) {
    NSMutableData *buffer = [NSMutableData data];
    const NSUInteger maxLength = 4 * 1024 * 1024;

    while (buffer.length < maxLength) {
        uint8_t byte = 0;
        ssize_t count = recv(fd, &byte, 1, 0);
        if (count == 0) {
            if (error) {
                *error = IcliFUProtocolError(1, @"Connection closed");
            }
            return nil;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (error) {
                *error = IcliFUProtocolError(errno, [NSString stringWithFormat:@"recv failed: %s", strerror(errno)]);
            }
            return nil;
        }

        if (byte == '\n') {
            break;
        }
        [buffer appendBytes:&byte length:1];
    }

    if (buffer.length >= maxLength) {
        if (error) {
            *error = IcliFUProtocolError(2, @"JSON message exceeded 4 MiB limit");
        }
        return nil;
    }

    if (buffer.length == 0) {
        if (error) {
            *error = IcliFUProtocolError(3, @"Received an empty message");
        }
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:buffer options:0 error:&jsonError];
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = jsonError ?: IcliFUProtocolError(4, @"Expected a JSON object");
        }
        return nil;
    }

    return object;
}

BOOL IcliFUWriteJSONLine(int fd, NSDictionary *object, NSError **error) {
    NSError *jsonError = nil;
    NSData *json = nil;
    @try {
        if (![NSJSONSerialization isValidJSONObject:object]) {
            if (error) {
                NSString *detail = IcliFUInvalidJSONValueDescription(object, @"$", 0);
                NSString *message = detail.length
                    ? [NSString stringWithFormat:@"Object contains values that cannot be serialized as JSON: %@", detail]
                    : @"Object contains values that cannot be serialized as JSON";
                *error = IcliFUProtocolError(5, message);
            }
            return NO;
        }
        json = [NSJSONSerialization dataWithJSONObject:object options:0 error:&jsonError];
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name ?: @"Unknown JSON serialization exception";
            NSString *detail = IcliFUInvalidJSONValueDescription(object, @"$", 0);
            NSString *message = detail.length
                ? [NSString stringWithFormat:@"JSON serialization threw an exception: %@; %@", reason, detail]
                : [NSString stringWithFormat:@"JSON serialization threw an exception: %@", reason];
            *error = IcliFUProtocolError(5, message);
        }
        return NO;
    }
    if (!json) {
        if (error) {
            *error = jsonError ?: IcliFUProtocolError(5, @"JSON serialization failed");
        }
        return NO;
    }

    NSMutableData *line = [json mutableCopy];
    uint8_t newline = '\n';
    [line appendBytes:&newline length:1];

    const uint8_t *bytes = line.bytes;
    NSUInteger remaining = line.length;
    while (remaining > 0) {
        ssize_t count = send(fd, bytes, remaining, 0);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (error) {
                *error = IcliFUProtocolError(errno, [NSString stringWithFormat:@"send failed: %s", strerror(errno)]);
            }
            return NO;
        }
        bytes += count;
        remaining -= (NSUInteger)count;
    }

    return YES;
}

static BOOL IcliFUErrorCodeIsOneOf(NSString *code, NSArray<NSString *> *values) {
    return code.length && [values containsObject:code];
}

NSDictionary *IcliFUEnrichErrorInfo(NSDictionary *errorInfo, NSString *operation) {
    NSMutableDictionary *enriched = [errorInfo isKindOfClass:[NSDictionary class]]
        ? [errorInfo mutableCopy]
        : [NSMutableDictionary dictionary];
    NSString *code = [enriched[@"code"] isKindOfClass:[NSString class]] ? enriched[@"code"] : @"unknown_error";
    NSString *message = [enriched[@"message"] isKindOfClass:[NSString class]] ? enriched[@"message"] : @"Unknown error";
    enriched[@"code"] = code;
    enriched[@"message"] = message;

    NSString *category = @"operation";
    BOOL retryable = YES;
    NSString *recoveryHint = @"check_target_health";
    NSString *recommendedAction = @"Run target.health, inspect operation_support, then retry the operation if it remains supported.";
    NSArray<NSString *> *suggestedOperations = @[@"target.health"];

    if ([code isEqualToString:@"target_not_found"] || [code isEqualToString:@"target_generation_changed"]) {
        category = @"target_lifecycle";
        recoveryHint = @"rediscover_target";
        recommendedAction = [code isEqualToString:@"target_generation_changed"]
            ? @"The selected process relaunched or reconnected. Run targets and target.history, resolve the exact current PID, run target.health, then reacquire process-scoped handles, snapshots, traces, and experiments before retrying."
            : @"Run targets and target.history, resolve the current process to an exact PID, then run target.health before retrying.";
        suggestedOperations = @[@"targets", @"target.history", @"target.resolve", @"target.health"];
    } else if ([code isEqualToString:@"target_ambiguous"]) {
        category = @"target_resolution";
        recoveryHint = @"select_exact_pid";
        recommendedAction = @"Use the candidate metadata to select an exact PID with target.resolve, then run target.health before retrying.";
        suggestedOperations = @[@"targets", @"target.resolve", @"target.health"];
    } else if (IcliFUErrorCodeIsOneOf(code, @[@"stale_handle", @"object_not_found"])) {
        category = @"object_lifecycle";
        recoveryHint = @"reacquire_object";
        recommendedAction = @"Reacquire the object from the current process. Prefer a stable UIKit selector, then retry with the fresh handle or selector.";
        suggestedOperations = @[@"ui.resolve", @"investigate.screen", @"investigate.element"];
    } else if (IcliFUErrorCodeIsOneOf(code, @[@"stale_snapshot", @"snapshot_not_found"])) {
        category = @"snapshot_lifecycle";
        recoveryHint = @"capture_fresh_baseline";
        recommendedAction = @"Capture a fresh saved UI snapshot in the current process generation, then repeat the snapshot comparison.";
        suggestedOperations = @[@"ui.snapshot_save", @"ui.snapshot_diff"];
    } else if ([code hasPrefix:@"experiment_"] || [code isEqualToString:@"stale_experiment"]) {
        category = @"experiment_state";
        retryable = ![code isEqualToString:@"experiment_unavailable"];
        recoveryHint = [code isEqualToString:@"experiment_unavailable"] ? @"check_operation_support" : @"inspect_experiment_state";
        recommendedAction = [code isEqualToString:@"experiment_unavailable"]
            ? @"Run target.health and inspect operation_support before using reversible experiments on this target."
            : @"Run experiment.status. Finish, roll back, or begin a fresh experiment as indicated by the current state, then retry.";
        suggestedOperations = [code isEqualToString:@"experiment_unavailable"]
            ? @[@"target.health"]
            : @[@"experiment.status", @"experiment.rollback", @"experiment.begin"];
    } else if ([code hasPrefix:@"trace_"]) {
        category = @"trace_state";
        recoveryHint = @"inspect_trace_state";
        recommendedAction = @"Run trace.status, then start or stop the bounded trace as required by the reported state before retrying.";
        suggestedOperations = @[@"trace.status", @"trace.start", @"trace.stop"];
    } else if (IcliFUErrorCodeIsOneOf(code, @[
        @"swift_runtime_unsafe", @"unsupported_flex", @"flex_unavailable", @"realm_unavailable",
        @"reflex_unavailable", @"unsupported_reflex", @"bookmarks_unavailable", @"globals_unavailable",
        @"network_recorder_unavailable", @"log_controller_unavailable", @"navigation_unavailable",
        @"signature_unavailable", @"heap_unconfigured", @"target_health_unavailable", @"internal_configuration"
    ])) {
        category = @"capability";
        retryable = NO;
        recoveryHint = @"check_operation_support";
        recommendedAction = @"Run target.health and use operation_support to select a supported inspection path or repair the missing capability before retrying.";
        suggestedOperations = @[@"target.health"];
    } else if (IcliFUErrorCodeIsOneOf(code, @[@"broker_unavailable", @"broker_rejected", @"agent_unreachable", @"request_timeout"])) {
        category = @"transport";
        recoveryHint = @"refresh_transport_and_target";
        recommendedAction = @"Restore broker/agent connectivity if needed, then rediscover the target, inspect target.history, resolve the current PID, and run target.health.";
        suggestedOperations = @[@"targets", @"target.history", @"target.resolve", @"target.health"];
    } else if (IcliFUErrorCodeIsOneOf(code, @[@"dependency_unavailable", @"dependency_failed", @"invalid_dependency_response"])) {
        category = @"dependency";
        retryable = NO;
        recoveryHint = @"repair_dependency";
        recommendedAction = @"Repair or restore the required external dependency, then retry the operation.";
        suggestedOperations = @[];
    } else if ([code hasSuffix:@"_timeout"]) {
        category = @"timeout";
        recoveryHint = @"refresh_state_and_retry";
        recommendedAction = @"Refresh target health and current UI/runtime state, reduce the operation scope or budget when possible, then retry.";
        suggestedOperations = @[@"target.health"];
    } else if ([code isEqualToString:@"window_not_found"] || [code hasSuffix:@"_busy"]) {
        category = @"target_state";
        recoveryHint = @"refresh_target_state";
        recommendedAction = @"Refresh target health and the current screen/runtime state, then retry when the target is ready.";
        suggestedOperations = @[@"target.health", @"investigate.screen"];
    } else if (IcliFUErrorCodeIsOneOf(code, @[
        @"selector_not_found", @"selector_ambiguous", @"member_not_found", @"class_not_found",
        @"class_unresolved", @"protocol_not_found", @"image_not_found", @"action_not_found",
        @"owner_not_found", @"view_not_found", @"focus_unresolved", @"index_path_not_found", @"not_found"
    ])) {
        category = @"discovery";
        recoveryHint = @"refresh_discovery";
        recommendedAction = @"Refresh the visible UI and runtime metadata, resolve the desired object or symbol from current evidence, then retry.";
        suggestedOperations = @[@"investigate.screen", @"ui.find", @"runtime.classes"];
    } else if ([code hasPrefix:@"invalid_"]
               || IcliFUErrorCodeIsOneOf(code, @[
                    @"include_filter_required", @"too_many_filters", @"argument_count_mismatch", @"wrong_type",
                    @"missing_value", @"path_outside_root", @"ambiguous_item", @"action_ambiguous",
                    @"action_disabled", @"selection_disallowed", @"control_disabled", @"point_out_of_bounds",
                    @"value_out_of_range", @"member_readonly", @"unsupported_type", @"unsupported_return_type",
                    @"unsupported_view", @"unknown_operation"
               ])) {
        category = @"validation";
        recoveryHint = @"correct_request";
        recommendedAction = @"Correct the request using the current operation schema and live UI/runtime metadata, then retry.";
        suggestedOperations = @[@"target.health"];
    } else if (IcliFUErrorCodeIsOneOf(code, @[@"protocol_mismatch", @"invalid_role", @"invalid_response", @"response_serialization_failed"])) {
        category = @"protocol";
        retryable = NO;
        recoveryHint = @"repair_protocol_client";
        recommendedAction = @"Correct the client/protocol incompatibility before issuing another request.";
        suggestedOperations = @[];
    }

    if (![enriched[@"category"] isKindOfClass:[NSString class]] || ![enriched[@"category"] length]) {
        enriched[@"category"] = category;
    }
    if (![enriched[@"retryable"] isKindOfClass:[NSNumber class]]) {
        enriched[@"retryable"] = @(retryable);
    }
    if (![enriched[@"recovery_hint"] isKindOfClass:[NSString class]] || ![enriched[@"recovery_hint"] length]) {
        enriched[@"recovery_hint"] = recoveryHint;
    }
    if (![enriched[@"recommended_action"] isKindOfClass:[NSString class]] || ![enriched[@"recommended_action"] length]) {
        enriched[@"recommended_action"] = recommendedAction;
    }

    NSMutableArray<NSString *> *operations = [NSMutableArray array];
    NSArray *existingSuggested = [enriched[@"suggested_operations"] isKindOfClass:[NSArray class]]
        ? enriched[@"suggested_operations"]
        : suggestedOperations;
    for (id candidate in existingSuggested) {
        if ([candidate isKindOfClass:[NSString class]] && [candidate length] && ![operations containsObject:candidate]) {
            [operations addObject:candidate];
        }
    }
    if (operation.length
        && [enriched[@"retryable"] boolValue]
        && IcliFUOperationMetadataByName()[operation]
        && ![operations containsObject:operation]) {
        [operations addObject:operation];
    }
    enriched[@"suggested_operations"] = operations;
    return enriched;
}

NSDictionary *IcliFUErrorInfo(NSString *code, NSString *message) {
    return IcliFUEnrichErrorInfo(@{
        @"code": code ?: @"unknown_error",
        @"message": message ?: @"Unknown error",
    }, nil);
}

NSDictionary *IcliFUResponse(NSString *requestID, BOOL ok, id result, NSDictionary *errorInfo) {
    NSMutableDictionary *response = [@{
        @"v": @(IcliFUProtocolVersion),
        @"kind": @"response",
        @"id": requestID ?: @"",
        @"ok": @(ok),
    } mutableCopy];

    if (ok) {
        response[@"result"] = result ?: [NSNull null];
    } else {
        response[@"error"] = errorInfo ?: IcliFUErrorInfo(@"unknown_error", @"Unknown error");
    }

    return response;
}
