// Per-app reflection preferences and a transient editor draft, independent of touch profiles.
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDictionary<NSString *, id> *dm_reflection_default_settings(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *dm_reflection_normalize_settings(id _Nullable settings);

@interface DmReflectionPreferences : NSObject
- (instancetype)init;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
// Untouched fields follow the latest persisted settings even during editing;
// edited fields preview the draft. Reading never writes preferences.
@property(nonatomic, readonly, copy) NSDictionary<NSString *, id> *currentSettings;
@property(nonatomic, readonly) BOOL editing;
// Main-thread mutations only. No preferences are written until a save.
- (void)beginEditing;
- (void)updateDraft:(NSDictionary<NSString *, id> *)settings;
- (void)resetDraft;
- (void)endEditingSaving:(BOOL)save;
@end

NS_ASSUME_NONNULL_END
