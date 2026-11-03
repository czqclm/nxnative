// Pure hinge-angle styling; no preferences, UIKit queries, input, or game state.
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, DmReflectionCurve) {
    DmReflectionCurveLinear,
    DmReflectionCurveSmooth,
    DmReflectionCurveBezier,
};

typedef struct {
    BOOL visible;
    BOOL captureEligible;     // Keep a small current source in inner portrait for paused previews.
    CGFloat angleDegrees;     // Finite input in [0, pi], converted to degrees; otherwise zero.
    CGFloat peakOpacity;      // Normalized reflection intensity; defaults to 1.
    CGFloat reachFraction;    // Virtual reach / control height; may extend beyond the screen.
    CGFloat blurStrength;     // Uniform blur, from 0 (sharp) to 1 (full).
    CGFloat featherPoints;    // Soft fade-in at the upper seam.
    DmReflectionCurve curve;
} DmReflectionStyle;

// UIHinge supplies radians. Unknown/nonfinite/closed/fully-flat angles are off;
// no angle is synthesized when the system has not supplied one. A visible style
// also requires the preference, an inner portrait layout, and a partially open hinge.
// Reach is exactly 3.75 times the original angle curve. The renderer crops its
// physical views to the control region without clamping this virtual reach.
FOUNDATION_EXPORT DmReflectionStyle dm_reflection_style(BOOL enabled, BOOL innerPortrait,
    BOOL partiallyOpen, CGFloat angleRadians);

// Applies sanitized per-app settings, retaining the same hinge/display gates.
FOUNDATION_EXPORT DmReflectionStyle dm_reflection_configured_style(NSDictionary *settings,
    BOOL innerPortrait, BOOL partiallyOpen, CGFloat angleRadians);
