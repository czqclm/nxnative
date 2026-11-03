// Structural and pause regressions against the production front end. These
// tests do not establish pixel-level reflection quality or game performance.
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CAReplicatorLayer.h>
#include <math.h>
#import "DmDuoDisplay.h"
#import "DmGamepad.h"
#import "DmTouchConfig.h"
#import "DmControlReflection.h"

UIViewController *front_ios_root(void);
void front_ios_focus_event(int event);
NSDictionary *dm_preview_pause_snapshot(void);
NSDictionary *dm_preview_input_snapshot(void);
void dm_preview_reset_pause_history(void);
void dm_preview_save_test_preferences(void);
void dm_preview_restore_test_preferences(void);
void dm_preview_set_test_controllers(NSArray<GCController *> *controllers);

@interface UIViewController (ReflectionFrontFixture)
- (void)startGame;
- (void)updateHingeStatus:(NSInteger)status angle:(CGFloat)angleRadians;
@end

// This lifecycle test intentionally has no root-controller or preference fixture.
@interface ReflectionLifecycleTests : XCTestCase
@end
@implementation ReflectionLifecycleTests
- (void)testDroppingAnActiveOwnerRestoresTheSurvivingGameAndRemovesDecorations {
    XCTAssertTrue(NSThread.isMainThread);
    UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 669, 951)];
    DmDuoGeometry geometry = dm_duo_geometry(root.bounds, UIEdgeInsetsZero, CGRectNull);
    Class gameClass = NSClassFromString(@"DmGameView"); XCTAssertNotNil(gameClass);
    UIView *game = [[gameClass alloc] initWithFrame:geometry.gameFrame];
    [root addSubview:game];
    CALayer *originalLayer = game.layer;
    XCTAssertTrue([originalLayer isKindOfClass:CAMetalLayer.class]);
    __weak DmControlReflection *weakOwner = nil;
    NSArray<UIView *> *decorations = nil;
    @autoreleasepool {
        DmControlReflection *owner = [[DmControlReflection alloc] initWithRootView:root gameView:game];
        weakOwner = owner;
        [owner updateWithBounds:root.bounds gameFrame:geometry.gameFrame controlFrame:geometry.padFrame
                          style:dm_reflection_style(YES, YES, YES, M_PI_2)];
        XCTAssertTrue(owner.isActive);
        NSMutableArray<UIView *> *views = [NSMutableArray array];
        for (NSString *identifier in @[@"control.reflection.mirror", @"control.reflection.blur", @"control.reflection.fade"]) {
            UIView *view = nil;
            for (UIView *child in root.subviews)
                if ([child.accessibilityIdentifier isEqualToString:identifier]) { view = child; break; }
            XCTAssertNotNil(view, @"Missing active decoration %@", identifier);
            if (view) [views addObject:view];
        }
        decorations = [views copy];
        XCTAssertEqual(decorations.count, 3u);
        XCTAssertNotEqual(game.superview, root);
        owner = nil;
    }
    XCTAssertNil(weakOwner);
    for (UIView *view in decorations) {
        XCTAssertNil(view.superview);
        XCTAssertFalse([view isDescendantOfView:root]);
    }
    XCTAssertEqual(game.superview, root);
    XCTAssertEqualObjects(root.subviews, (@[game]));
    XCTAssertTrue(CGRectEqualToRect(game.frame, geometry.gameFrame));
    XCTAssertEqual(game.layer, originalLayer);
}
@end

@interface UIView (ReflectionControlGeometry)
- (CGRect)controlRect:(NSString *)identifier;
@end

@interface ReflectionFixtureTouch : UITouch
@property(nonatomic, strong) UIView *coordinateView;
@property(nonatomic) CGPoint point;
@property(nonatomic) UITouchPhase testPhase;
@end
@implementation ReflectionFixtureTouch
- (CGPoint)locationInView:(UIView *)view { return view == self.coordinateView ? self.point : [self.coordinateView convertPoint:self.point toView:view]; }
- (CGPoint)previousLocationInView:(UIView *)view { return [self locationInView:view]; }
- (UITouchPhase)phase { return self.testPhase; }
@end

