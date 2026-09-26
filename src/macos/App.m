#import "App.h"
#import "TermView.h"
#import "Agents.h"
#import "History.h"
#import "Settings.h"
#import "Queue.h"
#import "Git.h"
#import "SplitView.h"
#import "Keys.h"
#import "Theme.h"
#include "at_control.h"
#include <stdlib.h>
#include <math.h>
#include <unistd.h>
#include <string.h>

typedef NS_ENUM(NSInteger, ATPage) {
    ATPageWorkspace = 0,
    ATPageQuickstart,
    ATPageHistory,
    ATPageSettings,
    ATPageQueue,
};

static NSColor *ATBg(void) { return ATColorBg(); }
static NSColor *ATHair(void) { return ATColorHair(); }
static NSColor *ATText(void) { return ATColorText(); }
static NSColor *ATMuted(void) { return ATColorMuted(); }
static NSColor *ATAccent(void) { return ATColorAccent(); }

static NSFont *ATSans(CGFloat size) {
    NSFont *f = [NSFont fontWithName:@"Avenir Next" size:size];
    return f ?: [NSFont systemFontOfSize:size weight:NSFontWeightMedium];
}

/* Green breathing = running. Copper = waiting for you. Hollow grey =
   starting. Nothing = no process at all. */
static const CGFloat kATDot = 7.0;

static void ATDrawActivityPip(ATActivity act, NSRect pip, NSUInteger working) {
    if (act != ATActivityNeedsInput && act != ATActivityWorking) return;
    NSBezierPath *halo = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(pip, -1.2, -1.2)];
    [ATBg() setFill];
    [halo fill];
    NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:pip];
    if (act == ATActivityNeedsInput) {
        [ATAccent() setFill];
        [p fill];
        return;
    }
    NSTimeInterval t = NSDate.timeIntervalSinceReferenceDate;
    CGFloat alpha = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 5.0));
    NSColor *c = [NSColor colorWithCalibratedRed:0.42 green:0.76 blue:0.47 alpha:1];
    [[c colorWithAlphaComponent:alpha] setFill];
    [p fill];
    if (working == 0 || pip.size.height < 14) return;
    NSString *label = working > 9 ? @"9+" : [NSString stringWithFormat:@"%lu", (unsigned long)working];
    CGFloat fs = pip.size.height * (label.length > 1 ? 0.48 : 0.58);
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:fs weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.07 alpha:1],
    };
    NSSize sz = [label sizeWithAttributes:attrs];
    [label drawAtPoint:NSMakePoint(NSMidX(pip) - sz.width / 2.0,
                                   NSMidY(pip) - sz.height / 2.0 - pip.size.height * 0.04)
        withAttributes:attrs];
}

static void ATDrawActivityPipOnIcon(ATActivity act, NSRect icon) {
    if (act != ATActivityNeedsInput && act != ATActivityWorking) return;
    CGFloat d = MAX(5.0, icon.size.width * 0.36);
    NSRect pip = NSMakeRect(NSMaxX(icon) - d * 0.72, NSMaxY(icon) - d * 0.72, d, d);
    ATDrawActivityPip(act, pip, 0);
}

static void ATDrawActivityDot(ATActivity act, NSPoint origin) {
    if (act == ATActivityNone) return;
    NSRect dot = NSMakeRect(origin.x, origin.y, kATDot, kATDot);
    if (act == ATActivityStandby) {
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, 0.75, 0.75)];
        ring.lineWidth = 1.25;
        [[ATMuted() colorWithAlphaComponent:0.75] setStroke];
        [ring stroke];
        return;
    }
    ATDrawActivityPip(act, dot, 0);
}

@interface ATDockTileView : NSView
@property (nonatomic, assign) ATActivity activity;
@property (nonatomic, assign) NSUInteger workingCount;
@end

@implementation ATDockTileView
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds;
    NSImage *icon = NSApp.applicationIconImage;
    [icon drawInRect:b
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];
    if (self.activity != ATActivityNeedsInput && self.activity != ATActivityWorking) return;
    CGFloat s = MIN(b.size.width, b.size.height);
    BOOL numbered = self.activity == ATActivityWorking && self.workingCount > 0;
    CGFloat d = s * (numbered ? 0.34 : 0.26);
    CGFloat m = s * 0.08;
    NSRect pip = NSMakeRect(NSMaxX(b) - d - m, NSMaxY(b) - d - m, d, d);
    ATDrawActivityPip(self.activity, pip, numbered ? self.workingCount : 0);
}
@end

/* Same attributes, but tail-truncated so a long name can't run past its slot. */
static NSDictionary *ATTruncating(NSDictionary *attrs) {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary *out = [attrs mutableCopy];
    out[NSParagraphStyleAttributeName] = ps;
    return out;
}

#pragma mark - Inline rename

/* A text field laid over a strip item. Enter or clicking away commits,
   Esc cancels. Holds itself alive until the edit finishes. */
@interface ATInlineRename : NSObject <NSTextFieldDelegate>
+ (void)beginInView:(NSView *)view
              frame:(NSRect)frame
               text:(NSString *)text
             commit:(void (^)(NSString *name))commit;
+ (void)startInView:(NSView *)view
              frame:(NSRect)frame
               text:(NSString *)text
             commit:(void (^)(NSString *name))commit;
@end

@implementation ATInlineRename {
    NSTextField *_field;
    NSResponder *_prev;
    void (^_commit)(NSString *);
    ATInlineRename *_alive;
    BOOL _done;
}

+ (void)beginInView:(NSView *)view
              frame:(NSRect)frame
               text:(NSString *)text
             commit:(void (^)(NSString *))commit {
    if (!view.window) return;
    /* A context-menu item calls this while the menu is still dismissing, and
       NSMenu restores the previous first responder when tracking ends — which
       would kick the field out and end editing the instant it appeared. Start
       on the next runloop turn, once the menu is gone. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self startInView:view frame:frame text:text commit:commit];
    });
}

+ (void)startInView:(NSView *)view
              frame:(NSRect)frame
               text:(NSString *)text
             commit:(void (^)(NSString *))commit {
    if (!view.window) return;
    ATInlineRename *r = [ATInlineRename new];
    r->_commit = [commit copy];
    r->_alive = r;
    r->_prev = view.window.firstResponder;

    NSRect box = NSInsetRect(frame, 4, 5);
    if (box.size.width < 120) box.size.width = 120;
    NSTextField *f = [[NSTextField alloc] initWithFrame:box];
    f.stringValue = text ?: @"";
    f.font = ATSans(12.5);
    f.textColor = ATText();
    f.backgroundColor = ATColorSurface();
    f.drawsBackground = YES;
    f.bezeled = NO;
    f.focusRingType = NSFocusRingTypeNone;
    r->_field = f;
    [view addSubview:f];
    [view.window makeFirstResponder:f];
    [f selectText:nil];
    /* selectText: re-installs the field editor, which fires
       controlTextDidEndEditing: for the session makeFirstResponder: just
       started. Attaching the delegate afterwards keeps that spurious
       notification from tearing the field down the instant it appears. */
    f.delegate = r;
}

- (void)finish:(BOOL)apply {
    if (_done) return;
    _done = YES;
    NSString *value = _field.stringValue;
    NSWindow *win = _field.window;
    _field.delegate = nil;
    [_field removeFromSuperview];
    _field = nil;
    /* Hand focus back to whatever had it, usually the terminal. */
    if (_prev && win) [win makeFirstResponder:_prev];
    _prev = nil;
    if (apply && _commit) _commit(value);
    _commit = nil;
    _alive = nil;
}

- (BOOL)control:(NSControl *)control
       textView:(NSTextView *)textView
doCommandBySelector:(SEL)command {
    (void)control;
    (void)textView;
    if (command == @selector(insertNewline:)) {
        [self finish:YES];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        [self finish:NO];
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
    (void)note;
    [self finish:YES];
}

@end

#pragma mark - Tab strip

@interface ATTabStrip : NSView
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL selectAction;
@property (nonatomic, assign) SEL newAction;
@property (nonatomic, assign) SEL foldersAction;
@property (nonatomic, assign) SEL homeAction;
@property (nonatomic, assign) SEL historyAction;
@property (nonatomic, assign) SEL settingsAction;
@property (nonatomic, assign) SEL queueAction;
@property (nonatomic, assign) BOOL homeSelected;
@property (nonatomic, assign) BOOL historySelected;
@property (nonatomic, assign) BOOL settingsSelected;
@property (nonatomic, assign) BOOL queueSelected;
@property (nonatomic, assign) NSInteger focusIndex;
- (void)reload;
- (NSRect)frameForIndex:(NSUInteger)index;
@end

typedef NS_ENUM(NSInteger, ATNavItem) {
    ATNavNone = -1,
    ATNavHome = 0,
    ATNavHistory = 1,
    ATNavQueue = 2,
    ATNavSettings = 3,
};

@implementation ATTabStrip {
    NSMutableArray<NSValue *> *_frames;
    NSRect _plusFrame;
    NSRect _homeFrame;
    NSRect _historyFrame;
    NSRect _settingsFrame;
    NSRect _queueFrame;
    NSInteger _hoverNav;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _frames = [NSMutableArray new];
    _focusIndex = -1;
    _hoverNav = ATNavNone;
    self.wantsLayer = YES;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

- (void)keyDown:(NSEvent *)event {
    NSWindowController *wc = self.window.windowController;
    if ([wc handleNavEvent:event]) return;
    unsigned short kc = event.keyCode;
    NSEventModifierFlags m = event.modifierFlags;
    if (kc == 48 && !(m & NSEventModifierFlagCommand) && !(m & NSEventModifierFlagControl)) {
        [wc tabChrome:!(m & NSEventModifierFlagShift)];
        return;
    }
    if (kc == 36) {
        [wc activateChrome];
        return;
    }
    if (kc == 53) {
        [wc escapeChrome];
        return;
    }
    [super keyDown:event];
}

- (ATAppDelegate *)app {
    return (ATAppDelegate *)NSApp.delegate;
}

- (void)reload {
    [self setNeedsDisplay:YES];
}

static void ATDrawFocus(NSRect r) {
    [ATColorAccent() setStroke];
    NSFrameRectWithWidth(NSInsetRect(r, 3, 3), 2);
}

static NSString *ATNavSymbol(ATNavItem item) {
    switch (item) {
    case ATNavHome: return @"house.fill";
    case ATNavHistory: return @"clock.arrow.counterclockwise";
    case ATNavQueue: return @"square.stack.fill";
    case ATNavSettings: return @"gearshape.fill";
    default: return nil;
    }
}

static void ATStrokeNavGlyph(ATNavItem item, NSRect box, NSColor *color) {
    [color setStroke];
    [color setFill];
    CGFloat x = NSMinX(box), y = NSMinY(box), w = NSWidth(box), h = NSHeight(box);
    CGFloat cx = NSMidX(box), cy = NSMidY(box);
    switch (item) {
    case ATNavHome: {
        NSBezierPath *p = [NSBezierPath bezierPath];
        p.lineJoinStyle = NSLineJoinStyleRound;
        [p moveToPoint:NSMakePoint(cx, y + 0.4)];
        [p lineToPoint:NSMakePoint(x + 0.6, y + 7.0)];
        [p lineToPoint:NSMakePoint(x + 3.2, y + 7.0)];
        [p lineToPoint:NSMakePoint(x + 3.2, y + h - 0.6)];
        [p lineToPoint:NSMakePoint(x + w - 3.2, y + h - 0.6)];
        [p lineToPoint:NSMakePoint(x + w - 3.2, y + 7.0)];
        [p lineToPoint:NSMakePoint(x + w - 0.6, y + 7.0)];
        [p closePath];
        [p fill];
        [ATBg() setFill];
        NSRectFill(NSMakeRect(cx - 1.6, y + h - 6.2, 3.2, 5.6));
        break;
    }
    case ATNavHistory: {
        NSBezierPath *c = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(box, 0.6, 0.6)];
        c.lineWidth = 1.6;
        [c stroke];
        NSBezierPath *hands = [NSBezierPath bezierPath];
        hands.lineWidth = 1.6;
        hands.lineCapStyle = NSLineCapStyleRound;
        [hands moveToPoint:NSMakePoint(cx, cy + 0.4)];
        [hands lineToPoint:NSMakePoint(cx, y + 3.4)];
        [hands moveToPoint:NSMakePoint(cx, cy + 0.4)];
        [hands lineToPoint:NSMakePoint(cx + 3.8, cy + 2.0)];
        [hands stroke];
        NSBezierPath *tail = [NSBezierPath bezierPath];
        tail.lineWidth = 1.5;
        tail.lineCapStyle = NSLineCapStyleRound;
        tail.lineJoinStyle = NSLineJoinStyleRound;
        [tail moveToPoint:NSMakePoint(x + 1.2, y + 3.2)];
        [tail lineToPoint:NSMakePoint(x + 1.2, y + 0.8)];
        [tail lineToPoint:NSMakePoint(x + 4.0, y + 0.8)];
        [tail stroke];
        break;
    }
    case ATNavQueue: {
        NSRect a = NSMakeRect(x + 1.6, y + 1.0, w - 3.2, 4.2);
        NSRect b = NSMakeRect(x + 1.6, y + 5.4, w - 3.2, 4.2);
        NSRect c = NSMakeRect(x + 1.6, y + 9.8, w - 3.2, 3.6);
        [[NSBezierPath bezierPathWithRoundedRect:a xRadius:1.4 yRadius:1.4] fill];
        [[color colorWithAlphaComponent:0.72] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:b xRadius:1.4 yRadius:1.4] fill];
        [[color colorWithAlphaComponent:0.45] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:c xRadius:1.4 yRadius:1.4] fill];
        break;
    }
    case ATNavSettings: {
        /* three sliders — readable at 14px, unlike a tiny gear */
        CGFloat ys[3] = { y + 2.4, y + 7.0, y + 11.6 };
        CGFloat knobs[3] = { x + 5.0, x + 9.6, x + 6.2 };
        for (int i = 0; i < 3; i++) {
            [color setStroke];
            NSBezierPath *line = [NSBezierPath bezierPath];
            line.lineWidth = 1.7;
            line.lineCapStyle = NSLineCapStyleRound;
            [line moveToPoint:NSMakePoint(x + 1.0, ys[i])];
            [line lineToPoint:NSMakePoint(x + w - 1.0, ys[i])];
            [line stroke];
            [color setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(knobs[i] - 2.3, ys[i] - 2.3, 4.6, 4.6)] fill];
            [ATBg() setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(knobs[i] - 1.1, ys[i] - 1.1, 2.2, 2.2)] fill];
        }
        break;
    }
    default:
        break;
    }
}

