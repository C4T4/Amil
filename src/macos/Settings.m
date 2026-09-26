#import "Settings.h"
#import "Keys.h"
#import "Theme.h"
#include "at_control.h"

static const CGFloat kRowH = 52;
static const CGFloat kPad = 36;

@implementation ATSettingsView {
    NSMutableArray<NSValue *> *_hits;
    NSMutableArray<NSNumber *> *_tags; /* -1 unix, -2 folder, else ext index */
    NSInteger _sel;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _hits = [NSMutableArray new];
    _tags = [NSMutableArray new];
    _sel = 0;
    self.wantsLayer = YES;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

- (void)reload {
    [self setNeedsDisplay:YES];
}

- (NSFont *)titleFont {
    return [NSFont fontWithName:@"Avenir Next" size:14] ?: [NSFont systemFontOfSize:14];
}

- (NSFont *)metaFont {
    return [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
}

- (void)drawSwitch:(BOOL)on inRect:(NSRect)r {
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:r
                                                         xRadius:r.size.height / 2.0
                                                         yRadius:r.size.height / 2.0];
    [(on ? ATColorAccent() : [ATColorMuted() colorWithAlphaComponent:0.35]) setFill];
    [track fill];
    CGFloat d = r.size.height - 6;
    CGFloat x = on ? NSMaxX(r) - 3 - d : r.origin.x + 3;
    NSRect knob = NSMakeRect(x, r.origin.y + 3, d, d);
    [[ATColorBg() colorWithAlphaComponent:0.95] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
}

- (CGFloat)drawRowAtY:(CGFloat)y
                width:(CGFloat)w
                title:(NSString *)title
                 meta:(NSString *)meta
                   on:(BOOL)on
                  tag:(NSInteger)tag {
    NSRect row = NSMakeRect(kPad, y, w - kPad * 2, kRowH);
    if (_sel == (NSInteger)_hits.count) {
        [[ATColorSurface() colorWithAlphaComponent:0.9] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(row, -8, 4) xRadius:8 yRadius:8] fill];
    }
    NSDictionary *tattr = @{
        NSFontAttributeName: self.titleFont,
        NSForegroundColorAttributeName: ATColorText(),
    };
    NSDictionary *mattr = @{
        NSFontAttributeName: self.metaFont,
        NSForegroundColorAttributeName: ATColorMuted(),
    };
    [title drawAtPoint:NSMakePoint(row.origin.x, y + 10) withAttributes:tattr];
    [meta drawAtPoint:NSMakePoint(row.origin.x, y + 30) withAttributes:mattr];
    NSRect sw = NSMakeRect(NSMaxX(row) - 40, y + (kRowH - 22) / 2.0, 40, 22);
    [self drawSwitch:on inRect:sw];
    [_hits addObject:[NSValue valueWithRect:row]];
    [_tags addObject:@(tag)];
    return y + kRowH;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATColorBg() setFill];
    NSRectFill(self.bounds);
    [_hits removeAllObjects];
    [_tags removeAllObjects];
    CGFloat y = 28;
    CGFloat w = NSWidth(self.bounds);
    NSDictionary *head = @{
        NSFontAttributeName: [NSFont fontWithName:@"Avenir Next" size:11] ?: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: ATColorMuted(),
        NSKernAttributeName: @1.4,
    };
    [@"SETTINGS" drawAtPoint:NSMakePoint(kPad, y) withAttributes:head];
    y += 28;

    if (at_control_forced_off()) {
        NSDictionary *warn = @{
            NSFontAttributeName: self.metaFont,
            NSForegroundColorAttributeName: ATColorAccent(),
        };
        [@"ATERMINAL_CONTROL=0 — socket and extensions are off for this process."
            drawAtPoint:NSMakePoint(kPad, y)
         withAttributes:warn];
        y += 28;
    }

    [@"AGENTS" drawAtPoint:NSMakePoint(kPad, y) withAttributes:head];
    y += 22;
    y = [self drawRowAtY:y width:w title:@"Yolo"
                    meta:@"Skip permission prompts on new Grok and Claude tabs"
                      on:at_control_yolo() != 0
                     tag:-3];
    y += 16;

    [@"EXTENSIONS" drawAtPoint:NSMakePoint(kPad, y) withAttributes:head];
    y += 22;

    uint32_t n = at_control_ext_count();
    if (n == 0) {
        NSDictionary *empty = @{
            NSFontAttributeName: self.metaFont,
            NSForegroundColorAttributeName: ATColorMuted(),
        };
        [@"No extensions on disk. zig build plugins, then copy libat-*.dylib here."
            drawAtPoint:NSMakePoint(kPad, y)
         withAttributes:empty];
        y += 24;
    }
    for (uint32_t i = 0; i < n; i++) {
        const char *titlec = at_control_ext_title(i);
        const char *idc = at_control_ext_id(i);
        NSString *title = titlec ? @(titlec) : @"extension";
        NSString *ident = idc ? @(idc) : @"";
        NSString *base;
        if ([ident isEqualToString:@"core"])
            base = @"bus, socket, and other extensions";
        else if ([ident isEqualToString:@"git"])
            base = @"branch and worktree on session tabs";
        else if ([ident isEqualToString:@"background"])
            base = @"keep agents running when the window is closed";
        else if ([ident isEqualToString:@"pipeline"])
            base = @"queue · you define the steps";
        else if ([ident isEqualToString:@"mcp"])
            base = @"127.0.0.1:8765 · master tools for workspaces and tabs";
        else if (at_control_ext_loaded(i))
            base = [NSString stringWithFormat:@"%@ · loaded", ident];
        else if (at_control_ext_enabled(i) && !at_control_ext_present(i))
            base = [NSString stringWithFormat:@"%@ · missing dylib", ident];
        else if (at_control_ext_enabled(i))
            base = [NSString stringWithFormat:@"%@ · failed to load", ident];
        else if (at_control_ext_present(i))
            base = [NSString stringWithFormat:@"%@ · installed", ident];
        else
            base = [NSString stringWithFormat:@"%@ · not installed", ident];
        const char *req = at_control_ext_requires(i);
        NSString *meta;
        if (req && req[0]) {
            NSString *need = @(req);
            if (!at_control_ext_deps_ok(i))
                meta = [NSString stringWithFormat:@"needs %@ · %@", need, base];
            else
                meta = [NSString stringWithFormat:@"requires %@ · %@", need, base];
        } else {
            meta = base;
        }
        y = [self drawRowAtY:y width:w title:title meta:meta
                          on:at_control_ext_enabled(i) != 0
                         tag:(NSInteger)i];
    }

    y += 16;
    if (at_control_plugin_dir()) {
        NSDictionary *link = @{
            NSFontAttributeName: self.metaFont,
            NSForegroundColorAttributeName: ATColorAccent(),
        };
        NSString *label = @"Show plugins folder";
        NSSize sz = [label sizeWithAttributes:link];
        NSRect r = NSMakeRect(kPad, y, sz.width + 8, 20);
        [label drawAtPoint:NSMakePoint(r.origin.x, y) withAttributes:link];
        [_hits addObject:[NSValue valueWithRect:r]];
        [_tags addObject:@(-2)];
    }
}

