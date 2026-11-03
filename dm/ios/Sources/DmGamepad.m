// Virtual gamepad and physical controllers, publishing through dm_input_set / dm_pad_set_player.
// Stored keys stay compatible: outer, inner (inner landscape), folded (inner portrait).
// They keep positions, scales and stick curves. Inner portrait uses full 3D controls;
// the other profiles retain their own 2D/3D/Tap choices.
// Both sticks are visible fixed-center controls. Touch ownership stays with a control until release.
// Live layout drafts reuse this exact view without changing its coordinate system or publishing touch input.
// Isolated test previews additionally skip all sensor and controller initialization.
// Unclaimed touches map only inside the real picture rectangle supplied by front_ios.m.
// Physical controllers, multiplayer slots, haptics and motion retain their existing behavior below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#import "DmGamepad.h"
#import "DmTouchConfig.h"
#include <pthread.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_slots.h"
#include <stdatomic.h>

NSNotificationName const DmGamepadLayoutEditingDidChangeNotification = @"DmGamepadLayoutEditingDidChangeNotification";

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME };   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic BOOL g_input_suppressed;
static _Atomic uint64_t g_input_generation;
static uint64_t g_touch_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
static void publish(void) {   // the touch gamepad and the shake; the host ORs them with player 1's controller and takes whichever stick is deflected more (hle_hid.c)
    pthread_mutex_lock(&g_mu);
    if (!atomic_load(&g_input_suppressed)) dm_input_set(g_touch_btn | g_shake_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}
// Serialize both boundaries with every nonzero publisher. A callback begun before
// a boundary cannot publish a stale sample after it, even if editing already ended.
// Neutral releases do not erase host press edges from before editing; only new
// editing-time events are suppressed. Held controllers resume on a later callback.
static void input_editing_set(BOOL editing) {
    pthread_mutex_lock(&g_mu);
    g_touch_btn = g_shake_btn = 0;
    g_touch_lx = g_touch_ly = g_touch_rx = g_touch_ry = 0;
    dm_input_set(0, 0, 0, 0, 0);
    for (int p = 0; p < DM_PLAYERS; p++) dm_pad_set_player(p, 0, 0, 0, 0, 0);
    atomic_fetch_add(&g_input_generation, 1);
    atomic_store(&g_input_suppressed, editing);
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    __block uint64_t seenGeneration = atomic_load(&g_input_generation);
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        uint64_t generation = atomic_load(&g_input_generation);
        BOOL suppressed = atomic_load(&g_input_suppressed);
        if (generation != seenGeneration || suppressed) {
            seenGeneration = generation; init = NO; last = -1; peak = 0;
        }
        if (suppressed) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu);
        if (!atomic_load(&g_input_suppressed) && generation == atomic_load(&g_input_generation)) {
            BOOL changed = g_shake_btn != want; g_shake_btn = want;
            if (changed) dm_input_set(g_touch_btn | g_shake_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
        }
        pthread_mutex_unlock(&g_mu);
    }];
}

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: on iOS 27 and later the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody), so Core Motion delivers
// them in that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Before that they come in the hardware frame, turned here by the interface orientation, which holds only where the hardware frame is the screen's portrait frame: not on iPhone
// Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen (Split View on the
// inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static BOOL g_motion_body;                  // samples in the body's frame (iOS 27+)
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    if (@available(iOS 27.0, *)) { g_motion.deviceMotionBody = body; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)"); }
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z}, as[3], ws[3];
        int o = g_motion_body ? 1 : atomic_load(&g_iface_orient);   // the body's frame is already the picture's: the portrait map, which leaves it as it is
        motion_phone_to_switch(o, a, as); motion_phone_to_switch(o, w, ws);
        dm_motion_set_switch(0, as, ws);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_SWAP_R = 15,                                  // layout button: top centre, level with − / +
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static NSString *const k_control_names[] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"PLUS", @"MINUS"};
int dm_opmode(void);   // hle_oe.c: 0 = handheld