static BOOL ATDrawSymbol(NSString *symbol, NSRect ir, NSColor *color) {
    if (!symbol.length) return NO;
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    if (!img) return NO;
    if (@available(macOS 12.0, *)) {
        NSImageSymbolConfiguration *cfg =
            [[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]
             configurationByApplyingConfiguration:
                 [NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
        img = [img imageWithSymbolConfiguration:cfg];
    }
    if (!img) return NO;
    [img drawInRect:ir
           fromRect:NSZeroRect
          operation:NSCompositingOperationSourceOver
           fraction:1.0
     respectFlipped:YES
              hints:nil];
    return YES;
}

static NSRect ATDrawNavIcon(ATNavItem item, CGFloat x, CGFloat h, BOOL on, BOOL hover) {
    const CGFloat slot = 32;
    NSRect frame = NSMakeRect(x, 0, slot, h);
    if (hover || on) {
        NSColor *wash = on ? [ATAccent() colorWithAlphaComponent:0.16]
                           : [ATHair() colorWithAlphaComponent:0.85];
        [wash setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame, 5, 6)
                                         xRadius:5
                                         yRadius:5] fill];
    }
    NSColor *col = on ? ATAccent() : ATMuted();
    NSRect glyph = NSMakeRect(x + (slot - 15) / 2.0, floor((h - 15) / 2.0), 15, 15);
    if (!ATDrawSymbol(ATNavSymbol(item), glyph, col)) {
        ATStrokeNavGlyph(item, NSInsetRect(glyph, 0.5, 0.5), col);
    }
    if (on) {
        [ATAccent() setFill];
        NSRectFill(NSMakeRect(x + 8, h - 3, slot - 16, 2));
    }
    return frame;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATBg() setFill];
    NSRectFill(self.bounds);
    [ATHair() setFill];
    NSRectFill(NSMakeRect(0, self.bounds.size.height - 1, self.bounds.size.width, 1));

    ATStore *store = self.app.store;
    [_frames removeAllObjects];
    uint32_t n = at_store_workspace_count(store);
    int32_t active = at_store_active_index(store);
    CGFloat x = 8;
    CGFloat h = self.bounds.size.height;
    CGFloat W = NSWidth(self.bounds);
    _homeFrame = ATDrawNavIcon(ATNavHome, x, h, self.homeSelected, _hoverNav == ATNavHome);
    x = NSMaxX(_homeFrame);
    _historyFrame = ATDrawNavIcon(ATNavHistory, x, h, self.historySelected, _hoverNav == ATNavHistory);
    x = NSMaxX(_historyFrame) + 8;
    [ATHair() setFill];
    NSRectFill(NSMakeRect(x, 8, 1, h - 16));
    x += 10;
    _settingsFrame = ATDrawNavIcon(ATNavSettings, W - 8 - 32, h, self.settingsSelected, _hoverNav == ATNavSettings);
    _queueFrame = ATDrawNavIcon(ATNavQueue, NSMinX(_settingsFrame) - 32, h, self.queueSelected, _hoverNav == ATNavQueue);
    CGFloat workMax = NSMinX(_queueFrame) - 36;
    for (uint32_t i = 0; i < n; i++) {
        if (x + 48 > workMax) break;
        const char *nm = at_store_name(store, i);
        NSString *title = nm ? @(nm) : @"workspace";
        BOOL on = !self.homeSelected && !self.historySelected && !self.settingsSelected && !self.queueSelected && (i == (uint32_t)active);
        NSDictionary *attrs = @{
            NSFontAttributeName: ATSans(12.5),
            NSForegroundColorAttributeName: on ? ATText() : ATMuted(),
        };
        const char *widc = at_store_id(store, i);
        ATActivity act = widc
            ? [self.window.windowController activityForWorkspaceId:@(widc)]
            : ATActivityNone;
        NSSize sz = [title sizeWithAttributes:attrs];
        CGFloat titleW = MIN(sz.width, 160.0);
        NSRect r = NSMakeRect(x, 0, titleW + 20 + (act == ATActivityNone ? 0 : 14), h);
        [_frames addObject:[NSValue valueWithRect:r]];
        [title drawInRect:NSMakeRect(r.origin.x + 10, (h - sz.height) / 2.0 - 1, titleW, sz.height)
           withAttributes:ATTruncating(attrs)];
        ATDrawActivityDot(act, NSMakePoint(r.origin.x + 10 + titleW + 6,
                                           floor((h - kATDot) / 2.0)));
        if (on) {
            [ATAccent() setFill];
            NSRectFill(NSMakeRect(r.origin.x + 8, h - 3, r.size.width - 16, 2));
        }
        x = NSMaxX(r) + 4;
    }
    if (x + 28 <= workMax) {
        NSString *plus = @"+";
        NSDictionary *plusAttrs = @{
            NSFontAttributeName: ATSans(16),
            NSForegroundColorAttributeName: ATMuted(),
        };
        NSSize psz = [plus sizeWithAttributes:plusAttrs];
        _plusFrame = NSMakeRect(x + 4, 0, 28, h);
        [plus drawAtPoint:NSMakePoint(_plusFrame.origin.x + 8, (h - psz.height) / 2.0 - 2) withAttributes:plusAttrs];
    } else {
        _plusFrame = NSZeroRect;
    }
    NSInteger fi = self.focusIndex;
    if (fi == 0) ATDrawFocus(_homeFrame);
    else if (fi == 1) ATDrawFocus(_historyFrame);
    else if (fi == 2) ATDrawFocus(_settingsFrame);
    else if (fi == 3) ATDrawFocus(_queueFrame);
    else if (fi >= 4 && fi - 4 < (NSInteger)_frames.count) ATDrawFocus(_frames[(NSUInteger)(fi - 4)].rectValue);
    else if (fi >= 4 && fi - 4 == (NSInteger)_frames.count) ATDrawFocus(_plusFrame);

    [self removeAllToolTips];
    [self addToolTipRect:_homeFrame owner:self userData:(void *)(intptr_t)ATNavHome];
    [self addToolTipRect:_historyFrame owner:self userData:(void *)(intptr_t)ATNavHistory];
    [self addToolTipRect:_queueFrame owner:self userData:(void *)(intptr_t)ATNavQueue];
    [self addToolTipRect:_settingsFrame owner:self userData:(void *)(intptr_t)ATNavSettings];
    [self.window invalidateCursorRectsForView:self];
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    (void)view;
    (void)tag;
    (void)point;
    switch ((ATNavItem)(intptr_t)data) {
    case ATNavHome: return @"Quickstart";
    case ATNavHistory: return @"History";
    case ATNavQueue: return @"Queue";
    case ATNavSettings: return @"Settings";
    default: return nil;
    }
}

- (void)resetCursorRects {
    [self addCursorRect:_homeFrame cursor:[NSCursor pointingHandCursor]];
    [self addCursorRect:_historyFrame cursor:[NSCursor pointingHandCursor]];
    [self addCursorRect:_queueFrame cursor:[NSCursor pointingHandCursor]];
    [self addCursorRect:_settingsFrame cursor:[NSCursor pointingHandCursor]];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in [self.trackingAreas copy]) [self removeTrackingArea:a];
    NSTrackingAreaOptions opts = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                 NSTrackingActiveInActiveApp | NSTrackingInVisibleRect;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:opts
                                                         owner:self
                                                      userInfo:nil]];
}

- (NSInteger)navItemAtPoint:(NSPoint)p {
    if (NSPointInRect(p, _homeFrame)) return ATNavHome;
    if (NSPointInRect(p, _historyFrame)) return ATNavHistory;
    if (NSPointInRect(p, _queueFrame)) return ATNavQueue;
    if (NSPointInRect(p, _settingsFrame)) return ATNavSettings;
    return ATNavNone;
}

- (void)mouseMoved:(NSEvent *)event {
    NSInteger h = [self navItemAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (h == _hoverNav) return;
    _hoverNav = h;
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (_hoverNav == ATNavNone) return;
    _hoverNav = ATNavNone;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, _plusFrame)) {
        if (self.target && self.newAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.newAction];
#pragma clang diagnostic pop
        }
        return;
    }
    if (NSPointInRect(p, _homeFrame)) {
        if (self.target && self.homeAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.homeAction];
#pragma clang diagnostic pop
        }
        return;
    }
    if (NSPointInRect(p, _historyFrame)) {
        if (self.target && self.historyAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.historyAction];
#pragma clang diagnostic pop
        }
        return;
    }
    if (NSPointInRect(p, _settingsFrame)) {
        if (self.target && self.settingsAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.settingsAction];
#pragma clang diagnostic pop
        }
        return;
    }
    if (NSPointInRect(p, _queueFrame)) {
        if (self.target && self.queueAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.queueAction];
#pragma clang diagnostic pop
        }
        return;
    }
    for (NSUInteger i = 0; i < _frames.count; i++) {
        NSRect r = _frames[i].rectValue;
        if (!NSPointInRect(p, r)) continue;
        int32_t active = at_store_active_index(self.app.store);
        if (!self.homeSelected && !self.historySelected && !self.settingsSelected && !self.queueSelected && (int32_t)i == active) {
            if (self.target && self.foldersAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [self.target performSelector:self.foldersAction withObject:self];
#pragma clang diagnostic pop
            }
            return;
        }
        if (self.target && self.selectAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.selectAction withObject:@(i)];
#pragma clang diagnostic pop
        }
        return;
    }
}

- (NSRect)frameForIndex:(NSUInteger)index {
    if (index >= _frames.count) return NSZeroRect;
    return _frames[index].rectValue;
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    for (NSUInteger i = 0; i < _frames.count; i++) {
        if (!NSPointInRect(p, _frames[i].rectValue)) continue;
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Workspace"];
        NSMenuItem *rename = [[NSMenuItem alloc] initWithTitle:@"Rename"
                                                        action:@selector(renameWorkspaceAt:)
                                                 keyEquivalent:@""];
        rename.target = self.target;
        rename.representedObject = @(i);
        [menu addItem:rename];
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:@"Close"
                                                      action:@selector(closeWorkspaceAt:)
                                               keyEquivalent:@""];
        close.target = self.target;
        close.representedObject = @(i);
        [menu addItem:close];
        return menu;
    }
    return nil;
}

@end

#pragma mark - Session tabs (agents inside a project)

@interface ATSessionBar : NSView
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL selectAction;
@property (nonatomic, assign) SEL addAction;
@property (nonatomic, assign) SEL closeAction;
@property (nonatomic, assign) NSInteger focusIndex;
- (void)reload;
- (NSRect)frameForIndex:(NSUInteger)index;
@end

