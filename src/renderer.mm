#import "stdafx.h"
#import "renderer.h"
#import "parser.h"
#import "artloader.h"
#import <CoreImage/CoreImage.h>

NSString * const kRTLinkScheme = @"fb2krich://cmd/";

#pragma mark - Art cache

@implementation RTArtCache {
    NSCache<NSString *, NSImage *> *_cache;
    NSCache<NSString *, NSFont *> *_fontCache;
    NSCache<NSString *, NSImage *> *_composedCache;
    NSMutableSet<NSString *> *_pending;
    NSMutableDictionary<NSString *, NSDate *> *_failed; // negative-cache timestamps
    NSLock *_lock;
}
+ (instancetype)shared {
    static RTArtCache *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RTArtCache new]; });
    return s;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [NSCache new];
        _cache.countLimit = 128;
        _pending = [NSMutableSet new];
        _failed = [NSMutableDictionary new];
        _lock = [NSLock new];
        _fontCache = [NSCache new];
        _fontCache.countLimit = 128;
        _composedCache = [NSCache new];
        _composedCache.countLimit = 64;
    }
    return self;
}
- (NSCache<NSString *, NSFont *> *)fontCache {
    return _fontCache;
}
- (NSCache<NSString *, NSImage *> *)composedCache {
    return _composedCache;
}
- (NSImage *)get:(NSString *)key {
    [_lock lock];
    NSImage * img = [_cache objectForKey:key];
    // tiny images are failure markers; expire after 30s so we retry later
    NSDate * failedAt = _failed[key];
    if (img && failedAt && -[failedAt timeIntervalSinceNow] > 30.0) {
        [_cache removeObjectForKey:key];
        [_failed removeObjectForKey:key];
        img = nil;
    }
    [_lock unlock];
    return img;
}
- (void)put:(NSString *)key image:(NSImage *)image {
    [_lock lock];
    [_cache setObject:image forKey:key];
    [_pending removeObject:key];
    BOOL isFailure = image.size.width <= 16.0 && image.size.height <= 16.0;
    if (isFailure) _failed[key] = [NSDate date];
    else [_failed removeObjectForKey:key];
    [_lock unlock];
}
- (BOOL)markPending:(NSString *)key {
    [_lock lock];
    BOOL fresh = ![_pending containsObject:key];
    if (fresh) [_pending addObject:key];
    [_lock unlock];
    return fresh;
}
@end

static NSString * ArtCacheKey(trackRef track, NSString * artName) {
    if ( track.is_empty() ) return nil;
    return [NSString stringWithFormat:@"%s|%@|%u", track->get_path(), artName,
            (unsigned)track->get_location().get_subsong_index()];
}

#pragma mark - Titleformat evaluation

namespace {

class TFScriptCache {
    pfc::map_t<pfc::string8, titleformat_object::ptr> m_map;
public:
    titleformat_object::ptr get(const char * scriptText) {
        titleformat_object::ptr * found = m_map.query_ptr(scriptText);
        if (found) return *found;
        titleformat_compiler::ptr comp = titleformat_compiler::get();
        titleformat_object::ptr obj;
        if (!comp.is_valid() || !comp->compile(obj, scriptText)) return nullptr;
        m_map.set(scriptText, obj);
        return obj;
    }
};

TFScriptCache & TFCache() { static TFScriptCache c; return c; }

static NSString * EvaluateCompiledTF(NSString * fallback, titleformat_object::ptr script,
                                    trackRef track) {
    @try {
        std::shared_ptr<pfc::string8> out = std::make_shared<pfc::string8>();
        if (!script.is_valid()) return fallback;
        if ( track.is_empty() ) return @"";
        // Playback pseudo-fields (%playback_time% / %playback_time_seconds% /
        // %playback_time_remaining% / %playback_time_remaining_seconds%) only
        // resolve in the playback context, so format via play_control when the
        // item is (or may be) the currently playing track.
        try {
            play_control::ptr pc = play_control::get();
            if ( pc.is_valid() )
                pc->playback_format_title_ex( track, nullptr, *out, script, nullptr,
                                              playback_control::display_level_all );
            else
                trackFormatTitle( track, nullptr, *out, script, nullptr );
        } catch ( ... ) {
            trackFormatTitle( track, nullptr, *out, script, nullptr );
        }
        return fb2k::strToPlatform( out->c_str() ) ?: @"";
    } @catch (NSException *e) { (void)e; return fallback; }
}

NSString * EvaluateTF(NSString * text, trackRef track) {
    return EvaluateCompiledTF(text, TFCache().get([text UTF8String]), track);
}

static NSString * EvaluateTFWithFallback(NSString * text, NSString * fallback,
                                         trackRef track) {
    titleformat_object::ptr script = TFCache().get([text UTF8String]);
    if (script.is_valid()) return EvaluateCompiledTF(text, script, track);
    if ([text isEqualToString:fallback]) return fallback;
    return EvaluateCompiledTF(fallback, TFCache().get([fallback UTF8String]), track);
}

// Stable identity of a track (path + subsong index), used to key evaluation
// caches. Reuses the same formatting as ArtCacheKey minus the art name.
// foobar2000 notifies metadb_io_callback::on_changed_sorted() whenever any
// track's tags/metadb contents are rewritten — regardless of playback state —
// e.g. the Playback Statistics play-count bump or a tag edit. Each changed
// item is resolved back to its per-track cache key (path|subsong, same as
// TrackKey) and the entry is dropped so the next render re-evaluates
// %play_count%/%title%/etc. against the fresh metadb handle.
// Something rewrote this track's tags/metadb contents (play-count bump, tag
// edit...); the cached render of %title%/%play_count%/etc. is stale. Declaration
// of the per-track cache key and eval cache so the invalidator below compiles
// regardless of where their definitions live in this file (they appear later,
// next to RTEvaluateCached which also consumes them).
static NSString * TrackKey(trackRef track);
static NSCache<NSString *, NSMutableDictionary<NSString *, NSString *> *> * TFEvalCache();

// Expression contains a token that depends on live playback/volume state.
// Such expressions must be re-evaluated every render; everything else (e.g.
// %artist%, %title%) evaluates identically while the track is unchanged and
// can be cached. This list is deliberately conservative: missing a volatile
// marker only disables caching, never serves stale text.
static BOOL RTExprIsVolatile(NSString * expr) {
    static NSArray<NSString *> * volatileMarks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        volatileMarks = @[ @"$volume", @"%playback_time", @"%isplaying",
                           @"%is_paused", @"%is_stopped", @"%volume", @"%_time_" ];
    });
    for (NSString * mark in volatileMarks)
        if ([expr containsString:mark]) return YES;
    return NO;
}

// Evaluation cache: static expressions keyed per track so %artist%/%title%/
// etc. are re-formatted only when the track changes, not on every render.
// Keyed by track -> {expression : rendered string} (an NSCache of mutable
// dictionaries; the per-track dict is bounded by the script's expression set).
static NSCache<NSString *, NSMutableDictionary<NSString *, NSString *> *> * TFEvalCache() {
    static NSCache * c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSCache new];
        c.countLimit = 64; // ~64 recent tracks
    });
    return c;
}

