#import "stdafx.h"
#import "RichTextConfigWindowController.h"
#import "../scriptstore.h"
#import "../notify.h"

extern const char * richtext_default_script(); // from config.cpp

@interface RichTextConfigWindowController () <NSTextViewDelegate>
@property (strong) NSTextView *editor;
@property (weak) RichTextPanelViewController *panel;
- (void)bindToPanel:(RichTextPanelViewController *)panel;
- (IBAction)onRevert:(id)sender;
@end

static NSMutableDictionary<NSString *, RichTextConfigWindowController *> * g_openWindows = nil;

// All configure windows share one remembered frame: reopening restores the
// position/size from the most recently closed window (across launches too).
static NSString * const kRTConfigFrameKey = @"RTRichTextConfigWindowFrame";

static void RTSaveConfigFrame(NSWindow * win) {
    [[NSUserDefaults standardUserDefaults] setObject:NSStringFromRect(win.frame)
                                              forKey:kRTConfigFrameKey];
}

static BOOL RTRestoreConfigFrame(NSWindow * win) {
    NSString * s = [[NSUserDefaults standardUserDefaults] stringForKey:kRTConfigFrameKey];
    if (!s) return NO;
    NSRect f = NSRectFromString(s);
    if (f.size.width <= 0 || f.size.height <= 0) return NO;
    [win setFrame:f display:NO];
    return YES;
}

// Editor that tints the line containing the caret while it has focus.
@interface RTCurrentLineTextView : NSTextView
@end

@implementation RTCurrentLineTextView

- (void)drawViewBackgroundInRect:(NSRect)rect {
    [super drawViewBackgroundInRect:rect];
    if (![self.window isKeyWindow] || self.window.firstResponder != self) return;
    NSRange sel = self.selectedRange;
    if (sel.location == NSNotFound) return;
    NSLayoutManager * lm = self.layoutManager;
    if (lm.numberOfGlyphs == 0) return;
    NSUInteger glyph = [lm glyphIndexForCharacterAtIndex:sel.location];
    NSRect lineRect;
    if (glyph < lm.numberOfGlyphs) {
        NSRange effectiveRange;
        lineRect = [lm lineFragmentRectForGlyphAtIndex:glyph effectiveRange:&effectiveRange];
    } else {
        // Caret at end of text: use the phantom empty line when the text ends
        // with a newline, otherwise fall back to the last real line.
        lineRect = lm.extraLineFragmentRect;
        if (NSIsEmptyRect(lineRect)) {
            NSRange effectiveRange;
            lineRect = [lm lineFragmentRectForGlyphAtIndex:lm.numberOfGlyphs - 1 effectiveRange:&effectiveRange];
        }
    }
    if (NSIsEmptyRect(lineRect)) return;
    NSRect full = NSMakeRect(0, lineRect.origin.y, self.bounds.size.width, ceil(lineRect.size.height));
    NSColor * tint = [[NSColor selectedTextBackgroundColor] colorWithAlphaComponent:0.22];
    [tint setFill];
    NSRectFillUsingOperation(full, NSCompositingOperationSourceOver);
}

@end

@implementation RichTextConfigWindowController

+ (void)initialize {
    if (self == [RichTextConfigWindowController class]) g_openWindows = [NSMutableDictionary new];
}

+ (void)configurePanel:(RichTextPanelViewController *)panel {
    NSString * key = panel.scriptID.length ? panel.scriptID : @"<default>";
    RichTextConfigWindowController * wc = g_openWindows[key];
    BOOL fresh = NO;
    if (!wc) {
        wc = [[RichTextConfigWindowController alloc] initWithPanel:panel];
        g_openWindows[key] = wc;
        fresh = YES;
    } else {
        // A cached window may outlive the panel that created it (panels are
        // destroyed on relayout) and _panel is weak, so it can go nil and fall
        // back to the default script. Always rebind to the panel being shown.
        [wc bindToPanel:panel];
    }
    NSWindow * win = wc.window;
    if (fresh) {
        // reopen at the last-closed position; first-ever open centres over
        if (!RTRestoreConfigFrame(win)) {
            NSWindow * host = panel.view.window;
            if (host) {
                NSRect hostFrame = [host convertRectFromScreen:host.frame];
                NSRect f = win.frame;
                f.origin.x = round(hostFrame.origin.x + (hostFrame.size.width - f.size.width) / 2.0);
                f.origin.y = round(hostFrame.origin.y + (hostFrame.size.height - f.size.height) / 2.0);
                [win setFrame:f display:NO];
            } else {
                [win center];
            }
        }
    }
    [win makeKeyAndOrderFront:nil];
    [wc refreshEditor];
}

- (instancetype)initWithPanel:(RichTextPanelViewController *)panel {
    NSRect frame = NSMakeRect(0, 0, 520, 380);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
    NSWindow * win = [[NSWindow alloc] initWithContentRect:frame
                                                 styleMask:style
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    win.title = panel.scriptID.length
        ? [NSString stringWithFormat:@"Configure Rich Text — %@", panel.scriptID]
        : @"Configure Rich Text";
    win.releasedWhenClosed = NO;

    self = [super initWithWindow:win];
    if (self) {
        _panel = panel;
        [self buildUI];
        [self refreshEditor];
        // follow system/host dark & light mode
        [win addObserver:self forKeyPath:@"effectiveAppearance" options:0 context:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(configWindowWillClose:)
                                                     name:NSWindowWillCloseNotification
                                                   object:win];
        // redraw the current-line highlight as the editor gains/loses focus
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(configWindowKeyChanged:)
                                                     name:NSWindowDidBecomeKeyNotification
                                                   object:win];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(configWindowKeyChanged:)
                                                     name:NSWindowDidResignKeyNotification
                                                   object:win];
    }
    return self;
}

