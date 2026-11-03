// Preference transactions and runtime regressions for the in-game reflection tools.
// Pixel-level blur and black preservation are verified separately with a Metal probe.
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#import "DmDuoDisplay.h"
#import "DmGamepad.h"
#import "DmTouchConfig.h"
#import "DmControlReflection.h"
#import "DmReflectionPreferences.h"
#include <math.h>

UIViewController *front_ios_root(void);
void front_ios_focus_event(int event);
NSDictionary *dm_preview_pause_snapshot(void);
NSDictionary *dm_preview_input_snapshot(void);
void dm_preview_reset_pause_history(void);
void dm_preview_save_test_preferences(void);
void dm_preview_restore_test_preferences(void);
void dm_preview_set_test_controllers(NSArray<GCController *> *controllers);

@interface UIViewController (TuningFrontFixture)
- (void)startGame;
- (void)updateHingeStatus:(NSInteger)status angle:(CGFloat)angleRadians;
- (void)selectReflectionParameter:(NSString *)key;
@end
@interface UIView (TuningControlGeometry)
- (CGRect)controlRect:(NSString *)identifier;
@end

static NSString *const tuningStoreKey = @"DmControlReflectionSettingsV1";
static NSString *const tuningEnabledKey = @"DmControlReflectionEnabled";

static UIView *tuningFindIdentifier(UIView *view, NSString *identifier) {
    if ([view.accessibilityIdentifier isEqualToString:identifier]) return view;
    for (UIView *child in view.subviews) {
        UIView *result = tuningFindIdentifier(child, identifier); if (result) return result;
    }
    return nil;
}
static UIView *tuningFindClass(UIView *view, NSString *name) {
    if ([NSStringFromClass(view.class) isEqualToString:name]) return view;
    for (UIView *child in view.subviews) {
        UIView *result = tuningFindClass(child, name); if (result) return result;
    }
    return nil;
}

@interface ReflectionTuningTests : XCTestCase
@property(nonatomic, strong) UIViewController *root;
@property(nonatomic, strong) UIView *game;
@property(nonatomic, strong) UIView *pad;
@property(nonatomic, copy) NSDictionary *savedDefaults;
@property(nonatomic, copy) NSString *savedActive;
@property(nonatomic, copy) NSString *domain;
@end