// Stable identity of a track (path + subsong index), same key used by the
// per-track evaluation cache and by RTInvalidateEvalCacheForTrack().
static NSString * TrackKey(trackRef track) {
    if ( track.is_empty() ) return nil;
    return [NSString stringWithFormat:@"%s|%u", track->get_path(),
            (unsigned)track->get_location().get_subsong_index()];
}

static NSString * RTEvaluateCached(NSString * expr, trackRef track,
                                   NSString * fallback) {
    if (RTExprIsVolatile(expr)) return EvaluateTFWithFallback(expr, fallback, track);
    NSString * tKey = TrackKey(track);
    if (!tKey) return EvaluateTFWithFallback(expr, fallback, track);
    NSCache * cache = TFEvalCache();
    NSMutableDictionary * perTrack = [cache objectForKey:tKey];
    if (!perTrack) {
        perTrack = [NSMutableDictionary new];
        [cache setObject:perTrack forKey:tKey];
    }
    NSString * cached = perTrack[expr];
    if (cached) return cached;
    NSString * result = EvaluateTFWithFallback(expr, fallback, track);
    if (result) perTrack[expr] = result;
    return result;
}

// Paren matching (nesting + quoted literals) lives in parser.mm as
// findMatchingParen; declared in parser.h and reused by the colour token
// injection below.

}

void RTInvalidateEvalCacheForTrack(trackRef track) {
    if ( track.is_empty() ) return;
    NSCache * cache = TFEvalCache();
    [cache removeObjectForKey:[NSString stringWithFormat:
                               @"%s|%u", track->get_path(),
                               (unsigned)track->get_location().get_subsong_index()]];
}

#pragma mark - Conditional colours ($rgb inside titleformat expressions)

// Printable-ASCII markers: private-use unicode chars get rejected by
// fb2k's titleformat compiler ("Invalid syntax"). "@@" collisions with
// real titles are vanishingly rare and only ever cost a wrong colour.
static NSString * const kRTColorOpenMark = @"@@RTC:";
static NSString * const kRTColorCloseMark = @"@@";

static BOOL IsDigitString(NSString * s) {
    // optional leading sign so bad values get clamped instead of skipped
    NSUInteger start = (s.length > 0 && [s characterAtIndex:0] == '-') ? 1 : 0;
    if (s.length <= start) return NO;
    for (NSUInteger i = start; i < s.length; ++i) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

static int ClampColorVal(int v) {
    if (v < 0) v = 0;
    if (v > 255) v = 255;
    return v;
}

static NSCharacterSet * WSChars() {
    static NSCharacterSet * ws;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ws = [NSCharacterSet whitespaceCharacterSet]; });
    return ws;
}

static NSCharacterSet * WSAndNewlineChars() {
    static NSCharacterSet * ws;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ws = [NSCharacterSet whitespaceAndNewlineCharacterSet]; });
    return ws;
}

// Case-insensitive "$rgb" occupying exactly positions pos..pos+3, with '(' at pos+4.
static BOOL IsRGBAt(NSString * s, NSUInteger pos) {
    if (pos + 5 > s.length || [s characterAtIndex:pos + 4] != '(') return NO;
    unichar b[4];
    [s getCharacters:b range:NSMakeRange(pos, 4)];
    if (b[0] != '$') return NO;
    for (NSUInteger k = 1; k < 4; ++k) {
        unichar lower = (k == 1) ? 'r' : (k == 2) ? 'g' : 'b';
        if (b[k] != lower && b[k] != (unichar)(lower - 32)) return NO;
    }
    return YES;
}

// Parses exactly 6 hex digits into a 24-bit value; returns NO on any non-hex char.
static BOOL ParseHex6(NSString * s, unsigned int * out) {
    unsigned int v = 0;
    for (NSUInteger k = 0; k < 6; ++k) {
        unichar c = [s characterAtIndex:k];
        int d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else return NO;
        v = (v << 4) | (unsigned)d;
    }
    *out = v;
    return YES;
}

static NSString * Expand3Hex(NSString * s) {
    unichar a = [s characterAtIndex:0], b = [s characterAtIndex:1], c = [s characterAtIndex:2];
    unichar buf[6] = { a, a, b, b, c, c };
    return [NSString stringWithCharacters:buf length:6];
}

// One $rgb argument: literal number, or a titleformat expression whose
// evaluation yields a number (e.g. $mod($crc32(%album%),256)).
static BOOL ResolveColorArg(NSString * t, trackRef track, int * outV) {
    if (IsDigitString(t)) { *outV = ClampColorVal(t.intValue); return YES; }
    if (t.length == 0 || track.is_empty()) return NO;
    NSString * ev = [EvaluateTF(t, track) stringByTrimmingCharactersInSet:
                     WSChars()];
    if (!IsDigitString(ev)) {
        return NO;
    }
    *outV = ClampColorVal(ev.intValue);
    return YES;
}

// Splits on commas that are outside quotes and not nested in parens.
static NSArray<NSString *> * TopLevelCommaSplit(NSString * s) {
    NSMutableArray<NSString *> * out = [NSMutableArray new];
    NSMutableString * cur = [NSMutableString new];
    NSInteger depth = 0;
    BOOL inSingle = NO, inDouble = NO;
    for (NSUInteger i = 0; i < s.length; ++i) {
        unichar c = [s characterAtIndex:i];
        if (inSingle) {
            [cur appendFormat:@"%C", c];
            if (c == '\'') {
                if (i + 1 < s.length && [s characterAtIndex:i + 1] == '\'') { [cur appendFormat:@"%C", c]; i++; }
                else inSingle = NO;
            }
            continue;
        }
        if (inDouble) { [cur appendFormat:@"%C", c]; if (c == '"') inDouble = NO; continue; }
        if (c == '\'') { inSingle = YES; [cur appendFormat:@"%C", c]; continue; }
        if (c == '"') { inDouble = YES; [cur appendFormat:@"%C", c]; continue; }
        if (c == '(') depth++;
        else if (c == ')') depth--;
        if (c == ',' && depth == 0) {
            // copy! storing cur directly would alias the mutable string
            [out addObject:[NSString stringWithString:cur]];
            [cur setString:@""];
            continue;
        }
        [cur appendFormat:@"%C", c];
    }
    if (cur.length > 0 || out.count > 0)
        [out addObject:[NSString stringWithString:cur]];
    return out;
}

static inline void RTChunkFlush(NSMutableString * out, unichar * chunk,
                                NSUInteger * chunkLen) {
    if (*chunkLen) {
        [out appendString:[NSString stringWithCharacters:chunk length:*chunkLen]];
        *chunkLen = 0;
    }
}

static inline void RTChunkPut(NSMutableString * out, unichar * chunk,
                              NSUInteger * chunkLen, unichar c) {
    if (*chunkLen == 64) RTChunkFlush(out, chunk, chunkLen);
    chunk[(*chunkLen)++] = c;
}