@implementation ATSessionBar {
    NSMutableArray<NSValue *> *_frames;
    NSRect _plusFrame;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _frames = [NSMutableArray new];
    _focusIndex = -1;
    self.wantsLayer = YES;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

- (void)keyDown:(NSEvent *)event {
    NSWindowController *wc = self.window.windowController;
    if ([wc handleNavEvent:event]) return;
    unsigned short kc = event.keyCode;
    NSEventModifierFlags m = event.modifierFlags;
    if (kc == 48 && !(m & NSEventModifierFlagCommand) && !(m & NSEventModifierFlagControl)) {
        [wc tabChrome:!(m & NSEventModifierFlagShift)];
        return;
    }
    if (kc == 36) {
        [wc activateChrome];
        return;
    }
    if (kc == 53) {
        [wc escapeChrome];
        return;
    }
    [super keyDown:event];
}

- (ATAppDelegate *)app {
    return (ATAppDelegate *)NSApp.delegate;
}

- (void)reload {
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATBg() setFill];
    NSRectFill(self.bounds);
    [ATHair() setFill];
    NSRectFill(NSMakeRect(0, self.bounds.size.height - 1, self.bounds.size.width, 1));
    [_frames removeAllObjects];
    ATStore *store = self.app.store;
    int32_t wi = at_store_active_index(store);
    if (wi < 0) return;
    uint32_t n = at_store_tab_count(store, (uint32_t)wi);
    int32_t active = at_store_active_tab(store, (uint32_t)wi);
    CGFloat x = 10;
    CGFloat h = self.bounds.size.height;
    for (uint32_t i = 0; i < n; i++) {
        const char *ag = at_store_tab_agent(store, (uint32_t)wi, i);
        const char *nm = at_store_tab_name(store, (uint32_t)wi, i);
        NSString *title = nm ? @(nm) : ATAgentDisplayName(ag ? @(ag) : @"claude");
        NSImage *icon = ATAgentImage(ag ? @(ag) : @"claude");
        icon.size = NSMakeSize(12, 12);
        NSDictionary *attrs = @{
            NSFontAttributeName: ATSans(12),
            NSForegroundColorAttributeName: (i == (uint32_t)active) ? ATText() : ATMuted(),
        };
        const char *tidc = at_store_tab_id(store, (uint32_t)wi, i);
        ATActivity act = tidc
            ? [self.window.windowController activityForTabId:@(tidc)]
            : ATActivityNone;
        NSSize sz = [title sizeWithAttributes:attrs];
        CGFloat titleW = MIN(sz.width, 160.0);
        const char *folder = at_store_folder(store, (uint32_t)wi, 0);
        const char *home = at_store_home(store);
        NSString *gcwd = (folder && folder[0]) ? @(folder) : (home ? @(home) : nil);
        ATGitInfo *git = at_control_git_on() ? ATGitProbe(gcwd) : nil;
        NSString *gline = git.shortLine;
        if (at_control_git_on() && !gline.length) gline = @"—";
        NSDictionary *gattrs = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: git.dirty ? ATAccent() : ATMuted(),
        };
        CGFloat gW = 0;
        if (gline.length) {
            gW = MIN([gline sizeWithAttributes:gattrs].width, 88.0) + 8;
        }
        NSRect r = NSMakeRect(x, 0, 12 + 8 + titleW + 16 + gW, h);
        [_frames addObject:[NSValue valueWithRect:r]];
        NSRect iconR = NSMakeRect(r.origin.x + 8, floor((h - 12) / 2.0), 12, 12);
        [icon drawInRect:iconR
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0
          respectFlipped:YES
                   hints:nil];
        ATDrawActivityPipOnIcon(act, iconR);
        [title drawInRect:NSMakeRect(r.origin.x + 24, (h - sz.height) / 2.0 - 1, titleW, sz.height)
           withAttributes:ATTruncating(attrs)];
        if (gline.length) {
            [gline drawInRect:NSMakeRect(r.origin.x + 24 + titleW + 6, (h - sz.height) / 2.0, gW - 8, sz.height)
               withAttributes:ATTruncating(gattrs)];
        }
        if (i == (uint32_t)active) {
            [ATAccent() setFill];
            NSRectFill(NSMakeRect(r.origin.x + 8, h - 3, r.size.width - 16, 2));
        }
        x = NSMaxX(r) + 2;
    }
    NSString *plus = @"+";
    NSDictionary *plusAttrs = @{
        NSFontAttributeName: ATSans(16),
        NSForegroundColorAttributeName: ATMuted(),
    };
    NSSize psz = [plus sizeWithAttributes:plusAttrs];
    _plusFrame = NSMakeRect(x + 4, 0, 28, h);
    [plus drawAtPoint:NSMakePoint(_plusFrame.origin.x + 8, (h - psz.height) / 2.0 - 2) withAttributes:plusAttrs];
    if (self.focusIndex >= 0 && self.focusIndex < (NSInteger)_frames.count) {
        ATDrawFocus(_frames[(NSUInteger)self.focusIndex].rectValue);
    } else if (self.focusIndex == (NSInteger)_frames.count) {
        ATDrawFocus(_plusFrame);
    }
}

- (NSRect)frameForIndex:(NSUInteger)index {
    if (index >= _frames.count) return NSZeroRect;
    return _frames[index].rectValue;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, _plusFrame)) {
        if (self.target && self.addAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.addAction withObject:self];
#pragma clang diagnostic pop
        }
        return;
    }
    for (NSUInteger i = 0; i < _frames.count; i++) {
        if (!NSPointInRect(p, _frames[i].rectValue)) continue;
        if (self.target && self.selectAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.selectAction withObject:@(i)];
#pragma clang diagnostic pop
        }
        return;
    }
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    for (NSUInteger i = 0; i < _frames.count; i++) {
        if (!NSPointInRect(p, _frames[i].rectValue)) continue;
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tab"];
        NSMenuItem *rename = [[NSMenuItem alloc] initWithTitle:@"Rename"
                                                        action:@selector(renameTabAt:)
                                                 keyEquivalent:@""];
        rename.target = self.target;
        rename.representedObject = @(i);
        [menu addItem:rename];
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *sr = [[NSMenuItem alloc] initWithTitle:@"Split Right" action:@selector(splitRight) keyEquivalent:@""];
        sr.target = self.target;
        [menu addItem:sr];
        NSMenuItem *sd = [[NSMenuItem alloc] initWithTitle:@"Split Down" action:@selector(splitDown) keyEquivalent:@""];
        sd.target = self.target;
        [menu addItem:sd];
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:@"Close"
                                                      action:self.closeAction
                                               keyEquivalent:@""];
        close.target = self.target;
        close.representedObject = @(i);
        [menu addItem:close];
        return menu;
    }
    return nil;
}

@end

#pragma mark - Status

@interface ATStatusView : NSView
@property (nonatomic, copy) NSString *line;
@property (nonatomic, strong) NSImage *icon;
@end
@implementation ATStatusView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATBg() setFill];
    NSRectFill(self.bounds);
    [ATHair() setFill];
    NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, 1));
    CGFloat x = 10;
    if (self.icon) {
        NSRect ir = NSMakeRect(x, (self.bounds.size.height - 12) / 2.0, 12, 12);
        [self.icon drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
        x = NSMaxX(ir) + 6;
    }
    if (!self.line.length) return;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: ATMuted(),
    };
    NSSize sz = [self.line sizeWithAttributes:attrs];
    [self.line drawAtPoint:NSMakePoint(x, (self.bounds.size.height - sz.height) / 2.0) withAttributes:attrs];
}
@end

#pragma mark - Sheet

@interface ATNewSheet : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy) void (^onCreate)(NSString *name, NSArray<NSString *> *folders, NSString *agent);
@end

@implementation ATNewSheet {
    NSTextField *_name;
    NSPopUpButton *_agent;
    NSTableView *_table;
    NSMutableArray<NSString *> *_folders;
}

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 360)
                                              styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = @"New workspace";
    w.backgroundColor = ATBg();
    self = [super initWithWindow:w];
    if (!self) return nil;
    _folders = [NSMutableArray new];
    NSView *c = w.contentView;
    c.wantsLayer = YES;

    NSTextField *label = [self label:@"Name" y:320];
    [c addSubview:label];
    _name = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 292, 420, 24)];
    _name.placeholderString = @"amigo-stack";
    _name.bezeled = YES;
    _name.bezelStyle = NSTextFieldRoundedBezel;
    _name.font = ATSans(13);
    [c addSubview:_name];

    NSTextField *al = [self label:@"Default agent" y:260];
    [c addSubview:al];
    _agent = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 232, 220, 24) pullsDown:NO];
    ATFillAgentPopup(_agent, @"claude");
    [c addSubview:_agent];

    NSTextField *fl = [self label:@"Folders" y:200];
    [c addSubview:fl];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 72, 420, 124)];
    sv.hasVerticalScroller = YES;
    sv.borderType = NSLineBorder;
    _table = [[NSTableView alloc] initWithFrame:sv.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    col.title = @"Path";
    col.width = 400;
    [_table addTableColumn:col];
    _table.headerView = nil;
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = ATColorSurface();
    _table.rowHeight = 22;
    sv.documentView = _table;
    [c addSubview:sv];

    NSButton *add = [[NSButton alloc] initWithFrame:NSMakeRect(20, 40, 90, 24)];
    add.title = @"Add folder";
    add.bezelStyle = NSBezelStyleRounded;
    add.target = self;
    add.action = @selector(addFolder:);
    [c addSubview:add];

    NSButton *remove = [[NSButton alloc] initWithFrame:NSMakeRect(118, 40, 100, 24)];
    remove.title = @"Remove";
    remove.bezelStyle = NSBezelStyleRounded;
    remove.target = self;
    remove.action = @selector(removeFolder:);
    [c addSubview:remove];

    NSMenu *rowMenu = [[NSMenu alloc] initWithTitle:@"Folder"];
    NSMenuItem *rm = [[NSMenuItem alloc] initWithTitle:@"Remove"
                                                action:@selector(removeFolder:)
                                         keyEquivalent:@""];
    rm.target = self;
    [rowMenu addItem:rm];
    _table.menu = rowMenu;

    NSButton *cancel = [[NSButton alloc] initWithFrame:NSMakeRect(268, 12, 80, 28)];
    cancel.title = @"Cancel";
    cancel.bezelStyle = NSBezelStyleRounded;
    cancel.target = self;
    cancel.action = @selector(cancel:);
    cancel.keyEquivalent = @"\x1b";
    [c addSubview:cancel];

    NSButton *create = [[NSButton alloc] initWithFrame:NSMakeRect(356, 12, 84, 28)];
    create.title = @"Create";
    create.bezelStyle = NSBezelStyleRounded;
    create.target = self;
    create.action = @selector(create:);
    create.keyEquivalent = @"\r";
    [c addSubview:create];
    return self;
}

- (NSTextField *)label:(NSString *)s y:(CGFloat)y {
    NSTextField *t = [[NSTextField alloc] initWithFrame:NSMakeRect(20, y, 400, 18)];
    t.stringValue = s;
    t.bezeled = NO;
    t.editable = NO;
    t.selectable = NO;
    t.drawsBackground = NO;
    t.textColor = ATMuted();
    t.font = ATSans(11);
    return t;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)_folders.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    (void)tableView;
    (void)tableColumn;
    return _folders[(NSUInteger)row];
}

- (void)delete:(id)sender {
    [self removeFolder:sender];
}

- (void)removeFolder:(id)sender {
    (void)sender;
    NSInteger row = _table.selectedRow;
    if (row < 0 || row >= (NSInteger)_folders.count) {
        NSBeep();
        return;
    }
    [_folders removeObjectAtIndex:(NSUInteger)row];
    [_table reloadData];
    if (_folders.count > 0) {
        NSInteger next = row < (NSInteger)_folders.count ? row : (NSInteger)_folders.count - 1;
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)next] byExtendingSelection:NO];
    }
}

- (void)addFolder:(id)sender {
    (void)sender;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.allowsMultipleSelection = YES;
    p.canCreateDirectories = YES;
    p.prompt = @"Add";
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        for (NSURL *u in p.URLs) {
            NSString *path = u.path;
            if (path.length && ![_folders containsObject:path]) [_folders addObject:path];
        }
        [_table reloadData];
    }];
}

- (void)cancel:(id)sender {
    (void)sender;
    [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseCancel];
}

