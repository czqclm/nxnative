#import <XCTest/XCTest.h>
#import "DmDuoDisplay.h"
#import "DmTouchConfig.h"
#include <math.h>

// UIKit owns the real final region class. These fixtures supply only its public
// frame/active selectors to the production view-query helper, without a device.
@interface GeometryRegionFixture : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic, getter=isActive) BOOL active;
@end
@implementation GeometryRegionFixture
@end

@interface GeometryViewFixture : UIView
@property(nonatomic, copy) NSArray<GeometryRegionFixture *> *regions;
@property(nonatomic) UIEdgeInsets fixtureInsets;
@property(nonatomic) UIViewReservedRegionQueryOptions lastOptions;
@end
@implementation GeometryViewFixture
- (UIEdgeInsets)safeAreaInsets { return self.fixtureInsets; }
- (NSArray<UIViewReservedRegion *> *)reservedRegionsOfKind:(UIViewReservedRegionKind *)kind options:(UIViewReservedRegionQueryOptions)options {
    (void)kind; self.lastOptions = options;
    NSArray *regions = self.regions ?: @[];
    if (!(options & UIViewReservedRegionQueryOptionsIncludeInactive))
        regions = [regions filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(GeometryRegionFixture *region, NSDictionary *bindings) {
            (void)bindings; return region.isActive;
        }]];
    return (NSArray<UIViewReservedRegion *> *)regions;
}
@end

static GeometryRegionFixture *regionFixture(CGRect frame, BOOL active) {
    GeometryRegionFixture *region = [GeometryRegionFixture new]; region.frame = frame; region.active = active; return region;
}

