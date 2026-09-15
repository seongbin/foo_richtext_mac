#import "stdafx.h"
#import "artloader.h"

namespace {

NSImage * nativeImageFromObj( fb2k::objRef obj ) {
    fb2k::image::ptr im;
    im ^= obj; // cast; yields invalid ptr on mismatch/null
    if (!im.is_valid()) return nil;
    // nativeImage_t is an NSImage* owned by the image object; the shared_ptr
    // below keeps that object alive until our async block has run.
    return (__bridge NSImage *) im->getNative();
}

} // namespace

void rt_load_art(trackRef track, const GUID & artID, std::function<void(NSImage *)> onDone) {
    if ( track.is_empty() || !onDone ) {
        dispatch_async( dispatch_get_main_queue(), ^{ if (onDone) onDone( nil ); } );
        return;
    }
    fb2k::imageLocation_t loc;
    if (!loc.setTrack2(track, artID)) {
        dispatch_async( dispatch_get_main_queue(), ^{ onDone( nil ); } );
        return;
    }

    // The beginLoad() handle must stay alive for the WHOLE async request -
    // releasing it cancels the load. Tie its lifetime to the receiver by
    // capturing it in the completion closure (mirrors albumArtCache keeping
    // m_imageLoader as a member).
    auto keepLoad = std::make_shared<fb2k::objRef>();

    auto recv = fb2k::makeObjReceiver( [onDone, keepLoad]( fb2k::objRef obj ) {
        if ( obj.is_empty() ) {
            dispatch_async( dispatch_get_main_queue(), ^{ onDone( nil ); } );
            return;
        }
        NSImage * img = nativeImageFromObj( obj );
        auto keepAlive = std::make_shared<fb2k::image::ptr>();
        *keepAlive ^= obj;
        dispatch_async( dispatch_get_main_queue(), ^{ onDone( img ); (void)keepAlive; } );
    } );

    *keepLoad = fb2k::imageLoader::get()->beginLoad( loc, fb2k::imageLoader::defArg(), recv );

    if ( keepLoad->is_empty() ) {
        dispatch_async( dispatch_get_main_queue(), ^{ onDone( nil ); } );
    }
}
