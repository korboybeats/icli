#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <math.h>
#include <stdlib.h>

// The Control Center toggles, through the same private services Control
// Center's modules call. Each was measured on iOS 17.1.1 from a root process
// with icli's entitlements; the entitlement each one needs is listed in
// docs/entitlements.md. Every getter returns -1 when its service is missing.
// Every setter returns 0 once the new state reads back, -1 when the service
// is missing and -2 when the state did not change within its deadline.

static void *loadFramework(const char *path) { return dlopen(path, RTLD_NOW); }

static BOOL sendBool(id object, const char *selector) {
    SEL sel = sel_registerName(selector);
    return [object respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
}

// Runs the current run loop until `done` holds or `seconds` pass. Services
// that deliver their state through run loop sources (BluetoothManager,
// SharingUI) only update while it runs; each pass ends at the next event.
static BOOL runLoopUntil(double seconds, BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done()) {
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        NSDate *step = [NSDate dateWithTimeIntervalSinceNow:0.05];
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[step earlierDate:deadline]];
    }
    return YES;
}

static int waitForState(double seconds, int want, int (*get)(void)) {
    return runLoopUntil(seconds, ^BOOL { return get() == want; }) ? 0 : -2;
}

// MARK: Airplane Mode

// AppSupport's RadiosPreferences, as the connectivity module uses it. Writes go
// to com.apple.radios.plist through SCPreferences and need
// com.apple.SystemConfiguration.SCPreferences-write-access for that file;
// without it the write is dropped silently.
static id radiosPreferences(void) {
    static id radios;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loadFramework("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport");
        Class cls = NSClassFromString(@"RadiosPreferences");
        if (cls) radios = [[cls alloc] init];
    });
    return radios;
}

int icli_cc_airplane_get(void) {
    id radios = radiosPreferences();
    if (![radios respondsToSelector:sel_registerName("airplaneMode")]) return -1;
    if ([radios respondsToSelector:sel_registerName("refresh")])
        ((void (*)(id, SEL))objc_msgSend)(radios, sel_registerName("refresh"));
    return sendBool(radios, "airplaneMode") ? 1 : 0;
}

int icli_cc_airplane_set(bool enabled) {
    id radios = radiosPreferences();
    SEL set = sel_registerName("setAirplaneMode:");
    if (![radios respondsToSelector:set]) return -1;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(radios, set, enabled);
    if ([radios respondsToSelector:sel_registerName("synchronize")])
        ((void (*)(id, SEL))objc_msgSend)(radios, sel_registerName("synchronize"));
    return waitForState(5, enabled ? 1 : 0, icli_cc_airplane_get);
}

// MARK: Wi-Fi

// MobileWiFi's manager client, with com.apple.wifi.manager-access. wifid
// (WiFiManagerSetPowerExt) saves a power change to AllowEnable only when the
// caller's process name is SpringBoard, Preferences, mobilewifitool or
// sharingd. For any other caller it drops the radio for a few seconds and then
// restores the saved state, so the client is created, and the change sent,
// under the name Settings uses. The process name is put back afterwards.
typedef void *WiFiManagerClientRef;

static void actAsSettings(dispatch_block_t work) {
    NSProcessInfo *process = NSProcessInfo.processInfo;
    NSString *savedName = process.processName;
    const char *savedProgname = getprogname();
    setprogname("Preferences");
    process.processName = @"Preferences";
    work();
    process.processName = savedName;
    setprogname(savedProgname);
}

static WiFiManagerClientRef wifiManager(void) {
    static WiFiManagerClientRef manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = loadFramework("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi");
        WiFiManagerClientRef (*create)(CFAllocatorRef, int) =
            framework ? dlsym(framework, "WiFiManagerClientCreate") : NULL;
        if (!create) return;
        actAsSettings(^{ manager = create(kCFAllocatorDefault, 0); });
    });
    return manager;
}