NSString * RTInjectColorTokens(NSString * expr, trackRef track) {
    if (expr.length == 0) return expr;
    // fast path: most expressions contain no $rgb token at all
    if ([expr rangeOfString:@"$rgb" options:NSCaseInsensitiveSearch].location == NSNotFound)
        return expr;
    NSMutableString * out = [NSMutableString stringWithCapacity:expr.length];
    NSUInteger n = expr.length, i = 0;
    BOOL inSingle = NO, inDouble = NO;
    NSCharacterSet * ws = WSChars();
    NSCharacterSet * wsNewline = WSAndNewlineChars();
    // buffer plain characters so we don't message NSString per unichar
    unichar chunk[64];
    NSUInteger chunkLen = 0;
    while (i < n) {
        unichar c = [expr characterAtIndex:i];
        if (inSingle) {
            RTChunkPut(out, chunk, &chunkLen, c);
            if (c == '\'') {
                if (i + 1 < n && [expr characterAtIndex:i + 1] == '\'') { RTChunkPut(out, chunk, &chunkLen, c); i++; }
                else inSingle = NO;
            }
            i++; continue;
        }
        if (c == '\'') { inSingle = YES; RTChunkPut(out, chunk, &chunkLen, c); i++; continue; }
        if (inDouble) {
            RTChunkPut(out, chunk, &chunkLen, c);
            if (c == '"') inDouble = NO;
            i++; continue;
        }
        if (c == '"') { inDouble = YES; RTChunkPut(out, chunk, &chunkLen, c); i++; continue; }

        if (IsRGBAt(expr, i)) {
            NSUInteger close = findMatchingParen(expr, i + 5);
            if (close != NSNotFound) {
                NSString * trimmed = [[expr substringWithRange:NSMakeRange(i + 5, close - (i + 5))]
                                      stringByTrimmingCharactersInSet:wsNewline];
                if (trimmed.length == 0) {
                    // $rgb() resets colour to default
                    RTChunkFlush(out, chunk, &chunkLen);
                    [out appendString:kRTColorOpenMark];
                    [out appendString:kRTColorCloseMark];
                    i = close + 1; continue;
                }
// fast split when no parens/quotes (common case): no nesting to honour
                static NSCharacterSet * splitChars;
                static dispatch_once_t onceSC;
                dispatch_once(&onceSC, ^{
                    splitChars = [NSCharacterSet characterSetWithCharactersInString:@"('\""];
                });
                NSArray<NSString *> * parts;
                if ([trimmed rangeOfCharacterFromSet:splitChars].location == NSNotFound) {
                    parts = [trimmed componentsSeparatedByString:@","];
                } else {
                    parts = TopLevelCommaSplit(trimmed);
                }
                NSMutableArray<NSString *> * vals = [NSMutableArray new];
                BOOL ok = NO;
                if (parts.count == 1) {
                    // single argument: try a hex colour code (e.g. $rgb(FF0436),
                    // #FF0436, or 3-digit shorthand F0A)
                    NSString * hexStr = [parts[0] stringByTrimmingCharactersInSet:ws];
                    if ([hexStr hasPrefix:@"#"]) hexStr = [hexStr substringFromIndex:1];
                    if (hexStr.length == 3) hexStr = Expand3Hex(hexStr);
                    if (hexStr.length == 6) {
                        unsigned int hex = 0;
                        if (ParseHex6(hexStr, &hex)) {
                            [vals addObject:[NSString stringWithFormat:@"%u", (hex >> 16) & 0xFF]];
                            [vals addObject:[NSString stringWithFormat:@"%u", (hex >> 8)  & 0xFF]];
                            [vals addObject:[NSString stringWithFormat:@"%u",  hex        & 0xFF]];
                            ok = YES;
                        }
                    }
                } else if (parts.count >= 3 && parts.count <= 4) {
                    ok = YES;
                    for (NSString * p in parts) {
                        NSString * t = [p stringByTrimmingCharactersInSet:ws];
                        int v;
                        if (!ResolveColorArg(t, track, &v)) { ok = NO; break; }
                        [vals addObject:[NSString stringWithFormat:@"%d", v]];
                    }
                }
                if (ok) {
                    RTChunkFlush(out, chunk, &chunkLen);
                    [out appendString:kRTColorOpenMark];
                    [out appendString:[vals componentsJoinedByString:@","]];
                    [out appendString:kRTColorCloseMark];
                    i = close + 1; continue;
                }
                // dynamic/non-numeric args: leave untouched
            }
        }
        RTChunkPut(out, chunk, &chunkLen, c);
        i++;
    }
    RTChunkFlush(out, chunk, &chunkLen);
    return out;
}

static NSRegularExpression * ColorTokenRegex() {
    static dispatch_once_t once;
    static NSRegularExpression * re;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"@@RTC:([^@]*)@@" options:0 error:nil];
    });
    return re;
}

static void AppendRun(NSMutableAttributedString * out, NSString * chunk,
                      NSDictionary<NSAttributedStringKey, id> * baseAttrs,
                      NSDictionary<NSAttributedStringKey, id> * overlay) {
    if (chunk.length == 0) return;
    NSDictionary * attrs = baseAttrs;
    if (overlay.count > 0) {
        NSMutableDictionary * merged = [baseAttrs mutableCopy];
        [merged addEntriesFromDictionary:overlay];
        attrs = merged;
    }
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:chunk attributes:attrs]];
}

// Strips C0 control characters (fb2k emits private control codes for its
// native $rgb/$font handling; they render as garbage here).
static NSString * StripControlChars(NSString * s) {
    if (s.length == 0) return s;
    static NSCharacterSet * bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet * m = [NSMutableCharacterSet new];
        [m addCharactersInRange:NSMakeRange(0, 9)];       // 0x00-0x08
        [m addCharactersInRange:NSMakeRange(11, 21)];     // 0x0B-0x1F (keep \t=9, \n=10)
        [m addCharactersInRange:NSMakeRange(0x7F, 1)];
        bad = m;
    });
    // fast path: most evaluated text has no control characters at all
    if ([s rangeOfCharacterFromSet:bad].location == NSNotFound) return s;
    // scan unichars once, copying only the keepers
    NSUInteger n = s.length;
    unichar * buf = (unichar *)malloc(n * sizeof(unichar));
    if (!buf) return [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@""];
    NSUInteger outLen = 0;
    for (NSUInteger i = 0; i < n; ++i) {
        unichar c = [s characterAtIndex:i];
        if (c <= 8 || (c >= 11 && c <= 31) || c == 0x7F) continue;
        buf[outLen++] = c;
    }
    NSString * clean = outLen == n
        ? s
        : [[NSString alloc] initWithCharacters:buf length:outLen];
    free(buf);
    return clean;
}

