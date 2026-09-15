#pragma once
#include "stdafx.h"

// Executes an internal foobar2000 command referenced by display name.
bool rt_run_command_by_path(const char * path);

// Returns the track the panel should display: now playing, else first selected.
trackRef rt_get_display_track();
