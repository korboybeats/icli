#import <Foundation/Foundation.h>

#import <arpa/inet.h>
#import <errno.h>
#import <math.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

#import "FUProtocol.h"

static void FUPrintUsage(void) {
    fprintf(stderr,
        "Usage:\n"
        "  flexultra targets [--human]\n"
        "  flexultra resolve --target <pid|bundle|process> [--human]\n"
        "  flexultra history [--target <pid|bundle|process>] [--limit N] [--human]\n"
        "  flexultra app list [--human]\n"
        "  flexultra app running [--human]\n"
        "  flexultra app frontmost [--human]\n"
        "  flexultra app launch <bundle-id> [--human]\n"
        "  flexultra app kill <bundle-id> [--force] [--human]\n"
        "  flexultra input tap <x> <y> [--human]\n"
        "  flexultra input double-tap <x> <y> [--interval N] [--human]\n"
        "  flexultra input long-press <x> <y> [--seconds N] [--human]\n"
        "  flexultra input swipe <from-x> <from-y> <to-x> <to-y> [--seconds N] [--steps N] [--human]\n"
        "  flexultra input drag <from-x> <from-y> <to-x> <to-y> [--seconds N] [--hold N] [--steps N] [--human]\n"
        "  flexultra input drag --points <json-array> [--seconds N] [--hold N] [--steps N] [--human]\n"
        "  flexultra input touch <down|move|up> <x> <y> [--normalized] [--human]\n"
        "  flexultra input touch-sequence <events-json> [--normalized] [--human]\n"
        "  flexultra ping --target <pid|bundle|process> [--human]\n"
        "  flexultra info --target <pid|bundle|process> [--human]\n"
        "  flexultra health --target <pid|bundle|process> [--human]\n"
        "  flexultra flex status|show|hide --target <target> [--human]\n"
        "  flexultra experiment begin|status|rollback|commit --target <target> [--human]\n"
        "  flexultra trace start --target <target> (--class PATTERN | --method PATTERN | --image PATTERN | --pattern CLASS METHOD)... [--exclude-class PATTERN] [--exclude-method PATTERN] [--exclude-image PATTERN] [--exclude-pattern CLASS METHOD] [--max-events N] [--max-total-events N] [--max-duration-ms N] [--arguments none|basic|class] [--human]\n"
        "  flexultra trace status --target <target> [--human]\n"
        "  flexultra trace events --target <target> [--after N] [--offset N] [--limit N] [--human]\n"
        "  flexultra trace stop --target <target> [--human]\n"
        "  flexultra runtime classes [query] --target <target> [--limit N] [--human]\n"
        "  flexultra runtime class <exact-class-name> --target <target> [--human]\n"
        "  flexultra runtime class-protocols <exact-class-name> --target <target> [--query <text>] [--direct-only] [--offset N] [--limit N] [--human]\n"
        "  flexultra runtime images [query] --target <target> [--offset N] [--limit N] [--human]\n"
        "  flexultra runtime image-classes <display-name|path> --target <target> [--query <text>] [--offset N] [--limit N] [--human]\n"
        "  flexultra runtime protocols [query] --target <target> [--offset N] [--limit N] [--human]\n"
        "  flexultra runtime protocol <exact-protocol-name> --target <target> [--query <text>] [--kind any|instance|class] [--requirement any|required|optional] [--offset N] [--limit N] [--human]\n"
        "  flexultra runtime protocol-classes <exact-protocol-name> --target <target> [--query <text>] [--offset N] [--limit N] [--human]\n"
        "  flexultra runtime methods [query] --target <target> --class-name <exact-class> [--kind any|instance|class] [--offset N] [--limit N] [--human]\n"
        "  flexultra runtime properties [query] --target <target> --class-name <exact-class> [--kind any|instance|class] [--offset N] [--limit N] [--human]\n"
        "  flexultra runtime ivars [query] --target <target> --class-name <exact-class> [--offset N] [--limit N] [--human]\n"
        "  flexultra heap snapshot --target <target> [--query <text>] [--sort name|count|size] [--offset N] [--limit N] [--timeout-ms N] [--human]\n"
        "  flexultra heap instances <exact-class-name> --target <target> [--offset N] [--limit N] [--retained] [--timeout-ms N] [--human]\n"
        "  flexultra heap subclasses <exact-class-name> --target <target> [--offset N] [--limit N] [--human]\n"
        "  flexultra heap references <handle|selector-json> --target <target> [--offset N] [--limit N] [--retained] [--timeout-ms N] [--human]\n"
        "  flexultra heap reference-graph <handle|selector-json> --target <target> [--max-depth N] [--max-nodes N] [--per-node-limit N] [--retained] [--timeout-ms N] [--human]\n"
        "  flexultra bookmarks list --target <target> [--query <text>] [--offset N] [--limit N] [--human]\n"
        "  flexultra bookmarks add <handle|selector-json> --target <target> [--human]\n"
        "  flexultra bookmarks remove <index> --target <target> [--human]\n"
        "  flexultra network transactions --target <target> [--kind http|websocket|firebase] [--query <text>] [--offset N] [--limit N] [--human]\n"
        "  flexultra logs messages --target <target> [--query <text>] [--offset N] [--limit N] [--human]\n"
        "  flexultra globals entries --target <target> [--query <text>] [--offset N] [--limit N] [--human]\n"
        "  flexultra globals open <section-index> <row-index> --target <target> [--present] [--human]\n"
        "  flexultra globals invoke <section-index> <row-index> --target <target> [--no-present] [--human]\n"
        "  flexultra defaults entries --target <target> [--query <text>] [--offset N] [--limit N] [--include-registered] [--human]\n"
        "  flexultra defaults get <key> --target <target> [--human]\n"
        "  flexultra defaults set <key> <json-value> --target <target> [--experiment <id>] [--human]\n"
        "  flexultra defaults remove <key> --target <target> [--experiment <id>] [--human]\n"
        "  flexultra keychain items [query] --target <target> [--offset N] [--limit N] [--human]\n"
        "  flexultra keychain item <service> <account> --target <target> [--access-group <group>] [--human]\n"
        "  flexultra database sqlite tables <path> --target <target> [--root home|bundle] [--offset N] [--limit N] [--human]\n"
        "  flexultra database sqlite columns <path> <table> --target <target> [--root home|bundle] [--human]\n"
        "  flexultra database sqlite rows <path> <table> --target <target> [--root home|bundle] [--offset N] [--limit N] [--human]\n"
        "  flexultra database realm tables <path> --target <target> [--root home|bundle] [--offset N] [--limit N] [--human]\n"
        "  flexultra database realm columns <path> <table> --target <target> [--root home|bundle] [--human]\n"
        "  flexultra database realm rows <path> <table> --target <target> [--root home|bundle] [--offset N] [--limit N] [--human]\n"
        "  flexultra filesystem list [path] --target <target> [--root home|bundle] [--offset N] [--limit N] [--human]\n"
        "  flexultra filesystem stat [path] --target <target> [--root home|bundle] [--human]\n"
        "  flexultra filesystem read <path> --target <target> [--root home|bundle] [--max-bytes N] [--human]\n"
        "  flexultra filesystem search <query> [path] --target <target> [--root home|bundle] [--offset N] [--limit N] [--max-nodes N] [--max-depth N] [--human]\n"
        "  flexultra ui windows --target <target> [--human]\n"
        "  flexultra ui key-window --target <target> [--human]\n"
        "  flexultra ui hierarchy [root-handle] --target <target> [--max-depth N] [--max-children N] [--max-nodes N] [--human]\n"
        "  flexultra ui find [query] --target <target> [--root <handle>] [--class-name <class>] [--text <text>] [--identifier <id>] [--label <label>] [--limit N] [--max-nodes N] [--include-hidden] [--human]\n"
        "  flexultra ui resolve <selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--human]\n"
        "  flexultra ui wait [query] --target <target> [--root <handle>] [--class-name <class>] [--text <text>] [--identifier <id>] [--label <label>] [--max-nodes N] [--include-hidden] [--state exists|gone] [--timeout-ms N] [--poll-interval-ms N] [--human]\n"
        "  flexultra ui activate <handle|selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--human]\n"
        "  flexultra ui select <handle|selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--human]\n"
        "  flexultra ui back --target <target> [--animated] [--human]\n"
        "  flexultra ui dismiss --target <target> [--animated] [--human]\n"
        "  flexultra ui first-responder --target <target> [--human]\n"
        "  flexultra ui dismiss-keyboard --target <target> [--human]\n"
        "  flexultra ui alert --target <target> [--human]\n"
        "  flexultra ui alert-action (--index N | --title <exact-title>) --target <target> [--human]\n"
        "  flexultra ui hit-test <x> <y> --target <target> [--root <handle>] [--human]\n"
        "  flexultra ui tap <x> <y> --target <target> [--root <handle>] [--human]\n"
        "  flexultra ui set-text <handle|selector-json> <text> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--submit] [--no-notify] [--experiment <id>] [--human]\n"
        "  flexultra ui set-value <handle|selector-json> <json-boolean-or-number> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--animated] [--no-notify] [--experiment <id>] [--human]\n"
        "  flexultra ui scroll <handle|selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--dx N] [--dy N] [--animated] [--experiment <id>] [--human]\n"
        "  flexultra ui screenshot [root-handle] --target <target> [--format jpeg|png] [--quality 0.1-1.0] [--max-dimension N] [--human]\n"
        "  flexultra ui snapshot [root-handle] --target <target> [--format jpeg|png] [--quality 0.1-1.0] [--max-dimension N] [--max-nodes N] [--no-image] [--human]\n"
        "  flexultra ui snapshot-save [root-handle] --target <target> [--max-nodes N] [--human]\n"
        "  flexultra ui snapshot-diff <snapshot-id> --target <target> [--root <handle>] [--max-nodes N] [--max-changes N] [--human]\n"
        "  flexultra ui deep-inspect <handle|selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--limit N] [--no-values] [--human]\n"
        "  flexultra swift inspect <handle|selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--limit N] [--no-values] [--human]\n"
        "  flexultra investigate screen [handle|selector-json] --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--limit N] [--no-values] [--no-image] [--format jpeg|png] [--quality 0.1-1.0] [--max-dimension N] [--human]\n"
        "  flexultra investigate element [handle|selector-json] --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--limit N] [--no-values] [--no-reference-graph] [--heap-max-depth N] [--heap-max-nodes N] [--heap-per-node-limit N] [--heap-timeout-ms N] [--no-trace-recipe] [--human]\n"
        "  flexultra object inspect <handle|selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--limit N] [--no-values] [--human]\n"
        "  flexultra object properties <handle|selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--query <text>] [--offset N] [--limit N] [--no-values] [--human]\n"
        "  flexultra object ivars <handle|selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--query <text>] [--offset N] [--limit N] [--no-values] [--human]\n"
        "  flexultra object methods <handle|selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--query <text>] [--offset N] [--limit N] [--class] [--human]\n"
        "  flexultra object get <handle|selector-json> <name> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--kind auto|property|ivar] [--human]\n"
        "  flexultra object set <handle|selector-json> <name> <json-scalar|@obj_<generation>_<counter>> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--kind auto|property|ivar] [--human]\n"
        "  flexultra object pin <handle|selector-json> --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--human]\n"
        "  flexultra object unpin <handle> --target <target> [--human]\n"
        "  flexultra object call <handle|selector-json> <selector> [args...] --target <target> [--root <handle>] [--max-nodes N] [--include-hidden] [--class] [--pin-result] [--human]\n"
        "\nTarget-routed commands accept --expected-generation <generation> to fail closed if the selected process changed after discovery.\n"
    );
}