- (void)toggleTag:(NSInteger)tag {
    if (at_control_forced_off() && tag != -2) return;
    if (tag == -3) {
        at_control_set_yolo(at_control_yolo() ? 0 : 1);
        [self setNeedsDisplay:YES];
        return;
    }
    if (tag == -2) {
        const char *dir = at_control_plugin_dir();
        if (!dir) return;
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:@(dir) isDirectory:YES]];
        return;
    }
    int on = at_control_ext_enabled((uint32_t)tag);
    at_control_set_ext(at_control_ext_id((uint32_t)tag), on ? 0 : 1);
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    for (NSUInteger i = 0; i < _hits.count; i++) {
        if (!NSPointInRect(p, _hits[i].rectValue)) continue;
        _sel = (NSInteger)i;
        [self toggleTag:_tags[i].integerValue];
        return;
    }
}

- (void)keyDown:(NSEvent *)event {
    NSWindowController *wc = self.window.windowController;
    if ([wc handleNavEvent:event]) return;
    unsigned short kc = event.keyCode;
    if (kc == 125 || kc == 126) {
        if (!_hits.count) return;
        if (kc == 125) _sel++;
        else _sel--;
        if (_sel < 0) _sel = 0;
        if (_sel >= (NSInteger)_hits.count) _sel = (NSInteger)_hits.count - 1;
        [self setNeedsDisplay:YES];
        return;
    }
    if (kc == 36 || kc == 49) {
        if (_sel >= 0 && _sel < (NSInteger)_tags.count) [self toggleTag:_tags[_sel].integerValue];
        return;
    }
    [super keyDown:event];
}

@end
