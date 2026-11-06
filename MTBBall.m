// SpringBoard-only overlay. No daemon, cleanup implementation, key window or polling.
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <substrate.h>
#import <math.h>
#import "MTBEdgeDock.h"

static CFStringRef const MTBPrefsDomain = CFSTR("com.knight914.memtrimball");
static const char *MTBPrefsChanged = "com.knight914.memtrimball.preferences-changed";
static const char *MTBLockState = "com.apple.springboard.lockstate";
static const char *MTBDisplayState = "com.apple.iokit.hid.displayStatus";
static const char *MTBNormalRequest = "com.crctdd.memtrim.request.normal";
static const char *MTBDeepRequest = "com.crctdd.memtrim.request.deep";

@class MTBBallController;
@interface MTBOverlayWindow : UIWindow
@property(nonatomic, weak) MTBBallController *owner;
@end
@interface MTBRootController : UIViewController
@property(nonatomic, weak) MTBBallController *owner;
@end
@interface MTBBallController : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) MTBOverlayWindow *window;
@property(nonatomic, strong) MTBRootController *root;
@property(nonatomic, strong) UIView *ball;
@property(nonatomic, strong) UILabel *ballLabel;
@property(nonatomic, strong) UIView *confirmation;
@property(nonatomic, strong) UILabel *feedback;
@property(nonatomic, strong) MTBEdgeDock *dock;
@property(nonatomic, strong) UIPanGestureRecognizer *pan;
@property(nonatomic, strong) UILongPressGestureRecognizer *hold;
@property(nonatomic, strong) UITapGestureRecognizer *tap;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL visibleAllowed;
@property(nonatomic) BOOL dragging;
@property(nonatomic) CGPoint dragOrigin;
@property(nonatomic) NSUInteger feedbackGeneration;
@property(nonatomic) int lockToken;
@property(nonatomic) int displayToken;
@property(nonatomic) int preferenceToken;
@property(nonatomic) BOOL lockRegistered;
@property(nonatomic) BOOL displayRegistered;
@property(nonatomic) BOOL preferenceRegistered;
- (void)start;
- (void)refresh;
- (void)layoutOverlay;
- (void)invalidateGeometry;
- (void)hideImmediately;
- (BOOL)acceptsPoint:(CGPoint)point;
- (void)considerLaunchComplete;
@end

@implementation MTBOverlayWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || ![self.owner acceptsPoint:point]) return nil;
    return [super hitTest:point withEvent:event];
}
@end
@implementation MTBRootController
- (void)loadView { self.view = [UIView new]; self.view.backgroundColor = UIColor.clearColor; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self.owner layoutOverlay]; }
- (void)viewSafeAreaInsetsDidChange { [super viewSafeAreaInsetsDidChange]; [self.owner invalidateGeometry]; }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self.owner invalidateGeometry];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak MTBRootController *weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [weakSelf.owner invalidateGeometry];
    }];
}
@end

// Reject missing/changed private signatures instead of calling an arbitrary ABI.
static BOOL MTBReadUILocked(BOOL *locked) {
    Class cls = NSClassFromString(@"SBLockScreenManager");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL query = NSSelectorFromString(@"isUILocked");
    Method factory = cls ? class_getClassMethod(cls, shared) : NULL;
    Method method = cls ? class_getInstanceMethod(cls, query) : NULL;
    if (!factory || !method || method_getNumberOfArguments(factory) != 2 || method_getNumberOfArguments(method) != 2) return NO;
    char result[16] = {0}, factoryResult[16] = {0};
    method_getReturnType(method, result, sizeof(result));
    method_getReturnType(factory, factoryResult, sizeof(factoryResult));
    if (factoryResult[0] != '@' || (result[0] != 'B' && result[0] != 'c')) return NO;
    id manager = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    if (!manager) return NO;
    *locked = ((BOOL (*)(id, SEL))objc_msgSend)(manager, query);
    return YES;
}

