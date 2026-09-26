#import "History.h"
#import "Agents.h"
#import "App.h"
#import "Keys.h"
#import "Theme.h"
#include <string.h>
#include <stdlib.h>

static NSColor *ATHBg(void) { return ATColorBg(); }
static NSColor *ATHRow(void) { return ATColorSurface(); }
static NSColor *ATHText(void) { return ATColorText(); }
static NSColor *ATHMuted(void) { return ATColorMuted(); }
static NSColor *ATHAccent(void) { return ATColorAccent(); }
static NSColor *ATHHair(void) { return ATColorHair(); }

static const CGFloat kRowH = 56;
static const NSUInteger kPerAgent = 80;

@implementation ATSessionInfo
@end

static BOOL ATHIsUUID(NSString *s) {
    if (s.length != 36) return NO;
    const char *c = s.UTF8String;
    if (!c) return NO;
    static const int dash[] = {8, 13, 18, 23};
    int di = 0;
    for (int i = 0; i < 36; i++) {
        if (di < 4 && i == dash[di]) {
            if (c[i] != '-') return NO;
            di++;
            continue;
        }
        char ch = c[i];
        BOOL hex = (ch >= '0' && ch <= '9') ||
                   (ch >= 'a' && ch <= 'f') ||
                   (ch >= 'A' && ch <= 'F');
        if (!hex) return NO;
    }
    return YES;
}

static NSString *ATHTilde(NSString *path) {
    NSString *home = NSHomeDirectory();
    if (home.length && [path hasPrefix:home]) {
        return [@"~" stringByAppendingString:[path substringFromIndex:home.length]];
    }
    return path ?: @"";
}

static NSString *ATHStr(id v) {
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

static NSString *ATHCleanTitle(NSString *s) {
    s = ATHStr(s);
    if (!s) return nil;
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length || [s hasPrefix:@"<"]) return nil;
    NSRange nl = [s rangeOfString:@"\n"];
    if (nl.location != NSNotFound) s = [s substringToIndex:nl.location];
    if (s.length > 88) s = [[s substringToIndex:85] stringByAppendingString:@"…"];
    return s.length ? s : nil;
}

static NSDate *ATHParseISO(id raw) {
    NSString *s = ATHStr(raw);
    if (!s || s.length < 19) return nil;
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'";
    NSDate *d = [fmt dateFromString:s];
    if (d) return d;
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    d = [fmt dateFromString:s];
    if (d) return d;
    if (s.length > 19) {
        fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
        d = [fmt dateFromString:s];
    }
    return d;
}

static NSString *ATHAgo(NSDate *date) {
    if (!date) return @"";
    NSTimeInterval dt = -[date timeIntervalSinceNow];
    if (dt < 60) return @"just now";
    if (dt < 3600) {
        int m = (int)(dt / 60);
        if (m < 1) m = 1;
        return [NSString stringWithFormat:@"%dm ago", m];
    }
    if (dt < 86400) return [NSString stringWithFormat:@"%dh ago", (int)(dt / 3600)];
    if (dt < 86400 * 7) return [NSString stringWithFormat:@"%dd ago", (int)(dt / 86400)];
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateStyle = NSDateFormatterMediumStyle;
    fmt.timeStyle = NSDateFormatterNoStyle;
    return [fmt stringFromDate:date] ?: @"";
}

static ATSessionInfo *ATHMake(NSString *agent, NSString *sid, NSArray<NSString *> *folders, NSString *title, NSDate *updated) {
    if (!sid.length) return nil;
    ATSessionInfo *s = [ATSessionInfo new];
    s.agentId = agent.length ? agent : @"claude";
    s.sessionId = sid;
    s.folders = folders.count ? folders : @[];
    s.cwd = folders.count ? folders[0] : @"";
    s.title = ATHCleanTitle(title) ?: @"untitled";
    s.updated = updated ?: [NSDate distantPast];
    return s;
}

static NSString *ATHFolderLine(ATSessionInfo *s) {
    NSArray<NSString *> *folders = s.folders.count ? s.folders : (s.cwd.length ? @[s.cwd] : @[]);
    if (!folders.count) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *f in folders) {
        NSString *t = ATHTilde(f);
        if (t.length) [parts addObject:t];
    }
    return [parts componentsJoinedByString:@"  ·  "];
}

static NSString *ATHClaudeUserText(id content) {
    if ([content isKindOfClass:[NSString class]]) return content;
    if (![content isKindOfClass:[NSArray class]]) return nil;
    for (id b in content) {
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        if ([b[@"type"] isEqualToString:@"text"] && [b[@"text"] isKindOfClass:[NSString class]]) {
            return b[@"text"];
        }
    }
    return nil;
}

