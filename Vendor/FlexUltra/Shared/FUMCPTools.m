#import "FUMCPTools.h"

#import "FUProtocol.h"

static NSDictionary *FUStringProperty(NSString *description) {
    return @{
        @"type": @"string",
        @"description": description ?: @"",
    };
}

static NSDictionary *FUIntegerProperty(NSString *description, NSNumber *minimum, NSNumber *maximum) {
    NSMutableDictionary *property = [@{
        @"type": @"integer",
        @"description": description ?: @"",
    } mutableCopy];
    if (minimum) property[@"minimum"] = minimum;
    if (maximum) property[@"maximum"] = maximum;
    return property;
}

static NSDictionary *FUBooleanProperty(NSString *description) {
    return @{
        @"type": @"boolean",
        @"description": description ?: @"",
    };
}

static NSDictionary *FUObjectSchema(NSDictionary *properties, NSArray<NSString *> *required) {
    NSMutableDictionary *schema = [@{
        @"type": @"object",
        @"properties": properties ?: @{},
        @"additionalProperties": @NO,
    } mutableCopy];
    if (required.count) schema[@"required"] = required;
    return schema;
}

static NSDictionary *FUTool(NSString *name, NSString *description, NSDictionary *schema) {
    return @{
        @"name": name,
        @"description": description,
        @"inputSchema": schema,
        @"annotations": FUMCPToolAnnotations(name) ?: @{},
    };
}