static int FUConnect(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

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

static NSString *FUValueAfter(NSArray<NSString *> *args, NSString *flag) {
    NSUInteger index = [args indexOfObject:flag];
    if (index == NSNotFound || index + 1 >= args.count) {
        return nil;
    }
    return args[index + 1];
}

static NSArray<NSString *> *FUValuesAfter(NSArray<NSString *> *args, NSString *flag) {
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (NSUInteger index = 0; index + 1 < args.count; index++) {
        if ([args[index] isEqualToString:flag]) {
            [values addObject:args[index + 1]];
            index++;
        }
    }
    return values;
}

static NSArray<NSDictionary *> *FUTracePatternsAfter(NSArray<NSString *> *args, NSString *flag, BOOL *valid) {
    NSMutableArray<NSDictionary *> *patterns = [NSMutableArray array];
    BOOL parsed = YES;
    for (NSUInteger index = 0; index < args.count; index++) {
        if (![args[index] isEqualToString:flag]) continue;
        if (index + 2 >= args.count || [args[index + 1] hasPrefix:@"--"] || [args[index + 2] hasPrefix:@"--"]) {
            parsed = NO;
            break;
        }
        [patterns addObject:@{ @"class": args[index + 1], @"method": args[index + 2] }];
        index += 2;
    }
    if (valid) *valid = parsed;
    return parsed ? patterns : nil;
}

static BOOL FUParseFiniteDouble(NSString *text, double *value) {
    if (text.length == 0) {
        return NO;
    }
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double parsed = 0.0;
    if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || !isfinite(parsed)) {
        return NO;
    }
    if (value) {
        *value = parsed;
    }
    return YES;
}

static BOOL FUParseNonnegativeInteger(NSString *text, NSInteger *value) {
    if (text.length == 0) {
        return NO;
    }
    NSScanner *scanner = [NSScanner scannerWithString:text];
    NSInteger parsed = 0;
    if (![scanner scanInteger:&parsed] || !scanner.isAtEnd || parsed < 0) {
        return NO;
    }
    if (value) {
        *value = parsed;
    }
    return YES;
}

static id FUParseScalar(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
        if ([parsed isKindOfClass:[NSString class]] || [parsed isKindOfClass:[NSNumber class]] || parsed == NSNull.null) {
            return parsed;
        }
    }
    return text;
}

static id FUParseCallArgument(NSString *text) {
    if ([text hasPrefix:@"@obj_"] && text.length > 1) {
        return @{ @"handle": [text substringFromIndex:1] };
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
        if (parsed) {
            return parsed;
        }
    }
    return text;
}

static NSDictionary *FUParseJSONObject(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}

static NSArray *FUParseJSONArray(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:[NSArray class]] ? parsed : nil;
}

static BOOL FUAttachUIActionTarget(NSMutableDictionary *request, NSString *targetText) {
    if (targetText.length == 0) return NO;
    if ([targetText hasPrefix:@"{"]) {
        NSDictionary *selector = FUParseJSONObject(targetText);
        if (!selector) return NO;
        request[@"selector"] = selector;
        return YES;
    }
    request[@"handle"] = targetText;
    return YES;
}

static BOOL FUAttachObjectTarget(NSMutableDictionary *request, NSString *targetText) {
    if (targetText.length == 0) return NO;
    if ([targetText hasPrefix:@"{"]) {
        NSDictionary *selector = FUParseJSONObject(targetText);
        if (!selector) return NO;
        request[@"ui_selector"] = selector;
        return YES;
    }
    request[@"handle"] = targetText;
    return YES;
}

static void FUPrintJSON(NSDictionary *response) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