@interface DmGamepad : UIView
- (instancetype)initWithFrame:(CGRect)frame editingProfile:(NSString *)profile settings:(NSDictionary *)settings;
- (void)setGameRectInParent:(CGRect)rect;
- (void)reset;
- (NSDictionary *)editingSettings;
- (NSString *)editingSelection;
- (void)selectEditingControl:(NSString *)control;
- (void)setEditingScale:(CGFloat)scale;
- (void)resetEditingLayout;
- (void)setEditingSelectionCallback:(void (^)(NSString *))callback;
- (void)setEditingSafeInsets:(UIEdgeInsets)insets;
- (BOOL)beginLayoutEditing;
- (BOOL)isLayoutEditing;
- (BOOL)finishLayoutEditing:(BOOL)save reason:(NSString *)reason;
- (void)resetLayoutDraft;
- (void)updateLayoutDraft:(NSDictionary *)settings;
- (NSString *)layoutEditingProfile;
- (NSArray<NSString *> *)editableControls;
@end
static __weak DmGamepad *g_view;
static void pads_start(void);   // Physical controllers, below

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob, *_rightRing, *_rightKnob;
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
    NSString *_touchProfile;
    NSDictionary *_touchSettings;
    BOOL _previewOnly, _layoutEditing, _forceFull;
    NSDictionary *_layoutSnapshot;
    NSString *_layoutProfile;
    CGRect _layoutEntryFrame, _layoutEntryBounds;
    UIEdgeInsets _layoutEntryInsets;
    CGAffineTransform _layoutEntryTransform;
    CGRect _gameRectInParent;
    CGSize _lastSize;
    UIEdgeInsets _editingSafeInsets;
    UITouch *_editingTouch;
    CGPoint _editingOffset;
    NSString *_editingSelection;
    CAShapeLayer *_editingOutline;
    void (^_editingSelectionCallback)(NSString *);
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = parent.contentsScale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout

- (instancetype)initWithFrame:(CGRect)f {
    return [self initWithFrame:f editingProfile:nil settings:nil];
}
- (instancetype)initWithFrame:(CGRect)f editingProfile:(NSString *)profile settings:(NSDictionary *)settings {
    if ((self = [super initWithFrame:f])) {
        _previewOnly = profile != nil;
        _touchProfile = [(_previewOnly ? profile : dm_touch_active_profile()) copy];
        _touchSettings = dm_touch_normalize_profile_settings(settings ?: dm_touch_profile_settings(_touchProfile));
        _gameRectInParent = CGRectNull;
        _lastSize = f.size;
        _editingSelection = @"LEFT_STICK";
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = YES;
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!_previewOnly && (!feedback || atoi(feedback))) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
        });
        _controls = [CALayer layer]; _controls.contentsScale = self.traitCollection.displayScale; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        _rightRing = shape(_controls); _rightRing.fillColor = k_ringFill.CGColor;
        _rightKnob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        CAShapeLayer *rightIn = [CAShapeLayer layer]; rightIn.fillColor = nil; rightIn.strokeColor = k_line.CGColor; rightIn.lineWidth = 1.5;
        [_rightKnob addSublayer:rightIn];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _swap = shape(_controls); _swapLabel = label(_swap, @"");
        if (_previewOnly) {
            _editingOutline = shape(self.layer); _editingOutline.fillColor = UIColor.clearColor.CGColor;
            _editingOutline.strokeColor = UIColor.systemOrangeColor.CGColor; _editingOutline.lineWidth = 2;
            _editingOutline.lineDashPattern = @[@5, @3];
        }
        [self configureLayout];
        [self applyLayout];
        if (_previewOnly) return self;
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(touchSettingsChanged:) name:DmTouchSettingsDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
        pads_start();
        [self padsChanged:nil];
        motion_start();
        phone_motion_start(self);
    }
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_layoutEditing) input_editing_set(NO);
}
- (BOOL)editing { return _previewOnly || _layoutEditing; }
- (void)configureLayout {
        // A live editor keeps the current 2D/3D/Tap visibility exactly as played.
        // Custom positions do not silently change the profile's chosen standard style.
        _forceFull = _previewOnly || [_touchProfile isEqual:@"folded"];
        int l = (int)dm_touch_layout_style(_touchProfile, DM_GAME_PAD_LAYOUT);
        if (_forceFull) l = 1;
        else if (l == 2 && dm_opmode() != 0) l = 0;
        _full = l == 1; _tap = l == 2;
}
- (void)touchSettingsChanged:(NSNotification *)note {
    (void)note;
    if (_previewOnly) return;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self touchSettingsChanged:nil]; }); return; }
    if (_layoutEditing) {
        if ([_layoutProfile isEqual:dm_touch_active_profile()]) return;
        [self finishLayoutEditing:NO reason:@"profileChanged"];
    }
    [self reset];
    _touchProfile = [dm_touch_active_profile() copy];
    _touchSettings = dm_touch_profile_settings(_touchProfile);
    [self configureLayout]; [self applyLayout]; [self setNeedsLayout];
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _tap || (fullOnly(b) && !_full);
    _ring.hidden = _knob.hidden = _tap;
    _rightRing.hidden = _rightKnob.hidden = _tap || !_full;
    _swap.hidden = _forceFull;
    _editingOutline.hidden = !self.editing || !_editingSelection.length;
    _controls.hidden = _padOff && !self.editing;
    _controls.opacity = [_touchSettings[@"opacity"] floatValue];
    _swapLabel.string = _tap ? @"Tap" : _full ? @"3D" : @"2D";
    [CATransaction commit];
}
- (void)nextLayout {   // 2D → 3D (→ Tap in handheld mode) → 2D: release every touch first (no key stays held), save, lay out again
    if (_forceFull || self.editing) return;
    int l = _tap ? 0 : _full ? (dm_opmode() == 0 ? 2 : 0) : 1;
    [self reset];
    _full = l == 1; _tap = l == 2;
    dm_touch_save_layout_style(_touchProfile, l);
    [self applyLayout]; [self setNeedsLayout];
}