- (void)create:(id)sender {
    (void)sender;
    NSString *name = [_name.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    /* No folder is allowed: the workspace then runs in the Quickstart home. */
    if (name.length == 0) {
        NSBeep();
        return;
    }
    if (self.onCreate) self.onCreate(name, _folders, ATSelectedAgentId(_agent));
    [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseOK];
}

@end

#pragma mark - Window

@interface ATWindowController : NSWindowController
- (void)reload;
- (void)showNewWorkspace;
- (void)renameWorkspaceAt:(id)sender;
- (void)renameTabAt:(id)sender;
- (void)addFolderToActive;
- (void)quickstart;
- (void)showHistory;
- (void)showQueue;
- (ATTermView *)termForPane:(NSString *)paneId;
- (void)openHistorySession:(ATSessionInfo *)session;
- (void)refreshRam;
- (void)refreshDockBadge;
- (void)noteUserPresent;
- (ATActivity)activityForTabId:(NSString *)tabId;
- (void)splitRight;
- (void)splitDown;
- (void)tabChrome:(BOOL)forward;
- (void)activateChrome;
- (void)escapeChrome;
- (void)cycleChrome:(BOOL)forward;
- (BOOL)handleNavEvent:(NSEvent *)event;
- (void)cycleWorkspace:(BOOL)forward;
- (void)cycleSession:(BOOL)forward;
- (void)focusPaneDir:(int)dir;
- (void)jumpWorkspace:(NSInteger)index;
@end

@implementation ATWindowController {
    ATTabStrip *_tabs;
    ATSessionBar *_sessions;
    NSLayoutConstraint *_sessionH;
    ATQuickstartView *_empty;
    ATHistoryView *_history;
    ATSettingsView *_settings;
    ATQueueView *_queue;
    ATStatusView *_status;
    NSView *_stage;
    NSMutableDictionary<NSString *, ATTermView *> *_terms;
    ATNewSheet *_sheet;
    ATPage _page;
    NSMutableSet<NSString *> *_restoredTabIds;
    NSString *_statusBase;
    NSTimer *_ramTimer;
    NSTimer *_pulseTimer;
    __weak ATTermView *_visibleTerm;
    int _chrome; /* 0 none, 1 work, 2 session, 3 pane */
    NSInteger _chromeIndex;
    ATDockTileView *_dockTile;
}

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1040, 680)
                                              styleMask:(NSWindowStyleMaskTitled |
                                                         NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable |
                                                         NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = @"Amil";
    w.backgroundColor = ATBg();
    w.titlebarAppearsTransparent = YES;
    w.minSize = NSMakeSize(640, 400);
    w.releasedWhenClosed = NO;
    [w center];
    self = [super initWithWindow:w];
    w.delegate = (id<NSWindowDelegate>)self;
    if (!self) return nil;
    _terms = [NSMutableDictionary new];
    _page = ATPageQuickstart;
    _restoredTabIds = [NSMutableSet new];
    __weak ATWindowController *ramWeak = self;
    _ramTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [ramWeak refreshRam];
        [ramWeak refreshDockBadge];
    }];
    _ramTimer.tolerance = 0.3;
    /* Drives the activity dot. Pulses while working; one extra paint when
       a pane goes idle so the green dot does not stick. */
    _pulseTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES block:^(NSTimer *t) {
        (void)t;
        ATWindowController *s = ramWeak;
        if (!s) return;
        BOOL dirty = NO;
        for (ATTermView *tv in s->_terms.allValues) {
            if ([tv activityNeedsPaint]) dirty = YES;
        }
        if (dirty) {
            if (!s->_sessions.hidden) [s->_sessions setNeedsDisplay:YES];
            [s->_tabs setNeedsDisplay:YES];
        }
        [s refreshDockBadge];
    }];
    _pulseTimer.tolerance = 0.05;
    ATStore *st = ((ATAppDelegate *)NSApp.delegate).store;
    if (st) {
        uint32_t nw = at_store_workspace_count(st);
        for (uint32_t wi = 0; wi < nw; wi++) {
            uint32_t nt = at_store_tab_count(st, wi);
            for (uint32_t ti = 0; ti < nt; ti++) {
                const char *tid = at_store_tab_id(st, wi, ti);
                if (tid) [_restoredTabIds addObject:@(tid)];
            }
        }
    }

    NSView *c = w.contentView;
    _tabs = [[ATTabStrip alloc] initWithFrame:NSZeroRect];
    _tabs.target = self;
    _tabs.selectAction = @selector(selectWorkspace:);
    _tabs.newAction = @selector(showNewWorkspace);
    _tabs.foldersAction = @selector(showFolders:);
    _tabs.homeAction = @selector(showLanding);
    _tabs.historyAction = @selector(showHistory);
    _tabs.settingsAction = @selector(showSettings);
    _tabs.queueAction = @selector(showQueue);
    _sessions = [[ATSessionBar alloc] initWithFrame:NSZeroRect];
    _sessions.target = self;
    _sessions.selectAction = @selector(selectSession:);
    _sessions.addAction = @selector(addSession:);
    _sessions.closeAction = @selector(closeSessionAt:);
    _empty = [[ATQuickstartView alloc] initWithFrame:NSZeroRect];
    __weak ATWindowController *weak = self;
    _empty.onStart = ^(NSString *agentId) {
        [weak quickstartWithAgent:agentId];
    };
    _empty.onChangeHome = ^{
        [weak changeHomeFolder];
    };
    _history = [[ATHistoryView alloc] initWithFrame:NSZeroRect];
    _history.onOpen = ^(ATSessionInfo *session) {
        [weak openHistorySession:session];
    };
    _settings = [[ATSettingsView alloc] initWithFrame:NSZeroRect];
    _queue = [[ATQueueView alloc] initWithFrame:NSZeroRect];
    _status = [[ATStatusView alloc] initWithFrame:NSZeroRect];
    _stage = [[NSView alloc] initWithFrame:NSZeroRect];
    _stage.wantsLayer = YES;
    _stage.layer.backgroundColor = ATBg().CGColor;
    _tabs.translatesAutoresizingMaskIntoConstraints = NO;
    _sessions.translatesAutoresizingMaskIntoConstraints = NO;
    _empty.translatesAutoresizingMaskIntoConstraints = NO;
    _history.translatesAutoresizingMaskIntoConstraints = NO;
    _settings.translatesAutoresizingMaskIntoConstraints = NO;
    _queue.translatesAutoresizingMaskIntoConstraints = NO;
    _status.translatesAutoresizingMaskIntoConstraints = NO;
    _stage.translatesAutoresizingMaskIntoConstraints = NO;
    [c addSubview:_tabs];
    [c addSubview:_sessions];
    [c addSubview:_stage];
    [c addSubview:_empty];
    [c addSubview:_history];
    [c addSubview:_settings];
    _settings.hidden = YES;
    [c addSubview:_queue];
    _queue.hidden = YES;
    [c addSubview:_status];
    _sessionH = [_sessions.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [_tabs.topAnchor constraintEqualToAnchor:c.topAnchor],
        [_tabs.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
        [_tabs.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
        [_tabs.heightAnchor constraintEqualToConstant:34],
        [_sessions.topAnchor constraintEqualToAnchor:_tabs.bottomAnchor],
        [_sessions.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
        [_sessions.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
        _sessionH,
        [_status.bottomAnchor constraintEqualToAnchor:c.bottomAnchor],
        [_status.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
        [_status.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
        [_status.heightAnchor constraintEqualToConstant:22],
        [_stage.topAnchor constraintEqualToAnchor:_sessions.bottomAnchor],
        [_stage.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
        [_stage.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
        [_stage.bottomAnchor constraintEqualToAnchor:_status.topAnchor],
        [_empty.topAnchor constraintEqualToAnchor:_stage.topAnchor],
        [_empty.leadingAnchor constraintEqualToAnchor:_stage.leadingAnchor],
        [_empty.trailingAnchor constraintEqualToAnchor:_stage.trailingAnchor],
        [_empty.bottomAnchor constraintEqualToAnchor:_stage.bottomAnchor],
        [_history.topAnchor constraintEqualToAnchor:_stage.topAnchor],
        [_history.leadingAnchor constraintEqualToAnchor:_stage.leadingAnchor],
        [_history.trailingAnchor constraintEqualToAnchor:_stage.trailingAnchor],
        [_history.bottomAnchor constraintEqualToAnchor:_stage.bottomAnchor],
        [_settings.topAnchor constraintEqualToAnchor:_stage.topAnchor],
        [_settings.leadingAnchor constraintEqualToAnchor:_stage.leadingAnchor],
        [_settings.trailingAnchor constraintEqualToAnchor:_stage.trailingAnchor],
        [_settings.bottomAnchor constraintEqualToAnchor:_stage.bottomAnchor],
        [_queue.topAnchor constraintEqualToAnchor:_stage.topAnchor],
        [_queue.leadingAnchor constraintEqualToAnchor:_stage.leadingAnchor],
        [_queue.trailingAnchor constraintEqualToAnchor:_stage.trailingAnchor],
        [_queue.bottomAnchor constraintEqualToAnchor:_stage.bottomAnchor],
    ]];
    [self syncQuickstartHome];
    [self reload];
    return self;
}

- (ATAppDelegate *)app {
    return (ATAppDelegate *)NSApp.delegate;
}

static NSString *ATFormatRAM(uint64_t bytes) {
    if (bytes < 1024ull * 1024) return @"<1 MB";
    double mb = bytes / (1024.0 * 1024.0);
    if (mb < 1024.0) return [NSString stringWithFormat:@"%.0f MB", mb];
    double gb = mb / 1024.0;
    if (gb < 10.0) return [NSString stringWithFormat:@"%.1f GB", gb];
    return [NSString stringWithFormat:@"%.0f GB", gb];
}

/* Working wins; otherwise a pane waiting for input beats a hollow start. */
- (ATActivity)activityWhere:(BOOL (^)(ATTermView *tv))match {
    ATActivity best = ATActivityNone;
    for (ATTermView *tv in _terms.allValues) {
        if (!match(tv)) continue;
        ATActivity a = tv.activity;
        if (a == ATActivityWorking) return ATActivityWorking;
        if (a > best) best = a;
    }
    return best;
}

- (ATActivity)activityForTabId:(NSString *)tabId {
    if (!tabId.length) return ATActivityNone;
    return [self activityWhere:^BOOL(ATTermView *tv) {
        return [tv.tabId isEqualToString:tabId];
    }];
}

/* Panes of a workspace keep running while you are in another one, so this is
   live even for the workspaces you cannot see. */
- (ATActivity)activityForWorkspaceId:(NSString *)wsId {
    if (!wsId.length) return ATActivityNone;
    return [self activityWhere:^BOOL(ATTermView *tv) {
        return [tv.workspaceId isEqualToString:wsId];
    }];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (at_control_background_on()) {
        [sender orderOut:nil];
        return NO;
    }
    return YES;
}

/* Pip on the Dock icon: green while an agent works, copper when one is
   waiting for you. Idle restores the real app icon. */
- (void)refreshDockBadge {
    ATActivity best = ATActivityNone;
    NSUInteger working = 0;
    for (ATTermView *tv in _terms.allValues) {
        ATActivity a = tv.activity;
        if (a == ATActivityWorking) {
            best = ATActivityWorking;
            working++;
        } else if (best != ATActivityWorking && a > best) {
            best = a;
        }
    }
    NSDockTile *tile = NSApp.dockTile;
    tile.badgeLabel = nil;
    BOOL pip = (best == ATActivityWorking || best == ATActivityNeedsInput);
    if (!pip) {
        if (tile.contentView) {
            tile.contentView = nil;
            _dockTile = nil;
            [tile display];
        }
        return;
    }
    if (!_dockTile) {
        _dockTile = [[ATDockTileView alloc] initWithFrame:NSMakeRect(0, 0, 128, 128)];
        tile.contentView = _dockTile;
    }
    BOOL same = _dockTile.activity == best && _dockTile.workingCount == working;
    _dockTile.activity = best;
    _dockTile.workingCount = working;
    if (!same || best == ATActivityWorking) {
        [_dockTile setNeedsDisplay:YES];
        [tile display];
    }
}

- (void)noteUserPresent {
    id fr = self.window.firstResponder;
    if ([fr isKindOfClass:[ATTermView class]]) [(ATTermView *)fr noteSeen];
    else if (_visibleTerm) [_visibleTerm noteSeen];
    [self refreshDockBadge];
    if (!_sessions.hidden) [_sessions setNeedsDisplay:YES];
    [_tabs setNeedsDisplay:YES];
}

- (void)refreshRam {
    if (_page != ATPageWorkspace || !_statusBase.length) return;
    ATTermView *tv = _visibleTerm;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:_statusBase];
    if (at_control_git_on()) {
        NSString *gcwd = tv.cwd;
        if (!gcwd.length) gcwd = [self homeFolder];
        ATGitInfo *git = ATGitProbe(gcwd);
        [parts addObject:git.shortLine.length ? git.shortLine : @"no git"];
    }
    uint64_t bytes = tv ? [tv childFootprint] : 0;
    if (bytes > 0) [parts addObject:ATFormatRAM(bytes)];
    NSString *line = [parts componentsJoinedByString:@"  ·  "];
    if ([_status.line isEqualToString:line]) return;
    _status.line = line;
    [_status setNeedsDisplay:YES];
    if (!_sessions.hidden) [_sessions setNeedsDisplay:YES];
}

- (ATTermView *)ensureTerm:(NSString *)paneId
                     agent:(NSString *)agId
                   session:(NSString *)session
                       cwd:(NSString *)cwd
                   folders:(NSArray<NSString *> *)folders
                 workspace:(NSString *)wsName {
    ATTermView *tv = _terms[paneId];
    if (tv) return tv;
    ATStore *store = self.app.store;
    NSString *wanted = ATAgentCommand(agId);
    BOOL resume = session.length > 0 && ATSessionExists(wanted, cwd, session);
    if (!session.length && [_restoredTabIds containsObject:paneId]) {
        NSString *found = ATFindSessionId(wanted, cwd);
        if (found.length) {
            session = found;
            resume = YES;
        }
    }
    if (!session.length && ([wanted isEqualToString:@"claude"] ||
                            [wanted isEqualToString:@"grok"] ||
                            [wanted isEqualToString:@"gemini"])) {
        session = ATMakeUUID();
        resume = NO;
    }
    if (session.length) at_store_set_tab_session(store, paneId.UTF8String, session.UTF8String);
    tv = [[ATTermView alloc] initWithCwd:cwd
                                 command:wanted
                                 folders:folders
                               workspace:wsName ?: @""
                                 session:session
                                  resume:resume];
    tv.paneId = paneId;
    __weak ATWindowController *weak = self;
    NSString *key = paneId;
    tv.onSession = ^(NSString *sid) {
        if (!sid.length) return;
        at_store_set_tab_session(((ATAppDelegate *)NSApp.delegate).store, key.UTF8String, sid.UTF8String);
    };
    tv.onFocus = ^(NSString *pid) {
        ATWindowController *self = weak;
        if (!self || !pid.length) return;
        int32_t wi = at_store_active_index(self.app.store);
        int32_t ti = wi >= 0 ? at_store_active_tab(self.app.store, (uint32_t)wi) : -1;
        if (wi < 0 || ti < 0) return;
        at_store_set_active_pane(self.app.store, (uint32_t)wi, (uint32_t)ti, pid.UTF8String);
        self->_visibleTerm = self->_terms[pid];
        [self refreshRam];
    };
    _terms[paneId] = tv;
    return tv;
}

- (NSView *)mountNode:(uint32_t)idx
                store:(ATStore *)store
                   ws:(uint32_t)wi
                  tab:(uint32_t)ti
                  cwd:(NSString *)cwd
              folders:(NSArray<NSString *> *)folders
            workspace:(NSString *)wsName {
    uint8_t kind = at_store_layout_kind(store, idx);
    if (kind == 0) {
        const char *pid = at_store_layout_pane_id(store, idx);
        const char *ag = at_store_layout_pane_agent(store, idx);
        const char *sess = at_store_layout_pane_session(store, idx);
        if (!pid) return [[NSView alloc] initWithFrame:NSZeroRect];
        ATTermView *tv = [self ensureTerm:@(pid)
                                    agent:ag ? @(ag) : @"claude"
                                  session:sess ? @(sess) : nil
                                      cwd:cwd
                                  folders:folders
                                workspace:wsName];
        const char *tid = at_store_tab_id(store, wi, ti);
        if (tid) tv.tabId = @(tid);
        const char *wid = at_store_id(store, wi);
        if (wid) tv.workspaceId = @(wid);
        tv.hidden = NO;
        return tv;
    }
    ATSplitView *sp = [[ATSplitView alloc] initWithFrame:NSZeroRect];
    sp.vertical = (kind == 1);
    sp.ratio = at_store_layout_ratio(store, idx);
    sp.nodeIndex = idx;
    __weak ATWindowController *weak = self;
    sp.onRatio = ^(uint32_t node, CGFloat r) {
        at_store_set_split_ratio(weak.app.store, node, (float)r);
    };
    int32_t ai = at_store_layout_a(store, idx);
    int32_t bi = at_store_layout_b(store, idx);
    NSView *a = ai >= 0 ? [self mountNode:(uint32_t)ai store:store ws:wi tab:ti cwd:cwd folders:folders workspace:wsName] : [[NSView alloc] initWithFrame:NSZeroRect];
    NSView *b = bi >= 0 ? [self mountNode:(uint32_t)bi store:store ws:wi tab:ti cwd:cwd folders:folders workspace:wsName] : [[NSView alloc] initWithFrame:NSZeroRect];
    [sp setFirst:a second:b];
    return sp;
}

- (void)showLanding {
    [self clearChrome];
    _page = ATPageQuickstart;
    [self reload];
}

- (void)showHistory {
    [self clearChrome];
    _page = ATPageHistory;
    [self reload];
}

- (ATTermView *)termForPane:(NSString *)paneId {
    if (!paneId.length) return nil;
    return _terms[paneId];
}

- (void)showSettings {
    [self clearChrome];
    _page = ATPageSettings;
    [self reload];
}

- (void)showQueue {
    [self clearChrome];
    _page = ATPageQueue;
    [self reload];
}

- (void)selectWorkspace:(NSNumber *)index {
    [self clearChrome];
    _page = ATPageWorkspace;
    at_store_set_active(self.app.store, index.intValue);
    at_store_save(self.app.store);
    [self reload];
}

- (void)showNewWorkspace {
    _sheet = [[ATNewSheet alloc] init];
    __weak ATWindowController *weak = self;
    _sheet.onCreate = ^(NSString *name, NSArray<NSString *> *folders, NSString *agent) {
        [weak createWorkspace:name folders:folders agent:agent];
    };
    [self.window beginSheet:_sheet.window completionHandler:^(NSModalResponse resp) {
        (void)resp;
        self->_sheet = nil;
    }];
}

- (void)createWorkspace:(NSString *)name folders:(NSArray<NSString *> *)folders agent:(NSString *)agent {
    if (![self makeWorkspace:name folders:folders agent:agent]) return;
    _page = ATPageWorkspace;
    [self reload];
}

- (NSString *)homeFolder {
    const char *h = at_store_home(self.app.store);
    if (h && h[0]) return @(h);
    return nil;
}

- (void)syncQuickstartHome {
    NSString *home = [self homeFolder];
    if (!home.length) {
        home = NSHomeDirectory();
        if (home.length) at_store_set_home(self.app.store, home.fileSystemRepresentation);
    }
    _empty.homePath = home;
    [_empty reloadHome];
}

- (void)changeHomeFolder {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.allowsMultipleSelection = NO;
    p.canCreateDirectories = YES;
    p.prompt = @"Use";
    p.message = @"Main folder for Quickstart";
    NSString *cur = [self homeFolder];
    if (cur) p.directoryURL = [NSURL fileURLWithPath:cur];
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || p.URLs.count == 0) return;
        NSString *path = p.URLs.firstObject.path;
        if (!path.length) return;
        at_store_set_home(self.app.store, path.fileSystemRepresentation);
        [self syncQuickstartHome];
    }];
}

- (void)quickstart {
    _page = ATPageQuickstart;
    [self reload];
}

- (void)quickstartWithAgent:(NSString *)agentId {
    NSString *home = [self homeFolder];
    if (!home.length) {
        [self changeHomeFolder];
        return;
    }
    ATStore *store = self.app.store;
    uint32_t n = at_store_workspace_count(store);
    for (uint32_t i = 0; i < n; i++) {
        const char *f = at_store_folder(store, i, 0);
        if (f && [@(f) isEqualToString:home]) {
            at_store_set_active(store, (int32_t)i);
            uint32_t n = at_store_tab_count(store, i);
            BOOL found = NO;
            for (uint32_t t = 0; t < n; t++) {
                const char *ag = at_store_tab_agent(store, i, t);
                if (ag && [@(ag) isEqualToString:agentId]) {
                    at_store_set_active_tab(store, i, (int32_t)t);
                    found = YES;
                    break;
                }
            }
            if (!found) at_store_add_tab(store, i, agentId.UTF8String);
            _page = ATPageWorkspace;
            [self reload];
            return;
        }
    }
    [self createWorkspace:home.lastPathComponent folders:@[home] agent:agentId];
}

- (void)selectSession:(NSNumber *)index {
    int32_t wi = at_store_active_index(self.app.store);
    if (wi < 0) return;
    at_store_set_active_tab(self.app.store, (uint32_t)wi, index.intValue);
    [self reload];
}

- (void)addSession:(id)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Agent"];
    for (uint32_t i = 0; i < at_agent_count(); i++) {
        const ATAgentInfo *a = at_agent_at(i);
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@(a->name)
                                                      action:@selector(addSessionAgent:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(a->id);
        NSImage *img = ATAgentImage(@(a->id));
        img.size = NSMakeSize(14, 14);
        item.image = img;
        [menu addItem:item];
    }
    NSEvent *ev = NSApp.currentEvent;
    if ([sender isKindOfClass:[NSView class]] && ev) {
        [NSMenu popUpContextMenu:menu withEvent:ev forView:sender];
    } else {
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(40, 20) inView:_sessions];
    }
}

- (void)addSessionAgent:(NSMenuItem *)item {
    NSString *agent = item.representedObject;
    int32_t wi = at_store_active_index(self.app.store);
    if (wi < 0 || !agent.length) return;
    at_store_add_tab(self.app.store, (uint32_t)wi, agent.UTF8String);
    [self reload];
}

- (void)splitRight {
    [self splitHoriz:NO];
}

- (void)splitDown {
    [self splitHoriz:YES];
}

- (void)splitHoriz:(BOOL)horiz {
    if (_page != ATPageWorkspace) return;
    ATStore *store = self.app.store;
    int32_t wi = at_store_active_index(store);
    int32_t ti = wi >= 0 ? at_store_active_tab(store, (uint32_t)wi) : -1;
    if (wi < 0 || ti < 0) return;
    if (at_store_split(store, (uint32_t)wi, (uint32_t)ti, horiz ? 1 : 0) != 0) return;
    [self reload];
}

- (BOOL)handleNavEvent:(NSEvent *)event {
    NSEventModifierFlags m = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL cmd = (m & NSEventModifierFlagCommand) != 0;
    BOOL opt = (m & NSEventModifierFlagOption) != 0;
    BOOL ctrl = (m & NSEventModifierFlagControl) != 0;
    BOOL shift = (m & NSEventModifierFlagShift) != 0;
    unsigned short kc = event.keyCode;
    if (!cmd && !ctrl && !opt && kc == 97) {
        [self cycleChrome:!shift];
        return YES;
    }
    if (!cmd && !ctrl && !opt && kc == 48 && _chrome != 0 && _page == ATPageWorkspace) {
        [self tabChrome:!shift];
        return YES;
    }
    if (!cmd && !ctrl && !opt && kc == 36 && _chrome != 0 && _page == ATPageWorkspace) {
        [self activateChrome];
        return YES;
    }
    if (!cmd && !ctrl && !opt && kc == 53 && _chrome != 0 && _page == ATPageWorkspace) {
        [self escapeChrome];
        return YES;
    }
    if (ctrl && !cmd && !opt && kc == 48) {
        [self cycleWorkspace:!shift];
        return YES;
    }
    if (cmd && opt && !ctrl) {
        if (kc == 123) { [self focusPaneDir:0]; return YES; }
        if (kc == 124) { [self focusPaneDir:1]; return YES; }
        if (kc == 126) { [self focusPaneDir:2]; return YES; }
        if (kc == 125) { [self focusPaneDir:3]; return YES; }
    }
    if (cmd && shift && !opt && !ctrl) {
        if (kc == 33) { [self cycleSession:NO]; return YES; }
        if (kc == 30) { [self cycleSession:YES]; return YES; }
    }
    if (cmd && !opt && !ctrl && !shift) {
        NSString *ch = event.charactersIgnoringModifiers;
        if (ch.length == 1) {
            unichar u = [ch characterAtIndex:0];
            if (u >= '1' && u <= '9') {
                [self jumpWorkspace:(NSInteger)(u - '1')];
                return YES;
            }
        }
    }
    return NO;
}

- (void)cycleWorkspace:(BOOL)forward {
    ATStore *store = self.app.store;
    uint32_t n = at_store_workspace_count(store);
    if (_page == ATPageQuickstart) {
        if (forward) [self showHistory];
        else if (n > 0) [self selectWorkspace:@(n - 1)];
        else [self showSettings];
        return;
    }
    if (_page == ATPageHistory) {
        if (forward) [self showSettings];
        else [self quickstart];
        return;
    }
    if (_page == ATPageSettings) {
        if (forward) [self showQueue];
        else [self showHistory];
        return;
    }
    if (_page == ATPageQueue) {
        if (forward) {
            if (n > 0) [self selectWorkspace:@0];
            else [self quickstart];
        } else {
            [self showSettings];
        }
        return;
    }
    int32_t i = at_store_active_index(store);
    if (n == 0) {
        if (forward) [self showHistory];
        else [self showQueue];
        return;
    }
    if (forward) {
        if (i < 0 || (uint32_t)i + 1 >= n) [self quickstart];
        else [self selectWorkspace:@(i + 1)];
    } else {
        if (i <= 0) [self showQueue];
        else [self selectWorkspace:@(i - 1)];
    }
}

- (void)cycleSession:(BOOL)forward {
    if (_page != ATPageWorkspace) return;
    ATStore *store = self.app.store;
    int32_t wi = at_store_active_index(store);
    if (wi < 0) return;
    uint32_t n = at_store_tab_count(store, (uint32_t)wi);
    if (n == 0) return;
    int32_t ti = at_store_active_tab(store, (uint32_t)wi);
    if (ti < 0) ti = 0;
    int32_t next = forward ? ti + 1 : ti - 1;
    if (next < 0) next = (int32_t)n - 1;
    if ((uint32_t)next >= n) next = 0;
    [self selectSession:@(next)];
}

- (void)jumpWorkspace:(NSInteger)index {
    ATStore *store = self.app.store;
    uint32_t n = at_store_workspace_count(store);
    if (index < 0 || (uint32_t)index >= n) return;
    [self selectWorkspace:@(index)];
}

- (void)collectPanesFrom:(uint32_t)idx
                    rect:(NSRect)r
                   store:(ATStore *)store
                     ids:(NSMutableArray<NSString *> *)ids
                  frames:(NSMutableArray<NSValue *> *)frames {
    uint8_t kind = at_store_layout_kind(store, idx);
    if (kind == 0) {
        const char *pid = at_store_layout_pane_id(store, idx);
        if (pid) {
            [ids addObject:@(pid)];
            [frames addObject:[NSValue valueWithRect:r]];
        }
        return;
    }
    CGFloat t = 5;
    CGFloat ratio = at_store_layout_ratio(store, idx);
    int32_t ai = at_store_layout_a(store, idx);
    int32_t bi = at_store_layout_b(store, idx);
    NSRect ra, rb;
    if (kind == 1) {
        CGFloat x = floor((NSWidth(r) - t) * ratio);
        ra = NSMakeRect(NSMinX(r), NSMinY(r), x, NSHeight(r));
        rb = NSMakeRect(NSMinX(r) + x + t, NSMinY(r), NSWidth(r) - x - t, NSHeight(r));
    } else {
        CGFloat y = floor((NSHeight(r) - t) * ratio);
        ra = NSMakeRect(NSMinX(r), NSMinY(r), NSWidth(r), y);
        rb = NSMakeRect(NSMinX(r), NSMinY(r) + y + t, NSWidth(r), NSHeight(r) - y - t);
    }
    if (ai >= 0) [self collectPanesFrom:(uint32_t)ai rect:ra store:store ids:ids frames:frames];
    if (bi >= 0) [self collectPanesFrom:(uint32_t)bi rect:rb store:store ids:ids frames:frames];
}

- (CGFloat)scoreDir:(int)dir from:(NSRect)a to:(NSRect)b {
    CGFloat ax = NSMidX(a), ay = NSMidY(a);
    CGFloat bx = NSMidX(b), by = NSMidY(b);
    BOOL ok = NO;
    CGFloat along = 0, perp = 0;
    switch (dir) {
        case 0:
            ok = NSMaxX(b) <= NSMinX(a) + 4;
            along = NSMinX(a) - NSMaxX(b);
            perp = fabs(ay - by);
            break;
        case 1:
            ok = NSMinX(b) >= NSMaxX(a) - 4;
            along = NSMinX(b) - NSMaxX(a);
            perp = fabs(ay - by);
            break;
        case 2:
            ok = NSMaxY(b) <= NSMinY(a) + 4;
            along = NSMinY(a) - NSMaxY(b);
            perp = fabs(ax - bx);
            break;
        case 3:
            ok = NSMinY(b) >= NSMaxY(a) - 4;
            along = NSMinY(b) - NSMaxY(a);
            perp = fabs(ax - bx);
            break;
        default:
            return CGFLOAT_MAX;
    }
    if (!ok || along < -1) return CGFLOAT_MAX;
    return along + perp * 0.35;
}

- (void)focusPaneDir:(int)dir {
    if (_page != ATPageWorkspace) return;
    ATStore *store = self.app.store;
    int32_t wi = at_store_active_index(store);
    int32_t ti = wi >= 0 ? at_store_active_tab(store, (uint32_t)wi) : -1;
    if (wi < 0 || ti < 0) return;
    at_store_layout_build(store, (uint32_t)wi, (uint32_t)ti);
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    NSMutableArray<NSValue *> *frames = [NSMutableArray new];
    [self collectPanesFrom:0 rect:_stage.bounds store:store ids:ids frames:frames];
    if (ids.count < 2) return;
    const char *ap = at_store_active_pane(store, (uint32_t)wi, (uint32_t)ti);
    NSString *cur = ap ? @(ap) : ids.firstObject;
    NSUInteger me = [ids indexOfObject:cur];
    if (me == NSNotFound) me = 0;
    NSRect f = [frames[me] rectValue];
    NSInteger best = -1;
    CGFloat bestScore = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < ids.count; i++) {
        if (i == me) continue;
        CGFloat s = [self scoreDir:dir from:f to:[frames[i] rectValue]];
        if (s < bestScore) {
            bestScore = s;
            best = (NSInteger)i;
        }
    }
    if (best < 0) return;
    NSString *pid = ids[(NSUInteger)best];
    at_store_set_active_pane(store, (uint32_t)wi, (uint32_t)ti, pid.UTF8String);
    ATTermView *tv = _terms[pid];
    _visibleTerm = tv;
    if (tv) [self.window makeFirstResponder:tv];
    for (ATTermView *t in _terms.allValues) [t setNeedsDisplay:YES];
    [self refreshRam];
}

