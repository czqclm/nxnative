// Compact tools for editing the live pad without presenting or resizing it.
#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DmReflectionPreferences;

@interface DmLiveTouchEditor : UIViewController
// The owner begins runtime editing first, pauses the game and attaches this child.
- (instancetype)initWithPad:(UIView *)pad;
- (instancetype)initWithPad:(UIView *)pad
     reflectionPreferences:(nullable DmReflectionPreferences *)preferences NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)name bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
// All rectangles use the root view's coordinates. The owner supplies view.frame.
// Saving/cancelling calls the runtime API; its notification lets the owner detach us.
- (void)layoutInBounds:(CGRect)bounds safeInsets:(UIEdgeInsets)insets preferredRegion:(CGRect)region;
@end

NS_ASSUME_NONNULL_END
