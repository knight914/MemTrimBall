#import "MTBEdgeDock.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static CFStringRef const MTBDockDomain = CFSTR("com.knight914.memtrimball");
static CGFloat MTBClampUnit(CGFloat value) { return isfinite(value) ? MIN(1, MAX(0, value)) : 0.5; }
static CGFloat MTBReadCoordinate(CFStringRef key, CGFloat fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, MTBDockDomain);
    double coordinate = fallback;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &coordinate);
    if (value) CFRelease(value);
    return MTBClampUnit(coordinate);
}
static BOOL MTBReadFlag(CFStringRef key, BOOL fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, MTBDockDomain);
    BOOL flag = fallback;
    if (value && CFGetTypeID(value) == CFBooleanGetTypeID()) flag = CFBooleanGetValue((CFBooleanRef)value);
    if (value) CFRelease(value);
    return flag;
}

@interface MTBEdgeDock ()
@property(nonatomic, readwrite, getter=isDocked) BOOL docked;
@property(nonatomic, readwrite) BOOL rightEdge;
@property(nonatomic, readwrite) CGFloat normalizedX;
@property(nonatomic, readwrite) CGFloat normalizedY;
@end

@implementation MTBEdgeDock
- (instancetype)init {
    if ((self = [super init])) {
        CFPreferencesAppSynchronize(MTBDockDomain);
        _normalizedX = MTBReadCoordinate(CFSTR("PositionX"), 1.0);
        _normalizedY = MTBReadCoordinate(CFSTR("PositionY"), 0.5);
        _docked = MTBReadFlag(CFSTR("Docked"), NO);
        _rightEdge = MTBReadFlag(CFSTR("RightEdge"), YES);
    }
    return self;
}
- (void)persist {
    // Separate keys avoid overwriting Enabled when Settings changes it concurrently.
    NSDictionary *values = @{@"PositionX": @(self.normalizedX), @"PositionY": @(self.normalizedY),
                             @"Docked": @(self.docked), @"RightEdge": @(self.rightEdge)};
    CFPreferencesSetMultiple((__bridge CFDictionaryRef)values, NULL, MTBDockDomain,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!CFPreferencesAppSynchronize(MTBDockDomain))
        NSLog(@"[MemTrimBall] Position preference synchronization failed.");
}
- (CGRect)frameInSafeBounds:(CGRect)bounds ballSize:(CGSize)ballSize handleSize:(CGSize)handleSize {
    if (CGRectIsEmpty(bounds) || CGRectIsNull(bounds) || CGRectIsInfinite(bounds)) return CGRectZero;
    CGSize size = self.docked ? handleSize : ballSize;
    size.width = MIN(MAX(1, size.width), CGRectGetWidth(bounds));
    size.height = MIN(MAX(1, size.height), CGRectGetHeight(bounds));
    CGFloat x = self.docked ? (self.rightEdge ? 1 : 0) : self.normalizedX;
    return CGRectMake(CGRectGetMinX(bounds) + x * (CGRectGetWidth(bounds) - size.width),
                      CGRectGetMinY(bounds) + self.normalizedY * (CGRectGetHeight(bounds) - size.height),
                      size.width, size.height);
}
- (void)finishDragAtCenter:(CGPoint)center elementSize:(CGSize)elementSize safeBounds:(CGRect)bounds edgeThreshold:(CGFloat)threshold {
    if (CGRectIsEmpty(bounds) || CGRectIsNull(bounds) || CGRectIsInfinite(bounds) ||
        !isfinite(center.x) || !isfinite(center.y)) return;
    // Map the final center using the actual current element size before changing its docked state.
    if (!isfinite(elementSize.width) || !isfinite(elementSize.height)) return;
    CGSize oldSize = CGSizeMake(MIN(MAX(1, elementSize.width), CGRectGetWidth(bounds)),
                                MIN(MAX(1, elementSize.height), CGRectGetHeight(bounds)));
    CGFloat usableWidth = MAX(0, CGRectGetWidth(bounds) - oldSize.width);
    CGFloat usableHeight = MAX(0, CGRectGetHeight(bounds) - oldSize.height);
    self.normalizedX = usableWidth > 0 ? MTBClampUnit((center.x - CGRectGetMinX(bounds) - oldSize.width / 2) / usableWidth) : 0.5;
    self.normalizedY = usableHeight > 0 ? MTBClampUnit((center.y - CGRectGetMinY(bounds) - oldSize.height / 2) / usableHeight) : 0.5;
    CGFloat left = center.x - CGRectGetMinX(bounds);
    CGFloat right = CGRectGetMaxX(bounds) - center.x;
    self.rightEdge = right < left;
    self.docked = MIN(left, right) <= MAX(0, threshold);
    if (self.docked) self.normalizedX = self.rightEdge ? 1 : 0;
    [self persist];
}
- (void)expand {
    if (!self.docked) return;
    self.docked = NO;
    self.normalizedX = self.rightEdge ? 1 : 0;
    [self persist];
}
@end