@interface GeometryTests : XCTestCase
@end
@implementation GeometryTests
- (void)assertAspectFit:(DmDuoGeometry)layout {
    XCTAssertGreaterThan(layout.gameFrame.size.height, 0);
    XCTAssertTrue(CGRectContainsRect(layout.videoRegion, layout.gameFrame));
    XCTAssertEqualWithAccuracy(layout.gameFrame.size.width / layout.gameFrame.size.height, 16.0 / 9.0, .0001);
}
- (void)assertGeometry:(DmDuoGeometry)a equals:(DmDuoGeometry)b {
    XCTAssertTrue(CGRectEqualToRect(a.videoRegion, b.videoRegion));
    XCTAssertTrue(CGRectEqualToRect(a.gameFrame, b.gameFrame));
    XCTAssertTrue(CGRectEqualToRect(a.padFrame, b.padFrame));
    XCTAssertEqual(a.axis, b.axis); XCTAssertEqual(a.split, b.split);
    XCTAssertEqual(a.usesReservedDivision, b.usesReservedDivision);
}
- (void)testPortraitAlwaysSplitsForEveryDisplayMode {
    for (NSString *mode in @[@"automatic", @"outer", @"inner", @"folded"]) {
        for (NSNumber *hasRegion in @[@NO, @YES]) {
            CGRect bounds = CGRectMake(10, 20, 430, 900);
            NSString *profile = dm_duo_resolve_profile(mode, hasRegion.boolValue, UIUserInterfaceSizeClassCompact, UIUserInterfaceSizeClassRegular, bounds);
            XCTAssertTrue(([@[@"outer", @"inner", @"folded"] containsObject:profile]));
            DmDuoGeometry layout = dm_duo_geometry(bounds, UIEdgeInsetsMake(40, 10, 30, 20), CGRectNull);
            [self assertAspectFit:layout]; XCTAssertTrue(layout.split);
            XCTAssertEqual(layout.axis, DmDuoSplitAxisHorizontal); XCTAssertFalse(layout.usesReservedDivision);
            XCTAssertEqual(CGRectGetMinY(layout.padFrame), CGRectGetMidY(bounds));
            XCTAssertLessThanOrEqual(CGRectGetMaxY(layout.gameFrame), CGRectGetMinY(layout.padFrame));
            XCTAssertEqual(layout.padFrame.size.width, bounds.size.width);
            XCTAssertTrue(CGRectContainsRect(UIEdgeInsetsInsetRect(bounds, UIEdgeInsetsMake(40, 10, 30, 20)), layout.gameFrame));
        }
    }
}
- (void)testLandscapeIgnoresEveryDivisionAndKeepsAspectAndSafeArea {
    CGRect bounds = CGRectMake(10, 20, 951, 669);
    UIEdgeInsets insets = UIEdgeInsetsMake(20, 84, 30, 10);
    DmDuoGeometry flat = dm_duo_geometry(bounds, insets, CGRectNull);
    for (NSValue *value in @[[NSValue valueWithCGRect:CGRectNull],
                             [NSValue valueWithCGRect:CGRectMake(10, 320, 951, 40)],
                             [NSValue valueWithCGRect:CGRectMake(465, 20, 40, 669)],
                             [NSValue valueWithCGRect:CGRectInfinite],
                             [NSValue valueWithCGRect:CGRectMake(NAN, 300, 951, 40)]]) {
        DmDuoGeometry layout = dm_duo_geometry(bounds, insets, value.CGRectValue);
        [self assertGeometry:layout equals:flat]; [self assertAspectFit:layout];
        XCTAssertFalse(layout.split); XCTAssertFalse(layout.usesReservedDivision);
        XCTAssertEqual(layout.axis, DmDuoSplitAxisNone);
        XCTAssertTrue(CGRectEqualToRect(layout.padFrame, bounds));
        XCTAssertTrue(CGRectEqualToRect(layout.videoRegion, UIEdgeInsetsInsetRect(bounds, insets)));
    }
}
- (void)testSquareUsesUnsplitInnerLandscapeProfile {
    CGRect bounds = CGRectMake(0, 0, 800, 800);
    DmDuoGeometry layout = dm_duo_geometry(bounds, UIEdgeInsetsZero, CGRectMake(0, 380, 800, 40));
    XCTAssertFalse(layout.split); XCTAssertFalse(layout.usesReservedDivision);
    XCTAssertEqual(layout.axis, DmDuoSplitAxisNone); XCTAssertTrue(CGRectEqualToRect(layout.padFrame, bounds));
    XCTAssertEqualObjects(dm_duo_resolve_profile(@"automatic", YES, 1, 1, bounds), @"inner");
    [self assertAspectFit:layout];
}
- (void)testPortraitHorizontalDivisionKeepsItsActualGap {
    CGRect bounds = CGRectMake(10, 20, 800, 1000), hinge = CGRectMake(10, 480, 800, 40);
    DmDuoGeometry layout = dm_duo_geometry(bounds, UIEdgeInsetsMake(20, 10, 30, 10), hinge);
    [self assertAspectFit:layout]; XCTAssertEqual(layout.axis, DmDuoSplitAxisHorizontal);
    XCTAssertLessThanOrEqual(CGRectGetMaxY(layout.gameFrame), 480);
    XCTAssertEqual(CGRectGetMinY(layout.padFrame), 520); XCTAssertTrue(layout.usesReservedDivision);
    XCTAssertEqual(CGRectGetMaxY(layout.padFrame), CGRectGetMaxY(bounds));
}
- (void)testPortraitMissingVerticalOutsideAndInvalidDivisionsUseMidpoint {
    CGRect bounds = CGRectMake(0, 0, 430, 900);
    UIEdgeInsets insets = UIEdgeInsetsMake(20, 10, 30, 10);
    DmDuoGeometry fallback = dm_duo_geometry(bounds, insets, CGRectNull);
    for (NSValue *value in @[[NSValue valueWithCGRect:CGRectNull], [NSValue valueWithCGRect:CGRectZero],
                             [NSValue valueWithCGRect:CGRectInfinite], [NSValue valueWithCGRect:CGRectMake(NAN, 400, 430, 20)],
                             [NSValue valueWithCGRect:CGRectMake(200, 0, 30, 900)],
                             [NSValue valueWithCGRect:CGRectMake(0, 1000, 430, 20)],
                             [NSValue valueWithCGRect:CGRectMake(0, 10, 430, 20)],
                             [NSValue valueWithCGRect:CGRectMake(0, 860, 430, 20)]]) {
        DmDuoGeometry layout = dm_duo_geometry(bounds, insets, value.CGRectValue);
        [self assertGeometry:layout equals:fallback]; [self assertAspectFit:layout];
        XCTAssertTrue(layout.split); XCTAssertFalse(layout.usesReservedDivision);
        XCTAssertEqual(CGRectGetMinY(layout.padFrame), 450);
    }
}
- (void)testInvalidBoundsReturnEmptyGeometry {
    for (NSValue *value in @[[NSValue valueWithCGRect:CGRectZero], [NSValue valueWithCGRect:CGRectNull],
                             [NSValue valueWithCGRect:CGRectInfinite], [NSValue valueWithCGRect:CGRectMake(0, 0, -1, 900)],
                             [NSValue valueWithCGRect:CGRectMake(0, 0, 430, NAN)]]) {
        DmDuoGeometry layout = dm_duo_geometry(value.CGRectValue, UIEdgeInsetsZero, CGRectNull);
        XCTAssertTrue(CGRectEqualToRect(layout.videoRegion, CGRectZero));
        XCTAssertTrue(CGRectEqualToRect(layout.gameFrame, CGRectZero));
        XCTAssertTrue(CGRectEqualToRect(layout.padFrame, CGRectZero));
        XCTAssertFalse(layout.split); XCTAssertFalse(layout.usesReservedDivision); XCTAssertEqual(layout.axis, DmDuoSplitAxisNone);
    }
}
- (void)testNonfiniteInsetsDoNotProduceNonfiniteGeometry {
    CGRect bounds = CGRectMake(0, 0, 430, 900);
    DmDuoGeometry layout = dm_duo_geometry(bounds, UIEdgeInsetsMake(NAN, INFINITY, -20, 10), CGRectNull);
    DmDuoGeometry finite = dm_duo_geometry(bounds, UIEdgeInsetsMake(0, 0, 0, 10), CGRectNull);
    [self assertGeometry:layout equals:finite]; [self assertAspectFit:layout];
}
- (void)testAutomaticProfilesFollowDisplayAndOrientation {
    CGRect portrait = CGRectMake(0, 0, 669, 951), landscape = CGRectMake(0, 0, 951, 669);
    XCTAssertEqualObjects(dm_duo_resolve_profile(@"automatic", YES, 1, 1, portrait), @"folded");
    XCTAssertEqualObjects(dm_duo_resolve_profile(@"automatic", YES, 1, 1, landscape), @"inner");
    XCTAssertEqualObjects(dm_duo_resolve_profile(nil, NO, 2, 2, portrait), @"folded");
    XCTAssertEqualObjects(dm_duo_resolve_profile(@"unknown", NO, 2, 2, landscape), @"inner");
    XCTAssertEqualObjects(dm_duo_resolve_profile(@"automatic", NO, 1, 2, portrait), @"outer");
    XCTAssertEqualObjects(dm_duo_resolve_profile(@"automatic", NO, 2, 1, landscape), @"outer");
}
- (void)testLegacyOverridesKeepDisplayFamilyAndRotateWithinInnerProfiles {
    CGRect portrait = CGRectMake(0, 0, 669, 951), landscape = CGRectMake(0, 0, 951, 669);
    for (NSString *mode in @[@"inner", @"folded"]) {
        XCTAssertEqualObjects(dm_duo_resolve_profile(mode, NO, 1, 1, portrait), @"folded");
        XCTAssertEqualObjects(dm_duo_resolve_profile(mode, NO, 1, 1, landscape), @"inner");
    }
    XCTAssertEqualObjects(dm_duo_resolve_profile(@"outer", YES, 2, 2, portrait), @"outer");
    XCTAssertEqualObjects(dm_duo_resolve_profile(@"outer", YES, 2, 2, landscape), @"outer");
}
- (void)testViewQueryKeepsProfileAndGeometryWhenDivisionBecomesActive {
    GeometryViewFixture *view = [[GeometryViewFixture alloc] initWithFrame:CGRectMake(0, 0, 800, 1000)];
    GeometryRegionFixture *hinge = regionFixture(CGRectMake(0, 480, 800, 40), NO); view.regions = @[hinge];
    NSString *activeBefore = dm_touch_active_profile(), *flatProfile = nil, *bentProfile = nil;
    DmDuoGeometry flat = dm_duo_layout_for_view(view, @"automatic", &flatProfile);
    XCTAssertTrue(view.lastOptions & UIViewReservedRegionQueryOptionsIncludeInactive);
    XCTAssertEqualObjects(flatProfile, @"folded"); XCTAssertTrue(flat.usesReservedDivision);
    hinge.active = YES;
    DmDuoGeometry bent = dm_duo_layout_for_view(view, @"automatic", &bentProfile);
    XCTAssertEqualObjects(flatProfile, bentProfile); [self assertGeometry:bent equals:flat];
    view.frame = CGRectMake(0, 0, 1000, 800);
    hinge.frame = CGRectMake(480, 0, 40, 800); hinge.active = NO;
    flat = dm_duo_layout_for_view(view, @"automatic", &flatProfile);
    hinge.active = YES; bent = dm_duo_layout_for_view(view, @"automatic", &bentProfile);
    XCTAssertEqualObjects(flatProfile, @"inner"); XCTAssertEqualObjects(flatProfile, bentProfile);
    XCTAssertFalse(flat.split); [self assertGeometry:bent equals:flat];
    XCTAssertEqualObjects(dm_touch_active_profile(), activeBefore);
}
- (void)testViewQuerySkipsInvalidAndVerticalRegionsBeforeInactiveHorizontalRegion {
    GeometryViewFixture *view = [[GeometryViewFixture alloc] initWithFrame:CGRectMake(0, 0, 800, 1000)];
    view.fixtureInsets = UIEdgeInsetsMake(20, 10, 30, 10);
    view.regions = @[regionFixture(CGRectNull, YES), regionFixture(CGRectMake(380, 0, 40, 1000), YES),
                     regionFixture(CGRectMake(0, 480, 800, 40), NO)];
    NSString *profile = nil;
    DmDuoGeometry layout = dm_duo_layout_for_view(view, @"outer", &profile);
    XCTAssertEqualObjects(profile, @"outer"); XCTAssertTrue(layout.usesReservedDivision);
    XCTAssertEqual(CGRectGetMinY(layout.padFrame), 520); [self assertAspectFit:layout];
    [self assertGeometry:dm_duo_layout_for_view(view, @"outer", NULL) equals:layout];
}
- (void)testThreeProfilesRemainIndependent {
    NSString *domain = NSBundle.mainBundle.bundleIdentifier;
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults persistentDomainForName:domain];
    dm_touch_save_profile(@"outer", @{@"leftSensitivity": @0.5});
    dm_touch_save_profile(@"inner", @{@"leftSensitivity": @1.25});
    dm_touch_save_profile(@"folded", @{@"leftSensitivity": @2.0});
    XCTAssertEqualObjects(dm_touch_profile_settings(@"outer")[@"leftSensitivity"], @0.5);
    XCTAssertEqualObjects(dm_touch_profile_settings(@"inner")[@"leftSensitivity"], @1.25);
    XCTAssertEqualObjects(dm_touch_profile_settings(@"folded")[@"leftSensitivity"], @2.0);
    if (saved) [NSUserDefaults.standardUserDefaults setPersistentDomain:saved forName:domain];
    else [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
}
@end