static NSString *const reflectionPreference = @"DmControlReflectionEnabled";
static NSString *const reflectionNotification = @"DmControlReflectionDidChange";

static UIView *reflectionFindClass(UIView *view, NSString *className) {
    if ([NSStringFromClass(view.class) isEqualToString:className]) return view;
    for (UIView *child in view.subviews) {
        UIView *found = reflectionFindClass(child, className); if (found) return found;
    }
    return nil;
}

static UIView *reflectionFindIdentifier(UIView *view, NSString *identifier) {
    if ([view.accessibilityIdentifier isEqualToString:identifier]) return view;
    for (UIView *child in view.subviews) {
        UIView *found = reflectionFindIdentifier(child, identifier); if (found) return found;
    }
    return nil;
}

@interface ReflectionTests : XCTestCase
@property(nonatomic, strong) UIViewController *root;
@property(nonatomic, strong) UIView *game;
@property(nonatomic, strong) UIView *pad;
@property(nonatomic, copy) NSDictionary *savedDefaults;
@property(nonatomic, copy) NSString *savedActive;
@property(nonatomic, copy) NSString *defaultsDomain;
@end

@implementation ReflectionTests
- (void)recordIssue:(XCTIssue *)issue {
    // Preserve failures while avoiding this simulator's unrelated symbolication hang.
    fprintf(stderr, "REFLECTION_TEST_ISSUE: %s\n", issue.compactDescription.UTF8String);
    XCTMutableIssue *recorded = [issue mutableCopy];
    recorded.sourceCodeContext = [[XCTSourceCodeContext alloc] initWithCallStack:@[] location:issue.sourceCodeContext.location];
    [super recordIssue:recorded];
}
- (void)setUp {
    [super setUp]; XCTAssertTrue(NSThread.isMainThread);
    self.defaultsDomain = NSBundle.mainBundle.bundleIdentifier;
    XCTAssertEqualObjects(self.defaultsDomain, @"org.nxnative.duo-ui-preview");
    self.savedDefaults = [NSUserDefaults.standardUserDefaults persistentDomainForName:self.defaultsDomain];
    self.savedActive = dm_touch_active_profile(); dm_preview_save_test_preferences();
    [NSUserDefaults.standardUserDefaults setObject:@"inner" forKey:@"DmTouchDisplayMode"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:reflectionPreference];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"DmControlReflectionSettingsV1"];
    dm_preview_set_test_controllers(@[]); dm_touch_set_active_profile(@"folded");
    for (NSString *profile in @[@"outer", @"inner", @"folded"]) {
        dm_touch_save_profile(profile, dm_touch_default_profile_settings());
        dm_touch_save_layout_style(profile, 1);
    }
    self.root = front_ios_root(); [self.root loadViewIfNeeded];
    self.root.view.frame = CGRectMake(0, 0, 466, 678);
    [self.root startGame];
    self.game = reflectionFindClass(self.root.view, @"DmGameView");
    self.pad = reflectionFindClass(self.root.view, @"DmGamepad");
    XCTAssertNotNil(self.game); XCTAssertNotNil(self.pad);
    [self settleLayout];
    // Drain real hierarchy/controller callbacks before injecting the detached
    // fixture's angle and profile. Later layout flushes deliberately do not pump
    // the parent window, whose physical orientation may differ from this fixture.
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    dm_touch_set_active_profile(@"folded");
    [self.root updateHingeStatus:UIHingeStatusPartiallyOpen angle:M_PI_2];
    [self settleLayout];
    front_ios_focus_event(2); front_ios_focus_event(3); dm_preview_reset_pause_history();
}
- (void)tearDown {
    if (self.pad) { dm_gamepad_end_layout_edit(self.pad, NO); dm_gamepad_release_touches(self.pad); }
    front_ios_focus_event(2); front_ios_focus_event(3);
    dm_preview_set_test_controllers(@[]);
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidDisconnectNotification object:nil];
    [self.root updateHingeStatus:-1 angle:NAN]; [self settleLayout];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    if (self.savedDefaults) [NSUserDefaults.standardUserDefaults setPersistentDomain:self.savedDefaults forName:self.defaultsDomain];
    else [NSUserDefaults.standardUserDefaults removePersistentDomainForName:self.defaultsDomain];
    dm_touch_set_active_profile(self.savedActive); dm_preview_restore_test_preferences();
    [self.root.view removeFromSuperview]; self.pad = nil; self.game = nil; self.root = nil;
    [super tearDown];
}
- (void)settleLayout {
    [self.root.view setNeedsLayout]; [self.root.view layoutIfNeeded];
    UIView *mirror = reflectionFindIdentifier(self.root.view, @"control.reflection.mirror");
    [mirror layoutIfNeeded]; [self.game setNeedsLayout]; [self.game layoutIfNeeded]; [self.pad layoutIfNeeded];
}
- (UIView *)mirror {
    UIView *view = reflectionFindIdentifier(self.root.view, @"control.reflection.mirror");
    if (view) XCTAssertEqualObjects(NSStringFromClass(view.class), @"DmReflectionMirrorView");
    return view;
}
- (void)assertReflectionAbsent {
    for (NSString *identifier in @[@"control.reflection.mirror", @"control.reflection.blur", @"control.reflection.fade"])
        XCTAssertNil(reflectionFindIdentifier(self.root.view, identifier), @"Stale reflection view %@", identifier);
}
- (NSDictionary *)profileSnapshot {
    return @{@"outer": dm_touch_profile_settings(@"outer"), @"inner": dm_touch_profile_settings(@"inner"),
             @"folded": dm_touch_profile_settings(@"folded")};
}
- (void)injectStatus:(NSInteger)status angle:(CGFloat)angleRadians {
    [self.root updateHingeStatus:status angle:angleRadians]; [self settleLayout];
}
- (void)setReflectionEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:reflectionPreference];
    [NSNotificationCenter.defaultCenter postNotificationName:reflectionNotification object:nil];
    [self settleLayout];
}
- (void)sendButton:(NSString *)identifier {
    UIButton *button = (UIButton *)reflectionFindIdentifier(self.root.view, identifier);
    XCTAssertTrue([button isKindOfClass:UIButton.class], @"Missing button %@", identifier);
    [button sendActionsForControlEvents:UIControlEventTouchUpInside]; [self settleLayout];
}
- (CGRect)gameFrameInRoot { return [self.game convertRect:self.game.bounds toView:self.root.view]; }
- (NSDictionary *)geometrySnapshot {
    NSMutableDictionary *controls = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"A", @"B", @"X", @"Y", @"L", @"R", @"ZL", @"ZR", @"PLUS", @"MINUS", @"L3", @"R3", @"DPAD", @"LEFT_STICK", @"RIGHT_STICK"])
        controls[key] = [NSValue valueWithCGRect:[self.pad controlRect:key]];
    return @{@"gameRootFrame": [NSValue valueWithCGRect:self.gameFrameInRoot],
        @"gameBounds": [NSValue valueWithCGRect:self.game.bounds],
        @"gameTransform": [NSValue valueWithCGAffineTransform:self.game.transform],
        @"drawableSize": [NSValue valueWithCGSize:((CAMetalLayer *)self.game.layer).drawableSize],
        @"padFrame": [NSValue valueWithCGRect:self.pad.frame], @"padBounds": [NSValue valueWithCGRect:self.pad.bounds],
        @"padTransform": [NSValue valueWithCGAffineTransform:self.pad.transform],
        @"padInsets": [NSValue valueWithUIEdgeInsets:self.pad.safeAreaInsets], @"controls": controls};
}
- (void)assertRect:(CGRect)actual near:(CGRect)expected {
    XCTAssertEqualWithAccuracy(actual.origin.x, expected.origin.x, .001);
    XCTAssertEqualWithAccuracy(actual.origin.y, expected.origin.y, .001);
    XCTAssertEqualWithAccuracy(actual.size.width, expected.size.width, .001);
    XCTAssertEqualWithAccuracy(actual.size.height, expected.size.height, .001);
}
- (void)assertExpectedRootGeometry {
    DmDuoGeometry expected = dm_duo_layout_for_view(self.root.view, [NSUserDefaults.standardUserDefaults stringForKey:@"DmTouchDisplayMode"], NULL);
    [self assertRect:self.gameFrameInRoot near:expected.gameFrame];
    [self assertRect:self.pad.frame near:expected.padFrame];
    XCTAssertEqual(self.pad.superview, self.root.view);
    XCTAssertTrue([self.game.layer isKindOfClass:CAMetalLayer.class]);
    CAMetalLayer *layer = (CAMetalLayer *)self.game.layer;
    XCTAssertGreaterThan(layer.drawableSize.width, 0); XCTAssertGreaterThan(layer.drawableSize.height, 0);
    // Metal textures use whole pixels even when UIKit uses fractional points.
    // Toggle tests separately require the before/after drawable sizes to match exactly.
    XCTAssertLessThan(fabs(layer.drawableSize.width - self.game.bounds.size.width * layer.contentsScale), 1.0);
    XCTAssertLessThan(fabs(layer.drawableSize.height - self.game.bounds.size.height * layer.contentsScale), 1.0);
}
- (void)assertPausedWithFocus:(int)focus {
    NSDictionary *state = dm_preview_pause_snapshot();
    XCTAssertEqualObjects(state[@"gfxSuspended"], @YES); XCTAssertEqualObjects(state[@"audioSuspended"], @YES);
    XCTAssertEqualObjects(state[@"clockReason1Frozen"], @YES); XCTAssertEqualObjects(state[@"focusState"], @(focus));
}
- (void)assertResumed {
    NSDictionary *state = dm_preview_pause_snapshot();
    XCTAssertEqualObjects(state[@"gfxSuspended"], @NO); XCTAssertEqualObjects(state[@"audioSuspended"], @NO);
    XCTAssertEqualObjects(state[@"clockReason1Frozen"], @NO); XCTAssertEqualObjects(state[@"focusState"], @1);
}
- (void)assertNoTransientResume {
    for (NSDictionary *event in dm_preview_pause_snapshot()[@"events"]) {
        NSString *component = event[@"component"];
        if ([component isEqualToString:@"gfx"] || [component isEqualToString:@"audio"] ||
            ([component isEqualToString:@"clock"] && [event[@"reason"] intValue] == 1))
            XCTAssertNotEqual([event[@"value"] intValue], 0, @"Unexpected resume: %@", event);
        if ([component isEqualToString:@"focus"]) XCTAssertNotEqual([event[@"value"] intValue], 1);
    }
}
- (void)testBentInnerPortraitDefaultsToEnabledWithoutPersistingAChoice {
    UIView *mirror = self.mirror; XCTAssertNotNil(mirror);
    XCTAssertTrue([mirror.layer isKindOfClass:CAReplicatorLayer.class]);
    // Only the original game is composed here; the reflected image comes from
    // the separate GPU surface, without a sharp duplicate underneath it.
    XCTAssertEqual(((CAReplicatorLayer *)mirror.layer).instanceCount, 1);
    XCTAssertEqual(mirror.superview, self.root.view); XCTAssertTrue([self.game isDescendantOfView:mirror]);
    NSUInteger mirrorIndex = [self.root.view.subviews indexOfObject:mirror];
    NSUInteger padIndex = [self.root.view.subviews indexOfObject:self.pad];
    XCTAssertNotEqual(mirrorIndex, NSNotFound); XCTAssertNotEqual(padIndex, NSNotFound); XCTAssertLessThan(mirrorIndex, padIndex);
    for (NSString *identifier in @[@"control.reflection.blur", @"control.reflection.fade"]) {
        UIView *effect = reflectionFindIdentifier(self.root.view, identifier); XCTAssertNotNil(effect);
        XCTAssertEqual(effect.superview, self.root.view); XCTAssertFalse(effect.userInteractionEnabled);
        if ([identifier containsString:@"blur"]) {
            XCTAssertTrue([effect.layer isKindOfClass:CAMetalLayer.class]);
            XCTAssertFalse([effect isKindOfClass:UIVisualEffectView.class]);
        }
        NSUInteger index = [self.root.view.subviews indexOfObject:effect];
        XCTAssertGreaterThan(index, mirrorIndex); XCTAssertLessThan(index, padIndex);
    }
    XCTAssertNil([[NSUserDefaults.standardUserDefaults persistentDomainForName:self.defaultsDomain] objectForKey:reflectionPreference]);
    [self assertExpectedRootGeometry];
}
- (void)testUniformGPUBlurSurfaceCoversTheReflectionWithoutMaterialTintOrAlphaRamp {
    [self injectStatus:UIHingeStatusPartiallyOpen angle:M_PI_2];
    UIView *blur = reflectionFindIdentifier(self.root.view, @"control.reflection.blur");
    XCTAssertNotNil(blur); XCTAssertFalse([blur isKindOfClass:UIVisualEffectView.class]);
    XCTAssertTrue([blur.layer isKindOfClass:CAMetalLayer.class]);
    if (![blur.layer isKindOfClass:CAMetalLayer.class]) return;
    XCTAssertNil(reflectionFindClass(blur, @"UIVisualEffectView"));
    XCTAssertNil(blur.maskView); XCTAssertNil(blur.layer.mask);
    XCTAssertEqual(blur.alpha, 1); XCTAssertEqual(blur.layer.opacity, 1);
    XCTAssertTrue(blur.opaque); XCTAssertTrue(blur.layer.opaque);
    CGFloat red = -1, green = -1, blue = -1, alpha = -1;
    XCTAssertTrue([blur.backgroundColor getRed:&red green:&green blue:&blue alpha:&alpha]);
    XCTAssertEqual(red, 0); XCTAssertEqual(green, 0); XCTAssertEqual(blue, 0); XCTAssertEqual(alpha, 1);
    XCTAssertEqual(((CAMetalLayer *)blur.layer).device, ((CAMetalLayer *)self.game.layer).device);
    XCTAssertEqual(blur.superview, self.root.view);
    CGRect controls = CGRectIntersection(self.root.view.bounds, self.pad.frame);
    CGRect reflectedPicture = CGRectMake(self.gameFrameInRoot.origin.x, controls.origin.y,
        self.gameFrameInRoot.size.width, controls.size.height);
    [self assertRect:blur.frame near:reflectedPicture];
    for (NSNumber *fraction in @[@.1, @.5, @.9]) {
        CGPoint point = CGPointMake(CGRectGetMidX(self.gameFrameInRoot),
                                    CGRectGetMinY(controls) + controls.size.height * fraction.doubleValue);
        XCTAssertTrue(CGRectContainsPoint(blur.frame, point));
    }
    // The long nonlinear fade must remain bright where the uniform blur is
    // actually visible, rather than reserving its intensity for an offscreen tail.
    DmReflectionStyle style = dm_reflection_style(YES, YES, YES, M_PI_2);
    CGFloat middleOpacity = dm_control_reflection_opacity(style, controls.size.height * .5, controls.size.height);
    CGFloat bottomOpacity = dm_control_reflection_opacity(style, controls.size.height, controls.size.height);
    XCTAssertGreaterThan(middleOpacity, .95); XCTAssertGreaterThan(bottomOpacity, .75);
    XCTAssertLessThan(bottomOpacity, middleOpacity);
}
- (void)testTogglesPreserveTheSameMetalViewLayerDrawableAndRootCoordinates {
    UIView *originalGame = self.game, *originalPad = self.pad;
    CALayer *originalLayer = self.game.layer;
    for (NSValue *value in @[[NSValue valueWithCGRect:CGRectMake(0, 0, 466, 678)],
                             [NSValue valueWithCGRect:CGRectMake(0, 0, 669, 951)],
                             [NSValue valueWithCGRect:CGRectMake(17, 23, 466, 678)]]) {
        CGRect bounds = value.CGRectValue;
        self.root.view.frame = (CGRect){CGPointZero, bounds.size}; self.root.view.bounds = bounds;
        [self settleLayout];
        NSDictionary *before = self.geometrySnapshot;
        NSDictionary *savedProfile = self.profileSnapshot;
        UIView *oldMirror = self.mirror; XCTAssertNotNil(oldMirror);
        [self setReflectionEnabled:NO];
        [self assertReflectionAbsent]; XCTAssertNil(oldMirror.superview); XCTAssertFalse([self.game isDescendantOfView:oldMirror]);
        XCTAssertEqual(self.game.superview, self.root.view);
        XCTAssertEqual(reflectionFindClass(self.root.view, @"DmGameView"), originalGame);
        XCTAssertEqual(self.game.layer, originalLayer); XCTAssertEqual(self.pad, originalPad);
        XCTAssertEqualObjects(self.geometrySnapshot, before); [self assertExpectedRootGeometry];
        [self setReflectionEnabled:YES];
        XCTAssertNotNil(self.mirror); XCTAssertTrue([originalGame isDescendantOfView:self.mirror]);
        XCTAssertEqual(self.game.layer, originalLayer); XCTAssertEqual(self.pad.superview, self.root.view);
        XCTAssertEqualObjects(self.geometrySnapshot, before); [self assertExpectedRootGeometry];
        XCTAssertEqualObjects(self.profileSnapshot, savedProfile);
    }
}
- (void)testLandscapeAndSquareTearDownReflectionAndPortraitRestoresIt {
    UIView *originalGame = self.game; CALayer *originalLayer = self.game.layer;
    for (NSValue *size in @[[NSValue valueWithCGSize:CGSizeMake(951, 669)], [NSValue valueWithCGSize:CGSizeMake(800, 800)]]) {
        UIView *oldMirror = self.mirror; XCTAssertNotNil(oldMirror);
        self.root.view.frame = (CGRect){CGPointZero, size.CGSizeValue}; [self settleLayout];
        [self assertReflectionAbsent]; XCTAssertNil(oldMirror.superview); XCTAssertFalse([self.game isDescendantOfView:oldMirror]);
        XCTAssertEqual(self.game.superview, self.root.view); XCTAssertEqual(self.game, originalGame);
        XCTAssertEqual(self.game.layer, originalLayer); [self assertExpectedRootGeometry];
        self.root.view.frame = CGRectMake(0, 0, 466, 678); [self settleLayout];
        XCTAssertNotNil(self.mirror); XCTAssertTrue([originalGame isDescendantOfView:self.mirror]);
        XCTAssertEqual(self.game.layer, originalLayer); [self assertExpectedRootGeometry];
    }
}
- (void)testReflectionTogglesKeepLiveDraftAndPauseUntilCancel {
    [self sendButton:@"live.layout.open"];
    XCTAssertTrue(dm_gamepad_is_layout_editing(self.pad)); [self assertPausedWithFocus:2];
    dm_gamepad_update_layout_draft(self.pad, @{@"opacity": @.4});
    NSDictionary *draft = dm_gamepad_editor_settings(self.pad), *before = self.geometrySnapshot;
    NSDictionary *stored = self.profileSnapshot;
    dm_preview_reset_pause_history();
    for (NSNumber *enabled in @[@NO, @YES]) {
        [self setReflectionEnabled:enabled.boolValue];
        XCTAssertTrue(dm_gamepad_is_layout_editing(self.pad)); [self assertPausedWithFocus:2];
        XCTAssertEqualObjects(dm_gamepad_editor_settings(self.pad), draft);
        XCTAssertEqualObjects(self.profileSnapshot, stored);
        XCTAssertEqualObjects(self.geometrySnapshot, before);
        XCTAssertNotNil(reflectionFindIdentifier(self.root.view, @"live.layout.save"));
        [self assertNoTransientResume];
    }
    [self sendButton:@"live.layout.cancel"]; XCTAssertFalse(dm_gamepad_is_layout_editing(self.pad)); [self assertResumed];
}
- (void)testBackgroundReflectionTogglesKeepDraftAndRemainPausedOnForeground {
    [self sendButton:@"live.layout.open"]; dm_gamepad_update_layout_draft(self.pad, @{@"opacity": @.4});
    NSDictionary *draft = dm_gamepad_editor_settings(self.pad);
    front_ios_focus_event(0); front_ios_focus_event(1); dm_preview_reset_pause_history();
    [self setReflectionEnabled:NO]; [self assertPausedWithFocus:3];
    [self setReflectionEnabled:YES]; [self assertPausedWithFocus:3];
    front_ios_focus_event(2); front_ios_focus_event(3); [self settleLayout];
    XCTAssertTrue(dm_gamepad_is_layout_editing(self.pad)); XCTAssertEqualObjects(dm_gamepad_editor_settings(self.pad), draft);
    [self assertPausedWithFocus:2]; [self assertNoTransientResume];
    [self sendButton:@"live.layout.cancel"]; [self assertResumed];
}
- (void)testSavingAfterReflectionToggleInBackgroundDoesNotReleaseBackgroundPause {
    [self sendButton:@"live.layout.open"];
    front_ios_focus_event(0); front_ios_focus_event(1); dm_preview_reset_pause_history();
    [self setReflectionEnabled:NO]; [self sendButton:@"live.layout.save"];
    XCTAssertFalse(dm_gamepad_is_layout_editing(self.pad)); [self assertPausedWithFocus:3]; [self assertNoTransientResume];
    [self assertReflectionAbsent];
    front_ios_focus_event(2); front_ios_focus_event(3); [self assertResumed];
}
- (void)testUnavailableUnknownClosedAndFlatStatesRemoveReflection {
    struct { NSInteger status; CGFloat angle; } cases[] = {
        {-1, NAN}, {UIHingeStatusUnknown, M_PI_2}, {UIHingeStatusClosed, 0},
        {UIHingeStatusFullyOpen, M_PI}, {UIHingeStatusFullyOpen, M_PI_2},
        {UIHingeStatusPartiallyOpen, 0}, {UIHingeStatusPartiallyOpen, M_PI},
        {UIHingeStatusPartiallyOpen, -1}, {UIHingeStatusPartiallyOpen, M_PI + .01},
        {UIHingeStatusPartiallyOpen, NAN}, {UIHingeStatusPartiallyOpen, INFINITY},
        {UIHingeStatusPartiallyOpen, -INFINITY}
    };
    UIView *game = self.game; CALayer *layer = self.game.layer;
    NSDictionary *before = self.geometrySnapshot;
    for (NSUInteger i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        [self injectStatus:UIHingeStatusPartiallyOpen angle:M_PI_2]; XCTAssertNotNil(self.mirror);
        [self injectStatus:cases[i].status angle:cases[i].angle]; [self assertReflectionAbsent];
        XCTAssertEqual(self.game, game); XCTAssertEqual(self.game.layer, layer);
        XCTAssertEqual(self.game.superview, self.root.view); XCTAssertEqualObjects(self.geometrySnapshot, before);
    }
    [self injectStatus:UIHingeStatusPartiallyOpen angle:M_PI_2]; XCTAssertNotNil(self.mirror);
}
- (void)testOuterPortraitRemainsOffWithAValidBentAngle {
    NSDictionary *before = self.geometrySnapshot;
    [NSUserDefaults.standardUserDefaults setObject:@"outer" forKey:@"DmTouchDisplayMode"];
    dm_touch_set_active_profile(@"outer"); [self injectStatus:UIHingeStatusPartiallyOpen angle:M_PI_2];
    [self assertReflectionAbsent]; XCTAssertEqual(self.game.superview, self.root.view);
    XCTAssertEqualObjects(self.geometrySnapshot, before);
    [NSUserDefaults.standardUserDefaults setObject:@"inner" forKey:@"DmTouchDisplayMode"];
    dm_touch_set_active_profile(@"folded"); [self injectStatus:UIHingeStatusPartiallyOpen angle:M_PI_2];
    XCTAssertNotNil(self.mirror);
}
- (void)testSameStatusAngleChangesKeepLiveDraftGeometryProfilesAndPause {
    [self sendButton:@"live.layout.open"]; XCTAssertTrue(dm_gamepad_is_layout_editing(self.pad));
    dm_gamepad_update_layout_draft(self.pad, @{@"opacity": @.4});
    dm_gamepad_editor_select(self.pad, @"A"); dm_gamepad_editor_set_scale(self.pad, 1.2); [self settleLayout];
    UIView *game = self.game; CALayer *layer = self.game.layer;
    NSDictionary *before = self.geometrySnapshot, *draft = dm_gamepad_editor_settings(self.pad), *stored = self.profileSnapshot;
    NSString *profile = dm_touch_active_profile();
    NSNumber *published = dm_preview_input_snapshot()[@"publishCount"];
    dm_preview_reset_pause_history();
    for (NSNumber *angle in @[@(M_PI_4), @(M_PI), @(M_PI_2)]) {
        // A status-only implementation misses both 90 -> 45 and 90 -> flat.
        [self injectStatus:UIHingeStatusPartiallyOpen angle:angle.doubleValue];
        if (angle.doubleValue == M_PI) [self assertReflectionAbsent]; else XCTAssertNotNil(self.mirror);
        XCTAssertEqual(self.game, game); XCTAssertEqual(self.game.layer, layer);
        XCTAssertEqualObjects(self.geometrySnapshot, before); XCTAssertTrue(dm_gamepad_is_layout_editing(self.pad));
        XCTAssertEqualObjects(dm_gamepad_editor_settings(self.pad), draft); XCTAssertEqualObjects(self.profileSnapshot, stored);
        XCTAssertEqualObjects(dm_touch_active_profile(), profile); XCTAssertEqualObjects(dm_gamepad_layout_edit_profile(self.pad), profile);
        XCTAssertEqualObjects(dm_preview_input_snapshot()[@"publishCount"], published);
        [self assertPausedWithFocus:2]; [self assertNoTransientResume];
    }
    [self sendButton:@"live.layout.cancel"]; [self assertResumed];
}
- (void)testAngleChangeDoesNotReleaseAHeldGamepadButton {
    CGRect button = [self.pad controlRect:@"A"];
    ReflectionFixtureTouch *touch = [ReflectionFixtureTouch new]; touch.coordinateView = self.pad;
    touch.point = CGPointMake(CGRectGetMidX(button), CGRectGetMidY(button)); touch.testPhase = UITouchPhaseBegan;
    [self.pad touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
    XCTAssertEqual([dm_preview_input_snapshot()[@"buttons"] unsignedLongLongValue] & 1ull, 1ull);
    NSNumber *published = dm_preview_input_snapshot()[@"publishCount"];
    NSDictionary *before = self.geometrySnapshot;
    [self injectStatus:UIHingeStatusPartiallyOpen angle:M_PI_4];
    XCTAssertEqual([dm_preview_input_snapshot()[@"buttons"] unsignedLongLongValue] & 1ull, 1ull);
    XCTAssertEqualObjects(dm_preview_input_snapshot()[@"publishCount"], published);
    XCTAssertEqualObjects(self.geometrySnapshot, before);
    touch.testPhase = UITouchPhaseEnded; [self.pad touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
    XCTAssertEqual([dm_preview_input_snapshot()[@"buttons"] unsignedLongLongValue], 0ull);
}
@end