// https://foosion.foobar2000.org/help/foo_textdisplay/1.1_beta_1/foo_textdisplay-titleformat-help.txt
static NSColor * BlendColors(NSColor * a, NSColor * b, double aFrac) {
    NSColor * ca = [a colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    NSColor * cb = [b colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    CGFloat ar = 0, ag = 0, ab = 0, aa = 1;
    CGFloat br = 0, bg = 0, bb = 0, ba = 1;
    [ca getRed:&ar green:&ag blue:&ab alpha:&aa];
    [cb getRed:&br green:&bg blue:&bb alpha:&ba];
    (void)ba;
    return [NSColor colorWithSRGBRed:ar * aFrac + br * (1 - aFrac)
                               green:ag * aFrac + bg * (1 - aFrac)
                                blue:ab * aFrac + bb * (1 - aFrac)
                               alpha:aa * aFrac + 1.0 * (1 - aFrac)];
}

// A dynamic colour that stays appearance-aware: blends the default text
// colour (labelColor) with `target` (either the panel background or the link
// colour) in the effective appearance at draw time.
static NSColor * DimHiliteDynamicColor(double textFrac, NSColor * target,
                                       NSString * nameKey) {
    NSString * name = [@"foo_richtext_dim_" stringByAppendingString:nameKey];
    return [NSColor colorWithName:name dynamicProvider:^NSColor *(NSAppearance *appearance) {
        (void)appearance;
        return BlendColors([NSColor labelColor], target, textFrac);
    }];
}

// System link colour resolved to its dark-appearance value so it renders the
// same in light and dark mode (the user wants the dark-mode link everywhere).
static NSColor * RTLinkColor() {
    static NSColor * c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSAppearance * dark = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        NSAppearance * previous = NSAppearance.currentAppearance;
        NSAppearance.currentAppearance = dark;
        NSColor * darkColor = [[NSColor linkColor] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        NSAppearance.currentAppearance = previous;
        c = darkColor ?: [NSColor linkColor];
    });
    return c;
}

static NSColor * DimHiliteColor(int level, NSColor * defaultTextColor,
                                NSColor * bgColor, NSColor * linkColor) {
    // Artwork background mode supplies explicit colors (mode 2 uses pure white
    // text). Dim levels are the same color with reduced alpha - the dark
    // artwork shows through more with depth of dim - rather than a blend
    // against a second hue, keeping the white constant and readable over the
    // auto-adjusted mask.
    if (defaultTextColor != nil && bgColor != nil) {
        if (level > 0) {
            CGFloat alpha = (level >= 3) ? 0.45 : (level == 2) ? 0.50 : 0.60;
            return [defaultTextColor colorWithAlphaComponent:alpha];
        }
        return defaultTextColor;
    }
    NSColor * bg = bgColor ?: [NSColor textBackgroundColor];
    NSColor * link = linkColor ?: RTLinkColor();
    static NSArray<NSColor *> * cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = @[
            DimHiliteDynamicColor(0.6, bg, @"d1"),
            DimHiliteDynamicColor(0.5, bg, @"d2"),
            DimHiliteDynamicColor(0.4, bg, @"d3"),
            DimHiliteDynamicColor(0.67, link, @"h1"),
            DimHiliteDynamicColor(0.33, link, @"h2"),
            DimHiliteDynamicColor(0.00, link, @"h3"),
        ];
    });
    if (level > 0) {
        if (level >= 3) return cache[2];
        if (level == 2) return cache[1];
        return cache[0];
    }
    if (level >= -3) {
        if (level == -3) return cache[5];
        if (level == -2) return cache[4];
        return cache[3];
    }
    return cache[5]; // <= -4 clamped to strongest highlight
}

// Effective foreground for a segment: its angle-bracket dim/highlight colour
// when set, otherwise `fallback` (the explicit colour or the default).
static NSColor * SegmentColor(int dimLevel, NSColor * fallback,
                              NSColor * defaultTextColor, NSColor * bgColor,
                              NSColor * linkColor) {
    if (dimLevel != 0)
        return DimHiliteColor(dimLevel, defaultTextColor, bgColor, linkColor);
    return fallback;
}

void RTAppendColorSpans(NSMutableAttributedString * out, NSString * s,
                        NSDictionary<NSAttributedStringKey, id> * baseAttrs) {
    if (s.length == 0) return;
    s = StripControlChars(s);
    NSArray<NSTextCheckingResult *> * matches =
        [ColorTokenRegex() matchesInString:s options:0 range:NSMakeRange(0, s.length)];
    if (matches.count == 0) {
        AppendRun(out, s, baseAttrs, nil);
        return;
    }
    NSDictionary * currentColor = nil;
    NSUInteger pos = 0;
    for (NSTextCheckingResult * m in matches) {
        if (m.range.location > pos)
            AppendRun(out, [s substringWithRange:NSMakeRange(pos, m.range.location - pos)],
                      baseAttrs, currentColor);
        NSString * spec = [s substringWithRange:[m rangeAtIndex:1]];
        if (spec.length == 0) {
            currentColor = nil; // $rgb() reset
        } else {
            NSArray * parts = [spec componentsSeparatedByString:@","];
            int r = parts.count > 0 ? ((NSString *)parts[0]).intValue : 0;
            int g = parts.count > 1 ? ((NSString *)parts[1]).intValue : 0;
            int b = parts.count > 2 ? ((NSString *)parts[2]).intValue : 0;
            int a = parts.count > 3 ? ((NSString *)parts[3]).intValue : 255;
            NSColor * col = [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0];
            currentColor = @{ NSForegroundColorAttributeName: col };
        }
        pos = m.range.location + m.range.length;
    }
    if (pos < s.length)
        AppendRun(out, [s substringWithRange:NSMakeRange(pos, s.length - pos)], baseAttrs, currentColor);
}

namespace {

// Matches a remainder consisting only of clock time: optional space/tab or
// ISO 'T' separator, H:MM / HH:MM[:SS[.fraction]], optional timezone
// (Z, +HH, +HHMM, +HH:MM), e.g. " 20:31", "T07:05:09.120+02:00".
static NSRegularExpression * TimeOnlyRemainderRegex() {
    static NSRegularExpression * re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^[ \\tT]*\\d{1,2}:\\d{2}(:\\d{2})?([.,]\\d+)?([ \\t]*(Z|z|[+-]\\d{2}:?\\d{2}))?$"
              options:0 error:nil];
    });
    return re;
}

static NSString * formatLeadingDateUncached(NSString * s);

// Tag values that START with a yyyy-mm-dd date are shown as "Nov 19, 2026"
// (std::put_time "%b %d, %Y"). Trailing clock-time info (e.g. " 20:31",
// "T07:05:09.120+02:00") is dropped; any other trailing text is kept
// verbatim; values that do not parse as a real calendar date pass through.
static NSString * FormatLeadingDate(NSString * s) {
    if (s.length < 10) return s;

    // Deterministic given the input string, so cache the result (date heads
    // repeat across renders for the same tag values).
    static NSCache<NSString *, NSString *> * resultCache;
    static dispatch_once_t onceR;
    dispatch_once(&onceR, ^{
        resultCache = [NSCache new];
        resultCache.countLimit = 256;
    });
    NSString * hit = [resultCache objectForKey:s];
    if (hit) return hit;
    NSString * result = formatLeadingDateUncached(s);
    if (result) [resultCache setObject:result forKey:s]; else result = s;
    return result;
}