int icli_cc_wifi_get(void) {
    WiFiManagerClientRef manager = wifiManager();
    Boolean (*getPower)(WiFiManagerClientRef) = manager ? dlsym(RTLD_DEFAULT, "WiFiManagerClientGetPower") : NULL;
    if (!getPower) return -1;
    return getPower(manager) ? 1 : 0;
}

int icli_cc_wifi_set(bool enabled) {
    WiFiManagerClientRef manager = wifiManager();
    void (*setPower)(WiFiManagerClientRef, Boolean) =
        manager ? dlsym(RTLD_DEFAULT, "WiFiManagerClientSetPower") : NULL;
    if (!setPower) return -1;
    actAsSettings(^{ setPower(manager, enabled); });
    return waitForState(8, enabled ? 1 : 0, icli_cc_wifi_get);
}

// MARK: Bluetooth

// BluetoothManager attaches to bluetoothd asynchronously; `available` turns
// on once it has, which needs com.apple.bluetooth.system.
static id bluetoothManager(void) {
    loadFramework("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager");
    Class cls = NSClassFromString(@"BluetoothManager");
    if (![cls respondsToSelector:sel_registerName("sharedInstance")]) return nil;
    id manager = ((id (*)(Class, SEL))objc_msgSend)(cls, sel_registerName("sharedInstance"));
    if (!runLoopUntil(5, ^BOOL { return sendBool(manager, "available"); })) return nil;
    return manager;
}

int icli_cc_bluetooth_get(void) {
    id manager = bluetoothManager();
    if (!manager) return -1;
    return sendBool(manager, "powered") ? 1 : 0;
}

int icli_cc_bluetooth_set(bool enabled) {
    id manager = bluetoothManager();
    if (!manager) return -1;
    ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(manager, sel_registerName("setPowered:"), enabled);
    ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(manager, sel_registerName("setEnabled:"), enabled);
    return waitForState(5, enabled ? 1 : 0, icli_cc_bluetooth_get);
}

// MARK: Cellular data

// CoreTelephony's server connection, under the client name Control Center's
// cellular data toggle uses. It needs icli's existing CommCenter entitlements.
typedef struct { int domain; int error; } CTResult;

static CFTypeRef telephonyConnection(void) {
    static CFTypeRef connection;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = loadFramework("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony");
        CFTypeRef (*create)(CFAllocatorRef, CFStringRef, void *, void *) =
            framework ? dlsym(framework, "_CTServerConnectionCreateWithIdentifier") : NULL;
        if (create) connection = create(kCFAllocatorDefault, CFSTR("com.apple.ControlCenter.CellularData"), NULL, NULL);
    });
    return connection;
}

int icli_cc_cellular_get(void) {
    CFTypeRef connection = telephonyConnection();
    CTResult (*get)(CFTypeRef, Boolean *) =
        connection ? dlsym(RTLD_DEFAULT, "_CTServerConnectionGetCellularDataIsEnabled") : NULL;
    if (!get) return -1;
    Boolean enabled = false;
    return get(connection, &enabled).error ? -1 : (enabled ? 1 : 0);
}

int icli_cc_cellular_set(bool enabled) {
    CFTypeRef connection = telephonyConnection();
    CTResult (*set)(CFTypeRef, Boolean) =
        connection ? dlsym(RTLD_DEFAULT, "_CTServerConnectionSetCellularDataIsEnabled") : NULL;
    if (!set) return -1;
    if (set(connection, enabled).error) return -3;
    return waitForState(5, enabled ? 1 : 0, icli_cc_cellular_get);
}

// MARK: Personal Hotspot

// Netrb's global service state: 1023 on, 1022 off. Lower values mean the
// hotspot is unavailable (no carrier support or no cellular data). One client
// serves the whole process: a client created right after another was
// destroyed answered reads with failure and refused changes (measured on
// iOS 17.1.1), while a kept client answered every call at once.
enum { HotspotOn = 1023, HotspotOff = 1022 };

static void *netrbSymbol(const char *name) {
    void *framework = loadFramework("/System/Library/PrivateFrameworks/Netrb.framework/Netrb");
    return framework ? dlsym(framework, name) : NULL;
}

