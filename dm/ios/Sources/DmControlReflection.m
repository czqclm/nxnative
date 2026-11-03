#import "DmControlReflection.h"
#import "DmReflectionGPU.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

NSNotificationName const DmControlReflectionDidChangeNotification = @"DmControlReflectionDidChange";
BOOL dm_control_reflection_enabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:@"DmControlReflectionEnabled"] == nil
        ? YES : [defaults boolForKey:@"DmControlReflectionEnabled"];
}
static CGFloat smooth_unit(CGFloat value) {
    CGFloat t = fmin(1, fmax(0, value)); return t * t * (3 - 2 * t);
}
CGFloat dm_control_reflection_opacity(DmReflectionStyle style, CGFloat distance, CGFloat regionHeight) {
    if (!style.visible || !isfinite(distance) || !isfinite(regionHeight) || regionHeight <= 0
        || !isfinite(style.peakOpacity) || !isfinite(style.reachFraction)
        || distance <= 0 || style.reachFraction <= 0) return 0;
    CGFloat reach = regionHeight * style.reachFraction;
    if (!isfinite(reach) || reach <= 0) return 0;
    if (distance >= reach) return 0;
    // Keep a soft seam, then retain a broad bright region before the tail.
    // This quintic Bezier has control values [1, 1, 1, 1, 0, 0]. Its slope is
    // zero at both ends; the factored form avoids cancellation near t == 1.
    CGFloat feather = fmin(isfinite(style.featherPoints) ? fmax(0, style.featherPoints) : 12, reach * .06);
    CGFloat t = distance / reach, u = 1 - t;
    CGFloat fade = style.curve == DmReflectionCurveLinear ? u
        : style.curve == DmReflectionCurveSmooth ? 1 - smooth_unit(t)
        : u * u * (1 + 2 * t + 3 * t * t + 4 * t * t * t);
    return fmin(1, fmax(0, style.peakOpacity)) * (feather > 0 ? smooth_unit(distance / feather) : 1)
        * fade;
}
static BOOL reflection_rect_valid(CGRect r) {
    return !CGRectIsNull(r) && !CGRectIsInfinite(r) && !CGRectIsEmpty(r)
        && isfinite(r.origin.x) && isfinite(r.origin.y)
        && isfinite(r.size.width) && isfinite(r.size.height);
}
@interface DmReflectionMirrorView : UIView
@end
@implementation DmReflectionMirrorView
+ (Class)layerClass { return CAReplicatorLayer.class; }
@end
@interface DmReflectionGradientView : UIView
@end
@implementation DmReflectionGradientView
+ (Class)layerClass { return CAGradientLayer.class; }
@end
@interface DmReflectionSurfaceView : UIView
@end
@implementation DmReflectionSurfaceView
+ (Class)layerClass { return CAMetalLayer.class; }
@end
static void decoration(UIView *view, NSString *identifier) {
    view.userInteractionEnabled = NO; view.accessibilityElementsHidden = YES;
    view.accessibilityIdentifier = identifier; view.opaque = NO;
    view.backgroundColor = UIColor.clearColor; view.autoresizingMask = UIViewAutoresizingNone;
}
@implementation DmControlReflection {
    __weak UIView *_root, *_game;
    DmReflectionMirrorView *_mirror;
    DmReflectionSurfaceView *_blur;
    DmReflectionGPU *_gpu;
    DmReflectionGradientView *_fade;
    CALayer *_mask, *_pictureMask, *_reflectionMask;
    DmReflectionStyle _style;
    CGRect _bounds, _gameFrame, _controls;
    BOOL _suspended;
}
- (instancetype)initWithRootView:(UIView *)root gameView:(UIView *)game {
    NSParameterAssert(root && game && root != game);
    if ((self = [super init])) {
        _root = root; _game = game;
        _suspended = UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[UIApplicationWillResignActiveNotification,
                UIApplicationDidEnterBackgroundNotification, UISceneWillDeactivateNotification,
                UISceneDidEnterBackgroundNotification])
            [center addObserver:self selector:@selector(sceneSuspended:) name:name object:nil];
        for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UISceneDidActivateNotification])
            [center addObserver:self selector:@selector(sceneResumed:) name:name object:nil];
    }
    return self;
}
- (BOOL)isActive { return _mirror != nil; }
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self disable]; [_gpu invalidate];
}
- (BOOL)notificationMatchesScene:(NSNotification *)notification {
    if (![notification.object isKindOfClass:UIScene.class]) return YES;
    UIWindowScene *scene = _root.window.windowScene;
    return scene == nil || notification.object == scene;
}
- (void)sceneSuspended:(NSNotification *)notification {
    if (![self notificationMatchesScene:notification]) return;
    _suspended = YES; [_gpu setSuspended:YES];
}
- (void)sceneResumed:(NSNotification *)notification {
    if (![self notificationMatchesScene:notification]) return;
    _suspended = NO; [_gpu setSuspended:NO];
}
- (void)attach {
    UIView *root = _root, *game = _game;
    _mirror = [DmReflectionMirrorView new]; decoration(_mirror, @"control.reflection.mirror");
    _mirror.clipsToBounds = YES;
    CAReplicatorLayer *replicator = (CAReplicatorLayer *)_mirror.layer;
    // Keep the original hierarchy and coordinates, but never create a second
    // compositor copy. The independent Metal surface draws the reflection.
    replicator.instanceCount = 1; replicator.instanceDelay = 0;
    NSUInteger index = [root.subviews indexOfObjectIdenticalTo:game];
    [root insertSubview:_mirror atIndex:index == NSNotFound ? 0 : index];
    [_mirror addSubview:game];
    _mask = [CALayer layer]; _pictureMask = [CALayer layer]; _reflectionMask = [CALayer layer];
    _pictureMask.backgroundColor = UIColor.whiteColor.CGColor;
    _reflectionMask.backgroundColor = UIColor.whiteColor.CGColor;
    [_mask addSublayer:_pictureMask]; [_mask addSublayer:_reflectionMask]; _mirror.layer.mask = _mask;
    _blur = [DmReflectionSurfaceView new];
    decoration(_blur, @"control.reflection.blur");
    _blur.opaque = YES; _blur.backgroundColor = UIColor.blackColor; _blur.contentScaleFactor = 1;
    _blur.clipsToBounds = YES;
    CAMetalLayer *surface = (CAMetalLayer *)_blur.layer;
    surface.device = ((CAMetalLayer *)game.layer).device;
    surface.pixelFormat = MTLPixelFormatBGRA8Unorm; surface.framebufferOnly = YES;
    surface.opaque = YES; surface.contentsScale = 1;
    surface.maximumDrawableCount = 2; surface.allowsNextDrawableTimeout = YES;
    surface.presentsWithTransaction = NO;
    [root insertSubview:_blur aboveSubview:_mirror];
    // A pure GPU Gaussian adds no material tint: RGB zero remains zero.
    // The existing brightness envelope stays a sibling above the GPU surface.
    _fade = [DmReflectionGradientView new]; decoration(_fade, @"control.reflection.fade");
    [root insertSubview:_fade aboveSubview:_blur];
}
- (void)configureCaptureForStyle:(DmReflectionStyle)style layer:(CAMetalLayer *)layer {
    UIView *game = _game;
    id<MTLDevice> device = [game.layer isKindOfClass:CAMetalLayer.class] ? ((CAMetalLayer *)game.layer).device : nil;
    BOOL eligible = style.captureEligible && reflection_rect_valid(_gameFrame) && device != nil;
    if (!_gpu && eligible) {
        _gpu = [[DmReflectionGPU alloc] initWithDevice:device]; [_gpu setSuspended:_suspended];
    }
    CGFloat width = fmin(640, fmax(1, ceil(_gameFrame.size.width)));
    CGFloat height = ceil(width * _gameFrame.size.height / fmax(1, _gameFrame.size.width));
    CGFloat reach = _controls.size.height * fmin(1, fmax(0, style.reachFraction));
    CGFloat scale = fmax(1, reach / fmax(1, _gameFrame.size.height));
    CGFloat fraction = reach / (scale * fmax(1, _gameFrame.size.height));
    [_gpu updateLayer:layer captureEligible:eligible captureSize:CGSizeMake(width, height)
            gameSize:_gameFrame.size sampleFraction:fraction blurStrength:style.blurStrength];
}
- (void)updateWithBounds:(CGRect)bounds gameFrame:(CGRect)gameFrame
           controlFrame:(CGRect)controlFrame style:(DmReflectionStyle)style {
    NSAssert(NSThread.isMainThread, @"Reflection layout belongs to the main thread");
    UIView *root = _root, *game = _game;
    CGRect controls = CGRectIntersection(bounds, controlFrame);
    BOOL visible = root && game && style.visible && bounds.size.height > bounds.size.width
        && reflection_rect_valid(bounds) && reflection_rect_valid(gameFrame) && reflection_rect_valid(controls)
        && isfinite(style.peakOpacity) && style.peakOpacity > 0
        && isfinite(style.reachFraction) && style.reachFraction > 0;
    BOOL sameGeometry = CGRectEqualToRect(bounds, _bounds) && CGRectEqualToRect(gameFrame, _gameFrame)
        && CGRectEqualToRect(controls, _controls);
    BOOL sameStyle = style.visible == _style.visible && style.peakOpacity == _style.peakOpacity
        && style.reachFraction == _style.reachFraction && style.angleDegrees == _style.angleDegrees
        && style.blurStrength == _style.blurStrength && style.featherPoints == _style.featherPoints
        && style.curve == _style.curve && style.captureEligible == _style.captureEligible;
    _style = style;
    if (_mirror && visible && sameGeometry && sameStyle) return;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _bounds = bounds; _gameFrame = gameFrame; _controls = controls;
    if (!visible) {
        [self hideViews]; if (game) game.frame = gameFrame;
        [self configureCaptureForStyle:style layer:nil];
        [CATransaction commit]; return;
    }
    BOOL animate = _mirror && sameGeometry && root.window != nil;
    if (!_mirror) [self attach];
    _mirror.frame = bounds; _mirror.bounds = bounds; game.frame = gameFrame;
    // Keep the full virtual fade distance; only the rendered region is clipped
    // to the physical panel, without shortening the brightness curve.
    CGFloat reach = controls.size.height * fmin(1, style.reachFraction);
    CAReplicatorLayer *replicator = (CAReplicatorLayer *)_mirror.layer;
    replicator.instanceTransform = CATransform3DIdentity;
    _mask.frame = bounds; _mask.bounds = bounds; _pictureMask.frame = gameFrame;
    _reflectionMask.frame = CGRectMake(gameFrame.origin.x, controls.origin.y, gameFrame.size.width, reach);
    CGRect reflection = CGRectMake(gameFrame.origin.x, controls.origin.y, gameFrame.size.width, reach);
    _blur.frame = reflection;
    CGFloat drawableScale = fmin(1, 1024 / fmax(1, fmax(reflection.size.width, reflection.size.height)));
    CAMetalLayer *surface = (CAMetalLayer *)_blur.layer;
    surface.drawableSize = CGSizeMake(fmax(1, ceil(reflection.size.width * drawableScale)),
                                     fmax(1, ceil(reflection.size.height * drawableScale)));
    [self configureCaptureForStyle:style layer:surface];
    _fade.frame = controls;
    CAGradientLayer *fade = (CAGradientLayer *)_fade.layer;
    NSArray *previous = ((CAGradientLayer *)fade.presentationLayer).colors ?: fade.colors;
    NSMutableArray *colors = [NSMutableArray array], *locations = [NSMutableArray array];
    for (int i = 0; i <= 128; i++) {
        CGFloat t = i / 128.0;
        CGFloat opacity = dm_control_reflection_opacity(style, t * controls.size.height, controls.size.height);
        [colors addObject:(__bridge id)[UIColor colorWithWhite:0 alpha:1 - opacity].CGColor];
        [locations addObject:@(t)];
    }
    fade.startPoint = CGPointMake(.5, 0); fade.endPoint = CGPointMake(.5, 1);
    fade.colors = colors; fade.locations = locations;
    if (animate && previous.count == colors.count) {
        CABasicAnimation *transition = [CABasicAnimation animationWithKeyPath:@"colors"];
        transition.fromValue = previous; transition.toValue = colors; transition.duration = .12;
        [fade addAnimation:transition forKey:@"hingeBrightness"];
    }
    [CATransaction commit];
}
- (void)hideViews {
    NSAssert(NSThread.isMainThread, @"Reflection teardown belongs to the main thread");
    if (!_mirror) return;
    UIView *root = _root, *game = _game; CGRect frame = game ? game.frame : CGRectZero;
    NSUInteger index = root ? [root.subviews indexOfObjectIdenticalTo:_mirror] : NSNotFound;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    if (root && game) { [root insertSubview:game atIndex:index == NSNotFound ? 0 : index]; game.frame = frame; }
    [_blur removeFromSuperview]; [_fade removeFromSuperview];
    _mirror.layer.mask = nil; [_mirror removeFromSuperview];
    _mirror = nil; _blur = nil; _fade = nil;
    _mask = nil; _pictureMask = nil; _reflectionMask = nil;
    [CATransaction commit];
}
- (void)disable {
    [self hideViews];
    DmReflectionStyle disabled = _style; disabled.captureEligible = NO;
    [self configureCaptureForStyle:disabled layer:nil];
}
- (NSDictionary<NSString *, id> *)debugSnapshot {
    return @{@"active": @(self.isActive), @"blurMode": @"uniform", @"renderBackend": @"gpuGaussian",
        @"gpu": _gpu ? [_gpu debugSnapshot] : @{}, @"fadeCurve": _style.curve == DmReflectionCurveLinear ? @"linear"
            : _style.curve == DmReflectionCurveSmooth ? @"smooth" : @"quinticBezier",
        @"blurStrength": @(_style.blurStrength), @"featherPoints": @(_style.featherPoints),
        @"angleDegrees": @(_style.angleDegrees),
        @"peakOpacity": @(_style.peakOpacity), @"reachFraction": @(_style.reachFraction),
        @"reachPoints": @(self.isActive ? _controls.size.height * _style.reachFraction : 0),
        @"visibleReachPoints": @(self.isActive ? _controls.size.height * fmin(1, _style.reachFraction) : 0),
        @"reduceTransparency": @(UIAccessibilityIsReduceTransparencyEnabled())};
}
@end