@implementation ReflectionTuningTests
- (void)recordIssue:(XCTIssue *)issue {
    fprintf(stderr, "REFLECTION_TUNING_ISSUE: %s\n", issue.compactDescription.UTF8String);
    XCTMutableIssue *recorded = [issue mutableCopy];
    recorded.sourceCodeContext = [[XCTSourceCodeContext alloc] initWithCallStack:@[] location:issue.sourceCodeContext.location];
    [super recordIssue:recorded];
}
- (void)setUp {
    [super setUp];
    XCTAssertTrue(NSThread.isMainThread);
    self.domain = NSBundle.mainBundle.bundleIdentifier;
    XCTAssertEqualObjects(self.domain, @"org.nxnative.duo-ui-preview");
    self.savedDefaults = [NSUserDefaults.standardUserDefaults persistentDomainForName:self.domain];
    self.savedActive = dm_touch_active_profile(); dm_preview_save_test_preferences();
    [NSUserDefaults.standardUserDefaults removeObjectForKey:tuningStoreKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:tuningEnabledKey];
}
- (void)tearDown {
    if (self.pad) { dm_gamepad_end_layout_edit(self.pad, NO); dm_gamepad_release_touches(self.pad); }
    if (self.root) {
        front_ios_focus_event(2); front_ios_focus_event(3);
        dm_preview_set_test_controllers(@[]);
        [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidDisconnectNotification object:nil];
        [self.root updateHingeStatus:-1 angle:NAN]; [self settleLayout];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
        [self.root.view removeFromSuperview];
        self.pad = nil; self.game = nil; self.root = nil;
    }
    if (self.savedDefaults) [NSUserDefaults.standardUserDefaults setPersistentDomain:self.savedDefaults forName:self.domain];
    else [NSUserDefaults.standardUserDefaults removePersistentDomainForName:self.domain];
    dm_touch_set_active_profile(self.savedActive); dm_preview_restore_test_preferences();
    [super tearDown];
}
- (NSDictionary *)storedReflection {
    return @{@"enabled": [NSUserDefaults.standardUserDefaults objectForKey:tuningEnabledKey] ?: NSNull.null,
        @"settings": [NSUserDefaults.standardUserDefaults objectForKey:tuningStoreKey] ?: NSNull.null};
}
- (void)startRuntime {
    [NSUserDefaults.standardUserDefaults setObject:@"inner" forKey:@"DmTouchDisplayMode"];
    dm_preview_set_test_controllers(@[]); dm_touch_set_active_profile(@"folded");
    for (NSString *profile in @[@"outer", @"inner", @"folded"]) {
        dm_touch_save_profile(profile, dm_touch_default_profile_settings());
        dm_touch_save_layout_style(profile, 1);
    }
    self.root = front_ios_root(); [self.root loadViewIfNeeded];
    self.root.view.frame = CGRectMake(0, 0, 466, 678); [self.root startGame];
    self.game = tuningFindClass(self.root.view, @"DmGameView");
    self.pad = tuningFindClass(self.root.view, @"DmGamepad");
    XCTAssertNotNil(self.game); XCTAssertNotNil(self.pad);
    [self settleLayout];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    dm_touch_set_active_profile(@"folded");
    [self.root updateHingeStatus:UIHingeStatusPartiallyOpen angle:M_PI_2]; [self settleLayout];
    front_ios_focus_event(2); front_ios_focus_event(3); dm_preview_reset_pause_history();
}
- (void)settleLayout {
    [self.root.view setNeedsLayout]; [self.root.view layoutIfNeeded];
    [tuningFindIdentifier(self.root.view, @"control.reflection.mirror") layoutIfNeeded];
    [self.game setNeedsLayout]; [self.game layoutIfNeeded]; [self.pad layoutIfNeeded];
}
- (DmReflectionPreferences *)preferences { return [self.root valueForKey:@"reflectionPreferences"]; }
- (DmControlReflection *)reflection { return [self.root valueForKey:@"controlReflection"]; }
- (void)sendButton:(NSString *)identifier {
    UIButton *button = (UIButton *)tuningFindIdentifier(self.root.view, identifier);
    XCTAssertTrue([button isKindOfClass:UIButton.class], @"Missing button %@", identifier);
    [button sendActionsForControlEvents:UIControlEventTouchUpInside]; [self settleLayout];
}
- (NSDictionary *)touchProfiles {
    return @{@"outer": dm_touch_profile_settings(@"outer"), @"inner": dm_touch_profile_settings(@"inner"),
             @"folded": dm_touch_profile_settings(@"folded")};
}
- (NSDictionary *)geometry {
    NSMutableDictionary *controls = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"A", @"B", @"X", @"Y", @"L", @"R", @"ZL", @"ZR", @"PLUS", @"MINUS", @"L3", @"R3", @"DPAD", @"LEFT_STICK", @"RIGHT_STICK"])
        controls[key] = [NSValue valueWithCGRect:[self.pad controlRect:key]];
    return @{@"game": [NSValue valueWithCGRect:[self.game convertRect:self.game.bounds toView:self.root.view]],
        @"gameBounds": [NSValue valueWithCGRect:self.game.bounds],
        @"drawable": [NSValue valueWithCGSize:((CAMetalLayer *)self.game.layer).drawableSize],
        @"pad": [NSValue valueWithCGRect:self.pad.frame], @"padBounds": [NSValue valueWithCGRect:self.pad.bounds],
        @"controls": controls};
}
- (void)assertEditingPaused {
    XCTAssertTrue(dm_gamepad_is_layout_editing(self.pad)); XCTAssertTrue(self.preferences.editing);
    NSDictionary *pause = dm_preview_pause_snapshot();
    XCTAssertEqualObjects(pause[@"gfxSuspended"], @YES);
    XCTAssertEqualObjects(pause[@"audioSuspended"], @YES);
    XCTAssertEqualObjects(pause[@"clockReason1Frozen"], @YES);
    XCTAssertEqualObjects(pause[@"focusState"], @2);
}
- (void)assertResumed {
    XCTAssertFalse(dm_gamepad_is_layout_editing(self.pad)); XCTAssertFalse(self.preferences.editing);
    NSDictionary *pause = dm_preview_pause_snapshot();
    XCTAssertEqualObjects(pause[@"gfxSuspended"], @NO);
    XCTAssertEqualObjects(pause[@"audioSuspended"], @NO);
    XCTAssertEqualObjects(pause[@"clockReason1Frozen"], @NO);
    XCTAssertEqualObjects(pause[@"focusState"], @1);
}
- (void)testDefaultSettingsRetainLegacySwitchWithoutWritingPreferences {
    NSDictionary *before = self.storedReflection;
    DmReflectionPreferences *preferences = [DmReflectionPreferences new];
    XCTAssertEqualObjects(preferences.currentSettings, dm_reflection_default_settings());
    XCTAssertEqualObjects(self.storedReflection, before);
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:tuningEnabledKey];
    XCTAssertEqualObjects(preferences.currentSettings[@"enabled"], @NO);
    XCTAssertEqualObjects(preferences.currentSettings[@"brightness"], @1);
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:tuningStoreKey]);
}
- (void)testMalformedAndNonfiniteSettingsFallBackOrClampToUsableValues {
    NSDictionary *defaults = dm_reflection_default_settings();
    XCTAssertEqualObjects(dm_reflection_normalize_settings((id)NSNull.null), defaults);
    XCTAssertEqualObjects(dm_reflection_normalize_settings((id)@[]), defaults);
    NSDictionary *invalid = dm_reflection_normalize_settings(@{
        @"brightness": @(NAN), @"length": @(INFINITY), @"blur": @"bad", @"feather": @(-INFINITY),
        @"curve": @"unknown", @"enabled": NSNull.null, @"angleLinked": @[], @"unrelated": @4});
    for (NSString *key in defaults) XCTAssertEqualObjects(invalid[key], defaults[key], @"Bad fallback for %@", key);
    XCTAssertNil(invalid[@"unrelated"]);
    NSDictionary *clamped = dm_reflection_normalize_settings(@{@"brightness": @2, @"length": @0,
        @"blur": @(-1), @"feather": @100, @"curve": @"smooth"});
    XCTAssertEqualObjects(clamped[@"brightness"], @1); XCTAssertEqualObjects(clamped[@"length"], @.25);
    XCTAssertEqualObjects(clamped[@"blur"], @0); XCTAssertEqualObjects(clamped[@"feather"], @40);
    XCTAssertEqualObjects(clamped[@"curve"], @"smooth");
}
- (void)testDraftCancelAndResetDoNotWriteUntilSave {
    DmReflectionPreferences *preferences = [DmReflectionPreferences new];
    NSDictionary *before = self.storedReflection;
    [preferences beginEditing];
    [preferences updateDraft:@{@"brightness": @.35, @"length": @2, @"blur": @.4, @"enabled": @NO}];
    XCTAssertEqualObjects(preferences.currentSettings[@"brightness"], @.35);
    XCTAssertEqualObjects(preferences.currentSettings[@"enabled"], @NO);
    XCTAssertEqualObjects(self.storedReflection, before);
    XCTAssertEqualObjects([DmReflectionPreferences new].currentSettings, dm_reflection_default_settings());
    [preferences resetDraft];
    XCTAssertEqualObjects(preferences.currentSettings, dm_reflection_default_settings());
    XCTAssertEqualObjects(self.storedReflection, before);
    [preferences endEditingSaving:NO]; XCTAssertFalse(preferences.editing);
    XCTAssertEqualObjects(self.storedReflection, before);
    [preferences beginEditing];
    [preferences updateDraft:@{@"brightness": @.35, @"length": @2, @"blur": @.4, @"enabled": @NO}];
    [preferences endEditingSaving:YES];
    DmReflectionPreferences *reloaded = [DmReflectionPreferences new];
    XCTAssertEqualObjects(reloaded.currentSettings, preferences.currentSettings);
    XCTAssertEqualObjects(reloaded.currentSettings[@"brightness"], @.35);
    XCTAssertEqualObjects(reloaded.currentSettings[@"length"], @2);
    XCTAssertEqualObjects(reloaded.currentSettings[@"enabled"], @NO);
}
- (void)testResetCanBeCancelledBackToTheSavedCustomSettings {
    DmReflectionPreferences *preferences = [DmReflectionPreferences new];
    [preferences beginEditing]; [preferences updateDraft:@{@"brightness": @.3, @"length": @2, @"curve": @"linear"}];
    [preferences endEditingSaving:YES];
    NSDictionary *saved = preferences.currentSettings, *stored = self.storedReflection;
    [preferences beginEditing]; [preferences resetDraft];
    XCTAssertEqualObjects(preferences.currentSettings, dm_reflection_default_settings());
    [preferences endEditingSaving:NO];
    XCTAssertEqualObjects(preferences.currentSettings, saved); XCTAssertEqualObjects(self.storedReflection, stored);
}
- (void)testUpdatesOutsideAnEditingSessionDoNotPersistOrChangeTheCurrentSettings {
    DmReflectionPreferences *preferences = [DmReflectionPreferences new];
    NSDictionary *settings = preferences.currentSettings, *stored = self.storedReflection;
    [preferences updateDraft:@{@"brightness": @.2}]; [preferences resetDraft]; [preferences endEditingSaving:YES];
    XCTAssertEqualObjects(preferences.currentSettings, settings); XCTAssertEqualObjects(self.storedReflection, stored);
}
- (void)testVisualSettingsAffectTheCurveAndLengthWithoutRelaxingDisplayOrHingeGates {
    NSDictionary *base = @{@"brightness": @.8, @"length": @2, @"blur": @.4, @"feather": @0, @"curve": @"bezier"};
    DmReflectionStyle right = dm_reflection_configured_style(base, YES, YES, M_PI_2);
    DmReflectionStyle acute = dm_reflection_configured_style(base, YES, YES, M_PI_4);
    XCTAssertTrue(right.visible); XCTAssertEqualWithAccuracy(right.reachFraction, 3.75, 1e-10);
    XCTAssertEqualWithAccuracy(acute.reachFraction, 5.625, 1e-10);
    XCTAssertEqualWithAccuracy(right.blurStrength, .4, 1e-10); XCTAssertEqual(right.featherPoints, 0);
    XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(right, 375, 400), .8 * .984375, 1e-10);
    NSMutableDictionary *fixed = [base mutableCopy]; fixed[@"angleLinked"] = @NO;
    XCTAssertEqualWithAccuracy(dm_reflection_configured_style(fixed, YES, YES, M_PI_4).reachFraction, 3.75, 1e-10);
    XCTAssertFalse(dm_reflection_configured_style(fixed, NO, YES, M_PI_2).visible);
    XCTAssertFalse(dm_reflection_configured_style(fixed, YES, NO, M_PI_2).visible);
    XCTAssertFalse(dm_reflection_configured_style(fixed, YES, YES, M_PI).visible);
    XCTAssertFalse(dm_reflection_configured_style(fixed, YES, YES, NAN).visible);
    fixed[@"enabled"] = @NO;
    XCTAssertFalse(dm_reflection_configured_style(fixed, YES, YES, M_PI_2).visible);
    NSDictionary *curves = @{@"linear": @.75, @"smooth": @.84375, @"bezier": @.984375};
    for (NSString *curve in curves) {
        DmReflectionStyle style = dm_reflection_configured_style(@{@"curve": curve, @"feather": @0}, YES, YES, M_PI_2);
        XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(style, 187.5, 400), [curves[curve] doubleValue], 1e-10);
    }
}
- (void)testPreviewChangesPreserveInputPauseGeometryAndAllSavedTouchProfiles {
    [self startRuntime]; [self sendButton:@"live.layout.open"]; [self assertEditingPaused];
    NSDictionary *geometry = self.geometry, *profiles = self.touchProfiles, *stored = self.storedReflection;
    NSDictionary *touchDraft = dm_gamepad_editor_settings(self.pad);
    NSNumber *published = dm_preview_input_snapshot()[@"publishCount"];
    CALayer *layer = self.game.layer; dm_preview_reset_pause_history();
    for (NSDictionary *change in @[@{@"brightness": @.42}, @{@"length": @1.4}, @{@"blur": @.5},
        @{@"feather": @24}, @{@"curve": @"smooth"}, @{@"angleLinked": @NO}, @{@"enabled": @NO}, @{@"enabled": @YES}]) {
        [self.preferences updateDraft:change]; [self settleLayout];
        [self assertEditingPaused]; XCTAssertEqualObjects(self.geometry, geometry);
        XCTAssertEqual(self.game.layer, layer); XCTAssertEqualObjects(self.touchProfiles, profiles);
        XCTAssertEqualObjects(dm_gamepad_editor_settings(self.pad), touchDraft);
        XCTAssertEqualObjects(dm_preview_input_snapshot()[@"publishCount"], published);
        XCTAssertEqualObjects(self.storedReflection, stored);
        XCTAssertEqual([dm_preview_pause_snapshot()[@"events"] count], 0u);
    }
    XCTAssertEqualWithAccuracy([self.reflection.debugSnapshot[@"peakOpacity"] doubleValue], .42, 1e-10);
    [self sendButton:@"live.layout.cancel"]; [self assertResumed];
    XCTAssertEqualObjects(self.storedReflection, stored);
}
- (void)testRuntimeSavePersistsBothDraftsAndCancelRestoresBothSavedValues {
    [self startRuntime]; [self sendButton:@"live.layout.open"];
    NSDictionary *outer = dm_touch_profile_settings(@"outer"), *inner = dm_touch_profile_settings(@"inner");
    [self.preferences updateDraft:@{@"brightness": @.35, @"length": @1.8}];
    dm_gamepad_update_layout_draft(self.pad, @{@"opacity": @.4});
    [self sendButton:@"live.layout.save"]; [self assertResumed];
    XCTAssertEqualObjects([DmReflectionPreferences new].currentSettings[@"brightness"], @.35);
    XCTAssertEqualObjects(dm_touch_profile_settings(@"folded")[@"opacity"], @.4);
    XCTAssertEqualObjects(dm_touch_profile_settings(@"outer"), outer); XCTAssertEqualObjects(dm_touch_profile_settings(@"inner"), inner);
    NSDictionary *stored = self.storedReflection, *touch = self.touchProfiles;
    [self sendButton:@"live.layout.open"];
    [self.preferences updateDraft:@{@"brightness": @.75, @"length": @.5}];
    dm_gamepad_update_layout_draft(self.pad, @{@"opacity": @.9});
    [self sendButton:@"live.layout.cancel"]; [self assertResumed];
    XCTAssertEqualObjects(self.storedReflection, stored); XCTAssertEqualObjects(self.touchProfiles, touch);
    XCTAssertEqualObjects(self.preferences.currentSettings[@"brightness"], @.35);
}
- (void)testHingeChangesPreserveTheReflectionDraftAndNeverSaveIt {
    [self startRuntime]; [self sendButton:@"live.layout.open"];
    [self.preferences updateDraft:@{@"brightness": @.3, @"length": @2, @"blur": @.6}];
    NSDictionary *draft = self.preferences.currentSettings, *stored = self.storedReflection, *geometry = self.geometry;
    for (NSNumber *angle in @[@(M_PI_4), @(M_PI), @(M_PI_2)]) {
        NSInteger status = angle.doubleValue == M_PI ? UIHingeStatusFullyOpen : UIHingeStatusPartiallyOpen;
        [self.root updateHingeStatus:status angle:angle.doubleValue]; [self settleLayout];
        [self assertEditingPaused];
        XCTAssertEqualObjects(self.preferences.currentSettings, draft); XCTAssertEqualObjects(self.storedReflection, stored);
        XCTAssertEqualObjects(self.geometry, geometry);
        XCTAssertEqual(self.reflection.isActive, angle.doubleValue != M_PI);
    }
    [self sendButton:@"live.layout.cancel"]; [self assertResumed];
}
- (void)testChangingControlGeometryCancelsUnsavedVisualAndTouchDrafts {
    [self startRuntime]; [self sendButton:@"live.layout.open"];
    NSDictionary *stored = self.storedReflection, *profiles = self.touchProfiles;
    [self.preferences updateDraft:@{@"brightness": @.3}]; dm_gamepad_update_layout_draft(self.pad, @{@"opacity": @.4});
    self.root.view.frame = CGRectMake(0, 0, 500, 740); [self settleLayout];
    [self assertResumed]; XCTAssertEqualObjects(self.storedReflection, stored); XCTAssertEqualObjects(self.touchProfiles, profiles);
    XCTAssertEqualObjects(self.preferences.currentSettings[@"brightness"], @1);
    XCTAssertNil([self.root valueForKey:@"layoutEditor"]);
}
- (void)testRotatingToInnerLandscapeCancelsTheVisualDraftAndHidesTheReflection {
    [self startRuntime]; [self sendButton:@"live.layout.open"];
    NSDictionary *stored = self.storedReflection, *profiles = self.touchProfiles;
    [self.preferences updateDraft:@{@"brightness": @.3}]; dm_gamepad_update_layout_draft(self.pad, @{@"opacity": @.4});
    self.root.view.frame = CGRectMake(0, 0, 678, 466); dm_touch_set_active_profile(@"inner"); [self settleLayout];
    [self assertResumed]; XCTAssertFalse(self.reflection.isActive);
    XCTAssertEqualObjects(self.storedReflection, stored); XCTAssertEqualObjects(self.touchProfiles, profiles);
    XCTAssertEqualObjects(self.preferences.currentSettings[@"brightness"], @1);
}

