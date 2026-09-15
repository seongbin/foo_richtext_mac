#pragma once
#include "stdafx.h"

// {A3687338-A539-472F-A25F-9492EC5D86C9}
static const GUID guid_richtext_element =
{ 0xa3687338, 0xa539, 0x472f, { 0xa2, 0x5f, 0x94, 0x92, 0xec, 0x5d, 0x86, 0xc9 } };

// {91289522-4DFA-4D74-8142-C407D0F20BAF}
static const GUID guid_richtext_cfg_script =
{ 0x91289522, 0x4dfa, 0x4d74, { 0x81, 0x42, 0xc4, 0x07, 0xd0, 0xf2, 0x0b, 0xaf } };

// {6D3E7C42-9A51-4F08-B2D6-31E7A5C90F84} - JSON map of per-instance scripts
static const GUID guid_richtext_cfg_overrides =
{ 0x6d3e7c42, 0x9a51, 0x4f08, { 0xb2, 0xd6, 0x31, 0xe7, 0xa5, 0xc9, 0x0f, 0x84 } };

// {EF5E6F4E-3F1F-4206-B688-F445AAA5F49E} - JSON array of auto-slot names,
// binding id-less panels to stable configs across relayouts and restarts
static const GUID guid_richtext_cfg_slots =
{ 0xef5e6f4e, 0x3f1f, 0x4206, { 0xb6, 0x88, 0xf4, 0x45, 0xaa, 0xa5, 0xf4, 0x9e } };

// {B75A4FE6-52C7-4A2B-9D24-C3F2D0E6B1A5} - JSON array of panel keys present in
// the last settled layout (used to purge configs of panels removed/never built)
static const GUID guid_richtext_cfg_layout =
{ 0xb75a4fe6, 0x52c7, 0x4a2b, { 0x9d, 0x24, 0xc3, 0xf2, 0xd0, 0xe6, 0xb1, 0xa5 } };

extern cfg_string g_richtext_script;     // default script (instances without id)
extern cfg_string g_richtext_overrides;  // JSON: { "id": "script", ... }
extern cfg_string g_richtext_slots;      // JSON: ["#0", "#1", ...]
extern cfg_string g_richtext_layout;     // JSON: ["#0", "myid", ...] last settled layout
const char * richtext_default_script();
