// Calls the production UIKit responder and editor actions using test touches.
// These are unit tests, not evidence of Device Hub pointer forwarding or hardware.
#import <XCTest/XCTest.h>
#import <GameController/GameController.h>
#import "DmGamepad.h"
#import "DmTouchConfig.h"

NSDictionary *dm_preview_input_snapshot(void);
void dm_preview_set_test_controllers(NSArray<GCController *> *controllers);

@interface UIView (TouchGeometryTests)
- (CGRect)controlRect:(NSString *)identifier;
@end

@interface PreviewTouch : UITouch
@property(nonatomic, strong) UIView *coordinateView;
@property(nonatomic) CGPoint point;
@property(nonatomic) UITouchPhase testPhase;
@end
@implementation PreviewTouch
- (CGPoint)locationInView:(UIView *)view { return view == self.coordinateView ? self.point : [self.coordinateView convertPoint:self.point toView:view]; }
- (CGPoint)previousLocationInView:(UIView *)view { return [self locationInView:view]; }
- (UITouchPhase)phase { return self.testPhase; }
@end

static CGPoint rectCenter(CGRect rect) { return CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)); }
static UIView *findIdentifier(UIView *view, NSString *identifier) {
    if ([view.accessibilityIdentifier isEqualToString:identifier]) return view;
    for (UIView *child in view.subviews) { UIView *found = findIdentifier(child, identifier); if (found) return found; }
    return nil;
}
static UINavigationBar *findBar(UIView *view) {
    if ([view isKindOfClass:UINavigationBar.class]) return (UINavigationBar *)view;
    for (UIView *child in view.subviews) { UINavigationBar *bar = findBar(child); if (bar) return bar; }
    return nil;
}

@interface TouchTests : XCTestCase
@property(nonatomic, copy) NSDictionary *savedDefaults;
@property(nonatomic, copy) NSString *savedActive;
@property(nonatomic, copy) NSString *defaultsDomain;
@property(nonatomic, strong) UIView *container;
@property(nonatomic, strong) UIView *runtimePad;
@end

