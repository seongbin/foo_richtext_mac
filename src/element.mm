#import "stdafx.h"
#import "guids.h"
#import "notify.h"
#import "scriptstore.h"
#import "Mac/RichTextPanelViewController.h"
#import "parser.h"
#import "renderer.h"
#include <atomic>

class ui_element_richtext : public ui_element_mac {
public:
    service_ptr instantiate( service_ptr arg ) override {
        NSDictionary * args = nil;
        if ( arg.is_valid() ) {
            NSObject * obj = fb2k::unwrapNSObject( arg );
            if ( [obj isKindOfClass:[NSDictionary class]] ) args = (NSDictionary *) obj;
        }
        RichTextPanelViewController * vc = [RichTextPanelViewController new];
        vc.scriptID = [RTScriptStore acquireKeyForID:args[@"id"]];
        vc.defaultFontName = args[@"font-name"];
        vc.defaultFontSize = [args[@"font-size"] doubleValue];
        vc.padding = [args[@"padding"] doubleValue];
        vc.backgroundMode = [args[@"background"] intValue];
        return fb2k::wrapNSObject( vc );
    }
    bool match_name( const char * name ) override {
        return name && stricmp_utf8( name, "richtext" ) == 0;
    }
    fb2k::stringRef get_name() override { return fb2k::makeString("Rich Text Panel"); }
    GUID get_guid() override { return guid_richtext_element; }
};

static service_factory_single_t<ui_element_richtext> g_element_factory;

namespace {

struct playback_watcher : play_callback_static {
    std::atomic<unsigned> stopGeneration { 0 };

    unsigned get_flags() override {
        return flag_on_playback_starting | flag_on_playback_new_track | flag_on_playback_stop
             | flag_on_playback_edited | flag_on_playback_pause
             | flag_on_playback_seek | flag_on_playback_time | flag_on_volume_change;
    }
    void on_playback_starting(play_control::t_track_command, bool) noexcept {
        stopGeneration.fetch_add(1, std::memory_order_relaxed);
    }
    void on_playback_new_track(metadb_handle_ptr) noexcept {
        stopGeneration.fetch_add(1, std::memory_order_relaxed);
        rt_notify_refresh();
    }
    void on_playback_stop(play_control::t_stop_reason) noexcept {
        // During next-track transitions foobar briefly clears the metadb and
        // reports stopped before the replacement track is available.
        unsigned generation = stopGeneration.fetch_add(1, std::memory_order_relaxed) + 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (stopGeneration.load(std::memory_order_relaxed) != generation)
                return;

            metadb_handle_ptr nowPlaying;
            playback_control::ptr pc = playback_control::get();
            if (pc.is_valid() && pc->get_now_playing(nowPlaying)) return;

            rt_notify_refresh();
        });
    }
    void on_playback_seek(double) noexcept { rt_notify_refresh(); }
    void on_playback_pause(bool) noexcept { rt_notify_refresh(); }
    void on_playback_edited(metadb_handle_ptr) noexcept { rt_notify_refresh(); }
    void on_playback_dynamic_info(const file_info &) noexcept {}
    void on_playback_dynamic_info_track(const file_info &) noexcept {}
    void on_playback_time(double time) noexcept {
        static double lastWholeSecond = -1;
        double whole = (double)(long long)time;
        if (whole != lastWholeSecond) {
            lastWholeSecond = whole;
            rt_notify_refresh();
        }
    }
    void on_volume_change(float) noexcept { rt_notify_refresh(); }
};

// refresh when active playlist selection changes
struct selection_watcher : playlist_callback_static {
    unsigned get_flags() override { return playlist_callback::flag_on_items_selection_change; }
    void on_items_selection_change(t_size playlist, const bit_array &, const bit_array &) override {
        if (playlist == playlist_manager::get()->get_active_playlist()) rt_notify_refresh();
    }
    void on_items_added(t_size, t_size, const pfc::list_base_const_t<metadb_handle_ptr> &, const bit_array &) override {}
    void on_items_reordered(t_size, const t_size *, t_size) override {}
    void on_items_removing(t_size, const bit_array &, t_size, t_size) override {}
    void on_items_removed(t_size, const bit_array &, t_size, t_size) override {}
    void on_item_focus_change(t_size, t_size, t_size) override {}
    void on_items_modified(t_size, const bit_array &) override {}
    void on_items_modified_fromplayback(t_size, const bit_array &, play_control::t_display_level) override {}
    void on_items_replaced(t_size, const bit_array &, const pfc::list_base_const_t<t_on_items_replaced_entry> &) override {}
    void on_item_ensure_visible(t_size, t_size) override {}
    void on_playlist_activate(t_size, t_size) override {}
    void on_playlist_created(t_size, const char *, t_size) override {}
    void on_playlists_reorder(const t_size *, t_size) override {}
    void on_playlists_removing(const bit_array &, t_size, t_size) override {}
    void on_playlists_removed(const bit_array &, t_size, t_size) override {}
    void on_playlist_renamed(t_size, const char *, t_size) override {}
    void on_default_format_changed() override {}
    void on_playback_order_changed(t_size) override {}
    void on_playlist_locked(t_size, bool) override {}
};

// Refresh when foobar2000 rewrites any track's tags/metadb contents —
// independent of playback state. This fires for Playback Statistics bumps
// (%play_count%), title/tag edits, and metadb_io tag rewrites. Each changed
// item's per-track TF eval cache entry is dropped and a refresh is requested.
struct metadb_watcher : metadb_io_callback {
    void on_changed_sorted(metadb_handle_list_cref p_items_sorted,
                           bool p_fromhook) override {
        for ( t_size i = 0; i < p_items_sorted.get_size(); ++i ) {
            RTInvalidateEvalCacheForTrack(p_items_sorted[i]);
        }
        rt_notify_refresh();
    }
};

static service_factory_single_t<metadb_watcher> g_metadb_watcher;
static service_factory_single_t<playback_watcher> g_playback_watcher;
static service_factory_single_t<selection_watcher> g_selection_watcher;

struct host_init_cleanup : initquit {
    void on_init() override { [RTScriptStore purgeUnloadedConfigs]; }
};
static service_factory_single_t<host_init_cleanup> g_init_cleanup_factory;

}
