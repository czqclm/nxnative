#import "DmTouchConfig.h"
#import <dispatch/dispatch.h>
#include <math.h>

NSNotificationName const DmTouchSettingsDidChangeNotification = @"DmTouchSettingsDidChangeNotification";
static NSString *const k_profiles_key = @"DmTouchProfilesV1";
static NSString *g_active_profile = @"outer";

static NSObject *touch_lock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static BOOL profile_valid(id value) {
    return [value isKindOfClass:NSString.class] &&
        ([(NSString *)value isEqualToString:@"outer"] || [(NSString *)value isEqualToString:@"inner"] ||
         [(NSString *)value isEqualToString:@"folded"]);
}

static NSArray<NSString *> *profile_names(void) { return @[@"outer", @"inner", @"folded"]; }

static NSSet<NSString *> *control_names(void) {
    static NSSet<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[@"A", @"B", @"X", @"Y", @"L", @"R", @"ZL", @"ZR", @"PLUS", @"MINUS",
                                    @"L3", @"R3", @"DPAD", @"LEFT_STICK", @"RIGHT_STICK"]];
    });
    return names;
}

static BOOL finite_number(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
}

static NSNumber *number(id value, double fallback, double lo, double hi) {
    double v = finite_number(value) ? [value doubleValue] : fallback;
    return @(fmin(fmax(v, lo), hi));
}

static NSDictionary<NSString *, id> *clean_controls(id raw) {
    if (![raw isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [(NSDictionary *)raw enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:NSString.class] || ![control_names() containsObject:key] ||
            ![value isKindOfClass:NSDictionary.class]) return;
        // Missing or non-finite coordinates cannot identify a meaningful custom position.
        if (!finite_number(value[@"x"]) || !finite_number(value[@"y"])) return;
        result[key] = @{@"x": number(value[@"x"], .5, 0, 1), @"y": number(value[@"y"], .5, 0, 1),
                        @"scale": number(value[@"scale"], 1, .5, 1.8)};
    }];
    return [result copy];
}

static NSDictionary<NSString *, id> *clean_profile(id raw) {
    NSDictionary *d = [raw isKindOfClass:NSDictionary.class] ? raw : @{};
    return @{
        @"leftSensitivity": number(d[@"leftSensitivity"], 1, .25, 2.5),
        @"rightSensitivity": number(d[@"rightSensitivity"], 1, .25, 2.5),
        @"leftDeadZone": number(d[@"leftDeadZone"], .1, 0, .4),
        @"rightDeadZone": number(d[@"rightDeadZone"], .1, 0, .4),
        @"opacity": number(d[@"opacity"], .75, .2, 1),
        @"controls": clean_controls(d[@"controls"]),
    };
}

static NSDictionary *stored_profiles(NSUserDefaults *defaults) {
    id raw = [defaults objectForKey:k_profiles_key];
    return [raw isKindOfClass:NSDictionary.class] ? raw : @{};
}

static void changed(NSString *profile, NSString *reason) {
    NSDictionary *info = @{@"profile": profile, @"reason": reason};
    void (^post)(void) = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:DmTouchSettingsDidChangeNotification object:nil userInfo:info];
    };
    if (NSThread.isMainThread) post();
    else dispatch_async(dispatch_get_main_queue(), post);
}

NSDictionary<NSString *, id> *dm_touch_profile_settings(NSString *profile) {
    NSString *name = profile_valid(profile) ? profile : @"outer";
    @synchronized(touch_lock()) {
        return clean_profile(stored_profiles(NSUserDefaults.standardUserDefaults)[name]);
    }
}

NSDictionary<NSString *, id> *dm_touch_default_profile_settings(void) { return clean_profile(nil); }
NSDictionary<NSString *, id> *dm_touch_normalize_profile_settings(NSDictionary<NSString *, id> *settings) { return clean_profile(settings); }

void dm_touch_save_profile(NSString *profile, NSDictionary<NSString *, id> *settings) {
    if (!profile_valid(profile) || ![settings isKindOfClass:NSDictionary.class]) return;
    BOOL didChange = NO;
    @synchronized(touch_lock()) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDictionary *stored = stored_profiles(defaults);
        NSDictionary *previous = clean_profile(stored[profile]);
        NSMutableDictionary *merged = [previous mutableCopy];
        for (NSString *key in previous) if (settings[key] != nil) merged[key] = settings[key];
        NSDictionary *next = clean_profile(merged);
        if (![previous isEqualToDictionary:next]) {
            NSMutableDictionary *profiles = [NSMutableDictionary dictionary];
            for (NSString *name in profile_names()) if (stored[name] != nil) profiles[name] = clean_profile(stored[name]);
            profiles[profile] = next;
            [defaults setObject:[profiles copy] forKey:k_profiles_key];
            didChange = YES;
        }
    }
    if (didChange) changed(profile, @"settings");
}

