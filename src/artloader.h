#pragma once
#include "stdafx.h"
#import <AppKit/AppKit.h>

// Asynchronously loads artwork (embedded or standalone file) for a track.
// onDone is always invoked on the main queue; nil image = not found.
void rt_load_art(trackRef track, const GUID & artID, std::function<void(NSImage *)> onDone);
