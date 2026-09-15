#include "stdafx.h"
#include "commands.h"

#include <cstdio>
#include <cstdarg>
#include <vector>

trackRef rt_get_display_track() {
    playback_control::ptr pc = playback_control::get();
    metadb_handle_ptr item;
    if ( pc.is_valid() && pc->get_now_playing( item ) ) return item;

    playlist_manager::ptr pm = playlist_manager::get();
    if ( pm.is_valid() ) {
        t_size count = pm->activeplaylist_get_item_count();
        if ( count > 0 ) {
            // 1. First selected item when stopped
            pfc::bit_array_bittable mask( count );
            pm->activeplaylist_get_selection_mask( mask );
            for ( t_size i = 0; i < count; ++i ) {
                if ( mask[i] ) return pm->activeplaylist_get_item_handle( i );
            }
            // 2. Cursor/focus item
            t_size focus = pm->activeplaylist_get_focus_item();
            if ( focus < count ) return pm->activeplaylist_get_item_handle( focus );
            // 3. Fallback -> first item
            return pm->activeplaylist_get_item_handle( 0 );
        }
    }
    return metadb_handle_ptr();
}

static void run_context_command(const GUID & guid) {
    metadb_handle_list data;
    auto track = rt_get_display_track();
    if ( track.is_valid() ) data.add_item( track );
    const GUID noSubcommand = {};
    menu_helpers::run_command_context( guid, noSubcommand, data );
}

// ------------------------------------------------------------------
// Full-path command resolution
// ------------------------------------------------------------------

// Diagnostic log written to ~/.foo_richtext_mac_debug.log so failures can be
// inspected without fishing console output out of the user.
static void rt_logf(const char * fmt, ...) {
    pfc::string8 fp;
    const char * home = getenv("HOME");
    if ( home && *home ) { fp = home; fp += "/"; }
    fp += ".foo_richtext_mac_debug.log";
    FILE * f = fopen( fp.c_str(), "a" );
    if ( !f ) return;
    va_list args;
    va_start( args, fmt );
    vfprintf( f, fmt, args );
    va_end( args );
    fputs( "\n", f );
    fclose( f );
}