- (NSInteger)workStopCount {
    return 4 + (NSInteger)at_store_workspace_count(self.app.store) + 1;
}

- (NSInteger)sessionStopCount {
    int32_t wi = at_store_active_index(self.app.store);
    if (wi < 0 || _page != ATPageWorkspace) return 0;
    return (NSInteger)at_store_tab_count(self.app.store, (uint32_t)wi) + 1;
}

- (NSArray<NSString *> *)paneIds {
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    if (_page != ATPageWorkspace) return ids;
    ATStore *store = self.app.store;
    int32_t wi = at_store_active_index(store);
    int32_t ti = wi >= 0 ? at_store_active_tab(store, (uint32_t)wi) : -1;
    if (wi < 0 || ti < 0) return ids;
    at_store_layout_build(store, (uint32_t)wi, (uint32_t)ti);
    uint32_t n = at_store_layout_count(store);
    for (uint32_t k = 0; k < n; k++) {
        if (at_store_layout_kind(store, k) != 0) continue;
        const char *pid = at_store_layout_pane_id(store, k);
        if (pid) [ids addObject:@(pid)];
    }
    return ids;
}

- (void)applyChromeFocus {
    NSInteger nWork = [self workStopCount];
    NSInteger nSess = [self sessionStopCount];
    NSArray<NSString *> *panes = [self paneIds];
    if (_chrome == 1) {
        if (_chromeIndex < 0) _chromeIndex = 0;
        if (_chromeIndex >= nWork) _chromeIndex = nWork - 1;
    } else if (_chrome == 2) {
        if (nSess <= 0) {
            _chrome = 1;
            _chromeIndex = 0;
        } else {
            if (_chromeIndex < 0) _chromeIndex = 0;
            if (_chromeIndex >= nSess) _chromeIndex = nSess - 1;
        }
    } else if (_chrome == 3) {
        if (panes.count == 0) {
            _chrome = 2;
            _chromeIndex = 0;
        } else {
            if (_chromeIndex < 0) _chromeIndex = 0;
            if (_chromeIndex >= (NSInteger)panes.count) _chromeIndex = (NSInteger)panes.count - 1;
        }
    }
    _tabs.focusIndex = (_chrome == 1) ? _chromeIndex : -1;
    _sessions.focusIndex = (_chrome == 2) ? _chromeIndex : -1;
    [_tabs setNeedsDisplay:YES];
    [_sessions setNeedsDisplay:YES];
    NSString *hl = (_chrome == 3 && _chromeIndex >= 0 && _chromeIndex < (NSInteger)panes.count)
        ? panes[(NSUInteger)_chromeIndex] : nil;
    for (NSString *k in _terms) {
        ATTermView *tv = _terms[k];
        tv.keyboardHighlight = hl && [k isEqualToString:hl];
        [tv setNeedsDisplay:YES];
    }
    if (_chrome == 1) [self.window makeFirstResponder:_tabs];
    else if (_chrome == 2) [self.window makeFirstResponder:_sessions];
    else if (_chrome == 3) [self.window makeFirstResponder:_tabs];
}