void dm_touch_reset_profile(NSString *profile) {
    if (!profile_valid(profile)) return;
    BOOL didChange = NO;
    @synchronized(touch_lock()) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDictionary *stored = stored_profiles(defaults);
        if (stored[profile] != nil) {
            NSMutableDictionary *profiles = [NSMutableDictionary dictionary];
            for (NSString *name in profile_names())
                if (![name isEqualToString:profile] && stored[name] != nil) profiles[name] = clean_profile(stored[name]);
            if (profiles.count) [defaults setObject:[profiles copy] forKey:k_profiles_key];
            else [defaults removeObjectForKey:k_profiles_key];
            didChange = YES;
        }
    }
    if (didChange) changed(profile, @"reset");
}

NSString *dm_touch_active_profile(void) {
    @synchronized(touch_lock()) { return g_active_profile; }
}

void dm_touch_set_active_profile(NSString *profile) {
    if (!profile_valid(profile)) return;
    BOOL didChange = NO;
    @synchronized(touch_lock()) {
        if (![g_active_profile isEqualToString:profile]) { g_active_profile = [profile copy]; didChange = YES; }
    }
    if (didChange) changed(profile, @"active");
}

BOOL dm_touch_has_custom_layout(NSString *profile) {
    return [(NSDictionary *)dm_touch_profile_settings(profile)[@"controls"] count] != 0;
}

static BOOL layout_style_valid(id value) {
    if (!finite_number(value)) return NO;
    double n = [value doubleValue];
    return n >= 0 && n <= 2 && floor(n) == n;
}

NSInteger dm_touch_layout_style(NSString *profile, NSInteger fallback) {
    NSInteger initial = fallback >= 0 && fallback <= 2 ? fallback : 1;
    if (!profile_valid(profile)) return initial;
    @synchronized(touch_lock()) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id value = [defaults objectForKey:[@"DmPadLayout." stringByAppendingString:profile]];
        // Reading an old choice seeds an untouched profile without writing or sharing future changes.
        if (value == nil) value = [defaults objectForKey:@"DmPadLayout"];
        return layout_style_valid(value) ? [value integerValue] : initial;
    }
}

void dm_touch_save_layout_style(NSString *profile, NSInteger style) {
    if (!profile_valid(profile) || style < 0 || style > 2) return;
    BOOL didChange = NO;
    @synchronized(touch_lock()) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *key = [@"DmPadLayout." stringByAppendingString:profile];
        id previous = [defaults objectForKey:key];
        if (!layout_style_valid(previous) || [previous integerValue] != style) {
            [defaults setObject:@(style) forKey:key];
            didChange = YES;
        }
    }
    if (didChange) changed(profile, @"layout");
}

float dm_touch_axis_strength(float radius, float deadZone, float sensitivity) {
    if (!isfinite(radius) || radius <= 0) return 0;
    float dead = isfinite(deadZone) ? fminf(fmaxf(deadZone, 0), .4f) : .1f;
    float gain = isfinite(sensitivity) ? fminf(fmaxf(sensitivity, .25f), 2.5f) : 1;
    if (radius <= dead) return 0;
    float position = fminf(fmaxf((radius - dead) / (.8f - dead), 0), 1);
    return powf(position, 1 / gain);
}

static CGRect finite_bounds(CGRect b) {
    if (!isfinite(b.origin.x) || !isfinite(b.origin.y) || !isfinite(b.size.width) || !isfinite(b.size.height)) return CGRectZero;
    return CGRectStandardize(b);
}

CGSize dm_touch_fitted_half_extent(CGSize requested, CGRect bounds) {
    CGRect b = finite_bounds(bounds);
    CGFloat x = isfinite(requested.width) ? fmax(requested.width, 0) : 0;
    CGFloat y = isfinite(requested.height) ? fmax(requested.height, 0) : 0;
    CGFloat scale = 1;
    if (x > 0) scale = fmin(scale, b.size.width / (2 * x));
    if (y > 0) scale = fmin(scale, b.size.height / (2 * y));
    return CGSizeMake(x * scale, y * scale);
}

CGPoint dm_touch_clamped_center(CGPoint normalized, CGRect bounds, CGSize halfExtent) {
    CGRect b = finite_bounds(bounds);
    CGSize half = dm_touch_fitted_half_extent(halfExtent, b);
    CGFloat x = isfinite(normalized.x) ? fmin(fmax(normalized.x, 0), 1) : .5;
    CGFloat y = isfinite(normalized.y) ? fmin(fmax(normalized.y, 0), 1) : .5;
    return CGPointMake(fmin(fmax(b.origin.x + x * b.size.width, b.origin.x + half.width), CGRectGetMaxX(b) - half.width),
                       fmin(fmax(b.origin.y + y * b.size.height, b.origin.y + half.height), CGRectGetMaxY(b) - half.height));
}
