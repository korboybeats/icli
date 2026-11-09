#!/usr/bin/env python3
"""Adapt the pinned FlexUltra source to icli; never alter the archived originals."""
from pathlib import Path
import hashlib
import json
import os
import re

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'Vendor/FlexUltra'
OUT = ROOT / '.build/flexultra-src'
CLIENT = ROOT / 'Sources/IcliFlexClient'


def write(path, content):
    if path.suffix in ('.m', '.h'):
        content = '// Adapted by icli: namespaced symbols and private on-demand transport.\n' + content
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text() != content:
        temporary = path.with_name(path.name + ".prepared-" + str(os.getpid()))
        temporary.write_text(content)
        temporary.replace(path)


def namespace(text):
    return re.sub(r'\bFU[A-Z][A-Za-z0-9_]*', lambda m: 'Icli' + m[0], text)


REALM_FACTORY = '''static id FURealmManagerForPath(NSString *absolutePath) {
    Class managerClass = NSClassFromString(@"FLEXRealmDatabaseManager");
    SEL factory = NSSelectorFromString(@"managerForDatabase:");
    return managerClass && [managerClass respondsToSelector:factory]
        ? ((id (*)(id, SEL, id))objc_msgSend)(managerClass, factory, absolutePath)
        : nil;
}
'''
# FLEX opens a Realm with a blank configuration (schema version 0), which Realm
# refuses with "Provided schema version 0 is less than last set version N" for
# any app that set a schema version (Bark: 18). Open it with the app's own
# configuration for its default file, else with the version stored in the file,
# and let FLEX's manager run its queries on that Realm.
REALM_FACTORY_FIXED = '''static NSString *FURealmOpenFailure = nil;

static id FURealmManagerForPath(NSString *absolutePath) {
    FURealmOpenFailure = nil;
    Class managerClass = NSClassFromString(@"FLEXRealmDatabaseManager");
    Class realmClass = NSClassFromString(@"RLMRealm");
    Class configurationClass = NSClassFromString(@"RLMRealmConfiguration");
    if (!managerClass || !realmClass || !configurationClass) return nil;
    NSURL *url = [NSURL fileURLWithPath:absolutePath];
    @try {
        id defaults = ((id (*)(id, SEL))objc_msgSend)(configurationClass, NSSelectorFromString(@"defaultConfiguration"));
        NSURL *defaultURL = [defaults valueForKey:@"fileURL"];
        BOOL appDefault = defaultURL.isFileURL && [defaultURL.URLByStandardizingPath.path isEqualToString:url.URLByStandardizingPath.path];
        NSError *versionError = nil;
        uint64_t version = ((uint64_t (*)(id, SEL, id, id, NSError **))objc_msgSend)(
            realmClass, NSSelectorFromString(@"schemaVersionAtURL:encryptionKey:error:"), url,
            appDefault ? [defaults valueForKey:@"encryptionKey"] : nil, &versionError);
        if (versionError) {
            FURealmOpenFailure = versionError.localizedDescription;
            return nil;
        }
        id configuration = nil;
        if (appDefault) {
            // The app's configuration carries its migration block: opening a
            // file older than the app's version would migrate (write) it.
            uint64_t appVersion = [[defaults valueForKey:@"schemaVersion"] unsignedLongLongValue];
            if (version < appVersion) {
                FURealmOpenFailure = [NSString stringWithFormat:@"The Realm file is at schema version %llu and the app expects %llu; opening it would run the app's migration and write the file. Let the app open it first.", version, appVersion];
                return nil;
            }
            configuration = [defaults copy];
        } else {
            configuration = [configurationClass new];
            [configuration setValue:url forKey:@"fileURL"];
            [configuration setValue:@(version) forKey:@"schemaVersion"];
        }
        NSError *openError = nil;
        id realm = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
            realmClass, NSSelectorFromString(@"realmWithConfiguration:error:"), configuration, &openError);
        if (!realm || openError) {
            FURealmOpenFailure = openError.localizedDescription;
            return nil;
        }
        id manager = [managerClass new];
        [manager setValue:realm forKey:@"realm"];
        [manager setValue:absolutePath forKey:@"path"];
        return manager;
    } @catch (NSException *exception) {
        FURealmOpenFailure = exception.reason;
        return nil;
    }
}
'''
REALM_OPEN_ERROR = 'FUErrorInfo(@"database_failed", @"FLEX could not open the requested Realm database.")'
REALM_OPEN_ERROR_FIXED = 'FUErrorInfo(@"database_failed", FURealmOpenFailure ?: @"FLEX could not open the requested Realm database.")'

