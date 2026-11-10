// The lease indicator: a small label in SpringBoard naming the runner that
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

static NSString *const LeasePath = @"/var/mobile/Library/Caches/com.icli.icli/lease.json";
static NSString *const HiddenPath = @"/var/mobile/Library/Caches/com.icli.icli/indicator-off";
static const char *const LeaseChanged = "com.icli.icli.lease-changed";

@interface IcliLeaseIndicator : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) NSTimer *expiry;
@end

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
    UIWindow *window = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.frame = UIScreen.mainScreen.bounds;
    // Above the status bar, alerts and the lock screen.
    window.windowLevel = 10000002;
    window.userInteractionEnabled = NO;
    window.backgroundColor = UIColor.clearColor;
    window.accessibilityElementsHidden = YES;
    window.rootViewController = [UIViewController new];
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
    [self.label sizeToFit];
    CGSize size = self.label.bounds.size;
    CGFloat width = MIN(size.width + 18, UIScreen.mainScreen.bounds.size.width - 40);
    // Just under the status bar and the Dynamic Island.
    CGFloat top = MAX(self.window.safeAreaInsets.top, 20) + 2;
    self.label.frame = CGRectMake((UIScreen.mainScreen.bounds.size.width - width) / 2, top, width, 18);
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
