#import "stdafx.h"
#import "RichTextPanelViewController.h"
#import "RichTextConfigWindowController.h"
#import "../parser.h"
#import "../renderer.h"
#import "../artloader.h"
#import "../commands.h"
#import "../notify.h"
#import "../scriptstore.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kPanelLineHeightMultiple = 1.2;

#pragma mark - Text view

@interface RTTextView : NSTextView
@property (nonatomic, copy) void (^onLinkClick)(NSString * url);
@property (nonatomic, copy) BOOL (^onScrollWheel)(NSEvent * event);
@property (nonatomic, copy) NSMenu * (^menuForEventBlock)(NSEvent * event);
@end

@interface RTAppearanceView : NSView
@property (nonatomic, copy) void (^onEffectiveAppearanceChange)(void);
@end

@implementation RTAppearanceView
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    if (self.onEffectiveAppearanceChange) self.onEffectiveAppearanceChange();
}
@end

@implementation RTTextView
- (BOOL)acceptsFirstResponder { return NO; }
- (NSFocusRingType)focusRingType { return NSFocusRingTypeNone; }
- (NSMenu *)menuForEvent:(NSEvent *)event {
    if (self.menuForEventBlock) return self.menuForEventBlock(event);
    return self.menu;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea * ta in self.trackingAreas)
        [self removeTrackingArea:ta];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                          options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                            owner:self
                                                         userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger idx = [[self layoutManager] characterIndexForPoint:p
                                                  inTextContainer:self.textContainer
                         fractionOfDistanceBetweenInsertionPoints:NULL];
    if (idx < self.textStorage.length &&
        [self.textStorage attribute:NSLinkAttributeName atIndex:idx effectiveRange:NULL]) {
        [[NSCursor pointingHandCursor] set];
    } else {
        [[NSCursor arrowCursor] set];
    }
}
// arrow cursor everywhere except over $cmd links, which get the hand
- (void)resetCursorRects {
    [self discardCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor arrowCursor]];
    NSLayoutManager * lm = [self layoutManager];
    NSString * s = [self.textStorage string];
    if (s.length == 0) return;
    [self.textStorage enumerateAttribute:NSLinkAttributeName
                                 inRange:NSMakeRange(0, s.length)
                                 options:0
                              usingBlock:^(id value, NSRange range, BOOL * stop) {
        if (!value) return;
        NSRange glyphs = [lm glyphRangeForCharacterRange:range actualCharacterRange:NULL];
        [lm enumerateLineFragmentsForGlyphRange:glyphs
                                     usingBlock:^(NSRect usedRect, NSRect fragRect,
                                                  NSTextContainer * fragContainer,
                                                  NSRange lineGlyphs, BOOL * s2) {
            NSPoint o = [self textContainerOrigin];
            usedRect.origin.x += o.x;
            usedRect.origin.y += o.y;
            [self addCursorRect:usedRect cursor:[NSCursor pointingHandCursor]];
        }];
    }];
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger idx = [[self layoutManager] characterIndexForPoint:p
                                                  inTextContainer:self.textContainer
                         fractionOfDistanceBetweenInsertionPoints:NULL];
    NSDictionary * attrs = nil;
    if (idx < self.textStorage.length) {
        NSRange eff = NSMakeRange(0, 0);
        attrs = [self.textStorage attributesAtIndex:idx effectiveRange:&eff];
    }
    // single click on artwork -> play or pause
    if (attrs[NSAttachmentAttributeName] != nil) {
        [self setSelectedRange:NSMakeRange(0, 0)];
        rt_run_command_by_path("Playback/Play or Pause");
        return;
    }
    // links are handled here on purpose: calling [super mouseDown:] first would
    // make NSTextView deliver the same click to the delegate as well, running
    // the $cmd command twice (e.g. Volume/Mute toggling twice = no-op).
    id linkVal = attrs[NSLinkAttributeName];
    if (linkVal && self.onLinkClick) {
        NSString * url = nil;
        if ([linkVal isKindOfClass:NSURL.class]) url = [(NSURL *)linkVal absoluteString];
        else if ([linkVal isKindOfClass:NSString.class]) url = (NSString *)linkVal;
        if (url.length > 0) {
            [self setSelectedRange:NSMakeRange(0, 0)];
            self.onLinkClick(url);
            return;
        }
    }
    if (event.clickCount >= 2) {
        // double-click on the panel's safe area -> show playing track in playlist
        [self setSelectedRange:NSMakeRange(0, 0)];
        rt_run_command_by_path("View/Show Now Playing in Playlist");
        return;
    }
    [super mouseDown:event];
    [self setSelectedRange:NSMakeRange(0, 0)];
}
- (void)scrollWheel:(NSEvent *)event {
    if (self.onScrollWheel && self.onScrollWheel(event)) return;
    [super scrollWheel:event];
}
@end

