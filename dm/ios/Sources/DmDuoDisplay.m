#import "DmDuoDisplay.h"
#import "DmTouchConfig.h"
#include <math.h>

static BOOL dm_duo_valid_rect(CGRect rect) {
    return !CGRectIsNull(rect) && !CGRectIsInfinite(rect)
        && isfinite(rect.origin.x) && isfinite(rect.origin.y)
        && isfinite(rect.size.width) && isfinite(rect.size.height)
        && rect.size.width > 0 && rect.size.height > 0;
}

static BOOL dm_duo_portrait(CGRect bounds) {
    return dm_duo_valid_rect(bounds) && bounds.size.height > bounds.size.width;
}

static CGFloat dm_duo_inset(CGFloat inset, CGFloat limit) {
    return isfinite(inset) ? MIN(limit, MAX(0, inset)) : 0;
}

static CGRect dm_duo_safe_rect(CGRect bounds, UIEdgeInsets insets) {
    CGFloat w = MAX(0, bounds.size.width), h = MAX(0, bounds.size.height);
    CGFloat left = dm_duo_inset(insets.left, w);
    CGFloat right = dm_duo_inset(insets.right, w - left);
    CGFloat top = dm_duo_inset(insets.top, h);
    CGFloat bottom = dm_duo_inset(insets.bottom, h - top);
    return CGRectMake(bounds.origin.x + left, bounds.origin.y + top,
                      w - left - right, h - top - bottom);
}

static CGRect dm_duo_fit_16_9(CGRect region) {
    if (CGRectIsEmpty(region) || CGRectIsNull(region)) return CGRectZero;
    CGFloat width = MIN(region.size.width, region.size.height * 16.0 / 9.0);
    CGFloat height = width * 9.0 / 16.0;
    return CGRectMake(CGRectGetMidX(region) - width / 2,
                      CGRectGetMidY(region) - height / 2, width, height);
}

DmDuoGeometry dm_duo_geometry(CGRect bounds, UIEdgeInsets safeInsets,
                             CGRect divisionFrame) {
    DmDuoGeometry result = {0};
    if (!dm_duo_valid_rect(bounds)) return result;
    CGRect safe = dm_duo_safe_rect(bounds, safeInsets);
    CGRect picture = bounds, controls = bounds;
    if (dm_duo_portrait(bounds)) {
        CGRect divider = dm_duo_valid_rect(divisionFrame) ? CGRectIntersection(bounds, divisionFrame) : CGRectNull;
        BOOL usable = dm_duo_valid_rect(divider) && divider.size.width >= divider.size.height;
        CGFloat start = CGRectGetMinY(divider), end = CGRectGetMaxY(divider);
        CGFloat lo = CGRectGetMinY(safe), hi = CGRectGetMaxY(safe);
        // An inactive horizontal divider still identifies the same physical gap.
        // Vertical, missing, or edge dividers use the portrait midpoint instead.
        if (!usable || start <= lo || end >= hi) {
            usable = NO;
            start = end = CGRectGetMidY(bounds);
        }
        picture.size.height = MAX(0, start - CGRectGetMinY(bounds));
        controls.origin.y = end;
        controls.size.height = MAX(0, CGRectGetMaxY(bounds) - end);
        result.split = YES;
        result.usesReservedDivision = usable;
        result.axis = DmDuoSplitAxisHorizontal;
    }
    CGRect available = CGRectIntersection(safe, picture);
    result.videoRegion = CGRectIsNull(available) ? CGRectZero : available;
    result.gameFrame = dm_duo_fit_16_9(result.videoRegion);
    result.padFrame = controls;
    return result;
}

NSString *dm_duo_resolve_profile(NSString *overrideMode, BOOL hasDivisionRegion,
                               UIUserInterfaceSizeClass horizontalSizeClass,
                               UIUserInterfaceSizeClass verticalSizeClass, CGRect bounds) {
    if ([overrideMode isEqualToString:@"outer"]) return @"outer";
    BOOL inner = [overrideMode isEqualToString:@"inner"] || [overrideMode isEqualToString:@"folded"]
        || hasDivisionRegion || (horizontalSizeClass == UIUserInterfaceSizeClassRegular
                                && verticalSizeClass == UIUserInterfaceSizeClassRegular);
    // Region data can be absent before attachment or while multitasking. Use
    // available layout traits as a fallback, never a fixed device pixel size.
    return inner ? (dm_duo_portrait(bounds) ? @"folded" : @"inner") : @"outer";
}

DmDuoGeometry dm_duo_layout_for_view(UIView *view, NSString *overrideMode, NSString **profileOut) {
    CGRect bounds = view.bounds;
    UIEdgeInsets insets = view.safeAreaInsets;
    DmDuoGeometry geometry = dm_duo_geometry(bounds, insets, CGRectNull);
    BOOL hasDivision = NO;
    if (@available(iOS 27.1, *)) {
        NSArray<UIViewReservedRegion *> *regions = [view
            reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind
            options:UIViewReservedRegionQueryOptionsIncludeInactive];
        hasDivision = regions.count > 0;
        for (UIViewReservedRegion *region in regions) {
            DmDuoGeometry candidate = dm_duo_geometry(bounds, insets, region.frame);
            if (candidate.usesReservedDivision) { geometry = candidate; break; }
        }
    }
    if (profileOut) *profileOut = dm_duo_resolve_profile(overrideMode, hasDivision,
        view.traitCollection.horizontalSizeClass, view.traitCollection.verticalSizeClass, bounds);
    return geometry;
}

