// Acceptance anchors and boundary properties of the production angle policy.
// These tests use radians, as UIHinge does, and do not assume sensor cadence.
#import <XCTest/XCTest.h>
#import "DmReflectionStyle.h"
#import "DmControlReflection.h"
#include <math.h>

@interface AngleReflectionTests : XCTestCase
@end

@implementation AngleReflectionTests
- (void)assertHidden:(DmReflectionStyle)style {
    XCTAssertFalse(style.visible);
    XCTAssertEqual(style.peakOpacity, 0);
    XCTAssertEqual(style.reachFraction, 0);
    XCTAssertTrue(isfinite(style.angleDegrees));
}
- (void)testRequestedNinetyAndFortyFiveDegreeAnchors {
    DmReflectionStyle rightAngle = dm_reflection_style(YES, YES, YES, M_PI_2);
    XCTAssertTrue(rightAngle.visible); XCTAssertEqualWithAccuracy(rightAngle.angleDegrees, 90, 1e-10);
    XCTAssertEqual(rightAngle.peakOpacity, 1);
    XCTAssertEqualWithAccuracy(rightAngle.reachFraction, 1.875, 1e-10);
    DmReflectionStyle acute = dm_reflection_style(YES, YES, YES, M_PI_4);
    XCTAssertTrue(acute.visible); XCTAssertEqualWithAccuracy(acute.angleDegrees, 45, 1e-10);
    XCTAssertEqual(acute.peakOpacity, 1);
    XCTAssertEqualWithAccuracy(acute.reachFraction, 2.8125, 1e-10);
    // Opening shortens the projection without weakening its peak brightness.
    DmReflectionStyle obtuse = dm_reflection_style(YES, YES, YES, 3 * M_PI_4);
    XCTAssertEqual(obtuse.peakOpacity, 1);
    XCTAssertEqualWithAccuracy(obtuse.reachFraction, .9375, 1e-10);
}
- (void)testOpeningReducesReachWhileEveryVisiblePeakRemainsOne {
    CGFloat previousReach = 3.75;
    for (NSInteger degree = 1; degree < 180; degree++) {
        DmReflectionStyle style = dm_reflection_style(YES, YES, YES, degree * M_PI / 180.0);
        XCTAssertTrue(style.visible);
        XCTAssertEqual(style.peakOpacity, 1);
        XCTAssertGreaterThan(style.reachFraction, 0); XCTAssertLessThanOrEqual(style.reachFraction, 3.75);
        XCTAssertLessThan(style.reachFraction, previousReach);
        XCTAssertEqualWithAccuracy(style.angleDegrees, degree, 1e-10);
        previousReach = style.reachFraction;
    }
    DmReflectionStyle before = dm_reflection_style(YES, YES, YES, (90 - 1e-5) * M_PI / 180.0);
    DmReflectionStyle after = dm_reflection_style(YES, YES, YES, (90 + 1e-5) * M_PI / 180.0);
    XCTAssertEqualWithAccuracy(before.peakOpacity, after.peakOpacity, 1e-6);
    XCTAssertEqualWithAccuracy(before.reachFraction, after.reachFraction, 1e-6);
}
- (void)testDisabledDisplayAndNonpartialStatesNeverProduceAReflection {
    [self assertHidden:dm_reflection_style(NO, YES, YES, M_PI_2)];
    [self assertHidden:dm_reflection_style(YES, NO, YES, M_PI_2)];
    [self assertHidden:dm_reflection_style(YES, YES, NO, M_PI_2)];
    [self assertHidden:dm_reflection_style(NO, NO, NO, M_PI_4)];
}
- (void)testMissingNonfiniteClosedAndFlatAnglesNeverUseANinetyDegreeFallback {
    CGFloat unavailable[] = {NAN, INFINITY, -INFINITY, -M_PI_2, 0, M_PI, M_PI + .01};
    for (NSUInteger i = 0; i < sizeof(unavailable) / sizeof(unavailable[0]); i++)
        [self assertHidden:dm_reflection_style(YES, YES, YES, unavailable[i])];
    DmReflectionStyle flat = dm_reflection_style(YES, YES, YES, M_PI);
    XCTAssertEqualWithAccuracy(flat.angleDegrees, 180, 1e-10);
}
- (void)testOpacityMeetsRequestedBrightnessAndReachOnFourHundredPointRegion {
    DmReflectionStyle rightAngle = dm_reflection_style(YES, YES, YES, M_PI_2);
    DmReflectionStyle acute = dm_reflection_style(YES, YES, YES, M_PI_4);
    XCTAssertEqual(dm_control_reflection_opacity(rightAngle, 0, 400), 0);
    XCTAssertEqual(dm_control_reflection_opacity(acute, 0, 400), 0);
    XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(rightAngle, 12, 400), 1, 1e-5);
    XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(acute, 12, 400), 1, 1e-5);
    for (NSNumber *distance in @[@750, @751, @1200])
        XCTAssertEqual(dm_control_reflection_opacity(rightAngle, distance.doubleValue, 400), 0);
    for (NSNumber *distance in @[@1125, @1126, @1200])
        XCTAssertEqual(dm_control_reflection_opacity(acute, distance.doubleValue, 400), 0);
    // Cropping the physical view must not force the virtual curve to zero at
    // the screen edge. The acute reflection also extends beyond the 90-degree one.
    XCTAssertGreaterThan(dm_control_reflection_opacity(rightAngle, 400, 400), 0);
    XCTAssertGreaterThan(dm_control_reflection_opacity(acute, 400, 400), 0);
    XCTAssertGreaterThan(dm_control_reflection_opacity(acute, 900, 400), 0);
    DmReflectionStyle obtuse = dm_reflection_style(YES, YES, YES, 3 * M_PI_4);
    XCTAssertGreaterThan(dm_control_reflection_opacity(obtuse, 374, 400), 0);
    XCTAssertEqual(dm_control_reflection_opacity(obtuse, 375, 400), 0);
    XCTAssertEqual(dm_control_reflection_opacity(obtuse, 400, 400), 0);
    // Acceptance anchors of the requested nonlinear fade, after the seam feather.
    // Both reaches are virtual: these samples must not be rescaled to screen height.
    XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(rightAngle, 187.5, 400), .984375, 1e-10);
    XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(rightAngle, 375, 400), .8125, 1e-10);
    XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(rightAngle, 562.5, 400), .3671875, 1e-10);
    XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(acute, 281.25, 400), .984375, 1e-10);
    XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(acute, 562.5, 400), .8125, 1e-10);
    XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(acute, 843.75, 400), .3671875, 1e-10);
}
- (void)testOpacityApproachesBothEdgesSoftlyAndContinuously {
    struct { CGFloat radians; CGFloat end; } cases[] = {{M_PI_2, 750}, {M_PI_4, 1125}};
    for (NSUInteger i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        DmReflectionStyle style = dm_reflection_style(YES, YES, YES, cases[i].radians);
        CGFloat previousNear = 1, previousFar = 1;
        for (NSNumber *epsilon in @[@.1, @.01, @.001]) {
            CGFloat near = dm_control_reflection_opacity(style, epsilon.doubleValue, 400);
            CGFloat far = dm_control_reflection_opacity(style, cases[i].end - epsilon.doubleValue, 400);
            XCTAssertGreaterThan(near, 0); XCTAssertLessThan(near, previousNear);
            XCTAssertGreaterThan(far, 0); XCTAssertLessThan(far, previousFar);
            previousNear = near; previousFar = far;
        }
        XCTAssertLessThan(previousNear, 1e-6); XCTAssertLessThan(previousFar, 1e-6);
        XCTAssertEqualWithAccuracy(dm_control_reflection_opacity(style, 11.999, 400),
                                  dm_control_reflection_opacity(style, 12.001, 400), .001);
        CGFloat previous = dm_control_reflection_opacity(style, 12, 400);
        for (NSInteger distance = 13; distance <= (NSInteger)cases[i].end; distance++) {
            CGFloat opacity = dm_control_reflection_opacity(style, distance, 400);
            XCTAssertGreaterThanOrEqual(opacity, 0); XCTAssertLessThanOrEqual(opacity, previous);
            previous = opacity;
        }
        XCTAssertEqual(previous, 0);
    }
}
- (void)testOpacityRejectsInvalidDistancesRegionsAndHiddenStyles {
    DmReflectionStyle style = dm_reflection_style(YES, YES, YES, M_PI_2);
    CGFloat invalidDistances[] = {NAN, INFINITY, -INFINITY, -1};
    for (NSUInteger i = 0; i < sizeof(invalidDistances) / sizeof(invalidDistances[0]); i++)
        XCTAssertEqual(dm_control_reflection_opacity(style, invalidDistances[i], 400), 0);
    CGFloat invalidHeights[] = {NAN, INFINITY, -INFINITY, -1, 0};
    for (NSUInteger i = 0; i < sizeof(invalidHeights) / sizeof(invalidHeights[0]); i++)
        XCTAssertEqual(dm_control_reflection_opacity(style, 12, invalidHeights[i]), 0);
    style.visible = NO;
    XCTAssertEqual(dm_control_reflection_opacity(style, 12, 400), 0);
}
@end
