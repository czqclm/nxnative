// Exercises the production runtime pad and live editor. Synthetic UITouch
// responders and target/action calls are unit tests, not physical input tests.
#import <XCTest/XCTest.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import "DmGamepad.h"
#import "DmTouchConfig.h"
#import "DmLiveTouchEditor.h"

NSDictionary *dm_preview_input_snapshot(void);
NSDictionary *dm_preview_pause_snapshot(void);
void dm_preview_reset_pause_history(void);
void dm_preview_save_test_preferences(void);
void dm_preview_restore_test_preferences(void);
void dm_preview_set_test_controllers(NSArray<GCController *> *controllers);
UIViewController *front_ios_root(void);
void front_ios_focus_event(int event);

@interface UIView (RuntimeGeometryTests)
- (CGRect)controlRect:(NSString *)identifier;
@end
@interface UIViewController (FrontRuntimeTests)
- (void)startGame;
@end
@interface DmLiveTouchEditor (LiveToolbarTests)
- (void)selectParameter:(NSString *)parameter;
- (void)selectControl:(NSString *)control;
@end

@interface RuntimeFixtureTouch : UITouch
@property(nonatomic, strong) UIView *coordinateView;
@property(nonatomic) CGPoint point;
@property(nonatomic) UITouchPhase testPhase;
@end
@implementation RuntimeFixtureTouch
- (CGPoint)locationInView:(UIView *)view { return view == self.coordinateView ? self.point : [self.coordinateView convertPoint:self.point toView:view]; }
- (CGPoint)previousLocationInView:(UIView *)view { return [self locationInView:view]; }
- (UITouchPhase)phase { return self.testPhase; }
@end

static CGPoint midpoint(CGRect rect) { return CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)); }
static UIView *findLiveIdentifier(UIView *view, NSString *identifier) {
    if ([view.accessibilityIdentifier isEqualToString:identifier]) return view;
    for (UIView *child in view.subviews) { UIView *found = findLiveIdentifier(child, identifier); if (found) return found; }
    return nil;
}
static UIView *findLiveClass(UIView *view, NSString *name) {
    if ([NSStringFromClass(view.class) isEqualToString:name]) return view;
    for (UIView *child in view.subviews) { UIView *found = findLiveClass(child, name); if (found) return found; }
    return nil;
}
static NSArray<NSString *> *allControls(void) {
    return @[@"A", @"B", @"X", @"Y", @"L", @"R", @"ZL", @"ZR", @"PLUS", @"MINUS", @"L3", @"R3", @"DPAD", @"LEFT_STICK", @"RIGHT_STICK"];
}
static NSDictionary *controlGeometry(UIView *pad) {
    NSMutableDictionary *rects = [NSMutableDictionary dictionary];
    for (NSString *key in allControls()) rects[key] = [NSValue valueWithCGRect:[pad controlRect:key]];
    return rects;
}
static NSDictionary *viewGeometry(UIView *pad) {
    return @{@"frame": [NSValue valueWithCGRect:pad.frame], @"bounds": [NSValue valueWithCGRect:pad.bounds],
        @"transform": [NSValue valueWithCGAffineTransform:pad.transform], @"safeInsets": [NSValue valueWithUIEdgeInsets:pad.safeAreaInsets],
        @"controls": controlGeometry(pad)};
}

