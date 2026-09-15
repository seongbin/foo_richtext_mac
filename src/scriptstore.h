#pragma once
#include "stdafx.h"

// Per-instance script storage
@interface RTScriptStore : NSObject
+ (NSString *)acquireKeyForID:(NSString *)scriptID;
+ (void)releaseKey:(NSString *)key;
+ (void)purgeUnloadedConfigs;
+ (NSString *)defaultScript;
+ (NSString *)scriptForID:(NSString *)scriptID;
+ (void)setScript:(NSString *)script forID:(NSString *)scriptID;
+ (void)removeScriptForID:(NSString *)scriptID; // revert to default
@end