#pragma mark - Controller

@interface RichTextPanelViewController () <NSTextViewDelegate, RTRefreshListener, NSLayoutManagerDelegate>
@property (strong) RTTextView *textView;
@property (strong) NSScrollView *scrollView;
@property (strong) NSArray<RTLine *> *lines;
@property (copy) NSString *lastScript;
@property (strong) NSMutableDictionary<NSString *, NSString *> *commandTable;
@property (strong) id keyMonitor;
@property (nonatomic) BOOL refreshPending;
@property (copy) NSString *lastArtworkKey;
@property (nonatomic) BOOL lastArtworkLoaded;
@property (nonatomic) NSRange lastArtRange;
@property (nonatomic) BOOL isDarkModeDirty;
@property (nonatomic) BOOL darkModeCachedValue;
@property (nonatomic) BOOL lastDarkMode;
@property (strong) NSImage *pendingArtworkTransitionImage;
@property (nonatomic) NSRect pendingArtworkTransitionRect;
@property (strong) CALayer *artworkBackgroundLayer;
@property (strong) NSArray<CALayer *> *artworkImageLayers;
@property (strong) CALayer *artworkDimMaskLayer;
@property (copy) NSString *artworkBackgroundKey;
@property (nonatomic) CGSize artworkBackgroundSize;
@end

// Geometry of the artwork attachment whose character index is known up front
// (reported by the renderer), so no full-storage scan is required.
static NSRect RTRectForAttachment(NSTextView *textView, NSUInteger attachmentIndex,
                                  NSTextAttachment **outAttachment) {
    NSAttributedString * storage = textView.textStorage;
    if (attachmentIndex != NSNotFound && attachmentIndex < storage.length) {
        NSTextAttachment * attachment = [storage attribute:NSAttachmentAttributeName
                                                   atIndex:attachmentIndex
                                            effectiveRange:NULL];
        if ([attachment isKindOfClass:NSTextAttachment.class]) {
            if (outAttachment) *outAttachment = attachment;
            NSLayoutManager *layoutManager = textView.layoutManager;
            [layoutManager ensureLayoutForTextContainer:textView.textContainer];
            NSRange glyphRange = [layoutManager glyphRangeForCharacterRange:
                                  NSMakeRange(attachmentIndex, 1) actualCharacterRange:NULL];
            NSRect rect = [layoutManager boundingRectForGlyphRange:glyphRange
                                                  inTextContainer:textView.textContainer];
            NSPoint origin = textView.textContainerOrigin;
            rect.origin.x += origin.x;
            rect.origin.y += origin.y;
            return rect;
        }
    }
    if (outAttachment) *outAttachment = nil;
    return NSZeroRect;
}

static NSImage * RTTransparentImage(NSSize size) {
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];
    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));
    [image unlockFocus];
    return image;
}

@implementation RichTextPanelViewController