for directory in ['Agent', 'Shared']:
    for path in (VENDOR / directory).iterdir():
        if path.suffix not in ['.h', '.m'] or path.name == 'FUAgent.m':
            continue
        text = path.read_text()
        if path.name == 'FUObjectRegistry.m':
            text += "\nvoid ICLIFlexAdoptGeneration(NSString *generation) {\n    FUInitializeObjectRegistry();\n    if (generation.length && FUHandleToObject.count == 0 && FUPinnedObjects.count == 0) FUObjectGeneration = [generation copy];\n}\n"
        if path.name == 'FURuntime.m':
            text = '#import "ICLIFlexPaths.h"\n' + text
            a = text.index('        NSArray<NSString *> *paths = @[')
            b = text.index('        ];', a) + len('        ];')
            text = text[:a] + '        NSArray<NSString *> *paths = @[ICLIFlexPrivatePath(@"libFLEX.dylib")];' + text[b:]
            a = text.index('        NSArray<NSString *> *reflexPaths = @[')
            b = text.index('        ];', a) + len('        ];')
            text = text[:a] + '        NSArray<NSString *> *reflexPaths = @[ICLIFlexPrivatePath(@"libicli-reflex.dylib")];' + text[b:]
        if path.name == 'FUStorage.m':
            text = text.replace(REALM_FACTORY, REALM_FACTORY_FIXED)
            assert REALM_FACTORY_FIXED in text, 'FUStorage.m Realm factory changed'
            assert text.count(REALM_OPEN_ERROR) == 3, 'FUStorage.m Realm open errors changed'
            text = text.replace(REALM_OPEN_ERROR, REALM_OPEN_ERROR_FIXED)
        write(OUT / directory / namespace(path.name), namespace(text))

# The original process health and worker guards, without its network service,
# broad tweak constructor, process exclusions or reconnect loop.
agent = (VENDOR / 'Agent/FUAgent.m').read_text()
a = agent.index('static uint64_t FUActivateAgentConnection')
b = agent.index('static BOOL FUBeginHeapWorker', a)
agent = agent[:a] + agent[b:]
a = agent.index('static BOOL FUIsEligibleProcess')
b = agent.index('static NSDictionary *FUHandleTargetHealth', a)
agent = agent[:a] + agent[b:]
agent = agent[:agent.index('static int FUConnectToDaemon')]
agent += (ROOT / 'Agent/FlexUltra/ICLIFlexAdapter.inc').read_text()
write(OUT / 'Agent/ICLIFlexAdapter.m', namespace(agent))

for path in (VENDOR / 'Shared').glob('*'):
    if path.suffix in ['.h', '.m']:
        text = path.read_text()
        if path.name == 'FUMCPTools.m':
            text = text.replace('List injected iOS processes currently connected to flexultrad, including generation, expected/current agent build status, connection metadata, and capabilities.', 'List running iOS apps and observed icli agents, with attachment, generation and build status. Call target_health on the requested foreground app to attach on demand.')
            text = text.replace('one connected FlexUltra target', 'one running icli target')
            text = text.replace('bounded daemon-lifetime target connection history', 'bounded persisted history of target connections observed by icli')
            text = text.replace('runtime-optional iCLI lifecycle bridge', 'in-process icli lifecycle executor')
            text = text.replace('runtime-optional iCLI device-control bridge', 'in-process icli device-control executor')
        write(CLIENT / namespace(path.name), namespace(text))

cli = (VENDOR / 'CLI/main.m').read_text()
# The existing parser and printers, with the loopback exchange replaced by
# the in-process host callback. No sockets or subprocesses in the CLI bridge.
a = cli.index('static int FUConnect(void)')
b = cli.index('static NSString *FUValueAfter', a)
cli = cli[:a] + cli[b:]
cli = cli.replace('int main(int argc, char *argv[])', 'static int runCLI(int argc, const char *const *argv)')
a = cli.index('        int fd = FUConnect();')
b = cli.index('        if (human) {', a)
cli = cli[:a] + '''        NSDictionary *response = ICLIFlexHostRequest(request);
        if (!response) return 3;

''' + cli[b:]
cli = cli.replace('  flexultra ', '  icli flex ').replace('flexultra:', 'icli flex:')
# JSON passthrough makes every catalog operation directly testable, including
# operations with no dedicated spelling in the original parser.
a = cli.index('        if (argc < 2)')
cli = cli[:a] + '''        if (argc == 2 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) { FUPrintUsage(); return 0; }
        if (argc == 3 && strcmp(argv[1], "request") == 0) {
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:[@(argv[2]) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (![request isKindOfClass:NSDictionary.class]) return 2;
            NSDictionary *response = ICLIFlexHostRequest(request);
            FUPrintJSON(response);
            return [response[@"ok"] boolValue] ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "catalog") == 0) {
            FUPrintJSON(@{@"ok": @YES, @"result": FUOperationCatalog()});
            return 0;
        }
''' + cli[a:]
cli = '#import "ICLIFlexHost.h"\n' + cli
cli += '''
int32_t icli_flex_cli(int argc, const char *const *argv, ICLIFlexTransport transport) {
    ICLIFlexSetTransport(transport);
    int result = runCLI(argc, argv);
    ICLIFlexSetTransport(NULL);
    return result;
}
'''
write(CLIENT / 'CLI.m', namespace(cli))