// Rebinds this cached window to the panel currently being configured, keeping
// the displayed script and window title in sync with the live panel.
- (void)bindToPanel:(RichTextPanelViewController *)panel {
    if (_panel == panel) return;
    _panel = panel;
    if (panel && panel.scriptID.length) {
        self.window.title = [NSString stringWithFormat:@"Configure Rich Text — %@", panel.scriptID];
    } else {
        self.window.title = @"Configure Rich Text";
    }
    [self refreshEditor];
}

- (void)configWindowWillClose:(NSNotification *)note {
    RTSaveConfigFrame(note.object);
    // Evict the cached window so it can't come back with a stale/nil panel.
    RichTextConfigWindowController * wc = note.object == self.window ? self : nil;
    if (wc) {
        for (NSString * k in [g_openWindows allKeys]) {
            if (g_openWindows[k] == wc) [g_openWindows removeObjectForKey:k];
        }
    }
}

- (void)configWindowKeyChanged:(NSNotification *)note {
    (void)note;
    [self.editor setNeedsDisplay:YES];
}

- (void)dealloc {
    [self.window removeObserver:self forKeyPath:@"effectiveAppearance"];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"effectiveAppearance"]) {
        // dynamic colors resolve again when the view redisplays
        [self.editor setNeedsDisplay:YES];
        [self refreshEditor];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)buildUI {
    NSView * root = self.window.contentView;

    NSScrollView * scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.borderType = NSBezelBorder;
    [root addSubview:scroll];

    NSTextView * ed = [[RTCurrentLineTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 240)];
    ed.editable = YES;
    ed.selectable = YES;
    ed.richText = NO;
    ed.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    // dynamic semantic colors: adapt to dark/light mode with the host app
    ed.drawsBackground = YES;
    ed.backgroundColor = [NSColor textBackgroundColor];
    ed.textColor = [NSColor textColor];
    ed.insertionPointColor = [NSColor textColor];
    ed.selectedTextAttributes = @{ NSBackgroundColorAttributeName: [NSColor selectedTextBackgroundColor] };
    ed.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    // do not wrap long lines; scroll horizontally instead
    ed.horizontallyResizable = YES;
    ed.verticallyResizable = YES;
    ed.minSize = NSMakeSize(0, 0);
    ed.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    ed.textContainer.widthTracksTextView = NO;
    ed.textContainer.containerSize = NSMakeSize(FLT_MAX, FLT_MAX);
    [ed layoutManager]; // opt into TextKit 1
    ed.delegate = self;
    scroll.documentView = ed;
    self.editor = ed;

    NSButton * revert = [NSButton buttonWithTitle:@"Revert to Default" target:self action:@selector(onRevert:)];
    revert.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:revert];

    // Escape closes the window
    NSButton * esc = [[NSButton alloc] initWithFrame:NSMakeRect(-1000, -1000, 10, 10)];
    esc.keyEquivalent = @"\033";
    esc.target = self;
    esc.action = @selector(onEscPressed:);
    [root addSubview:esc];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:root.topAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:12],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-12],
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-52],
        [revert.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:15],
        [revert.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [revert.widthAnchor constraintEqualToConstant:120],
    ]];
}

- (void)refreshEditor {
    NSString * script = [RTScriptStore scriptForID:self.panel.scriptID];
    if (![self.editor.string isEqualToString:script]) {
        [self.editor.textStorage setAttributedString:
            [[NSAttributedString alloc] initWithString:script attributes:@{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: [NSColor textColor] }]];
        [self.editor setSelectedRange:NSMakeRange(script.length, 0)];
    }
    self.editor.typingAttributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor textColor] };
    // sync the document view with the scroll view so long lines are never
    // wider than the viewport but still fill it when content is short
    NSScrollView * sv = (NSScrollView *)self.editor.superview;
    if ([sv isKindOfClass:NSScrollView.class]) {
        CGFloat visible = sv.contentSize.width;
        [self.editor sizeToFit];
        NSRect frame = self.editor.frame;
        if (NSWidth(frame) < visible) frame.size.width = visible;
        self.editor.frame = frame;
    }
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidResize:)
                                                 name:NSWindowDidResizeNotification
                                               object:self.window];
    [self windowDidResize:nil];
}

// keep the document view sized to the viewport while resizing
- (void)windowDidResize:(NSNotification *)note {
    (void)note;
    NSScrollView * sv = (NSScrollView *)self.editor.superview;
    if (![sv isKindOfClass:NSScrollView.class]) return;
    CGFloat visible = sv.contentSize.width;
    [self.editor sizeToFit];
    NSRect frame = self.editor.frame;
    if (NSWidth(frame) < visible) frame.size.width = visible;
    self.editor.frame = frame;
    [sv reflectScrolledClipView:[sv contentView]];
}

// live preview while typing
- (void)textDidChange:(NSNotification *)notification {
    [RTScriptStore setScript:self.editor.string ?: @"" forID:self.panel.scriptID];
    rt_notify_refresh();
}

// redraw the current-line highlight whenever the caret/selection moves
- (void)textViewDidChangeSelection:(NSNotification *)notification {
    (void)notification;
    [self.editor setNeedsDisplay:YES];
}

- (IBAction)onRevert:(id)sender {
    // load the hardcoded default script from config.cpp
    NSString * defaultScript = [NSString stringWithUTF8String:richtext_default_script()];
    [RTScriptStore setScript:defaultScript forID:self.panel.scriptID];
    rt_notify_refresh();
    [self refreshEditor];
}

- (void)onEscPressed:(id)sender {
    (void)sender;
    [self.window close];
}

@end