- (void)loadView {
    RTAppearanceView * root = [[RTAppearanceView alloc] initWithFrame:NSMakeRect(0, 0, 420, 260)];
    root.wantsLayer = YES;

    // background=1 (default): translucent material overlay as before.
    // background=0: no overlay — the host's default background shows through.
    // background=2: opaque artwork-derived color, applied once it's loaded.
    if (self.backgroundMode == 1) {
        NSVisualEffectView * fx = [[NSVisualEffectView alloc] initWithFrame:root.bounds];
        fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        fx.material = NSVisualEffectMaterialSidebar;
        fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        fx.state = NSVisualEffectStateActive;
        [root addSubview:fx positioned:NSWindowBelow relativeTo:nil];
    } else if (self.backgroundMode == 2) {
        root.layer.backgroundColor = [[NSColor textBackgroundColor] CGColor];
        CALayer *background = [CALayer layer];
        background.frame = root.bounds;
        background.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        background.masksToBounds = YES;
        [root.layer addSublayer:background];
        self.artworkBackgroundLayer = background;
    }

    NSScrollView * scroll = [[NSScrollView alloc] initWithFrame:root.bounds];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = NO;
    scroll.hasHorizontalScroller = NO;
    scroll.drawsBackground = NO;
    [root addSubview:scroll];

    RTTextView * tv = [[RTTextView alloc] initWithFrame:NSMakeRect(0, 0, root.bounds.size.width, root.bounds.size.height)];
    tv.editable = NO;
    tv.selectable = NO;
    tv.drawsBackground = NO;
    tv.richText = YES;
    tv.automaticLinkDetectionEnabled = NO;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.minSize = NSZeroSize;
    tv.maxSize = CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX);
    tv.textContainerInset = NSZeroSize;
    __weak typeof(self) wself = self;
    tv.onLinkClick = ^(NSString * url){ [wself textView:nil clickedOnLink:url atIndex:0]; };
    tv.onScrollWheel = ^BOOL(NSEvent * e){ return [wself handleScrollWheel:e]; };
    tv.menuForEventBlock = ^NSMenu *(NSEvent * event) {
        NSPoint p = [wself.textView convertPoint:event.locationInWindow fromView:nil];
        return [wself contextMenuForPoint:p];
    };
    tv.textContainer.lineFragmentPadding = 0;
    tv.textContainer.widthTracksTextView = YES;
    tv.layoutManager.delegate = self;
    tv.layoutManager.usesFontLeading = NO;
    NSMutableDictionary * lt = [(NSDictionary *)tv.linkTextAttributes mutableCopy] ?: [NSMutableDictionary new];
    lt[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleNone); // no default underline
    // Remove the default link foreground (system blue) so per-run colors from
    // $rgb apply to $cmd labels; the renderer supplies a blue default instead.
    [lt removeObjectForKey:NSForegroundColorAttributeName];
    [lt removeObjectForKey:@"NSColor"];
    tv.linkTextAttributes = lt;
    tv.delegate = self;
    scroll.documentView = tv;

    CGFloat p = self.padding;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:root.topAnchor constant:p],
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-p],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:p],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-p],
    ]];

    self.view = root;
    self.textView = tv;
    self.scrollView = scroll;
    self.commandTable = [NSMutableDictionary new];
    self.isDarkModeDirty = YES;

    root.onEffectiveAppearanceChange = ^{
        wself.isDarkModeDirty = YES;
        [wself render];
    };
    rt_add_listener(self);
    [self installKeyMonitor];
    [self render];
}

- (void)dealloc {
    if (self.keyMonitor) {
        [NSEvent removeMonitor:self.keyMonitor];
        self.keyMonitor = nil;
    }
    [RTScriptStore releaseKey:self.scriptID];
    rt_remove_listener(self);
}

// Route left/right arrow keys to the seek commands while the panel's window is
// key, regardless of which subview holds first responder. Also assign Cmd+N / Cmd+W.
// Commands run via rt_run_command_by_path (name-based, mac-GUID agnostic);
// standard_commands::guid_* constants are the Windows-era command GUIDs and do
// not resolve on the mac port, so they are not used here.
- (void)installKeyMonitor {
    if (self.keyMonitor) return;
    __weak typeof(self) wself = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.window != wself.view.window) return event;
        NSEventModifierFlags mods = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl);
        if (mods == NSEventModifierFlagCommand) {
            switch (event.keyCode) {
                case 45: // n -> File/New Playlist
                    rt_run_command_by_path("File/New Playlist");
                    return nil; // consume
                case 13: // w -> File/Remove Playlist
                    rt_run_command_by_path("File/Remove Playlist");
                    return nil; // consume
                case 35: // p -> View/Playlist Manager
                    rt_run_command_by_path("View/Playlist Manager");
                    return nil; // consume
                case 32: // u -> File/Add Location...
                    rt_run_command_by_path("File/Add Location...");
                    return nil; // consume
                case 123: // cmd+left -> File/Previous Playlist
                    rt_run_command_by_path("File/Previous Playlist");
                    return nil; // consume
                case 124: // cmd+right -> File/Next Playlist
                    rt_run_command_by_path("File/Next Playlist");
                    return nil; // consume
                default:
                    break;
            }
        }
        switch (event.keyCode) {
            case 123: // left arrow
                rt_run_command_by_path("Playback/Seek/Back by 10 Seconds");
                return nil; // consume
            case 124: // right arrow
                rt_run_command_by_path("Playback/Seek/Ahead by 10 Seconds");
                return nil; // consume
            default:
                return event;
        }
    }];
}

// re-render on resize so $image() lines rescale with the panel width
- (void)viewDidLayout {
    [super viewDidLayout];
    self.artworkBackgroundLayer.frame = self.view.bounds;
    [self render];
}

