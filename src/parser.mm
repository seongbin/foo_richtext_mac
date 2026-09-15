#import "stdafx.h"
#import "parser.h"

@implementation RTSegment
@end
@implementation RTLine
- (instancetype)init {
    self = [super init];
    if (self) _segments = [NSMutableArray new];
    return self;
}
@end

namespace {

static // $crlf is a native titleformat function with no argument support, so
// $crlf(n) is expanded here into n consecutive $crlf() calls before the
// text reaches the TF compiler (0 clears to nothing; capped for safety).
// Runs at PARSE time so per-render evaluation never re-does this regex.
static NSString * RTExpandCrlf(NSString * expr) {
    if ([expr rangeOfString:@"$crlf"].location == NSNotFound) return expr;
    static NSRegularExpression * re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"\\$crlf\\s*\\(\\s*(\\d+)\\s*\\)"
                                                       options:0 error:nil];
    });
    NSMutableString * out = [NSMutableString new];
    __block NSInteger pos = 0;
    [re enumerateMatchesInString:expr
                         options:0
                           range:NSMakeRange(0, expr.length)
                      usingBlock:^(NSTextCheckingResult * m, NSMatchingFlags flags, BOOL * stop) {
        (void)flags; (void)stop;
        if ((NSInteger)m.range.location > pos)
            [out appendString:[expr substringWithRange:NSMakeRange(pos, m.range.location - pos)]];
        NSInteger n = [[expr substringWithRange:[m rangeAtIndex:1]] integerValue];
        if (n < 0) n = 0;
        if (n > 20) n = 20;
        for (NSInteger i = 0; i < n; ++i) [out appendString:@"$crlf()"];
        pos = m.range.location + m.range.length;
    }];
    if (pos < (NSInteger)expr.length)
        [out appendString:[expr substringFromIndex:pos]];
    return out;
}

NSCharacterSet *WhitespaceSet() {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSCharacterSet whitespaceCharacterSet]; });
    return set;
}

static NSCharacterSet *WhitespaceAndNewlineSet() {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSCharacterSet whitespaceAndNewlineCharacterSet]; });
    return set;
}

bool isArtToken(NSString *name, NSString ** outArt) {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{ @"front": @"front",
                 @"cover": @"front",
                 @"back": @"back",
                 @"artist": @"artist",
                 @"disc": @"disc" };
    });
    NSString *v = map[name.lowercaseString];
    if (v && outArt) *outArt = v;
    return v != nil;
}

bool hasPrefixAt(NSString *line, NSUInteger pos, NSString *prefix) {
    NSUInteger pl = prefix.length;
    if (pos + pl > line.length) return false;
    for (NSUInteger k = 0; k < pl; ++k)
        if ([line characterAtIndex:pos + k] != [prefix characterAtIndex:k]) return false;
    return true;
}

// Finds the "<"...">" (dim) and ">"..."<" (highlight) angle-bracket pairs in a
// line's literal text (ignoring quoted regions), mirroring foobar2000's muted
// markup. Returns the indices of every bracket that is part of a COMPLETED
// pair; an unmatched lone "<" or ">" is left out so it renders literally and
// does not colour the rest of the line. Grouping is contiguous: the first
// bracket sets a direction, each repeat of the opener deepens the level, and
// each opposite bracket is a closer; the group is matched when depth hits zero.
static NSMutableIndexSet * PairedBrackets(NSString * line) {
    NSUInteger n = line.length;
    NSMutableIndexSet * matched = [NSMutableIndexSet indexSet];
    BOOL inSingle = NO, inDouble = NO;
    int kind = 0;   // 0 none, +1 dim (<..>), -1 highlight (>..<)
    int depth = 0;
    NSMutableIndexSet * groupOpen = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < n; ++i) {
        unichar c = [line characterAtIndex:i];
        if (inSingle) {
            if (c == '\'') {
                if (i + 1 < n && [line characterAtIndex:i + 1] == '\'') i++;
                else inSingle = NO;
            }
            continue;
        }
        if (inDouble) { if (c == '"') inDouble = NO; continue; }
        if (c == '\'') { inSingle = YES; continue; }
        if (c == '"')  { inDouble = YES; continue; }
        if (c != '<' && c != '>') continue;
        if (kind == 0) {
            kind = (c == '<') ? 1 : -1;
            depth = 1;
            [groupOpen addIndex:i];
            continue;
        }
        unichar opener = (kind == 1) ? '<' : '>';
        if (c == opener) {
            depth++;
            [groupOpen addIndex:i];
        } else {
            depth--;
            [matched addIndex:i];
            if (depth == 0) {
                [matched addIndexes:groupOpen];
                [groupOpen removeAllIndexes];
                kind = 0;
            }
        }
    }
    return matched;
}

