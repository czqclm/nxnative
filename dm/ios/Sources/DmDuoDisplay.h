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
    CGRect padFrame;          // Whole bounds, or the lower panel when folded.
    BOOL split;
    BOOL usesReservedDivision;
    DmDuoSplitAxis axis;
} DmDuoGeometry;

// Pure functions: no device queries, preferences, notifications, or game state.
// Folded always means upper picture/lower controls. A usable horizontal division
// supplies its real Y boundaries and gap. Vertical or missing divisions use the
// horizontal midpoint of bounds, without claiming a reserved division was used.
FOUNDATION_EXPORT DmDuoGeometry dm_duo_geometry(CGRect bounds, UIEdgeInsets safeInsets,
    BOOL folded, CGRect divisionFrame, BOOL divisionActive);
FOUNDATION_EXPORT NSString *dm_duo_resolve_profile(NSString * _Nullable overrideMode,
    BOOL hasDivisionRegion, BOOL hasActiveDivisionRegion,
    UIUserInterfaceSizeClass horizontalSizeClass, UIUserInterfaceSizeClass verticalSizeClass);

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
