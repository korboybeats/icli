#import <Foundation/Foundation.h>
#import <dlfcn.h>
#include <assert.h>

static BOOL legacy;
static BOOL missingPredicate;
static BOOL loaded;
static NSUInteger proxyLists, recordLists, oldPredicates, newPredicates, stateRequests;
static BOOL registrationAccepted = YES;
static NSArray *registrationInfos;
static NSDictionary *registrationDictionary;
static Class fixtureClass(NSString *name);
static void *fixtureLoad(const char *path, int flags) { loaded = YES; return NULL; }
static int fixturePidPath(int pid, void *buffer, uint32_t size) { return 0; }

// Run the production adapters against deterministic native API substitutes.
#define NSClassFromString fixtureClass
#define dlopen fixtureLoad
#define proc_pidpath fixturePidPath
#import "../../Sources/IcliSystemPrivate/LaunchServices.m"
#import "../../Sources/IcliLaunchPrivate/Launch.m"
#import "../../Sources/IcliPrivate/AppRegistration.m"
#undef proc_pidpath
#undef dlopen
#undef NSClassFromString

@interface AppProxy : NSObject
@property NSString *applicationIdentifier;
@property NSURL *bundleURL;
@property NSString *localizedName;
@property NSString *applicationType;
@property NSString *signerIdentity;
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
@end

static NSArray<AppProxy *> *proxies(void) {
    static NSArray *apps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AppProxy *bootstrap = [AppProxy new], *system = [AppProxy new];
        bootstrap.applicationIdentifier = @"dev.owngoal.icli.bootstrap";
        bootstrap.bundleURL = [NSURL fileURLWithPath:@"/Applications/Fixture.app" isDirectory:YES];
        bootstrap.localizedName = @"Fixture";
        bootstrap.applicationType = @"System";
        bootstrap.signerIdentity = @"Fixture signer";
        system.applicationIdentifier = @"com.apple.fixture";
        system.bundleURL = [NSURL fileURLWithPath:@"/Applications/SystemFixture.app" isDirectory:YES];
        system.applicationType = @"System";
        apps = @[bootstrap, system];
    });
    return apps;
}

@implementation AppProxy
+ (id)applicationProxyForIdentifier:(NSString *)identifier {
    for (AppProxy *app in proxies()) if ([app.applicationIdentifier isEqual:identifier]) return app;
    return nil;
}
@end

@interface LegacyWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (BOOL)registerApplicationDictionary:(NSDictionary *)info;
@end
@implementation LegacyWorkspace
+ (id)defaultWorkspace { return [self new]; }
- (NSArray *)allInstalledApplications { proxyLists++; return proxies(); }
- (BOOL)registerApplicationDictionary:(NSDictionary *)info {
    registrationDictionary = info;
    return registrationAccepted;
}
@end

@interface ModernWorkspace : LegacyWorkspace
- (id)registerContainerizedApplicationWithInfoDictionaries:(NSArray *)infos
    operationUUID:(NSUUID *)uuid requestContext:(id)context saveObserver:(id)observer registrationError:(NSError **)error;
@end
@implementation ModernWorkspace
- (id)registerContainerizedApplicationWithInfoDictionaries:(NSArray *)infos
    operationUUID:(NSUUID *)uuid requestContext:(id)context saveObserver:(id)observer registrationError:(NSError **)error {
    assert(uuid && !context && !observer && error);
    registrationInfos = infos;
    if (!registrationAccepted) *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
    return nil;
}
@end

@interface LegacyRecord : NSObject
+ (id)enumeratorWithOptions:(NSUInteger)options;
@end
@implementation LegacyRecord
+ (id)enumeratorWithOptions:(NSUInteger)options {
    recordLists++;
    NSMutableArray *records = [NSMutableArray array];
    for (AppProxy *app in proxies()) {
        NSMutableDictionary *record = [@{@"bundleIdentifier": app.applicationIdentifier,
            @"URL": app.bundleURL, @"typeForInstallMachinery": app.applicationType} mutableCopy];
        record[@"signerIdentity"] = app.signerIdentity;
        [records addObject:record];
    }
    return records;
}
@end
@interface ModernRecord : LegacyRecord
@property NSString *signerIdentity;
@end
@implementation ModernRecord
@end