static NSString * formatLeadingDateUncached(NSString * s) {
    if (s.length < 10) return s;

    // structural check: ^\d{4}-\d{2}-\d{2}
    static NSCharacterSet * digits;
    static dispatch_once_t onceD;
    dispatch_once(&onceD, ^{
        digits = [NSCharacterSet decimalDigitCharacterSet];
    });
    for (NSUInteger k = 0; k < 10; ++k) {
        unichar c = [s characterAtIndex:k];
        if (k == 4 || k == 7) {
            if (c != '-') return s;
        } else if (![digits characterIsMember:c]) {
            return s;
        }
    }

    static NSDateFormatter * inFmt, * outFmt;
    static dispatch_once_t onceF;
    dispatch_once(&onceF, ^{
        NSLocale * posix = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        inFmt = [NSDateFormatter new];
        inFmt.locale = posix;
        inFmt.dateFormat = @"yyyy-MM-dd";
        inFmt.lenient = NO;
        outFmt = [NSDateFormatter new];
        outFmt.locale = posix;
        outFmt.dateFormat = @"MMM dd, yyyy";
    });

    NSString * head = [s substringToIndex:10];
    NSDate * d = [inFmt dateFromString:head];
    if (!d) return s; // not a valid calendar date (e.g. 2026-13-99)
    if (s.length == 10) return [outFmt stringFromDate:d];

    // drop the remainder when it is only clock-time info
    NSString * rest = [s substringFromIndex:10];
    NSRegularExpression * timeRe = TimeOnlyRemainderRegex();
    return [timeRe firstMatchInString:rest options:0 range:NSMakeRange(0, rest.length)]
        ? [outFmt stringFromDate:d]
        : [NSString stringWithFormat:@"%@%@", [outFmt stringFromDate:d], rest];
}

// Application default font = macOS system font at system size.
static double DefaultFontSize() { return [NSFont systemFontSize]; }

static NSFont * SystemFontWithSize(double size) {
    // size <= 0 -> application default size
    return [NSFont systemFontOfSize:size > 0 ? size : DefaultFontSize()];
}

static BOOL rtIsNumeric(NSString * s) {
    NSScanner * sc = [NSScanner scannerWithString:s];
    double d = 0;
    return [sc scanDouble:&d] && [sc isAtEnd];
}

// Maps a $font weight argument to NSFontWeight. Accepts names
// (thin/light/regular/medium/semibold/bold/heavy/black, ...) or a numeric
// 0..1 value; returns -1 when no weight was requested.
static NSFontWeight ParseWeight(NSString * w) {
    if (w.length == 0) return (NSFontWeight)-1;
    static NSDictionary<NSString *, NSNumber *> * map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{ @"thin": @(NSFontWeightThin),
                 @"ultralight": @(NSFontWeightUltraLight),
                 @"extralight": @(NSFontWeightUltraLight),
                 @"light": @(NSFontWeightLight),
                 @"regular": @(NSFontWeightRegular),
                 @"normal": @(NSFontWeightRegular),
                 @"medium": @(NSFontWeightMedium),
                 @"semibold": @(NSFontWeightSemibold),
                 @"demibold": @(NSFontWeightSemibold),
                 @"bold": @(NSFontWeightBold),
                 @"heavy": @(NSFontWeightHeavy),
                 @"black": @(NSFontWeightBlack) };
    });
    NSNumber * v = map[w.lowercaseString];
    if (v) return v.doubleValue;
    if (rtIsNumeric(w)) return MIN(MAX(w.doubleValue, 0.0), 1.0);
    return (NSFontWeight)-1; // unknown -> no change
}

NSFont * ApplyWeight(NSFont * font, NSString * weightStr) {
    NSFontWeight w = ParseWeight(weightStr);
    if (w < 0 || !font) return font;
    NSMutableDictionary * attributes = [font.fontDescriptor.fontAttributes mutableCopy];
    [attributes removeObjectForKey:NSFontNameAttribute];
    attributes[NSFontFamilyAttribute] = font.familyName;
    NSDictionary * existingTraits = attributes[NSFontTraitsAttribute];
    NSMutableDictionary * traits = existingTraits ? [existingTraits mutableCopy] : [NSMutableDictionary dictionary];
    traits[NSFontWeightTrait] = @(w);
    attributes[NSFontTraitsAttribute] = traits;
    NSFontDescriptor * descriptor = [NSFontDescriptor fontDescriptorWithFontAttributes:attributes];
    return [NSFont fontWithDescriptor:descriptor size:font.pointSize] ?: font;
}

// fontStyle: normal|italic|oblique (nil = unchanged)
static NSFont * ApplyStyle(NSFont * font, NSString * style) {
    if (!font || style.length == 0) return font;
    NSString * s = style.lowercaseString;
    if ([s isEqualToString:@"italic"] || [s isEqualToString:@"oblique"]) {
        return [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSFontItalicTrait];
    }
    return font; // normal / unknown -> no change
}

NSFont * ResolveFont(NSString * name, double size, NSString * weight, NSString * style) {
    double sz = size > 0 ? size : DefaultFontSize();
    // Cache resolved fonts: segments repeatedly resolve the same (name,size,weight,style).
    NSString * cacheKey = name.length ? name : @"*";
    cacheKey = [NSString stringWithFormat:@"%@|%.2f|%@|%@", cacheKey, sz,
                weight ?: @"", style ?: @""];
    NSCache * fontCache = [RTArtCache shared].fontCache;
    NSFont * cached = [fontCache objectForKey:cacheKey];
    if (cached) return cached;
    NSFontWeight w = ParseWeight(weight);
    NSFont * f;
    if (name.length == 0) {
        f = [NSFont systemFontOfSize:sz weight:w >= 0 ? w : NSFontWeightRegular];
    } else {
        f = [NSFont fontWithName:name size:sz];
        if (!f) f = SystemFontWithSize(sz); // unknown name -> app default + weight
        else f = ApplyWeight(f, weight);
    }
    f = ApplyStyle(f, style);
    if (f) [fontCache setObject:f forKey:cacheKey];
    return f;
}

// Per-segment font: an empty explicit $font() name falls back to the panel's
// default family (if set); a zero size falls back to the panel's default size
// (if set) before the hardcoded default.
NSFont * ExplicitFont(NSString * defaultName, double defaultSize, NSString * name, double size,
                      NSString * weight, NSString * style) {
    if (name.length == 0) name = defaultName;
    if (!(size > 0) && defaultSize > 0) size = defaultSize;
    return ResolveFont(name, size, weight, style);
}

