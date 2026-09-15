#pragma once
#include "stdafx.h"
#import "RichTextPanelViewController.h"

// Floating popup editor for a single panel's script.
@interface RichTextConfigWindowController : NSWindowController
// Shows the configure window for the given panel instance.
+ (void)configurePanel:(RichTextPanelViewController *)panel;
@end