static void *netrbClient(void) {
    static void *client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *(*create)(dispatch_queue_t, id, void *) = netrbSymbol("_NETRBClientCreate");
        if (create) client = create(dispatch_get_main_queue(), ^{}, NULL);
    });
    return client;
}

int icli_cc_hotspot_state(void) {
    int (*get)(void *, unsigned *, unsigned *) = netrbSymbol("_NETRBClientGetGlobalServiceState");
    void *client = get ? netrbClient() : NULL;
    if (!client) return -1;
    unsigned state = 0, reason = 0;
    if (!get(client, &state, &reason)) return -1;
    return (int)state;
}

int icli_cc_hotspot_get(void) {
    int state = icli_cc_hotspot_state();
    return state == HotspotOn ? 1 : state == HotspotOff ? 0 : -1;
}

int icli_cc_hotspot_set(bool enabled) {
    int (*set)(void *, unsigned) = netrbSymbol("_NETRBClientSetGlobalServiceState");
    void *client = set ? netrbClient() : NULL;
    if (!client) return -1;
    if (!set(client, enabled ? HotspotOn : HotspotOff)) return -3;
    return waitForState(5, enabled ? 1 : 0, icli_cc_hotspot_get);
}

// MARK: AirDrop

// SharingUI's discovery controller: 0 receiving off, 1 contacts only,
// 2 everyone (for 10 minutes on iOS 16.2 and later). Needs
// com.apple.private.airdrop.settings. The controller asks sharingd for its
// settings when it is created; until the answer arrives it reads 0. The
// answer, and the one after each change, ends with its delegate's
// discoveryControllerSettingsDidChange:, delivered on the main queue.
@interface IcliAirDropObserver : NSObject
@property (nonatomic) NSUInteger updates;
@end

@implementation IcliAirDropObserver
- (void)discoveryControllerSettingsDidChange:(id)controller { self.updates++; }
@end

static IcliAirDropObserver *airdropObserver;

static id airdropController(void) {
    static id controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loadFramework("/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI");
        Class cls = NSClassFromString(@"SFAirDropDiscoveryController");
        if (!cls) return;
        airdropObserver = [IcliAirDropObserver new];
        controller = [[cls alloc] init];
        if ([controller respondsToSelector:sel_registerName("setDelegate:")])
            ((void (*)(id, SEL, id))objc_msgSend)(controller, sel_registerName("setDelegate:"), airdropObserver);
        // Without the first answer there is no state to report.
        if (!runLoopUntil(5, ^BOOL { return airdropObserver.updates > 0; })) controller = nil;
    });
    return controller;
}

int icli_cc_airdrop_get(void) {
    id controller = airdropController();
    SEL mode = sel_registerName("discoverableMode");
    if (![controller respondsToSelector:mode]) return -1;
    return (int)((long (*)(id, SEL))objc_msgSend)(controller, mode);
}

bool icli_cc_airdrop_time_limited(void) {
    return sendBool(airdropController(), "isTimeLimitedEveryoneMode");
}

int icli_cc_airdrop_set(int mode) {
    id controller = airdropController();
    SEL set = sel_registerName("setDiscoverableMode:");
    if (![controller respondsToSelector:set]) return -1;
    ((void (*)(id, SEL, long))objc_msgSend)(controller, set, mode);
    return waitForState(5, mode, icli_cc_airdrop_get);
}

// MARK: Flashlight

// AVFCapture's AVFlashlight. Level 0 turns it off: turnPowerOff alone left
// the LED lit at the lowest level. The level stays after the process exits.
// A new AVFlashlight reads level 0 until the server's first notifications
// arrive on the run loop; the server sends FlashlightOverheated,
// FlashlightAvailable and FlashlightLevel on every connection, the level even
// when it is 0. The object is made from a subclass that counts the level
// notifications, so the getter can wait for the first one.
static NSUInteger flashlightLevelUpdates;