// ---- In-place layout draft lifecycle ----
- (void)postLayoutEditing:(NSString *)reason profile:(NSString *)profile {
    [NSNotificationCenter.defaultCenter postNotificationName:DmGamepadLayoutEditingDidChangeNotification
        object:self userInfo:@{@"editing": @(_layoutEditing), @"profile": profile, @"reason": reason}];
}
- (BOOL)layoutGeometryChanged {
    return !CGRectEqualToRect(self.frame, _layoutEntryFrame) || !CGRectEqualToRect(self.bounds, _layoutEntryBounds) ||
        !UIEdgeInsetsEqualToEdgeInsets(self.safeAreaInsets, _layoutEntryInsets) ||
        !CGAffineTransformEqualToTransform(self.transform, _layoutEntryTransform);
}
- (BOOL)beginLayoutEditing {
    if (!NSThread.isMainThread || _previewOnly || _layoutEditing || atomic_load(&g_input_suppressed) || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return NO;
    if (![_touchProfile isEqual:dm_touch_active_profile()]) [self touchSettingsChanged:nil];
    [self reset];   // Publish the final release before editing suppresses virtual input.
    input_editing_set(YES);
    _layoutSnapshot = dm_touch_normalize_profile_settings(_touchSettings);
    _layoutProfile = [_touchProfile copy];
    _layoutEntryFrame = self.frame; _layoutEntryBounds = self.bounds;
    _layoutEntryInsets = self.safeAreaInsets; _layoutEntryTransform = self.transform;
    _touchSettings = dm_touch_normalize_profile_settings(_layoutSnapshot);
    _layoutEditing = YES;
    if (!_editingOutline) {
        _editingOutline = shape(self.layer); _editingOutline.fillColor = UIColor.clearColor.CGColor;
        _editingOutline.strokeColor = UIColor.systemOrangeColor.CGColor; _editingOutline.lineWidth = 2;
        _editingOutline.lineDashPattern = @[@5, @3];
    }
    _editingSelection = self.editableControls.firstObject ?: @"";
    [self applyLayout]; [self setNeedsLayout];
    [self postLayoutEditing:@"begin" profile:_layoutProfile];
    return YES;
}
- (BOOL)isLayoutEditing { return _layoutEditing; }
- (NSString *)layoutEditingProfile { return _layoutProfile ?: _touchProfile; }
- (BOOL)finishLayoutEditing:(BOOL)save reason:(NSString *)reason {
    if (!NSThread.isMainThread || !_layoutEditing) return NO;
    BOOL accepted = YES;
    if (save && ![_layoutProfile isEqual:dm_touch_active_profile()]) { save = NO; accepted = NO; reason = @"profileChanged"; }
    if (save && [self layoutGeometryChanged]) { save = NO; accepted = NO; reason = @"geometryChanged"; }
    NSString *profile = [_layoutProfile copy];
    NSDictionary *draft = dm_touch_normalize_profile_settings(_touchSettings);
    NSDictionary *snapshot = _layoutSnapshot;
    [self reset];   // Clear draft touches without publishing an input event.
    // End first: the preference-change notification may synchronously call back into this view.
    _layoutEditing = NO; _layoutSnapshot = nil; _layoutProfile = nil;
    _touchProfile = [dm_touch_active_profile() copy];
    _touchSettings = [_touchProfile isEqual:profile] ? (save ? draft : snapshot) : dm_touch_profile_settings(_touchProfile);
    [self configureLayout]; [self applyLayout]; [self setNeedsLayout];
    if (save) dm_touch_save_profile(profile, draft);
    input_editing_set(NO);
    [self postLayoutEditing:reason profile:profile];
    return accepted;
}
- (void)resetLayoutDraft {
    if (!_layoutEditing) return;
    [self reset]; _touchSettings = dm_touch_default_profile_settings();
    if (![self.editableControls containsObject:_editingSelection]) _editingSelection = self.editableControls.firstObject ?: @"";
    [self applyLayout]; [self setNeedsLayout];
    if (_editingSelectionCallback) _editingSelectionCallback(_editingSelection);
}
- (void)updateLayoutDraft:(NSDictionary *)settings {
    if (!_layoutEditing || ![settings isKindOfClass:NSDictionary.class]) return;
    NSMutableDictionary *draft = [_touchSettings mutableCopy];
    for (NSString *key in @[@"leftSensitivity", @"rightSensitivity", @"leftDeadZone", @"rightDeadZone", @"opacity"])
        if (settings[key] != nil) draft[key] = settings[key];
    _touchSettings = dm_touch_normalize_profile_settings(draft);
    [self applyLayout]; [self setNeedsLayout];
    if (_editingSelectionCallback) _editingSelectionCallback(_editingSelection);
}
- (void)setFrame:(CGRect)frame {
    if (_layoutEditing && !CGRectEqualToRect(self.frame, frame)) [self finishLayoutEditing:NO reason:@"geometryChanged"];
    [super setFrame:frame];
}
- (void)setBounds:(CGRect)bounds {
    if (_layoutEditing && !CGRectEqualToRect(self.bounds, bounds)) [self finishLayoutEditing:NO reason:@"geometryChanged"];
    [super setBounds:bounds];
}
- (void)setTransform:(CGAffineTransform)transform {
    if (_layoutEditing && !CGAffineTransformEqualToTransform(self.transform, transform)) [self finishLayoutEditing:NO reason:@"geometryChanged"];
    [super setTransform:transform];
}

// ---- Shared runtime/editor geometry, in pad-local points ----
- (UIEdgeInsets)controlSafeInsets { return _previewOnly ? _editingSafeInsets : self.safeAreaInsets; }
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.controlSafeInsets); }
- (CGFloat)u { return MAX(0, MIN(self.bounds.size.height / 430.0, MIN(self.controlBounds.size.width / 600.0, 1.3))); }
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (CGRect)controlBounds {
    CGRect b = UIEdgeInsetsInsetRect(self.bounds, self.controlSafeInsets);
    if (b.size.width <= 0 || b.size.height <= 0) b = self.bounds;
    return CGRectInset(b, MIN(2, b.size.width / 4), MIN(2, b.size.height / 4));
}
- (CGFloat)scaleFor:(NSString *)key {
    NSNumber *value = _touchSettings[@"controls"][key][@"scale"];
    return value ? value.doubleValue : 1;
}
- (CGSize)halfExtentFor:(NSString *)key base:(CGSize)half {
    CGFloat scale = [self scaleFor:key];
    return dm_touch_fitted_half_extent(CGSizeMake(half.width * scale, half.height * scale), self.controlBounds);
}
- (CGPoint)positionFor:(NSString *)key fallback:(CGPoint)point halfExtent:(CGSize)half {
    NSDictionary *saved = _touchSettings[@"controls"][key];
    if (saved) point = CGPointMake(CGRectGetMinX(self.bounds) + [saved[@"x"] doubleValue] * self.bounds.size.width,
                                  CGRectGetMinY(self.bounds) + [saved[@"y"] doubleValue] * self.bounds.size.height);
    CGRect b = self.controlBounds;
    CGPoint n = CGPointMake(b.size.width ? (point.x - b.origin.x) / b.size.width : .5,
                           b.size.height ? (point.y - b.origin.y) / b.size.height : .5);
    return dm_touch_clamped_center(n, b, half);
}
// Default clusters are laid out inside the same safe bounds used by the final clamp.
// Expanding those bounds first would collapse individual face buttons at a large side inset.
- (CGPoint)faceCenter { CGRect s = self.controlBounds; CGFloat u = self.u; return side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceRadius:(int)b { return [self halfExtentFor:k_control_names[b] base:CGSizeMake(K_FACE_R * self.u, K_FACE_R * self.u)].width; }
- (CGPoint)facePos:(int)b {
    CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    switch (b) { case B_A: c.x += g; break; case B_B: c.y += g; break; case B_X: c.y -= g; break; default: c.x -= g; }
    CGFloat r = [self faceRadius:b]; return [self positionFor:k_control_names[b] fallback:c halfExtent:CGSizeMake(r, r)];
}
- (CGPoint)stickHome { return [self stickCentre:0]; }
- (CGPoint)stickCentre:(int)i {
    CGRect s = self.controlBounds; CGFloat u = self.u, r = [self stickR:i];
    CGPoint c = side(s, i, (i ? K_LOW_X : K_STICK_X) * u, CGRectGetMaxY(s) - (i ? 150 : K_PAD_Y) * u);
    return [self positionFor:i ? @"RIGHT_STICK" : @"LEFT_STICK" fallback:c halfExtent:CGSizeMake(r, r)];
}
- (CGFloat)stickR:(int)i {
    CGFloat r = (i ? K_RSTICK_R : K_STICK_R) * self.u;
    return [self halfExtentFor:i ? @"RIGHT_STICK" : @"LEFT_STICK" base:CGSizeMake(r, r)].width;
}
- (CGPoint)dpadCenter { CGRect s = self.controlBounds; CGFloat u = self.u, r = self.dpadR;
    return [self positionFor:@"DPAD" fallback:side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u) halfExtent:CGSizeMake(r, r)]; }
