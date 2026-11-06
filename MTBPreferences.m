// Independent extension: never alters MemTrimPrefs.bundle on disk.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import <substrate.h>

static CFStringRef const MTBPrefsDomain = CFSTR("com.knight914.memtrimball");
static CFStringRef const MTBPrefsChanged = CFSTR("com.knight914.memtrimball.preferences-changed");
static NSString * const MTBSwitchID = @"com.knight914.memtrimball.enabled-switch";

@interface MTBPreferenceTarget : NSObject
- (id)mtb_readEnabled:(PSSpecifier *)specifier;
- (void)mtb_writeEnabled:(id)value specifier:(PSSpecifier *)specifier;
@end
@implementation MTBPreferenceTarget
- (id)mtb_readEnabled:(PSSpecifier *)specifier {
    (void)specifier;
    CFPreferencesAppSynchronize(MTBPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Enabled"), MTBPrefsDomain);
    BOOL enabled = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
    if (value) CFRelease(value);
    return @(enabled); // Missing or malformed values fail closed.
}
- (void)mtb_writeEnabled:(id)value specifier:(PSSpecifier *)specifier {
    (void)specifier;
    BOOL enabled = [value respondsToSelector:@selector(boolValue)] && [value boolValue];
    CFPreferencesSetAppValue(CFSTR("Enabled"), enabled ? kCFBooleanTrue : kCFBooleanFalse, MTBPrefsDomain);
    if (CFPreferencesAppSynchronize(MTBPrefsDomain)) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             MTBPrefsChanged, NULL, NULL, true);
    } else {
        NSLog(@"[MemTrimBall] Preferences synchronization failed; no change notification sent.");
    }
}
@end

static MTBPreferenceTarget *MTBTarget;
static NSArray *(*MTBOriginalSpecifiers)(id, SEL);
static Class MTBHookedClass;
static id MTBBundleObserver;

static NSArray *MTBSpecifiers(id self, SEL cmd) {
    NSArray *original = MTBOriginalSpecifiers(self, cmd);
    // Avoid changing arrays owned/cached by the original preference bundle.
    if (original && ![original isKindOfClass:NSArray.class]) return original;
    NSMutableArray *result = original ? [original mutableCopy] : [NSMutableArray array];
    for (PSSpecifier *specifier in result) {
        if ([specifier respondsToSelector:@selector(propertyForKey:)] &&
            [[specifier propertyForKey:@"id"] isEqual:MTBSwitchID]) return result;
    }
    PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
    [group setProperty:@"MemTrimBall" forKey:@"label"];
    [group setProperty:@"默认关闭。启用后可拖至侧边收纳；点击仅发送普通释放请求，长按确认后发送深度请求，不保证释放完成。" forKey:@"footerText"];
    [result addObject:group];
    PSSpecifier *toggle = [PSSpecifier preferenceSpecifierNamed:@"显示悬浮球"
                                                      target:MTBTarget
                                                         set:@selector(mtb_writeEnabled:specifier:)
                                                         get:@selector(mtb_readEnabled:)
                                                      detail:Nil cell:PSSwitchCell edit:Nil];
    [toggle setProperty:MTBSwitchID forKey:@"id"];
    [toggle setProperty:@NO forKey:@"default"];
    [result addObject:toggle];
    return result;
}

static void MTBTryHookPreferences(void) {
    NSCAssert(NSThread.isMainThread, @"Preference hooks must be installed on main thread");
    if (MTBHookedClass) return;
    Class cls = NSClassFromString(@"MTPreferencesController");
    if (!cls || !class_getInstanceMethod(cls, @selector(specifiers))) return;
    NSBundle *bundle = [NSBundle bundleForClass:cls];
    if (![bundle.bundlePath.lastPathComponent isEqualToString:@"MemTrimPrefs.bundle"]) return;
    MTBTarget = [MTBPreferenceTarget new];
    MSHookMessageEx(cls, @selector(specifiers), (IMP)MTBSpecifiers, (IMP *)&MTBOriginalSpecifiers);
    MTBHookedClass = cls;
    if (MTBBundleObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:MTBBundleObserver];
        MTBBundleObserver = nil;
    }
}

__attribute__((constructor)) static void MTBPreferencesInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.Preferences"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Register before probing: covers already-loaded and later-loaded bundles without polling.
            MTBBundleObserver = [NSNotificationCenter.defaultCenter
                addObserverForName:NSBundleDidLoadNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) { MTBTryHookPreferences(); }];
            MTBTryHookPreferences();
        });
    }
}