static NSString *ATHClaudeTitle(NSString *cwd, NSString *sid) {
    if (!cwd.length || !sid.length) return nil;
    NSMutableString *slug = [NSMutableString stringWithCapacity:cwd.length];
    for (NSUInteger i = 0; i < cwd.length; i++) {
        unichar ch = [cwd characterAtIndex:i];
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
            [slug appendFormat:@"%C", ch];
        } else {
            [slug appendString:@"-"];
        }
    }
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@".claude/projects"]
                      stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.jsonl", slug, sid]];
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) return nil;
    NSData *data = [h readDataOfLength:24 * 1024];
    [h closeFile];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *title = nil;
    NSInteger n = 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (n++ > 80) break;
        if (!line.length) continue;
        NSData *ld = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!ld) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:ld options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSString *type = ATHStr(obj[@"type"]);
        if ([type isEqualToString:@"summary"] || [type isEqualToString:@"custom-title"] || [type isEqualToString:@"ai-title"]) {
            title = ATHCleanTitle(ATHStr(obj[@"summary"]) ?: ATHStr(obj[@"title"]));
        }
        if (!title && [type isEqualToString:@"user"]) {
            id msg = obj[@"message"];
            title = ATHCleanTitle(ATHClaudeUserText([msg isKindOfClass:[NSDictionary class]] ? msg[@"content"] : nil));
        }
        if (title) break;
    }
    return title;
}

static NSString *ATHGrokTitle(NSString *cwd, NSString *sid) {
    if (!cwd.length || !sid.length) return nil;
    NSString *enc = [cwd stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
    NSString *path = [[[[NSHomeDirectory() stringByAppendingPathComponent:@".grok/sessions"]
                        stringByAppendingPathComponent:enc]
                       stringByAppendingPathComponent:sid]
                      stringByAppendingPathComponent:@"summary.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    return ATHCleanTitle(ATHStr(json[@"generated_title"]) ?: ATHStr(json[@"session_summary"]) ?: ATHStr(json[@"last_turn_summary"]));
}

static NSArray<ATSessionInfo *> *ATHCollect(void) {
    ATStore *store = ((ATAppDelegate *)NSApp.delegate).store;
    if (!store) return @[];
    uint32_t n = at_store_history_count(store);
    NSMutableArray<ATSessionInfo *> *all = [NSMutableArray new];
    for (uint32_t i = 0; i < n; i++) {
        const char *sidc = at_store_history_session(store, i);
        const char *agentc = at_store_history_agent(store, i);
        const char *cwdc = at_store_history_cwd(store, i);
        const char *titlec = at_store_history_title(store, i);
        int64_t updated = at_store_history_updated(store, i);
        NSString *sid = sidc ? @(sidc) : nil;
        NSString *agent = agentc ? @(agentc) : @"claude";
        NSString *cwd = cwdc ? @(cwdc) : @"";
        NSString *title = titlec ? @(titlec) : nil;
        NSMutableArray<NSString *> *folders = [NSMutableArray new];
        uint32_t nf = at_store_history_folder_count(store, i);
        for (uint32_t f = 0; f < nf; f++) {
            const char *fp = at_store_history_folder(store, i, f);
            if (fp && fp[0]) [folders addObject:@(fp)];
        }
        if (!folders.count && cwd.length) [folders addObject:cwd];
        if (!title.length) {
            NSString *main = folders.count ? folders[0] : cwd;
            if ([agent isEqualToString:@"claude"]) title = ATHClaudeTitle(main, sid);
            else if ([agent isEqualToString:@"grok"]) title = ATHGrokTitle(main, sid);
        }
        NSDate *date = updated > 0 ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)updated] : nil;
        ATSessionInfo *s = ATHMake(agent, sid, folders, title, date);
        if (s) [all addObject:s];
    }
    return all;
}

#pragma mark - List document

@interface ATHListView : NSView
@property (nonatomic, copy) NSArray<ATSessionInfo *> *items;
@property (nonatomic, copy) NSSet<NSString *> *openIds;
@property (nonatomic, assign) NSInteger hover;
@property (nonatomic, assign) NSInteger selected;
@property (nonatomic, copy) void (^onOpen)(ATSessionInfo *session);
@end

@implementation ATHListView
- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _hover = -1;
    _selected = 0;
    NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                      options:(NSTrackingMouseEnteredAndExited |
                                                               NSTrackingMouseMoved |
                                                               NSTrackingActiveInKeyWindow |
                                                               NSTrackingInVisibleRect)
                                                        owner:self
                                                     userInfo:nil];
    [self addTrackingArea:ta];
    return self;
}