- (CGFloat)dpadR { return [self halfExtentFor:@"DPAD" base:CGSizeMake(K_DPAD_R * self.u, K_DPAD_R * self.u)].width; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_ZR || b == B_L || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    CGFloat r = [self dropR:b] * K_DROP_TIP;
    return [self positionFor:k_control_names[b] fallback:side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u) halfExtent:CGSizeMake(r, r)]; }
- (CGFloat)dropR:(int)b { CGFloat r = (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u * K_DROP_TIP;
    return [self halfExtentFor:k_control_names[b] base:CGSizeMake(r, r)].width / K_DROP_TIP; }
- (CGFloat)clickR:(int)b { CGFloat r = K_CLICK_R * self.u; return [self halfExtentFor:k_control_names[b] base:CGSizeMake(r, r)].width; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u, r = [self clickR:b];
    return [self positionFor:k_control_names[b] fallback:side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u) halfExtent:CGSizeMake(r, r)]; }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u;
    CGSize half = [self halfExtentFor:k_control_names[b] base:CGSizeMake(K_PILL_W * u / 2, K_PILL_H * u / 2)];
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + K_PILL_Y * u);
    c = [self positionFor:k_control_names[b] fallback:c halfExtent:half];
    return CGRectMake(c.x - half.width, c.y - half.height, half.width * 2, half.height * 2);
}
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= [self clickR:b] * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)inSwap:(CGPoint)p { return !_forceFull && dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= [self faceRadius:b] * 1.25) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (NSArray<NSString *> *)editableControls {
    if (_tap && !_previewOnly) return @[];
    if (!_full && !_previewOnly) return @[@"LEFT_STICK", @"A", @"B", @"X", @"Y", @"L", @"R", @"ZL", @"ZR", @"PLUS", @"MINUS"];
    return @[@"LEFT_STICK", @"RIGHT_STICK", @"A", @"B", @"X", @"Y", @"L", @"R", @"ZL", @"ZR", @"PLUS", @"MINUS", @"L3", @"R3", @"DPAD"];
}
- (CGRect)controlRect:(NSString *)key {
    CGPoint c = CGPointZero; CGFloat r = 0;
    if ([key isEqual:@"LEFT_STICK"] || [key isEqual:@"RIGHT_STICK"]) {
        int i = [key isEqual:@"RIGHT_STICK"]; c = [self stickCentre:i]; r = [self stickR:i];
    } else if ([key isEqual:@"DPAD"]) { c = self.dpadCenter; r = self.dpadR; }
    else for (int b = 0; b < 12; b++) if ([key isEqual:k_control_names[b]]) {
        if (b <= B_Y) { c = [self facePos:b]; r = [self faceRadius:b]; }
        else if (isDrop(b)) { c = [self dropCenter:b]; r = [self dropR:b] * K_DROP_TIP; }
        else if (isClick(b)) { c = [self clickCenter:b]; r = [self clickR:b]; }
        else return [self pillRect:b];
        break;
    }
    return CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r);
}
- (void)selectEditingControl:(NSString *)control {
    if (!self.editing || ![self.editableControls containsObject:control]) return;
    _editingSelection = [control copy]; [self setNeedsLayout];
    if (_editingSelectionCallback) _editingSelectionCallback(_editingSelection);
}
- (NSDictionary *)editingSettings { return [_touchSettings copy]; }
- (NSString *)editingSelection { return _editingSelection; }
- (void)setEditingSelectionCallback:(void (^)(NSString *))callback { _editingSelectionCallback = [callback copy]; }
- (void)setEditingSafeInsets:(UIEdgeInsets)insets {
    if (!_previewOnly || UIEdgeInsetsEqualToEdgeInsets(_editingSafeInsets, insets)) return;
    _editingSafeInsets = insets; [self setNeedsLayout];
}
- (void)editControl:(NSString *)name position:(CGPoint)position scale:(CGFloat)scale {
    if (!self.editing || ![self.editableControls containsObject:name] || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    NSMutableDictionary *settings = [_touchSettings mutableCopy];
    NSMutableDictionary *controls = [settings[@"controls"] mutableCopy] ?: [NSMutableDictionary dictionary];
    controls[name] = @{@"x": @(fmin(fmax((position.x - self.bounds.origin.x) / self.bounds.size.width, 0), 1)),
                       @"y": @(fmin(fmax((position.y - self.bounds.origin.y) / self.bounds.size.height, 0), 1)),
                       @"scale": @(fmin(fmax(isfinite(scale) ? scale : 1, .5), 1.8))};
    settings[@"controls"] = controls; _touchSettings = settings;
    // Persist the fitted center, so the saved normalized position is what the editor showed.
    CGRect rect = [self controlRect:name];
    controls[name] = @{@"x": @((CGRectGetMidX(rect) - self.bounds.origin.x) / self.bounds.size.width),
                       @"y": @((CGRectGetMidY(rect) - self.bounds.origin.y) / self.bounds.size.height),
                       @"scale": controls[name][@"scale"]};
    [self setNeedsLayout];
}
- (void)setEditingScale:(CGFloat)scale {
    if (!self.editing || !_editingSelection.length) return;
    CGRect r = [self controlRect:_editingSelection];
    [self editControl:_editingSelection position:CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)) scale:scale];
}
- (void)resetEditingLayout {
    if (!self.editing) return;
    NSMutableDictionary *settings = [_touchSettings mutableCopy]; settings[@"controls"] = @{}; _touchSettings = settings;
    _editingTouch = nil; [self selectEditingControl:@"LEFT_STICK"]; [self setNeedsLayout];
}
- (void)editingTouchesBegan:(NSSet<UITouch *> *)touches {
    if (_editingTouch) return;
    UITouch *touch = touches.anyObject; CGPoint p = [touch locationInView:self];
    NSString *selected = nil; CGFloat best = CGFLOAT_MAX;
    for (NSString *name in self.editableControls) {
        CGRect r = [self controlRect:name];
        if (!CGRectContainsPoint(CGRectInset(r, -10, -10), p)) continue;
        CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
        CGFloat score = dist(p, c) / MAX(1, MIN(r.size.width, r.size.height) / 2);
        if (score < best) { best = score; selected = name; }
    }
    if (!selected) return;
    [self selectEditingControl:selected];
    CGRect r = [self controlRect:selected];
    _editingOffset = CGPointMake(p.x - CGRectGetMidX(r), p.y - CGRectGetMidY(r)); _editingTouch = touch;
}
- (void)editingTouchesMoved:(NSSet<UITouch *> *)touches {
    if (!_editingTouch || ![touches containsObject:_editingTouch]) return;
    CGPoint p = [_editingTouch locationInView:self];
    [self editControl:_editingSelection position:CGPointMake(p.x - _editingOffset.x, p.y - _editingOffset.y) scale:[self scaleFor:_editingSelection]];
}
- (void)setGameRectInParent:(CGRect)rect {
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) || !isfinite(rect.size.width) || !isfinite(rect.size.height) || rect.size.width <= 0 || rect.size.height <= 0) rect = CGRectNull;
    if (CGRectEqualToRect(rect, _gameRectInParent)) return;
    if (_layoutEditing) [self finishLayoutEditing:NO reason:@"geometryChanged"];
    [self reset]; _gameRectInParent = rect;
}
- (void)recompute {
    if (self.editing) { [self refresh]; return; }
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y);
        if (R <= 0 || d <= 0) continue;
        float dead = [_touchSettings[i ? @"rightDeadZone" : @"leftDeadZone"] floatValue];
        float sensitivity = [_touchSettings[i ? @"rightSensitivity" : @"leftSensitivity"] floatValue];
        CGFloat m = dm_touch_axis_strength((float)(d / R), dead, sensitivity) / d;
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (swap && !_swapHeld) || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil || _stick[1] != nil;
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Unclaimed touches use the exact picture rectangle provided by front_ios.m.
// A split control panel is outside that rectangle; its empty space never touches the game.
- (void)pushGame {
    if (self.editing) return;
    CGRect b = _gameRectInParent;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i] && self.superview && !CGRectIsNull(b) && b.size.width > 0 && b.size.height > 0) {
        CGPoint p = [_game[i] locationInView:self.superview];
        if (!CGRectContainsPoint(b, p)) continue;
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - b.origin.x) / b.size.width, 0), 0.999), (float)fmin(fmax((p.y - b.origin.y) / b.size.height, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    if (self.editing || !self.superview || CGRectIsNull(_gameRectInParent) || !CGRectContainsPoint(_gameRectInParent, [t locationInView:self.superview])) return NO;
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (self.editing) { [self editingTouchesBegan:ts]; return; }
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self]; int hit = _tap ? -1 : [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if ([self inSwap:p]) { [_owner setObject:@(C_SWAP) forKey:t]; continue; }
        if (_tap) { game |= [self gameBegin:t]; continue; }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        for (int b = B_A; b <= B_Y; b++) { CGFloat f = dist(p, [self facePos:b]) / MAX(1, [self faceRadius:b] * 1.6); if (f <= best) { best = f; kind = C_FACE; } }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; } }
        if (_full && !_stick[1]) { CGFloat s = dist(p, [self stickCentre:1]) / MAX(1, [self stickR:1] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; idx = 1; } }
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (self.editing) { [self editingTouchesMoved:ts]; return; }
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) _stickNow[v >> 8] = p;
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    if (self.editing) { if (_editingTouch && [ts containsObject:_editingTouch]) _editingTouch = nil; return; }
    BOOL swap = NO, game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if (ended && (v & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) swap = YES;   // layout button: counts only when released on the button
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
    if (swap) [self nextLayout];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; _editingTouch = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_layoutEditing && [self layoutGeometryChanged]) [self finishLayoutEditing:NO reason:@"geometryChanged"];
    if (!CGSizeEqualToSize(_lastSize, self.bounds.size)) { [self reset]; _lastSize = self.bounds.size; }
    UIWindowScene *ws = self.window.windowScene; if (ws && !_previewOnly) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    for (int b = 0; b < B_N; b++) _label[b].contentsScale = self.traitCollection.displayScale;
    _swapLabel.contentsScale = self.traitCollection.displayScale;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; CGFloat r = [self faceRadius:b]; setPath(_key[b], circlePath(c, r)); placeLabel(_label[b], c, 20 * r / K_FACE_R); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            CGFloat du = [self dropR:b] / (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R);
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * du)); placeLabel(_label[b], c, 16 * du);
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; CGFloat r = [self clickR:b]; setPath(_key[b], circlePath(c, r)); placeLabel(_label[b], c, 13 * r / K_CLICK_R);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * rc.size.height / K_PILL_H);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    CGFloat dpadU = self.dpadR / K_DPAD_R;
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * dpadU, K_ARM_IN * dpadU, arms[i].angle, 6 * dpadU));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    for (int i = 0; i < 2; i++) {
        CAShapeLayer *ring = i ? _rightRing : _ring, *knob = i ? _rightKnob : _knob;
        CGFloat r = [self stickR:i], k = K_KNOB_R * r / (i ? K_RSTICK_R : K_STICK_R);
        setPath(ring, circlePath([self stickCentre:i], r));
        knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k); setPath(knob, circlePath(CGPointMake(k, k), k));
        CAShapeLayer *in = (CAShapeLayer *)knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
        in.frame = knob.bounds; in.path = ip; CGPathRelease(ip);
    }
    if (self.editing && _editingSelection.length) setPath(_editingOutline, CGPathCreateWithRoundedRect(CGRectInset([self controlRect:_editingSelection], -4, -4), 8, 8, NULL));
    [CATransaction commit];
    [self refresh];
}
- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    if (_layoutEditing && !UIEdgeInsetsEqualToEdgeInsets(self.safeAreaInsets, _layoutEntryInsets)) [self finishLayoutEditing:NO reason:@"geometryChanged"];
    [self setNeedsLayout];
}
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor; _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    _swap.fillColor = (_swapHeld ? k_on : k_idle).CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    for (int i = 0; i < 2; i++) {
        CGPoint h = [self stickCentre:i], o = [self knobOffset:i]; CAShapeLayer *knob = i ? _rightKnob : _knob;
        CGFloat r = [self stickR:i], travel = r > 0 ? MAX(0, (r - knob.bounds.size.width / 2) / r) : 0;
        knob.position = CGPointMake(h.x + o.x * travel, h.y + o.y * travel); knob.fillColor = (_stick[i] ? k_on : k_idle).CGColor;
    }
    [CATransaction commit];
}