- (void)testSavingEditedParametersPreservesAnExternalUntouchedMasterSwitch {
    DmReflectionPreferences *preferences = [DmReflectionPreferences new];
    [preferences beginEditing]; [preferences updateDraft:@{@"brightness": @.3}];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:tuningEnabledKey];
    XCTAssertEqualObjects(preferences.currentSettings[@"enabled"], @NO);
    [preferences endEditingSaving:YES];
    XCTAssertFalse([NSUserDefaults.standardUserDefaults boolForKey:tuningEnabledKey]);
    XCTAssertEqualObjects([DmReflectionPreferences new].currentSettings[@"brightness"], @.3);
}
- (void)testReflectionTabSliderPreviewsAndSaveUsesTheRuntimeTransaction {
    [self startRuntime]; [self sendButton:@"live.layout.open"];
    UISegmentedControl *tabs = (UISegmentedControl *)tuningFindIdentifier(self.root.view, @"live.layout.tabs");
    XCTAssertTrue([tabs isKindOfClass:UISegmentedControl.class]);
    if (![tabs isKindOfClass:UISegmentedControl.class]) return;
    tabs.selectedSegmentIndex = 1; [tabs sendActionsForControlEvents:UIControlEventValueChanged];
    UIViewController *editor = [self.root valueForKey:@"layoutEditor"];
    [editor selectReflectionParameter:@"brightness"];
    UISlider *slider = (UISlider *)tuningFindIdentifier(self.root.view, @"live.reflection.slider");
    XCTAssertTrue([slider isKindOfClass:UISlider.class]);
    if (![slider isKindOfClass:UISlider.class]) return;
    NSDictionary *stored = self.storedReflection;
    slider.value = .4; [slider sendActionsForControlEvents:UIControlEventValueChanged]; [self settleLayout];
    XCTAssertEqualWithAccuracy([self.preferences.currentSettings[@"brightness"] doubleValue], .4, .001);
    XCTAssertEqualWithAccuracy([self.reflection.debugSnapshot[@"peakOpacity"] doubleValue], .4, .001);
    XCTAssertEqualObjects(self.storedReflection, stored); [self assertEditingPaused];
    [self sendButton:@"live.layout.save"]; [self assertResumed];
    XCTAssertEqualWithAccuracy([[DmReflectionPreferences new].currentSettings[@"brightness"] doubleValue], .4, .001);
}
- (void)testReflectionTabResetKeepsTheUnsavedTouchDraftAndRemainsCancellable {
    [self startRuntime]; [self sendButton:@"live.layout.open"];
    dm_gamepad_update_layout_draft(self.pad, @{@"opacity": @.4});
    [self.preferences updateDraft:@{@"brightness": @.3}];
    NSDictionary *stored = self.storedReflection, *profiles = self.touchProfiles;
    UISegmentedControl *tabs = (UISegmentedControl *)tuningFindIdentifier(self.root.view, @"live.layout.tabs");
    XCTAssertTrue([tabs isKindOfClass:UISegmentedControl.class]);
    if (![tabs isKindOfClass:UISegmentedControl.class]) return;
    tabs.selectedSegmentIndex = 1; [tabs sendActionsForControlEvents:UIControlEventValueChanged];
    [self sendButton:@"live.layout.reset"];
    XCTAssertEqualObjects(self.preferences.currentSettings, dm_reflection_default_settings());
    XCTAssertEqualObjects(dm_gamepad_editor_settings(self.pad)[@"opacity"], @.4);
    XCTAssertEqualObjects(self.storedReflection, stored); [self assertEditingPaused];
    [self sendButton:@"live.layout.cancel"]; [self assertResumed];
    XCTAssertEqualObjects(self.touchProfiles, profiles); XCTAssertEqualObjects(self.storedReflection, stored);
}
@end