namespace {

// Splits "Playback/Random" into segments.
void split_path(const char * path, pfc::list_t<pfc::string8> & out) {
    out.remove_all();
    const char * p = path;
    while (*p) {
        const char * slash = strchr(p, '/');
        size_t len = slash ? (size_t)(slash - p) : strlen(p);
        pfc::string8 seg;
        seg.set_string(p, len);
        out.add_item(seg);
        if (!slash) break;
        p = slash + 1;
    }
}

// Maps the standard top-level menu names (which are what $cmd() paths use) to
// their well-known group GUIDs. mainmenu_group_popup exposes no display names
// on macOS, so these constants are the only reliable anchor for path segment 0.
bool top_group_guid(const char * name, GUID & out) {
    struct Entry { const char * n; const GUID & g; };
    static const Entry map[] = {
        { "file",     mainmenu_groups::file },
        { "view",     mainmenu_groups::view },
        { "edit",     mainmenu_groups::edit },
        { "playback", mainmenu_groups::playback },
        { "library",  mainmenu_groups::library },
        { "help",     mainmenu_groups::help },
    };
    for ( const Entry & e : map ) {
        if ( stricmp_utf8( name, e.n ) == 0 ) { out = e.g; return true; }
    }
    return false;
}

GUID group_parent(const GUID & g) {
    struct CachedParent { GUID group; GUID parent; };
    static std::vector<CachedParent> cache;
    for ( const CachedParent & entry : cache ) {
        if ( entry.group == g ) return entry.parent;
    }

    service_enum_t<mainmenu_group> e;
    service_ptr_t<mainmenu_group> x;
    while ( e.next(x) ) {
        if ( x->get_guid() == g ) {
            GUID parent = x->get_parent();
            cache.push_back( { g, parent } );
            return parent;
        }
    }
    cache.push_back( { g, pfc::guid_null } );
    return pfc::guid_null;
}

// True when the group `start` is or descends from (is nested inside) `want`.
bool chain_contains(const GUID & start, const GUID & want) {
    GUID cur = start;
    for ( int guard = 0; guard < 16 && !( cur == pfc::guid_null ); ++guard ) {
        if ( cur == want ) return true;
        cur = group_parent( cur );
    }
    return false;
}

// Number of groups strictly between `start` and the top-level group `top`
// (0 when `start` IS `top`, 1 when `start` is a popup whose parent is `top`,
// ...). Matches the number of unnamed popup levels a path must cross, so a
// 2-segment path like "Playback/Random" prefers depth 0 (direct child of the
// Playback group) while "Playback/Order/Random" needs depth 1 (the Order popup).
unsigned chain_depth(const GUID & start, const GUID & top) {
    unsigned d = 0;
    GUID cur = start;
    for ( int guard = 0; guard < 16 && !( cur == pfc::guid_null ); ++guard ) {
        if ( cur == top ) return d;
        cur = group_parent( cur );
        ++d;
    }
    return UINT_MAX;
}

void rt_log_guid(const char * label, const GUID & g) {
    char buf[64];
    sprintf( buf, "{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
             (unsigned)g.Data1, (unsigned)g.Data2, (unsigned)g.Data3,
             (unsigned)g.Data4[0], (unsigned)g.Data4[1], (unsigned)g.Data4[2], (unsigned)g.Data4[3],
             (unsigned)g.Data4[4], (unsigned)g.Data4[5], (unsigned)g.Data4[6], (unsigned)g.Data4[7] );
    rt_logf( "rt: %s %s", label, buf );
}

// Exact context resolution: "Playback/Random" -> command named "Random" whose
// parent-group chain is nested under the well-known "playback" group. The
// candidate closest to the top-level group (shallowest chain) is the one the
// menu itself would hit first while descending "Playback/Random": on this build
// that is standard_commands::guid_main_random (play random track) at depth 1,
// while the playback-order "Random" toggle sits one level below (depth 2).
// Ambiguous candidates (several at the same shallowest depth) are never fired.
bool try_mainmenu_context(const char * path) {
    const char * leaf = strrchr(path, '/');
    if ( !leaf ) return false;
    pfc::string8 seg0;
    seg0.set_string(path, (t_size)(leaf - path));
    leaf++;
    if ( seg0.is_empty() || !*leaf ) return false;

    GUID topGuid;
    if ( !top_group_guid( seg0.c_str(), topGuid ) ) {
        rt_logf( "rt: seg0 '%s' is not a known top-level group", seg0.c_str() );
        return false;
    }

    struct Candidate {
        GUID guid;
        GUID parent;
        unsigned depth;
    };
    pfc::list_t<Candidate> cands;
    pfc::string8 name;
    service_enum_t<mainmenu_commands> e;
    service_ptr_t<mainmenu_commands> svc;
    while ( e.next(svc) ) {
        service_ptr_t<mainmenu_commands_v2> v2;
        svc->service_query_t( v2 );
        const unsigned n = svc->get_command_count();
        for ( unsigned i = 0; i < n; ++i ) {
            if ( v2.is_valid() && v2->is_command_dynamic(i) ) continue;
            svc->get_name( i, name );
            if ( stricmp_utf8( name, leaf ) != 0 ) continue;
            const GUID parent = svc->get_parent();
            if ( !chain_contains( parent, topGuid ) ) continue;
            Candidate c;
            c.guid = svc->get_command( i );
            c.parent = parent;
            c.depth = chain_depth( parent, topGuid );
            cands.add_item( c );
        }
    }

    if ( cands.get_count() == 0 ) {
        rt_logf( "rt: no static match for '%s'", path );
        return false;
    }

    for ( t_size i = 0; i < cands.get_count(); ++i ) {
        rt_log_guid( "candidate cmd", cands[i].guid );
        rt_log_guid( "candidate parent", cands[i].parent );
        rt_logf( "rt:   depth=%u", cands[i].depth );
    }

    unsigned minDepth = UINT_MAX;
    for ( t_size i = 0; i < cands.get_count(); ++i ) {
        if ( cands[i].depth < minDepth ) minDepth = cands[i].depth;
    }
    Candidate * chosen = nullptr;
    unsigned minCount = 0;
    for ( t_size i = 0; i < cands.get_count(); ++i ) {
        if ( cands[i].depth == minDepth ) {
            ++minCount;
            chosen = &cands[i];
        }
    }

    if ( minCount == 1 ) {
        rt_logf( "rt: chosen '%s' (shallowest depth=%u, %u candidate(s)) -> g_execute", path, minDepth, (unsigned)cands.get_count() );
        return mainmenu_commands::g_execute( chosen->guid, service_ptr_t<service_base>() );
    }

    rt_logf( "rt: ambiguous '%s': %u candidates, %u at shallowest depth - safe skip", path, (unsigned)cands.get_count(), (unsigned)minCount );
    return false;
}

// Exact walk of dynamic command subtrees (the SDK v1-era mainmenu_node API,
// the same pattern as mainmenu_commands_v2::dynamic_execute in mainmenu.cpp).
// Names are compared segment-by-segment, never trimmed.
bool desc_dynamic(mainmenu_node::ptr node, const pfc::list_t<pfc::string8> & segs, unsigned depth) {
    if ( node.is_empty() ) return false;
    const t_uint32 t = node->get_type();
    if ( t == mainmenu_node::type_separator ) return false;

    pfc::string8 text;
    t_uint32 flags = 0;
    node->get_display( text, flags );

    if ( t == mainmenu_node::type_command ) {
        if ( depth + 1 == segs.get_count() && stricmp_utf8( text, segs[depth].c_str() ) == 0 ) {
            node->execute( service_ptr_t<service_base>() );
            return true;
        }
        return false;
    }

    unsigned nextDepth = depth;
    if ( !text.is_empty() ) {
        if ( depth >= segs.get_count() ) return false;
        if ( stricmp_utf8( text, segs[depth].c_str() ) != 0 ) return false;
        nextDepth = depth + 1;
    }
    const t_size n = node->get_children_count();
    for ( t_size c = 0; c < n; ++c ) {
        if ( desc_dynamic( node->get_child(c), segs, nextDepth ) ) return true;
    }
    return false;
}

bool try_mainmenu_dynamic(const char * path) {
    pfc::list_t<pfc::string8> segs;
    split_path(path, segs);
    if ( segs.get_count() < 2 ) return false;

    // No hardcoded top-level-group gate: component menus (e.g. "Playback
    // Statistics/Rating/+") live in popups the standard-group map does not
    // know, so the tree's own display names must anchor the match instead.
    service_enum_t<mainmenu_commands> e;
    service_ptr_t<mainmenu_commands> svc;
    while ( e.next(svc) ) {
        service_ptr_t<mainmenu_commands_v2> v2;
        if ( !svc->service_query_t( v2 ) ) continue;
        const unsigned n = svc->get_command_count();
        for ( unsigned i = 0; i < n; ++i ) {
            if ( !v2->is_command_dynamic(i) ) continue;
            mainmenu_node::ptr root = v2->dynamic_instantiate( i );
            if ( root.is_empty() ) continue;
            // A dynamic tree may be rooted at the top popup itself, at a
            // sub-popup, or at an unnamed wrapper around the leaf items; try
            // matching from every possible start segment so all layouts match.
            for ( unsigned s = 0; s < segs.get_count(); ++s ) {
                if ( desc_dynamic( root, segs, s ) ) {
                    rt_logf( "rt: dynamic context match '%s'", path );
                    return true;
                }
            }
        }
    }
    rt_logf( "rt: no dynamic match for '%s'", path );
    return false;
}

// Exact walk of a built context menu (menu_tree_item API) matching the full
// slash-path against node display names. Descends through itemSubmenu nodes by
// name until the final segment names an itemCommand, which is then executed.
// This is what the SDK-native g_find_by_name / run_main helpers cannot do for
// multi-level component trees like "Playback Statistics/Rating/-", whose +/- 
// items are context commands on the now-playing track, not main-menu commands.
bool desc_ctx_item(menu_tree_item::ptr node, const pfc::list_t<pfc::string8> & segs, unsigned depth) {
    const auto t = node->type();
    if ( depth + 1 == segs.get_count() ) {
        if ( t == menu_tree_item::itemCommand && stricmp_utf8( node->name(), segs[depth].c_str() ) == 0 ) {
            node->execute( service_ptr_t<service_base>() );
            return true;
        }
        return false;
    }
    if ( t != menu_tree_item::itemSubmenu || stricmp_utf8( node->name(), segs[depth].c_str() ) != 0 ) return false;
    const size_t n = node->childCount();
    for ( size_t i = 0; i < n; ++i ) {
        if ( desc_ctx_item( node->childAt( i ), segs, depth + 1 ) ) return true;
    }
    return false;
}

static bool try_context_now_playing(const char * path) {
    pfc::list_t<pfc::string8> segs;
    split_path(path, segs);
    if ( segs.get_count() < 2 ) return false;

    service_ptr_t<contextmenu_manager> base = contextmenu_manager::g_create();
    service_ptr_t<contextmenu_manager_v2> mgr;
    if ( base.is_empty() || !base->service_query_t( mgr ) ) {
        rt_logf( "rt: no context menu manager for '%s'", path );
        return false;
    }
    if ( !mgr->init_context_now_playing( 0 ) ) {
        rt_logf( "rt: no now-playing context menu for '%s'", path );
        return false;
    }
    menu_tree_item::ptr root = mgr->build_menu();
    if ( root.is_empty() ) {
        rt_logf( "rt: empty context menu for '%s'", path );
        return false;
    }
    const size_t n = root->childCount();
    for ( size_t i = 0; i < n; ++i ) {
        if ( desc_ctx_item( root->childAt( i ), segs, 0 ) ) {
            rt_logf( "rt: context-menu match '%s'", path );
            return true;
        }
    }
    rt_logf( "rt: no context-menu match for '%s'", path );
    return false;
}

// Safe leaf fallback: if the last path segment uniquely identifies exactly ONE
// registered main-menu command, execute it. Ambiguous leaves ("Random" exists
// in more than one menu) are never fired here, so the earlier "executed Random
// instead of Playback/Random" bug cannot recur, while the built-in UI features
// (click artwork -> play or pause, safe-area double-click -> show now playing,
// wheel on artwork -> volume) keep working even when they are not nested under
// a known top-level group.
bool try_leaf_unique(const char * path) {
    const char * leaf = path;
    const char * slash = strrchr(path, '/');
    if ( slash ) leaf = slash + 1;

    GUID found = pfc::guid_null;
    unsigned matches = 0;
    pfc::string8 name;
    service_enum_t<mainmenu_commands> e;
    service_ptr_t<mainmenu_commands> svc;
    while ( e.next(svc) ) {
        const unsigned n = svc->get_command_count();
        for ( unsigned i = 0; i < n; ++i ) {
            svc->get_name( i, name );
            if ( stricmp_utf8( name, leaf ) == 0 ) {
                ++matches;
                if ( matches == 1 ) found = svc->get_command( i );
            }
        }
    }
    if ( matches != 1 ) {
        rt_logf( "rt: leaf '%s' for '%s' has %u matches - safe skip", leaf, path, matches );
        return false;
    }
    rt_logf( "rt: leaf '%s' for '%s' unique -> g_execute", leaf, path );
    return mainmenu_commands::g_execute( found, service_ptr_t<service_base>() );
}

} // namespace