NSNotificationName const DmDuoLayoutDidChangeNotification = @"DmDuoLayoutDidChangeNotification";
static NSString *dm_duo_axis = @"none";
static NSString *dm_duo_profile = @"outer";
static BOOL dm_duo_reserved;
static DmDuoGeometry dm_duo_last_geometry;

NSString *dm_duo_current_layout_axis(void) { return dm_duo_axis; }

static NSArray<NSNumber *> *dm_duo_rect_values(CGRect rect) {
    return @[@(rect.origin.x), @(rect.origin.y), @(rect.size.width), @(rect.size.height)];
}

NSDictionary<NSString *, id> *dm_duo_current_layout_snapshot(void) {
    return @{@"profile": dm_duo_profile, @"axis": dm_duo_axis,
             @"reservedDivision": @(dm_duo_reserved),
             @"gameFrame": dm_duo_rect_values(dm_duo_last_geometry.gameFrame),
             @"padFrame": dm_duo_rect_values(dm_duo_last_geometry.padFrame),
             @"videoRegion": dm_duo_rect_values(dm_duo_last_geometry.videoRegion)};
}

void dm_duo_publish_layout(NSString *profile, DmDuoGeometry geometry) {
    NSString *axis = geometry.axis == DmDuoSplitAxisHorizontal ? @"horizontal"
        : geometry.axis == DmDuoSplitAxisVertical ? @"vertical" : @"none";
    if ([axis isEqualToString:dm_duo_axis] && [profile isEqualToString:dm_duo_profile]
        && dm_duo_reserved == geometry.usesReservedDivision
        && CGRectEqualToRect(dm_duo_last_geometry.gameFrame, geometry.gameFrame)
        && CGRectEqualToRect(dm_duo_last_geometry.padFrame, geometry.padFrame)) return;
    dm_duo_axis = axis; dm_duo_profile = [profile copy];
    dm_duo_reserved = geometry.usesReservedDivision;
    dm_duo_last_geometry = geometry;
    [NSNotificationCenter.defaultCenter postNotificationName:DmDuoLayoutDidChangeNotification
        object:nil userInfo:@{@"profile": profile, @"axis": axis,
                              @"reservedDivision": @(geometry.usesReservedDivision)}];
}

// A transparent layout probe lets a full-screen SwiftUI launcher participate
// without subclassing its hosting controller or observing UIKit geometry by KVO.
@interface DmDuoLayoutProbe : UIView
@property(nonatomic, strong) id<UIInteraction> hingeInteraction;
@end

@implementation DmDuoLayoutProbe
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.accessibilityElementsHidden = YES;
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged:)
            name:DmTouchSettingsDidChangeNotification object:nil];
        [self registerForTraitChanges:@[UITraitHorizontalSizeClass.class, UITraitVerticalSizeClass.class]
            withHandler:^(DmDuoLayoutProbe *self, UITraitCollection *previous) {
                (void)previous; [self setNeedsLayout];
            }];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)settingsChanged:(NSNotification *)notification { (void)notification; [self setNeedsLayout]; }
- (void)didMoveToWindow { [super didMoveToWindow]; [self setNeedsLayout]; }
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)willMoveToSuperview:(UIView *)newSuperview {
    if (!newSuperview && self.hingeInteraction) [self.superview removeInteraction:self.hingeInteraction];
    [super willMoveToSuperview:newSuperview];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *host = self.superview;
    if (!host.window) return; // An inactive/detached hierarchy must not replace the visible UI's state.
    NSString *profile = nil;
    DmDuoGeometry geometry = dm_duo_layout_for_view(host,
        [NSUserDefaults.standardUserDefaults stringForKey:@"DmTouchDisplayMode"], &profile);
    dm_touch_set_active_profile(profile);
    dm_duo_publish_layout(profile, geometry);
}
@end

void dm_duo_observe_layout_in_view(UIView *view) {
    for (UIView *child in view.subviews) if ([child isKindOfClass:DmDuoLayoutProbe.class]) return;
    DmDuoLayoutProbe *probe = [[DmDuoLayoutProbe alloc] initWithFrame:view.bounds];
    [view insertSubview:probe atIndex:0];
    if (@available(iOS 27.1, *)) {
        __weak DmDuoLayoutProbe *weakProbe = probe;
        probe.hingeInteraction = [[UIHingeInteraction alloc] initWithUpdateHandler:
            ^(UIHingeInteraction *interaction, UIHingeInteractionUpdate *update) {
                (void)interaction; (void)update; [weakProbe setNeedsLayout];
            }];
        [view addInteraction:probe.hingeInteraction];
    }
    [probe setNeedsLayout];
}