NSArray<NSString *> *splitArgs(NSString *args) {
    return [args componentsSeparatedByString:@","];
}

BOOL isNumericArg(NSString * s) {
    NSScanner * sc = [NSScanner scannerWithString:s];
    [sc setCharactersToBeSkipped:WhitespaceSet()];
    double d = 0;
    return [sc scanDouble:&d] && [sc isAtEnd];
}

BOOL isWeightName(NSString * s) {
    static NSSet<NSString *> * names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[ @"thin", @"ultralight", @"extralight", @"light", @"regular",
                                       @"normal", @"medium", @"semibold", @"demibold", @"bold",
                                       @"heavy", @"black" ]];
    });
    return [names containsObject:s.lowercaseString];
}

BOOL isStyleName(NSString * s) {
    static NSSet<NSString *> * names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[ @"normal", @"italic", @"oblique" ]];
    });
    return [names containsObject:s.lowercaseString];
}

// $font(name,size,weight,style)
NSUInteger tryParseFontDirective(NSString *line, NSUInteger pos, NSString **outName,
                                 double *outSize, NSString **outWeight, NSString **outStyle) {
    if (!hasPrefixAt(line, pos, @"$font(")) return 0;
    NSUInteger openParen = pos + 5;
    NSUInteger close = findMatchingParen(line, openParen + 1);
    if (close == NSNotFound) return 0;
    NSString *args = [line substringWithRange:NSMakeRange(openParen + 1, close - openParen - 1)];
    args = [args stringByTrimmingCharactersInSet:WhitespaceSet()];

    NSString *name = nil, *weight = nil, *style = nil;
    double size = 0;
    if (args.length > 0) {
        NSMutableArray<NSString *> *parts = [NSMutableArray new];
        for (NSString * raw in splitArgs(args)) {
            NSString * p = [raw stringByTrimmingCharactersInSet:WhitespaceSet()];
            [parts addObject:p ?: @""];
        }

        NSString * last = parts.lastObject;
        if (last.length > 0 && !isNumericArg(last) && isStyleName(last)) {
            style = last.lowercaseString;
            if ([style isEqualToString:@"normal"]) style = nil; // no trait
            [parts removeLastObject];
        }

        last = parts.lastObject;
        if (last.length > 0 && !isNumericArg(last) && isWeightName(last)) {
            weight = last.lowercaseString;
            [parts removeLastObject];
        }

        last = parts.lastObject;
        if (last.length > 0 && isNumericArg(last)) {
            double sz = last.doubleValue;
            if (sz <= 1 || sz > 512) return 0;
            size = sz;
            [parts removeLastObject];
        }

        while (parts.count && [(NSString *)parts.lastObject length] == 0) [parts removeLastObject];
        if (parts.count) {
            name = [parts componentsJoinedByString:@","];
            if (name.length == 0) name = nil;
        }
        if (!weight && !size && !name && args.length > 0 && !isNumericArg(args)) {
            if (isWeightName(args)) { weight = args.lowercaseString; name = nil; }
        }
    }
    if (outName) *outName = name;
    if (outSize) *outSize = size;
    if (outWeight) *outWeight = weight;
    if (outStyle) *outStyle = style;
    return close - pos + 1;
}

