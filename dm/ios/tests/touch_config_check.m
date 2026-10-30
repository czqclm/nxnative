// Isolated tests: replace standardUserDefaults with an in-memory object in this process.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "DmTouchConfig.h"
#include <math.h>
#include <stdio.h>

@interface MemoryDefaults : NSObject
@property(nonatomic) NSMutableDictionary *values;
- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
@end
@implementation MemoryDefaults
- (instancetype)init { if ((self = [super init])) _values = [NSMutableDictionary dictionary]; return self; }
- (id)objectForKey:(NSString *)key { return _values[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { _values[key] = value; }
- (void)removeObjectForKey:(NSString *)key { [_values removeObjectForKey:key]; }
@end

static MemoryDefaults *memory;
static id memory_defaults(id self, SEL selector) { (void)self; (void)selector; return memory; }
static int checks;
#define CHECK(expr) do { checks++; if (!(expr)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expr); return 1; } } while (0)
static BOOL near(double a, double b) { return fabs(a - b) < 1e-6; }

int main(void) { @autoreleasepool {
    memory = [MemoryDefaults new];
    Method method = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    IMP original = method_setImplementation(method, (IMP)memory_defaults);
    __block int notifications = 0;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:DmTouchSettingsDidChangeNotification object:nil queue:nil
                                                            usingBlock:^(NSNotification *note) { (void)note; notifications++; NSCAssert(NSThread.isMainThread, @"Main-thread notifications"); }];
    NSDictionary *outer = dm_touch_profile_settings(@"outer");
    CHECK(near([outer[@"leftSensitivity"] doubleValue], 1));
    CHECK(near([outer[@"rightDeadZone"] doubleValue], .1));
    CHECK(near([outer[@"opacity"] doubleValue], .75));
    CHECK(!dm_touch_has_custom_layout(@"outer"));
    CHECK(memory.values.count == 0);

    NSDictionary *controls = @{@"LEFT_STICK": @{@"x": @.12, @"y": @.8, @"scale": @1.25}};
    dm_touch_save_profile(@"outer", @{@"leftSensitivity": @1.4, @"controls": controls});
    CHECK(notifications == 1);
    CHECK(dm_touch_has_custom_layout(@"outer"));
    dm_touch_save_profile(@"outer", @{@"rightSensitivity": @.8});
    outer = dm_touch_profile_settings(@"outer");
    CHECK([outer[@"controls"] isEqualToDictionary:controls]);
    CHECK(near([outer[@"leftSensitivity"] doubleValue], 1.4));
    CHECK(near([outer[@"rightSensitivity"] doubleValue], .8));
    CHECK(near([dm_touch_profile_settings(@"inner")[@"leftSensitivity"] doubleValue], 1));
    dm_touch_save_profile(@"folded", @{@"opacity": @.4});
    CHECK(near([dm_touch_profile_settings(@"folded")[@"opacity"] doubleValue], .4));
    NSDictionary *snapshot = [memory.values copy];
    dm_touch_save_profile(@"invalid", @{@"opacity": @.9});
    dm_touch_reset_profile(@"invalid");
    CHECK([snapshot isEqualToDictionary:memory.values]);

    dm_touch_save_profile(@"inner", @{
        @"leftSensitivity": @100, @"rightSensitivity": @(-20),
        @"leftDeadZone": @(NAN), @"rightDeadZone": @.9, @"opacity": @"0.9",
        @"controls": @{
            @"A": @{@"x": @(-5), @"y": @8, @"scale": @30},
            @"B": @{@"x": @(INFINITY), @"y": @.5, @"scale": @1},
            @"X": @{@"x": @.5},
            @"Y": @{@"x": @.4, @"y": @.5, @"scale": @(-2)},
            @"UNKNOWN": @{@"x": @.5, @"y": @.5, @"scale": @1},
        }
    });
    NSDictionary *inner = dm_touch_profile_settings(@"inner");
    CHECK(near([inner[@"leftSensitivity"] doubleValue], 2.5));
    CHECK(near([inner[@"rightSensitivity"] doubleValue], .25));
    CHECK(near([inner[@"leftDeadZone"] doubleValue], .1));
    CHECK(near([inner[@"rightDeadZone"] doubleValue], .4));
    CHECK(near([inner[@"opacity"] doubleValue], .75));
    NSDictionary *valid = inner[@"controls"];
    CHECK(valid.count == 2);
    CHECK(near([valid[@"A"][@"x"] doubleValue], 0));
    CHECK(near([valid[@"A"][@"y"] doubleValue], 1));
    CHECK(near([valid[@"A"][@"scale"] doubleValue], 1.8));
    CHECK(near([valid[@"Y"][@"scale"] doubleValue], .5));
    dm_touch_save_profile(@"outer", @{@"controls": @{}});
    CHECK(!dm_touch_has_custom_layout(@"outer"));
    CHECK(near([dm_touch_profile_settings(@"outer")[@"leftSensitivity"] doubleValue], 1.4));
    dm_touch_reset_profile(@"inner");
    CHECK([dm_touch_profile_settings(@"inner") isEqualToDictionary:dm_touch_default_profile_settings()]);
    CHECK(near([dm_touch_profile_settings(@"folded")[@"opacity"] doubleValue], .4));
    snapshot = [memory.values copy];
    (void)dm_touch_default_profile_settings();
    CHECK([snapshot isEqualToDictionary:memory.values]);

    [memory setObject:@"folded" forKey:@"DmTouchDisplayMode"];
    int before = notifications;
    dm_touch_set_active_profile(@"inner");
    CHECK([dm_touch_active_profile() isEqualToString:@"inner"]);
    CHECK(notifications == before + 1);
    dm_touch_set_active_profile(@"inner");
    dm_touch_set_active_profile(@"automatic");
    CHECK(notifications == before + 1);
    CHECK([[memory objectForKey:@"DmTouchDisplayMode"] isEqualToString:@"folded"]);
    CHECK([dm_touch_active_profile() isEqualToString:@"inner"]);

    CHECK(near(dm_touch_axis_strength(.1, .1, 1), 0));
    CHECK(near(dm_touch_axis_strength(.8, .1, 1), 1));
    CHECK(near(dm_touch_axis_strength(.45, .1, 1), .5));
    CHECK(near(dm_touch_axis_strength(.45, .1, 2), sqrt(.5)));
    CHECK(near(dm_touch_axis_strength(.45, .1, .25), .0625));
    CHECK(near(dm_touch_axis_strength(0, 0, 2.5), 0));
    CHECK(near(dm_touch_axis_strength(.4, .4, 2.5), 0));
    CHECK(near(dm_touch_axis_strength(NAN, .1, 1), 0));
    CHECK(near(dm_touch_axis_strength(INFINITY, .1, 1), 0));
    CHECK(near(dm_touch_axis_strength(.45, NAN, NAN), .5));
    for (float sensitivity = .25; sensitivity < 2.51; sensitivity += .25) {
        CHECK(near(dm_touch_axis_strength(.8, .1, sensitivity), 1));
        CHECK(near(dm_touch_axis_strength(1, .1, sensitivity), 1));
        CHECK(near(dm_touch_axis_strength(.1, .1, sensitivity), 0));
        float last = 0;
        for (int i = 0; i <= 100; i++) {
            float value = dm_touch_axis_strength(i / 100.0f, .1f, sensitivity);
            CHECK(isfinite(value) && value >= last && value >= 0 && value <= 1);
            last = value;
        }
    }
    float previous = 0;
    for (int i = 0; i <= 1000; i++) {
        float value = dm_touch_axis_strength(i / 1000.0f, .4f, 2.5f);
        CHECK(isfinite(value) && value >= previous && value >= 0 && value <= 1);
        previous = value;
    }
    CGRect bounds = CGRectMake(10, 20, 200, 100);
    CGSize half = CGSizeMake(30, 20);
    CGPoint center = dm_touch_clamped_center(CGPointMake(-2, 5), bounds, half);
    CHECK(near(center.x, 40) && near(center.y, 100));
    center = dm_touch_clamped_center(CGPointMake(NAN, INFINITY), bounds, half);
    CHECK(near(center.x, 110) && near(center.y, 70));
    half = dm_touch_fitted_half_extent(CGSizeMake(300, 100), bounds);
    CHECK(near(half.width, 100) && near(half.height, 100.0/3));
    center = dm_touch_clamped_center(CGPointMake(0, 1), bounds, half);
    CHECK(center.x-half.width >= CGRectGetMinX(bounds)-1e-6 && center.x+half.width <= CGRectGetMaxX(bounds)+1e-6);
    CHECK(center.y-half.height >= CGRectGetMinY(bounds)-1e-6 && center.y+half.height <= CGRectGetMaxY(bounds)+1e-6);
    half = dm_touch_fitted_half_extent(CGSizeMake(30, 20), CGRectZero);
    CHECK(near(half.width, 0) && near(half.height, 0));
    center = dm_touch_clamped_center(CGPointMake(.5, .5), CGRectNull, CGSizeMake(30, 20));
    CHECK(isfinite(center.x) && isfinite(center.y));

    // Legacy 2D/3D/Tap choices must not leak between outer, inner and folded profiles.
    snapshot = [memory.values copy];
    CHECK(dm_touch_layout_style(@"outer", 1) == 1);
    CHECK(dm_touch_layout_style(@"inner", 0) == 0);
    CHECK([snapshot isEqualToDictionary:memory.values]);
    [memory setObject:@0 forKey:@"DmPadLayout"];
    CHECK(dm_touch_layout_style(@"outer", 1) == 0);
    CHECK(dm_touch_layout_style(@"inner", 1) == 0);
    CHECK(dm_touch_layout_style(@"folded", 1) == 0);
    before = notifications;
    dm_touch_save_layout_style(@"outer", 1);
    CHECK(notifications == before + 1);
    CHECK(dm_touch_layout_style(@"outer", 0) == 1);
    CHECK(dm_touch_layout_style(@"inner", 1) == 0);
    dm_touch_save_layout_style(@"inner", 2);
    dm_touch_save_layout_style(@"folded", 0);
    CHECK(dm_touch_layout_style(@"outer", 0) == 1);
    CHECK(dm_touch_layout_style(@"inner", 1) == 2);
    CHECK(dm_touch_layout_style(@"folded", 1) == 0);
    CHECK([[memory objectForKey:@"DmPadLayout"] isEqual:@0]);
    [memory setObject:@2 forKey:@"DmPadLayout"];
    CHECK(dm_touch_layout_style(@"outer", 0) == 1);
    CHECK(dm_touch_layout_style(@"inner", 1) == 2);
    CHECK(dm_touch_layout_style(@"folded", 1) == 0);
    dm_touch_save_layout_style(@"inner", 0);
    CHECK(dm_touch_layout_style(@"outer", 0) == 1);
    CHECK(dm_touch_layout_style(@"inner", 1) == 0);
    CHECK(dm_touch_layout_style(@"folded", 1) == 0);
    CHECK([[memory objectForKey:@"DmTouchDisplayMode"] isEqual:@"folded"]);
    snapshot = [memory.values copy]; before = notifications;
    dm_touch_save_layout_style(@"outer", 1);
    dm_touch_save_layout_style(@"invalid", 1);
    dm_touch_save_layout_style(@"outer", -1);
    dm_touch_save_layout_style(@"outer", 3);
    CHECK(notifications == before);
    CHECK([snapshot isEqualToDictionary:memory.values]);
    [memory setObject:@"2" forKey:@"DmPadLayout.inner"];
    CHECK(dm_touch_layout_style(@"inner", 1) == 1);
    [memory setObject:@.5 forKey:@"DmPadLayout.inner"];
    CHECK(dm_touch_layout_style(@"inner", 1) == 1);
    [memory setObject:@(NAN) forKey:@"DmPadLayout.inner"];
    CHECK(dm_touch_layout_style(@"inner", 1) == 1);
    [memory setObject:@YES forKey:@"DmPadLayout.inner"];
    CHECK(dm_touch_layout_style(@"inner", 1) == 1);
    CHECK(dm_touch_layout_style(@"invalid", 2) == 2);
    CHECK(dm_touch_layout_style(@"invalid", -9) == 1);
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    method_setImplementation(method, original);
    printf("touch_config: %d checks passed; preferences remained in memory only\n", checks);
    return 0;
} }
