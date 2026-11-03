// UI-only simulator executable. Every guest/host function below is a test stub.
// This target never loads NSO modules, RomFS, keys, or game code.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import "DmDuoDisplay.h"
#import "DmGamepad.h"
#import "DmTouchConfig.h"
#import "DmControlReflection.h"
#include "front.h"
#include "dm_input.h"
#include <pthread.h>

UIViewController *front_ios_root(void);
void front_ios_focus_event(int event);
uint64_t g_t0_ns;
static pthread_mutex_t inputLock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t buttons;
static int32_t axes[4];
static int touchscreenCount;
static UILabel *readout;
static BOOL started;
static uint64_t inputPublishCount;
static NSArray<GCController *> *testControllers;
static uint64_t inputPathButtons, inputPressLatch, physicalButtons[DM_PLAYERS], physicalPressLatch[DM_PLAYERS];
static uint64_t inputNonzeroPublishes, physicalNonzeroPublishes;
static CMAccelerometerHandler testAccelerometerHandler;
static NSOperationQueue *testAccelerometerQueue;
static BOOL gfxSuspended, audioSuspended;
static uint64_t clockFreezeReasons;
static int focusState;
static NSMutableArray<NSDictionary *> *pauseEvents;

// Capture the production front end's pause calls; these stubs do not suspend
// a real renderer, audio engine, guest clock, or game. History is bounded so the
// GUI preview can remain open without an accumulating diagnostic allocation.
static void recordPauseEvent(NSString *component, int value, int reason) {
    if (!pauseEvents) pauseEvents = [NSMutableArray array];
    [pauseEvents addObject:@{@"component": component, @"value": @(value), @"reason": @(reason)}];
    if (pauseEvents.count > 128) [pauseEvents removeObjectAtIndex:0];
}
NSDictionary *dm_preview_pause_snapshot(void) {
    pthread_mutex_lock(&inputLock);
    NSDictionary *snapshot = @{@"gfxSuspended": @(gfxSuspended), @"audioSuspended": @(audioSuspended),
        @"clockReason1Frozen": @((clockFreezeReasons & (1ull << 1)) != 0), @"focusState": @(focusState),
        @"events": [pauseEvents copy] ?: @[]};
    pthread_mutex_unlock(&inputLock); return snapshot;
}
void dm_preview_reset_pause_history(void) {
    pthread_mutex_lock(&inputLock); [pauseEvents removeAllObjects]; pthread_mutex_unlock(&inputLock);
}
static NSURL *testPreferenceRecoveryURL(void) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:@".preview-test-preferences.plist"];
}
void dm_preview_restore_test_preferences(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"org.nxnative.duo-ui-preview"]) return;
    NSURL *url = testPreferenceRecoveryURL(); NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:url];
    if (!saved) return;
    if ([saved[@"hadDomain"] boolValue]) [NSUserDefaults.standardUserDefaults setPersistentDomain:saved[@"defaults"] forName:NSBundle.mainBundle.bundleIdentifier];
    else [NSUserDefaults.standardUserDefaults removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    dm_touch_set_active_profile(saved[@"active"]);
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}
void dm_preview_save_test_preferences(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"org.nxnative.duo-ui-preview"]) return;
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    [@{@"defaults": saved ?: @{}, @"hadDomain": @(saved != nil), @"active": dm_touch_active_profile()} writeToURL:testPreferenceRecoveryURL() atomically:YES];
}