// Override only this fixture's safeAreaInsets, with no extra ivars or changes
// to the production class. In particular, do not use the isolated preview's
// safe-inset API: these tests must exercise runtime -> editing on the same pad.
static char insetKey;
static UIEdgeInsets fixtureInsets(id object, SEL selector) {
    (void)selector;
    NSValue *value = objc_getAssociatedObject(object, &insetKey);
    return value ? value.UIEdgeInsetsValue : UIEdgeInsetsZero;
}
static void setFixtureInsets(UIView *pad, UIEdgeInsets insets) {
    Class cls = NSClassFromString(@"PreviewRuntimeInsetGamepad");
    if (!cls) {
        cls = objc_allocateClassPair(NSClassFromString(@"DmGamepad"), "PreviewRuntimeInsetGamepad", 0);
        Method method = class_getInstanceMethod(UIView.class, @selector(safeAreaInsets));
        class_addMethod(cls, @selector(safeAreaInsets), (IMP)fixtureInsets, method_getTypeEncoding(method));
        objc_registerClassPair(cls);
    }
    object_setClass(pad, cls);
    objc_setAssociatedObject(pad, &insetKey, [NSValue valueWithUIEdgeInsets:insets], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [pad safeAreaInsetsDidChange];
}

@interface RuntimeLayoutFixture : XCTestCase
@property(nonatomic, copy) NSDictionary *savedDefaults;
@property(nonatomic, copy) NSString *savedActive;
@property(nonatomic, copy) NSString *defaultsDomain;
@property(nonatomic, strong) UIView *container;
@property(nonatomic, strong) UIView *pad;
@end
@implementation RuntimeLayoutFixture
- (void)recordIssue:(XCTIssue *)issue {
    // The installed simulator's CoreSymbolication can block opening an object
    // file while XCTest resolves a failure stack. Keep failure severity, text,
    // attachments and source location, but avoid that unrelated symbol lookup.
    fprintf(stderr, "PREVIEW_TEST_ISSUE: %s\n", issue.compactDescription.UTF8String);
    XCTMutableIssue *recorded = [issue mutableCopy];
    recorded.sourceCodeContext = [[XCTSourceCodeContext alloc] initWithCallStack:@[] location:issue.sourceCodeContext.location];
    [super recordIssue:recorded];
}
- (void)setUp {
    [super setUp]; XCTAssertTrue(NSThread.isMainThread);
    self.defaultsDomain = NSBundle.mainBundle.bundleIdentifier;
    XCTAssertEqualObjects(self.defaultsDomain, @"org.nxnative.duo-ui-preview");
    self.savedDefaults = [NSUserDefaults.standardUserDefaults persistentDomainForName:self.defaultsDomain];
    self.savedActive = dm_touch_active_profile();
    dm_preview_save_test_preferences();
    [NSUserDefaults.standardUserDefaults setObject:@"outer" forKey:@"DmTouchDisplayMode"];
    dm_preview_set_test_controllers(@[]); dm_touch_set_active_profile(@"outer");
    for (NSString *profile in @[@"outer", @"inner", @"folded"]) {
        dm_touch_save_profile(profile, dm_touch_default_profile_settings()); dm_touch_save_layout_style(profile, 1);
    }
}
- (void)tearDown {
    if (self.pad) { dm_gamepad_end_layout_edit(self.pad, NO); dm_gamepad_release_touches(self.pad); }
    dm_preview_set_test_controllers(@[]);
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidDisconnectNotification object:nil];
    [self drainControllerQueue];
    [self.pad removeFromSuperview]; self.pad = nil; self.container = nil;
    if (self.savedDefaults) [NSUserDefaults.standardUserDefaults setPersistentDomain:self.savedDefaults forName:self.defaultsDomain];
    else [NSUserDefaults.standardUserDefaults removePersistentDomainForName:self.defaultsDomain];
    dm_touch_set_active_profile(self.savedActive);
    dm_preview_restore_test_preferences();
    [super tearDown];
}
- (void)drainControllerQueue { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]]; }
- (UIView *)makePad:(CGRect)frame insets:(UIEdgeInsets)insets profile:(NSString *)profile {
    if (self.pad) { dm_gamepad_end_layout_edit(self.pad, NO); [self.pad removeFromSuperview]; self.pad = nil; }
    dm_touch_set_active_profile(profile);
    self.container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MAX(1000, CGRectGetMaxX(frame)), MAX(1000, CGRectGetMaxY(frame)))];
    self.pad = dm_gamepad_view(frame); [self.container addSubview:self.pad];
    setFixtureInsets(self.pad, insets);
    dm_gamepad_set_game_rect(self.pad, CGRectMake(84, 0, 764, 430));
    [self.pad setNeedsLayout]; [self.pad layoutIfNeeded]; [self drainControllerQueue];
    // The app's launcher observer may have updated the active profile while the
    // queue drained; the fixture explicitly chooses its profile afterwards.
    dm_touch_set_active_profile(profile); [self.pad layoutIfNeeded]; return self.pad;
}
- (UIView *)makePad { return [self makePad:CGRectMake(0, 0, 932, 430) insets:UIEdgeInsetsZero profile:@"outer"]; }
- (void)drag:(NSString *)control to:(CGPoint)point {
    RuntimeFixtureTouch *touch = [RuntimeFixtureTouch new]; touch.coordinateView = self.pad;
    touch.point = midpoint([self.pad controlRect:control]); touch.testPhase = UITouchPhaseBegan;
    [self.pad touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
    touch.point = point; touch.testPhase = UITouchPhaseMoved;
    [self.pad touchesMoved:[NSSet setWithObject:touch] withEvent:nil];
    touch.testPhase = UITouchPhaseEnded; [self.pad touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
}
- (void)sendButton:(NSString *)identifier in:(UIView *)view {
    UIControl *button = (UIControl *)findLiveIdentifier(view, identifier);
    XCTAssertTrue([button isKindOfClass:UIControl.class], @"Missing control %@", identifier);
    XCTAssertTrue(button.enabled, @"Disabled control %@", identifier);
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}
- (NSDictionary *)allProfileSettings {
    return @{@"outer": dm_touch_profile_settings(@"outer"), @"inner": dm_touch_profile_settings(@"inner"), @"folded": dm_touch_profile_settings(@"folded")};
}
@end

@interface RuntimeLayoutTests : RuntimeLayoutFixture
@end
@implementation RuntimeLayoutTests
- (void)testBeginAndCancelPreserveActualGeometryInAllDisplayRegions {
    NSArray *cases = @[
        @{@"profile": @"outer", @"frame": [NSValue valueWithCGRect:CGRectMake(0, 0, 466, 678)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 0, 0, 84)]},
        @{@"profile": @"outer", @"frame": [NSValue valueWithCGRect:CGRectMake(0, 0, 932, 430)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 84, 21, 0)]},
        @{@"profile": @"inner", @"frame": [NSValue valueWithCGRect:CGRectMake(0, 0, 608, 860)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(30, 0, 21, 0)]},
        @{@"profile": @"folded", @"frame": [NSValue valueWithCGRect:CGRectMake(0, 450, 608, 430)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 0, 21, 0)]},
        @{@"profile": @"folded", @"frame": [NSValue valueWithCGRect:CGRectMake(320, 0, 300, 608)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 0, 0, 84)]}
    ];
    for (NSDictionary *example in cases) for (NSInteger style = 0; style <= 2; style++) {
        NSString *profile = example[@"profile"]; dm_touch_save_layout_style(profile, style);
        UIView *pad = [self makePad:[example[@"frame"] CGRectValue] insets:[example[@"insets"] UIEdgeInsetsValue] profile:profile];
        NSDictionary *before = viewGeometry(pad);
        XCTAssertTrue(dm_gamepad_begin_layout_edit(pad)); [pad layoutIfNeeded];
        XCTAssertEqualObjects(dm_gamepad_layout_edit_profile(pad), profile);
        XCTAssertEqualObjects(viewGeometry(pad), before, @"%@ style %ld changed on entry", profile, (long)style);
        XCTAssertTrue(dm_gamepad_end_layout_edit(pad, NO)); [pad layoutIfNeeded];
        XCTAssertEqualObjects(viewGeometry(pad), before, @"%@ style %ld changed on cancel", profile, (long)style);
    }
}
- (void)testBeginKeepsExistingBoundsOriginAndTransform {
    UIView *pad = [self makePad];
    pad.bounds = CGRectMake(7, 11, 932, 430); pad.transform = CGAffineTransformMakeScale(.8, .8);
    [pad setNeedsLayout]; [pad layoutIfNeeded]; NSDictionary *before = viewGeometry(pad);
    XCTAssertTrue(dm_gamepad_begin_layout_edit(pad)); [pad layoutIfNeeded];
    XCTAssertEqualObjects(viewGeometry(pad), before);
    XCTAssertTrue(dm_gamepad_end_layout_edit(pad, NO)); [pad layoutIfNeeded];
    XCTAssertEqualObjects(viewGeometry(pad), before);
}
- (void)testRuntimeDragScaleAndScalarDraftNeverPersistOrPublishAndCancelRestores {
    UIView *pad = [self makePad]; NSDictionary *before = [self allProfileSettings], *geometry = viewGeometry(pad);
    XCTAssertTrue(dm_gamepad_begin_layout_edit(pad));
    NSNumber *published = dm_preview_input_snapshot()[@"publishCount"];
    [self drag:@"LEFT_STICK" to:CGPointMake(400, 200)];
    XCTAssertEqualObjects(dm_gamepad_editor_selection(pad), @"LEFT_STICK");
    dm_gamepad_editor_set_scale(pad, 1.7);
    dm_gamepad_update_layout_draft(pad, @{@"opacity": @.35, @"leftSensitivity": @2.3, @"rightDeadZone": @.25});
    NSDictionary *draft = dm_gamepad_editor_settings(pad);
    XCTAssertEqualWithAccuracy([draft[@"controls"][@"LEFT_STICK"][@"x"] doubleValue], 400.0/932, .001);
    XCTAssertEqualWithAccuracy([draft[@"controls"][@"LEFT_STICK"][@"scale"] doubleValue], 1.7, .001);
    XCTAssertEqualObjects(draft[@"opacity"], @.35); XCTAssertEqualObjects(draft[@"leftSensitivity"], @2.3);
    XCTAssertEqualObjects(draft[@"rightDeadZone"], @.25);
    XCTAssertEqualObjects([self allProfileSettings], before);
    XCTAssertEqualObjects(dm_preview_input_snapshot()[@"publishCount"], published);
    XCTAssertEqualObjects(dm_preview_input_snapshot()[@"axes"], (@[@0,@0,@0,@0]));
    XCTAssertTrue(dm_gamepad_end_layout_edit(pad, NO)); [pad layoutIfNeeded];
    XCTAssertEqualObjects([self allProfileSettings], before); XCTAssertEqualObjects(viewGeometry(pad), geometry);
    XCTAssertEqualObjects(dm_gamepad_editor_settings(pad), before[@"outer"]);
}
- (void)testRuntimeSaveTargetsOnlyTheProfileAtEntryAndNotifies {
    UIView *pad = [self makePad:CGRectMake(0, 450, 608, 430) insets:UIEdgeInsetsZero profile:@"folded"];
    NSDictionary *before = [self allProfileSettings]; NSMutableArray *events = [NSMutableArray array];
    id token = [NSNotificationCenter.defaultCenter addObserverForName:DmGamepadLayoutEditingDidChangeNotification object:pad queue:nil usingBlock:^(NSNotification *note) { [events addObject:note.userInfo]; }];
    XCTAssertTrue(dm_gamepad_begin_layout_edit(pad));
    [self drag:@"A" to:CGPointMake(280, 180)]; dm_gamepad_editor_set_scale(pad, 1.4);
    dm_gamepad_update_layout_draft(pad, @{@"leftSensitivity": @.7, @"opacity": @.45});
    NSDictionary *expected = dm_gamepad_editor_settings(pad);
    XCTAssertTrue(dm_gamepad_end_layout_edit(pad, YES));
    XCTAssertFalse(dm_gamepad_is_layout_editing(pad));
    XCTAssertEqualObjects(dm_touch_profile_settings(@"folded"), expected);
    XCTAssertEqualObjects(dm_touch_profile_settings(@"outer"), before[@"outer"]);
    XCTAssertEqualObjects(dm_touch_profile_settings(@"inner"), before[@"inner"]);
    XCTAssertEqual(events.count, 2u);
    XCTAssertEqualObjects(events.firstObject[@"editing"], @YES); XCTAssertEqualObjects(events.lastObject[@"editing"], @NO);
    for (NSDictionary *event in events) { XCTAssertEqualObjects(event[@"profile"], @"folded"); XCTAssertTrue([event[@"reason"] length] > 0); }
    [NSNotificationCenter.defaultCenter removeObserver:token];
}
- (void)testResetChangesOnlyTheUnsavedRuntimeDraft {
    dm_touch_save_profile(@"outer", @{@"opacity": @.3, @"rightSensitivity": @2, @"controls": @{@"A": @{@"x": @.6, @"y": @.3, @"scale": @1.6}}});
    UIView *pad = [self makePad]; NSDictionary *before = [self allProfileSettings];
    XCTAssertTrue(dm_gamepad_begin_layout_edit(pad)); dm_gamepad_reset_layout_draft(pad);
    XCTAssertEqualObjects(dm_gamepad_editor_settings(pad), dm_touch_default_profile_settings());
    XCTAssertEqualObjects([self allProfileSettings], before);
    XCTAssertTrue(dm_gamepad_end_layout_edit(pad, NO));
    XCTAssertEqualObjects(dm_gamepad_editor_settings(pad), before[@"outer"]);
    XCTAssertEqualObjects([self allProfileSettings], before);
}
- (void)testProfileAndActualGeometryChangesAutomaticallyCancelTheDraft {
    UIView *pad = [self makePad]; NSDictionary *before = [self allProfileSettings];
    XCTAssertTrue(dm_gamepad_begin_layout_edit(pad)); dm_gamepad_update_layout_draft(pad, @{@"opacity": @.3});
    dm_touch_set_active_profile(@"inner"); XCTAssertFalse(dm_gamepad_is_layout_editing(pad));
    XCTAssertEqualObjects([self allProfileSettings], before); dm_touch_set_active_profile(@"outer");
    NSArray<void (^)(void)> *changes = @[
        ^{ pad.frame = CGRectOffset(pad.frame, 4, 0); },
        ^{ CGRect bounds = pad.bounds; bounds.size.width -= 10; pad.bounds = bounds; },
        ^{ pad.transform = CGAffineTransformMakeScale(.95, .95); },
        ^{ setFixtureInsets(pad, UIEdgeInsetsMake(0, 84, 0, 0)); },
        ^{ dm_gamepad_set_game_rect(pad, CGRectMake(80, 5, 700, 400)); }
    ];
    for (void (^change)(void) in changes) {
        XCTAssertTrue(dm_gamepad_begin_layout_edit(pad)); dm_gamepad_update_layout_draft(pad, @{@"opacity": @.3});
        change(); [pad setNeedsLayout]; [pad layoutIfNeeded];
        XCTAssertFalse(dm_gamepad_is_layout_editing(pad)); XCTAssertEqualObjects([self allProfileSettings], before);
    }
}
- (void)testRepeatedUnchangedLayoutDoesNotCancelEditing {
    UIView *pad = [self makePad]; XCTAssertTrue(dm_gamepad_begin_layout_edit(pad));
    pad.frame = pad.frame; pad.bounds = pad.bounds; pad.transform = pad.transform;
    [pad safeAreaInsetsDidChange]; dm_gamepad_set_game_rect(pad, CGRectMake(84, 0, 764, 430));
    dm_touch_set_active_profile(@"outer"); [pad setNeedsLayout]; [pad layoutIfNeeded];
    XCTAssertTrue(dm_gamepad_is_layout_editing(pad));
}
- (void)testControllerConnectionKeepsEditorVisibleAndExitRestoresControllerPolicy {
    UIView *pad = [self makePad]; CALayer *controls = pad.layer.sublayers.firstObject;
    XCTAssertTrue(dm_gamepad_begin_layout_edit(pad)); dm_gamepad_update_layout_draft(pad, @{@"opacity": @.4});
    GCController *controller = [GCController controllerWithExtendedGamepad];
    dm_preview_set_test_controllers(@[controller]);
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:controller]; [self drainControllerQueue];
    XCTAssertTrue(dm_gamepad_is_layout_editing(pad)); XCTAssertFalse(controls.hidden);
    XCTAssertEqualObjects(dm_gamepad_editor_settings(pad)[@"opacity"], @.4);
    XCTAssertTrue(dm_gamepad_end_layout_edit(pad, NO)); [pad layoutIfNeeded]; XCTAssertTrue(controls.hidden);
    XCTAssertTrue(dm_gamepad_begin_layout_edit(pad)); [pad layoutIfNeeded]; XCTAssertFalse(controls.hidden);
    XCTAssertTrue(dm_gamepad_end_layout_edit(pad, YES)); [pad layoutIfNeeded]; XCTAssertTrue(controls.hidden);
    dm_preview_set_test_controllers(@[]);
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidDisconnectNotification object:controller]; [self drainControllerQueue];
    XCTAssertFalse(controls.hidden);
}
- (DmLiveTouchEditor *)makeToolbar {
    DmLiveTouchEditor *editor = [[DmLiveTouchEditor alloc] initWithPad:self.pad]; [editor loadViewIfNeeded];
    editor.view.frame = self.container.bounds;
    [self.container addSubview:editor.view];
    [editor layoutInBounds:self.container.bounds safeInsets:UIEdgeInsetsZero preferredRegion:self.pad.frame];
    [editor.view setNeedsLayout]; [editor.view layoutIfNeeded]; return editor;
}
- (void)testToolbarActualSliderResetCancelAndSaveActionsUseRuntimeDraft {
    UIView *pad = [self makePad]; NSDictionary *before = [self allProfileSettings], *geometry = viewGeometry(pad);
    XCTAssertTrue(dm_gamepad_begin_layout_edit(pad)); DmLiveTouchEditor *editor = [self makeToolbar];
    XCTAssertEqualObjects(viewGeometry(pad), geometry);
    [editor selectControl:@"LEFT_STICK"]; [editor selectParameter:@"scale"];
    UISlider *slider = (UISlider *)findLiveIdentifier(editor.view, @"live.layout.slider"); XCTAssertNotNil(slider);
    slider.value = 1.5; [slider sendActionsForControlEvents:UIControlEventValueChanged];
    XCTAssertEqualWithAccuracy([dm_gamepad_editor_settings(pad)[@"controls"][@"LEFT_STICK"][@"scale"] doubleValue], 1.5, .001);
    [editor selectParameter:@"opacity"]; slider.value = .4; [slider sendActionsForControlEvents:UIControlEventValueChanged];
    XCTAssertEqualWithAccuracy([dm_gamepad_editor_settings(pad)[@"opacity"] doubleValue], .4, .001);
    XCTAssertEqualObjects([self allProfileSettings], before);
    [self sendButton:@"live.layout.reset" in:editor.view];
    XCTAssertEqualObjects(dm_gamepad_editor_settings(pad), dm_touch_default_profile_settings());
    XCTAssertEqualObjects([self allProfileSettings], before);
    [self sendButton:@"live.layout.cancel" in:editor.view]; XCTAssertFalse(dm_gamepad_is_layout_editing(pad));
    XCTAssertEqualObjects([self allProfileSettings], before); [editor.view removeFromSuperview];
    XCTAssertTrue(dm_gamepad_begin_layout_edit(pad)); editor = [self makeToolbar];
    [editor selectParameter:@"rightSensitivity"]; slider = (UISlider *)findLiveIdentifier(editor.view, @"live.layout.slider");
    slider.value = 1.75; [slider sendActionsForControlEvents:UIControlEventValueChanged];
    NSDictionary *expected = dm_gamepad_editor_settings(pad);
    [self sendButton:@"live.layout.save" in:editor.view]; XCTAssertFalse(dm_gamepad_is_layout_editing(pad));
    XCTAssertEqualObjects(dm_touch_profile_settings(@"outer"), expected);
    XCTAssertEqualObjects(dm_touch_profile_settings(@"inner"), before[@"inner"]); XCTAssertEqualObjects(dm_touch_profile_settings(@"folded"), before[@"folded"]);
    [editor.view removeFromSuperview];
}
- (void)testToolbarTransparentRootPassesThroughPointsOutsideItsControls {
    [self makePad]; XCTAssertTrue(dm_gamepad_begin_layout_edit(self.pad)); DmLiveTouchEditor *editor = [self makeToolbar];
    UIView *save = findLiveIdentifier(editor.view, @"live.layout.save"); XCTAssertNotNil(save);
    CGPoint savePoint = [save convertPoint:midpoint(save.bounds) toView:editor.view];
    XCTAssertNotNil([editor.view hitTest:savePoint withEvent:nil]);
    BOOL foundPassThrough = NO;
    for (CGFloat y = 10; y < editor.view.bounds.size.height; y += 30) {
        if (![editor.view hitTest:CGPointMake(10, y) withEvent:nil]) { foundPassThrough = YES; break; }
    }
    XCTAssertTrue(foundPassThrough); [editor.view removeFromSuperview];
}
@end