- (void)setItems:(NSArray<ATSessionInfo *> *)items {
    NSInteger keep = _selected;
    _items = [items copy];
    _hover = -1;
    if (keep >= (NSInteger)items.count) keep = (NSInteger)items.count - 1;
    if (keep < 0) keep = 0;
    _selected = keep;
    CGFloat w = self.superview ? NSWidth(self.superview.bounds) : NSWidth(self.frame);
    CGFloat minH = self.superview ? NSHeight(self.superview.bounds) : 0;
    self.frame = NSMakeRect(0, 0, w, MAX(minH, items.count * kRowH));
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATHBg() setFill];
    NSRectFill(self.bounds);
    NSFont *titleFont = [NSFont fontWithName:@"Avenir Next" size:13] ?: [NSFont systemFontOfSize:13];
    NSFont *metaFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSMutableParagraphStyle *trunc = [NSMutableParagraphStyle new];
    trunc.lineBreakMode = NSLineBreakByTruncatingTail;
    CGFloat w = NSWidth(self.bounds);
    NSInteger n = (NSInteger)self.items.count;
    NSInteger start = MAX(0, (NSInteger)floor(dirty.origin.y / kRowH) - 1);
    NSInteger end = MIN(n, (NSInteger)ceil(NSMaxY(dirty) / kRowH) + 1);
    for (NSInteger i = start; i < end; i++) {
        ATSessionInfo *s = self.items[(NSUInteger)i];
        NSRect row = NSMakeRect(0, i * kRowH, w, kRowH);
        if (i == self.selected || i == self.hover) {
            [ATHRow() setFill];
            NSRectFill(row);
        }
        if (i == self.selected) {
            [ATHAccent() setFill];
            NSRectFill(NSMakeRect(0, row.origin.y + 8, 3, kRowH - 16));
        }
        NSImage *icon = ATAgentImage(s.agentId);
        icon.size = NSMakeSize(16, 16);
        [icon drawInRect:NSMakeRect(20, row.origin.y + 12, 16, 16)
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0
          respectFlipped:YES
                   hints:nil];
        BOOL open = [self.openIds containsObject:s.sessionId];
        NSDictionary *titleAttrs = @{
            NSFontAttributeName: titleFont,
            NSForegroundColorAttributeName: ATHText(),
            NSParagraphStyleAttributeName: trunc,
        };
        NSString *title = s.title ?: @"untitled";
        [title drawInRect:NSMakeRect(46, row.origin.y + 10, w - 70, 18) withAttributes:titleAttrs];
        NSString *dirs = ATHFolderLine(s);
        NSString *meta = dirs.length
            ? [NSString stringWithFormat:@"%@  ·  %@  ·  %@", dirs, ATHAgo(s.updated), ATAgentDisplayName(s.agentId)]
            : [NSString stringWithFormat:@"%@  ·  %@", ATHAgo(s.updated), ATAgentDisplayName(s.agentId)];
        NSDictionary *metaAttrs = @{
            NSFontAttributeName: metaFont,
            NSForegroundColorAttributeName: ATHMuted(),
            NSParagraphStyleAttributeName: trunc,
        };
        [meta drawInRect:NSMakeRect(46, row.origin.y + 30, w - 70, 16) withAttributes:metaAttrs];
        if (open) {
            [ATHAccent() setFill];
            NSRectFill(NSMakeRect(8, row.origin.y + 24, 3, 8));
        }
        [ATHHair() setFill];
        NSRectFill(NSMakeRect(46, NSMaxY(row) - 1, w - 66, 1));
    }
}

- (NSInteger)indexAt:(NSPoint)p {
    if (p.y < 0) return -1;
    NSInteger i = (NSInteger)floor(p.y / kRowH);
    if (i < 0 || i >= (NSInteger)self.items.count) return -1;
    return i;
}

- (void)mouseMoved:(NSEvent *)event {
    NSInteger i = [self indexAt:[self convertPoint:event.locationInWindow fromView:nil]];
    if (i == self.hover) return;
    self.hover = i;
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    self.hover = -1;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    NSInteger i = [self indexAt:[self convertPoint:event.locationInWindow fromView:nil]];
    if (i < 0 || !self.onOpen) return;
    self.selected = i;
    [self setNeedsDisplay:YES];
    self.onOpen(self.items[(NSUInteger)i]);
}

- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.items.count) {
        [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
    }
}
@end

#pragma mark - History page

