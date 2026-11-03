// Runtime pad and the isolated layout-editor preview share the same geometry.
#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const DmGamepadLayoutEditingDidChangeNotification;
FOUNDATION_EXPORT UIView *dm_gamepad_view(CGRect frame);
// The root gear can keep its editing action and use this menu on long press.
FOUNDATION_EXPORT UIButton *dm_game_menu_button(void);
FOUNDATION_EXPORT void dm_gamepad_set_menu_visible(UIView *pad, BOOL visible);
FOUNDATION_EXPORT void dm_gamepad_active(void);
FOUNDATION_EXPORT void dm_gamepad_reset(void);
FOUNDATION_EXPORT void dm_gamepad_release_touches(UIView *pad);
// The picture rectangle is in the pad's superview coordinates, including split layouts.
FOUNDATION_EXPORT void dm_gamepad_set_game_rect(UIView *pad, CGRect rect);
// Main-thread, in-place draft editing. Never resizes or reparents the runtime pad.
// End returns NO if no session exists or a requested save was cancelled by a geometry/profile change.
FOUNDATION_EXPORT BOOL dm_gamepad_begin_layout_edit(UIView *pad);
FOUNDATION_EXPORT BOOL dm_gamepad_is_layout_editing(UIView *pad);
FOUNDATION_EXPORT BOOL dm_gamepad_end_layout_edit(UIView *pad, BOOL save);
FOUNDATION_EXPORT void dm_gamepad_reset_layout_draft(UIView *pad);
FOUNDATION_EXPORT void dm_gamepad_update_layout_draft(UIView *pad, NSDictionary<NSString *, id> *scalarSettings);
FOUNDATION_EXPORT NSString *dm_gamepad_layout_edit_profile(UIView *pad);
FOUNDATION_EXPORT NSArray<NSString *> *dm_gamepad_layout_edit_controls(UIView *pad);
// Notification object is the pad; userInfo: editing, profile, reason.
// Reasons: begin, saved, cancelled, profileChanged, geometryChanged.
// Backgrounding releases touches but retains the draft; the front end keeps the game paused.
FOUNDATION_EXPORT UIViewController *dm_touch_editor_controller(NSString *profile);

// Editor-only views never start sensors, bind controllers, or publish game input.
FOUNDATION_EXPORT UIView *dm_gamepad_editor_preview(NSString *profile, NSDictionary<NSString *, id> *settings);
FOUNDATION_EXPORT void dm_gamepad_editor_set_safe_insets(UIView *preview, UIEdgeInsets insets);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *dm_gamepad_editor_settings(UIView *preview);
FOUNDATION_EXPORT NSString *dm_gamepad_editor_selection(UIView *preview);
FOUNDATION_EXPORT void dm_gamepad_editor_select(UIView *preview, NSString *control);
FOUNDATION_EXPORT void dm_gamepad_editor_set_scale(UIView *preview, CGFloat scale);
FOUNDATION_EXPORT void dm_gamepad_editor_reset_layout(UIView *preview);
FOUNDATION_EXPORT void dm_gamepad_editor_on_selection(UIView *preview, void (^ _Nullable callback)(NSString *control));
NS_ASSUME_NONNULL_END