// Harness-process-only enumeration override. Device Hub exposes virtual MFi
// controllers, which correctly hide the production touch UI. Suppress those
// here without changing production code or disconnecting any real accessory.
static NSArray<GCController *> *previewControllers(id object, SEL selector) {
    (void)object; (void)selector; return testControllers ?: @[];
}
void dm_preview_set_test_controllers(NSArray<GCController *> *controllers) { testControllers = [controllers copy]; }
NSDictionary *dm_preview_input_snapshot(void) {
    pthread_mutex_lock(&inputLock);
    NSDictionary *snapshot = @{@"buttons": @(buttons), @"axes": @[@(axes[0]), @(axes[1]), @(axes[2]), @(axes[3])],
                               @"publishCount": @(inputPublishCount), @"touchscreenTouches": @(touchscreenCount),
                               @"inputNonzeroPublishes": @(inputNonzeroPublishes), @"physicalNonzeroPublishes": @(physicalNonzeroPublishes)};
    pthread_mutex_unlock(&inputLock); return snapshot;
}
// Shadow only hle_hid.c's per-source press-edge latch (buttons & ~old).
// Raw edges include DM_BTN_SHAKE before HID's button mask; no guest HID service
// or clock executes here. Release-to-zero deliberately does not erase an edge.
uint64_t dm_preview_consume_press_latches(void) {
    pthread_mutex_lock(&inputLock); uint64_t value = inputPressLatch; inputPressLatch = 0;
    for (int p = 0; p < DM_PLAYERS; p++) { value |= physicalPressLatch[p]; physicalPressLatch[p] = 0; }
    pthread_mutex_unlock(&inputLock); return value;
}
void dm_preview_clear_input_audit(void) {
    pthread_mutex_lock(&inputLock); inputPressLatch = 0; memset(physicalPressLatch, 0, sizeof physicalPressLatch);
    inputNonzeroPublishes = physicalNonzeroPublishes = 0; pthread_mutex_unlock(&inputLock);
}

@interface PreviewAccelerometerData : CMAccelerometerData
@property(nonatomic) CMAcceleration testAcceleration;
@property(nonatomic) NSTimeInterval testTimestamp;
@end
@implementation PreviewAccelerometerData
- (CMAcceleration)acceleration { return self.testAcceleration; }
- (NSTimeInterval)timestamp { return self.testTimestamp; }
@end
static BOOL previewAccelerometerAvailable(id object, SEL selector) { (void)object; (void)selector; return YES; }
static void previewStartAccelerometer(id object, SEL selector, NSOperationQueue *queue, CMAccelerometerHandler handler) {
    (void)object; (void)selector; testAccelerometerQueue = queue; testAccelerometerHandler = [handler copy];
}
// Invoke the exact production motion_start handler on the queue it supplied.
// No hardware motion manager or private production state is accessed.
BOOL dm_preview_inject_accelerometer(NSTimeInterval timestamp, double x, double y, double z) {
    if (!testAccelerometerQueue || !testAccelerometerHandler) return NO;
    PreviewAccelerometerData *sample = [PreviewAccelerometerData new];
    sample.testTimestamp = timestamp; sample.testAcceleration = (CMAcceleration){x, y, z};
    CMAccelerometerHandler handler = testAccelerometerHandler;
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{ handler(sample, nil); }];
    [testAccelerometerQueue addOperations:@[operation] waitUntilFinished:YES]; return YES;
}