- (void)clearChrome {
    _chrome = 0;
    _chromeIndex = 0;
    _tabs.focusIndex = -1;
    _sessions.focusIndex = -1;
    [_tabs setNeedsDisplay:YES];
    [_sessions setNeedsDisplay:YES];
    for (ATTermView *tv in _terms.allValues) {
        tv.keyboardHighlight = NO;
        [tv setNeedsDisplay:YES];
    }
}

- (void)tabChrome:(BOOL)forward {
    if (_page == ATPageQuickstart || _page == ATPageHistory || _page == ATPageSettings || _page == ATPageQueue) return;
    if (_chrome == 0) {
        _chrome = 2;
        int32_t wi = at_store_active_index(self.app.store);
        int32_t ti = wi >= 0 ? at_store_active_tab(self.app.store, (uint32_t)wi) : 0;
        _chromeIndex = ti >= 0 ? ti : 0;
        [self applyChromeFocus];
        return;
    }
    NSInteger nWork = [self workStopCount];
    NSInteger nSess = [self sessionStopCount];
    NSInteger nPane = (NSInteger)[self paneIds].count;
    NSInteger dir = forward ? 1 : -1;
    _chromeIndex += dir;
    if (_chrome == 1) {
        if (_chromeIndex >= nWork) {
            _chrome = nSess ? 2 : (nPane ? 3 : 1);
            _chromeIndex = 0;
        } else if (_chromeIndex < 0) {
            if (nPane) {
                _chrome = 3;
                _chromeIndex = nPane - 1;
            } else if (nSess) {
                _chrome = 2;
                _chromeIndex = nSess - 1;
            } else {
                _chromeIndex = nWork - 1;
            }
        }
    } else if (_chrome == 2) {
        if (_chromeIndex >= nSess) {
            _chrome = nPane ? 3 : 1;
            _chromeIndex = 0;
        } else if (_chromeIndex < 0) {
            _chrome = 1;
            _chromeIndex = nWork - 1;
        }
    } else if (_chrome == 3) {
        if (_chromeIndex >= nPane) {
            _chrome = 1;
            _chromeIndex = 0;
        } else if (_chromeIndex < 0) {
            _chrome = nSess ? 2 : 1;
            _chromeIndex = nSess ? nSess - 1 : nWork - 1;
        }
    }
    [self applyChromeFocus];
}

- (void)cycleChrome:(BOOL)forward {
    if (_page != ATPageWorkspace) {
        [self cycleWorkspace:forward];
        return;
    }
    if (_chrome == 0) {
        _chrome = forward ? 1 : 3;
        if (_chrome == 1) {
            int32_t i = at_store_active_index(self.app.store);
            _chromeIndex = i >= 0 ? 4 + i : 0;
        } else {
            _chromeIndex = (NSInteger)[self paneIds].count - 1;
            if (_chromeIndex < 0) {
                _chrome = 2;
                _chromeIndex = 0;
            }
        }
        [self applyChromeFocus];
        return;
    }
    if (forward) {
        if (_chrome == 1) {
            _chrome = [self sessionStopCount] ? 2 : 3;
            _chromeIndex = 0;
        } else if (_chrome == 2) {
            _chrome = [self paneIds].count ? 3 : 0;
            _chromeIndex = 0;
        } else {
            [self escapeChrome];
            return;
        }
        if (_chrome == 3 && [self paneIds].count == 0) {
            [self escapeChrome];
            return;
        }
        [self applyChromeFocus];
    } else {
        if (_chrome == 3) {
            _chrome = 2;
            _chromeIndex = [self sessionStopCount] - 1;
        } else if (_chrome == 2) {
            _chrome = 1;
            int32_t i = at_store_active_index(self.app.store);
            _chromeIndex = i >= 0 ? 4 + i : 0;
        } else {
            [self escapeChrome];
            return;
        }
        [self applyChromeFocus];
    }
}

- (void)escapeChrome {
    [self clearChrome];
    if (_visibleTerm) [self.window makeFirstResponder:_visibleTerm];
}

- (void)activateChrome {
    if (_chrome == 0) return;
    if (_chrome == 1) {
        NSInteger n = (NSInteger)at_store_workspace_count(self.app.store);
        if (_chromeIndex == 0) {
            [self clearChrome];
            [self showLanding];
            return;
        }
        if (_chromeIndex == 1) {
            [self clearChrome];
            [self showHistory];
            return;
        }
        if (_chromeIndex == 2) {
            [self clearChrome];
            [self showSettings];
            return;
        }
        if (_chromeIndex == 3) {
            [self clearChrome];
            [self showQueue];
            return;
        }
        if (_chromeIndex >= 4 && _chromeIndex - 4 < n) {
            [self clearChrome];
            [self selectWorkspace:@(_chromeIndex - 4)];
            return;
        }
        if (_chromeIndex >= 4 + n) {
            [self clearChrome];
            [self showNewWorkspace];
            return;
        }
    } else if (_chrome == 2) {
        int32_t wi = at_store_active_index(self.app.store);
        uint32_t n = wi >= 0 ? at_store_tab_count(self.app.store, (uint32_t)wi) : 0;
        if (_chromeIndex >= 0 && _chromeIndex < (NSInteger)n) {
            [self clearChrome];
            [self selectSession:@(_chromeIndex)];
            return;
        }
        if (_chromeIndex == (NSInteger)n) {
            [self clearChrome];
            [self addSession:_sessions];
            return;
        }
    } else if (_chrome == 3) {
        NSArray<NSString *> *panes = [self paneIds];
        if (_chromeIndex >= 0 && _chromeIndex < (NSInteger)panes.count) {
            NSString *pid = panes[(NSUInteger)_chromeIndex];
            int32_t wi = at_store_active_index(self.app.store);
            int32_t ti = wi >= 0 ? at_store_active_tab(self.app.store, (uint32_t)wi) : -1;
            if (wi >= 0 && ti >= 0) {
                at_store_set_active_pane(self.app.store, (uint32_t)wi, (uint32_t)ti, pid.UTF8String);
            }
            [self clearChrome];
            ATTermView *tv = _terms[pid];
            _visibleTerm = tv;
            if (tv) [self.window makeFirstResponder:tv];
            [self refreshRam];
            return;
        }
    }
}

- (void)closeSession {
    int32_t wi = at_store_active_index(self.app.store);
    if (wi < 0) return;
    int32_t ti = at_store_active_tab(self.app.store, (uint32_t)wi);
    if (ti < 0) return;
    const char *ap = at_store_active_pane(self.app.store, (uint32_t)wi, (uint32_t)ti);
    if (ap && at_store_close_pane(self.app.store, (uint32_t)wi, (uint32_t)ti, ap) == 0) {
        NSString *key = @(ap);
        ATTermView *tv = _terms[key];
        [tv killChild];
        [tv removeFromSuperview];
        [_terms removeObjectForKey:key];
        [self reload];
        return;
    }
    [self closeSessionIndex:ti];
}

- (void)closeSessionAt:(id)sender {
    NSNumber *n = [sender isKindOfClass:[NSMenuItem class]] ? [sender representedObject] : sender;
    if (![n isKindOfClass:[NSNumber class]]) return;
    [self closeSessionIndex:n.intValue];
}

- (void)closeSessionIndex:(int32_t)ti {
    int32_t wi = at_store_active_index(self.app.store);
    if (wi < 0 || ti < 0) return;
    ATStore *store = self.app.store;
    at_store_layout_build(store, (uint32_t)wi, (uint32_t)ti);
    uint32_t n = at_store_layout_count(store);
    for (uint32_t k = 0; k < n; k++) {
        if (at_store_layout_kind(store, k) != 0) continue;
        const char *pid = at_store_layout_pane_id(store, k);
        if (!pid) continue;
        NSString *key = @(pid);
        ATTermView *tv = _terms[key];
        [tv killChild];
        [tv removeFromSuperview];
        [_terms removeObjectForKey:key];
    }
    if (at_store_remove_tab(store, (uint32_t)wi, (uint32_t)ti) != 0) {
        [self closeActive];
        return;
    }
    [self reload];
}

- (void)closeWorkspaceAt:(id)sender {
    NSNumber *n = [sender isKindOfClass:[NSMenuItem class]] ? [sender representedObject] : sender;
    if (![n isKindOfClass:[NSNumber class]]) return;
    at_store_set_active(self.app.store, n.intValue);
    [self closeActive];
}

- (void)renameWorkspaceAt:(id)sender {
    NSNumber *n = [sender isKindOfClass:[NSMenuItem class]] ? [sender representedObject] : sender;
    if (![n isKindOfClass:[NSNumber class]]) return;
    uint32_t idx = n.unsignedIntValue;
    if (idx >= at_store_workspace_count(self.app.store)) return;
    const char *cur = at_store_name(self.app.store, idx);
    __weak typeof(self) weakSelf = self;
    [ATInlineRename beginInView:_tabs
                          frame:[_tabs frameForIndex:idx]
                           text:cur ? @(cur) : @""
                         commit:^(NSString *name) {
        typeof(self) s = weakSelf;
        if (!s) return;
        NSString *trimmed = [name stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        /* A workspace must keep a name; an empty edit is a no-op. */
        if (!trimmed.length) return;
        at_store_set_name(s.app.store, idx, trimmed.UTF8String);
        [s reload];
    }];
}

- (void)renameTabAt:(id)sender {
    NSNumber *n = [sender isKindOfClass:[NSMenuItem class]] ? [sender representedObject] : sender;
    if (![n isKindOfClass:[NSNumber class]]) return;
    int32_t wi = at_store_active_index(self.app.store);
    if (wi < 0) return;
    uint32_t ti = n.unsignedIntValue;
    if (ti >= at_store_tab_count(self.app.store, (uint32_t)wi)) return;
    const char *cur = at_store_tab_name(self.app.store, (uint32_t)wi, ti);
    __weak typeof(self) weakSelf = self;
    [ATInlineRename beginInView:_sessions
                          frame:[_sessions frameForIndex:ti]
                           text:cur ? @(cur) : @""
                         commit:^(NSString *name) {
        typeof(self) s = weakSelf;
        if (!s) return;
        NSString *trimmed = [name stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        /* Empty clears the name, so the tab falls back to its agent. */
        at_store_set_tab_name(s.app.store, (uint32_t)wi, ti, trimmed.UTF8String);
        [s reload];
    }];
}

- (void)addFolderToActive {
    int32_t i = at_store_active_index(self.app.store);
    if (i < 0) {
        [self showNewWorkspace];
        return;
    }
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.allowsMultipleSelection = YES;
    p.prompt = @"Add";
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        for (NSURL *u in p.URLs) {
            at_store_add_folder(self.app.store, (uint32_t)i, u.path.fileSystemRepresentation);
        }
        [self reload];
    }];
}

