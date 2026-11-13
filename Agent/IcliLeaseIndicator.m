// The lease indicator: a small label in SpringBoard, just above the home
// indicator, naming the runner that
// holds icli's device lease, so whoever holds the phone sees which agent is
// driving it. The package installs it as a SpringBoard tweak with a bundle
// filter; it hooks nothing.
//
// It does no work while nothing changes. icli posts LeaseChanged whenever it
// writes or removes the lease file; the indicator then reads the file once and
// shows or hides the label. A lease that lapses without a release is hidden
// by a one-shot timer set to its expiry, moved on every renewal.
//
// The label passes touches through, is hidden from accessibility so `ui tree`
// does not read it, and is kept out of screenshots so `screen shot` and OCR
// see the screen as it is without it. Display mirroring still shows it.
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/message.h>

static NSString *const LeasePath = @"/var/mobile/Library/Caches/com.korboy.icli/lease.json";
static NSString *const HiddenPath = @"/var/mobile/Library/Caches/com.korboy.icli/indicator-off";
static const char *const LeaseChanged = "com.korboy.icli.lease-changed";

@interface IcliLeaseIndicator : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) NSTimer *expiry;
+ (instancetype)shared;
- (void)layoutLabel;
@end

// A window SpringBoard draws on top of other apps still takes their touches
// unless the system skips it when it routes them: UIKit asks the window's
// _ignoresHitTest when it sets up its CAContext. userInteractionEnabled alone
// only keeps touches from SpringBoard's own views (measured on iOS 17.1.1:
// with it, a tap on Safari's address field under the label did nothing).
@interface IcliPassThroughWindow : UIWindow
@end

@implementation IcliPassThroughWindow
- (BOOL)_ignoresHitTest { return YES; }
@end

@interface IcliIndicatorViewController : UIViewController
@end

@implementation IcliIndicatorViewController
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [[IcliLeaseIndicator shared] layoutLabel];
}
@end

// Where the home indicator's top edge is, from the indicator view's own
// geometry (MaterialKit's MTLumaDodgePillView: its height and its distance
// from the bottom edge), so the label sits just above it on every device:
// on the iPhone 15 Pro Max that is 5 points tall, 8 points up. 0 on a device
// without one.
static CGFloat homeIndicatorTop(CGSize screen) {
    if (screen.height <= 0) return 0;
    CGFloat bottomInset = 0;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *scene = (UIWindowScene *)candidate;
        if (scene.screen != UIScreen.mainScreen) continue;
        // SpringBoard's status-bar window has zero insets even on Face ID
        // phones. Check all main-screen windows instead of an arbitrary first.
        for (UIWindow *window in scene.windows)
            bottomInset = MAX(bottomInset, window.safeAreaInsets.bottom);
    }
    // A device with a home button has no bottom safe area and no indicator.
    if (bottomInset <= 0) return 0;
    Class pill = NSClassFromString(@"MTLumaDodgePillView");
    SEL edge = sel_registerName("suggestedEdgeSpacing");
    SEL size = sel_registerName("suggestedSizeForContentWidth:");
    if (![pill instancesRespondToSelector:edge] || ![pill instancesRespondToSelector:size]) return 0;
    UIView *view = [[pill alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
    CGFloat spacing = ((CGFloat (*)(id, SEL))objc_msgSend)(view, edge);
    CGSize bar = ((CGSize (*)(id, SEL, CGFloat))objc_msgSend)(view, size, screen.width);
    if (spacing <= 0 || bar.height <= 0) return 0;
    return screen.height - spacing - bar.height;
}

@implementation IcliLeaseIndicator

+ (instancetype)shared {
    static IcliLeaseIndicator *indicator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ indicator = [IcliLeaseIndicator new]; });
    return indicator;
}

- (UIWindowScene *)scene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && ((UIWindowScene *)scene).screen == UIScreen.mainScreen)
            return (UIWindowScene *)scene;
    }
    return nil;
}