@implementation MTBBallController
- (instancetype)init {
    if ((self = [super init])) {
        _lockToken = _displayToken = _preferenceToken = NOTIFY_TOKEN_INVALID;
        _dock = [MTBEdgeDock new];
    }
    return self;
}
- (BOOL)environmentAllowsUI {
    if (!self.ready || !self.enabled || !self.lockRegistered || !self.displayRegistered || !self.preferenceRegistered) return NO;
    uint64_t lock = UINT64_MAX, display = UINT64_MAX;
    if (notify_get_state(self.lockToken, &lock) != NOTIFY_STATUS_OK ||
        notify_get_state(self.displayToken, &display) != NOTIFY_STATUS_OK) return NO;
    BOOL locked = YES;
    // Only explicitly unlocked + explicitly lit + private UI-unlocked is accepted.
    // Darwin keys/state semantics remain target-device validation gates (see README).
    return lock == 0 && display == 1 && MTBReadUILocked(&locked) && !locked;
}
- (void)loadEnabled {
    CFPreferencesAppSynchronize(MTBPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Enabled"), MTBPrefsDomain);
    self.enabled = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
    if (value) CFRelease(value);
}
- (void)considerLaunchComplete {
    if (self.ready) { [self refresh]; return; }
    UIApplication *app = UIApplication.sharedApplication;
    // Covers injection after didFinishLaunching; never infer readiness from our own window.
    BOOL hasSystemWindow = NO;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class])
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    // SpringBoard can still own legacy non-scene windows on iOS 15/16.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (windows.count == 0) [windows addObjectsFromArray:app.windows];
#pragma clang diagnostic pop
    for (UIWindow *window in windows) {
        if (![window isKindOfClass:MTBOverlayWindow.class]) { hasSystemWindow = YES; break; }
    }
    if (app.delegate && app.applicationState == UIApplicationStateActive && hasSystemWindow) self.ready = YES;
    [self refresh];
}
- (void)start {
    NSCAssert(NSThread.isMainThread, @"UI on main thread only");
    __weak MTBBallController *weakSelf = self;
    self.lockRegistered = notify_register_dispatch(MTBLockState, &_lockToken, dispatch_get_main_queue(), ^(__unused int token) {
        [weakSelf hideImmediately]; [weakSelf considerLaunchComplete];
    }) == NOTIFY_STATUS_OK;
    self.displayRegistered = notify_register_dispatch(MTBDisplayState, &_displayToken, dispatch_get_main_queue(), ^(__unused int token) {
        [weakSelf hideImmediately]; [weakSelf considerLaunchComplete];
    }) == NOTIFY_STATUS_OK;
    self.preferenceRegistered = notify_register_dispatch(MTBPrefsChanged, &_preferenceToken, dispatch_get_main_queue(), ^(__unused int token) {
        [weakSelf loadEnabled]; [weakSelf refresh];
    }) == NOTIFY_STATUS_OK;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(didLaunch:) name:UIApplicationDidFinishLaunchingNotification object:nil];
    [nc addObserver:self selector:@selector(didActivate:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(protectedDataLost:) name:UIApplicationProtectedDataWillBecomeUnavailable object:nil];
    [nc addObserver:self selector:@selector(didActivate:) name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
    [self loadEnabled];
    [self considerLaunchComplete];
}
- (void)didLaunch:(NSNotification *)note { (void)note; self.ready = YES; [self refresh]; }
- (void)didActivate:(NSNotification *)note { (void)note; [self considerLaunchComplete]; }
- (void)protectedDataLost:(NSNotification *)note { (void)note; [self hideImmediately]; }
- (void)hideImmediately {
    self.visibleAllowed = NO;
    self.window.hidden = YES;
    [self closeConfirmation];
    self.dragging = NO;
    self.pan.enabled = NO; self.pan.enabled = YES;
    self.hold.enabled = NO; self.hold.enabled = YES;
    self.feedbackGeneration++;
    self.feedback.hidden = YES;
}
- (void)refresh {
    NSCAssert(NSThread.isMainThread, @"UI on main thread only");
    if (![self environmentAllowsUI]) { [self hideImmediately]; return; }
    if (!self.window) [self createWindow];
    self.visibleAllowed = YES;
    [self layoutOverlay];
    self.window.hidden = NO; // Deliberately never makeKeyWindow/makeKeyAndVisible.
}
- (void)createWindow {
    self.root = [MTBRootController new]; self.root.owner = self;
    // Use SpringBoard's application window scene where available, not another process/scene.
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)candidate; break;
        }
    }
    self.window = scene ? [[MTBOverlayWindow alloc] initWithWindowScene:scene] : [[MTBOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.owner = self;
    self.window.backgroundColor = UIColor.clearColor;
    self.window.windowLevel = UIWindowLevelAlert - 1;
    self.window.rootViewController = self.root;
    self.window.hidden = YES;
    self.ball = [UIView new];
    self.ball.backgroundColor = [UIColor colorWithRed:0.12 green:0.36 blue:0.53 alpha:0.94];
    self.ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    self.ball.layer.borderWidth = 1;
    self.ball.isAccessibilityElement = YES;
    self.ball.accessibilityTraits = UIAccessibilityTraitButton;
    [self.root.view addSubview:self.ball];
    self.ballLabel = [UILabel new];
    self.ballLabel.textColor = UIColor.whiteColor;
    self.ballLabel.textAlignment = NSTextAlignmentCenter;
    self.ballLabel.font = [UIFont boldSystemFontOfSize:14];
    self.ballLabel.userInteractionEnabled = NO;
    [self.ball addSubview:self.ballLabel];
    self.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    self.pan.maximumNumberOfTouches = 1;
    self.hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    self.hold.minimumPressDuration = 0.65;
    self.hold.allowableMovement = 10;
    self.tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    [self.tap requireGestureRecognizerToFail:self.pan];
    [self.tap requireGestureRecognizerToFail:self.hold];
    for (UIGestureRecognizer *recognizer in @[self.pan, self.hold, self.tap]) {
        recognizer.delegate = self;
        [self.ball addGestureRecognizer:recognizer];
    }
    self.feedback = [UILabel new];
    self.feedback.textColor = UIColor.whiteColor;
    self.feedback.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
    self.feedback.font = [UIFont systemFontOfSize:13];
    self.feedback.textAlignment = NSTextAlignmentCenter;
    self.feedback.numberOfLines = 0;
    self.feedback.userInteractionEnabled = NO;
    self.feedback.layer.cornerRadius = 12;
    self.feedback.clipsToBounds = YES;
    self.feedback.hidden = YES;
    [self.root.view addSubview:self.feedback];
}
- (CGRect)safeBounds {
    CGRect bounds = self.root.view.bounds;
    UIEdgeInsets insets = self.root.view.safeAreaInsets;
    insets.top += 8; insets.bottom += 8; insets.left += 8; insets.right += 8;
    CGRect safe = UIEdgeInsetsInsetRect(bounds, insets);
    return CGRectGetWidth(safe) >= 44 && CGRectGetHeight(safe) >= 60 ? safe : CGRectZero;
}
- (void)layoutOverlay {
    if (!self.window) return;
    CGRect safe = [self safeBounds];
    if (CGRectIsEmpty(safe)) { self.ball.hidden = YES; [self closeConfirmation]; return; }
    self.ball.hidden = NO;
    if (!self.dragging) self.ball.frame = [self.dock frameInSafeBounds:safe ballSize:CGSizeMake(56, 56) handleSize:CGSizeMake(44, 60)];
    self.ball.layer.cornerRadius = self.dock.isDocked ? 14 : CGRectGetWidth(self.ball.bounds) / 2;
    self.ballLabel.frame = self.ball.bounds;
    self.ballLabel.text = self.dock.isDocked ? (self.dock.rightEdge ? @"‹" : @"›") : @"MT";
    self.ball.accessibilityLabel = self.dock.isDocked ? @"展开 MemTrim 悬浮球" : @"请求 MemTrim 普通释放";
    self.ball.accessibilityHint = self.dock.isDocked ? @"点击展开，拖动可移动把手" : @"点击发送普通请求，长按显示深度请求确认";
    CGFloat width = MIN(320, CGRectGetWidth(safe));
    self.feedback.frame = CGRectMake(CGRectGetMidX(safe) - width / 2, CGRectGetMinY(safe), width, 64);
    if (self.confirmation) {
        CGFloat height = MIN(210, CGRectGetHeight(safe));
        self.confirmation.frame = CGRectMake(CGRectGetMidX(safe) - width / 2, CGRectGetMidY(safe) - height / 2, width, height);
        UILabel *message = (UILabel *)[self.confirmation viewWithTag:1];
        message.frame = CGRectMake(12, 8, width - 24, MAX(1, height - 64));
        [self.confirmation viewWithTag:2].frame = CGRectMake(8, height - 52, (width - 24) / 2, 44);
        [self.confirmation viewWithTag:3].frame = CGRectMake(16 + (width - 24) / 2, height - 52, (width - 24) / 2, 44);
    }
}
- (void)invalidateGeometry {
    if (self.dragging) { self.dragging = NO; self.pan.enabled = NO; self.pan.enabled = YES; }
    [self closeConfirmation];
    [self layoutOverlay];
}
- (BOOL)acceptsPoint:(CGPoint)point {
    // Revalidate on every incoming hit, including the confirm button hit.
    if (!self.visibleAllowed || ![self environmentAllowsUI]) { [self hideImmediately]; return NO; }
    if (self.confirmation) return CGRectContainsPoint(self.confirmation.frame, point);
    return !self.ball.hidden && CGRectContainsPoint(self.ball.frame, point);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (![self environmentAllowsUI] || self.confirmation) return NO;
    return recognizer != self.hold || !self.dock.isDocked;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)one shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)two {
    (void)one; (void)two; return NO;
}
- (void)drag:(UIPanGestureRecognizer *)recognizer {
    if (![self environmentAllowsUI]) { [self hideImmediately]; return; }
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self closeConfirmation]; self.feedback.hidden = YES;
            self.dragging = YES; self.dragOrigin = self.ball.center;
            break;
        case UIGestureRecognizerStateChanged: {
            CGRect safe = [self safeBounds];
            CGPoint offset = [recognizer translationInView:self.root.view];
            CGFloat halfW = CGRectGetWidth(self.ball.bounds) / 2;
            CGFloat halfH = CGRectGetHeight(self.ball.bounds) / 2;
            self.ball.center = CGPointMake(MAX(CGRectGetMinX(safe) + halfW, MIN(CGRectGetMaxX(safe) - halfW, self.dragOrigin.x + offset.x)),
                                          MAX(CGRectGetMinY(safe) + halfH, MIN(CGRectGetMaxY(safe) - halfH, self.dragOrigin.y + offset.y)));
            break;
        }
        case UIGestureRecognizerStateEnded:
            if (self.dragging) [self.dock finishDragAtCenter:self.ball.center elementSize:self.ball.bounds.size safeBounds:[self safeBounds] edgeThreshold:48];
            self.dragging = NO; [self layoutOverlay]; break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.dragging = NO; [self layoutOverlay]; break;
        default: break;
    }
}
- (void)tapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized) return;
    if (![self environmentAllowsUI]) { [self hideImmediately]; return; }
    if (self.dock.isDocked) { [self.dock expand]; [self layoutOverlay]; return; }
    [self sendRequest:MTBNormalRequest];
}
- (void)longPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || self.dock.isDocked || self.dragging) return;
    if (![self environmentAllowsUI]) { [self hideImmediately]; return; }
    [self closeConfirmation];
    self.feedback.hidden = YES;
    UIView *panel = [UIView new];
    panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.98];
    panel.layer.cornerRadius = 16;
    panel.accessibilityViewIsModal = YES;
    UILabel *message = [UILabel new]; message.tag = 1;
    message.text = @"请求深度释放？\n可能影响后台应用。这里只发送请求，不代表清理完成。";
    message.textColor = UIColor.whiteColor; message.numberOfLines = 0;
    message.font = [UIFont systemFontOfSize:15]; message.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:message];
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem]; cancel.tag = 2;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(closeConfirmation) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:cancel];
    UIButton *confirm = [UIButton buttonWithType:UIButtonTypeSystem]; confirm.tag = 3;
    [confirm setTitle:@"发送深度请求" forState:UIControlStateNormal];
    [confirm setTitleColor:UIColor.systemOrangeColor forState:UIControlStateNormal];
    [confirm addTarget:self action:@selector(confirmDeep) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:confirm];
    self.confirmation = panel;
    [self.root.view addSubview:panel];
    self.ball.accessibilityElementsHidden = YES;
    [self layoutOverlay];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, message);
}
- (void)closeConfirmation {
    [self.confirmation removeFromSuperview]; self.confirmation = nil;
    self.ball.accessibilityElementsHidden = NO;
}
- (void)confirmDeep {
    if (!self.confirmation) return;
    [self closeConfirmation];
    [self sendRequest:MTBDeepRequest];
}
- (void)sendRequest:(const char *)name {
    if (![self environmentAllowsUI]) { [self hideImmediately]; return; }
    uint32_t status = notify_post(name);
    self.feedback.text = status == NOTIFY_STATUS_OK ? @"已请求 MemTrim；不代表清理完成" : @"请求发送失败";
    self.feedback.hidden = NO;
    [self layoutOverlay];
    NSUInteger generation = ++self.feedbackGeneration;
    __weak MTBBallController *weakSelf = self;
    // One-shot feedback dismissal only. No periodic lock/display queries or polling.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.feedbackGeneration == generation) weakSelf.feedback.hidden = YES;
    });
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.feedback.text);
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_lockToken != NOTIFY_TOKEN_INVALID) notify_cancel(_lockToken);
    if (_displayToken != NOTIFY_TOKEN_INVALID) notify_cancel(_displayToken);
    if (_preferenceToken != NOTIFY_TOKEN_INVALID) notify_cancel(_preferenceToken);
}
@end

static MTBBallController *MTBController;
__attribute__((constructor)) static void MTBBallInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            MTBController = [MTBBallController new];
            [MTBController start];
        });
    }
}