static void flashlightNotification(id self, SEL _cmd, id name, id payload) {
    Class base = NSClassFromString(@"AVFlashlight");
    IMP handle = class_getMethodImplementation(base, _cmd);
    ((void (*)(id, SEL, id, id))handle)(self, _cmd, name, payload);
    if ([name isKindOfClass:NSString.class] && [name isEqualToString:@"FlashlightLevel"]) flashlightLevelUpdates++;
}

static Class flashlightClass(void) {
    Class base = NSClassFromString(@"AVFlashlight");
    SEL handle = sel_registerName("_handleNotification:payload:");
    if (!base || !class_getInstanceMethod(base, handle)) return base;
    Class observed = objc_getClass("IcliObservedFlashlight");
    if (observed) return observed;
    observed = objc_allocateClassPair(base, "IcliObservedFlashlight", 0);
    if (!observed) return base;
    class_addMethod(observed, handle, (IMP)flashlightNotification, "v@:@@");
    objc_registerClassPair(observed);
    return observed;
}

static id flashlight(void) {
    static id torch;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loadFramework("/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture");
        Class cls = flashlightClass();
        if (!cls || !sendBool((id)cls, "hasFlashlight")) return;
        torch = [[cls alloc] init];
    });
    // Without the observing subclass there is no signal, and the read is
    // whatever the object holds.
    if (torch && object_getClass(torch) == objc_getClass("IcliObservedFlashlight"))
        runLoopUntil(3, ^BOOL { return flashlightLevelUpdates > 0; });
    return torch;
}

double icli_cc_flashlight_level(void) {
    id torch = flashlight();
    SEL level = sel_registerName("flashlightLevel");
    if (![torch respondsToSelector:level]) return -1;
    return ((float (*)(id, SEL))objc_msgSend)(torch, level);
}

bool icli_cc_flashlight_overheated(void) { return sendBool(flashlight(), "isOverheated"); }

static int flashlightTarget = 0;
static int flashlightReadsTarget(void) {
    return (int)lround(icli_cc_flashlight_level() * 100) == flashlightTarget ? 1 : 0;
}

int icli_cc_flashlight_set(double level) {
    id torch = flashlight();
    SEL setLevel = sel_registerName("setFlashlightLevel:withError:");
    if (![torch respondsToSelector:setLevel]) return -1;
    NSError *error = nil;
    BOOL ok = YES;
    if (level > 0)
        ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(torch, sel_registerName("turnPowerOnWithError:"), &error);
    if (ok) ok = ((BOOL (*)(id, SEL, float, NSError **))objc_msgSend)(torch, setLevel, (float)level, &error);
    if (!ok) return -3;
    flashlightTarget = (int)lround(level * 100);
    return waitForState(3, 1, flashlightReadsTarget);
}

// MARK: Focus

// The DoNotDisturb services, under Control Center's client identifier. An
// assertion outlives the process that took it only for the client identifiers
// listed with DNDAssertionsPersist in DoNotDisturb's user-toggles preload
// bundle; icli's own identifier is not one of them.
static NSString *const FocusClient = @"com.apple.donotdisturb.control-center.module";
static NSString *const FocusAssertion = @"com.apple.donotdisturb.control-center.module.manual";

static id focusService(NSString *name) {
    loadFramework("/System/Library/PrivateFrameworks/DoNotDisturb.framework/DoNotDisturb");
    Class cls = NSClassFromString(name);
    SEL make = sel_registerName("serviceForClientIdentifier:");
    if (![cls respondsToSelector:make]) return nil;
    return ((id (*)(Class, SEL, NSString *))objc_msgSend)(cls, make, FocusClient);
}

static id callWithError(id target, const char *selector, NSError **error) {
    SEL sel = sel_registerName(selector);
    if (![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, NSError **))objc_msgSend)(target, sel, error);
}

static NSArray *focusModes(NSError **error) {
    NSMutableArray *modes = [NSMutableArray array];
    NSArray *available = callWithError(focusService(@"DNDModeSelectionService"), "availableModesWithError:", error);
    for (id mode in available) {
        id identifier = [mode valueForKey:@"modeIdentifier"];
        id name = [mode valueForKey:@"name"];
        if ([identifier isKindOfClass:NSString.class])
            [modes addObject:@{@"id": identifier, @"name": [name isKindOfClass:NSString.class] ? name : identifier}];
    }
    return modes;
}

