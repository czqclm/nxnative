// Live, hinge-driven reflection below the game, using public composition APIs.
#pragma once
#import <UIKit/UIKit.h>
#import "DmReflectionStyle.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const DmControlReflectionDidChangeNotification;
// The unset preference defaults to YES; standard defaults keep it per app.
FOUNDATION_EXPORT BOOL dm_control_reflection_enabled(void);
FOUNDATION_EXPORT CGFloat dm_control_reflection_opacity(DmReflectionStyle style,
    CGFloat distance, CGFloat regionHeight);

@interface DmControlReflection : NSObject
@property(nonatomic, readonly, getter=isActive) BOOL active;
- (instancetype)initWithRootView:(UIView *)root gameView:(UIView *)game NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
// Main-thread only. All rectangles remain in root coordinates. The same game
// view and its Metal layer are retained across attachment and removal.
- (void)updateWithBounds:(CGRect)bounds gameFrame:(CGRect)gameFrame
           controlFrame:(CGRect)controlFrame style:(DmReflectionStyle)style;
- (void)disable;
- (NSDictionary<NSString *, id> *)debugSnapshot;
@end

NS_ASSUME_NONNULL_END
