#import "DmReflectionPreferences.h"
#import "DmControlReflection.h"
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

static NSString *const reflectionSettingsKey = @"DmControlReflectionSettingsV1";
static NSString *const reflectionEnabledKey = @"DmControlReflectionEnabled";

NSDictionary<NSString *, id> *dm_reflection_default_settings(void) {
    return @{@"enabled": @YES, @"brightness": @1, @"length": @1, @"blur": @1,
             @"feather": @12, @"curve": @"bezier", @"angleLinked": @YES};
}

static NSNumber *reflection_number(id value, double fallback, double low, double high) {
    if (![value isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        || !isfinite([value doubleValue])) return @(fallback);
    return @(fmin(high, fmax(low, [value doubleValue])));
}

static NSNumber *reflection_boolean(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        double number = [value doubleValue];
        if (isfinite(number) && (number == 0 || number == 1)) return @([value boolValue]);
    }
    return @YES;
}

NSDictionary<NSString *, id> *dm_reflection_normalize_settings(id settings) {
    NSDictionary *values = [settings isKindOfClass:NSDictionary.class] ? settings : @{};
    id curve = values[@"curve"];
    if (![curve isKindOfClass:NSString.class] || ![@[@"linear", @"smooth", @"bezier"] containsObject:curve]) curve = @"bezier";
    return @{@"enabled": reflection_boolean(values[@"enabled"]),
             @"brightness": reflection_number(values[@"brightness"], 1, 0, 1),
             @"length": reflection_number(values[@"length"], 1, .25, 3),
             @"blur": reflection_number(values[@"blur"], 1, 0, 1),
             @"feather": reflection_number(values[@"feather"], 12, 0, 40),
             @"curve": [curve copy], @"angleLinked": reflection_boolean(values[@"angleLinked"])};
}

@implementation DmReflectionPreferences {
    NSUserDefaults *_defaults;
    NSDictionary *_draft;
    NSMutableSet<NSString *> *_dirtyKeys;
    BOOL _editing;
}

- (instancetype)init { return [self initWithDefaults:NSUserDefaults.standardUserDefaults]; }
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    NSParameterAssert(defaults != nil);
    if ((self = [super init])) _defaults = defaults;
    return self;
}
- (BOOL)editing { return _editing; }
- (NSDictionary *)persistedSettings {
    id stored = [_defaults objectForKey:reflectionSettingsKey];
    NSMutableDictionary *values = [[stored isKindOfClass:NSDictionary.class] ? stored : @{} mutableCopy];
    // The existing master switch remains authoritative, including when the new
    // parameter dictionary is absent or an older dictionary contains that key.
    id enabled = [_defaults objectForKey:reflectionEnabledKey];
    if (enabled) values[@"enabled"] = enabled; else [values removeObjectForKey:@"enabled"];
    return dm_reflection_normalize_settings(values);
}
- (NSDictionary<NSString *, id> *)currentSettings {
    NSMutableDictionary *values = [[self persistedSettings] mutableCopy];
    if (_editing) for (NSString *key in _dirtyKeys) values[key] = _draft[key];
    return dm_reflection_normalize_settings(values);
}
- (void)changed {
    [NSNotificationCenter.defaultCenter postNotificationName:DmControlReflectionDidChangeNotification object:self];
}
- (void)beginEditing {
    NSAssert(NSThread.isMainThread, @"Reflection drafts belong to the main thread");
    if (_editing) return;
    _draft = [self persistedSettings];
    _dirtyKeys = [NSMutableSet set]; _editing = YES;
    [self changed];
}
- (void)updateDraft:(NSDictionary<NSString *, id> *)settings {
    NSAssert(NSThread.isMainThread, @"Reflection drafts belong to the main thread");
    if (!_editing || ![settings isKindOfClass:NSDictionary.class]) return;
    NSDictionary *before = self.currentSettings;
    NSMutableDictionary *values = [before mutableCopy];
    BOOL supplied = NO;
    for (NSString *key in dm_reflection_default_settings()) {
        if (settings[key] == nil) continue;
        values[key] = settings[key]; [_dirtyKeys addObject:key]; supplied = YES;
    }
    if (!supplied) return;
    _draft = dm_reflection_normalize_settings(values);
    if (![_draft isEqualToDictionary:before]) [self changed];
}
- (void)resetDraft {
    NSAssert(NSThread.isMainThread, @"Reflection drafts belong to the main thread");
    if (!_editing) return;
    _draft = dm_reflection_default_settings();
    _dirtyKeys = [NSMutableSet setWithArray:_draft.allKeys];
    [self changed];
}
- (void)endEditingSaving:(BOOL)save {
    NSAssert(NSThread.isMainThread, @"Reflection drafts belong to the main thread");
    if (!_editing) return;
    NSDictionary *values = self.currentSettings;
    NSSet<NSString *> *dirty = [_dirtyKeys copy];
    // End the draft before persistence and notification can synchronously reenter.
    _editing = NO; _draft = nil; _dirtyKeys = nil;
    if (save && dirty.count) {
        if ([dirty containsObject:@"enabled"])
            [_defaults setObject:values[@"enabled"] forKey:reflectionEnabledKey];
        if (dirty.count > ([dirty containsObject:@"enabled"] ? 1u : 0u)) {
            NSMutableDictionary *parameters = [values mutableCopy];
            [parameters removeObjectForKey:@"enabled"];
            [_defaults setObject:[parameters copy] forKey:reflectionSettingsKey];
        }
    }
    [self changed];
}
@end