// right-click menu
- (NSMenu *)contextMenuForPoint:(NSPoint)p {
    NSMenu * m = [NSMenu new];
    BOOL showArtwork = [self hasImageInScript] && [self pointIsOverArtwork:p];
    if (showArtwork) {
        [m addItem:[NSMenuItem separatorItem]];
    }
    NSMenuItem * configure = [[NSMenuItem alloc] initWithTitle:@"Configure…" action:@selector(onConfigure:) keyEquivalent:@""];
    configure.target = self;
    [m addItem:configure];
    return m;
}

- (BOOL)hasImageInScript {
    for (RTLine * line in self.lines)
        if (line.imageArt.length > 0) return YES;
    return NO;
}

- (BOOL)pointIsOverArtwork:(NSPoint)p {
    NSLayoutManager * lm = self.textView.layoutManager;
    NSAttributedString * storage = self.textView.textStorage;
    NSString * s = storage.string;
    if (lm == nil || s.length == 0) return NO;
    __block BOOL over = NO;
    [storage enumerateAttribute:NSAttachmentAttributeName
                        inRange:NSMakeRange(0, s.length)
                       options:0
                    usingBlock:^(id value, NSRange range, BOOL * stop) {
        if (!value) return;
        NSRange glyphRange = [lm glyphRangeForCharacterRange:range
                                        actualCharacterRange:NULL];
        NSRect tvRect = [lm boundingRectForGlyphRange:glyphRange
                                      inTextContainer:self.textView.textContainer];
        tvRect.origin.x += self.textView.textContainerOrigin.x;
        tvRect.origin.y += self.textView.textContainerOrigin.y;
        if (NSPointInRect(p, NSInsetRect(tvRect, -4, -4))) {
            over = YES;
            *stop = YES;
        }
    }];
    return over;
}

- (void)onConfigure:(id)sender {
    [RichTextConfigWindowController configurePanel:self];
}

- (BOOL)isDarkMode {
    // Recompute only when the effective appearance actually changed; the view
    // marks the cache dirty via onEffectiveAppearanceChange.
    if (!self.isDarkModeDirty) return self.darkModeCachedValue;
    self.isDarkModeDirty = NO;
    BOOL dark = NO;
    if (@available(macOS 10.14, *)) {
        NSAppearanceName match = [self.view.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
        dark = [match isEqualToString:NSAppearanceNameDarkAqua];
    }
    self.darkModeCachedValue = dark;
    return dark;
}

- (void)rtRefresh {
    // Coalesce refresh notifications (a burst — e.g. a Playback Statistics
    // write-back on top of the end-of-track playback callbacks — would each
    // otherwise trigger a full page re-render) into a single render per tick.
    if (self.refreshPending) return;
    self.refreshPending = YES;
    __weak typeof(self) wself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) sself = wself;
        if (!sself) return;
        sself.refreshPending = NO;
        [sself render];
    });
}

// Forcibly set a uniform line-fragment height per font size so Latin and CJK
// lines (whose fallback fonts have different natural metrics) render at the
// same height. NSParagraphStyle min/max line height is unreliable for mixed
// scripts; this layout-manager delegate overrides it reliably.
- (BOOL)layoutManager:(NSLayoutManager *)layoutManager
    shouldSetLineFragmentRect:(NSRect *)lineFragmentRect
    lineFragmentUsedRect:(NSRect *)usedRect
    baselineOffset:(CGFloat *)baselineOffset
    inTextContainer:(NSTextContainer *)container
    forGlyphRange:(NSRange)glyphRange {
    NSTextStorage * ts = layoutManager.textStorage;
    // Let lines that contain image/artwork attachments keep their natural full
    // height; forcing a small uniform height would clip the image into the
    // following line's area.
    NSRange charRange = [layoutManager characterRangeForGlyphRange:glyphRange actualGlyphRange:NULL];
    if (charRange.location != NSNotFound && ts.length > 0) {
        __block BOOL hasAttachment = NO;
        [ts enumerateAttribute:NSAttachmentAttributeName inRange:charRange options:0
                    usingBlock:^(id value, NSRange r, BOOL * stop) {
            if (value) { hasAttachment = YES; *stop = YES; }
        }];
        if (hasAttachment) return NO;
    }
    NSFont * font = ts.length > 0 ? [ts attribute:NSFontAttributeName atIndex:glyphRange.location effectiveRange:NULL] : nil;
    if (!font) {
        font = self.defaultFontName.length > 0 ? [NSFont fontWithName:self.defaultFontName size:self.defaultFontSize] : [NSFont systemFontOfSize:self.defaultFontSize];
        if (!font) font = [NSFont systemFontOfSize:self.defaultFontSize];
    }
    CGFloat lineHeight = ceil(font.pointSize * kPanelLineHeightMultiple + 1.0);
    NSRect frag = *lineFragmentRect;
    NSRect use = *usedRect;
    frag.size.height = lineHeight;
    use.size.height = MAX(lineHeight, use.size.height);
    *lineFragmentRect = frag;
    *usedRect = use;
    return YES;
}