NSDictionary * BaseAttrs(NSFont * font, NSColor * color, NSColor * defaultColor, BOOL darkMode) {
    (void)darkMode;
    // Paragraph style depends only on the line height, so cache one per
    // height instead of copying NSParagraphStyle per segment.
    static NSCache<NSNumber *, NSParagraphStyle *> * psCache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        psCache = [NSCache new];
        psCache.countLimit = 32;
    });
    double lh = ceil(font.pointSize * 1.2 + 1.0);
    NSNumber * lhKey = @(lh);
    NSParagraphStyle * ps = [psCache objectForKey:lhKey];
    if (!ps) {
        NSMutableParagraphStyle * mps = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
        [mps setMinimumLineHeight:lh];
        [mps setMaximumLineHeight:lh];
        [mps setLineBreakMode:NSLineBreakByTruncatingTail];
        ps = [mps copy];
        [psCache setObject:ps forKey:lhKey];
    }
    return @{ NSFontAttributeName : font,
              NSForegroundColorAttributeName : (color ?: (defaultColor ?: [NSColor labelColor])),
              NSParagraphStyleAttributeName : ps };
}

static NSDictionary * InlineImageLineAttrs(NSDictionary * attrs, NSFont * font,
                                           CGFloat imageHeight, BOOL hasInlineImage) {
    if (!hasInlineImage) return attrs;
    NSMutableDictionary * centered = [attrs mutableCopy];
    CGFloat textCenter = (font.ascender + font.descender) * 0.5;
    centered[NSBaselineOffsetAttributeName] = @((imageHeight * 0.5) - textCenter);
    return centered;
}

// Corner radius that scales with the artwork card size (~4% capped to a sane
// range), so small boxes stay subtle and large ones keep a natural ratio.
static double RTCornerRadius(double w, double h);

NSImage * PlaceholderImage(double w, double h, BOOL darkMode) {
    NSSize size = NSMakeSize(w, h);
    NSImage * img = [[NSImage alloc] initWithSize:size];
    [img lockFocus];
    NSColor * fill;
    if (darkMode)
        fill = [NSColor colorWithSRGBRed:30.0 / 255.0 green:31.0 / 255.0 blue:34.0 / 255.0 alpha:0.75];
    else
        fill = [NSColor colorWithSRGBRed:234.0 / 255.0 green:235.0 / 255.0 blue:237.0 / 255.0 alpha:0.75];
    [fill setFill];
    double corner = RTCornerRadius(w, h);
    NSBezierPath * box = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, w, h)
                                                        xRadius:corner yRadius:corner];
    [box fill];
    // grow "♫" with the placeholder; non-ASCII draws fine on a flipped image
    CGFloat noteSize = MAX(12.0, MIN(w, h) * 0.35);
    CGFloat noteGray = darkMode ? 0.55 : 0.45;
    NSDictionary * attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:noteSize],
                              NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:noteGray green:noteGray blue:noteGray alpha:1.0] };
    NSSize note = [@"♫" sizeWithAttributes:attrs];
    [@"♫" drawAtPoint:NSMakePoint((w - note.width) * 0.5, (h - note.height) * 0.5) withAttributes:attrs];
    [img unlockFocus];
    return img;
}

// Corner radius that scales with the artwork card size (~4% capped to a sane
// range), so small boxes stay subtle and large ones keep a natural ratio.
static double RTCornerRadius(double w, double h) {
    double r = MIN(w, h) * 0.04;
    if (r < 8.0) r = 8.0;
    if (r > 64.0) r = 64.0;
    return r;
}

// Corner radius is defined at file scope after the anonymous namespaces so
// the global mangling exported via renderer.h is produced.
NSImage * ScaledImage(NSImage * src, double w, double h) {
    NSImage * out = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [out lockFocus];
    [src drawInRect:NSMakeRect(0, 0, w, h)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
                hints:nil];
    [out unlockFocus];
    return out;
}

static int rtPlaybackState() {
    playback_control::ptr pc = playback_control::get();
    if (!pc.is_valid()) return 0;
    if (pc->is_paused()) return 2;
    if (pc->is_playing()) return 1;
    return 0;
}

static BOOL rtIsPaused() {
    return rtPlaybackState() == 2;
}

static double RTVolumeDB() {
    playback_control::ptr pc = playback_control::get();
    if (!pc.is_valid()) return 0.0;
    @try {
        return pc->get_volume();
    } @catch (NSException *e) { (void)e; return 0.0; }
}

static NSString * RTVolumeString(BOOL isDB) {
    double db = RTVolumeDB();
    if (isDB) {
        if (fabs(db - rint(db)) < 0.0005)
            return [NSString stringWithFormat:@"%d", (int)rint(db)];
        return [NSString stringWithFormat:@"%.1f", db];
    }
    double pct = (pow(10.0, db / 50.0) - 0.01) / 0.99;
    int pctInt = (int)lrint(pct * 100.0);
    if (pctInt < 0) pctInt = 0;
    if (pctInt > 100) pctInt = 100;
    return [NSString stringWithFormat:@"%d", pctInt];
}

// Substitutes the live custom directives ($volume(0)/$volume(1)) inside a
// titleformat expression with their literal current values, so fb2k's TF
// engine can use them within other functions, e.g.
// $ifequal($volume(0),0,🔊,🔇).
static NSString * InjectIsPlayingState(NSString * expr) {
    static NSRegularExpression * reVol;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reVol = [NSRegularExpression
                 regularExpressionWithPattern:@"\\$volume\\s*\\(\\s*([01])\\s*\\)"
                 options:0 error:nil];
    });
    NSMutableString * result = [expr mutableCopy];
    // Apply edits from the last match backwards: shrinking string length does
    // not invalidate the ranges of earlier matches.
    NSArray<NSTextCheckingResult *> * matches = [reVol matchesInString:expr
                                                               options:0
                                                                 range:NSMakeRange(0, expr.length)];
    for (NSInteger idx = (NSInteger)matches.count - 1; idx >= 0; idx--) {
        NSTextCheckingResult * m = matches[idx];
        NSString * arg = [expr substringWithRange:[m rangeAtIndex:1]];
        // 0 -> dB, 1 -> percentage
        [result replaceCharactersInRange:m.range withString:RTVolumeString([arg isEqualToString:@"0"])];
    }
    return result;
}

static NSImage * GrayscaleImage(NSImage * src, BOOL on) {
    if (!on) return src;
    NSBitmapImageRep * rep = [NSBitmapImageRep imageRepWithData:[src TIFFRepresentation]];
    CGImageRef cg = rep.CGImage;
    if (!cg) return src;

    CIImage * input = [CIImage imageWithCGImage:cg];
    CIFilter * bw = [CIFilter filterWithName:@"CIPhotoEffectMono"];
    if (!bw) return src;
    [bw setDefaults];
    [bw setValue:input forKey:kCIInputImageKey];
    CIImage * result = [bw valueForKey:kCIOutputImageKey];
    // Share one CIContext across calls instead of allocating per image.
    static CIContext * ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
    });
    CGImageRef outCG = [ctx createCGImage:result fromRect:input.extent];
    if (!outCG) return src;
    NSBitmapImageRep * repOut = [[NSBitmapImageRep alloc] initWithCGImage:outCG];
    CGImageRelease(outCG);

    NSImage * out = [[NSImage alloc] initWithSize:src.size];
    [out addRepresentation:repOut];
    return out;
}

