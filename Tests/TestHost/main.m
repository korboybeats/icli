#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>
#import <Vision/Vision.h>
#import <Security/Security.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

// Test-only application. Its state file is an independent oracle for CLI tests.
static NSString *const StatePath = @"/var/mobile/Library/Caches/icli-testhost/state.json";

@interface TestController : UIViewController <UITextViewDelegate, UIScrollViewDelegate, UINavigationControllerDelegate>
@property(nonatomic) NSMutableDictionary *state;
@property(nonatomic) UITextView *input;
@property(nonatomic) UILabel *status;
@property(nonatomic) UILabel *delayed;
@property(nonatomic) UIView *dragTarget;
@property(nonatomic) CGPoint dragStart;
@property(nonatomic) UIImage *ocrImage;
@property(nonatomic) AVAudioPlayer *player;
@property(nonatomic) UIButton *incrementButton;
@property(nonatomic) NSTimeInterval toggleDelay;
@property(nonatomic) NSUInteger toggleGeneration;
@property(nonatomic) BOOL directActivation;
@property(nonatomic) BOOL rejectActivation;
- (void)save;
@property(nonatomic) BOOL keyboardVisible;
@property(nonatomic) NSInteger resetGeneration;
@property(nonatomic) CLLocationManager *locationManager;
- (void)reset;
- (void)handleURL:(NSURL *)url;
@end

@interface ActivationProbeButton : UIButton
@property(nonatomic, weak) TestController *controller;
@end
@implementation ActivationProbeButton
- (BOOL)accessibilityActivate {
    BOOL handled;
    if (self.controller.directActivation && self.enabled) {
        [self sendActionsForControlEvents:UIControlEventTouchUpInside];
        handled = !self.controller.rejectActivation;
    } else {
        handled = [super accessibilityActivate];
    }
    self.controller.state[@"activation_calls"] = @([self.controller.state[@"activation_calls"] intValue] + 1);
    self.controller.state[@"activation_handled"] = @(handled);
    [self.controller save];
    return handled;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.controller.state[@"touch_began"] = @([self.controller.state[@"touch_began"] intValue] + 1);
    [self.controller save];
    [super touchesBegan:touches withEvent:event];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.controller.state[@"touch_ended"] = @([self.controller.state[@"touch_ended"] intValue] + 1);
    [self.controller save];
    [super touchesEnded:touches withEvent:event];
}
@end