- (void)showFolders:(id)sender {
    (void)sender;
    int32_t idx = at_store_active_index(self.app.store);
    if (idx < 0) return;
    ATStore *store = self.app.store;
    uint32_t n = at_store_folder_count(store, (uint32_t)idx);
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Folders"];
    for (uint32_t f = 0; f < n; f++) {
        const char *p = at_store_folder(store, (uint32_t)idx, f);
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:p ? @(p) : @"?" action:nil keyEquivalent:@""];
        item.enabled = NO;
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *add = [[NSMenuItem alloc] initWithTitle:@"Add folder…" action:@selector(addFolderToActive) keyEquivalent:@""];
    add.target = self;
    [menu addItem:add];
    NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:@"Close workspace" action:@selector(closeActive) keyEquivalent:@""];
    close.target = self;
    [menu addItem:close];
    NSEvent *ev = NSApp.currentEvent;
    [NSMenu popUpContextMenu:menu withEvent:ev forView:_tabs];
}

- (void)closeActive {
    int32_t i = at_store_active_index(self.app.store);
    if (i < 0) return;
    const char *idc = at_store_id(self.app.store, (uint32_t)i);
    if (idc) {
        NSString *key = @(idc);
        ATTermView *tv = _terms[key];
        [tv killChild];
        [tv removeFromSuperview];
        [_terms removeObjectForKey:key];
    }
    at_store_remove_workspace(self.app.store, (uint32_t)i);
    [self reload];
}

- (BOOL)makeWorkspace:(NSString *)name folders:(NSArray<NSString *> *)folders agent:(NSString *)agent {
    /* calloc(0, …) may hand back NULL, which is not an error here: a workspace
       with no folder is allowed. */
    const char **paths = folders.count ? calloc(folders.count, sizeof(char *)) : NULL;
    if (folders.count && !paths) return NO;
    for (NSUInteger i = 0; i < folders.count; i++) {
        paths[i] = folders[i].fileSystemRepresentation;
    }
    int rc = at_store_add_workspace(self.app.store, name.UTF8String, paths, (uint32_t)folders.count, agent.UTF8String);
    free(paths);
    if (rc != 0) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Could not create workspace";
        const char *err = at_store_error();
        a.informativeText = err ? @(err) : @"unknown error";
        [a runModal];
        return NO;
    }
    return YES;
}

- (void)openHistorySession:(ATSessionInfo *)s {
    NSArray<NSString *> *folders = s.folders.count ? s.folders : (s.cwd.length ? @[s.cwd] : @[]);
    if (!s.sessionId.length || !folders.count || !s.agentId.length) return;
    ATStore *store = self.app.store;
    uint32_t n = at_store_workspace_count(store);
    for (uint32_t wi = 0; wi < n; wi++) {
        uint32_t nt = at_store_tab_count(store, wi);
        for (uint32_t ti = 0; ti < nt; ti++) {
            const char *sid = at_store_tab_session(store, wi, ti);
            if (sid && [@(sid) isEqualToString:s.sessionId]) {
                at_store_set_active(store, (int32_t)wi);
                at_store_set_active_tab(store, wi, (int32_t)ti);
                _page = ATPageWorkspace;
                [self reload];
                return;
            }
        }
    }
    int32_t wi = -1;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t nf = at_store_folder_count(store, i);
        for (uint32_t f = 0; f < nf; f++) {
            const char *fp = at_store_folder(store, i, f);
            if (fp && [@(fp) isEqualToString:folders[0]]) {
                wi = (int32_t)i;
                break;
            }
        }
        if (wi >= 0) break;
    }
    if (wi < 0) {
        if (![self makeWorkspace:folders[0].lastPathComponent folders:folders agent:s.agentId]) return;
        wi = at_store_active_index(store);
        if (wi < 0) return;
        const char *tid = at_store_tab_id(store, (uint32_t)wi, 0);
        if (tid) at_store_set_tab_session(store, tid, s.sessionId.UTF8String);
        _page = ATPageWorkspace;
        [self reload];
        return;
    }
    at_store_set_active(store, wi);
    at_store_add_tab(store, (uint32_t)wi, s.agentId.UTF8String);
    int32_t ti = at_store_active_tab(store, (uint32_t)wi);
    if (ti >= 0) {
        const char *tid = at_store_tab_id(store, (uint32_t)wi, (uint32_t)ti);
        if (tid) at_store_set_tab_session(store, tid, s.sessionId.UTF8String);
    }
    _page = ATPageWorkspace;
    [self reload];
}

- (void)reload {
    [self syncQuickstartHome];
    _tabs.homeSelected = (_page == ATPageQuickstart);
    _tabs.historySelected = (_page == ATPageHistory);
    _tabs.settingsSelected = (_page == ATPageSettings);
    _tabs.queueSelected = (_page == ATPageQueue);
    [_tabs reload];
    ATStore *store = self.app.store;
    int32_t i = at_store_active_index(store);
    _sessions.hidden = YES;
    _sessionH.constant = 0;
    if (_page == ATPageQuickstart) {
        _empty.hidden = NO;
        _history.hidden = YES;
        _settings.hidden = YES;
        _queue.hidden = YES;
        _status.hidden = NO;
        _stage.hidden = YES;
        self.window.title = @"Amil";
        NSString *home = [self homeFolder] ?: @"";
        _status.icon = nil;
        _statusBase = home.length ? [NSString stringWithFormat:@"%@  ·  pick an agent", home] : @"pick an agent";
        _status.line = _statusBase;
        _visibleTerm = nil;
        [_status setNeedsDisplay:YES];
        [self.window makeFirstResponder:_empty];
        return;
    }
    if (_page == ATPageHistory) {
        _empty.hidden = YES;
        _history.hidden = NO;
        _settings.hidden = YES;
        _queue.hidden = YES;
        _status.hidden = NO;
        _stage.hidden = YES;
        self.window.title = @"History";
        _status.icon = nil;
        _statusBase = @"past sessions";
        _status.line = _statusBase;
        _visibleTerm = nil;
        [_status setNeedsDisplay:YES];
        [_history reload];
        [self.window makeFirstResponder:_history];
        return;
    }
    if (_page == ATPageSettings) {
        _empty.hidden = YES;
        _history.hidden = YES;
        _settings.hidden = NO;
        _queue.hidden = YES;
        _status.hidden = NO;
        _stage.hidden = YES;
        self.window.title = @"Settings";
        _status.icon = nil;
        _statusBase = @"extensions";
        _status.line = _statusBase;
        _visibleTerm = nil;
        [_status setNeedsDisplay:YES];
        [_settings reload];
        [self.window makeFirstResponder:_settings];
        return;
    }
    if (_page == ATPageQueue) {
        _empty.hidden = YES;
        _history.hidden = YES;
        _settings.hidden = YES;
        _queue.hidden = NO;
        _status.hidden = NO;
        _stage.hidden = YES;
        self.window.title = @"Queue";
        _status.icon = nil;
        _statusBase = @"pipeline";
        _status.line = _statusBase;
        _visibleTerm = nil;
        [_status setNeedsDisplay:YES];
        [_queue reload];
        [self.window makeFirstResponder:_queue];
        return;
    }
    BOOL empty = i < 0;
    _history.hidden = YES;
    _settings.hidden = YES;
    _queue.hidden = YES;
    _empty.hidden = !empty;
    _status.hidden = empty;
    _stage.hidden = empty;
    if (empty) {
        _page = ATPageQuickstart;
        _tabs.homeSelected = YES;
        _tabs.historySelected = NO;
        _tabs.settingsSelected = NO;
        _tabs.queueSelected = NO;
        [_tabs reload];
        _empty.hidden = NO;
        self.window.title = @"Amil";
        _status.line = @"";
        _statusBase = @"";
        _visibleTerm = nil;
        _status.icon = nil;
        [_status setNeedsDisplay:YES];
        return;
    }
    _sessions.hidden = NO;
    _sessionH.constant = 28;
    [_sessions reload];
    const char *name = at_store_name(store, (uint32_t)i);
    const char *folder = at_store_folder(store, (uint32_t)i, 0);
    int32_t ti = at_store_active_tab(store, (uint32_t)i);
    if (ti < 0) ti = 0;
    const char *tabId = at_store_tab_id(store, (uint32_t)i, (uint32_t)ti);
    const char *agent = at_store_tab_agent(store, (uint32_t)i, (uint32_t)ti);
    if (!agent) agent = at_store_agent(store, (uint32_t)i);
    self.window.title = name ? @(name) : @"Amil";
    /* A workspace may carry no folder at all — fall back to the Quickstart
       home so the agent still has somewhere real to run. */
    NSString *cwd = folder ? @(folder) : ([self homeFolder] ?: NSHomeDirectory());
    NSString *agId = agent ? @(agent) : @"claude";
    NSImage *icon = ATAgentImage(agId);
    icon.size = NSMakeSize(12, 12);
    _status.icon = icon;
    _statusBase = [NSString stringWithFormat:@"%@  ·  %@", cwd, ATAgentDisplayName(agId)];
    _status.line = _statusBase;
    [_status setNeedsDisplay:YES];

    for (NSView *v in [_stage.subviews copy]) {
        if ([v isKindOfClass:[ATTermView class]]) v.hidden = YES;
        else [v removeFromSuperview];
    }
    if (!tabId) return;
    NSMutableArray<NSString *> *folders = [NSMutableArray new];
    uint32_t nf = at_store_folder_count(store, (uint32_t)i);
    for (uint32_t f = 0; f < nf; f++) {
        const char *fp = at_store_folder(store, (uint32_t)i, f);
        if (fp && fp[0]) [folders addObject:@(fp)];
    }
    at_store_layout_build(store, (uint32_t)i, (uint32_t)ti);
    NSView *root = [self mountNode:0
                             store:store
                                ws:(uint32_t)i
                               tab:(uint32_t)ti
                               cwd:cwd
                           folders:folders
                         workspace:name ? @(name) : @""];
    [root removeFromSuperview];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [_stage addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:_stage.topAnchor],
        [root.leadingAnchor constraintEqualToAnchor:_stage.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:_stage.trailingAnchor],
        [root.bottomAnchor constraintEqualToAnchor:_stage.bottomAnchor],
    ]];
    root.hidden = NO;
    const char *ap = at_store_active_pane(store, (uint32_t)i, (uint32_t)ti);
    ATTermView *focus = ap ? _terms[@(ap)] : nil;
    if (!focus && [root isKindOfClass:[ATTermView class]]) focus = (ATTermView *)root;
    _visibleTerm = focus;
    if (focus) [self.window makeFirstResponder:focus];
    [self refreshRam];
}

@end

#pragma mark - App

@interface ATControlWatch : NSObject
- (int)watchFd:(int)fd onRead:(void (*)(int, void *))cb user:(void *)user;
- (int)unwatchFd:(int)fd;
- (void)cancelAll;
@end

@implementation ATControlWatch {
    NSMutableDictionary<NSNumber *, dispatch_source_t> *_src;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _src = [NSMutableDictionary new];
    return self;
}

- (int)watchFd:(int)fd onRead:(void (*)(int, void *))cb user:(void *)user {
    if (fd < 0 || !cb) return -1;
    NSNumber *key = @(fd);
    if (_src[key]) return -1;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0,
                                                   dispatch_get_main_queue());
    int captured = fd;
    void (*fn)(int, void *) = cb;
    void *u = user;
    dispatch_source_set_event_handler(src, ^{ fn(captured, u); });
    dispatch_source_set_cancel_handler(src, ^{ close(captured); });
    _src[key] = src;
    dispatch_resume(src);
    return 0;
}

- (int)unwatchFd:(int)fd {
    NSNumber *key = @(fd);
    dispatch_source_t src = _src[key];
    if (!src) return -1;
    [_src removeObjectForKey:key];
    dispatch_source_cancel(src);
    return 0;
}

- (void)cancelAll {
    for (dispatch_source_t src in _src.allValues) dispatch_source_cancel(src);
    [_src removeAllObjects];
}

@end

static int ATUiReload(void *ctx) {
    ATWindowController *wc = (__bridge ATWindowController *)ctx;
    [wc reload];
    return 0;
}

static int ATUiPaneWrite(void *ctx, const char *pane, const void *bytes, size_t n, int submit) {
    ATWindowController *wc = (__bridge ATWindowController *)ctx;
    if (!pane) return -1;
    ATTermView *tv = [wc termForPane:@(pane)];
    if (!tv) return -1;
    if (n > 0 && bytes) [tv writeBytes:bytes length:n];
    if (submit) {
        const char cr = '\r';
        [tv writeBytes:&cr length:1];
    }
    return 0;
}

static int ATUiPaneActivity(void *ctx, const char *pane) {
    ATWindowController *wc = (__bridge ATWindowController *)ctx;
    if (!pane) return -1;
    ATTermView *tv = [wc termForPane:@(pane)];
    if (!tv) return -1;
    return (int)tv.activity;
}