NSAttributedString * AttachmentForLineImage(NSImage * image, CGFloat maxWidth,
                                            BOOL darkMode, BOOL shadowEnabled,
                                            NSString * sourceKey) {
    NSTextAttachment * attachment = [NSTextAttachment new];
    BOOL placeholder = (image == nil);
    // negative-cache marker (tiny image from failed loads) also renders as placeholder
    if (!placeholder && image.size.width <= 16.0 && image.size.height <= 16.0) placeholder = YES;
    NSSize src = placeholder ? NSZeroSize : image.size;

    // canvas is always a square matching the placeholder box
    double w = round(maxWidth);
    double h = w;

    BOOL grayscale = rtIsPaused();

    // Composed-image cache: re-composing the shadowed card (and grayscaling)
    // every render is wasteful; the composition depends only on the source
    // art, canvas width, dark mode, shadow flag, and pause state.
    NSCache * compCache = [RTArtCache shared].composedCache;
    NSString * key;
    if (placeholder)
        key = [NSString stringWithFormat:@"p|%.0f|%d|%d", w, darkMode, grayscale];
    else
        key = [NSString stringWithFormat:@"c|%@|%.0f|%d|%d|%d", sourceKey ?: @"?", w,
               darkMode, shadowEnabled, grayscale];
    NSImage * cachedDrawn = [compCache objectForKey:key];

    NSImage * drawn;
    if (cachedDrawn) {
        drawn = cachedDrawn;
    } else if (placeholder) {
        drawn = PlaceholderImage(w, h, darkMode);
    } else {
        double padX = shadowEnabled ? 8.0 : 0.0;
        double padTop = shadowEnabled ? 12.0 : 0.0;
        double padBottom = shadowEnabled ? 8.0 : 0.0;
        double availW = w - padX * 2;
        double availH = h - padTop - padBottom;
        double sx = availW / src.width, sy = availH / src.height;
        double s = MIN(sx, sy);
        double dw = round(src.width  * s);
        double dh = round(src.height * s);
        double ox = padX + round((availW - dw) * 0.5);
        double oy = padTop + round((availH - dh) * 0.5);
        NSRect contentRect = NSMakeRect(ox, oy, dw, dh);
        drawn = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
        [drawn lockFocus];
        if (shadowEnabled) {
            NSShadow * shadow = [NSShadow new];
            shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.40];
            shadow.shadowOffset = NSMakeSize(0, -4.0);
            shadow.shadowBlurRadius = 10.0;
            [shadow set];
        }
        double corner = RTCornerRadius(dw, dh);
        NSBezierPath * card = [NSBezierPath bezierPathWithRoundedRect:contentRect
                                                             xRadius:corner yRadius:corner];
        [card fill];
        [card addClip];
        // only the card casts the shadow; reset so the image draw below does not
        // add a second overlapping shadow (which corrupted the corners)
        CGContextRef ctx = (CGContextRef)[NSGraphicsContext currentContext].CGContext;
        CGContextSetShadowWithColor(ctx, CGSizeZero, 0.0, NULL);
        [image drawInRect:contentRect
                 fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0
           respectFlipped:YES
                     hints:nil];
        NSColor * borderColor = darkMode
            ? [NSColor colorWithWhite:1.0 alpha:0.10]
            : [NSColor colorWithWhite:0.0 alpha:0.10];
        [borderColor setStroke];
        NSBezierPath * border = [NSBezierPath bezierPathWithRoundedRect:
                                 NSInsetRect(contentRect, 0.5, 0.5)
                                                               xRadius:MAX(0.0, corner - 0.5)
                                                               yRadius:MAX(0.0, corner - 0.5)];
        border.lineWidth = 1.0;
        [border stroke];
        [drawn unlockFocus];
    }
    if (!cachedDrawn) {
        drawn = GrayscaleImage(drawn, grayscale);
        [compCache setObject:drawn forKey:key];
    }
    double baselineOffset = shadowEnabled ? -round(h * 0.15) : 0.0;
    NSTextAttachmentCell * cell = [[NSTextAttachmentCell alloc] init];
    cell.image = drawn;
    attachment.attachmentCell = cell;
    attachment.bounds = NSMakeRect(0, baselineOffset, w, h);
    return [NSAttributedString attributedStringWithAttachment:attachment];
}

} // namespace

@implementation RTRenderer

+ (NSString *)artCacheKey:(trackRef)track name:(NSString *)artName {
    return ArtCacheKey(track, artName);
}