bool rt_run_command_by_path(const char * path) {
    if ( !path || !*path ) return false;
    try {
        rt_logf( "rt: resolve '%s'", path );

        // 1. Exact context resolution (top-level group + unique leaf within it).
        if ( try_mainmenu_context( path ) ) {
            return true;
        }

        // 2. Exact dynamic-subtree resolution (Playback/Order/Random style).
        if ( try_mainmenu_dynamic( path ) ) {
            return true;
        }

        // 3. Safe unique-leaf fallback (never fires ambiguous leaves).
        if ( try_leaf_unique( path ) ) {
            return true;
        }

        // 4. Context-menu on the now-playing track (component trees like
        //    "Playback Statistics/Rating/-" whose +/- are context commands).
        if ( try_context_now_playing( path ) ) {
            return true;
        }

        // 5. SDK-native resolvers, full string only (no trimming).
        GUID ctxGuid;
        if ( menu_helpers::find_command_by_name( path, ctxGuid ) ) {
            run_context_command( ctxGuid );
            return true;
        }
        GUID mainGuid;
        if ( mainmenu_commands::g_find_by_name( path, mainGuid ) ) {
            mainmenu_commands::g_execute( mainGuid );
            return true;
        }

        rt_logf( "rt: unknown command '%s'", path );
        return false;
    } catch (...) {
        rt_logf( "rt: exception while resolving '%s'", path );
        return false;
    }
}