@interface FrontLayoutPauseTests : RuntimeLayoutFixture
@property(nonatomic, strong) UIViewController *root;
@end
@implementation FrontLayoutPauseTests
- (void)setUp {
    [super setUp];
    // Use the real front end and its real button/child toolbar. The host boot
    // function remains the explicit UI-only stub, so no game code can execute.
    self.root = front_ios_root(); [self.root loadViewIfNeeded]; self.root.view.frame = CGRectMake(0, 0, 932, 430);
    [self.root startGame]; [self.root.view setNeedsLayout]; [self.root.view layoutIfNeeded];
    self.pad = findLiveClass(self.root.view, @"DmGamepad"); XCTAssertNotNil(self.pad);
    self.container = self.root.view; [self drainControllerQueue];
    front_ios_focus_event(2); front_ios_focus_event(3); dm_preview_reset_pause_history();
}
- (void)tearDown {
    dm_gamepad_end_layout_edit(self.pad, NO); front_ios_focus_event(2); front_ios_focus_event(3);
    [super tearDown]; self.root = nil;
}
- (void)assertPausedWithFocus:(int)focus {
    NSDictionary *state = dm_preview_pause_snapshot();
    XCTAssertEqualObjects(state[@"gfxSuspended"], @YES); XCTAssertEqualObjects(state[@"audioSuspended"], @YES);
    XCTAssertEqualObjects(state[@"clockReason1Frozen"], @YES); XCTAssertEqualObjects(state[@"focusState"], @(focus));
}
- (void)assertResumedWithFocus:(int)focus {
    NSDictionary *state = dm_preview_pause_snapshot();
    XCTAssertEqualObjects(state[@"gfxSuspended"], @NO); XCTAssertEqualObjects(state[@"audioSuspended"], @NO);
    XCTAssertEqualObjects(state[@"clockReason1Frozen"], @NO); XCTAssertEqualObjects(state[@"focusState"], @(focus));
}
- (void)assertNoTransientResume {
    for (NSDictionary *event in dm_preview_pause_snapshot()[@"events"]) {
        NSString *component = event[@"component"];
        if ([component isEqualToString:@"gfx"] || [component isEqualToString:@"audio"] ||
            ([component isEqualToString:@"clock"] && [event[@"reason"] intValue] == 1)) {
            XCTAssertNotEqual([event[@"value"] intValue], 0, @"Transient resume during another pause owner: %@", event);
        }
        if ([component isEqualToString:@"focus"]) XCTAssertNotEqual([event[@"value"] intValue], 1);
    }
}
- (void)testRealLayoutButtonAndToolbarDoNotMovePadAndPauseUntilForegroundSaveOrCancel {
    for (NSString *action in @[@"live.layout.cancel", @"live.layout.save"]) {
        NSDictionary *before = viewGeometry(self.pad); CGRect gameBefore = findLiveClass(self.root.view, @"DmGameView").frame;
        [self sendButton:@"live.layout.open" in:self.root.view]; [self.root.view layoutIfNeeded];
        XCTAssertTrue(dm_gamepad_is_layout_editing(self.pad)); [self assertPausedWithFocus:2];
        XCTAssertEqualObjects(viewGeometry(self.pad), before);
        XCTAssertTrue(CGRectEqualToRect(findLiveClass(self.root.view, @"DmGameView").frame, gameBefore));
        [self sendButton:action in:self.root.view]; XCTAssertFalse(dm_gamepad_is_layout_editing(self.pad));
        [self assertResumedWithFocus:1];
        XCTAssertNil(findLiveIdentifier(self.root.view, @"live.layout.save"));
    }
}
- (void)testBackgroundForegroundWhileEditingNeverPrematurelyResumes {
    [self sendButton:@"live.layout.open" in:self.root.view]; dm_gamepad_update_layout_draft(self.pad, @{@"opacity": @.4});
    dm_preview_reset_pause_history();
    front_ios_focus_event(0); [self assertPausedWithFocus:2];
    front_ios_focus_event(1); [self assertPausedWithFocus:3];
    front_ios_focus_event(2); [self assertPausedWithFocus:2];
    front_ios_focus_event(3); [self assertPausedWithFocus:2];
    XCTAssertTrue(dm_gamepad_is_layout_editing(self.pad)); XCTAssertEqualObjects(dm_gamepad_editor_settings(self.pad)[@"opacity"], @.4);
    [self assertNoTransientResume];
    [self sendButton:@"live.layout.cancel" in:self.root.view]; [self assertResumedWithFocus:1];
}
- (void)testEndingEditInBackgroundWaitsForForegroundBeforeResuming {
    [self sendButton:@"live.layout.open" in:self.root.view];
    front_ios_focus_event(0); front_ios_focus_event(1); dm_preview_reset_pause_history();
    [self sendButton:@"live.layout.save" in:self.root.view];
    XCTAssertFalse(dm_gamepad_is_layout_editing(self.pad)); [self assertPausedWithFocus:3]; [self assertNoTransientResume];
    front_ios_focus_event(2); [self assertResumedWithFocus:2];
    front_ios_focus_event(3); [self assertResumedWithFocus:1];
}
@end