@implementation ATHistoryView {
    NSTextField *_title;
    NSTextField *_sub;
    NSMutableArray<NSButton *> *_filters;
    NSString *_filter;
    NSScrollView *_scroll;
    ATHListView *_list;
    NSArray<ATSessionInfo *> *_all;
    NSTextField *_empty;
    NSInteger _stop;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _filter = @"all";
    NSFont *titleFont = [NSFont fontWithName:@"Avenir Next" size:22] ?:
        [NSFont systemFontOfSize:22 weight:NSFontWeightMedium];
    NSFont *subFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _title = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _title.stringValue = @"History";
    _title.font = titleFont;
    _title.textColor = ATHText();
    _title.bezeled = NO;
    _title.editable = NO;
    _title.selectable = NO;
    _title.drawsBackground = NO;
    _sub = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _sub.stringValue = @"sessions from this terminal — click to open";
    _sub.font = subFont;
    _sub.textColor = ATHMuted();
    _sub.bezeled = NO;
    _sub.editable = NO;
    _sub.selectable = NO;
    _sub.drawsBackground = NO;
    [self addSubview:_title];
    [self addSubview:_sub];
    _filters = [NSMutableArray new];
    NSArray<NSString *> *ids = @[@"all", @"claude", @"grok", @"chatgpt", @"gemini"];
    NSArray<NSString *> *labels = @[@"All", @"Claude", @"Grok", @"ChatGPT", @"Gemini"];
    for (NSUInteger i = 0; i < ids.count; i++) {
        NSButton *b = [NSButton buttonWithTitle:labels[i] target:self action:@selector(pickFilter:)];
        b.bezelStyle = NSBezelStyleInline;
        b.bordered = NO;
        b.font = [NSFont fontWithName:@"Avenir Next" size:12] ?: [NSFont systemFontOfSize:12];
        b.identifier = ids[i];
        b.wantsLayer = YES;
        b.layer.cornerRadius = 8;
        [self addSubview:b];
        [_filters addObject:b];
    }
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.hasHorizontalScroller = NO;
    _scroll.borderType = NSNoBorder;
    _scroll.autohidesScrollers = YES;
    _list = [[ATHListView alloc] initWithFrame:NSZeroRect];
    __weak ATHistoryView *weak = self;
    _list.onOpen = ^(ATSessionInfo *s) {
        if (weak.onOpen) weak.onOpen(s);
    };
    _scroll.documentView = _list;
    [self addSubview:_scroll];
    _empty = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _empty.stringValue = @"no sessions yet";
    _empty.font = subFont;
    _empty.textColor = ATHMuted();
    _empty.bezeled = NO;
    _empty.editable = NO;
    _empty.selectable = NO;
    _empty.drawsBackground = NO;
    _empty.alignment = NSTextAlignmentCenter;
    _empty.hidden = YES;
    [self addSubview:_empty];
    [self restyleFilters];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

- (void)moveSel:(NSInteger)delta {
    if (!_list.items.count) return;
    NSInteger n = (NSInteger)_list.items.count;
    NSInteger i = _list.selected + delta;
    if (i < 0) i = 0;
    if (i >= n) i = n - 1;
    _list.selected = i;
    [_list setNeedsDisplay:YES];
    NSRect row = NSMakeRect(0, i * kRowH, NSWidth(_list.bounds), kRowH);
    [_list scrollRectToVisible:row];
}

- (void)moveFilter:(NSInteger)delta {
    if (!_filters.count) return;
    NSInteger cur = 0;
    for (NSUInteger i = 0; i < _filters.count; i++) {
        if ([_filters[i].identifier isEqualToString:_filter]) cur = (NSInteger)i;
    }
    NSInteger n = (NSInteger)_filters.count;
    NSInteger next = (cur + delta) % n;
    if (next < 0) next += n;
    [self pickFilter:_filters[(NSUInteger)next]];
}

- (void)openSel {
    if (_list.selected < 0 || _list.selected >= (NSInteger)_list.items.count) return;
    if (self.onOpen) self.onOpen(_list.items[(NSUInteger)_list.selected]);
}

- (void)keyDown:(NSEvent *)event {
    unsigned short kc = event.keyCode;
    NSInteger nStops = (NSInteger)_filters.count + 1;
    if (kc == 48 && !(event.modifierFlags & NSEventModifierFlagControl) &&
        !(event.modifierFlags & NSEventModifierFlagCommand)) {
        NSInteger dir = (event.modifierFlags & NSEventModifierFlagShift) ? -1 : 1;
        _stop = (_stop + dir) % nStops;
        if (_stop < 0) _stop += nStops;
        if (_stop < (NSInteger)_filters.count) [self pickFilter:_filters[(NSUInteger)_stop]];
        [self setNeedsDisplay:YES];
        [_list setNeedsDisplay:YES];
        return;
    }
    NSWindowController *wc = self.window.windowController;
    if ([wc handleNavEvent:event]) return;
    if (kc == 125) { _stop = (NSInteger)_filters.count; [self moveSel:1]; return; }
    if (kc == 126) { _stop = (NSInteger)_filters.count; [self moveSel:-1]; return; }
    if (kc == 123) { [self moveFilter:-1]; return; }
    if (kc == 124) { [self moveFilter:1]; return; }
    if (kc == 36) { [self openSel]; return; }
    if (kc == 53) {
        [wc quickstart];
        return;
    }
    [super keyDown:event];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATHBg() setFill];
    NSRectFill(self.bounds);
}