static void FUPrintHuman(NSString *op, NSDictionary *response) {
    if (![response[@"ok"] boolValue]) {
        NSDictionary *error = response[@"error"];
        fprintf(stderr, "error: %s\n", [error[@"message"] UTF8String]);
        NSString *recoveryHint = [error[@"recovery_hint"] isKindOfClass:[NSString class]] ? error[@"recovery_hint"] : nil;
        NSString *recommendedAction = [error[@"recommended_action"] isKindOfClass:[NSString class]] ? error[@"recommended_action"] : nil;
        NSArray *suggestedOperations = [error[@"suggested_operations"] isKindOfClass:[NSArray class]] ? error[@"suggested_operations"] : nil;
        if (recoveryHint.length) fprintf(stderr, "recovery: %s\n", recoveryHint.UTF8String);
        if (recommendedAction.length) fprintf(stderr, "next: %s\n", recommendedAction.UTF8String);
        if (suggestedOperations.count) {
            NSString *joined = [suggestedOperations componentsJoinedByString:@", "];
            fprintf(stderr, "suggested operations: %s\n", joined.UTF8String);
        }
        return;
    }

    NSDictionary *result = response[@"result"];
    if ([op isEqualToString:@"targets"]) {
        NSArray *targets = result[@"targets"];
        if (targets.count == 0) {
            printf("No FlexUltra agents connected.\n");
            return;
        }
        for (NSDictionary *target in targets) {
            NSString *bundle = [target[@"bundle_id"] isKindOfClass:[NSString class]] ? target[@"bundle_id"] : @"-";
            NSString *buildStatus = [target[@"build_status"] isKindOfClass:[NSString class]] ? target[@"build_status"] : @"unknown";
            printf("%-7s  %-28s  %-8s  %s\n", [[target[@"pid"] stringValue] UTF8String], [target[@"process"] UTF8String], buildStatus.UTF8String, bundle.UTF8String);
        }
        return;
    }

    if ([op isEqualToString:@"target.resolve"]) {
        NSDictionary *target = result[@"target"];
        NSString *bundle = [target[@"bundle_id"] isKindOfClass:[NSString class]] ? target[@"bundle_id"] : @"-";
        printf("%s -> pid=%s process=%s bundle=%s match=%s build=%s\n",
            [result[@"query"] UTF8String],
            [[target[@"pid"] stringValue] UTF8String],
            [target[@"process"] UTF8String],
            bundle.UTF8String,
            [result[@"match_kind"] UTF8String],
            [target[@"build_status"] UTF8String]);
        return;
    }

    if ([op isEqualToString:@"target.history"]) {
        NSString *state = [result[@"state"] isKindOfClass:[NSString class]] ? result[@"state"] : @"unknown";
        NSString *query = [result[@"query"] isKindOfClass:[NSString class]] ? result[@"query"] : @"*";
        printf("target=%s state=%s retained=%s dropped=%s reconnects=%s\n",
            query.UTF8String,
            state.UTF8String,
            [[result[@"retained_match_count"] stringValue] UTF8String],
            [[result[@"history_dropped"] stringValue] UTF8String],
            [[result[@"reconnect_count_in_retained_history"] stringValue] UTF8String]);
        NSString *action = [result[@"recommended_action"] isKindOfClass:[NSString class]] ? result[@"recommended_action"] : nil;
        if (action.length) printf("action: %s\n", action.UTF8String);
        for (NSDictionary *event in result[@"events"]) {
            NSString *bundle = [event[@"bundle_id"] isKindOfClass:[NSString class]] ? event[@"bundle_id"] : @"-";
            printf("%s  pid=%s  %-12s  %-8s  seq=%s  %s\n",
                [[event[@"event_at_unix_ms"] stringValue] UTF8String],
                [[event[@"pid"] stringValue] UTF8String],
                [event[@"event"] UTF8String],
                [event[@"build_status"] UTF8String],
                [[event[@"connection_sequence"] stringValue] UTF8String],
                bundle.UTF8String);
        }
        return;
    }

    if ([op isEqualToString:@"runtime.classes"]) {
        for (NSString *name in result[@"classes"]) {
            printf("%s\n", name.UTF8String);
        }
        if ([result[@"truncated"] boolValue]) {
            fprintf(stderr, "Showing %lu of %lu matches.\n", (unsigned long)[result[@"classes"] count], (unsigned long)[result[@"total"] unsignedIntegerValue]);
        }
        return;
    }
    if ([op isEqualToString:@"runtime.images"]) {
        for (NSDictionary *image in result[@"images"]) {
            printf("%-5s  %-42s  %s\n",
                [[image[@"index"] stringValue] UTF8String],
                [image[@"name"] UTF8String],
                [image[@"path"] UTF8String]);
        }
        return;
    }
    if ([op isEqualToString:@"runtime.image_classes"]) {
        for (NSString *name in result[@"classes"]) printf("%s\n", name.UTF8String);
        return;
    }
    if ([op isEqualToString:@"runtime.protocols"]) {
        for (NSString *name in result[@"protocols"]) printf("%s\n", name.UTF8String);
        return;
    }
    if ([op isEqualToString:@"runtime.class_protocols"]) {
        for (NSDictionary *protocol in result[@"protocols"]) {
            printf("%-28s  %-9s  %s\n",
                [protocol[@"declaring_class"] UTF8String],
                [protocol[@"inherited"] boolValue] ? "inherited" : "direct",
                [protocol[@"name"] UTF8String]);
        }
        return;
    }
    if ([op isEqualToString:@"runtime.protocol"]) {
        printf("protocol %s\n", [result[@"name"] UTF8String]);
        NSArray *adopted = result[@"adopted_protocols"];
        if ([adopted count]) printf("adopts   %s\n", [[adopted componentsJoinedByString:@", "] UTF8String]);
        for (NSDictionary *method in result[@"methods"]) {
            printf("%-8s  %-8s  %s\n",
                [method[@"requirement"] UTF8String],
                [method[@"method_kind"] UTF8String],
                [method[@"name"] UTF8String]);
        }
        return;
    }
    if ([op isEqualToString:@"runtime.protocol_classes"]) {
        for (NSDictionary *cls in result[@"classes"]) {
            id superclass = cls[@"superclass"];
            id image = cls[@"image"];
            printf("%-36s  %-28s  %s\n",
                [cls[@"name"] UTF8String],
                superclass == NSNull.null ? "-" : [superclass UTF8String],
                image == NSNull.null ? "-" : [image UTF8String]);
        }
        return;
    }
    if ([op isEqualToString:@"runtime.methods"]) {
        for (NSDictionary *method in result[@"methods"]) {
            printf("%-8s  %s\n",
                [method[@"method_kind"] UTF8String],
                [method[@"name"] UTF8String]);
        }
        return;
    }
    if ([op isEqualToString:@"runtime.properties"]) {
        for (NSDictionary *property in result[@"properties"]) {
            printf("%-8s  %-28s  %s\n",
                [property[@"property_kind"] UTF8String],
                [property[@"declaring_class"] UTF8String],
                [property[@"name"] UTF8String]);
        }
        return;
    }
    if ([op isEqualToString:@"runtime.ivars"]) {
        for (NSDictionary *ivar in result[@"ivars"]) {
            printf("%-28s  %s\n",
                [ivar[@"declaring_class"] UTF8String],
                [ivar[@"name"] UTF8String]);
        }
        return;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            FUPrintUsage();
            return 2;
        }

        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            [args addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        BOOL human = [args containsObject:@"--human"];
        NSString *target = FUValueAfter(args, @"--target") ?: FUValueAfter(args, @"-t");
        NSString *expectedGeneration = FUValueAfter(args, @"--expected-generation");
        NSString *limitString = FUValueAfter(args, @"--limit");
        NSString *offsetString = FUValueAfter(args, @"--offset");
        NSString *queryString = FUValueAfter(args, @"--query");
        NSString *sortString = FUValueAfter(args, @"--sort");
        NSString *memberKind = FUValueAfter(args, @"--kind");
        NSString *requirementString = FUValueAfter(args, @"--requirement");
        NSString *networkKindString = FUValueAfter(args, @"--kind");
        NSString *rootHandle = FUValueAfter(args, @"--root");
        NSString *classNameFilter = FUValueAfter(args, @"--class-name");
        NSString *textFilter = FUValueAfter(args, @"--text");
        NSString *identifierFilter = FUValueAfter(args, @"--identifier");
        NSString *labelFilter = FUValueAfter(args, @"--label");
        NSString *maxDepthString = FUValueAfter(args, @"--max-depth");
        NSString *maxChildrenString = FUValueAfter(args, @"--max-children");
        NSString *maxNodesString = FUValueAfter(args, @"--max-nodes");
        NSString *perNodeLimitString = FUValueAfter(args, @"--per-node-limit");
        NSString *maxBytesString = FUValueAfter(args, @"--max-bytes");
        NSString *dxString = FUValueAfter(args, @"--dx");
        NSString *dyString = FUValueAfter(args, @"--dy");
        NSString *formatString = FUValueAfter(args, @"--format");
        NSString *qualityString = FUValueAfter(args, @"--quality");
        NSString *maxDimensionString = FUValueAfter(args, @"--max-dimension");
        NSString *maxChangesString = FUValueAfter(args, @"--max-changes");
        NSString *stateString = FUValueAfter(args, @"--state");
        NSString *timeoutMSString = FUValueAfter(args, @"--timeout-ms");
        NSString *pollIntervalMSString = FUValueAfter(args, @"--poll-interval-ms");
        NSString *alertIndexString = FUValueAfter(args, @"--index");
        NSString *alertTitleString = FUValueAfter(args, @"--title");
        NSString *intervalString = FUValueAfter(args, @"--interval");
        NSString *secondsString = FUValueAfter(args, @"--seconds");
        NSString *stepsString = FUValueAfter(args, @"--steps");
        NSString *holdString = FUValueAfter(args, @"--hold");
        NSString *pointsString = FUValueAfter(args, @"--points");
        NSString *traceMaxEventsString = FUValueAfter(args, @"--max-events");
        NSString *traceMaxTotalEventsString = FUValueAfter(args, @"--max-total-events");
        NSString *traceMaxDurationMsString = FUValueAfter(args, @"--max-duration-ms");
        NSString *traceArgumentDetail = FUValueAfter(args, @"--arguments");
        NSString *traceAfterString = FUValueAfter(args, @"--after");
        NSString *experimentID = FUValueAfter(args, @"--experiment");
        NSString *heapMaxDepthString = FUValueAfter(args, @"--heap-max-depth");
        NSString *heapMaxNodesString = FUValueAfter(args, @"--heap-max-nodes");
        NSString *heapPerNodeLimitString = FUValueAfter(args, @"--heap-per-node-limit");
        NSString *heapTimeoutMSString = FUValueAfter(args, @"--heap-timeout-ms");

        NSString *op = nil;
        NSMutableDictionary *request = [@{
            @"v": @(FUProtocolVersion),
            @"kind": @"request",
            @"id": NSUUID.UUID.UUIDString,
        } mutableCopy];

        NSString *command = args.firstObject;
        if ([command isEqualToString:@"targets"]) {
            op = @"targets";
        } else if ([command isEqualToString:@"resolve"] && target.length) {
            op = @"target.resolve";
        } else if ([command isEqualToString:@"history"]) {
            NSInteger historyLimit = 0;
            BOOL valid = !limitString.length
                || (FUParseNonnegativeInteger(limitString, &historyLimit) && historyLimit >= 1 && historyLimit <= 128);
            if (valid) {
                op = @"target.history";
                if (limitString.length) request[@"limit"] = @(historyLimit);
            }
        } else if ([command isEqualToString:@"app"] && args.count >= 2) {
            NSString *action = args[1];
            if ([@[@"list", @"running", @"frontmost"] containsObject:action]) {
                op = [@"app." stringByAppendingString:action];
            } else if ([action isEqualToString:@"launch"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"app.launch";
                request[@"bundle_id"] = args[2];
            } else if ([action isEqualToString:@"kill"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"app.kill";
                request[@"bundle_id"] = args[2];
                if ([args containsObject:@"--force"]) {
                    request[@"force"] = @YES;
                }
            }
        } else if ([command isEqualToString:@"input"] && args.count >= 2) {
            NSString *action = args[1];
            if (([action isEqualToString:@"tap"] || [action isEqualToString:@"double-tap"] || [action isEqualToString:@"long-press"]) && args.count >= 4) {
                double x = 0.0, y = 0.0;
                BOOL valid = FUParseFiniteDouble(args[2], &x) && FUParseFiniteDouble(args[3], &y) && x >= 0.0 && y >= 0.0;
                if (valid && [action isEqualToString:@"double-tap"] && intervalString) {
                    double interval = 0.0;
                    valid = FUParseFiniteDouble(intervalString, &interval) && interval >= 0.0;
                    if (valid) request[@"interval"] = @(interval);
                }
                if (valid && [action isEqualToString:@"long-press"] && secondsString) {
                    double seconds = 0.0;
                    valid = FUParseFiniteDouble(secondsString, &seconds) && seconds >= 0.0;
                    if (valid) request[@"seconds"] = @(seconds);
                }
                if (valid) {
                    op = [action isEqualToString:@"tap"] ? @"input.tap" :
                        ([action isEqualToString:@"double-tap"] ? @"input.double_tap" : @"input.long_press");
                    request[@"x"] = @(x);
                    request[@"y"] = @(y);
                }
            } else if ([action isEqualToString:@"swipe"] && args.count >= 6) {
                double fromX = 0.0, fromY = 0.0, toX = 0.0, toY = 0.0;
                BOOL valid =
                    FUParseFiniteDouble(args[2], &fromX) && FUParseFiniteDouble(args[3], &fromY) &&
                    FUParseFiniteDouble(args[4], &toX) && FUParseFiniteDouble(args[5], &toY) &&
                    fromX >= 0.0 && fromY >= 0.0 && toX >= 0.0 && toY >= 0.0;
                if (valid && secondsString) {
                    double seconds = 0.0;
                    valid = FUParseFiniteDouble(secondsString, &seconds) && seconds >= 0.0;
                    if (valid) request[@"seconds"] = @(seconds);
                }
                if (valid && stepsString) {
                    NSInteger steps = 0;
                    valid = FUParseNonnegativeInteger(stepsString, &steps) && steps > 0;
                    if (valid) request[@"steps"] = @(steps);
                }
                if (valid) {
                    op = @"input.swipe";
                    request[@"from_x"] = @(fromX);
                    request[@"from_y"] = @(fromY);
                    request[@"to_x"] = @(toX);
                    request[@"to_y"] = @(toY);
                }
            } else if ([action isEqualToString:@"drag"]) {
                BOOL valid = YES;
                if (pointsString) {
                    NSArray *points = FUParseJSONArray(pointsString);
                    valid = points != nil;
                    if (valid) request[@"points"] = points;
                } else if (args.count >= 6) {
                    double fromX = 0.0, fromY = 0.0, toX = 0.0, toY = 0.0;
                    valid =
                        FUParseFiniteDouble(args[2], &fromX) && FUParseFiniteDouble(args[3], &fromY) &&
                        FUParseFiniteDouble(args[4], &toX) && FUParseFiniteDouble(args[5], &toY) &&
                        fromX >= 0.0 && fromY >= 0.0 && toX >= 0.0 && toY >= 0.0;
                    if (valid) {
                        request[@"from_x"] = @(fromX);
                        request[@"from_y"] = @(fromY);
                        request[@"to_x"] = @(toX);
                        request[@"to_y"] = @(toY);
                    }
                } else {
                    valid = NO;
                }
                for (NSArray<NSString *> *pair in @[@[@"seconds", secondsString ?: @""], @[@"hold", holdString ?: @""]]) {
                    if (!valid || [pair[1] length] == 0) continue;
                    double number = 0.0;
                    valid = FUParseFiniteDouble(pair[1], &number) && number >= 0.0;
                    if (valid) request[pair[0]] = @(number);
                }
                if (valid && stepsString) {
                    NSInteger steps = 0;
                    valid = FUParseNonnegativeInteger(stepsString, &steps) && steps > 0;
                    if (valid) request[@"steps"] = @(steps);
                }
                if (valid) op = @"input.drag";
            } else if ([action isEqualToString:@"touch"] && args.count >= 5) {
                NSString *phase = args[2];
                double x = 0.0, y = 0.0;
                BOOL valid = [@[@"down", @"move", @"up"] containsObject:phase] &&
                    FUParseFiniteDouble(args[3], &x) && FUParseFiniteDouble(args[4], &y) && x >= 0.0 && y >= 0.0;
                if (valid) {
                    op = @"input.touch";
                    request[@"phase"] = phase;
                    request[@"x"] = @(x);
                    request[@"y"] = @(y);
                    if ([args containsObject:@"--normalized"]) request[@"normalized"] = @YES;
                }
            } else if ([action isEqualToString:@"touch-sequence"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                NSArray *events = FUParseJSONArray(args[2]);
                if (events) {
                    op = @"input.touch_sequence";
                    request[@"events"] = events;
                    if ([args containsObject:@"--normalized"]) request[@"normalized"] = @YES;
                }
            }
        } else if ([command isEqualToString:@"ping"]) {
            op = @"ping";
        } else if ([command isEqualToString:@"info"]) {
            op = @"agent.info";
        } else if ([command isEqualToString:@"health"]) {
            op = @"target.health";
        } else if ([command isEqualToString:@"flex"] && args.count >= 2) {
            NSString *action = args[1];
            if ([@[@"status", @"show", @"hide"] containsObject:action]) {
                op = [@"flex." stringByAppendingString:action];
            }
        } else if ([command isEqualToString:@"experiment"] && args.count >= 2) {
            NSString *action = args[1];
            if ([@[@"begin", @"status", @"rollback", @"commit"] containsObject:action]) {
                op = [@"experiment." stringByAppendingString:action];
            }
        } else if ([command isEqualToString:@"trace"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"start"]) {
                NSArray *includeClasses = FUValuesAfter(args, @"--class");
                NSArray *includeMethods = FUValuesAfter(args, @"--method");
                NSArray *includeImages = FUValuesAfter(args, @"--image");
                NSArray *excludeClasses = FUValuesAfter(args, @"--exclude-class");
                NSArray *excludeMethods = FUValuesAfter(args, @"--exclude-method");
                NSArray *excludeImages = FUValuesAfter(args, @"--exclude-image");
                BOOL includePatternsValid = YES;
                BOOL excludePatternsValid = YES;
                NSArray *includePatterns = FUTracePatternsAfter(args, @"--pattern", &includePatternsValid);
                NSArray *excludePatterns = FUTracePatternsAfter(args, @"--exclude-pattern", &excludePatternsValid);
                NSUInteger includeCount = includeClasses.count + includeMethods.count + includeImages.count + includePatterns.count;
                BOOL valid = includePatternsValid && excludePatternsValid && includeCount > 0;
                if (traceArgumentDetail.length && ![@[@"none", @"basic", @"class"] containsObject:traceArgumentDetail]) valid = NO;
                NSInteger maxEvents = 0;
                if (traceMaxEventsString.length && (!FUParseNonnegativeInteger(traceMaxEventsString, &maxEvents) || maxEvents == 0)) valid = NO;
                NSInteger maxTotalEvents = 0;
                if (traceMaxTotalEventsString.length && (!FUParseNonnegativeInteger(traceMaxTotalEventsString, &maxTotalEvents) || maxTotalEvents == 0)) valid = NO;
                NSInteger maxDurationMs = 0;
                if (traceMaxDurationMsString.length && (!FUParseNonnegativeInteger(traceMaxDurationMsString, &maxDurationMs) || maxDurationMs == 0)) valid = NO;
                if (valid) {
                    op = @"trace.start";
                    if (includeClasses.count) request[@"include_classes"] = includeClasses;
                    if (includeMethods.count) request[@"include_methods"] = includeMethods;
                    if (includeImages.count) request[@"include_images"] = includeImages;
                    if (includePatterns.count) request[@"include_patterns"] = includePatterns;
                    if (excludeClasses.count) request[@"exclude_classes"] = excludeClasses;
                    if (excludeMethods.count) request[@"exclude_methods"] = excludeMethods;
                    if (excludeImages.count) request[@"exclude_images"] = excludeImages;
                    if (excludePatterns.count) request[@"exclude_patterns"] = excludePatterns;
                    if (traceMaxEventsString.length) request[@"max_events"] = @(maxEvents);
                    if (traceMaxTotalEventsString.length) request[@"max_total_events"] = @(maxTotalEvents);
                    if (traceMaxDurationMsString.length) request[@"max_duration_ms"] = @(maxDurationMs);
                    if (traceArgumentDetail.length) request[@"argument_detail"] = traceArgumentDetail;
                }
            } else if ([action isEqualToString:@"status"]) {
                op = @"trace.status";
            } else if ([action isEqualToString:@"events"]) {
                BOOL valid = YES;
                NSInteger afterSequence = 0;
                NSInteger traceOffset = 0;
                NSInteger traceLimit = 0;
                if (traceAfterString.length && !FUParseNonnegativeInteger(traceAfterString, &afterSequence)) valid = NO;
                if (offsetString.length && !FUParseNonnegativeInteger(offsetString, &traceOffset)) valid = NO;
                if (limitString.length && (!FUParseNonnegativeInteger(limitString, &traceLimit) || traceLimit == 0)) valid = NO;
                if (valid) {
                    op = @"trace.events";
                    if (traceAfterString.length) request[@"after_sequence"] = @(afterSequence);
                    if (offsetString.length) request[@"offset"] = @(traceOffset);
                    if (limitString.length) request[@"limit"] = @(traceLimit);
                }
            } else if ([action isEqualToString:@"stop"]) {
                op = @"trace.stop";
            }
        } else if ([command isEqualToString:@"runtime"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"classes"]) {
                op = @"runtime.classes";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                    request[@"query"] = args[2];
                }
                if (limitString.integerValue > 0) {
                    request[@"limit"] = @([limitString integerValue]);
                }
            } else if ([action isEqualToString:@"class"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"runtime.class";
                request[@"name"] = args[2];
            } else if ([action isEqualToString:@"class-protocols"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"runtime.class_protocols";
                request[@"class_name"] = args[2];
                if (queryString.length) request[@"query"] = queryString;
                request[@"include_inherited"] = @((BOOL)![args containsObject:@"--direct-only"]);
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"images"]) {
                op = @"runtime.images";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) request[@"query"] = args[2];
                else if (queryString.length) request[@"query"] = queryString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"image-classes"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"runtime.image_classes";
                request[@"image"] = args[2];
                if (queryString.length) request[@"query"] = queryString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"protocols"]) {
                op = @"runtime.protocols";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) request[@"query"] = args[2];
                else if (queryString.length) request[@"query"] = queryString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"protocol"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"runtime.protocol";
                request[@"name"] = args[2];
                if (queryString.length) request[@"query"] = queryString;
                if (memberKind.length) request[@"method_kind"] = memberKind;
                if (requirementString.length) request[@"requirement"] = requirementString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"protocol-classes"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"runtime.protocol_classes";
                request[@"name"] = args[2];
                if (queryString.length) request[@"query"] = queryString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"methods"]) {
                op = @"runtime.methods";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) request[@"query"] = args[2];
                else if (queryString.length) request[@"query"] = queryString;
                if (classNameFilter.length) request[@"class_name"] = classNameFilter;
                if (memberKind.length) request[@"method_kind"] = memberKind;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"properties"]) {
                op = @"runtime.properties";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) request[@"query"] = args[2];
                else if (queryString.length) request[@"query"] = queryString;
                if (classNameFilter.length) request[@"class_name"] = classNameFilter;
                if (memberKind.length) request[@"property_kind"] = memberKind;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"ivars"]) {
                op = @"runtime.ivars";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) request[@"query"] = args[2];
                else if (queryString.length) request[@"query"] = queryString;
                if (classNameFilter.length) request[@"class_name"] = classNameFilter;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            }
        } else if ([command isEqualToString:@"heap"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"snapshot"]) {
                op = @"heap.snapshot";
                if (queryString.length) request[@"query"] = queryString;
                if (sortString.length) request[@"sort"] = sortString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
                if (timeoutMSString.length) request[@"timeout_ms"] = @([timeoutMSString integerValue]);
            } else if ([action isEqualToString:@"instances"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"heap.instances";
                request[@"name"] = args[2];
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
                if ([args containsObject:@"--retained"]) request[@"retained"] = @YES;
                if (timeoutMSString.length) request[@"timeout_ms"] = @([timeoutMSString integerValue]);
            } else if ([action isEqualToString:@"subclasses"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"heap.subclasses";
                request[@"name"] = args[2];
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"references"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                if (FUAttachObjectTarget(request, args[2])) {
                    op = @"heap.references";
                    if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                    if (limitString.length) request[@"limit"] = @([limitString integerValue]);
                    if ([args containsObject:@"--retained"]) request[@"retained"] = @YES;
                    if (timeoutMSString.length) request[@"timeout_ms"] = @([timeoutMSString integerValue]);
                }
            } else if ([action isEqualToString:@"reference-graph"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                if (FUAttachObjectTarget(request, args[2])) {
                    op = @"heap.reference_graph";
                    if (maxDepthString.length) request[@"max_depth"] = @([maxDepthString integerValue]);
                    if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                    if (perNodeLimitString.length) request[@"per_node_limit"] = @([perNodeLimitString integerValue]);
                    if ([args containsObject:@"--retained"]) request[@"retained"] = @YES;
                    if (timeoutMSString.length) request[@"timeout_ms"] = @([timeoutMSString integerValue]);
                }
            }
        } else if ([command isEqualToString:@"bookmarks"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"list"]) {
                op = @"bookmarks.list";
                if (queryString.length) request[@"query"] = queryString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"add"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                if (FUAttachObjectTarget(request, args[2])) {
                    op = @"bookmarks.add";
                }
            } else if ([action isEqualToString:@"remove"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                NSInteger bookmarkIndex = 0;
                if (FUParseNonnegativeInteger(args[2], &bookmarkIndex)) {
                    op = @"bookmarks.remove";
                    request[@"index"] = @(bookmarkIndex);
                }
            }
        } else if ([command isEqualToString:@"network"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"transactions"]) {
                op = @"network.transactions";
                if (networkKindString.length) request[@"network_kind"] = networkKindString;
                if (queryString.length) request[@"query"] = queryString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            }
        } else if ([command isEqualToString:@"logs"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"messages"]) {
                op = @"logs.messages";
                if (queryString.length) request[@"query"] = queryString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            }
        } else if ([command isEqualToString:@"globals"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"entries"]) {
                op = @"globals.entries";
                if (queryString.length) request[@"query"] = queryString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if (([action isEqualToString:@"open"] || [action isEqualToString:@"invoke"]) && args.count >= 4) {
                NSInteger sectionIndex = 0;
                NSInteger rowIndex = 0;
                if (FUParseNonnegativeInteger(args[2], &sectionIndex) && FUParseNonnegativeInteger(args[3], &rowIndex)) {
                    op = [action isEqualToString:@"open"] ? @"globals.open" : @"globals.invoke";
                    request[@"section_index"] = @(sectionIndex);
                    request[@"row_index"] = @(rowIndex);
                    if ([action isEqualToString:@"open"] && [args containsObject:@"--present"]) request[@"present"] = @YES;
                    if ([action isEqualToString:@"invoke"] && [args containsObject:@"--no-present"]) request[@"present"] = @NO;
                }
            }
        } else if ([command isEqualToString:@"defaults"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"entries"]) {
                op = @"defaults.entries";
                if (queryString.length) request[@"query"] = queryString;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
                if ([args containsObject:@"--include-registered"]) request[@"include_registered"] = @YES;
            } else if ([action isEqualToString:@"get"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"defaults.get";
                request[@"key"] = args[2];
            } else if ([action isEqualToString:@"set"] && args.count >= 4 && ![args[2] hasPrefix:@"-"]) {
                op = @"defaults.set";
                request[@"key"] = args[2];
                request[@"value"] = FUParseCallArgument(args[3]);
            } else if ([action isEqualToString:@"remove"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"defaults.remove";
                request[@"key"] = args[2];
            }
        } else if ([command isEqualToString:@"keychain"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"items"]) {
                op = @"keychain.items";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) request[@"query"] = args[2];
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"item"] && args.count >= 4 && ![args[2] hasPrefix:@"-"] && ![args[3] hasPrefix:@"-"]) {
                op = @"keychain.item";
                request[@"service"] = args[2];
                request[@"account"] = args[3];
                NSString *accessGroup = FUValueAfter(args, @"--access-group");
                if (accessGroup.length) request[@"access_group"] = accessGroup;
            }
        } else if ([command isEqualToString:@"database"] && args.count >= 4 && [@[@"sqlite", @"realm"] containsObject:args[1]]) {
            NSString *databaseKind = args[1];
            NSString *databasePrefix = [@"database." stringByAppendingString:databaseKind];
            NSString *action = args[2];
            if ([action isEqualToString:@"tables"] && ![args[3] hasPrefix:@"-"]) {
                op = [databasePrefix stringByAppendingString:@".tables"];
                request[@"path"] = args[3];
                if (rootHandle.length) request[@"root"] = rootHandle;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            } else if ([action isEqualToString:@"columns"] && args.count >= 5 && ![args[3] hasPrefix:@"-"] && ![args[4] hasPrefix:@"-"]) {
                op = [databasePrefix stringByAppendingString:@".columns"];
                request[@"path"] = args[3];
                request[@"table"] = args[4];
                if (rootHandle.length) request[@"root"] = rootHandle;
            } else if ([action isEqualToString:@"rows"] && args.count >= 5 && ![args[3] hasPrefix:@"-"] && ![args[4] hasPrefix:@"-"]) {
                op = [databasePrefix stringByAppendingString:@".rows"];
                request[@"path"] = args[3];
                request[@"table"] = args[4];
                if (rootHandle.length) request[@"root"] = rootHandle;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
            }
        } else if ([command isEqualToString:@"filesystem"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"list"] || [action isEqualToString:@"stat"]) {
                op = [@"filesystem." stringByAppendingString:action];
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) request[@"path"] = args[2];
                if (rootHandle.length) request[@"root"] = rootHandle;
                if ([action isEqualToString:@"list"]) {
                    if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                    if (limitString.length) request[@"limit"] = @([limitString integerValue]);
                }
            } else if ([action isEqualToString:@"read"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"filesystem.read";
                request[@"path"] = args[2];
                if (rootHandle.length) request[@"root"] = rootHandle;
                if (maxBytesString.length) request[@"max_bytes"] = @([maxBytesString integerValue]);
            } else if ([action isEqualToString:@"search"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"filesystem.search";
                request[@"query"] = args[2];
                if (args.count >= 4 && ![args[3] hasPrefix:@"-"]) request[@"path"] = args[3];
                if (rootHandle.length) request[@"root"] = rootHandle;
                if (offsetString.length) request[@"offset"] = @([offsetString integerValue]);
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
                if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                if (maxDepthString.length) request[@"max_depth"] = @([maxDepthString integerValue]);
            }
        } else if ([command isEqualToString:@"ui"] && args.count >= 2) {
            NSString *action = args[1];
            if ([action isEqualToString:@"windows"]) {
                op = @"ui.windows";
            } else if ([action isEqualToString:@"key-window"]) {
                op = @"ui.key_window";
            } else if ([action isEqualToString:@"hierarchy"]) {
                op = @"ui.hierarchy";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                    request[@"root"] = args[2];
                }
                if (maxDepthString.integerValue > 0) {
                    request[@"max_depth"] = @([maxDepthString integerValue]);
                }
                if (maxChildrenString.integerValue > 0) {
                    request[@"max_children"] = @([maxChildrenString integerValue]);
                }
                if (maxNodesString.integerValue > 0) {
                    request[@"max_nodes"] = @([maxNodesString integerValue]);
                }
            } else if ([action isEqualToString:@"find"]) {
                op = @"ui.find";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                    request[@"query"] = args[2];
                }
                if (rootHandle.length) request[@"root"] = rootHandle;
                if (classNameFilter.length) request[@"class"] = classNameFilter;
                if (textFilter.length) request[@"text"] = textFilter;
                if (identifierFilter.length) request[@"accessibility_identifier"] = identifierFilter;
                if (labelFilter.length) request[@"accessibility_label"] = labelFilter;
                if (limitString.length) request[@"limit"] = @([limitString integerValue]);
                if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
            } else if ([action isEqualToString:@"resolve"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                NSDictionary *selector = FUParseJSONObject(args[2]);
                if (selector) {
                    op = @"ui.resolve";
                    request[@"selector"] = selector;
                    if (rootHandle.length) request[@"root"] = rootHandle;
                    if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                    if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
                }
            } else if ([action isEqualToString:@"wait"]) {
                op = @"ui.wait";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                    request[@"query"] = args[2];
                }
                if (rootHandle.length) request[@"root"] = rootHandle;
                if (classNameFilter.length) request[@"class"] = classNameFilter;
                if (textFilter.length) request[@"text"] = textFilter;
                if (identifierFilter.length) request[@"accessibility_identifier"] = identifierFilter;
                if (labelFilter.length) request[@"accessibility_label"] = labelFilter;
                if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
                if (stateString.length) request[@"state"] = stateString;
                if (timeoutMSString.length) request[@"timeout_ms"] = @([timeoutMSString integerValue]);
                if (pollIntervalMSString.length) request[@"poll_interval_ms"] = @([pollIntervalMSString integerValue]);
            } else if ([action isEqualToString:@"activate"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                if (FUAttachUIActionTarget(request, args[2])) {
                    op = @"ui.activate";
                    if (rootHandle.length) request[@"root"] = rootHandle;
                    if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                    if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
                }
            } else if ([action isEqualToString:@"select"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                if (FUAttachUIActionTarget(request, args[2])) {
                    op = @"ui.select";
                    if (rootHandle.length) request[@"root"] = rootHandle;
                    if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                    if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
                }
            } else if ([action isEqualToString:@"back"]) {
                op = @"ui.back";
                if ([args containsObject:@"--animated"]) request[@"animated"] = @YES;
            } else if ([action isEqualToString:@"dismiss"]) {
                op = @"ui.dismiss";
                if ([args containsObject:@"--animated"]) request[@"animated"] = @YES;
            } else if ([action isEqualToString:@"first-responder"]) {
                op = @"ui.first_responder";
            } else if ([action isEqualToString:@"dismiss-keyboard"]) {
                op = @"ui.dismiss_keyboard";
            } else if ([action isEqualToString:@"alert"]) {
                op = @"ui.alert";
            } else if ([action isEqualToString:@"alert-action"]) {
                BOOL hasIndex = alertIndexString != nil;
                BOOL hasTitle = alertTitleString != nil;
                if (hasIndex != hasTitle) {
                    if (hasIndex) {
                        NSInteger index = 0;
                        if (FUParseNonnegativeInteger(alertIndexString, &index)) {
                            op = @"ui.alert_action";
                            request[@"index"] = @(index);
                        }
                    } else if (alertTitleString.length > 0) {
                        op = @"ui.alert_action";
                        request[@"title"] = alertTitleString;
                    }
                }
            } else if ([action isEqualToString:@"hit-test"] && args.count >= 4) {
                double x = 0.0;
                double y = 0.0;
                if (FUParseFiniteDouble(args[2], &x) && FUParseFiniteDouble(args[3], &y)) {
                    op = @"ui.hit_test";
                    request[@"x"] = @(x);
                    request[@"y"] = @(y);
                    if (rootHandle.length) request[@"root"] = rootHandle;
                }
            } else if ([action isEqualToString:@"tap"] && args.count >= 4) {
                double x = 0.0;
                double y = 0.0;
                if (FUParseFiniteDouble(args[2], &x) && FUParseFiniteDouble(args[3], &y)) {
                    op = @"ui.tap";
                    request[@"x"] = @(x);
                    request[@"y"] = @(y);
                    if (rootHandle.length) request[@"root"] = rootHandle;
                }
            } else if ([action isEqualToString:@"set-text"] && args.count >= 4 && ![args[2] hasPrefix:@"-"]) {
                if (FUAttachUIActionTarget(request, args[2])) {
                    op = @"ui.set_text";
                    request[@"text"] = args[3];
                    if (rootHandle.length) request[@"root"] = rootHandle;
                    if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                    if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
                    if ([args containsObject:@"--submit"]) request[@"submit"] = @YES;
                    if ([args containsObject:@"--no-notify"]) request[@"notify"] = @NO;
                }
            } else if ([action isEqualToString:@"set-value"] && args.count >= 4 && ![args[2] hasPrefix:@"-"]) {
                id value = FUParseScalar(args[3]);
                if (FUAttachUIActionTarget(request, args[2]) && [value isKindOfClass:[NSNumber class]]) {
                    op = @"ui.set_value";
                    request[@"value"] = value;
                    if (rootHandle.length) request[@"root"] = rootHandle;
                    if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                    if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
                    if ([args containsObject:@"--animated"]) request[@"animated"] = @YES;
                    if ([args containsObject:@"--no-notify"]) request[@"notify"] = @NO;
                }
            } else if ([action isEqualToString:@"scroll"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                if (FUAttachUIActionTarget(request, args[2])) {
                    op = @"ui.scroll";
                    if (rootHandle.length) request[@"root"] = rootHandle;
                    if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                    if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
                    if (dxString.length) request[@"dx"] = @([dxString doubleValue]);
                    if (dyString.length) request[@"dy"] = @([dyString doubleValue]);
                    if ([args containsObject:@"--animated"]) request[@"animated"] = @YES;
                }
            } else if ([action isEqualToString:@"screenshot"]) {
                op = @"ui.screenshot";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) request[@"root"] = args[2];
                if (rootHandle.length) request[@"root"] = rootHandle;
                if (formatString.length) request[@"format"] = formatString;
                if (qualityString.length) request[@"quality"] = @([qualityString doubleValue]);
                if (maxDimensionString.length) request[@"max_dimension"] = @([maxDimensionString integerValue]);
            } else if ([action isEqualToString:@"snapshot"]) {
                op = @"ui.snapshot";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) request[@"root"] = args[2];
                if (rootHandle.length) request[@"root"] = rootHandle;
                if (formatString.length) request[@"format"] = formatString;
                if (qualityString.length) request[@"quality"] = @([qualityString doubleValue]);
                if (maxDimensionString.length) request[@"max_dimension"] = @([maxDimensionString integerValue]);
                if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                if ([args containsObject:@"--no-image"]) request[@"include_image"] = @NO;
            } else if ([action isEqualToString:@"snapshot-save"]) {
                op = @"ui.snapshot_save";
                if (args.count >= 3 && ![args[2] hasPrefix:@"-"]) request[@"root"] = args[2];
                if (rootHandle.length) request[@"root"] = rootHandle;
                if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
            } else if ([action isEqualToString:@"snapshot-diff"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                op = @"ui.snapshot_diff";
                request[@"snapshot_id"] = args[2];
                if (rootHandle.length) request[@"root"] = rootHandle;
                if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                if (maxChangesString.length) request[@"max_changes"] = @([maxChangesString integerValue]);
            } else if ([action isEqualToString:@"deep-inspect"] && args.count >= 3 && ![args[2] hasPrefix:@"-"]) {
                if (FUAttachObjectTarget(request, args[2])) {
                    op = @"ui.deep_inspect";
                    if (rootHandle.length) request[@"root"] = rootHandle;
                    if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
                    if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
                    if (limitString.integerValue > 0) request[@"limit"] = @([limitString integerValue]);
                    if ([args containsObject:@"--no-values"]) request[@"include_values"] = @NO;
                }
            }
        } else if ([command isEqualToString:@"swift"] && args.count >= 3) {
            NSString *action = args[1];
            if (![action isEqualToString:@"inspect"] || !FUAttachObjectTarget(request, args[2])) {
                FUPrintUsage();
                return 2;
            }
            op = @"swift.inspect";
            if (rootHandle.length) request[@"root"] = rootHandle;
            if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
            if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
            if (limitString.integerValue > 0) request[@"limit"] = @([limitString integerValue]);
            if ([args containsObject:@"--no-values"]) request[@"include_values"] = @NO;
        } else if ([command isEqualToString:@"investigate"] && args.count >= 2) {
            NSString *action = args[1];
            if (![action isEqualToString:@"screen"] && ![action isEqualToString:@"element"]) {
                FUPrintUsage();
                return 2;
            }
            BOOL elementInvestigation = [action isEqualToString:@"element"];
            op = elementInvestigation ? @"investigate.element" : @"investigate.screen";
            if (args.count >= 3 && ![args[2] hasPrefix:@"-"] && !FUAttachObjectTarget(request, args[2])) {
                FUPrintUsage();
                return 2;
            }
            if (rootHandle.length) request[@"root"] = rootHandle;
            if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
            if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
            if (limitString.integerValue > 0) request[@"limit"] = @([limitString integerValue]);
            if ([args containsObject:@"--no-values"]) request[@"include_values"] = @NO;
            if (elementInvestigation) {
                if ([args containsObject:@"--no-reference-graph"]) request[@"include_reference_graph"] = @NO;
                if (heapMaxDepthString.length) request[@"heap_max_depth"] = @([heapMaxDepthString integerValue]);
                if (heapMaxNodesString.length) request[@"heap_max_nodes"] = @([heapMaxNodesString integerValue]);
                if (heapPerNodeLimitString.length) request[@"heap_per_node_limit"] = @([heapPerNodeLimitString integerValue]);
                if (heapTimeoutMSString.length) request[@"heap_timeout_ms"] = @([heapTimeoutMSString integerValue]);
                if ([args containsObject:@"--no-trace-recipe"]) request[@"include_trace_recipe"] = @NO;
            } else {
                if ([args containsObject:@"--no-image"]) request[@"include_image"] = @NO;
                if (formatString.length) request[@"format"] = formatString;
                if (qualityString.length) request[@"quality"] = @([qualityString doubleValue]);
                if (maxDimensionString.length) request[@"max_dimension"] = @([maxDimensionString integerValue]);
            }
        } else if ([command isEqualToString:@"object"] && args.count >= 3) {
            NSString *action = args[1];
            if (!FUAttachObjectTarget(request, args[2])) {
                FUPrintUsage();
                return 2;
            }
            if (rootHandle.length) request[@"root"] = rootHandle;
            if (maxNodesString.length) request[@"max_nodes"] = @([maxNodesString integerValue]);
            if ([args containsObject:@"--include-hidden"]) request[@"include_hidden"] = @YES;
            if ([action isEqualToString:@"inspect"]) {
                op = @"object.inspect";
                if (limitString.integerValue > 0) {
                    request[@"limit"] = @([limitString integerValue]);
                }
                if ([args containsObject:@"--no-values"]) {
                    request[@"include_values"] = @NO;
                }
            } else if ([@[@"properties", @"ivars", @"methods"] containsObject:action]) {
                op = [@"object." stringByAppendingString:action];
                if (queryString) {
                    request[@"query"] = queryString;
                }
                if (offsetString.length) {
                    request[@"offset"] = @([offsetString integerValue]);
                }
                if (limitString.length) {
                    request[@"limit"] = @([limitString integerValue]);
                }
                if ([args containsObject:@"--no-values"]) {
                    request[@"include_values"] = @NO;
                }
                if ([action isEqualToString:@"methods"] && [args containsObject:@"--class"]) {
                    request[@"class_methods"] = @YES;
                }
            } else if ([action isEqualToString:@"get"] && args.count >= 4) {
                op = @"object.get";
                request[@"name"] = args[3];
                if (memberKind.length) {
                    request[@"member_kind"] = memberKind;
                }
            } else if ([action isEqualToString:@"set"] && args.count >= 5) {
                op = @"object.set";
                request[@"name"] = args[3];
                request[@"value"] = FUParseCallArgument(args[4]);
                if (memberKind.length) {
                    request[@"member_kind"] = memberKind;
                }
            } else if ([action isEqualToString:@"pin"]) {
                op = @"object.pin";
            } else if ([action isEqualToString:@"unpin"]) {
                op = @"object.unpin";
            } else if ([action isEqualToString:@"call"] && args.count >= 4) {
                op = @"object.call";
                request[@"selector"] = args[3];
                request[@"method_kind"] = [args containsObject:@"--class"] ? @"class" : @"instance";
                if ([args containsObject:@"--pin-result"]) request[@"pin_result"] = @YES;
                NSMutableArray *callArguments = [NSMutableArray array];
                NSSet *options = [NSSet setWithArray:@[@"--target", @"-t", @"--expected-generation", @"--root", @"--max-nodes", @"--include-hidden", @"--class", @"--pin-result", @"--human"]];
                for (NSUInteger i = 4; i < args.count; i++) {
                    NSString *argument = args[i];
                    if ([options containsObject:argument]) {
                        break;
                    }
                    [callArguments addObject:FUParseCallArgument(argument)];
                }
                request[@"arguments"] = callArguments;
            }
        }

        if (!op) {
            FUPrintUsage();
            return 2;
        }
        request[@"op"] = op;
        if (experimentID.length && [@[@"defaults.set", @"defaults.remove", @"ui.set_text", @"ui.set_value", @"ui.scroll"] containsObject:op]) {
            request[@"experiment_id"] = experimentID;
        }
        if (target.length) {
            request[@"target"] = target;
        }
        if (expectedGeneration.length && !FUOperationIsDaemonLocal(op)) {
            request[@"expected_generation"] = expectedGeneration;
        }

        int fd = FUConnect();
        if (fd < 0) {
            fprintf(stderr, "flexultra: could not connect to flexultrad on 127.0.0.1:%u\n", FUDaemonPort);
            return 3;
        }

        NSDictionary *hello = @{
            @"v": @(FUProtocolVersion),
            @"kind": @"hello",
            @"role": @"cli",
        };
        if (!FUWriteJSONLine(fd, hello, nil)) {
            close(fd);
            return 3;
        }
        NSDictionary *ack = FUReadJSONLine(fd, nil);
        if (![ack[@"ok"] boolValue]) {
            fprintf(stderr, "flexultra: daemon rejected protocol handshake\n");
            close(fd);
            return 3;
        }

        NSInteger responseTimeout = FUReceiveTimeoutForRequest(request);
        FUSetReceiveTimeout(fd, responseTimeout);

        if (!FUWriteJSONLine(fd, request, nil)) {
            close(fd);
            return 3;
        }
        NSError *responseError = nil;
        NSDictionary *response = FUReadJSONLine(fd, &responseError);
        close(fd);
        if (!response) {
            if (responseError.code == EAGAIN || responseError.code == EWOULDBLOCK) {
                fprintf(stderr, "flexultra: timed out waiting for %s after %ld seconds\n", op.UTF8String, (long)responseTimeout);
            } else {
                fprintf(stderr, "flexultra: no response from daemon: %s\n", responseError.localizedDescription.UTF8String ?: "unknown transport error");
            }
            return 3;
        }

        if (human) {
            FUPrintHuman(op, response);
        } else {
            FUPrintJSON(response);
        }

        return [response[@"ok"] boolValue] ? 0 : 1;
    }
}