NSUInteger tryParseRGBDirective(NSString *line, NSUInteger pos, NSColor **outColor) {
    if (!hasPrefixAt(line, pos, @"$rgb(")) return 0;
    NSUInteger openParen = pos + 4;
    NSUInteger close = findMatchingParen(line, openParen + 1);
    if (close == NSNotFound) return 0;
    NSString *args = [line substringWithRange:NSMakeRange(openParen + 1, close - openParen - 1)];
    NSString *trimmed = [args stringByTrimmingCharactersInSet:WhitespaceAndNewlineSet()];
    if (trimmed.length == 0) {
        if (outColor) *outColor = nil;
        return close - pos + 1;
    }
    NSArray<NSString *> *parts = splitArgs(args);
    NSInteger vals[3];
    if (parts.count == 1) {
        // single argument: try a hex colour code (e.g. $rgb(FF0436), #FF0436,
        // or 3-digit shorthand F0A)
        NSString *hexStr = [parts[0] stringByTrimmingCharactersInSet:WhitespaceSet()];
        if ([hexStr hasPrefix:@"#"]) hexStr = [hexStr substringFromIndex:1];
        if (hexStr.length == 3) {
            unichar a = [hexStr characterAtIndex:0], b = [hexStr characterAtIndex:1], c = [hexStr characterAtIndex:2];
            hexStr = [NSString stringWithFormat:@"%c%c%c%c%c%c", a, a, b, b, c, c];
        }
        unsigned int hex = 0;
        NSScanner *sc = [NSScanner scannerWithString:hexStr];
        if (hexStr.length != 6 || ![sc scanHexInt:&hex] || ![sc isAtEnd]) return 0;
        vals[0] = (hex >> 16) & 0xFF;
        vals[1] = (hex >> 8)  & 0xFF;
        vals[2] =  hex        & 0xFF;
    } else if (parts.count == 3) {
        for (int i = 0; i < 3; ++i) {
            long long v = parts[i].longLongValue;
            if (v < 0) v = 0;
            if (v > 255) v = 255;
            vals[i] = v;
        }
    } else {
        return 0;
    }
    if (outColor)
        *outColor = [NSColor colorWithSRGBRed:vals[0] / 255.0 green:vals[1] / 255.0 blue:vals[2] / 255.0 alpha:1.0];
    return close - pos + 1;
}

NSUInteger tryParseField(NSString *line, NSUInteger pos, NSMutableArray<RTSegment *> *out,
                         NSString *fontName, double fontSize, NSString *fontWeight, NSString *fontStyle, NSColor *color) {
    if ([line characterAtIndex:pos] != '%') return 0;
    NSUInteger n = line.length;
    for (NSUInteger i = pos + 1; i < n; ++i) {
        if ([line characterAtIndex:i] == '%') {
            NSString *name = [line substringWithRange:NSMakeRange(pos + 1, i - pos - 1)];
            if (name.length == 0) return 0;
            RTSegment *seg = [RTSegment new];
            seg.kind = RTSegmentText;
            seg.text = [NSString stringWithFormat:@"%%%@%%", name];
            seg.fontName = fontName;
            seg.fontSize = fontSize;
            seg.fontWeight = fontWeight;
            seg.fontStyle = fontStyle;
            seg.color = color;
            [out addObject:seg];
            return i - pos + 1;
        }
    }
    return 0;
}

NSString * UnquoteTrim(NSString * s) {
    s = [s stringByTrimmingCharactersInSet:WhitespaceSet()];
    if (s.length >= 2) {
        unichar q0 = [s characterAtIndex:0];
        if ((q0 == '\'' || q0 == '"') && [s characterAtIndex:s.length - 1] == q0)
            s = [s substringWithRange:NSMakeRange(1, s.length - 2)];
        s = [s stringByTrimmingCharactersInSet:WhitespaceSet()];
    }
    return s;
}

// First comma at parenthesis depth 0 and outside single quotes; commas inside
// nested titleformat calls (e.g. $ifequal(a,b,c,d)) do not split arguments.
static NSRange FindTopLevelComma(NSString * args) {
    NSInteger depth = 0;
    BOOL inQuote = NO;
    for (NSUInteger i = 0; i < args.length; i++) {
        unichar c = [args characterAtIndex:i];
        if (inQuote) { if (c == '\'') inQuote = NO; continue; }
        if (c == '\'') { inQuote = YES; continue; }
        if (c == '(') depth++;
        else if (c == ')') depth--;
        else if (c == ',' && depth == 0) return NSMakeRange(i, 1);
    }
    return NSMakeRange(NSNotFound, 0);
}

