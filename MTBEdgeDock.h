#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// UI-independent state model. Call on main thread; owner supplies current window safe bounds.
// No timers, observers, global windows, or original-plugin writes.
@interface MTBEdgeDock : NSObject
@property(nonatomic, readonly, getter=isDocked) BOOL docked;
@property(nonatomic, readonly) BOOL rightEdge;
@property(nonatomic, readonly) CGFloat normalizedX;
@property(nonatomic, readonly) CGFloat normalizedY;
- (instancetype)init;
// Safe bounds are in the overlay window coordinate system. Fully visible handle, no cut-off hit area.
- (CGRect)frameInSafeBounds:(CGRect)safeBounds ballSize:(CGSize)ballSize handleSize:(CGSize)handleSize;
// Call after a drag ends. Threshold measured from dragged center to safe edge.
- (void)finishDragAtCenter:(CGPoint)center elementSize:(CGSize)elementSize safeBounds:(CGRect)safeBounds edgeThreshold:(CGFloat)threshold;
// Tapping the handle restores the ball on the same side/Y; does NOT send a MemTrim request.
- (void)expand;
@end
NS_ASSUME_NONNULL_END