- (void)render {
    trackRef track = rt_get_display_track();
    NSString * artworkKey = [RTRenderer artCacheKey:track name:@"front"];
    BOOL artworkChanged = self.lastArtworkKey != nil &&
        ![self.lastArtworkKey isEqualToString:(artworkKey ?: @"")];
    NSImage *cachedArtwork = artworkKey ? [[RTArtCache shared] get:artworkKey] : nil;
    BOOL currentArtworkLoaded = cachedArtwork != nil &&
        cachedArtwork.size.width > 16.0 && cachedArtwork.size.height > 16.0;
    BOOL currentArtworkUnavailable = cachedArtwork != nil &&
        cachedArtwork.size.width <= 16.0 && cachedArtwork.size.height <= 16.0;
    if (artworkChanged) {
        self.pendingArtworkTransitionImage = nil;
        self.pendingArtworkTransitionRect = NSZeroRect;
        if (self.lastArtworkLoaded) {
            NSTextAttachment *oldAttachment = nil;
            NSRect oldRect = RTRectForAttachment(_textView, self.lastArtRange.location, &oldAttachment);
            NSImage *oldImage = ((NSTextAttachmentCell *)oldAttachment.attachmentCell).image;
            if (oldImage && !NSIsEmptyRect(oldRect)) {
                self.pendingArtworkTransitionImage = oldImage;
                self.pendingArtworkTransitionRect = oldRect;
            }
        }
    }
    BOOL canAnimateArtwork = self.pendingArtworkTransitionImage != nil && currentArtworkLoaded;
    self.lastArtworkKey = [artworkKey copy] ?: @"";
    self.lastArtworkLoaded = currentArtworkLoaded;

    NSString * script = [RTScriptStore scriptForID:self.scriptID];
    BOOL scriptChanged = ![script isEqualToString:self.lastScript];
    if (scriptChanged) {
        self.lines = RTParseScript(script);
        self.lastScript = [script copy];
    }

    NSColor * defaultTextColor = self.backgroundMode == 2 ? [NSColor whiteColor] : nil;
    NSColor * defaultBgColor = nil;
    if (self.backgroundMode == 2) {
        NSImage * cached = cachedArtwork;
        BOOL isFailureMarker = (cached != nil && cached.size.width <= 16.0 && cached.size.height <= 16.0);
        if (cached != nil && !isFailureMarker) {
            [self applyArtworkBackgroundForTrack:track defaultTextColor:&defaultTextColor defaultBgColor:&defaultBgColor];
        } else if (artworkKey) {
            // ensure the artwork load is in flight; scheduleArtLoad re-renders
            if (isFailureMarker) [self resetPanelBackground];
            [self scheduleArtLoad:@"front" track:track];
        } else {
            [self resetPanelBackground];
        }
    } else if (self.backgroundMode == 0) {
        [self resetPanelBackground];
    }

    NSMutableDictionary * cmds = [NSMutableDictionary new];
    __weak typeof(self) wself = self;
    CGFloat contentWidth = _textView.textContainer.containerSize.width;
    if (contentWidth <= 1.0) contentWidth = 280.0; // fallback before first layout
NSRect visible = [_scrollView documentVisibleRect];
    CGFloat contentHeight = visible.size.height;
    if (contentHeight <= 1.0) contentHeight = _scrollView.bounds.size.height;
    if (contentHeight <= 1.0) contentHeight = 260.0; // fallback before first layout
    BOOL dark = self.isDarkMode;
    NSRange artRange = NSMakeRange(NSNotFound, 0);
    BOOL hasArt = NO;
    NSAttributedString * as = [RTRenderer renderLines:self.lines
                                                track:track
                                         commandTable:cmds
                                             darkMode:dark
                                            maxWidth:contentWidth
                                           maxHeight:contentHeight
                                          backgroundMode:self.backgroundMode
                                     defaultTextColor:defaultTextColor
                                 defaultBackgroundColor:defaultBgColor
                                      defaultFontSize:self.defaultFontSize
                                       defaultFontName:self.defaultFontName
                                           loadHandler:^(NSString * artName){ [wself scheduleArtLoad:artName track:track]; }
                                        artRangeOut:&artRange];
    hasArt = artRange.location != NSNotFound;
    self.commandTable = cmds;

    // Keep the outgoing artwork visible while the random-playback artwork is
    // still loading; replacing it with the new track's placeholder creates a
    // blank frame before the transition can begin.
    if (self.pendingArtworkTransitionImage && !currentArtworkLoaded && !currentArtworkUnavailable) {
        NSMutableAttributedString *heldAs = [as mutableCopy];
        [heldAs enumerateAttribute:NSAttachmentAttributeName
                            inRange:NSMakeRange(0, heldAs.length)
                            options:0
                         usingBlock:^(id value, NSRange range, BOOL *stop) {
            if (![value isKindOfClass:NSTextAttachment.class]) return;
            NSTextAttachment *attachment = value;
            ((NSTextAttachmentCell *)attachment.attachmentCell).image =
                self.pendingArtworkTransitionImage;
            *stop = YES;
        }];
        as = heldAs;
    }

    NSRect oldArtworkRect = self.pendingArtworkTransitionRect;
    NSImage *oldArtwork = self.pendingArtworkTransitionImage;

    // The placeholder/art size lives in the attachment geometry (its cell image
    // and bounds), not in the glyph string, so the rendered string can be
    // character-identical while the box must be re-laid-out at a new size
    // (e.g. panel resize at host start while stopped). Only skip once we know
    // the storage's attachment matches the rendered attachment's geometry too.
    BOOL artGeometryMatches = NO;
    NSTextAttachment * renderedAttachment = nil;
    if (artRange.location != NSNotFound && artRange.location < as.length &&
        artRange.location < _textView.textStorage.length) {
        NSTextAttachment * fresh = [_textView.textStorage attribute:NSAttachmentAttributeName
                                                           atIndex:artRange.location
                                                    effectiveRange:NULL];
        renderedAttachment = [as attribute:NSAttachmentAttributeName
                                   atIndex:artRange.location
                            effectiveRange:NULL];
        if ([fresh isKindOfClass:NSTextAttachment.class] &&
            [renderedAttachment isKindOfClass:NSTextAttachment.class]) {
            NSImage * freshImg = ((NSTextAttachmentCell *)fresh.attachmentCell).image;
            NSImage * renderedImg = ((NSTextAttachmentCell *)renderedAttachment.attachmentCell).image;
            artGeometryMatches = freshImg != nil && renderedImg != nil &&
                NSEqualSizes(freshImg.size, renderedImg.size) &&
                NSEqualRects(fresh.bounds, renderedAttachment.bounds);
        }
    }

    // If the rendered glyph string, artwork, geometry, and appearance are
    // unchanged, the storage needs no re-typesetting: refresh just the drawn
    // attachment images (e.g. the pause-state grayscale) and keep the existing
    // layout. This is the common case on playback/burst notifications that
    // produce identical output (time-only text stays stable while e.g. volume
    // toggles). A panel resize changes the placeholder size in the rendered
    // string, so artGeometryMatches turns false and we fall through to a real
    // re-render.
    BOOL visualStateUnchanged =
        !scriptChanged &&
        [as.string isEqualToString:_textView.textStorage.string] &&
        (!hasArt || artGeometryMatches) &&
        !artworkChanged && !canAnimateArtwork &&
        dark == self.lastDarkMode;
    self.lastDarkMode = dark;

    if (visualStateUnchanged) {
        if (artRange.location != NSNotFound && artRange.location < _textView.textStorage.length) {
            if (renderedAttachment) {
                NSTextAttachment * fresh = [_textView.textStorage attribute:NSAttachmentAttributeName
                                                                   atIndex:artRange.location
                                                            effectiveRange:NULL];
                if ([fresh isKindOfClass:NSTextAttachment.class]) {
                    ((NSTextAttachmentCell *)fresh.attachmentCell).image =
                        ((NSTextAttachmentCell *)renderedAttachment.attachmentCell).image;
                    [_textView setNeedsDisplay:YES];
                }
            }
        }
        self.lastArtRange = artRange;
    } else {
        [_textView.textStorage setAttributedString:as];
        self.lastArtRange = artRange;

        NSTextAttachment *newAttachment = nil;
        NSRect newArtworkRect = RTRectForAttachment(_textView, artRange.location, &newAttachment);
        NSImage *newArtwork = ((NSTextAttachmentCell *)newAttachment.attachmentCell).image;
        if (canAnimateArtwork && oldArtwork && newArtwork && !NSIsEmptyRect(oldArtworkRect) &&
            !NSIsEmptyRect(newArtworkRect)) {
            NSImageView *oldView = [[NSImageView alloc] initWithFrame:oldArtworkRect];
            oldView.image = oldArtwork;
            oldView.imageScaling = NSImageScaleAxesIndependently;
            NSImageView *newView = [[NSImageView alloc] initWithFrame:
                                    NSOffsetRect(newArtworkRect, newArtworkRect.size.width, 0)];
            newView.image = newArtwork;
            newView.imageScaling = NSImageScaleAxesIndependently;
            newView.alphaValue = 0.0;
            [_textView addSubview:oldView];
            [_textView addSubview:newView];
            // Always clear the transient overlay views; even if the animation
            // group is interrupted they must not linger over the artwork and
            // swallow wheel/clicks on the panel.
            __weak NSImageView *wOld = oldView, *wNew = newView;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [wOld removeFromSuperview];
                [wNew removeFromSuperview];
            });
            self.pendingArtworkTransitionImage = nil;
            self.pendingArtworkTransitionRect = NSZeroRect;

            NSTextAttachment *visibleAttachment = nil;
            RTRectForAttachment(_textView, artRange.location, &visibleAttachment);
            ((NSTextAttachmentCell *)visibleAttachment.attachmentCell).image =
                RTTransparentImage(newArtwork.size);
            NSRect oldEndRect = NSOffsetRect(oldArtworkRect, -oldArtworkRect.size.width, 0);
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.25;
                oldView.animator.frame = oldEndRect;
                oldView.animator.alphaValue = 0.0;
                newView.animator.frame = newArtworkRect;
                newView.animator.alphaValue = 1.0;
            } completionHandler:^{
                NSTextAttachment *currentAttachment = nil;
                RTRectForAttachment(_textView, artRange.location, &currentAttachment);
                ((NSTextAttachmentCell *)currentAttachment.attachmentCell).image = newArtwork;
                [_textView setNeedsDisplay:YES];
                [oldView removeFromSuperview];
                [newView removeFromSuperview];
            }];
        }
    }
    [_textView setSelectedRange:NSMakeRange(0, 0)];
    if ([_textView window])
        [[_textView window] invalidateCursorRectsForView:_textView];
}