// Parses $cmd(command,value). Command is a menu path, either literal or a
// titleformat expression resolved at render time. Second argument is the
// displayed text/emoji; when omitted a literal path falls back to showing its
// last path component. Only top-level commas split the arguments.
NSUInteger tryParseCmd(NSString *line, NSUInteger pos, NSMutableArray<RTSegment *> *out,
                       NSString *fontName, double fontSize, NSString *fontWeight, NSString *fontStyle, NSColor *color) {
    if (!hasPrefixAt(line, pos, @"$cmd(")) return 0;
    NSUInteger openParen = pos + 4;
    NSUInteger closeParen = findMatchingParen(line, openParen + 1);
    if (closeParen == NSNotFound) return 0;

    NSString *args = [line substringWithRange:NSMakeRange(openParen + 1, closeParen - openParen - 1)];
    NSRange comma = FindTopLevelComma(args);
    BOOL hasValue = comma.location != NSNotFound;
    NSString *path = UnquoteTrim(hasValue ? [args substringToIndex:comma.location] : args);
    NSString *value = UnquoteTrim(hasValue ? [args substringFromIndex:comma.location + 1] : @"");
    if (path.length == 0) return 0;
    if (value.length == 0 && ![path hasPrefix:@"$"]) {
        NSRange lastSlash = [path rangeOfString:@"/" options:NSBackwardsSearch];
        value = (lastSlash.location == NSNotFound || lastSlash.location + 1 >= path.length)
            ? path
            : [path substringFromIndex:lastSlash.location + 1];
    }
    if (value.length == 0) return 0;

    RTSegment *seg = [RTSegment new];
    seg.kind = RTSegmentLink;
    seg.text = RTExpandCrlf(value); // $crlf(n) expanded once at parse time
    seg.commandPath = path;
    seg.fontName = fontName;
    seg.fontSize = fontSize;
    seg.fontWeight = fontWeight;
    seg.fontStyle = fontStyle;
    seg.color = color;
    [out addObject:seg];
    return closeParen - pos + 1;
}

BOOL isIdentChar(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '$';
}

// Parses $volume(0) / $volume(1) into a segment rendered from the live volume
// at display time. The argument picks the unit: 0 = dB, 1 = percentage.
// Recognizes only the exact function; anything else returns 0 and falls
// through to the regular titleformat/plain-text handling.
NSUInteger tryParseVolumeDirective(NSString *line, NSUInteger pos, NSMutableArray<RTSegment *> *out,
                                   NSString *fontName, double fontSize, NSString *fontWeight,
                                   NSString *fontStyle, NSColor *color) {
    if ([line characterAtIndex:pos] != '$') return 0;
    NSUInteger n = line.length;
    NSUInteger i = pos + 1;
    while (i < n && isIdentChar([line characterAtIndex:i])) ++i;
    NSString *name = [line substringWithRange:NSMakeRange(pos + 1, i - pos - 1)];
    if (![name isEqualToString:@"volume"]) return 0;

    NSUInteger end = i;
    int mode = 0; // 0 = dB
    if (end < n && [line characterAtIndex:end] == '(') {
        NSUInteger close = findMatchingParen(line, end + 1);
        if (close == NSNotFound) return 0;
        NSString *inner = [[line substringWithRange:NSMakeRange(end + 1, close - end - 1)]
            stringByTrimmingCharactersInSet:WhitespaceSet()];
        if ([inner isEqualToString:@"1"]) mode = 1;
        else if (![inner isEqualToString:@"0"]) return 0; // unexpected arg -> not ours
        end = close + 1;
    } else {
        return 0; // $volume requires its unit argument
    }

    RTSegment *seg = [RTSegment new];
    seg.kind = RTSegmentVolume;
    seg.mode = mode;
    seg.text = [line substringWithRange:NSMakeRange(pos, end - pos)];
    seg.fontName = fontName;
    seg.fontSize = fontSize;
    seg.fontWeight = fontWeight;
    seg.fontStyle = fontStyle;
    seg.color = color;
    [out addObject:seg];
    return end - pos;
}

static BOOL tryParseImageDirective(NSString *line, NSUInteger pos, NSString **outArt,
                                   BOOL *outShadow) {
    if (!hasPrefixAt(line, pos, @"$image(")) return 0;
    NSUInteger openParen = pos + 6;
    NSUInteger close = findMatchingParen(line, openParen + 1);
    if (close == NSNotFound) return 0;
    NSString *inner = [line substringWithRange:NSMakeRange(openParen + 1, close - openParen - 1)];
    inner = [inner stringByTrimmingCharactersInSet:WhitespaceSet()];
    if (inner.length == 0) return 0;

    NSArray<NSString *> *parts = [inner componentsSeparatedByString:@","];
    NSString *token = [parts.firstObject stringByTrimmingCharactersInSet:WhitespaceSet()];

    // strip optional %...% wrapper
    if (token.length >= 2 &&
        [token characterAtIndex:0] == '%' &&
        [token characterAtIndex:token.length - 1] == '%')
        token = [token substringWithRange:NSMakeRange(1, token.length - 2)];

    NSString *art = nil;
    if (!isArtToken(token, &art)) return 0;

    BOOL shadow = YES;

    if (outArt) *outArt = art;
    if (outShadow) *outShadow = shadow;
    return close - pos + 1;
}

