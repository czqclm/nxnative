#import "DmDuoDisplay.h"
#import "DmTouchConfig.h"
#include <math.h>

static CGRect dm_duo_safe_rect(CGRect bounds, UIEdgeInsets insets) {
    CGFloat w = MAX(0, bounds.size.width), h = MAX(0, bounds.size.height);
    CGFloat left = MIN(w, MAX(0, insets.left));
    CGFloat right = MIN(w - left, MAX(0, insets.right));
    CGFloat top = MIN(h, MAX(0, insets.top));
    CGFloat bottom = MIN(h - top, MAX(0, insets.bottom));
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
                             BOOL folded, CGRect divisionFrame, BOOL divisionActive) {
    DmDuoGeometry result = {0};
    if (CGRectIsNull(bounds) || CGRectIsInfinite(bounds) || CGRectIsEmpty(bounds)) return result;
    CGRect safe = dm_duo_safe_rect(bounds, safeInsets);
    CGRect picture = bounds, controls = bounds;
    if (folded) {
        CGRect divider = CGRectIntersection(bounds, divisionFrame);
        BOOL usable = divisionActive && !CGRectIsNull(divider) && !CGRectIsEmpty(divider)
            && !CGRectIsInfinite(divider) && divider.size.width >= divider.size.height;
        CGFloat start = CGRectGetMinY(divider), end = CGRectGetMaxY(divider);
        CGFloat lo = CGRectGetMinY(safe), hi = CGRectGetMaxY(safe);
        // Folded is always upper/lower. A vertical or unusable divider falls back
        // to the screen midpoint instead of changing the controls to a side panel.
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
                               BOOL hasActiveDivisionRegion,
                               UIUserInterfaceSizeClass horizontalSizeClass,
                               UIUserInterfaceSizeClass verticalSizeClass) {
    if ([overrideMode isEqualToString:@"outer"] || [overrideMode isEqualToString:@"inner"]
        || [overrideMode isEqualToString:@"folded"]) return overrideMode;
    if (hasActiveDivisionRegion) return @"folded";
    if (hasDivisionRegion) return @"inner";
    // Region data can be absent before attachment or while multitasking. Use
    // available layout traits as a fallback, never a fixed device pixel size.
    return horizontalSizeClass == UIUserInterfaceSizeClassRegular
        && verticalSizeClass == UIUserInterfaceSizeClassRegular ? @"inner" : @"outer";
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
    CGRect division = CGRectNull;
    BOOL hasDivision = NO, activeDivision = NO;
    if (@available(iOS 27.1, *)) {
        NSArray<UIViewReservedRegion *> *regions = [host
            reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind
            options:UIViewReservedRegionQueryOptionsIncludeInactive];
        hasDivision = regions.count > 0;
        for (UIViewReservedRegion *region in regions) {
            if (region.isActive && !CGRectIsEmpty(CGRectIntersection(host.bounds, region.frame))) {
                activeDivision = YES; division = region.frame; break;
            }
        }
    }
    NSString *profile = dm_duo_resolve_profile(
        [NSUserDefaults.standardUserDefaults stringForKey:@"DmTouchDisplayMode"],
        hasDivision, activeDivision, host.traitCollection.horizontalSizeClass,
        host.traitCollection.verticalSizeClass);
    DmDuoGeometry geometry = dm_duo_geometry(host.bounds, host.safeAreaInsets,
        [profile isEqualToString:@"folded"], division, activeDivision);
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