static int ATUiFocusWorkspace(void *ctx, const char *workspace) {
    ATWindowController *wc = (__bridge ATWindowController *)ctx;
    if (!workspace) return -1;
    ATStore *store = wc.app.store;
    uint32_t n = at_store_workspace_count(store);
    for (uint32_t i = 0; i < n; i++) {
        const char *id = at_store_id(store, i);
        if (id && strcmp(id, workspace) == 0) {
            [wc selectWorkspace:@(i)];
            return 0;
        }
    }
    return -1;
}

static int ATUiFocusTab(void *ctx, const char *workspace, const char *tab) {
    ATWindowController *wc = (__bridge ATWindowController *)ctx;
    if (!tab) return -1;
    ATStore *store = wc.app.store;
    int32_t wi = -1;
    if (workspace && workspace[0]) {
        uint32_t n = at_store_workspace_count(store);
        for (uint32_t i = 0; i < n; i++) {
            const char *id = at_store_id(store, i);
            if (id && strcmp(id, workspace) == 0) {
                wi = (int32_t)i;
                break;
            }
        }
    } else {
        wi = at_store_active_index(store);
    }
    if (wi < 0) return -1;
    uint32_t tn = at_store_tab_count(store, (uint32_t)wi);
    for (uint32_t t = 0; t < tn; t++) {
        const char *id = at_store_tab_id(store, (uint32_t)wi, t);
        if (id && strcmp(id, tab) == 0) {
            at_store_set_active(store, wi);
            at_store_set_active_tab(store, (uint32_t)wi, (int32_t)t);
            [wc selectWorkspace:@(wi)];
            return 0;
        }
    }
    return -1;
}

static int ATUiTabAdd(void *ctx, const char *workspace, const char *agent, const char *session) {
    (void)session;
    ATWindowController *wc = (__bridge ATWindowController *)ctx;
    ATStore *store = wc.app.store;
    int32_t wi = -1;
    if (workspace && workspace[0]) {
        uint32_t n = at_store_workspace_count(store);
        for (uint32_t i = 0; i < n; i++) {
            const char *id = at_store_id(store, i);
            if (id && strcmp(id, workspace) == 0) {
                wi = (int32_t)i;
                break;
            }
        }
    } else {
        wi = at_store_active_index(store);
    }
    if (wi < 0) return -1;
    const char *ag = (agent && agent[0]) ? agent : "grok";
    if (at_store_add_tab(store, (uint32_t)wi, ag) != 0) return -1;
    at_store_set_active(store, wi);
    uint32_t tabs = at_store_tab_count(store, (uint32_t)wi);
    if (tabs > 0) at_store_set_active_tab(store, (uint32_t)wi, (int32_t)(tabs - 1));
    [wc reload];
    return 0;
}

static int ATIoWatch(void *ctx, int fd, void (*on_read)(int, void *), void *user) {
    return [(__bridge ATControlWatch *)ctx watchFd:fd onRead:on_read user:user];
}

static int ATIoUnwatch(void *ctx, int fd) {
    return [(__bridge ATControlWatch *)ctx unwatchFd:fd];
}

@interface ATAppDelegate ()
@property (nonatomic, strong) ATWindowController *wc;
@property (nonatomic, strong) NSTimer *flushTimer;
@property (nonatomic, strong) ATControlWatch *controlWatch;
@end

@implementation ATAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    self.store = at_store_open();
    [self buildMenu];
    self.wc = [[ATWindowController alloc] init];
    [self.wc showWindow:nil];
    self.controlWatch = [ATControlWatch new];
    ATControlIO io = {
        .ctx = (__bridge void *)self.controlWatch,
        .watch_fd = ATIoWatch,
        .unwatch_fd = ATIoUnwatch,
    };
    ATControlUI ui = {0};
    ui.ctx = (__bridge void *)self.wc;
    ui.reload = ATUiReload;
    ui.pane_write = ATUiPaneWrite;
    ui.pane_activity = ATUiPaneActivity;
    ui.tab_add = ATUiTabAdd;
    ui.focus_workspace = ATUiFocusWorkspace;
    ui.focus_tab = ATUiFocusTab;
    at_control_start(self.store, &ui, &io);
    self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                       target:self
                                                     selector:@selector(flushStore)
                                                     userInfo:nil
                                                      repeats:YES];
    self.flushTimer.tolerance = 1.0;
    /* ATERMINAL_DEBUG_RENAME=1 fires the rename on workspace 0 a few seconds
       after launch, so the bug can be reproduced without a human clicking. */
    if (NSProcessInfo.processInfo.environment[@"ATERMINAL_DEBUG_RENAME"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.wc renameWorkspaceAt:@0];
        });
    }
}

- (void)flushStore {
    if (self.store) at_store_save(self.store);
}

- (void)applicationDidBecomeActive:(NSNotification *)n {
    (void)n;
    [self.wc noteUserPresent];
}

- (void)applicationDidResignActive:(NSNotification *)n {
    (void)n;
    [self flushStore];
}

- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    [self.flushTimer invalidate];
    self.flushTimer = nil;
    at_control_stop();
    [self.controlWatch cancelAll];
    self.controlWatch = nil;
    if (self.store) {
        at_store_save(self.store);
        at_store_close(self.store);
        self.store = NULL;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s {
    (void)s;
    return at_control_background_on() ? NO : YES;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    (void)app;
    if (!flag) [self.wc.window makeKeyAndOrderFront:nil];
    return YES;
}

- (void)buildMenu {
    NSMenu *menubar = [NSMenu new];
    NSApp.mainMenu = menubar;

    NSMenuItem *appItem = [NSMenuItem new];
    [menubar addItem:appItem];
    NSMenu *app = [[NSMenu alloc] initWithTitle:@"Amil"];
    appItem.submenu = app;
    [app addItemWithTitle:@"About Amil" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [app addItem:[NSMenuItem separatorItem]];
    [app addItemWithTitle:@"Settings…" action:@selector(menuSettings:) keyEquivalent:@","];
    [app addItemWithTitle:@"Queue" action:@selector(menuQueue:) keyEquivalent:@""];
    [app addItem:[NSMenuItem separatorItem]];
    [app addItemWithTitle:@"Quit Amil" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenuItem *fileItem = [NSMenuItem new];
    [menubar addItem:fileItem];
    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    fileItem.submenu = file;
    NSMenuItem *qs = [[NSMenuItem alloc] initWithTitle:@"Quickstart…" action:@selector(menuQuickstart:) keyEquivalent:@"n"];
    [file addItem:qs];
    NSMenuItem *hist = [[NSMenuItem alloc] initWithTitle:@"History" action:@selector(menuHistory:) keyEquivalent:@"y"];
    [file addItem:hist];
    NSMenuItem *nw = [[NSMenuItem alloc] initWithTitle:@"New Workspace…" action:@selector(menuNewWorkspace:) keyEquivalent:@"O"];
    nw.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [file addItem:nw];
    NSMenuItem *af = [[NSMenuItem alloc] initWithTitle:@"Add Folder…" action:@selector(menuAddFolder:) keyEquivalent:@"o"];
    [file addItem:af];
    [file addItem:[NSMenuItem separatorItem]];
    NSMenuItem *nt = [[NSMenuItem alloc] initWithTitle:@"New Agent Tab" action:@selector(menuNewTab:) keyEquivalent:@"t"];
    [file addItem:nt];
    NSMenuItem *sr = [[NSMenuItem alloc] initWithTitle:@"Split Right" action:@selector(menuSplitRight:) keyEquivalent:@"d"];
    [file addItem:sr];
    NSMenuItem *sd = [[NSMenuItem alloc] initWithTitle:@"Split Down" action:@selector(menuSplitDown:) keyEquivalent:@"d"];
    sd.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [file addItem:sd];
    NSMenuItem *ct = [[NSMenuItem alloc] initWithTitle:@"Close Pane" action:@selector(menuCloseTab:) keyEquivalent:@"w"];
    [file addItem:ct];
    [file addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"W"];

    NSMenuItem *editItem = [NSMenuItem new];
    [menubar addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    editItem.submenu = edit;
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    NSMenuItem *goItem = [NSMenuItem new];
    [menubar addItem:goItem];
    NSMenu *go = [[NSMenu alloc] initWithTitle:@"Go"];
    goItem.submenu = go;
    NSMenuItem *nws = [[NSMenuItem alloc] initWithTitle:@"Next Workspace" action:@selector(menuNextWorkspace:) keyEquivalent:@"\t"];
    nws.keyEquivalentModifierMask = NSEventModifierFlagControl;
    [go addItem:nws];
    NSMenuItem *pws = [[NSMenuItem alloc] initWithTitle:@"Previous Workspace" action:@selector(menuPrevWorkspace:) keyEquivalent:@"\t"];
    pws.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagShift;
    [go addItem:pws];
    NSMenuItem *nst = [[NSMenuItem alloc] initWithTitle:@"Next Agent Tab" action:@selector(menuNextSession:) keyEquivalent:@"]"];
    nst.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [go addItem:nst];
    NSMenuItem *pst = [[NSMenuItem alloc] initWithTitle:@"Previous Agent Tab" action:@selector(menuPrevSession:) keyEquivalent:@"["];
    pst.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [go addItem:pst];
    [go addItem:[NSMenuItem separatorItem]];
    NSString *left = [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
    NSString *right = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
    NSString *up = [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey];
    NSString *down = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];
    NSEventModifierFlags paneMods = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    NSMenuItem *pl = [[NSMenuItem alloc] initWithTitle:@"Focus Pane Left" action:@selector(menuPaneLeft:) keyEquivalent:left];
    pl.keyEquivalentModifierMask = paneMods;
    [go addItem:pl];
    NSMenuItem *pr = [[NSMenuItem alloc] initWithTitle:@"Focus Pane Right" action:@selector(menuPaneRight:) keyEquivalent:right];
    pr.keyEquivalentModifierMask = paneMods;
    [go addItem:pr];
    NSMenuItem *pu = [[NSMenuItem alloc] initWithTitle:@"Focus Pane Up" action:@selector(menuPaneUp:) keyEquivalent:up];
    pu.keyEquivalentModifierMask = paneMods;
    [go addItem:pu];
    NSMenuItem *pd = [[NSMenuItem alloc] initWithTitle:@"Focus Pane Down" action:@selector(menuPaneDown:) keyEquivalent:down];
    pd.keyEquivalentModifierMask = paneMods;
    [go addItem:pd];
    NSMenuItem *cyc = [[NSMenuItem alloc] initWithTitle:@"Cycle Keyboard Focus"
                                                 action:@selector(menuCycleFocus:)
                                          keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSF6FunctionKey]];
    cyc.keyEquivalentModifierMask = 0;
    [go addItem:cyc];
    [go addItem:[NSMenuItem separatorItem]];
    for (int k = 1; k <= 9; k++) {
        NSString *title = [NSString stringWithFormat:@"Workspace %d", k];
        NSString *ke = [NSString stringWithFormat:@"%d", k];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:@selector(menuJumpWorkspace:) keyEquivalent:ke];
        it.tag = k - 1;
        [go addItem:it];
    }

    NSMenuItem *winItem = [NSMenuItem new];
    [menubar addItem:winItem];
    NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
    winItem.submenu = win;
    [win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    NSApp.windowsMenu = win;
}

- (void)menuQuickstart:(id)sender {
    (void)sender;
    [self.wc quickstart];
}

- (void)menuHistory:(id)sender {
    (void)sender;
    [self.wc showHistory];
}

- (void)menuSettings:(id)sender {
    (void)sender;
    [self.wc showSettings];
}

- (void)menuQueue:(id)sender {
    (void)sender;
    [self.wc showQueue];
}

- (void)menuNewWorkspace:(id)sender {
    (void)sender;
    [self.wc showNewWorkspace];
}

- (void)menuAddFolder:(id)sender {
    (void)sender;
    [self.wc addFolderToActive];
}

- (void)menuNewTab:(id)sender {
    (void)sender;
    [self.wc addSession:nil];
}

- (void)menuSplitRight:(id)sender {
    (void)sender;
    [self.wc splitRight];
}

- (void)menuSplitDown:(id)sender {
    (void)sender;
    [self.wc splitDown];
}

- (void)menuCloseTab:(id)sender {
    (void)sender;
    [self.wc closeSession];
}

- (void)menuNextWorkspace:(id)sender {
    (void)sender;
    [self.wc cycleWorkspace:YES];
}

- (void)menuPrevWorkspace:(id)sender {
    (void)sender;
    [self.wc cycleWorkspace:NO];
}

- (void)menuNextSession:(id)sender {
    (void)sender;
    [self.wc cycleSession:YES];
}

- (void)menuPrevSession:(id)sender {
    (void)sender;
    [self.wc cycleSession:NO];
}

- (void)menuPaneLeft:(id)sender {
    (void)sender;
    [self.wc focusPaneDir:0];
}

- (void)menuPaneRight:(id)sender {
    (void)sender;
    [self.wc focusPaneDir:1];
}

- (void)menuPaneUp:(id)sender {
    (void)sender;
    [self.wc focusPaneDir:2];
}

- (void)menuPaneDown:(id)sender {
    (void)sender;
    [self.wc focusPaneDir:3];
}

- (void)menuJumpWorkspace:(NSMenuItem *)sender {
    [self.wc jumpWorkspace:sender.tag];
}

- (void)menuCycleFocus:(id)sender {
    (void)sender;
    [self.wc cycleChrome:YES];
}

@end

void at_macos_main(void) {
    @autoreleasepool {
        if (!getenv("HOME")) {
            setenv("HOME", NSHomeDirectory().fileSystemRepresentation, 1);
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        ATAppDelegate *del = [ATAppDelegate new];
        NSApp.delegate = del;
        [NSApp run];
    }
}