// If line[pos] starts an unknown titleformat function call ($name(...)),
// returns the index just past its closing ')' - honoring single-quote
// literal regions - so nested %fields% stay inside one segment and the
// whole expression reaches the TF compiler intact. Returns 0 otherwise.
NSUInteger tfFunctionEnd(NSString *line, NSUInteger pos) {
    NSUInteger n = line.length;
    NSUInteger i = pos + 1;
    if (i >= n || !isIdentChar([line characterAtIndex:i])) return 0;
    while (i < n && isIdentChar([line characterAtIndex:i])) ++i;
    if (i >= n || [line characterAtIndex:i] != '(') return 0;

    NSInteger depth = 0;
    BOOL inQuote = NO;
    for (; i < n; ++i) {
        unichar c = [line characterAtIndex:i];
        if (c == '\'') { inQuote = !inQuote; continue; }
        if (inQuote) continue;
        if (c == '(') ++depth;
        else if (c == ')') {
            if (--depth == 0) return i + 1;
        }
    }
    return 0;
}

}

NSUInteger findMatchingParen(NSString *s, NSUInteger from) {
    NSInteger depth = 1;
    BOOL inSingle = NO, inDouble = NO;
    NSUInteger n = s.length;
    for (NSUInteger i = from; i < n; ++i) {
        unichar c = [s characterAtIndex:i];
        if (inSingle) {
            if (c == '\'') {
                if (i + 1 < n && [s characterAtIndex:i + 1] == '\'') i++;
                else inSingle = NO;
            }
            continue;
        }
        if (inDouble) { if (c == '"') inDouble = NO; continue; }
        if (c == '\'') { inSingle = YES; continue; }
        if (c == '"') { inDouble = YES; continue; }
        if (c == '(') depth++;
        else if (c == ')') { if (--depth == 0) return i; }
    }
    return NSNotFound;
}

