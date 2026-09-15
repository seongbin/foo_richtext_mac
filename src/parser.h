#pragma once
#include "stdafx.h"

typedef NS_ENUM(uint8_t, RTSegmentKind) {
    RTSegmentText,
    RTSegmentLink,
    RTSegmentVolume,
    RTSegmentImage,
    RTSegmentLiteral,
};

@interface RTSegment : NSObject
@property RTSegmentKind kind;
@property (copy) NSString *text;
@property (copy) NSString *commandPath;
@property (copy) NSString *fontName;
@property double fontSize;
@property (copy) NSString *fontWeight;
@property (copy) NSString *fontStyle;
@property (strong) NSColor *color;
@property (copy) NSString *imageArt;
@property BOOL imageShadow;
@property int mode;
@property int dimLevel;
@end

@interface RTLine : NSObject
@property (strong) NSMutableArray<RTSegment *> *segments;
@property (copy) NSString *imageArt;
@property BOOL imageShadow;
@end

NSArray<RTLine *> * RTParseScript(NSString *script);
NSUInteger findMatchingParen(NSString *s, NSUInteger from);
