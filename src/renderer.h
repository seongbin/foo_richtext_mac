#pragma once
#include "stdafx.h"
#import "parser.h"
#import "artloader.h"

extern NSString * const kRTLinkScheme;

NSString * RTInjectColorTokens(NSString * expr, trackRef track);
void RTAppendColorSpans(NSMutableAttributedString * out, NSString * s,
                        NSDictionary<NSAttributedStringKey, id> * baseAttrs);

// Drops the per-track titleformat evaluation cache entry owned by #track
// (path|subsong). Called from the metadb subscriber when foobar2000 rewrites
// a track's tags (play-count bump, tag edit...) so %title% etc. re-evaluates
// against the fresh metadb handle on the next render.
void RTInvalidateEvalCacheForTrack(trackRef track);

@interface RTArtCache : NSObject
+ (instancetype)shared;
- (NSImage *)get:(NSString *)key;
- (void)put:(NSString *)key image:(NSImage *)image;
- (BOOL)markPending:(NSString *)key;
@property (readonly) NSCache<NSString *, NSFont *> *fontCache;
@property (readonly) NSCache<NSString *, NSImage *> *composedCache;
@end

@interface RTRenderer : NSObject
+ (NSString *)artCacheKey:(trackRef)track name:(NSString *)artName;
+ (BOOL)artGUIDForName:(NSString *)artName out:(GUID *)out;
// Renders the parsed layout. On return artRangeOut (if non-null) receives the
// character range of the first text attachment in the result (artwork), or
// {NSNotFound, 0} when there is none - so callers need not rescan the storage.
+ (NSAttributedString *)renderLines:(NSArray<RTLine *> *)lines
                              track:(trackRef)track
                       commandTable:(NSMutableDictionary<NSString *, NSString *> *)commandTable
                           darkMode:(BOOL)darkMode
                         maxWidth:(CGFloat)maxWidth
                        maxHeight:(CGFloat)maxHeight
                  backgroundMode:(int)backgroundMode
                   defaultTextColor:(NSColor *)defaultTextColor
               defaultBackgroundColor:(NSColor *)defaultBackgroundColor
                    defaultFontSize:(double)defaultFontSize
                     defaultFontName:(NSString *)defaultFontName
                       loadHandler:(void (^)(NSString *artName))loadHandler
                        artRangeOut:(NSRange *)artRangeOut;
@end