NSArray<RTLine *> * RTParseScript(NSString *script) {
    NSMutableArray<RTLine *> *lines = [NSMutableArray new];
    if (script.length == 0) return lines;
    NSArray<NSString *> *rawLines = [script componentsSeparatedByCharactersInSet:
                                     [NSCharacterSet newlineCharacterSet]];
    for (NSString *line in rawLines) {
        // full-line comment: //
        NSString * trimmedHead = [line stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmedHead hasPrefix:@"//"]) continue;
        RTLine *rtLine = [RTLine new];
        __block NSString *fontName = nil;
        __block double fontSize = 0;
        __block NSString *fontWeight = nil;
        __block NSString *fontStyle = nil;
        __block NSColor *color = nil;
        __block int dimLevel = 0;

        NSMutableString *run = [NSMutableString new];
        auto flushRun = ^{
            if (run.length == 0) return;
            RTSegment *seg = [RTSegment new];
            seg.kind = RTSegmentText;
            seg.text = RTExpandCrlf(run); // $crlf(n) expanded once at parse time
            seg.fontName = fontName;
            seg.fontSize = fontSize;
            seg.fontWeight = fontWeight;
            seg.fontStyle = fontStyle;
            seg.color = color;
            seg.dimLevel = dimLevel;
            [rtLine.segments addObject:seg];
            [run setString:@""];
        };
        auto stampLast = ^(void){ rtLine.segments.lastObject.dimLevel = dimLevel; };

        NSUInteger n = line.length, i = 0;
        // Angle-bracket pairing precomputed so only completed "<...>"/">...<"
        // pairs affect dim/highlighting; a lone "<" or ">" renders literally.
        NSMutableIndexSet * paired = PairedBrackets(line);

        // when a single/double quote is open, everything up to the matching
        // close is literal text (so e.g. '%' can display a % symbol); the
        // quotes themselves are not rendered. Quoted content is emitted as a
        // dedicated RTSegmentLiteral so it is displayed verbatim (never
        // re-interpreted as titleformat field/function).
        unichar quoteChar = 0;
        NSMutableString *litRun = [NSMutableString new];
        while (i < n) {
            unichar c = [line characterAtIndex:i];
            if (quoteChar != 0) {
                if (c == quoteChar) {
                    quoteChar = 0;
                    i++;
                    if (litRun.length > 0) {
                        RTSegment *seg = [RTSegment new];
                        seg.kind = RTSegmentLiteral;
                        seg.text = [NSString stringWithString:litRun];
                        seg.fontName = fontName;
                        seg.fontSize = fontSize;
                        seg.fontWeight = fontWeight;
                        seg.fontStyle = fontStyle;
                        seg.color = color;
                        seg.dimLevel = dimLevel;
                        [rtLine.segments addObject:seg];
                        [litRun setString:@""];
                    }
                    continue;
                }
                [litRun appendFormat:@"%C", c]; i++; continue;
            }
            if ((c == '\'' || c == '"') ) { flushRun(); quoteChar = c; i++; continue; }
            if (c == '$' && i + 1 < n && [line characterAtIndex:i + 1] == '$') { [run appendString:@"$"]; i += 2; continue; }
            if (c == '%' && i + 1 < n && [line characterAtIndex:i + 1] == '%') { [run appendString:@"%"]; i += 2; continue; }

            if (c == '$') {
                flushRun();
                NSString *art = nil;
                BOOL imgShadow = NO;
                NSUInteger usedImg = tryParseImageDirective(line, i, &art, &imgShadow);
                if (usedImg > 0) {
                    [rtLine.segments removeAllObjects];
                    rtLine.imageArt = art;
                    rtLine.imageShadow = imgShadow;
                    break;
                }

                NSString *nm = nil, *wt = nil, *st = nil; double sz = 0; NSColor *col = nil;
                NSUInteger used = tryParseFontDirective(line, i, &nm, &sz, &wt, &st);
                if (used > 0) { fontName = nm; fontSize = sz; fontWeight = wt; fontStyle = st; i += used; continue; }
                NSUInteger used2 = tryParseRGBDirective(line, i, &col);
                if (used2 > 0) { color = col; i += used2; continue; }
                NSUInteger used3 = tryParseCmd(line, i, rtLine.segments, fontName, fontSize, fontWeight, fontStyle, color);
                if (used3 > 0) { stampLast(); i += used3; continue; }
                NSUInteger used6 = tryParseVolumeDirective(line, i, rtLine.segments, fontName, fontSize, fontWeight, fontStyle, color);
                if (used6 > 0) { stampLast(); i += used6; continue; }
                // not one of our directives: if it is a titleformat function
                // call, keep the whole expression in the current run so it is
                // compiled as TF syntax (supports nesting, $if/$upper/etc.)
                NSUInteger funcEnd = tfFunctionEnd(line, i);
                if (funcEnd > i) {
                    [run appendString:[line substringWithRange:NSMakeRange(i, funcEnd - i)]];
                    i = funcEnd;
                    continue;
                }
                [run appendFormat:@"%C", c]; i++; continue;
            }
            if (c == '[') {
                // Standard titleformat [...] conditional section (e.g.
                // [%artist%]). Match the closing bracket honoring nesting and
                // single-quote literal regions, and keep the WHOLE span as one
                // run so it reaches the titleformat compiler intact.
                NSInteger depth = 1;
                BOOL inQuote = NO;
                NSUInteger j = i + 1;
                for (; j < n; ++j) {
                    unichar d = [line characterAtIndex:j];
                    if (d == '\'') inQuote = !inQuote;
                    else if (!inQuote) {
                        if (d == '[') depth++;
                        else if (d == ']') { if (--depth == 0) break; }
                    }
                }
                if (j < n) {
                    [run appendString:[line substringWithRange:NSMakeRange(i, j - i + 1)]];
                    i = j + 1;
                    continue;
                }
                [run appendFormat:@"%C", c]; i++; continue;
            }
            if (c == '%') {
                flushRun();
                NSUInteger used = tryParseField(line, i, rtLine.segments, fontName, fontSize, fontWeight, fontStyle, color);
                if (used > 0) { stampLast(); i += used; continue; }
                [run appendFormat:@"%C", c]; i++; continue;
            }
            if (c == '<' || c == '>') {
                if ([paired containsIndex:i]) {
                    flushRun();
                    if (c == '<') dimLevel++; else dimLevel--;
                } else {
                    // unmatched lone bracket: render it literally, no colour
                    [run appendFormat:@"%C", c];
                }
                i++; continue;
            }
            [run appendFormat:@"%C", c]; i++;
        }
        flushRun();
        [lines addObject:rtLine];
    }
    return lines;
}