uint64_t now_ns(void) { return (uint64_t)(CACurrentMediaTime() * 1000000000.0); }
int front_ios_boot_ok(void) { return 1; }
const char *front_ios_boot_message(void) { return NULL; }
uint64_t mtl_present_count(void) { return 0; }
void dm_input_set(uint64_t b, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    pthread_mutex_lock(&inputLock);
    inputPressLatch |= b & ~inputPathButtons; inputPathButtons = b;
    if (b || lx || ly || rx || ry) inputNonzeroPublishes++;
    buttons = b;
    axes[0] = lx; axes[1] = ly; axes[2] = rx; axes[3] = ry;
    inputPublishCount++;
    pthread_mutex_unlock(&inputLock);
}
uint64_t dm_input_samples(void) { return 0; }
void dm_touch_set(const dm_touch *touches, int count) { (void)touches; touchscreenCount = count; }
void dm_pad_set_player(int player, uint64_t b, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    if (player < 0 || player >= DM_PLAYERS) return;
    pthread_mutex_lock(&inputLock);
    physicalPressLatch[player] |= b & ~physicalButtons[player]; physicalButtons[player] = b;
    if (b || lx || ly || rx || ry) physicalNonzeroPublishes++;
    if (player == 0) { buttons = b; axes[0] = lx; axes[1] = ly; axes[2] = rx; axes[3] = ry; inputPublishCount++; }
    pthread_mutex_unlock(&inputLock);
}
void dm_pad_set(uint64_t b, int32_t lx, int32_t ly, int32_t rx, int32_t ry) { dm_pad_set_player(0, b, lx, ly, rx, ry); }
uint32_t dm_player_npad(int player) { return player == 0 ? 0x20 : (uint32_t)player; }
void dm_pad_players(uint32_t mask) { (void)mask; }
void dm_motion_set(int p, const float a[3], const float r[3]) { (void)p; (void)a; (void)r; }
void dm_motion_set_switch(int p, const float a[3], const float r[3]) { (void)p; (void)a; (void)r; }
void dm_motion_clear(int p) { (void)p; }
void dm_haptics_apple_init(void) {}
void dm_haptics_apple_controller(int p, GCController *c) { (void)p; (void)c; }
void dm_haptics_apple_shutdown(void) {}
void dm_focus_set(int state) {
    pthread_mutex_lock(&inputLock); focusState = state; recordPauseEvent(@"focus", state, 0); pthread_mutex_unlock(&inputLock);
}
void dm_audio_suspend(int suspend) {
    pthread_mutex_lock(&inputLock); audioSuspended = suspend != 0; recordPauseEvent(@"audio", suspend, 0); pthread_mutex_unlock(&inputLock);
}
void dm_audio_reset(void) {}
// Test-only success: no host save sender, cloud I/O, or network operations.
int save_sync_flush(int timeout_ms) { (void)timeout_ms; return 1; }
void dm_gfx_suspend(int suspend) {
    pthread_mutex_lock(&inputLock); gfxSuspended = suspend != 0; recordPauseEvent(@"gfx", suspend, 0); pthread_mutex_unlock(&inputLock);
}
void guest_clock_freeze_for(int reason, int enabled) {
    pthread_mutex_lock(&inputLock);
    if (reason >= 0 && reason < 64) {
        if (enabled) clockFreezeReasons |= 1ull << reason;
        else clockFreezeReasons &= ~(1ull << reason);
    }
    recordPauseEvent(@"clock", enabled, reason); pthread_mutex_unlock(&inputLock);
}
int dm_opmode(void) { const char *value = getenv("DM_OPMODE"); return value ? atoi(value) : 0; }

void dm_preview_start_metal(UIView *view);
uint64_t dm_preview_metal_frames(void);

static UIView *findNamedView(UIView *view, NSString *name) {
    if ([NSStringFromClass(view.class) isEqualToString:name] || [view.accessibilityIdentifier isEqualToString:name]) return view;
    for (UIView *child in view.subviews) { UIView *found = findNamedView(child, name); if (found) return found; }
    return nil;
}

static UIView *findGameView(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"DmGameView"]) return view;
    for (UIView *child in view.subviews) { UIView *found = findGameView(child); if (found) return found; }
    return nil;
}

static void writeState(void) {
    int32_t a[4]; uint64_t b;
    pthread_mutex_lock(&inputLock); memcpy(a, axes, sizeof(a)); b = buttons; pthread_mutex_unlock(&inputLock);
    NSMutableDictionary *state = [dm_duo_current_layout_snapshot() mutableCopy];
    state[@"testOnly"] = @YES; state[@"gameCodeExecuted"] = @NO;
    state[@"simulationPhysicalControllersSuppressed"] = @YES;
    state[@"simulationAccelerometerStubbed"] = @YES;
    state[@"gameStarted"] = @(started);
    state[@"pauseState"] = dm_preview_pause_snapshot();
    state[@"buttons"] = @(b); state[@"axes"] = @[@(a[0]), @(a[1]), @(a[2]), @(a[3])];
    state[@"touchscreenTouches"] = @(touchscreenCount);
    state[@"settings"] = dm_touch_profile_settings(dm_touch_active_profile());
    state[@"displayMode"] = [NSUserDefaults.standardUserDefaults stringForKey:@"DmTouchDisplayMode"] ?: @"automatic";
    UIView *game = readout.superview;
    if (game) {
        UIView *root = game.window.rootViewController.view ?: game.superview;
        CGRect frame = [game convertRect:game.bounds toView:root];
        state[@"metalPreviewFrames"] = @(dm_preview_metal_frames());
        state[@"reflectionActive"] = @(findNamedView(root, @"control.reflection.mirror") != nil);
        id reflection = [game.window.rootViewController valueForKey:@"controlReflection"];
        if (reflection) state[@"reflectionParameters"] = [reflection debugSnapshot];
        state[@"actualGameFrame"] = @[@(frame.origin.x), @(frame.origin.y), @(frame.size.width), @(frame.size.height)];
        CAMetalLayer *layer = (CAMetalLayer *)game.layer;
        state[@"drawableSize"] = @[@(layer.drawableSize.width), @(layer.drawableSize.height)];
        state[@"displayScale"] = @(layer.contentsScale);
        UIView *sibling = findNamedView(root, @"DmGamepad");
        if (sibling) {
            CGRect pad = [sibling convertRect:sibling.bounds toView:root];
            state[@"actualPadFrame"] = @[@(pad.origin.x), @(pad.origin.y), @(pad.size.width), @(pad.size.height)];
            state[@"layoutEditing"] = @(dm_gamepad_is_layout_editing(sibling));
            if (dm_gamepad_is_layout_editing(sibling)) {
                state[@"layoutEditProfile"] = dm_gamepad_layout_edit_profile(sibling) ?: @"";
                state[@"layoutDraft"] = dm_gamepad_editor_settings(sibling);
            }
        }
    }
    readout.text = [NSString stringWithFormat:@"触控测试画面（不运行游戏）\n\n当前：%@ · %@\n左摇杆：%d, %d\n右摇杆：%d, %d\n按键位图：0x%llx",
        state[@"profile"], state[@"axis"], a[0], a[1], a[2], a[3], (unsigned long long)b];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToURL:[documents URLByAppendingPathComponent:@"ui-state.json"] atomically:YES];
}