- (void)layout {
    [super layout];
    CGFloat w = NSWidth(self.bounds);
    CGFloat y = 28;
    _title.frame = NSMakeRect(24, y, w - 48, 28);
    y += 30;
    _sub.frame = NSMakeRect(24, y, w - 48, 16);
    y += 28;
    CGFloat x = 24;
    for (NSButton *b in _filters) {
        NSSize sz = [b.title sizeWithAttributes:@{NSFontAttributeName: b.font}];
        CGFloat bw = MAX(52, sz.width + 20);
        b.frame = NSMakeRect(x, y, bw, 26);
        x += bw + 8;
    }
    y += 38;
    CGFloat listTop = y;
    _scroll.frame = NSMakeRect(0, listTop, w, NSHeight(self.bounds) - listTop);
    _list.frame = NSMakeRect(0, 0, w, MAX(NSHeight(_scroll.bounds), _list.items.count * kRowH));
    _empty.frame = NSMakeRect(24, listTop + 40, w - 48, 20);
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    self.needsLayout = YES;
    [self layoutSubtreeIfNeeded];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self layout];
}

- (void)restyleFilters {
    for (NSButton *b in _filters) {
        BOOL on = [b.identifier isEqualToString:_filter];
        b.layer.backgroundColor = on ? ATHRow().CGColor : [NSColor clearColor].CGColor;
        b.layer.borderWidth = on ? 1.5 : 0;
        b.layer.borderColor = on ? ATHAccent().CGColor : [NSColor clearColor].CGColor;
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc]
            initWithString:b.title ?: @""
            attributes:@{
                NSFontAttributeName: b.font,
                NSForegroundColorAttributeName: on ? ATHText() : ATHMuted(),
            }];
        b.attributedTitle = t;
    }
}

- (void)pickFilter:(NSButton *)sender {
    _filter = sender.identifier ?: @"all";
    [self restyleFilters];
    [self applyFilter];
}

- (NSSet<NSString *> *)openSessionIds {
    NSMutableSet<NSString *> *ids = [NSMutableSet new];
    ATStore *store = ((ATAppDelegate *)NSApp.delegate).store;
    if (!store) return ids;
    uint32_t nw = at_store_workspace_count(store);
    for (uint32_t wi = 0; wi < nw; wi++) {
        uint32_t nt = at_store_tab_count(store, wi);
        for (uint32_t ti = 0; ti < nt; ti++) {
            const char *s = at_store_tab_session(store, wi, ti);
            if (s && s[0]) [ids addObject:@(s)];
        }
    }
    return ids;
}

- (void)applyFilter {
    NSArray<ATSessionInfo *> *src = _all ?: @[];
    NSArray<ATSessionInfo *> *shown = src;
    if (![_filter isEqualToString:@"all"]) {
        NSMutableArray<ATSessionInfo *> *f = [NSMutableArray new];
        for (ATSessionInfo *s in src) {
            if ([s.agentId isEqualToString:_filter]) [f addObject:s];
        }
        shown = f;
    }
    _list.openIds = [self openSessionIds];
    _list.items = shown;
    _empty.hidden = shown.count > 0;
    _empty.stringValue = src.count ? @"no sessions for this agent" : @"no sessions from this terminal yet";
    NSUInteger n = src.count;
    _sub.stringValue = n ? [NSString stringWithFormat:@"%lu session%@ from this terminal — click to open",
                            (unsigned long)n, n == 1 ? @"" : @"s"]
                         : @"sessions from this terminal — click to open";
    [self layout];
    [self.window invalidateCursorRectsForView:_list];
}

- (void)reload {
    _all = ATHCollect();
    [self applyFilter];
}

@end