@implementation TestController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.state = [NSMutableDictionary dictionary];
    self.locationManager = [CLLocationManager new];
    for (NSNotificationName name in @[UIContentSizeCategoryDidChangeNotification,
                                      UIAccessibilityReduceMotionStatusDidChangeNotification,
                                      UIAccessibilityReduceTransparencyStatusDidChangeNotification,
                                      UIAccessibilityDarkerSystemColorsStatusDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(save) name:name object:nil];
    }
    [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardDidShowNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        self.keyboardVisible = YES;
        [self save];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardDidHideNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        self.keyboardVisible = NO;
        [self save];
    }];
    UIScreenEdgePanGestureRecognizer *edgePan =
        [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgePanned:)];
    edgePan.edges = UIRectEdgeLeft;
    [self.view addGestureRecognizer:edgePan];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(24, 65, 370, 40)];
    title.text = @"icli TestHost";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.accessibilityIdentifier = @"screen.title";
    [self.view addSubview:title];
    self.input = [[UITextView alloc] initWithFrame:CGRectMake(24, 120, 360, 90)];
    self.input.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.input.font = [UIFont systemFontOfSize:20];
    self.input.autocorrectionType = UITextAutocorrectionTypeNo;
    self.input.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.input.smartQuotesType = UITextSmartQuotesTypeNo;
    self.input.smartDashesType = UITextSmartDashesTypeNo;
    self.input.delegate = self;
    self.input.accessibilityLabel = @"Test input";
    self.input.accessibilityIdentifier = @"input.text";
    [self.view addSubview:self.input];
    ActivationProbeButton *button = [ActivationProbeButton buttonWithType:UIButtonTypeSystem];
    button.controller = self;
    button.frame = CGRectMake(24, 225, 170, 44);
    [button setTitle:@"Increment" forState:UIControlStateNormal];
    button.accessibilityIdentifier = @"counter.increment";
    self.incrementButton = button;
    [button addTarget:self action:@selector(increment:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    UIButton *toggle = [UIButton buttonWithType:UIButtonTypeSystem];
    toggle.frame = CGRectMake(210, 225, 174, 44);
    [toggle setTitle:@"Delayed element" forState:UIControlStateNormal];
    toggle.accessibilityIdentifier = @"element.toggle";
    [toggle addTarget:self action:@selector(toggleDelayed:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:toggle];
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(24, 275, 360, 28)];
    self.status.accessibilityIdentifier = @"counter.status";
    [self.view addSubview:self.status];
    self.delayed = [[UILabel alloc] initWithFrame:CGRectMake(24, 307, 360, 30)];
    self.delayed.text = @"Ready element";
    self.delayed.accessibilityIdentifier = @"element.ready";
    [self.view addSubview:self.delayed];
    UIView *gestures = [[UIView alloc] initWithFrame:CGRectMake(24, 350, 360, 100)];
    gestures.backgroundColor = UIColor.systemTealColor;
    gestures.isAccessibilityElement = YES;
    gestures.accessibilityLabel = @"Gesture area";
    gestures.accessibilityIdentifier = @"gesture.area";
    [self.view addSubview:gestures];
    UITapGestureRecognizer *doubleTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapped:)];
    doubleTap.numberOfTapsRequired = 2;
    [gestures addGestureRecognizer:doubleTap];
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
    longPress.minimumPressDuration = 0.4;
    [gestures addGestureRecognizer:longPress];
    [gestures addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinched:)]];
    self.dragTarget = [[UIView alloc] initWithFrame:CGRectMake(24, 470, 60, 60)];
    self.dragTarget.backgroundColor = UIColor.systemOrangeColor;
    self.dragTarget.isAccessibilityElement = YES;
    self.dragTarget.accessibilityLabel = @"Drag target";
    self.dragTarget.accessibilityIdentifier = @"drag.target";
    [self.dragTarget
        addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)]];
    [self.view addSubview:self.dragTarget];
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(24, 550, 360, 100)];
    scroll.contentSize = CGSizeMake(360, 900);
    scroll.backgroundColor = UIColor.secondarySystemBackgroundColor;
    scroll.accessibilityIdentifier = @"scroll.list";
    scroll.delegate = self;
    for(int i=0;i<20;i++) {
        UILabel *row = [[UILabel alloc] initWithFrame:CGRectMake(10, i*44, 330, 40)];
        row.text = [NSString stringWithFormat:@"Row %d",i];
        [scroll addSubview:row];
    }
    [self.view addSubview:scroll];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(360, 80)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.whiteColor setFill]; [context fillRect:CGRectMake(0,0,360,80)];
        [@"HELLO 123" drawAtPoint:CGPointMake(8,4) withAttributes:@{
            NSFontAttributeName:[UIFont boldSystemFontOfSize:28],
            NSForegroundColorAttributeName:UIColor.blackColor
        }];
        [@"中文测试" drawAtPoint:CGPointMake(8,40) withAttributes:@{
            NSFontAttributeName:[UIFont systemFontOfSize:26],
            NSForegroundColorAttributeName:UIColor.blackColor
        }];
    }];
    self.ocrImage = image;
    UIImageView *ocr = [[UIImageView alloc] initWithImage:image];
    ocr.frame = CGRectMake(24, 670, 360, 80);
    ocr.isAccessibilityElement = NO;
    [self.view addSubview:ocr];
    [self reset];
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "icli-testhost-heartbeat");
    }];
}
- (void)edgePanned:(UIScreenEdgePanGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) return;
    self.state[@"edge_pans"] = @([self.state[@"edge_pans"] intValue] + 1);
    [self save];
}
- (void)navigationController:(UINavigationController *)nav didShowViewController:(UIViewController *)shown animated:(BOOL)animated {
    self.state[@"nav_depth"] = @(nav.viewControllers.count);
    [self save];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (self.state) [self save];
}
- (void)save {
    self.state[@"text"] = self.input.text ?: @"";
    self.state[@"delayed_visible"] = @(!self.delayed.hidden);
    self.state[@"drag_x"] = @(self.dragTarget.center.x);
    self.state[@"drag_y"] = @(self.dragTarget.center.y);
    self.state[@"counter"] = self.state[@"counter"] ?: @0;
    self.state[@"launch_arguments"] = NSProcessInfo.processInfo.arguments;
    self.state[@"launch_env"] = NSProcessInfo.processInfo.environment[@"ICLI_TEST"] ?: @"";
    self.state[@"language"] = NSLocale.preferredLanguages.firstObject ?: @"";
    self.state[@"locale"] = NSLocale.currentLocale.localeIdentifier ?: @"";
    self.state[@"interface_style"] = @(self.traitCollection.userInterfaceStyle);
    self.state[@"content_size"] = UIApplication.sharedApplication.preferredContentSizeCategory ?: @"";
    self.state[@"reduce_motion"] = @(UIAccessibilityIsReduceMotionEnabled());
    self.state[@"reduce_transparency"] = @(UIAccessibilityIsReduceTransparencyEnabled());
    self.state[@"darker_colors"] = @(UIAccessibilityDarkerSystemColorsEnabled());
    self.state[@"keyboard_visible"] = @(self.keyboardVisible);
    self.state[@"reset_generation"] = @(self.resetGeneration);
    self.state[@"camera_status"] = @([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]);
    self.state[@"microphone_status"] = @([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]);
    if (@available(iOS 14.0, *)) self.state[@"location_status"] = @(self.locationManager.authorizationStatus);
    self.status.text = [NSString stringWithFormat:@"Count: %@",self.state[@"counter"]];
    self.status.accessibilityValue = [self.state[@"counter"] stringValue];
    [[NSFileManager defaultManager] createDirectoryAtPath:StatePath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [[NSJSONSerialization dataWithJSONObject:self.state options:NSJSONWritingSortedKeys error:nil]
        writeToFile:StatePath
         atomically:YES];
}
- (void)reset {
    self.directActivation = NO;
    self.rejectActivation = NO;
    self.incrementButton.frame = CGRectMake(24, 225, 170, 44);
    [self.incrementButton removeTarget:self action:NULL forControlEvents:UIControlEventTouchUpInside];
    [self.incrementButton addTarget:self action:@selector(increment:) forControlEvents:UIControlEventTouchUpInside];
    self.toggleGeneration++;
    self.toggleDelay = 1;
    self.incrementButton.enabled = YES;
    for (UIView *view in [self.view.subviews copy]) {
        if (view.tag == 7301) [view removeFromSuperview];
    }
    [self.input resignFirstResponder];
    if (self.presentedViewController) [self dismissViewControllerAnimated:NO completion:nil];
    [self.state removeAllObjects];
    self.resetGeneration++;
    self.input.text = @"";
    self.delayed.hidden = YES;
    self.dragTarget.center = CGPointMake(54,500);
    for (UIView *view in self.view.subviews) {
        if ([view isKindOfClass:UIScrollView.class] && view != self.input)
            [(UIScrollView *)view setContentOffset:CGPointZero animated:NO];
    }
    [self save];
}
- (void)increment:(id)sender {
    self.state[@"counter"] = @([self.state[@"counter"] intValue]+1);
    [self.input resignFirstResponder];
    [self save];
}
- (void)toggleDelayed:(id)sender {
    NSUInteger generation = self.toggleGeneration;
    self.state[@"toggle_taps"] = @([self.state[@"toggle_taps"] intValue] + 1);
    [self save];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.toggleDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.toggleGeneration) return;
        self.delayed.hidden = !self.delayed.hidden;
        [self save];
    });
}
- (void)doubleTapped:(id)sender {
    self.state[@"double_taps"] = @([self.state[@"double_taps"] intValue]+1);
    [self save];
}
- (void)longPressed:(UILongPressGestureRecognizer *)recognizer {
    if(recognizer.state==UIGestureRecognizerStateBegan){
        self.state[@"long_presses"] = @([self.state[@"long_presses"] intValue]+1);
        [self save];
    }
}
- (void)pinched:(UIPinchGestureRecognizer *)recognizer {
    self.state[@"pinch_scale"]=@(recognizer.scale);
    self.state[@"pinch_events"]=@([self.state[@"pinch_events"] intValue]+1);
    [self save];
}
- (void)dragged:(UIPanGestureRecognizer *)recognizer {
    if(recognizer.state==UIGestureRecognizerStateBegan)self.dragStart=self.dragTarget.center;
    CGPoint delta=[recognizer translationInView:self.view];
    self.dragTarget.center=CGPointMake(self.dragStart.x+delta.x,self.dragStart.y+delta.y);
    self.state[@"drag_events"]=@([self.state[@"drag_events"] intValue]+1);
    [self save];
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if(scrollView==self.input)return;
    self.state[@"scroll_y"]=@(scrollView.contentOffset.y);
    [self save];
}
- (void)textViewDidChange:(UITextView *)textView { [self save]; }
- (void)handleURL:(NSURL *)url {
    if([url.host isEqual:@"reset"]) [self reset];
    else if([url.host isEqual:@"verified-direct"]) self.directActivation = YES;
    else if([url.host isEqual:@"verified-direct-reject"]) {
        self.directActivation = YES;
        self.rejectActivation = YES;
    }
    else if([url.host isEqual:@"verified-replace"]) {
        CGRect old = self.incrementButton.frame;
        [self.incrementButton removeFromSuperview];
        ActivationProbeButton *replacement = [ActivationProbeButton buttonWithType:UIButtonTypeSystem];
        replacement.controller = self;
        replacement.frame = old;
        [replacement setTitle:@"Replacement" forState:UIControlStateNormal];
        replacement.accessibilityIdentifier = @"counter.increment";
        [replacement addTarget:self action:@selector(verifiedOtherTap:) forControlEvents:UIControlEventTouchUpInside];
        self.incrementButton = replacement;
        [self.view addSubview:replacement];
    }
    else if([url.host isEqual:@"verified-relocate"]) {
        CGRect old = self.incrementButton.frame;
        self.incrementButton.frame = CGRectMake(210, 460, 174, 44);
        UIButton *decoy = [UIButton buttonWithType:UIButtonTypeSystem];
        decoy.tag = 7301;
        decoy.frame = old;
        [decoy setTitle:@"Decoy" forState:UIControlStateNormal];
        decoy.accessibilityIdentifier = @"counter.decoy";
        [decoy addTarget:self action:@selector(verifiedOtherTap:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:decoy];
    }
    else if([url.host isEqual:@"verified-disabled"]) self.incrementButton.enabled = NO;
    else if([url.host isEqual:@"verified-slow"]) self.toggleDelay = 3;
    else if([url.host isEqual:@"verified-duplicate"] || [url.host isEqual:@"verified-label"]
            || [url.host isEqual:@"verified-overlay"]) {
        UIButton *fixture = [UIButton buttonWithType:UIButtonTypeSystem];
        fixture.tag = 7301;
        BOOL overlay = [url.host isEqual:@"verified-overlay"];
        fixture.frame = overlay ? self.incrementButton.frame : CGRectMake(210, 460, 174, 44);
        [fixture setTitle:overlay ? @"Overlay" : @"Increment" forState:UIControlStateNormal];
        fixture.backgroundColor = UIColor.systemBackgroundColor;
        fixture.accessibilityIdentifier = overlay ? @"counter.overlay"
            : ([url.host isEqual:@"verified-label"] ? @"counter.other" : @"counter.increment");
        [fixture addTarget:self action:@selector(verifiedOtherTap:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:fixture];
    }
    else if([url.host isEqual:@"permission-camera"] || [url.host isEqual:@"permission-microphone"]) {
        // A real permission alert, drawn by the system outside this app. iOS asks
        // once per app, so this suits a manual check rather than a repeatable case.
        [AVCaptureDevice requestAccessForMediaType:[url.host hasSuffix:@"camera"] ? AVMediaTypeVideo : AVMediaTypeAudio
                                 completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.state[@"permission_granted"] = @(granted);
                [self save];
            });
        }];
    }
    else if([url.host isEqual:@"partial-match"]) {
        UIButton *fixture = [UIButton buttonWithType:UIButtonTypeSystem];
        fixture.tag = 7301;
        fixture.frame = CGRectMake(210, 460, 174, 44);
        [fixture setTitle:@"Increment more" forState:UIControlStateNormal];
        fixture.accessibilityIdentifier = @"counter.more";
        [fixture addTarget:self action:@selector(verifiedOtherTap:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:fixture];
    }
    else if([url.host isEqual:@"alert"] || [url.host isEqual:@"alert-passcode"]) {
        BOOL passcode = [url.host isEqual:@"alert-passcode"];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:passcode ? @"Enter iPhone Passcode" : @"Fixture alert"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        for (NSString *title in @[@"Don\u2019t Allow", @"Allow"]) {
            [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                self.state[@"alert_result"] = title;
                [self save];
            }]];
        }
        [self presentViewController:alert animated:NO completion:nil];
    }
    else if([url.host isEqual:@"nav"]) {
        UIViewController *root = [UIViewController new];
        root.title = @"Nav root";
        root.view.backgroundColor = UIColor.systemBackgroundColor;
        UIViewController *pushed = [UIViewController new];
        pushed.title = @"Nav pushed";
        pushed.view.backgroundColor = UIColor.systemBackgroundColor;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        nav.delegate = self;
        [self presentViewController:nav animated:NO completion:^{ [nav pushViewController:pushed animated:NO]; }];
    }
    else if([url.host isEqual:@"refresh"]) [self save];
    else if([url.host isEqual:@"focus"]) [self.input becomeFirstResponder];
    else if([url.host isEqual:@"blur"]) [self.input resignFirstResponder];
    else if([url.host isEqual:@"toggle"]) [self toggleDelayed:nil];
    else if([url.host isEqual:@"clipboard-set"]) UIPasteboard.generalPasteboard.string = @"TestHost clipboard 中文 🌱";
    else if([url.host isEqual:@"clipboard-read"])
        self.state[@"clipboard"] = UIPasteboard.generalPasteboard.string ?: @"";
    else if([url.host isEqual:@"brightness-set"]) UIScreen.mainScreen.brightness = 0.25;
    else if([url.host isEqual:@"brightness-reset"]) UIScreen.mainScreen.brightness = 0.5;
    else if([url.host isEqual:@"audio-start"]) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        unsigned char header[44] = {
            'R','I','F','F',0x24,0x7d,0,0,'W','A','V','E',
            'f','m','t',' ',16,0,0,0,1,0,1,0,0x40,0x1f,0,0,0x80,0x3e,0,0,2,0,16,0,
            'd','a','t','a',0,0x7d,0,0
        };
        NSMutableData *wave=[NSMutableData dataWithBytes:header length:44]; [wave increaseLengthBy:32000];
        self.player=[[AVAudioPlayer alloc] initWithData:wave error:nil]; self.player.numberOfLoops=-1;
        self.state[@"audio_playing"]=@([self.player play]);
    }
    else if([url.host isEqual:@"audio-stop"]) {
        [self.player stop];
        [[AVAudioSession sharedInstance] setActive:NO error:nil];
    }
    else if([url.host isEqual:@"ocr"]) {
        VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.recognitionLanguages = @[@"en-US", @"zh-Hans"];
        NSError *error = nil;
        BOOL ok = [[[VNImageRequestHandler alloc] initWithCGImage:self.ocrImage.CGImage options:@{}]
            performRequests:@[request]
                      error:&error];
        NSMutableArray *texts = [NSMutableArray array];
        for(VNRecognizedTextObservation *result in request.results)
            [texts addObject:[result topCandidates:1].firstObject.string ?: @""];
        self.state[@"ocr"] = @{@"ok": @(ok), @"error": error.description ?: @"", @"texts": texts};
    }
    else if([url.host isEqual:@"network-probe"]) {
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(54321);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        const char payload[] = "icli acceptance packet";
        ssize_t sent = sendto(fd, payload, sizeof(payload), 0, (struct sockaddr *)&address, sizeof(address));
        if (fd >= 0) close(fd);
        self.state[@"network_bytes"] = @(sent);
    }
    else if([url.host isEqual:@"keychain-probe"]) {
        NSString *service = [@"icli.testhost." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService:service, (__bridge id)kSecAttrAccount:@"acceptance"};
        NSMutableDictionary *item = [query mutableCopy];
        item[(__bridge id)kSecValueData] = [@"testhost-fixture" dataUsingEncoding:NSUTF8StringEncoding];
        OSStatus added = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        NSMutableDictionary *lookup = [query mutableCopy];
        lookup[(__bridge id)kSecReturnData] = @YES;
        CFTypeRef found = NULL;
        OSStatus read = SecItemCopyMatching((__bridge CFDictionaryRef)lookup, &found);
        BOOL matches = found && [(__bridge id)found isEqual:item[(__bridge id)kSecValueData]];
        if (found) CFRelease(found);
        OSStatus removed = SecItemDelete((__bridge CFDictionaryRef)query);
        self.state[@"keychain"] = @{
            @"add_status":@(added),
            @"read_status":@(read),
            @"matches":@(matches),
            @"delete_status":@(removed)
        };
    }
    else if([url.host isEqual:@"crash"]) abort();
    self.state[@"last_url"] = url.absoluteString;
    [self save];
}
- (void)verifiedOtherTap:(id)sender {
    self.state[@"other_taps"] = @([self.state[@"other_taps"] intValue] + 1);
    [self save];
}
@end

