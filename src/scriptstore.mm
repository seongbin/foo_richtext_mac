#import "stdafx.h"
#import "scriptstore.h"
#import "guids.h"

@implementation RTScriptStore

static NSMutableSet<NSString *> * g_liveKeys;   // all currently-alive panel keys
static NSInteger g_liveIdless = 0;              // alive id-less panels in build
static NSInteger g_nextSlotIndex = 0;           // next auto-slot index in build
static BOOL g_needSlotReset = NO;               // a release happened -> reset ordinal next acquire
static int g_reconcileEpoch = 0;                // bumps each debounce; stale blocks ignored
static NSMutableDictionary<NSString *, NSString *> * s_cachedMap;  // lazily populated, invalidated on mutations
static NSString * s_cachedDefaultScript;        // lazily populated, invalidated on mutations

+ (void)initialize {
    if (self == [RTScriptStore class]) {
        g_liveKeys = [NSMutableSet new];
    }
}

#pragma mark - JSON load/save helpers

+ (void)invalidateCache {
    s_cachedMap = nil;
    s_cachedDefaultScript = nil;
}

// JSON object -> NUL-terminated cfg_string write, shared by the three save
// paths (map/slots/layout). cfg_string needs a C string, so the JSON data is
// decoded to NSString and stored via UTF8String.
+ (void)persistJSON:(id)obj toCfg:(cfg_string &)cfg clearCache:(BOOL)clearCache {
    NSError * err = nil;
    NSData * data = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:&err];
    if (err || !data) return;
    NSString * s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) return;
    cfg = s.UTF8String;
    if (clearCache) s_cachedMap = nil;
}

+ (NSMutableDictionary<NSString *, NSString *> *)loadMap {
    if (s_cachedMap) return s_cachedMap;
    NSData * data = [@(( g_richtext_overrides.get().c_str() )) dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) { s_cachedMap = [NSMutableDictionary new]; return s_cachedMap; }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
    if (![obj isKindOfClass:[NSDictionary class]]) { s_cachedMap = [NSMutableDictionary new]; return s_cachedMap; }
    s_cachedMap = [NSMutableDictionary dictionaryWithDictionary:obj];
    return s_cachedMap;
}

+ (void)saveMap:(NSDictionary<NSString *, NSString *> *)map {
    [self persistJSON:map toCfg:g_richtext_overrides clearCache:YES];
}

// The ordered list of auto-slot names, assigned to id-less panels by ordinal.
+ (NSMutableArray<NSString *> *)loadSlots {
    NSData * data = [@(( g_richtext_slots.get().c_str() )) dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr] : nil;
    if (![obj isKindOfClass:[NSArray class]]) return [NSMutableArray new];
    return [NSMutableArray arrayWithArray:obj];
}

+ (void)saveSlots:(NSArray<NSString *> *)slots {
    [self persistJSON:slots toCfg:g_richtext_slots clearCache:NO];
}

// Persisted snapshot of the keys present in the last settled layout.
+ (NSArray<NSString *> *)loadLayoutKeys {
    NSData * data = [@(( g_richtext_layout.get().c_str() )) dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr] : nil;
    if (![obj isKindOfClass:[NSArray class]]) return @[];
    return [NSArray arrayWithArray:obj];
}

+ (void)saveLayoutKeys:(NSArray<NSString *> *)keys {
    [self persistJSON:keys toCfg:g_richtext_layout clearCache:NO];
}

#pragma mark - panel lifecycle

+ (NSString *)acquireKeyForID:(NSString *)panelID {
    NSString * key;
    if (panelID.length > 0) {
        key = panelID;
    } else {
        NSMutableArray<NSString *> * slots = [self loadSlots];
        if (g_needSlotReset) {           // a previous build released panels; restart ordinal
            g_needSlotReset = NO;
            g_nextSlotIndex = 0;
        }
        NSInteger idx = g_nextSlotIndex;
        if (idx < (NSInteger)slots.count) {
            key = slots[idx];            // reuse the slot bound to this ordinal
        } else {
            key = [NSString stringWithFormat:@"#%ld", (long)slots.count];
            [slots addObject:key];
            [self saveSlots:slots];
        }
        g_nextSlotIndex++;
        g_liveIdless++;
    }
    [g_liveKeys addObject:key];
    [self scheduleReconcile];
    return key;
}

+ (void)releaseKey:(NSString *)key {
    if (key.length == 0) return;
    [g_liveKeys removeObject:key];
    if ([key hasPrefix:@"#"]) {
        if (g_liveIdless > 0) g_liveIdless--;
        g_needSlotReset = YES;           // a panel was released -> next acquire restarts ordinal
    }
}

#pragma mark - reconciliation (purge removed panels' configs)

// Debounced after each panel is created.
+ (void)scheduleReconcile {
    int epoch = ++g_reconcileEpoch;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (epoch != g_reconcileEpoch) return; // superseded by a newer build
        [self reconcileLayout];
    });
}

+ (void)reconcileLayout {
    NSArray<NSString *> * current = [[g_liveKeys allObjects] sortedArrayUsingSelector:@selector(compare:)];
    if (current.count == 0) return;
    [self saveLayoutKeys:current];
    [self purgeConfigsNotIn:current];
}

+ (void)purgeUnloadedConfigs {
    NSArray<NSString *> * expected = [self loadLayoutKeys];
    g_richtext_script = richtext_default_script(); // new panels use config.cpp template
    s_cachedDefaultScript = nil;
    if (expected.count == 0) return; // no snapshot yet -> can't tell, keep everything
    [self purgeConfigsNotIn:expected];
}

+ (void)purgeConfigsNotIn:(NSArray<NSString *> *)layoutKeys {
    NSMutableSet<NSString *> * kept = [NSMutableSet setWithArray:layoutKeys];
    NSMutableSet<NSString *> * dead = [NSMutableSet new];
    for (NSString * key in [self loadMap])   if (![kept containsObject:key] && ![dead containsObject:key]) [dead addObject:key];
    for (NSString * key in [self loadSlots]) if (![kept containsObject:key] && ![dead containsObject:key]) [dead addObject:key];
    if (dead.count == 0) return;
    for (NSString * key in dead) [self destroyConfigForKey:key];
}

+ (void)destroyConfigForKey:(NSString *)key {
    NSMutableDictionary<NSString *, NSString *> * map = [self loadMap];
    if (map[key]) { [map removeObjectForKey:key]; [self saveMap:map]; }
}

#pragma mark - script access

+ (NSString *)defaultScript {
    if (!s_cachedDefaultScript) s_cachedDefaultScript = @( g_richtext_script.get().c_str() );
    return s_cachedDefaultScript;
}

+ (NSString *)scriptForID:(NSString *)scriptID {
    if (scriptID.length == 0) return [self defaultScript];
    return [self loadMap][scriptID] ?: [self defaultScript];
}

+ (void)setScript:(NSString *)script forID:(NSString *)scriptID {
    if (scriptID.length == 0) {
        g_richtext_script = [script UTF8String];
        s_cachedDefaultScript = nil;
        return;
    }
    NSMutableDictionary * map = [self loadMap];
    map[scriptID] = script ?: @"";
    [self saveMap:map];
}

+ (void)removeScriptForID:(NSString *)scriptID {
    if (scriptID.length == 0) {
        g_richtext_script = richtext_default_script();
        s_cachedDefaultScript = nil;
        return;
    }
    NSMutableDictionary * map = [self loadMap];
    [map removeObjectForKey:scriptID];
    [self saveMap:map];
}

@end