+ (BOOL)artGUIDForName:(NSString *)artName out:(GUID *)out {
    static NSDictionary<NSString *, NSValue *> * artIDs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        artIDs = @{ @"front": [NSValue valueWithBytes:&album_art_ids::cover_front objCType:@encode(GUID)],
                    @"back": [NSValue valueWithBytes:&album_art_ids::cover_back objCType:@encode(GUID)],
                    @"artist": [NSValue valueWithBytes:&album_art_ids::artist objCType:@encode(GUID)],
                    @"disc": [NSValue valueWithBytes:&album_art_ids::disc objCType:@encode(GUID)] };
    });
    NSString * canonical = [artName lowercaseString];
    if ([canonical isEqualToString:@"cover"]) canonical = @"front";
    NSValue * boxed = artIDs[canonical];
    if (!boxed) return NO;
    if (out) [boxed getValue:out];
    return YES;
}

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
                         artRangeOut:(NSRange *)artRangeOut {
    if (artRangeOut) *artRangeOut = NSMakeRange(NSNotFound, 0);
    NSRange firstArtRange = NSMakeRange(NSNotFound, 0);
    NSMutableAttributedString * out = [NSMutableAttributedString new];
    // background=2: the link colour is a 50/50 blend of the computed text and
    // background colours; otherwise the system link colour is used.
    static NSColor * linkColor;
    static dispatch_once_t onceLink;
    dispatch_once(&onceLink, ^{ linkColor = RTLinkColor(); });
    CGFloat contentSize = MAX(0.0, MIN(maxWidth, maxHeight));
    NSFont * panelDefault = ExplicitFont(defaultFontName, defaultFontSize, nil, 0, nil, nil);

    for (RTLine * line in lines) {
        if (line.imageArt.length > 0 && line.segments.count == 0) {
            GUID artGuid;
            if ([RTRenderer artGUIDForName:line.imageArt out:&artGuid]) {
                NSString * canonical = [line.imageArt lowercaseString];
                if ([canonical isEqualToString:@"cover"]) canonical = @"front";
                NSString * key = ArtCacheKey(track, canonical);
                // Draw a placeholder even when the display track is empty
                // (fresh host start with playback stopped): only the cache
                // lookup and the async load are key-gated.
                NSImage * img = key ? [[RTArtCache shared] get:key] : nil;
                if (!img && loadHandler && key) loadHandler(canonical);
                [out appendAttributedString:AttachmentForLineImage(img, contentSize,
                                                                    darkMode, line.imageShadow, key)];
                if (firstArtRange.location == NSNotFound)
                    firstArtRange = NSMakeRange(out.length - 1, 1);
            }
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                        attributes:BaseAttrs(panelDefault, nil, defaultTextColor, darkMode)]];
            continue;
        }

        NSFont * baseFont = nil;
        for (RTSegment * seg in line.segments)
            if (seg.fontName.length > 0 || seg.fontSize > 0 || seg.fontWeight.length > 0 || seg.fontStyle.length > 0) { baseFont = ExplicitFont(defaultFontName, defaultFontSize, seg.fontName, seg.fontSize, seg.fontWeight, seg.fontStyle); break; }
        if (!baseFont) baseFont = panelDefault;
        BOOL hasInlineImage = NO;
        for (RTSegment * seg in line.segments)
            if (seg.kind == RTSegmentImage) { hasInlineImage = YES; break; }

        NSMutableAttributedString * lineOut = [NSMutableAttributedString new];
        NSUInteger inlineArtPos = NSNotFound;
        for (RTSegment * seg in line.segments) {
            switch (seg.kind) {
                case RTSegmentText: {
                    NSFont * font = ExplicitFont(defaultFontName, defaultFontSize, seg.fontName, seg.fontSize > 0 ? seg.fontSize : 0, seg.fontWeight, seg.fontStyle);
                    if (font == nil) font = baseFont;
                    NSString * raw = InjectIsPlayingState(seg.text); // $crlf already expanded at parse time
                    NSString * injected = RTInjectColorTokens(raw, track);
                    NSString * rendered = FormatLeadingDate(RTEvaluateCached(injected, track, raw));
                    if (rendered.length == 0) continue;
                    NSDictionary * attrs = InlineImageLineAttrs(
                        BaseAttrs(font, SegmentColor(seg.dimLevel, seg.color, defaultTextColor, defaultBackgroundColor, linkColor), defaultTextColor, darkMode),
                        font, contentSize, hasInlineImage);
                    RTAppendColorSpans(lineOut, rendered, attrs);
                    break;
                }
                case RTSegmentLink: {
                    NSFont * font = ExplicitFont(defaultFontName, defaultFontSize, seg.fontName, seg.fontSize, seg.fontWeight, seg.fontStyle);
                    NSString * rawLabel = InjectIsPlayingState(seg.text); // $crlf already expanded at parse time
                    NSString * injected = RTInjectColorTokens(rawLabel, track);
                    NSString * rendered = RTEvaluateCached(injected, track, rawLabel);
                    if (rendered.length == 0) continue;
                    NSUInteger idx = commandTable.count;
                    NSString * url = [NSString stringWithFormat:@"%@%lu", kRTLinkScheme,
                                      (unsigned long)idx];
                    NSString * resolvedPath;
                    resolvedPath = RTEvaluateCached(InjectIsPlayingState(seg.commandPath), track,
                                          seg.commandPath);
                    if (resolvedPath.length == 0) continue;
                    commandTable[url] = resolvedPath;
                    NSMutableDictionary * attrs = [InlineImageLineAttrs(
                        BaseAttrs(font, SegmentColor(seg.dimLevel, (seg.color ?: linkColor), defaultTextColor, defaultBackgroundColor, linkColor), defaultTextColor, darkMode),
                        font, contentSize, hasInlineImage) mutableCopy];
                    attrs[NSLinkAttributeName] = url;
                    RTAppendColorSpans(lineOut, rendered, attrs);
                    [lineOut appendAttributedString:[[NSAttributedString alloc] initWithString:@" "
                                                                                    attributes:InlineImageLineAttrs(@{ NSFontAttributeName: font }, font, contentSize, hasInlineImage)]];
                    break;
                }
                case RTSegmentLiteral: {
                    NSFont * font = ExplicitFont(defaultFontName, defaultFontSize, seg.fontName, seg.fontSize > 0 ? seg.fontSize : 0, seg.fontWeight, seg.fontStyle);
                    if (font == nil) font = baseFont;
                    [lineOut appendAttributedString:[[NSAttributedString alloc] initWithString:seg.text
                                                                                    attributes:InlineImageLineAttrs(BaseAttrs(font, SegmentColor(seg.dimLevel, seg.color, defaultTextColor, defaultBackgroundColor, linkColor), defaultTextColor, darkMode), font, contentSize, hasInlineImage)]];
                    break;
                }
                case RTSegmentVolume: {
                    NSFont * font = ExplicitFont(defaultFontName, defaultFontSize, seg.fontName, seg.fontSize, seg.fontWeight, seg.fontStyle);
                    if (font == nil) font = baseFont;
                    NSString * rendered = RTVolumeString(seg.mode == 0);
                    [lineOut appendAttributedString:[[NSAttributedString alloc] initWithString:rendered
                                                                                    attributes:InlineImageLineAttrs(BaseAttrs(font, SegmentColor(seg.dimLevel, seg.color, defaultTextColor, defaultBackgroundColor, linkColor), defaultTextColor, darkMode), font, contentSize, hasInlineImage)]];
                    break;
                }
                case RTSegmentImage: {
                    GUID artGuid;
                    if (![RTRenderer artGUIDForName:seg.imageArt out:&artGuid]) break;
                    NSString *canonical = [seg.imageArt.lowercaseString isEqualToString:@"cover"] ? @"front" : seg.imageArt.lowercaseString;
                    NSString *key = ArtCacheKey(track, canonical);
                    NSImage *img = key ? [[RTArtCache shared] get:key] : nil;
                    if (!img && loadHandler && key) loadHandler(canonical);
                    [lineOut appendAttributedString:AttachmentForLineImage(img, contentSize,
                                                                            darkMode, seg.imageShadow, key)];
                    if (firstArtRange.location == NSNotFound) inlineArtPos = lineOut.length - 1;
                    break;
                }
            }
        }

        // Script newlines are neglected: they do NOT create panel line breaks.
        // Only an explicit $crlf() breaks line rather than "\n".
        if (lineOut.length == 0) continue;
        NSString * current = out.string;
        unichar last = current.length > 0 ? [current characterAtIndex:current.length - 1] : 0;
        if (current.length > 0 && last != '\n' && last != ' ' && last != '\t')
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@" "
                                                                        attributes:BaseAttrs(baseFont, nil, defaultTextColor, darkMode)]];
        if (inlineArtPos != NSNotFound)
            firstArtRange = NSMakeRange(out.length + inlineArtPos, 1);
        [out appendAttributedString:lineOut];
    }
    if (artRangeOut && firstArtRange.location != NSNotFound)
        *artRangeOut = firstArtRange;
    return out;
}

@end