// UIKit in iOS 27 stops an app built with that SDK at launch unless it uses
// the scene life cycle (UIKit/assert_for_no_scene_lifecycle), so the window
// and the URLs come through a scene delegate.
@interface TestDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) TestController *controller;
@end
@implementation TestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.controller=[TestController new];
    // The container fixture has no URL scheme and cannot reach the shared state
    // file; it reports what cfprefsd serves it in its own container at launch.
    if ([NSBundle.mainBundle.bundleIdentifier hasSuffix:@".ContainerFixture"]) {
        NSMutableDictionary *seen = [NSMutableDictionary dictionary];
        [NSUserDefaults.standardUserDefaults.dictionaryRepresentation
            enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
                if ([key hasPrefix:@"icli-acceptance-"]) seen[key] = value;
            }];
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/icli-prefs-seen.json"];
        [[NSJSONSerialization dataWithJSONObject:seen options:0 error:nil] writeToFile:path atomically:YES];
    }
    return YES;
}
@end

@interface TestSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic) UIWindow *window;
@end
@implementation TestSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    TestController *controller=((TestDelegate *)UIApplication.sharedApplication.delegate).controller;
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController=controller;
    [self.window makeKeyAndVisible];
    for(UIOpenURLContext *context in options.URLContexts) [controller handleURL:context.URL];
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    TestController *controller=((TestDelegate *)UIApplication.sharedApplication.delegate).controller;
    for(UIOpenURLContext *context in contexts) [controller handleURL:context.URL];
}
@end
int main(int argc,char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc,argv,nil,NSStringFromClass(TestDelegate.class));
    }
}
