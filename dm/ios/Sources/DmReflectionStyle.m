#import "DmReflectionStyle.h"
#import "DmReflectionPreferences.h"
#include <math.h>

DmReflectionStyle dm_reflection_style(BOOL enabled, BOOL innerPortrait,
                                     BOOL partiallyOpen, CGFloat angleRadians) {
    DmReflectionStyle style = {0};
    style.captureEligible = innerPortrait;
    BOOL finite = isfinite(angleRadians);
    if (finite && angleRadians >= 0 && angleRadians <= M_PI)
        style.angleDegrees = angleRadians * 180.0 / M_PI;
    if (!enabled || !innerPortrait || !partiallyOpen || !finite
        || angleRadians <= 0 || angleRadians >= M_PI) return style;

    CGFloat angle = style.angleDegrees;
    style.peakOpacity = 1;
    style.reachFraction = (180.0 - angle) / 180.0 * 3.75;
    style.blurStrength = 1;
    style.featherPoints = 12;
    style.curve = DmReflectionCurveBezier;
    style.visible = YES;
    return style;
}

DmReflectionStyle dm_reflection_configured_style(NSDictionary *settings,
    BOOL innerPortrait, BOOL partiallyOpen, CGFloat angleRadians) {
    NSDictionary *options = dm_reflection_normalize_settings(settings);
    DmReflectionStyle style = dm_reflection_style([options[@"enabled"] boolValue],
        innerPortrait, partiallyOpen, angleRadians);
    if (!style.visible) return style;
    style.peakOpacity = [options[@"brightness"] doubleValue];
    if (![options[@"angleLinked"] boolValue]) style.reachFraction = 1.875;
    style.reachFraction *= [options[@"length"] doubleValue];
    style.blurStrength = [options[@"blur"] doubleValue];
    style.featherPoints = [options[@"feather"] doubleValue];
    NSString *curve = options[@"curve"];
    style.curve = [curve isEqualToString:@"linear"] ? DmReflectionCurveLinear
        : [curve isEqualToString:@"smooth"] ? DmReflectionCurveSmooth : DmReflectionCurveBezier;
    return style;
}