NSArray<NSDictionary<NSString *, id> *> *FUMCPTools(void) {
    NSDictionary *target = FUStringProperty(@"PID, bundle identifier, or process name of the injected target.");
    NSDictionary *expectedGeneration = FUStringProperty(@"Optional process generation captured from targets, target.resolve, or target.health. The daemon rejects the request if the selected process has relaunched or reconnected since discovery.");
    NSDictionary *handle = FUStringProperty(@"Generation-qualified, process-scoped FlexUltra object handle such as obj_0123456789abcdef0123456789abcdef_42. Handles from a previous target launch fail with stale_handle. Raw pointers are never accepted.");
    NSDictionary *stableSelector = @{
        @"type": @"object",
        @"description": @"Stable UIKit selector returned by ui.find or ui.snapshot. It contains a semantic strategy plus a hierarchy path fallback and no process-scoped handle.",
        @"properties": @{
            @"version": @{ @"type": @"integer", @"const": @1 },
            @"strategy": @{ @"type": @"string", @"enum": @[@"accessibility_identifier", @"accessibility_label", @"text", @"path"] },
            @"value": FUStringProperty(@"Exact semantic value for non-path strategies."),
            @"class": FUStringProperty(@"Exact UIKit class name."),
            @"path": @{ @"type": @"array", @"items": @{ @"type": @"integer", @"minimum": @0 } },
        },
        @"required": @[@"version", @"strategy", @"class", @"path"],
        @"additionalProperties": @NO,
    };
    NSDictionary *pagination = @{
        @"offset": FUIntegerProperty(@"Zero-based offset.", @0, nil),
        @"limit": FUIntegerProperty(@"Maximum number of results.", @1, @1000),
    };
    NSDictionary *traceStringArray = @{
        @"type": @"array",
        @"items": @{ @"type": @"string", @"minLength": @1 },
        @"description": @"ObjSee wildcard filter patterns. Multiple entries are ORed by ObjSee.",
    };
    NSDictionary *tracePatternArray = @{
        @"type": @"array",
        @"items": FUObjectSchema(@{
            @"class": @{ @"type": @"string", @"minLength": @1 },
            @"method": @{ @"type": @"string", @"minLength": @1 },
        }, @[@"class", @"method"]),
        @"description": @"ObjSee class+method wildcard filter pairs.",
    };
    NSDictionary *filesystemRoot = @{
        @"type": @"string",
        @"enum": @[@"home", @"bundle"],
        @"description": @"Filesystem root. home is the target app container; bundle is the main application bundle.",
    };
    NSDictionary *defaultsValue = @{
        @"oneOf": @[
            @{ @"type": @"string" },
            @{ @"type": @"number" },
            @{ @"type": @"boolean" },
            @{ @"type": @"array", @"items": @{}, @"description": @"JSON array containing property-list-compatible values; null is rejected." },
            @{ @"type": @"object", @"additionalProperties": @YES, @"description": @"JSON object with string keys and property-list-compatible values; null is rejected." },
        ],
        @"description": @"Property-list-compatible JSON value. Use defaults.remove to delete a key; null is not accepted.",
    };

    NSArray<NSDictionary<NSString *, id> *> *tools = @[
        FUTool(@"flexultra_targets", @"List injected iOS processes currently connected to flexultrad, including generation, expected/current agent build status, connection metadata, and capabilities.", FUObjectSchema(@{}, @[])),
        FUTool(@"flexultra_target_resolve", @"Deterministically resolve a PID, bundle identifier, or process name to one connected FlexUltra target. Ambiguous names return candidate metadata so the client can choose a PID.", FUObjectSchema(@{
            @"target": target,
        }, @[@"target"])),
        FUTool(@"flexultra_target_history", @"Inspect bounded daemon-lifetime target connection history. Use it to distinguish current, stale, recently disconnected, and never-observed targets without retaining app payloads or object handles.", FUObjectSchema(@{
            @"target": target,
            @"limit": FUIntegerProperty(@"Maximum recent lifecycle events to return. Defaults to 32.", @1, @128),
        }, @[])),
        FUTool(@"flexultra_app_list", @"List installed applications through the runtime-optional iCLI lifecycle bridge.", FUObjectSchema(@{}, @[])),
        FUTool(@"flexultra_app_running", @"List running applications through the runtime-optional iCLI lifecycle bridge.", FUObjectSchema(@{}, @[])),
        FUTool(@"flexultra_app_frontmost", @"Return the frontmost application through the runtime-optional iCLI lifecycle bridge.", FUObjectSchema(@{}, @[])),
        FUTool(@"flexultra_app_launch", @"Launch an application by bundle identifier through the runtime-optional iCLI lifecycle bridge.", FUObjectSchema(@{
            @"bundle_id": FUStringProperty(@"Bundle identifier to launch."),
        }, @[@"bundle_id"])),
        FUTool(@"flexultra_app_kill", @"Terminate an application by bundle identifier through the runtime-optional iCLI lifecycle bridge.", FUObjectSchema(@{
            @"bundle_id": FUStringProperty(@"Bundle identifier to terminate."),
            @"force": FUBooleanProperty(@"Request force termination when supported by iCLI."),
        }, @[@"bundle_id"])),
        FUTool(@"flexultra_input_tap", @"Send a real digitizer tap at screen coordinates through the runtime-optional iCLI device-control bridge.", FUObjectSchema(@{
            @"x": @{ @"type": @"number", @"minimum": @0, @"description": @"Horizontal screen coordinate in UIKit points." },
            @"y": @{ @"type": @"number", @"minimum": @0, @"description": @"Vertical screen coordinate in UIKit points." },
        }, @[@"x", @"y"])),
        FUTool(@"flexultra_input_double_tap", @"Send a real digitizer double-tap through the runtime-optional iCLI device-control bridge.", FUObjectSchema(@{
            @"x": @{ @"type": @"number", @"minimum": @0, @"description": @"Horizontal screen coordinate in UIKit points." },
            @"y": @{ @"type": @"number", @"minimum": @0, @"description": @"Vertical screen coordinate in UIKit points." },
            @"interval": @{ @"type": @"number", @"minimum": @0, @"description": @"Optional seconds between taps. iCLI defaults to 0.1." },
        }, @[@"x", @"y"])),
        FUTool(@"flexultra_input_long_press", @"Send a real digitizer long press through the runtime-optional iCLI device-control bridge.", FUObjectSchema(@{
            @"x": @{ @"type": @"number", @"minimum": @0, @"description": @"Horizontal screen coordinate in UIKit points." },
            @"y": @{ @"type": @"number", @"minimum": @0, @"description": @"Vertical screen coordinate in UIKit points." },
            @"seconds": @{ @"type": @"number", @"minimum": @0, @"description": @"Optional press duration. iCLI defaults to 0.6 seconds." },
        }, @[@"x", @"y"])),
        FUTool(@"flexultra_input_swipe", @"Send a real digitizer swipe through the runtime-optional iCLI device-control bridge.", FUObjectSchema(@{
            @"from_x": @{ @"type": @"number", @"minimum": @0 },
            @"from_y": @{ @"type": @"number", @"minimum": @0 },
            @"to_x": @{ @"type": @"number", @"minimum": @0 },
            @"to_y": @{ @"type": @"number", @"minimum": @0 },
            @"seconds": @{ @"type": @"number", @"minimum": @0, @"description": @"Optional swipe duration. iCLI defaults to 0.25 seconds." },
            @"steps": FUIntegerProperty(@"Optional interpolation steps. iCLI defaults to 20.", @1, nil),
        }, @[@"from_x", @"from_y", @"to_x", @"to_y"])),
        FUTool(@"flexultra_input_drag", @"Send a real digitizer drag using endpoints or a point path through the runtime-optional iCLI device-control bridge.", FUObjectSchema(@{
            @"from_x": @{ @"type": @"number", @"minimum": @0 },
            @"from_y": @{ @"type": @"number", @"minimum": @0 },
            @"to_x": @{ @"type": @"number", @"minimum": @0 },
            @"to_y": @{ @"type": @"number", @"minimum": @0 },
            @"points": @{
                @"type": @"array",
                @"minItems": @2,
                @"description": @"Alternative to endpoints: ordered screen points [{x,y}, ...].",
                @"items": FUObjectSchema(@{
                    @"x": @{ @"type": @"number", @"minimum": @0 },
                    @"y": @{ @"type": @"number", @"minimum": @0 },
                }, @[@"x", @"y"]),
            },
            @"seconds": @{ @"type": @"number", @"minimum": @0, @"description": @"Optional drag duration. iCLI defaults to 0.3 seconds." },
            @"hold": @{ @"type": @"number", @"minimum": @0, @"description": @"Optional initial hold duration. iCLI defaults to 0.5 seconds." },
            @"steps": FUIntegerProperty(@"Optional interpolation steps. iCLI defaults to 20.", @1, nil),
        }, @[])),
        FUTool(@"flexultra_input_touch", @"Send one raw digitizer touch phase through the runtime-optional iCLI device-control bridge.", FUObjectSchema(@{
            @"phase": @{ @"type": @"string", @"enum": @[@"down", @"move", @"up"] },
            @"x": @{ @"type": @"number", @"minimum": @0 },
            @"y": @{ @"type": @"number", @"minimum": @0 },
            @"normalized": FUBooleanProperty(@"Interpret x and y in the 0-1 fixed-portrait digitizer coordinate space."),
        }, @[@"phase", @"x", @"y"])),
        FUTool(@"flexultra_input_touch_sequence", @"Send a timed raw digitizer touch sequence through the runtime-optional iCLI device-control bridge.", FUObjectSchema(@{
            @"events": @{
                @"type": @"array",
                @"minItems": @1,
                @"items": FUObjectSchema(@{
                    @"phase": @{ @"type": @"string", @"enum": @[@"down", @"move", @"up"] },
                    @"x": @{ @"type": @"number", @"minimum": @0 },
                    @"y": @{ @"type": @"number", @"minimum": @0 },
                    @"delay_ms": @{ @"type": @"number", @"minimum": @0 },
                }, @[@"phase", @"x", @"y", @"delay_ms"]),
            },
            @"normalized": FUBooleanProperty(@"Interpret event x/y values in the 0-1 fixed-portrait digitizer coordinate space."),
        }, @[@"events"])),
        FUTool(@"flexultra_ping", @"Verify routing to one injected process.", FUObjectSchema(@{ @"target": target }, @[@"target"])),
        FUTool(@"flexultra_target_health", @"Qualify an injected target for AI inspection: process generation, UIKit/FLEX health, current state, and per-operation live readiness in operation_support. supported_operations/unsupported_operations provide compact indexes; capabilities and flex.features remain broad compatibility summaries.", FUObjectSchema(@{ @"target": target }, @[@"target"])),
        FUTool(@"flexultra_flex", @"Get FLEX status or show/hide the FLEX explorer overlay.", FUObjectSchema(@{
            @"target": target,
            @"action": @{ @"type": @"string", @"enum": @[@"status", @"show", @"hide"] },
        }, @[@"target", @"action"])),
        FUTool(@"flexultra_experiment_begin", @"Begin one process-generation-scoped reversible experiment in the target process.", FUObjectSchema(@{
            @"target": target,
        }, @[@"target"])),
        FUTool(@"flexultra_experiment_status", @"Return the active reversible experiment and mutation count for the target process.", FUObjectSchema(@{
            @"target": target,
        }, @[@"target"])),
        FUTool(@"flexultra_experiment_rollback", @"Roll back the active reversible experiment in reverse mutation order and end it.", FUObjectSchema(@{
            @"target": target,
        }, @[@"target"])),
        FUTool(@"flexultra_experiment_commit", @"Commit the active reversible experiment by keeping its mutations and ending it.", FUObjectSchema(@{
            @"target": target,
        }, @[@"target"])),
        FUTool(@"flexultra_trace_start", @"Start one bounded ObjSee Objective-C message trace in the target process. At least one include_classes, include_methods, include_images, or include_patterns entry is required.", FUObjectSchema(@{
            @"target": target,
            @"include_classes": traceStringArray,
            @"include_methods": traceStringArray,
            @"include_images": traceStringArray,
            @"include_patterns": tracePatternArray,
            @"exclude_classes": traceStringArray,
            @"exclude_methods": traceStringArray,
            @"exclude_images": traceStringArray,
            @"exclude_patterns": tracePatternArray,
            @"max_events": FUIntegerProperty(@"Bounded ring-buffer capacity. Defaults to 500.", @100, @5000),
            @"max_total_events": FUIntegerProperty(@"Maximum events observed before the trace stops automatically. Defaults to 5000.", @1, @50000),
            @"max_duration_ms": FUIntegerProperty(@"Maximum trace lifetime in milliseconds before automatic stop. Defaults to 30000.", @100, @300000),
            @"argument_detail": @{ @"type": @"string", @"enum": @[@"none", @"basic", @"class"], @"description": @"Argument metadata detail. Defaults to none; higher detail adds tracing overhead." },
        }, @[@"target"])),
        FUTool(@"flexultra_trace_status", @"Return the current or most recently stopped ObjSee trace session status for the target process.", FUObjectSchema(@{
            @"target": target,
        }, @[@"target"])),
        FUTool(@"flexultra_trace_events", @"Read a bounded page of captured ObjSee trace events. after_sequence is a stable cursor for incremental AI polling.", FUObjectSchema(@{
            @"target": target,
            @"after_sequence": FUIntegerProperty(@"Return only events with a sequence greater than this cursor.", @0, nil),
            @"offset": FUIntegerProperty(@"Zero-based offset after applying after_sequence.", @0, nil),
            @"limit": FUIntegerProperty(@"Maximum trace events to return.", @1, @500),
        }, @[@"target"])),
        FUTool(@"flexultra_trace_stop", @"Stop the active ObjSee trace while preserving its bounded captured events for later reads.", FUObjectSchema(@{
            @"target": target,
        }, @[@"target"])),
        FUTool(@"flexultra_runtime_classes", @"Search Objective-C runtime classes through FLEX.", FUObjectSchema(@{
            @"target": target,
            @"query": FUStringProperty(@"Case-insensitive class-name query. Empty returns all classes up to the limit."),
            @"limit": FUIntegerProperty(@"Maximum classes to return.", @1, @500),
        }, @[@"target"])),
        FUTool(@"flexultra_runtime_class", @"Resolve an exact loaded Objective-C class into a process-scoped class-object handle for FLEX inspection and class-method calls.", FUObjectSchema(@{
            @"target": target,
            @"name": FUStringProperty(@"Exact Objective-C class name, such as UIViewController."),
        }, @[@"target", @"name"])),
        FUTool(@"flexultra_runtime_class_protocols", @"List protocols directly adopted by an exact loaded Objective-C class and, optionally, its superclass chain.", FUObjectSchema(@{
            @"target": target,
            @"class_name": FUStringProperty(@"Exact loaded Objective-C class name."),
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against protocol names."),
            @"include_inherited": FUBooleanProperty(@"Include protocols directly adopted by superclasses. Defaults to true."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"class_name"])),
        FUTool(@"flexultra_runtime_images", @"Browse loaded Mach-O images through FLEXRuntimeClient, including display names and exact paths for follow-up class browsing.", FUObjectSchema(@{
            @"target": target,
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against image display names and paths."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target"])),
        FUTool(@"flexultra_runtime_image_classes", @"List Objective-C classes FLEX associates with one loaded image. Accepts a display name or exact path from flexultra_runtime_images.", FUObjectSchema(@{
            @"target": target,
            @"image": FUStringProperty(@"Loaded image display name or exact path."),
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against class names."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"image"])),
        FUTool(@"flexultra_runtime_protocols", @"Browse loaded Objective-C protocols using FLEXRuntimeClient's runtime catalog.", FUObjectSchema(@{
            @"target": target,
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against protocol names."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target"])),
        FUTool(@"flexultra_runtime_protocol", @"Inspect one exact loaded Objective-C protocol, including adopted protocols and required/optional instance/class method contracts.", FUObjectSchema(@{
            @"target": target,
            @"name": FUStringProperty(@"Exact loaded Objective-C protocol name."),
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against selector or type encoding."),
            @"method_kind": @{ @"type": @"string", @"enum": @[@"any", @"instance", @"class"], @"description": @"Restrict to instance or class method contracts. Defaults to any." },
            @"requirement": @{ @"type": @"string", @"enum": @[@"any", @"required", @"optional"], @"description": @"Restrict to required or optional method contracts. Defaults to any." },
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"name"])),
        FUTool(@"flexultra_runtime_protocol_classes", @"List loaded Objective-C classes that conform to one exact protocol from FLEX's runtime catalog.", FUObjectSchema(@{
            @"target": target,
            @"name": FUStringProperty(@"Exact loaded Objective-C protocol name."),
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against class names."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"name"])),
        FUTool(@"flexultra_runtime_methods", @"Search methods on one exact loaded Objective-C class through FLEXRuntimeClient. Results include the exact declaring class, implementation provenance, and invocation metadata for direct follow-up calls or tweak hook selection.", FUObjectSchema(@{
            @"target": target,
            @"class_name": FUStringProperty(@"Exact loaded Objective-C class name."),
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against selector/signature text."),
            @"method_kind": @{ @"type": @"string", @"enum": @[@"any", @"instance", @"class"], @"description": @"Restrict to instance or class methods. Defaults to any." },
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"class_name"])),
        FUTool(@"flexultra_runtime_properties", @"Inspect FLEX property metadata for one exact loaded Objective-C class before locating an instance.", FUObjectSchema(@{
            @"target": target,
            @"class_name": FUStringProperty(@"Exact loaded Objective-C class name."),
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against property or declaring-class names."),
            @"property_kind": @{ @"type": @"string", @"enum": @[@"any", @"instance", @"class"], @"description": @"Restrict to instance or class properties. Defaults to any." },
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"class_name"])),
        FUTool(@"flexultra_runtime_ivars", @"Inspect FLEX ivar metadata for one exact loaded Objective-C class before locating an instance.", FUObjectSchema(@{
            @"target": target,
            @"class_name": FUStringProperty(@"Exact loaded Objective-C class name."),
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against ivar or declaring-class names."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"class_name"])),
        FUTool(@"flexultra_heap_snapshot", @"Generate FLEX's live heap snapshot and return class-level instance counts, instance sizes, and estimated bytes for AI discovery.", FUObjectSchema(@{
            @"target": target,
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against live class names."),
            @"sort": @{ @"type": @"string", @"enum": @[@"name", @"count", @"size"], @"description": @"Sort by class name, descending live instance count, or descending estimated bytes. Defaults to name." },
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
            @"timeout_ms": FUIntegerProperty(@"Maximum heap work time in milliseconds. Defaults to 60000.", @1, @110000),
        }, @[@"target"])),
        FUTool(@"flexultra_heap_instances", @"Find live instances of an exact Objective-C class through FLEX heap enumeration and return process-scoped object handles.", FUObjectSchema(@{
            @"target": target,
            @"name": FUStringProperty(@"Exact Objective-C class name."),
            @"retained": FUBooleanProperty(@"Ask FLEX to retain objects while enumerating. Defaults to false."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
            @"timeout_ms": FUIntegerProperty(@"Maximum heap work time in milliseconds. Defaults to 60000.", @1, @110000),
        }, @[@"target", @"name"])),
        FUTool(@"flexultra_heap_subclasses", @"Find loaded subclasses of an exact Objective-C class through FLEX heap discovery.", FUObjectSchema(@{
            @"target": target,
            @"name": FUStringProperty(@"Exact Objective-C class name."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"name"])),
        FUTool(@"flexultra_heap_references", @"Find live objects that reference a target object using FLEX heap enumeration. Accepts a live handle or stable UIKit selector.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"ui_selector": stableSelector,
            @"retained": FUBooleanProperty(@"Ask FLEX to retain objects while enumerating. Defaults to false."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
            @"timeout_ms": FUIntegerProperty(@"Maximum heap work time in milliseconds. Defaults to 60000.", @1, @110000),
        }, @[@"target"])),
        FUTool(@"flexultra_heap_reference_graph", @"Build a bounded cycle-safe reverse-reference graph from a live object using FLEX heap enumeration. Edges point from each referrer to the object it references.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"ui_selector": stableSelector,
            @"max_depth": FUIntegerProperty(@"Maximum reverse-reference BFS depth. Defaults to 2.", @1, @5),
            @"max_nodes": FUIntegerProperty(@"Maximum graph nodes including the root. Defaults to 100.", @1, @500),
            @"per_node_limit": FUIntegerProperty(@"Maximum reverse references followed from each scanned node. Defaults to 50.", @1, @200),
            @"retained": FUBooleanProperty(@"Ask FLEX to retain objects while enumerating. Defaults to false."),
            @"timeout_ms": FUIntegerProperty(@"Maximum heap work time in milliseconds. Defaults to 60000.", @1, @110000),
        }, @[@"target"])),
        FUTool(@"flexultra_bookmarks_list", @"List FLEX object bookmarks with live object handles for continued inspection.", FUObjectSchema(@{
            @"target": target,
            @"query": FUStringProperty(@"Optional case-insensitive match against bookmarked object class and FLEX-safe description."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target"])),
        FUTool(@"flexultra_bookmarks_add", @"Add a live object handle or stable UIKit selector to FLEX's bookmark manager.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"ui_selector": stableSelector,
        }, @[@"target"])),
        FUTool(@"flexultra_bookmarks_remove", @"Remove one FLEX bookmark by its zero-based bookmark index.", FUObjectSchema(@{
            @"target": target,
            @"index": FUIntegerProperty(@"Zero-based index from flexultra_bookmarks_list.", @0, nil),
        }, @[@"target", @"index"])),
        FUTool(@"flexultra_network_transactions", @"Read FLEX network recorder history for HTTP, WebSocket, or Firebase traffic and return live transaction handles for deeper inspection.", FUObjectSchema(@{
            @"target": target,
            @"kind": @{ @"type": @"string", @"enum": @[@"http", @"websocket", @"firebase"], @"description": @"Transaction family. Defaults to http." },
            @"query": FUStringProperty(@"Optional FLEX transaction query. Falls back to description substring matching when matchesQuery: is unavailable."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target"])),
        FUTool(@"flexultra_logs_messages", @"Read FLEX OS log history headlessly and return live FLEXSystemLogMessage handles for deeper inspection.", FUObjectSchema(@{
            @"target": target,
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against log sender and message text."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target"])),
        FUTool(@"flexultra_globals_entries", @"Enumerate FLEX global tools and shortcuts headlessly with live FLEXGlobalsEntry handles for deeper inspection.", FUObjectSchema(@{
            @"target": target,
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against section title and entry name."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target"])),
        FUTool(@"flexultra_globals_open", @"Instantiate a controller-backed FLEX global and return its pinned live UIViewController, optionally presenting it in the target app.", FUObjectSchema(@{
            @"target": target,
            @"section_index": FUIntegerProperty(@"Zero-based default FLEX globals section index.", @0, nil),
            @"row_index": FUIntegerProperty(@"Zero-based row index within the selected FLEX globals section.", @0, nil),
            @"present": FUBooleanProperty(@"Present the returned controller in FLEX. Defaults to false."),
        }, @[@"target", @"section_index", @"row_index"])),
        FUTool(@"flexultra_globals_invoke", @"Invoke an action-backed FLEX global with a real FLEXGlobalsViewController host, optionally presenting that host first.", FUObjectSchema(@{
            @"target": target,
            @"section_index": FUIntegerProperty(@"Zero-based default FLEX globals section index.", @0, nil),
            @"row_index": FUIntegerProperty(@"Zero-based row index within the selected FLEX globals section.", @0, nil),
            @"present": FUBooleanProperty(@"Present the FLEX globals host before invoking the action. Defaults to true."),
        }, @[@"target", @"section_index", @"row_index"])),
        FUTool(@"flexultra_defaults_entries", @"Enumerate the target app's UserDefaults through FLEXDefaultsContentSection, optionally including registered/system-visible defaults.", FUObjectSchema(@{
            @"target": target,
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against default keys and value descriptions."),
            @"include_registered": FUBooleanProperty(@"Include the full standardUserDefaults dictionaryRepresentation instead of only app-owned preference keys."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target"])),
        FUTool(@"flexultra_defaults_get", @"Read one key from NSUserDefaults.standardUserDefaults in the target process.", FUObjectSchema(@{
            @"target": target,
            @"key": FUStringProperty(@"Non-empty UserDefaults key."),
        }, @[@"target", @"key"])),
        FUTool(@"flexultra_defaults_set", @"Set one property-list-compatible value in NSUserDefaults.standardUserDefaults in the target process.", FUObjectSchema(@{
            @"target": target,
            @"key": FUStringProperty(@"Non-empty UserDefaults key."),
            @"value": defaultsValue,
            @"experiment_id": FUStringProperty(@"Optional active reversible experiment ID. When supplied, the previous value is recorded for rollback."),
        }, @[@"target", @"key", @"value"])),
        FUTool(@"flexultra_defaults_remove", @"Remove one key from NSUserDefaults.standardUserDefaults in the target process.", FUObjectSchema(@{
            @"target": target,
            @"key": FUStringProperty(@"Non-empty UserDefaults key."),
            @"experiment_id": FUStringProperty(@"Optional active reversible experiment ID. When supplied, the previous value is recorded for rollback."),
        }, @[@"target", @"key"])),
        FUTool(@"flexultra_keychain_items", @"Enumerate generic-password Keychain items accessible to the injected target process through FLEXKeychain.", FUObjectSchema(@{
            @"target": target,
            @"query": FUStringProperty(@"Optional case-insensitive substring matched against service, account, access group, label, and description."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target"])),
        FUTool(@"flexultra_keychain_item", @"Read one accessible generic-password Keychain item and its password data through FLEXKeychainQuery.", FUObjectSchema(@{
            @"target": target,
            @"service": FUStringProperty(@"Exact non-empty Keychain service."),
            @"account": FUStringProperty(@"Exact non-empty Keychain account."),
            @"access_group": FUStringProperty(@"Optional exact access group used to disambiguate duplicate service/account pairs."),
        }, @[@"target", @"service", @"account"])),
        FUTool(@"flexultra_database_sqlite_tables", @"Enumerate tables in a SQLite database inside the target app container or bundle through FLEXSQLiteDatabaseManager.", FUObjectSchema(@{
            @"target": target,
            @"root": filesystemRoot,
            @"path": FUStringProperty(@"Relative path to a SQLite database file."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"path"])),
        FUTool(@"flexultra_database_sqlite_columns", @"Enumerate columns for one table in a confined target-app SQLite database through FLEXSQLiteDatabaseManager.", FUObjectSchema(@{
            @"target": target,
            @"root": filesystemRoot,
            @"path": FUStringProperty(@"Relative path to a SQLite database file."),
            @"table": FUStringProperty(@"Exact non-empty SQLite table name returned by flexultra_database_sqlite_tables."),
        }, @[@"target", @"path", @"table"])),
        FUTool(@"flexultra_database_sqlite_rows", @"Read a bounded page of rows from one table in a confined target-app SQLite database through FLEXSQLiteDatabaseManager.", FUObjectSchema(@{
            @"target": target,
            @"root": filesystemRoot,
            @"path": FUStringProperty(@"Relative path to a SQLite database file."),
            @"table": FUStringProperty(@"Exact non-empty SQLite table name returned by flexultra_database_sqlite_tables."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"path", @"table"])),
        FUTool(@"flexultra_database_realm_tables", @"Enumerate tables in a Realm database inside the target app container or bundle through FLEXRealmDatabaseManager.", FUObjectSchema(@{
            @"target": target,
            @"root": filesystemRoot,
            @"path": FUStringProperty(@"Relative path to a Realm database file."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"path"])),
        FUTool(@"flexultra_database_realm_columns", @"Enumerate columns for one table in a confined target-app Realm database through FLEXRealmDatabaseManager.", FUObjectSchema(@{
            @"target": target,
            @"root": filesystemRoot,
            @"path": FUStringProperty(@"Relative path to a Realm database file."),
            @"table": FUStringProperty(@"Exact non-empty Realm table name returned by flexultra_database_realm_tables."),
        }, @[@"target", @"path", @"table"])),
        FUTool(@"flexultra_database_realm_rows", @"Read a bounded JSON-safe page of rows from one table in a confined target-app Realm database through FLEXRealmDatabaseManager.", FUObjectSchema(@{
            @"target": target,
            @"root": filesystemRoot,
            @"path": FUStringProperty(@"Relative path to a Realm database file."),
            @"table": FUStringProperty(@"Exact non-empty Realm table name returned by flexultra_database_realm_tables."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target", @"path", @"table"])),
        FUTool(@"flexultra_filesystem_list", @"List one directory inside the target app container or application bundle with deterministic pagination.", FUObjectSchema(@{
            @"target": target,
            @"root": filesystemRoot,
            @"path": FUStringProperty(@"Relative directory path. Defaults to the selected root."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
        }, @[@"target"])),
        FUTool(@"flexultra_filesystem_stat", @"Return bounded metadata for one path inside the target app container or application bundle.", FUObjectSchema(@{
            @"target": target,
            @"root": filesystemRoot,
            @"path": FUStringProperty(@"Relative path. Defaults to the selected root."),
        }, @[@"target"])),
        FUTool(@"flexultra_filesystem_read", @"Read a bounded file from the target app container or application bundle as UTF-8 text or base64.", FUObjectSchema(@{
            @"target": target,
            @"root": filesystemRoot,
            @"path": FUStringProperty(@"Relative file path."),
            @"max_bytes": FUIntegerProperty(@"Maximum bytes returned. Defaults to 65536 and is capped at 1048576.", @1, @1048576),
        }, @[@"target", @"path"])),
        FUTool(@"flexultra_filesystem_search", @"Recursively search filenames under a bounded target-app filesystem subtree without following symlink directories.", FUObjectSchema(@{
            @"target": target,
            @"root": filesystemRoot,
            @"query": FUStringProperty(@"Non-empty case-insensitive filename substring."),
            @"path": FUStringProperty(@"Relative directory to search. Defaults to the selected root."),
            @"offset": pagination[@"offset"],
            @"limit": pagination[@"limit"],
            @"max_nodes": FUIntegerProperty(@"Maximum filesystem entries visited. Defaults to 5000.", @1, @50000),
            @"max_depth": FUIntegerProperty(@"Maximum directory depth traversed. Defaults to 32.", @1, @128),
        }, @[@"target", @"query"])),
        FUTool(@"flexultra_ui_windows", @"Enumerate scene-aware UIWindow objects and register object handles.", FUObjectSchema(@{ @"target": target }, @[@"target"])),
        FUTool(@"flexultra_ui_key_window", @"Return the current key window or best visible fallback.", FUObjectSchema(@{ @"target": target }, @[@"target"])),
        FUTool(@"flexultra_ui_hierarchy", @"Return a bounded UIKit hierarchy rooted at the key window or an object handle.", FUObjectSchema(@{
            @"target": target,
            @"root": handle,
            @"max_depth": FUIntegerProperty(@"Maximum hierarchy depth.", @1, @32),
            @"max_children": FUIntegerProperty(@"Maximum children per view.", @1, @200),
            @"max_nodes": FUIntegerProperty(@"Maximum total nodes.", @1, @5000),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_find", @"Search the live UIKit view tree by text, class, accessibility identifier, or accessibility label and return object handles.", FUObjectSchema(@{
            @"target": target,
            @"root": handle,
            @"query": FUStringProperty(@"General substring matched against class, text, accessibility identifier, and accessibility label."),
            @"class": FUStringProperty(@"Class-name substring filter."),
            @"text": FUStringProperty(@"Visible text/title substring filter."),
            @"accessibility_identifier": FUStringProperty(@"Accessibility identifier substring filter."),
            @"accessibility_label": FUStringProperty(@"Accessibility label substring filter."),
            @"limit": FUIntegerProperty(@"Maximum matches.", @1, @500),
            @"max_nodes": FUIntegerProperty(@"Maximum nodes to scan.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Include hidden or fully transparent views."),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_resolve", @"Resolve a stable UIKit selector from a previous find/snapshot into a fresh live object handle.", FUObjectSchema(@{
            @"target": target,
            @"selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving semantic selectors.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve."),
        }, @[@"target", @"selector"])),
        FUTool(@"flexultra_ui_wait", @"Wait until a UIKit selector exists or is gone, using the same filters as ui.find.", FUObjectSchema(@{
            @"target": target,
            @"root": handle,
            @"query": FUStringProperty(@"General substring matched against class, text, accessibility identifier, and accessibility label."),
            @"class": FUStringProperty(@"Class-name substring filter."),
            @"text": FUStringProperty(@"Visible text/title substring filter."),
            @"accessibility_identifier": FUStringProperty(@"Accessibility identifier substring filter."),
            @"accessibility_label": FUStringProperty(@"Accessibility label substring filter."),
            @"max_nodes": FUIntegerProperty(@"Maximum nodes to scan per poll.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Include hidden or fully transparent views."),
            @"state": @{ @"type": @"string", @"enum": @[@"exists", @"gone"], @"description": @"Condition to wait for. Defaults to exists." },
            @"timeout_ms": FUIntegerProperty(@"Maximum wait in milliseconds. Defaults to 5000.", @0, @30000),
            @"poll_interval_ms": FUIntegerProperty(@"Polling interval in milliseconds. Defaults to 100.", @25, @5000),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_activate", @"Activate a UIKit view using a live handle or stable selector. Selector targets are resolved immediately before activation.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving a selector target.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve."),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_select", @"Select a UITableViewCell or UICollectionViewCell using UIKit's semantic user-selection path. Accepts a live handle or stable selector.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving a selector target.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve."),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_back", @"Pop the active UIKit navigation controller by one view controller.", FUObjectSchema(@{
            @"target": target,
            @"animated": FUBooleanProperty(@"Animate the navigation pop. Defaults to false."),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_dismiss", @"Dismiss the deepest active UIKit modal presentation.", FUObjectSchema(@{
            @"target": target,
            @"animated": FUBooleanProperty(@"Animate the dismissal. Defaults to false."),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_first_responder", @"Return the current UIKit first responder with a live object handle and stable selector, or found=false when no view is focused.", FUObjectSchema(@{
            @"target": target,
        }, @[@"target"])),
        FUTool(@"flexultra_ui_dismiss_keyboard", @"Resign the current UIKit first responder and end editing in the key window. This is idempotent when no responder is focused.", FUObjectSchema(@{
            @"target": target,
        }, @[@"target"])),
        FUTool(@"flexultra_ui_alert", @"Inspect the currently presented UIAlertController, including its actions, text fields, preferred action, and live FLEX object handles. Returns found=false when no alert is presented.", FUObjectSchema(@{
            @"target": target,
        }, @[@"target"])),
        FUTool(@"flexultra_ui_alert_action", @"Activate one action on the currently presented UIAlertController using visible UIKit controls. Provide exactly one of index or exact title.", FUObjectSchema(@{
            @"target": target,
            @"index": FUIntegerProperty(@"Zero-based action index.", @0, nil),
            @"title": FUStringProperty(@"Exact action title. Duplicate titles are rejected as ambiguous."),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_hit_test", @"Resolve a root-relative UIKit point into the live hit view and its ancestor chain without activating it.", FUObjectSchema(@{
            @"target": target,
            @"x": @{ @"type": @"number", @"description": @"Horizontal root-relative coordinate in UIKit points." },
            @"y": @{ @"type": @"number", @"description": @"Vertical root-relative coordinate in UIKit points." },
            @"root": handle,
        }, @[@"target", @"x", @"y"])),
        FUTool(@"flexultra_ui_tap", @"Hit-test a root-relative UIKit point and activate the nearest actionable view.", FUObjectSchema(@{
            @"target": target,
            @"x": @{ @"type": @"number", @"description": @"Horizontal root-relative coordinate in UIKit points." },
            @"y": @{ @"type": @"number", @"description": @"Vertical root-relative coordinate in UIKit points." },
            @"root": handle,
        }, @[@"target", @"x", @"y"])),
        FUTool(@"flexultra_ui_set_text", @"Set text on a UITextField, UITextView, or UISearchBar using a live handle or stable selector and optionally submit it.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving a selector target.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve."),
            @"text": FUStringProperty(@"Replacement text."),
            @"submit": FUBooleanProperty(@"Also trigger the control's submit/search action when supported."),
            @"notify": FUBooleanProperty(@"Emit the normal editing-change callback/notification. Defaults to true."),
            @"experiment_id": FUStringProperty(@"Optional active reversible experiment ID. When supplied, the previous text is recorded for rollback."),
        }, @[@"target", @"text"])),
        FUTool(@"flexultra_ui_set_value", @"Set the semantic value of a UISwitch, UISlider, UIStepper, or UISegmentedControl using a live handle or stable selector.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving a selector target.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve."),
            @"value": @{
                @"oneOf": @[
                    @{ @"type": @"boolean" },
                    @{ @"type": @"number" },
                ],
                @"description": @"Switch state, slider/stepper value, or segmented-control selected index.",
            },
            @"animated": FUBooleanProperty(@"Animate switch/slider updates when UIKit supports it."),
            @"notify": FUBooleanProperty(@"Emit UIControlEventValueChanged after the update. Defaults to true."),
            @"experiment_id": FUStringProperty(@"Optional active reversible experiment ID. When supplied, the previous control value is recorded for rollback."),
        }, @[@"target", @"value"])),
        FUTool(@"flexultra_ui_scroll", @"Scroll a UIScrollView by a bounded delta using a live handle or stable selector.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving a selector target.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve."),
            @"dx": @{ @"type": @"number", @"description": @"Horizontal content-offset delta in points." },
            @"dy": @{ @"type": @"number", @"description": @"Vertical content-offset delta in points." },
            @"animated": FUBooleanProperty(@"Animate the scroll."),
            @"experiment_id": FUStringProperty(@"Optional active reversible experiment ID. When supplied, the previous content offset is recorded for rollback."),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_screenshot", @"Capture the key window or a registered view as an MCP image.", FUObjectSchema(@{
            @"target": target,
            @"root": handle,
            @"format": @{ @"type": @"string", @"enum": @[@"jpeg", @"png"] },
            @"quality": @{ @"type": @"number", @"minimum": @0.1, @"maximum": @1.0, @"description": @"JPEG quality; ignored for PNG." },
            @"max_dimension": FUIntegerProperty(@"Maximum rendered width or height in pixels.", @128, @2048),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_snapshot", @"Capture a compact AI-oriented UIKit snapshot with live handles, semantic actions, and an optional MCP image.", FUObjectSchema(@{
            @"target": target,
            @"root": handle,
            @"include_image": FUBooleanProperty(@"Include a screenshot in the same response. Defaults to true."),
            @"format": @{ @"type": @"string", @"enum": @[@"jpeg", @"png"] },
            @"quality": @{ @"type": @"number", @"minimum": @0.1, @"maximum": @1.0, @"description": @"JPEG quality; ignored for PNG." },
            @"max_dimension": FUIntegerProperty(@"Maximum rendered width or height in pixels.", @128, @2048),
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan.", @1, @10000),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_snapshot_save", @"Save a bounded image-free UIKit baseline inside the target process and return a process-generation-scoped snapshot ID.", FUObjectSchema(@{
            @"target": target,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan for the saved baseline.", @1, @10000),
        }, @[@"target"])),
        FUTool(@"flexultra_ui_snapshot_diff", @"Compare the current UIKit state with a saved baseline and return bounded added, removed, moved, and semantically changed elements.", FUObjectSchema(@{
            @"target": target,
            @"snapshot_id": FUStringProperty(@"Snapshot ID returned by flexultra_ui_snapshot_save. It is valid only for the current target process generation."),
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan. Defaults to the saved baseline bound when omitted.", @1, @10000),
            @"max_changes": FUIntegerProperty(@"Maximum returned entries per diff category.", @1, @1000),
        }, @[@"target", @"snapshot_id"])),
        FUTool(@"flexultra_ui_deep_inspect", @"Inspect one UIView or UIViewController with UIKit relationships plus bounded FLEX metadata for AI investigation.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving ui_selector.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"limit": FUIntegerProperty(@"Maximum FLEX members and relationship entries returned per bounded section.", @1, @200),
            @"include_values": FUBooleanProperty(@"Include FLEX property and ivar values. Defaults to true."),
        }, @[@"target"])),
        FUTool(@"flexultra_object_inspect", @"Inspect an object through FLEXObjectExplorer using either a process-scoped handle or a stable UIKit selector.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving ui_selector.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"limit": FUIntegerProperty(@"Maximum entries per metadata category.", @1, @1000),
            @"include_values": FUBooleanProperty(@"Include property and ivar values."),
        }, @[@"target"])),
        FUTool(@"flexultra_swift_inspect", @"Inspect Swift class metadata through FlexUltra's Reflex metadata bridge using either a process-scoped handle or a stable UIKit selector. Call only when target_health.capabilities.swift_inspection is true. The safe mode returns field names and offsets without constructing FLEXSwiftMirror; Swift values, writes, mangled-type resolution, and protocol conformances remain disabled.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving ui_selector.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"limit": FUIntegerProperty(@"Maximum entries returned per Swift/FLEX metadata category.", @1, @500),
            @"include_values": FUBooleanProperty(@"Request Swift field values. Current metadata-only safe mode suppresses this request and reports value_suppression_reason."),
        }, @[@"target"])),
        FUTool(@"flexultra_investigate_screen", @"Capture one bounded AI investigation bundle: UIKit snapshot, focused deep FLEX metadata, optional Reflex Swift metadata, FLEX status, suggested next actions, and an optional MCP image.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan for snapshot and selector resolution.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"limit": FUIntegerProperty(@"Maximum FLEX members and relationship entries returned per bounded section.", @1, @200),
            @"include_values": FUBooleanProperty(@"Include FLEX property and ivar values. Defaults to true."),
            @"include_image": FUBooleanProperty(@"Include one screenshot in the same MCP result. Defaults to true."),
            @"format": @{ @"type": @"string", @"enum": @[@"jpeg", @"png"] },
            @"quality": @{ @"type": @"number", @"minimum": @0.1, @"maximum": @1.0, @"description": @"JPEG quality; ignored for PNG." },
            @"max_dimension": FUIntegerProperty(@"Maximum rendered width or height in pixels.", @128, @2048),
        }, @[@"target"])),
        FUTool(@"flexultra_investigate_element", @"Investigate one live UIKit element for AI tweak development: deep FLEX/object metadata, exact runtime class methods/properties/ivars, bounded reverse references, stable selector data, observed control/gesture hook candidates, related classes, and an optional ObjSee trace recipe. This operation runs on FlexUltra's dedicated heap worker.", FUObjectSchema(@{
            @"target": target,
            @"handle": handle,
            @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan for snapshot and selector resolution.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"limit": FUIntegerProperty(@"Maximum FLEX/runtime members returned per bounded section.", @1, @200),
            @"include_values": FUBooleanProperty(@"Include FLEX property and ivar values. Defaults to true."),
            @"include_reference_graph": FUBooleanProperty(@"Include the bounded reverse-reference graph. Defaults to true."),
            @"heap_max_depth": FUIntegerProperty(@"Maximum reverse-reference traversal depth. Defaults to 2.", @1, @5),
            @"heap_max_nodes": FUIntegerProperty(@"Maximum reverse-reference graph nodes. Defaults to 80.", @1, @500),
            @"heap_per_node_limit": FUIntegerProperty(@"Maximum incoming references expanded per graph node. Defaults to 30.", @1, @200),
            @"heap_timeout_ms": FUIntegerProperty(@"Heap graph timeout in milliseconds. Defaults to 20000.", @1, @110000),
            @"include_trace_recipe": FUBooleanProperty(@"Include a bounded ObjSee trace.start recipe for the selected runtime class. Defaults to true."),
        }, @[@"target"])),
        FUTool(@"flexultra_object_properties", @"Page FLEX property metadata for an object using either a process-scoped handle or a stable UIKit selector.", FUObjectSchema(@{
            @"target": target, @"handle": handle, @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving ui_selector.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"query": FUStringProperty(@"Case-insensitive substring matched against property name or declaring class before pagination."),
            @"offset": pagination[@"offset"], @"limit": pagination[@"limit"],
            @"include_values": FUBooleanProperty(@"Include property values."),
        }, @[@"target"])),
        FUTool(@"flexultra_object_ivars", @"Page FLEX ivar metadata for an object using either a process-scoped handle or a stable UIKit selector.", FUObjectSchema(@{
            @"target": target, @"handle": handle, @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving ui_selector.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"query": FUStringProperty(@"Case-insensitive substring matched against ivar name or declaring class before pagination."),
            @"offset": pagination[@"offset"], @"limit": pagination[@"limit"],
            @"include_values": FUBooleanProperty(@"Include ivar values."),
        }, @[@"target"])),
        FUTool(@"flexultra_object_methods", @"Page instance or class method metadata for an object using either a process-scoped handle or a stable UIKit selector. Each method includes invocation metadata describing whether object.call can invoke it and the JSON shape of its arguments and return value.", FUObjectSchema(@{
            @"target": target, @"handle": handle, @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving ui_selector.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"query": FUStringProperty(@"Case-insensitive substring matched against selector name, declaring class, or signature before pagination."),
            @"offset": pagination[@"offset"], @"limit": pagination[@"limit"],
            @"class_methods": FUBooleanProperty(@"Return class methods instead of instance methods."),
        }, @[@"target"])),
        FUTool(@"flexultra_object_get", @"Read one property or ivar through FLEX using either a process-scoped handle or a stable UIKit selector.", FUObjectSchema(@{
            @"target": target, @"handle": handle, @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving ui_selector.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"name": FUStringProperty(@"Property or ivar name."),
            @"member_kind": @{ @"type": @"string", @"enum": @[@"auto", @"property", @"ivar"] },
        }, @[@"target", @"name"])),
        FUTool(@"flexultra_object_set", @"Write one property or ivar through FLEX using either a process-scoped handle or a stable UIKit selector. Values may be null, boolean, number, string, or an existing object handle reference.", FUObjectSchema(@{
            @"target": target, @"handle": handle, @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving ui_selector.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"name": FUStringProperty(@"Property or ivar name."),
            @"member_kind": @{ @"type": @"string", @"enum": @[@"auto", @"property", @"ivar"] },
            @"value": @{
                @"description": @"JSON scalar value or an existing generation-qualified object reference shaped as {\"handle\":\"obj_0123456789abcdef0123456789abcdef_42\"}. Object references are valid only for object-valued members.",
                @"oneOf": @[
                    @{ @"type": @"null" },
                    @{ @"type": @"boolean" },
                    @{ @"type": @"number" },
                    @{ @"type": @"string" },
                    FUObjectSchema(@{ @"handle": handle }, @[@"handle"]),
                ],
            },
        }, @[@"target", @"name", @"value"])),
        FUTool(@"flexultra_object_pin", @"Retain an object handle across requests. The target may be a live handle or stable UIKit selector.", FUObjectSchema(@{
            @"target": target, @"handle": handle, @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving ui_selector.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
        }, @[@"target"])),
        FUTool(@"flexultra_object_unpin", @"Release a previously pinned object handle.", FUObjectSchema(@{
            @"target": target, @"handle": handle,
        }, @[@"target", @"handle"])),
        FUTool(@"flexultra_object_call", @"Invoke a supported Objective-C instance or class method on an object targeted by a process-scoped handle or stable UIKit selector. Object arguments use a generation-qualified handle object such as {\"handle\":\"obj_0123456789abcdef0123456789abcdef_42\"}; supported struct arguments use typed JSON objects for CGPoint, CGSize, CGRect, UIEdgeInsets, and NSRange.", FUObjectSchema(@{
            @"target": target, @"handle": handle, @"ui_selector": stableSelector,
            @"root": handle,
            @"max_nodes": FUIntegerProperty(@"Maximum UIKit nodes to scan when resolving ui_selector.", @1, @10000),
            @"include_hidden": FUBooleanProperty(@"Allow hidden or fully transparent views to resolve through ui_selector."),
            @"selector": FUStringProperty(@"Objective-C method selector, including colons. ui_selector identifies the target object."),
            @"method_kind": @{ @"type": @"string", @"enum": @[@"instance", @"class"] },
            @"arguments": @{ @"type": @"array", @"description": @"Arguments in selector order. Supports JSON scalars, generation-qualified object references, and typed CGPoint/CGSize/CGRect/UIEdgeInsets/NSRange JSON objects." },
            @"pin_result": FUBooleanProperty(@"Retain a non-nil object/class return value before the request completes so its handle survives later requests."),
        }, @[@"target", @"selector"])),
    ];

    NSMutableArray<NSDictionary<NSString *, id> *> *toolsWithGeneration = [NSMutableArray arrayWithCapacity:tools.count];
    NSSet<NSString *> *generationExcludedTools = [NSSet setWithArray:@[
        @"flexultra_target_resolve",
        @"flexultra_target_history",
    ]];
    for (NSDictionary<NSString *, id> *tool in tools) {
        NSString *name = [tool[@"name"] isKindOfClass:[NSString class]] ? tool[@"name"] : @"";
        NSDictionary *schema = [tool[@"inputSchema"] isKindOfClass:[NSDictionary class]] ? tool[@"inputSchema"] : nil;
        NSDictionary *properties = [schema[@"properties"] isKindOfClass:[NSDictionary class]] ? schema[@"properties"] : nil;
        if (!properties[@"target"] || [generationExcludedTools containsObject:name]) {
            [toolsWithGeneration addObject:tool];
            continue;
        }

        NSMutableDictionary *updatedProperties = [properties mutableCopy];
        updatedProperties[@"expected_generation"] = expectedGeneration;
        NSMutableDictionary *updatedSchema = [schema mutableCopy];
        updatedSchema[@"properties"] = updatedProperties;
        NSMutableDictionary *updatedTool = [tool mutableCopy];
        updatedTool[@"inputSchema"] = updatedSchema;
        [toolsWithGeneration addObject:updatedTool];
    }
    return toolsWithGeneration;
}

NSArray<NSString *> *FUAIRequiredMCPToolNames(void) {
    return @[
        @"flexultra_targets",
        @"flexultra_target_history",
        @"flexultra_target_resolve",
        @"flexultra_target_health",
        @"flexultra_investigate_screen",
    ];
}