@implementation TouchTests
- (void)setUp {
    [super setUp];
    XCTAssertTrue(NSThread.isMainThread);
    self.defaultsDomain = NSBundle.mainBundle.bundleIdentifier;
    XCTAssertEqualObjects(self.defaultsDomain, @"org.nxnative.duo-ui-preview");
    self.savedDefaults = [NSUserDefaults.standardUserDefaults persistentDomainForName:self.defaultsDomain];
    self.savedActive = dm_touch_active_profile();
    // The preview app alone is affected, and its exact raw domain is restored.
    [NSUserDefaults.standardUserDefaults setObject:@"outer" forKey:@"DmTouchDisplayMode"];
    dm_preview_set_test_controllers(@[]);
    dm_touch_set_active_profile(@"outer");
    for (NSString *profile in @[@"outer", @"inner", @"folded"]) {
        dm_touch_save_profile(profile, dm_touch_default_profile_settings());
        dm_touch_save_layout_style(profile, 1);
    }
}
- (void)tearDown {
    if (self.runtimePad) dm_gamepad_release_touches(self.runtimePad);
    dm_preview_set_test_controllers(@[]);
    if (self.savedDefaults) [NSUserDefaults.standardUserDefaults setPersistentDomain:self.savedDefaults forName:self.defaultsDomain];
    else [NSUserDefaults.standardUserDefaults removePersistentDomainForName:self.defaultsDomain];
    dm_touch_set_active_profile(self.savedActive);
    [self.runtimePad removeFromSuperview]; self.runtimePad = nil; self.container = nil;
    [super tearDown];
}
- (PreviewTouch *)touchIn:(UIView *)view point:(CGPoint)point {
    PreviewTouch *touch = [PreviewTouch new]; touch.coordinateView = view; touch.point = point; touch.testPhase = UITouchPhaseBegan; return touch;
}
- (UIView *)makeRuntimePad {
    self.container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 932, 430)];
    self.runtimePad = dm_gamepad_view(self.container.bounds);
    [self.container addSubview:self.runtimePad];
    dm_gamepad_set_game_rect(self.runtimePad, CGRectMake(84, 0, 764, 430));
    [self.runtimePad setNeedsLayout]; [self.runtimePad layoutIfNeeded];
    // Drain the production pad's asynchronous initial controller-enumeration reset.
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    dm_touch_set_active_profile(@"outer");
    return self.runtimePad;
}
- (NSArray *)axes { return dm_preview_input_snapshot()[@"axes"]; }
- (void)testRuntimeBothSticksMoveIndependentlyAndReleaseToZero {
    UIView *pad = [self makeRuntimePad];
    CGRect left = [pad controlRect:@"LEFT_STICK"], right = [pad controlRect:@"RIGHT_STICK"];
    PreviewTouch *l = [self touchIn:pad point:rectCenter(left)], *r = [self touchIn:pad point:rectCenter(right)];
    [pad touchesBegan:[NSSet setWithObjects:l, r, nil] withEvent:nil];
    l.point = CGPointMake(CGRectGetMaxX(left), CGRectGetMidY(left));
    r.point = CGPointMake(CGRectGetMidX(right), CGRectGetMinY(right));
    [pad touchesMoved:[NSSet setWithObjects:l, r, nil] withEvent:nil];
    XCTAssertEqualObjects(self.axes, (@[@32767, @0, @0, @32767]));
    [pad touchesEnded:[NSSet setWithObject:l] withEvent:nil];
    XCTAssertEqualObjects(self.axes, (@[@0, @0, @0, @32767]));
    [pad touchesEnded:[NSSet setWithObject:r] withEvent:nil];
    XCTAssertEqualObjects(self.axes, (@[@0, @0, @0, @0]));
}
- (void)testRuntimeButtonUsesEditedPositionAndCancelReleases {
    dm_touch_save_profile(@"outer", @{@"controls": @{@"A": @{@"x": @0.5, @"y": @0.55, @"scale": @1.6}}});
    UIView *pad = [self makeRuntimePad];
    CGRect a = [pad controlRect:@"A"];
    XCTAssertEqualWithAccuracy(CGRectGetMidX(a) / pad.bounds.size.width, .5, .001);
    PreviewTouch *touch = [self touchIn:pad point:rectCenter(a)];
    [pad touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
    XCTAssertEqual([dm_preview_input_snapshot()[@"buttons"] unsignedLongLongValue] & 1, 1);
    [pad touchesCancelled:[NSSet setWithObject:touch] withEvent:nil];
    XCTAssertEqual([dm_preview_input_snapshot()[@"buttons"] unsignedLongLongValue], 0);
}
- (void)testRuntimeIndependentSensitivityAndDeadZone {
    dm_touch_save_profile(@"outer", @{@"leftSensitivity": @0.25, @"rightSensitivity": @2.5, @"leftDeadZone": @0.2, @"rightDeadZone": @0});
    UIView *pad = [self makeRuntimePad];
    CGRect left = [pad controlRect:@"LEFT_STICK"], right = [pad controlRect:@"RIGHT_STICK"];
    PreviewTouch *l = [self touchIn:pad point:rectCenter(left)], *r = [self touchIn:pad point:rectCenter(right)];
    [pad touchesBegan:[NSSet setWithObjects:l, r, nil] withEvent:nil];
    l.point = CGPointMake(CGRectGetMidX(left) + left.size.width * .05, CGRectGetMidY(left));
    r.point = CGPointMake(CGRectGetMidX(right) + right.size.width * .05, CGRectGetMidY(right));
    [pad touchesMoved:[NSSet setWithObjects:l, r, nil] withEvent:nil];
    XCTAssertEqual([self.axes[0] intValue], 0); XCTAssertGreaterThan([self.axes[2] intValue], 0);
    l.point = CGPointMake(CGRectGetMidX(left) + left.size.width * .2, CGRectGetMidY(left));
    r.point = CGPointMake(CGRectGetMidX(right) + right.size.width * .2, CGRectGetMidY(right));
    [pad touchesMoved:[NSSet setWithObjects:l, r, nil] withEvent:nil];
    XCTAssertGreaterThan([self.axes[0] intValue], 0);
    XCTAssertGreaterThan([self.axes[2] intValue], [self.axes[0] intValue]);
    [pad touchesEnded:[NSSet setWithObjects:l, r, nil] withEvent:nil];
}
- (void)testRuntimeGeometryAndProfileChangesReleaseHeldTouches {
    UIView *pad = [self makeRuntimePad];
    CGRect left = [pad controlRect:@"LEFT_STICK"];
    PreviewTouch *touch = [self touchIn:pad point:rectCenter(left)];
    [pad touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
    touch.point = CGPointMake(CGRectGetMaxX(left), CGRectGetMidY(left));
    [pad touchesMoved:[NSSet setWithObject:touch] withEvent:nil];
    XCTAssertGreaterThan([self.axes[0] intValue], 0);
    dm_gamepad_set_game_rect(pad, CGRectMake(84, 10, 764, 400));
    XCTAssertEqualObjects(self.axes, (@[@0, @0, @0, @0]));
    touch.point = rectCenter(left); [pad touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
    touch.point = CGPointMake(CGRectGetMaxX(left), CGRectGetMidY(left));
    [pad touchesMoved:[NSSet setWithObject:touch] withEvent:nil];
    dm_touch_set_active_profile(@"inner");
    XCTAssertEqualObjects(self.axes, (@[@0, @0, @0, @0]));
    XCTAssertEqual([dm_preview_input_snapshot()[@"buttons"] unsignedLongLongValue], 0);
}
- (void)dragControl:(NSString *)control inPreview:(UIView *)preview {
    CGRect original = [preview controlRect:control];
    PreviewTouch *touch = [self touchIn:preview point:rectCenter(original)];
    [preview touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
    touch.point = CGPointMake(preview.bounds.size.width * .44, preview.bounds.size.height * .47);
    touch.testPhase = UITouchPhaseMoved;
    [preview touchesMoved:[NSSet setWithObject:touch] withEvent:nil];
    touch.testPhase = UITouchPhaseEnded; [preview touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
}
- (void)testEditorResponderDragAndScaleAreIsolatedUntilSave {
    NSDictionary *before = dm_touch_profile_settings(@"inner");
    NSNumber *publishCount = dm_preview_input_snapshot()[@"publishCount"];
    UIView *preview = dm_gamepad_editor_preview(@"inner", before);
    preview.frame = CGRectMake(0, 0, 800, 900); [preview layoutIfNeeded];
    [self dragControl:@"LEFT_STICK" inPreview:preview];
    NSDictionary *control = dm_gamepad_editor_settings(preview)[@"controls"][@"LEFT_STICK"];
    XCTAssertEqualWithAccuracy([control[@"x"] doubleValue], .44, .001);
    XCTAssertEqualWithAccuracy([control[@"y"] doubleValue], .47, .001);
    dm_gamepad_editor_set_scale(preview, 1.7);
    XCTAssertEqualWithAccuracy([dm_gamepad_editor_settings(preview)[@"controls"][@"LEFT_STICK"][@"scale"] doubleValue], 1.7, .001);
    XCTAssertEqualObjects(dm_touch_profile_settings(@"inner"), before);
    XCTAssertEqualObjects(dm_preview_input_snapshot()[@"publishCount"], publishCount);
}
- (UIViewController *)makeEditor:(NSString *)profile {
    UIViewController *editor = dm_touch_editor_controller(profile); [editor loadViewIfNeeded];
    editor.view.frame = CGRectMake(0, 0, 800, 1000); [editor.view setNeedsLayout]; [editor.view layoutIfNeeded];
    return editor;
}
- (void)sendEditorAction:(NSString *)identifier controller:(UIViewController *)editor {
    UINavigationBar *bar = findBar(editor.view); XCTAssertNotNil(bar);
    NSMutableArray *items = [NSMutableArray arrayWithArray:bar.topItem.leftBarButtonItems ?: @[]];
    [items addObjectsFromArray:bar.topItem.rightBarButtonItems ?: @[]];
    for (UIBarButtonItem *item in items) if ([item.accessibilityIdentifier isEqualToString:identifier]) {
        XCTAssertTrue([UIApplication.sharedApplication sendAction:item.action to:item.target from:item forEvent:nil]); return;
    }
    XCTFail(@"No editor action %@", identifier);
}
- (void)testControllerCancelDiscardsDraftAndSavePersistsOnlySelectedProfile {
    NSDictionary *before = dm_touch_profile_settings(@"folded"), *other = dm_touch_profile_settings(@"inner");
    UIViewController *cancelled = [self makeEditor:@"folded"];
    UIView *draft = findIdentifier(cancelled.view, @"touch.editor.preview"); XCTAssertNotNil(draft);
    [draft layoutIfNeeded]; [self dragControl:@"A" inPreview:draft];
    [self sendEditorAction:@"touch.editor.cancel" controller:cancelled];
    XCTAssertEqualObjects(dm_touch_profile_settings(@"folded"), before);
    UIViewController *saved = [self makeEditor:@"folded"];
    draft = findIdentifier(saved.view, @"touch.editor.preview"); [draft layoutIfNeeded];
    [self dragControl:@"A" inPreview:draft];
    UISlider *slider = (UISlider *)findIdentifier(saved.view, @"touch.editor.scale");
    XCTAssertNotNil(slider); slider.value = 1.6; [slider sendActionsForControlEvents:UIControlEventValueChanged];
    NSDictionary *expected = dm_gamepad_editor_settings(draft);
    [self sendEditorAction:@"touch.editor.save" controller:saved];
    XCTAssertEqualObjects(dm_touch_profile_settings(@"folded"), expected);
    XCTAssertEqualObjects(dm_touch_profile_settings(@"inner"), other);
    XCTAssertNotEqualObjects(dm_touch_profile_settings(@"folded"), before);
}
- (void)testRuntimeMockControllerHidesAndRestoresControls {
    UIView *pad = [self makeRuntimePad]; CALayer *controls = pad.layer.sublayers.firstObject;
    XCTAssertFalse(controls.hidden);
    GCController *controller = [GCController controllerWithExtendedGamepad];
    dm_preview_set_test_controllers(@[controller]);
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:controller];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    XCTAssertTrue(controls.hidden);
    dm_preview_set_test_controllers(@[]);
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidDisconnectNotification object:controller];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    XCTAssertFalse(controls.hidden);
}
- (void)testDefaultClustersRetainSpacingAtLargeSideSafeInsets {
    NSArray<NSDictionary *> *cases = @[
        @{@"name": @"Duo outer right inset", @"size": [NSValue valueWithCGSize:CGSizeMake(466, 678)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 0, 0, 84)]},
        @{@"name": @"Duo outer left inset", @"size": [NSValue valueWithCGSize:CGSizeMake(466, 678)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 84, 0, 0)]},
        @{@"name": @"Duo landscape right inset", @"size": [NSValue valueWithCGSize:CGSizeMake(678, 466)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 0, 21, 84)]},
        @{@"name": @"Duo landscape left inset", @"size": [NSValue valueWithCGSize:CGSizeMake(678, 466)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 84, 21, 0)]},
        @{@"name": @"Narrow right panel", @"size": [NSValue valueWithCGSize:CGSizeMake(300, 608)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 0, 21, 84)]},
        @{@"name": @"Narrow left panel", @"size": [NSValue valueWithCGSize:CGSizeMake(300, 608)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 84, 21, 0)]},
        @{@"name": @"Lower panel", @"size": [NSValue valueWithCGSize:CGSizeMake(608, 304)], @"insets": [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 0, 21, 84)]},
    ];
    NSArray<NSString *> *cluster = @[@"A", @"B", @"X", @"Y", @"LEFT_STICK", @"RIGHT_STICK", @"DPAD"];
    NSNumber *published = dm_preview_input_snapshot()[@"publishCount"];
    for (NSDictionary *example in cases) {
        UIView *preview = dm_gamepad_editor_preview(@"folded", dm_touch_default_profile_settings());
        CGSize size = [example[@"size"] CGSizeValue]; UIEdgeInsets insets = [example[@"insets"] UIEdgeInsetsValue];
        preview.frame = (CGRect){CGPointZero, size}; dm_gamepad_editor_set_safe_insets(preview, insets);
        [preview setNeedsLayout]; [preview layoutIfNeeded];
        CGRect safe = UIEdgeInsetsInsetRect(preview.bounds, insets);
        for (NSUInteger i = 0; i < cluster.count; i++) {
            CGRect a = [preview controlRect:cluster[i]];
            XCTAssertTrue(CGRectContainsRect(safe, a), @"%@ %@ outside safe bounds", example[@"name"], cluster[i]);
            for (NSUInteger j = i + 1; j < cluster.count; j++) {
                CGRect b = [preview controlRect:cluster[j]];
                CGFloat distance = hypot(CGRectGetMidX(a) - CGRectGetMidX(b), CGRectGetMidY(a) - CGRectGetMidY(b));
                XCTAssertGreaterThanOrEqual(distance + .001, (a.size.width + b.size.width) / 2,
                    @"%@ overlapping %@ / %@", example[@"name"], cluster[i], cluster[j]);
            }
        }
    }
    XCTAssertEqualObjects(dm_preview_input_snapshot()[@"publishCount"], published);
}
- (void)testCustomCoordinatesStillUseWholePadBoundsWithSideInsets {
    NSDictionary *settings = @{@"controls": @{@"A": @{@"x": @.5, @"y": @.4, @"scale": @1}}};
    NSMutableDictionary *draft = [dm_touch_default_profile_settings() mutableCopy]; [draft addEntriesFromDictionary:settings];
    UIView *preview = dm_gamepad_editor_preview(@"outer", draft);
    preview.frame = CGRectMake(0, 0, 466, 678);
    dm_gamepad_editor_set_safe_insets(preview, UIEdgeInsetsMake(0, 0, 0, 84));
    [preview setNeedsLayout]; [preview layoutIfNeeded];
    CGRect button = [preview controlRect:@"A"];
    XCTAssertEqualWithAccuracy(CGRectGetMidX(button), 466 * .5, .001);
    XCTAssertEqualWithAccuracy(CGRectGetMidY(button), 678 * .4, .001);
    XCTAssertEqualObjects(dm_gamepad_editor_settings(preview)[@"controls"], settings[@"controls"]);
}
@end
