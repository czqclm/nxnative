// Display geometry shared by the iOS front end and the UI-only preview harness.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DmDuoSplitAxis) {
    DmDuoSplitAxisNone,
    DmDuoSplitAxisHorizontal,  // Upper picture, lower controls.
    DmDuoSplitAxisVertical     // Legacy value; the geometry policy never returns it.
};

typedef struct {
    CGRect videoRegion;       // Safe region assigned to the picture, in parent-view coordinates.
    CGRect gameFrame;         // Aspect-fit 16:9 picture, never stretched.
    CGRect padFrame;          // Whole bounds in landscape/square, lower panel in portrait.
    BOOL split;
    BOOL usesReservedDivision;
    DmDuoSplitAxis axis;
} DmDuoGeometry;

// Pure functions: no device queries, preferences, notifications, or game state.
// Portrait always means upper picture/lower controls. A usable horizontal division
// supplies its real Y boundaries and gap, whether active or inactive. Vertical or
// missing divisions use the midpoint. Landscape and square bounds never split.
FOUNDATION_EXPORT DmDuoGeometry dm_duo_geometry(CGRect bounds, UIEdgeInsets safeInsets,
    CGRect divisionFrame);
// Existing storage keys remain unchanged: outer = outer display, folded = inner
// portrait, inner = inner landscape/square. Both old inner/folded overrides force
// the inner display family; orientation still selects its profile and geometry.
FOUNDATION_EXPORT NSString *dm_duo_resolve_profile(NSString * _Nullable overrideMode,
    BOOL hasDivisionRegion, UIUserInterfaceSizeClass horizontalSizeClass,
    UIUserInterfaceSizeClass verticalSizeClass, CGRect bounds);
// Main-thread query shared by the launcher and running game. Includes inactive
// division regions so bending alone does not select another profile or divider.
// Does not publish state or write preferences; profileOut may be NULL.
FOUNDATION_EXPORT DmDuoGeometry dm_duo_layout_for_view(UIView *view,
    NSString * _Nullable overrideMode, NSString * _Nullable * _Nullable profileOut);

// Main-thread UI state, published even while the startup launcher is visible.
// Notification userInfo: profile (outer/inner/folded), axis (none/horizontal),
// reservedDivision (BOOL). The axis describes the real layout, not device orientation.
FOUNDATION_EXPORT NSNotificationName const DmDuoLayoutDidChangeNotification;
FOUNDATION_EXPORT NSString *dm_duo_current_layout_axis(void);
// JSON-safe geometry snapshot, also useful for UI-only simulator diagnostics.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *dm_duo_current_layout_snapshot(void);
FOUNDATION_EXPORT void dm_duo_publish_layout(NSString *profile, DmDuoGeometry geometry);
// Attach to a UIKit-owned view. In SwiftUI, use a UIViewRepresentable container;
// never insert subviews directly into UIHostingController.view. A full-screen
// presentation can detach the game view, so the visible launcher needs its own probe.
FOUNDATION_EXPORT void dm_duo_observe_layout_in_view(UIView *view);

NS_ASSUME_NONNULL_END