@interface LegacyPredicate : NSObject
+ (id)predicateMatchingLaunchServicesProcesses;
@end
@implementation LegacyPredicate
+ (id)predicateMatchingLaunchServicesProcesses { oldPredicates++; return [self new]; }
@end
@interface ModernPredicate : LegacyPredicate
+ (id)predicateMatchingProcessTypeApplication;
@end
@implementation ModernPredicate
+ (id)predicateMatchingProcessTypeApplication { newPredicates++; return [self new]; }
@end
@interface StateDescriptor : NSObject
@property unsigned long values;
+ (id)descriptor;
@end
@implementation StateDescriptor
+ (id)descriptor { return [self new]; }
@end
@interface BoardConnection : NSObject
+ (id)sharedInstance;
- (NSArray *)statesForPredicate:(id)predicate withDescriptor:(StateDescriptor *)descriptor error:(NSError **)error;
@end
@implementation BoardConnection
+ (id)sharedInstance { return [self new]; }
- (NSArray *)statesForPredicate:(id)predicate withDescriptor:(StateDescriptor *)descriptor error:(NSError **)error {
    assert(predicate && descriptor.values == 0x19 && error);
    stateRequests++;
    return @[@{@"process": @{@"pid": @1234,
        @"identity": @{@"embeddedApplicationIdentifier": @"dev.owngoal.icli.bootstrap"}},
        @"assertions": @[@{@"domain": @"com.apple.frontboard:SuspendableRole-UIFocal"}]}];
}
@end

static Class fixtureClass(NSString *name) {
    if ([name isEqual:@"LSApplicationWorkspace"]) return loaded ? (legacy ? LegacyWorkspace.class : ModernWorkspace.class) : Nil;
    if ([name isEqual:@"LSApplicationProxy"]) return loaded ? AppProxy.class : Nil;
    if ([name isEqual:@"LSApplicationRecord"]) return legacy ? LegacyRecord.class : ModernRecord.class;
    if ([name isEqual:@"RBSProcessPredicate"]) return missingPredicate ? NSObject.class : (legacy ? LegacyPredicate.class : ModernPredicate.class);
    if ([name isEqual:@"RBSProcessStateDescriptor"]) return StateDescriptor.class;
    if ([name isEqual:@"RBSConnection"]) return BoardConnection.class;
    return NSClassFromString(name);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSString *mode = @(argv[1]);
        legacy = [mode isEqual:@"legacy"];
        missingPredicate = [mode isEqual:@"missing-predicate"];
        if ([mode isEqual:@"cold-installed"]) {
            assert(!loaded && icli_app_is_installed("dev.owngoal.icli.bootstrap") && loaded);
            assert(!icli_app_is_installed("dev.owngoal.icli.missing"));
        } else if ([mode isEqual:@"cold-name"]) {
            assert(!loaded);
            char *name = icli_app_name("dev.owngoal.icli.bootstrap");
            assert(loaded && name && !strcmp(name, "Fixture"));
            free(name);
            assert(!icli_app_name("dev.owngoal.icli.missing"));
        } else {
            NSMutableDictionary *pids = [NSMutableDictionary dictionary];
            NSString *focal = bulkFocalApplication(pids);
            if (missingPredicate) {
                assert(!focal && !stateRequests);
            } else {
                assert([focal isEqual:@"dev.owngoal.icli.bootstrap"] && [pids[focal] intValue] == 1234);
                assert(stateRequests == 1 && oldPredicates == legacy && newPredicates == !legacy);
                NSArray *index = appIndex();
                assert(index.count == 2 && [index[0][@"signer"] isEqual:@"Fixture signer"] && !index[1][@"signer"]);
                assert(proxyLists == legacy && recordLists == !legacy);
                NSDictionary *info = @{@"CFBundleIdentifier": @"fixture", @"_LSBundlePlugins": @{
                    @"b": @{@"CFBundleIdentifier": @"b"}, @"a": @{@"CFBundleIdentifier": @"a"}}};
                NSError *error = nil;
                assert(icli_ls_register_containerized(icli_ls_workspace(), info, &error) && !error);
                if (legacy) assert(registrationDictionary == info && !registrationInfos);
                else {
                    assert(registrationInfos.count == 3 && !registrationInfos[0][@"_LSBundlePlugins"]);
                    assert([registrationInfos[1][@"CFBundleIdentifier"] isEqual:@"a"]);
                    assert([registrationInfos[2][@"CFBundleIdentifier"] isEqual:@"b"]);
                }
                registrationAccepted = NO;
                assert(!icli_ls_register_containerized(icli_ls_workspace(), info, &error));
                assert(legacy ? error == nil : error.code == 1);
            }
        }
        printf("PASS app services %s\n", argv[1]);
    }
}