// background=2: layer moving, oversaturated artwork copies and blur them to
// reproduce the flowing Apple Music-style artwork background.
- (void)applyArtworkBackgroundForTrack:(trackRef)track defaultTextColor:(NSColor **)outText defaultBgColor:(NSColor **)outBg {
    static const CGFloat maskOpacity = 0.6;
    NSString * key = [RTRenderer artCacheKey:track name:@"front"];
    NSImage * img = key ? [[RTArtCache shared] get:key] : nil;
    if (img == nil) return;
    CGSize bounds = self.artworkBackgroundLayer.bounds.size;
    if ([self.artworkBackgroundKey isEqualToString:key] &&
        CGSizeEqualToSize(self.artworkBackgroundSize, bounds) &&
        self.artworkImageLayers.count == 4) {
        NSColor *bg = [NSColor colorWithSRGBRed:0.08 green:0.08 blue:0.08 alpha:1.0];
        if (outText) *outText = [NSColor whiteColor];
        if (outBg) *outBg = bg;
        return;
    }
    [self.artworkBackgroundLayer.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
    NSRect proposed = NSMakeRect(0, 0, 0, 0);
    CGImageRef image = [img CGImageForProposedRect:&proposed context:nil hints:nil];
    if (image == nil) return;
    NSArray<NSNumber *> *scales = @[ @0.25, @0.50, @0.80, @1.25 ];
    NSMutableArray<CALayer *> *layers = [NSMutableArray arrayWithCapacity:scales.count];
    CGFloat side = MAX(bounds.width, bounds.height);
    for (NSUInteger index = 0; index < scales.count; index++) {
        CGFloat size = side * scales[index].doubleValue;
        CALayer *layer = [CALayer layer];
        layer.contents = (__bridge id)image;
        layer.contentsGravity = kCAGravityResizeAspectFill;
        layer.frame = CGRectMake((bounds.width - size) * 0.5, (bounds.height - size) * 0.5, size, size);
        layer.opacity = 0.72;
        CIFilter *saturation = [CIFilter filterWithName:@"CIColorControls"];
        [saturation setValue:@1.8 forKey:kCIInputSaturationKey];
        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        [blur setValue:@(8.0 + index * 16.0) forKey:kCIInputRadiusKey];
        layer.filters = @[ saturation, blur ];
        [self.artworkBackgroundLayer addSublayer:layer];
        [layers addObject:layer];
        CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rotation.fromValue = @(-0.12 - index * 0.08);
        rotation.toValue = @(0.12 + index * 0.08);
        rotation.duration = 5.0 + index * 2.5;
        rotation.autoreverses = YES;
        rotation.repeatCount = HUGE_VALF;
        [layer addAnimation:rotation forKey:@"rt_rotation"];
        CABasicAnimation *position = [CABasicAnimation animationWithKeyPath:@"position"];
        position.fromValue = [NSValue valueWithPoint:NSMakePoint(CGRectGetMidX(layer.frame) - 18.0, CGRectGetMidY(layer.frame) + 14.0)];
        position.toValue = [NSValue valueWithPoint:NSMakePoint(CGRectGetMidX(layer.frame) + 18.0, CGRectGetMidY(layer.frame) - 14.0)];
        position.duration = 7.0 + index * 2.0;
        position.autoreverses = YES;
        position.repeatCount = HUGE_VALF;
        [layer addAnimation:position forKey:@"rt_motion"];
    }
    self.artworkImageLayers = layers;
    CALayer *mask = [CALayer layer];
    mask.frame = self.artworkBackgroundLayer.bounds;
    mask.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    mask.backgroundColor = [[NSColor colorWithCalibratedWhite:0.0 alpha:maskOpacity] CGColor];
    [self.artworkBackgroundLayer addSublayer:mask];
    self.artworkDimMaskLayer = mask;
    self.artworkBackgroundKey = key;
    self.artworkBackgroundSize = bounds;
    NSColor *bg = [NSColor colorWithSRGBRed:0.08 green:0.08 blue:0.08 alpha:1.0];
    self.view.layer.backgroundColor = bg.CGColor;
    if (outText) *outText = [NSColor whiteColor];
    if (outBg) *outBg = bg;
}

// background=0: clear the panel so the host's default background shows through.
- (void)resetPanelBackground {
    [self.artworkBackgroundLayer.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
    self.artworkImageLayers = nil;
    self.artworkDimMaskLayer = nil;
    self.artworkBackgroundKey = nil;
    self.artworkBackgroundSize = CGSizeZero;
    if (self.view.layer.backgroundColor != NULL) self.view.layer.backgroundColor = NULL;
}

- (void)scheduleArtLoad:(NSString *)artName track:(trackRef)track {
    NSString * key = [RTRenderer artCacheKey:track name:artName];
    if (!key) return;
    if (![[RTArtCache shared] markPending:key]) return;
    GUID guid;
    if (![RTRenderer artGUIDForName:artName out:&guid]) return;
    __weak typeof(self) wself = self;
    rt_load_art(track, guid, ^(NSImage * img) {
        if (!img) {
            // negative cache: tiny transparent image so we don't retry per frame
            img = [[NSImage alloc] initWithSize:NSMakeSize(8, 8)];
        }
        [[RTArtCache shared] put:key image:img];
        [wself render];
    });
}

- (BOOL)handleScrollWheel:(NSEvent *)event {
    NSPoint p = [self.textView convertPoint:event.locationInWindow fromView:nil];
    if ([self hasImageInScript] && [self pointIsOverArtwork:p]) {
        double dy = event.scrollingDeltaY;
        if (dy > 0)
            rt_run_command_by_path("Playback/Volume/Up");
        else if (dy < 0)
            rt_run_command_by_path("Playback/Volume/Down");
    }
    return YES;
}

#pragma mark NSTextViewDelegate

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex {
    (void)textView; (void)charIndex;
    NSString * s = nil;
    if ([link isKindOfClass:NSURL.class]) s = [(NSURL *)link absoluteString];
    else if ([link isKindOfClass:NSString.class]) s = (NSString *)link;
    if (s.length == 0) return NO;
    NSString * path = self.commandTable[s];
    if (path.length == 0) return NO;
    rt_run_command_by_path([path UTF8String]);
    return YES;
}

@end