- (void)makeWindow {
    UIWindowScene *scene = [self scene];
    UIWindow *window = scene ? [[IcliPassThroughWindow alloc] initWithWindowScene:scene]
                             : [[IcliPassThroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.frame = UIScreen.mainScreen.bounds;
    // Above the status bar, alerts and the lock screen.
    window.windowLevel = 10000002;
    window.userInteractionEnabled = NO;
    window.backgroundColor = UIColor.clearColor;
    window.accessibilityElementsHidden = YES;
    window.rootViewController = [IcliIndicatorViewController new];
    window.rootViewController.view.backgroundColor = UIColor.clearColor;
    window.rootViewController.view.userInteractionEnabled = NO;
    // CALayer's disableUpdateMask bit 1 keeps the layer out of screenshots:
    // measured on iOS 17.1.1, icli's screenshots, OCR and ui tree do not see
    // it, while the wired display mirror still shows it. Bit 4 also
    // hides it from that mirror, so it is left clear.
    SEL mask = sel_registerName("setDisableUpdateMask:");
    if ([window.layer respondsToSelector:mask])
        ((void (*)(id, SEL, unsigned int))objc_msgSend)(window.layer, mask, 1u << 1);
    // CALayer's disableUpdateMask keeps a layer out of screenshots and screen
    // recordings (bits 1 and 4), as the system does for its own overlays.

    UILabel *label = [UILabel new];
    label.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.backgroundColor = [UIColor colorWithRed:0.85 green:0.25 blue:0.1 alpha:0.85];
    label.layer.cornerRadius = 9;
    label.layer.masksToBounds = YES;
    label.accessibilityElementsHidden = YES;
    [window.rootViewController.view addSubview:label];
    self.window = window;
    self.label = label;
}

- (void)layoutLabel {
    if (!self.label) return;
    [self.label sizeToFit];
    CGSize size = self.label.bounds.size;
    // The label belongs to the controller's view. During rotation its bounds
    // can differ from the window's, and layout runs after that view is sized.
    CGRect bounds = self.label.superview.bounds;
    CGSize screen = bounds.size;
    CGFloat width = MIN(size.width + 18, screen.width - 40);
    CGFloat bottom = screen.height - 4;
    CGFloat bar = homeIndicatorTop(screen);
    if (bar > 0) bottom = bar - 3;
    self.label.frame = CGRectMake(bounds.origin.x + (screen.width - width) / 2,
                                 bounds.origin.y + bottom - 18, width, 18);
}

- (NSDictionary *)lease {
    NSData *data = [NSData dataWithContentsOfFile:LeasePath];
    id lease = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![lease isKindOfClass:NSDictionary.class]) return nil;
    id expires = lease[@"expires_at"];
    if (![expires isKindOfClass:NSNumber.class] || [expires doubleValue] <= NSDate.date.timeIntervalSince1970) return nil;
    return lease;
}

- (void)refresh {
    [self.expiry invalidate];
    self.expiry = nil;
    NSDictionary *lease = [NSFileManager.defaultManager fileExistsAtPath:HiddenPath] ? nil : [self lease];
    if (!lease) {
        self.window.hidden = YES;
        return;
    }
    if (!self.window) [self makeWindow];
    id owner = lease[@"owner"];
    self.label.text = [NSString stringWithFormat:@"icli: %@", [owner isKindOfClass:NSString.class] && [owner length] ? owner : @"leased"];
    [self layoutLabel];
    self.window.hidden = NO;
    NSDate *expires = [NSDate dateWithTimeIntervalSince1970:[lease[@"expires_at"] doubleValue]];
    __weak IcliLeaseIndicator *weakSelf = self;
    self.expiry = [NSTimer scheduledTimerWithTimeInterval:MAX(expires.timeIntervalSinceNow, 0) + 0.5 repeats:NO block:^(__unused NSTimer *timer) {
        [weakSelf refresh];
    }];
}

- (void)start {
    int token;
    notify_register_dispatch(LeaseChanged, &token, dispatch_get_main_queue(), ^(__unused int t) {
        [self refresh];
    });
    [self refresh];
}

@end

__attribute__((constructor)) static void IcliLeaseIndicatorLoad(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    // SpringBoard has no scene or screen to draw on until it has launched.
    __block id observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                                          object:nil
                                                                           queue:NSOperationQueue.mainQueue
                                                                      usingBlock:^(__unused NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        observer = nil;
        [[IcliLeaseIndicator shared] start];
    }];
}