char *icli_cc_focus_json(void) {
    NSError *error = nil;
    id state = callWithError(focusService(@"DNDStateService"), "queryCurrentStateWithError:", &error);
    if (!state) {
        return icli_json(@{@"error": error.localizedDescription ?: @"The Do Not Disturb service is unavailable."});
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    BOOL active = sendBool(state, "isActive");
    result[@"active"] = @(active);
    NSArray *modes = focusModes(nil);
    result[@"modes"] = modes;
    id identifier = active ? [state valueForKey:@"activeModeIdentifier"] : nil;
    if ([identifier isKindOfClass:NSString.class]) {
        result[@"mode_id"] = identifier;
        for (NSDictionary *mode in modes)
            if ([mode[@"id"] isEqual:identifier]) result[@"mode"] = mode[@"name"];
    }
    return icli_json_or_empty(result);
}

// Turns a Focus on (`mode` is its identifier) or, with NULL, ends every active
// Focus the way Control Center's module does. Returns 0, -1 when the service
// is missing, or -3 with the reason in `message`.
int icli_cc_focus_set(const char *mode, char **message) {
    id service = focusService(@"DNDModeAssertionService");
    if (!service) return -1;
    NSError *error = nil;
    BOOL ok;
    if (mode) {
        Class details = NSClassFromString(@"DNDModeAssertionDetails");
        SEL make = sel_registerName("userRequestedAssertionDetailsWithIdentifier:modeIdentifier:lifetime:");
        if (![details respondsToSelector:make]) return -1;
        id request = ((id (*)(Class, SEL, NSString *, NSString *, id))objc_msgSend)(
            details, make, FocusAssertion, @(mode), nil);
        SEL take = sel_registerName("takeModeAssertionWithDetails:error:");
        ok = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(service, take, request, &error) != nil;
    } else {
        SEL invalidate = sel_registerName("invalidateAllActiveModeAssertionsWithError:");
        if (![service respondsToSelector:invalidate]) return -1;
        ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(service, invalidate, &error);
    }
    if (!ok) {
        if (message) *message = strdup((error.localizedDescription ?: @"The Do Not Disturb service refused the change.").UTF8String);
        return -3;
    }
    return 0;
}

// MARK: Screen mirroring

// Control Center's rule (MediaControls' mirroring controller): the screen is
// mirrored when the system screen output context routes to a device other
// than the local one. Needs com.apple.avfoundation.allow-system-wide-context.
char *icli_cc_mirroring_json(void) {
    loadFramework("/System/Library/Frameworks/AVFoundation.framework/AVFoundation");
    Class contextClass = NSClassFromString(@"AVOutputContext");
    Class deviceClass = NSClassFromString(@"AVOutputDevice");
    SEL shared = sel_registerName("sharedSystemScreenContext");
    if (![contextClass respondsToSelector:shared] || ![deviceClass respondsToSelector:sel_registerName("sharedLocalDevice")])
        return icli_json(@{@"error": @"The system screen output context is unavailable."});
    id context = ((id (*)(Class, SEL))objc_msgSend)(contextClass, shared);
    if (!context) return icli_json(@{@"error": @"The system screen output context is unavailable."});
    id device = [context respondsToSelector:sel_registerName("outputDevice")]
        ? ((id (*)(id, SEL))objc_msgSend)(context, sel_registerName("outputDevice")) : nil;
    id local = ((id (*)(Class, SEL))objc_msgSend)(deviceClass, sel_registerName("sharedLocalDevice"));
    BOOL mirroring = device && ![device isEqual:local];
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:@(mirroring) forKey:@"mirroring"];
    if (mirroring) {
        id name = [device respondsToSelector:sel_registerName("name")] ? [device valueForKey:@"name"] : nil;
        if ([name isKindOfClass:NSString.class]) result[@"device"] = name;
    }
    return icli_json_or_empty(result);
}