// ---- Physical controllers ----
// Each controller with an extended gamepad profile is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    uint64_t generation = atomic_load(&g_input_generation);
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    if (atomic_load(&g_input_suppressed)) return;
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.buttonB, B_A); K(g.buttonA, B_B); K(g.buttonY, B_X); K(g.buttonX, B_Y);   // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    int32_t lx = axis(g.leftThumbstick.xAxis.value), ly = axis(g.leftThumbstick.yAxis.value);
    int32_t rx = axis(g.rightThumbstick.xAxis.value), ry = axis(g.rightThumbstick.yAxis.value);
    pthread_mutex_lock(&g_mu);
    if (!atomic_load(&g_input_suppressed) && generation == atomic_load(&g_input_generation)) dm_pad_set_player(p, m, lx, ly, rx, ry);
    pthread_mutex_unlock(&g_mu);
}
// Home and Capture: without this iOS takes them as system gestures (Home opens the Games overlay, Capture a screenshot); the app gives them no function
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) { gone.extendedGamepad.valueChangedHandler = nil; dm_motion_detach(gone, 0); }
    BOOL any = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone && c.extendedGamepad) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_keep_system_buttons(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c.extendedGamepad);
    }
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_keep_system_buttons(c);
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    return pad_slot_mask(&g_slots) != 0;
}
- (void)padsChanged:(NSNotification *)note {
    GCController *c = note.object, *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (c && (!c.extendedGamepad || g_merge)) LOG("controller %s: %s%s", gone ? "disconnected" : "connected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
    BOOL any = g_merge ? pads_merged(gone) : pads_slotted(gone);
    dispatch_async(dispatch_get_main_queue(), ^{ self->_padOff = any; self->_controls.hidden = any && !self.editing; [self reset]; });
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_release_touches(UIView *pad) { if ([pad isKindOfClass:DmGamepad.class]) [(DmGamepad *)pad reset]; }
void dm_gamepad_set_game_rect(UIView *pad, CGRect rect) { if ([pad isKindOfClass:DmGamepad.class]) [(DmGamepad *)pad setGameRectInParent:rect]; }
BOOL dm_gamepad_begin_layout_edit(UIView *pad) { return [pad isKindOfClass:DmGamepad.class] && [(DmGamepad *)pad beginLayoutEditing]; }
BOOL dm_gamepad_is_layout_editing(UIView *pad) { return [pad isKindOfClass:DmGamepad.class] && [(DmGamepad *)pad isLayoutEditing]; }
BOOL dm_gamepad_end_layout_edit(UIView *pad, BOOL save) {
    return [pad isKindOfClass:DmGamepad.class] && [(DmGamepad *)pad finishLayoutEditing:save reason:save ? @"saved" : @"cancelled"];
}
void dm_gamepad_reset_layout_draft(UIView *pad) { if ([pad isKindOfClass:DmGamepad.class]) [(DmGamepad *)pad resetLayoutDraft]; }
void dm_gamepad_update_layout_draft(UIView *pad, NSDictionary *settings) { if ([pad isKindOfClass:DmGamepad.class]) [(DmGamepad *)pad updateLayoutDraft:settings]; }
NSString *dm_gamepad_layout_edit_profile(UIView *pad) { return [pad isKindOfClass:DmGamepad.class] ? [(DmGamepad *)pad layoutEditingProfile] : dm_touch_active_profile(); }
NSArray<NSString *> *dm_gamepad_layout_edit_controls(UIView *pad) { return [pad isKindOfClass:DmGamepad.class] ? [(DmGamepad *)pad editableControls] : @[]; }
UIView *dm_gamepad_editor_preview(NSString *profile, NSDictionary *settings) {
    NSString *name = [@[@"outer", @"inner", @"folded"] containsObject:profile] ? profile : @"outer";
    return [[DmGamepad alloc] initWithFrame:CGRectZero editingProfile:name settings:settings];
}
void dm_gamepad_editor_set_safe_insets(UIView *preview, UIEdgeInsets insets) { [(DmGamepad *)preview setEditingSafeInsets:insets]; }
NSDictionary *dm_gamepad_editor_settings(UIView *preview) { return [(DmGamepad *)preview editingSettings]; }
NSString *dm_gamepad_editor_selection(UIView *preview) { return [(DmGamepad *)preview editingSelection]; }
void dm_gamepad_editor_select(UIView *preview, NSString *control) { [(DmGamepad *)preview selectEditingControl:control]; }
void dm_gamepad_editor_set_scale(UIView *preview, CGFloat scale) { [(DmGamepad *)preview setEditingScale:scale]; }
void dm_gamepad_editor_reset_layout(UIView *preview) { [(DmGamepad *)preview resetEditingLayout]; }
void dm_gamepad_editor_on_selection(UIView *preview, void (^callback)(NSString *)) { [(DmGamepad *)preview setEditingSelectionCallback:callback]; }
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); }); }   // On become active: motion_apple.h
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    // The front end combines background and editing pause reasons. Keep a layout draft
    // across backgrounding, but no touch that ended off-screen remains held on return.
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_shake_btn = 0; pthread_mutex_unlock(&g_mu); publish();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
