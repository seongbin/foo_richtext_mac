#pragma once
#include "stdafx.h"

@interface RichTextPanelViewController : NSViewController
@property (copy) NSString *scriptID;
@property (copy) NSString *defaultFontName;
@property (nonatomic) double defaultFontSize;
@property (nonatomic) double padding;
@property (nonatomic) int backgroundMode;
@end