mcp = (VENDOR / 'MCP/main.m').read_text()
a = mcp.index('static int FUConnectBroker(void)')
b = mcp.index('static NSString *FUPrettyJSON', a)
mcp = mcp[:a] + '''static NSDictionary *FUSendBrokerRequest(NSDictionary *request) {
    return ICLIFlexHostRequest(request);
}

''' + mcp[b:]
mcp = mcp.replace('int main(int argc, char *argv[])', 'static int runMCP(void)')
mcp = '#import "ICLIFlexHost.h"\n' + mcp
mcp += '''
int32_t icli_flex_mcp(ICLIFlexTransport transport) {
    ICLIFlexSetTransport(transport);
    int result = runMCP();
    ICLIFlexSetTransport(NULL);
    return result;
}
'''
mcp = mcp.replace('during the current daemon lifetime', 'in icli\'s observed target history')
mcp = mcp.replace('Start with flexultra_targets', 'icli attaches to the requested foreground app on demand; a running target with agent_attached=false needs target_health to attach, without a restart. History is persisted only for agents icli observes, with no resident broker. Start with flexultra_targets')
mcp = mcp.replace('On iOS 26 and newer the current Reflex/Echo mirror constructor is disabled for target-process safety; use Objective-C/FLEX object, runtime, UI, and heap tools instead.', 'Swift inspection reads class metadata only; live Swift value reads and mirror construction remain disabled, matching the supplied implementation.')

mcp = mcp.replace('live inspection and control of injected jailbroken iOS processes', 'live inspection and control of selected jailbroken iOS processes through icli')
write(CLIENT / 'MCP.m', namespace(mcp))

daemon = (VENDOR / 'Daemon/main.m').read_text()
a = daemon.index('static BOOL FUInputNumber(')
b = daemon.index('static void FUWriteLocked', a)
inputs = '''#import "ICLIFlexHost.h"
#import <math.h>
static id FURunICLI(NSArray *arguments, NSDictionary **error) {
    (void)error;
    return @{@"argv": arguments};
}
''' + daemon[a:b]
inputs += '''
char *icli_flex_input_arguments_json(const char *source) {
    @autoreleasepool {
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:[@(source) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSDictionary *error = nil;
        id result = FUHandleInputOperation(request[@"op"], request, &error);
        id response = result ?: @{@"error": error ?: @{}};
        NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
        return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    }
}
'''
write(CLIENT / 'InputArguments.m', namespace(inputs))

# The same identity is compiled into both ends. Do not hash generated output.
hash_ = hashlib.sha256()
for directory in [VENDOR / 'Agent', VENDOR / 'Shared', ROOT / 'Agent/FlexUltra']:
    for path in sorted(directory.rglob('*')):
        if path.is_file():
            hash_.update(path.relative_to(ROOT).as_posix().encode())
            hash_.update(path.read_bytes())
for name in ['Agent/IcliProbeAgent.m', 'Agent/ICLIFlexBridge.h', 'Agent/ICLIFlexBridge.m']:
    hash_.update((ROOT / name).read_bytes())
hash_.update(Path(__file__).read_bytes())
build = hash_.hexdigest()[:24]
header = '#pragma once\n#define ICLI_FULL_FLEX_BUILD "' + build + '"\n'
write(OUT / 'ICLIFlexBuild.h', header)
write(CLIENT / 'ICLIFlexBuild.h', header)
ops = re.findall(r'FUOperation\(@"([^"]+)",\s*(?:@"[^"]+"|nil),', (VENDOR / 'Shared/FUProtocol.m').read_text())
write(ROOT / 'docs/development/flexultra-operation-catalog.json', json.dumps({'operations': ops, 'count': len(ops), 'source': 'FlexUltra.zip/Shared/FUProtocol.m'}, indent=2)+'\n')
print('Prepared', len(ops), 'FlexUltra operations; build', build)
