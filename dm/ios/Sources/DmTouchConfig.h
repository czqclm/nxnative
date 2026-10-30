// Per-display touch settings shared by the launcher, runtime pad and layout editor.
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const DmTouchSettingsDidChangeNotification;

// Profiles: outer, inner, folded. The setter below never writes DmTouchDisplayMode.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *dm_touch_profile_settings(NSString *profile);
// A fresh default snapshot for an editor's draft reset; never changes preferences.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *dm_touch_default_profile_settings(void);
// Validates a detached draft without reading or writing preferences.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *dm_touch_normalize_profile_settings(NSDictionary<NSString *, id> *settings);
// Merges supplied scalar settings; an omitted controls dictionary is preserved.
// Supplying controls replaces the complete control layout; {} restores built-in positions.
FOUNDATION_EXPORT void dm_touch_save_profile(NSString *profile, NSDictionary<NSString *, id> *settings);
FOUNDATION_EXPORT void dm_touch_reset_profile(NSString *profile);
FOUNDATION_EXPORT NSString *dm_touch_active_profile(void);
FOUNDATION_EXPORT void dm_touch_set_active_profile(NSString *profile);
FOUNDATION_EXPORT BOOL dm_touch_has_custom_layout(NSString *profile);
// Standard 2D/3D/Tap style (0/1/2), kept separately for each display profile.
// An unsaved profile can use the old DmPadLayout value as its migration seed.
FOUNDATION_EXPORT NSInteger dm_touch_layout_style(NSString *profile, NSInteger fallback);
FOUNDATION_EXPORT void dm_touch_save_layout_style(NSString *profile, NSInteger style);

// Scalar keys: leftSensitivity/rightSensitivity (.25..2.5, default 1),
// leftDeadZone/rightDeadZone (0..0.4, default .1), opacity (.2..1, default .75).
// controls maps A/B/X/Y/L/R/ZL/ZR/PLUS/MINUS/L3/R3/DPAD/LEFT_STICK/RIGHT_STICK
// to {x: 0..1, y: 0..1, scale: .5..1.8}. Coordinates are local to the pad bounds.
// Reads return validated defaults without writing preferences.

// Pure helpers: normalizedRadius is finger distance / stick radius. Sensitivity
// changes the response curve; every setting retains full input at radius >= .8.
FOUNDATION_EXPORT float dm_touch_axis_strength(float normalizedRadius, float deadZone, float sensitivity);
// Oversized controls are fitted proportionally before their centers are clamped.
FOUNDATION_EXPORT CGSize dm_touch_fitted_half_extent(CGSize requested, CGRect bounds);
FOUNDATION_EXPORT CGPoint dm_touch_clamped_center(CGPoint normalized, CGRect bounds, CGSize halfExtent);

NS_ASSUME_NONNULL_END
