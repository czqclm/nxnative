// Regression for an input edge being latched while the game is paused for a
// live layout edit. These unit tests call the production-installed controller
// handler and captured CoreMotion callback; they do not claim hardware delivery.
#import <XCTest/XCTest.h>
#import <GameController/GameController.h>
#import "DmGamepad.h"
#import "DmTouchConfig.h"
#include "dm_input.h"

NSDictionary *dm_preview_input_snapshot(void);
void dm_preview_set_test_controllers(NSArray<GCController *> *controllers);
uint64_t dm_preview_consume_press_latches(void);
void dm_preview_clear_input_audit(void);
void dm_preview_save_test_preferences(void);
void dm_preview_restore_test_preferences(void);
BOOL dm_preview_inject_accelerometer(NSTimeInterval timestamp, double x, double y, double z);

@interface PhysicalInputEditingTests : XCTestCase
@property(nonatomic, strong) UIView *container;
@property(nonatomic, strong) UIView *pad;
@property(nonatomic, strong) GCController *controller;
@end

@implementation PhysicalInputEditingTests
- (void)recordIssue:(XCTIssue *)issue {
    // Preserve the issue while avoiding this simulator's blocking stack lookup.
    fprintf(stderr, "PREVIEW_TEST_ISSUE: %s\n", issue.compactDescription.UTF8String);
    XCTMutableIssue *recorded = [issue mutableCopy];
    recorded.sourceCodeContext = [[XCTSourceCodeContext alloc] initWithCallStack:@[] location:issue.sourceCodeContext.location];
    [super recordIssue:recorded];
}
- (void)setUp {
    [super setUp]; XCTAssertTrue(NSThread.isMainThread);
    XCTAssertEqualObjects(NSBundle.mainBundle.bundleIdentifier, @"org.nxnative.duo-ui-preview");
    dm_preview_save_test_preferences();
    [NSUserDefaults.standardUserDefaults setObject:@"outer" forKey:@"DmTouchDisplayMode"];
    dm_touch_set_active_profile(@"outer"); dm_touch_save_layout_style(@"outer", 1);
    dm_preview_set_test_controllers(@[]);
    self.container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 932, 430)];
    self.pad = dm_gamepad_view(self.container.bounds); [self.container addSubview:self.pad];
    [self.pad setNeedsLayout]; [self.pad layoutIfNeeded]; [self drainControllerQueue];
    self.controller = [GCController controllerWithExtendedGamepad];
    [self connectControllers:@[self.controller] notification:GCControllerDidConnectNotification controller:self.controller];
    dm_preview_clear_input_audit();
}
- (void)tearDown {
    if (self.controller.extendedGamepad.valueChangedHandler) [self sendButton:0 stickX:0 controller:self.controller];
    dm_gamepad_end_layout_edit(self.pad, NO);
    [self connectControllers:@[] notification:GCControllerDidDisconnectNotification controller:self.controller];
    dm_gamepad_reset(); [self drainControllerQueue]; dm_preview_clear_input_audit();
    [self.pad removeFromSuperview]; self.pad = nil; self.container = nil; self.controller = nil;
    dm_preview_restore_test_preferences(); [super tearDown];
}
- (void)drainControllerQueue { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]]; }
- (void)connectControllers:(NSArray<GCController *> *)controllers notification:(NSNotificationName)name controller:(GCController *)controller {
    dm_preview_set_test_controllers(controllers);
    [NSNotificationCenter.defaultCenter postNotificationName:name object:controller]; [self drainControllerQueue];
}
- (void)sendButton:(float)value stickX:(float)x controller:(GCController *)controller {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    XCTAssertNotNil(gamepad.valueChangedHandler, @"Production pad did not install its controller callback");
    [gamepad.buttonA setValue:value]; [gamepad.leftThumbstick setValueForXAxis:x yAxis:0];
    // setValue configures the synthetic input. Explicit invocation makes the
    // callback path deterministic without pretending a hardware event arrived.
    if (gamepad.valueChangedHandler) gamepad.valueChangedHandler(gamepad, gamepad.buttonA);
}
- (void)assertNoNonzeroPublication {
    NSDictionary *snapshot = dm_preview_input_snapshot();
    XCTAssertEqual([snapshot[@"inputNonzeroPublishes"] unsignedLongLongValue], 0ull);
    XCTAssertEqual([snapshot[@"physicalNonzeroPublishes"] unsignedLongLongValue], 0ull);
}
- (void)testPhysicalControllerPressReleaseDuringLiveEditDoesNotLatchOrReplay {
    // Positive control: a complete press/release still reaches the next guest
    // sample through the shadow latch even though the current value is zero.
    [self sendButton:1 stickX:1 controller:self.controller]; [self sendButton:0 stickX:0 controller:self.controller];
    XCTAssertNotEqual(dm_preview_consume_press_latches(), 0ull);
    XCTAssertGreaterThan([dm_preview_input_snapshot()[@"physicalNonzeroPublishes"] unsignedLongLongValue], 0ull);

    XCTAssertTrue(dm_gamepad_begin_layout_edit(self.pad)); dm_preview_clear_input_audit();
    [self sendButton:1 stickX:1 controller:self.controller]; [self sendButton:0 stickX:0 controller:self.controller];
    [self assertNoNonzeroPublication];
    XCTAssertTrue(dm_gamepad_end_layout_edit(self.pad, NO)); [self drainControllerQueue];
    XCTAssertEqual(dm_preview_consume_press_latches(), 0ull, @"A press made only while editing leaked into the first resumed sample");
    [self assertNoNonzeroPublication];
    [self sendButton:1 stickX:1 controller:self.controller]; [self sendButton:0 stickX:0 controller:self.controller];
    XCTAssertNotEqual(dm_preview_consume_press_latches(), 0ull, @"Normal controller input must resume on a new callback");
}
- (void)testReconnectAndSecondPlayerCannotLatchInputOrReplayHeldButtonsOnExit {
    XCTAssertTrue(dm_gamepad_begin_layout_edit(self.pad)); dm_preview_clear_input_audit();
    GCController *second = [GCController controllerWithExtendedGamepad];
    [self connectControllers:@[self.controller, second] notification:GCControllerDidConnectNotification controller:second];
    [self sendButton:1 stickX:.8 controller:self.controller]; [self sendButton:1 stickX:-.8 controller:second];
    [self connectControllers:@[second] notification:GCControllerDidDisconnectNotification controller:self.controller];
    [self connectControllers:@[second, self.controller] notification:GCControllerDidConnectNotification controller:self.controller];
    [self sendButton:1 stickX:1 controller:self.controller];
    [self assertNoNonzeroPublication];
    // The held physical states deliberately stay nonzero across this boundary;
    // ending editing must not poll and replay them into the paused HID latch.
    XCTAssertTrue(dm_gamepad_end_layout_edit(self.pad, YES)); [self drainControllerQueue];
    [self assertNoNonzeroPublication]; XCTAssertEqual(dm_preview_consume_press_latches(), 0ull);
    [self sendButton:0 stickX:0 controller:self.controller]; [self sendButton:0 stickX:0 controller:second];
    [self sendButton:1 stickX:0 controller:second]; [self sendButton:0 stickX:0 controller:second];
    XCTAssertNotEqual(dm_preview_consume_press_latches(), 0ull);
    [self connectControllers:@[self.controller] notification:GCControllerDidDisconnectNotification controller:second];
}
- (void)testPhoneShakeDuringLiveEditCannotPublishOrReplayOldPulse {
    static NSTimeInterval timestamp = 1000; timestamp += 10;
    XCTAssertTrue(dm_preview_inject_accelerometer(timestamp, 0, 0, 0));
    XCTAssertTrue(dm_preview_inject_accelerometer(timestamp + .01, 4, 0, 0));
    XCTAssertNotEqual(dm_preview_consume_press_latches() & DM_BTN_SHAKE, 0ull,
        @"Positive control must exercise the real production shake callback");
    XCTAssertTrue(dm_preview_inject_accelerometer(timestamp + 1, 0, 0, 0)); dm_preview_clear_input_audit();

    XCTAssertTrue(dm_gamepad_begin_layout_edit(self.pad)); dm_preview_clear_input_audit();
    XCTAssertTrue(dm_preview_inject_accelerometer(timestamp + 1.01, 0, 0, 0));
    XCTAssertTrue(dm_preview_inject_accelerometer(timestamp + 1.02, 4, 0, 0));
    XCTAssertTrue(dm_preview_inject_accelerometer(timestamp + 1.03, 0, 0, 0));
    [self assertNoNonzeroPublication];
    XCTAssertTrue(dm_gamepad_end_layout_edit(self.pad, NO));
    XCTAssertEqual(dm_preview_consume_press_latches(), 0ull);
    // Still within the original shake's 120 ms tail. A new neutral sample must
    // not revive that gesture after editing is over.
    XCTAssertTrue(dm_preview_inject_accelerometer(timestamp + 1.04, 0, 0, 0));
    [self assertNoNonzeroPublication]; XCTAssertEqual(dm_preview_consume_press_latches(), 0ull);
    XCTAssertTrue(dm_preview_inject_accelerometer(timestamp + 1.05, 4, 0, 0));
    XCTAssertNotEqual(dm_preview_consume_press_latches() & DM_BTN_SHAKE, 0ull,
        @"A fresh post-editor shake must still work");
    XCTAssertTrue(dm_preview_inject_accelerometer(timestamp + 2, 0, 0, 0));
}
@end