void front_ios_boot(void) {
    started = YES;
    UIView *game = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            game = findGameView(window.rootViewController.view); if (game) break;
        }
        if (game) break;
    }
    // This label is inside the production Metal view, so its rectangle comes
    // from production front_ios.m rather than a parallel mock layout.
    readout = [[UILabel alloc] initWithFrame:game.bounds];
    readout.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    readout.numberOfLines = 0; readout.textAlignment = NSTextAlignmentCenter;
    readout.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightMedium];
    readout.adjustsFontSizeToFitWidth = YES; readout.minimumScaleFactor = 0.5;
    readout.textColor = UIColor.whiteColor;
    readout.backgroundColor = UIColor.clearColor;
    readout.layer.shadowColor = UIColor.blackColor.CGColor;
    readout.layer.shadowOpacity = 1; readout.layer.shadowRadius = 3;
    readout.userInteractionEnabled = NO;
    readout.accessibilityIdentifier = @"preview.gameReadout";
    [game addSubview:readout];
    if (game) dm_preview_start_metal(game);
    writeState();
}

@interface PreviewSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation PreviewSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    g_t0_ns = now_ns(); setenv("DM_MOTION", "0", 1); setenv("DM_PHONE_MOTION", "0", 1);
    // An explicit launch override skips resolving any saved cloud-folder bookmark.
    setenv("DM_SAVE_SYNC", "", 1);
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = front_ios_root(); [self.window makeKeyAndVisible];
    [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) { (void)timer; writeState(); }];
}
- (void)sceneWillResignActive:(UIScene *)scene { (void)scene; front_ios_focus_event(0); }
- (void)sceneDidEnterBackground:(UIScene *)scene { (void)scene; front_ios_focus_event(1); }
- (void)sceneWillEnterForeground:(UIScene *)scene { (void)scene; front_ios_focus_event(2); }
- (void)sceneDidBecomeActive:(UIScene *)scene { (void)scene; front_ios_focus_event(3); }
@end

@interface PreviewAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation PreviewAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)app; (void)options;
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Preview" sessionRole:session.role];
    config.delegateClass = PreviewSceneDelegate.class; return config;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        // Recover only this preview's preferences if a previous unit-test host
        // was interrupted before XCTest could run tearDown.
        dm_preview_restore_test_preferences();
        method_setImplementation(class_getClassMethod(GCController.class, @selector(controllers)), (IMP)previewControllers);
        method_setImplementation(class_getInstanceMethod(CMMotionManager.class, @selector(isAccelerometerAvailable)), (IMP)previewAccelerometerAvailable);
        method_setImplementation(class_getInstanceMethod(CMMotionManager.class, @selector(startAccelerometerUpdatesToQueue:withHandler:)), (IMP)previewStartAccelerometer);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(PreviewAppDelegate.class));
    }
}
