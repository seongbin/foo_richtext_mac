#include "stdafx.h"
#include "guids.h"

const char * richtext_default_script() {
	return
    "$font(,16,Semibold)$cmd(Playback/Previous,Prev)$tab()$cmd(Playback/Next,Next)$tab()$cmd(Playback/Random,Random)\n"
    "$crlf(2)\n"
		"$font(,18,Semibold)$if2(%title%,N/A)\n"
    "$crlf()\n"
		"$font(,16,Semibold)<$if2(%artist%,N/A)>\n"
    "$crlf(2)\n"
    "<<$if2(%genre% • ,)$if2($left(%releasedate%,10) • ,)$ifequal(%play_count%,0,Never Played,Played $ifequal(%play_count%,1,once,$ifequal(%play_count%,2,twice,$num(%play_count%,1) time$ifgreater(%play_count%,1,s,))))>>\n"
    "$crlf(2)\n"
    "$image(front)\n"
    "$crlf()\n"
    "$font(,18,Semibold)$if2(%album%,N/A)\n"
    "$crlf()\n"
    "$font(,16,Semibold)<$if2(%album artist%,N/A)>\n"
    "$crlf(2)\n"
    "<<$if2(%date%,)>>\n"
    "<<$if($meta_test(totaltracks),$crlf()$num(%totaltracks%,1) song$ifgreater(%totaltracks%,1,s,),)>>\n"
    "<<$if3($crlf()%publisher%,$crlf()%copyright%,$crlf()%comment%)>>\n"
    "$crlf(2)\n"
    "$cmd(Playback/Volume/Mute,Volume $volume(1)%%)[• %playback_time%]\n"
    "";
}

cfg_string g_richtext_script( guid_richtext_cfg_script, richtext_default_script() );
cfg_string g_richtext_overrides( guid_richtext_cfg_overrides, "{}" );
cfg_string g_richtext_slots( guid_richtext_cfg_slots, "[]" );
cfg_string g_richtext_layout( guid_richtext_cfg_layout, "[]" );
