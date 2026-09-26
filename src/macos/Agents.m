#import "Agents.h"
#import "Keys.h"
#import "Theme.h"
#include "at_control.h"
#include <string.h>

/* Launch lines. Yolo flags are applied in ATAgentFlagsForCommand, not here. */
static const ATAgentInfo kAgents[] = {
    { "claude", "Claude", "claude-sonnet-4-5", "claude", "claude", NULL },
    { "grok", "Grok", "grok-4.5", "grok", "grok", NULL },
    { "chatgpt", "ChatGPT", "gpt-4.1", "chatgpt", "codex", NULL },
    { "gemini", "Gemini", "gemini-2.5-pro", "gemini", "gemini", NULL },
};

uint32_t at_agent_count(void) {
    return (uint32_t)(sizeof(kAgents) / sizeof(kAgents[0]));
}

const ATAgentInfo *at_agent_at(uint32_t index) {
    if (index >= at_agent_count()) return NULL;
    return &kAgents[index];
}

const ATAgentInfo *at_agent_find(const char *id) {
    if (!id || !id[0]) return &kAgents[0];
    if (strcmp(id, "grok-code") == 0) id = "grok";
    for (uint32_t i = 0; i < at_agent_count(); i++) {
        if (strcmp(kAgents[i].id, id) == 0) return &kAgents[i];
    }
    return NULL;
}

static NSColor *ATQBg(void) { return ATColorBg(); }
static NSColor *ATQText(void) { return ATColorText(); }
static NSColor *ATQMuted(void) { return ATColorMuted(); }
static NSColor *ATQAccent(void) { return ATColorAccent(); }
static NSColor *ATQCard(void) { return ATColorSurface(); }

static NSString *ATAgentResourcePath(NSString *icon) {
    NSString *path = [[NSBundle mainBundle] pathForResource:icon ofType:@"png" inDirectory:@"agents"];
    if (path) return path;
    NSString *exe = [[NSBundle mainBundle] executablePath];
    if (exe) {
        NSString *guess = [[[[exe stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"Resources"]
            stringByAppendingPathComponent:[NSString stringWithFormat:@"agents/%@.png", icon]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:guess]) return guess;
    }
    return nil;
}

NSImage *ATAgentImage(NSString *agentId) {
    const ATAgentInfo *info = at_agent_find(agentId.UTF8String);
    NSString *icon = info ? @(info->icon) : agentId;
    NSString *path = ATAgentResourcePath(icon);
    if (!path) return nil;
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
    img.size = NSMakeSize(32, 32);
    return img;
}

NSString *ATAgentDisplayName(NSString *agentId) {
    const ATAgentInfo *info = at_agent_find(agentId.UTF8String);
    return info ? @(info->name) : (agentId.length ? agentId : @"Claude");
}

NSString *ATAgentCommand(NSString *agentId) {
    const ATAgentInfo *info = at_agent_find(agentId.UTF8String);
    if (!info || !info->cmd || !info->cmd[0]) return nil;
    return @(info->cmd);
}

NSArray<NSString *> *ATAgentFlagsForCommand(NSString *command) {
    if (!command.length) return @[];
    if (at_control_yolo()) {
        if ([command isEqualToString:@"grok"]) return @[ @"--always-approve" ];
        if ([command isEqualToString:@"claude"]) return @[ @"--dangerously-skip-permissions" ];
    } else if ([command isEqualToString:@"grok"]) {
        /* Home config may still say always-approve. The toggle is the switch. */
        return @[ @"--permission-mode", @"ask" ];
    }
    for (uint32_t i = 0; i < at_agent_count(); i++) {
        const ATAgentInfo *a = at_agent_at(i);
        if (!a->cmd || ![command isEqualToString:@(a->cmd)]) continue;
        if (!a->flags || !a->flags[0]) return @[];
        NSMutableArray<NSString *> *out = [NSMutableArray new];
        for (NSString *f in [@(a->flags) componentsSeparatedByString:@" "]) {
            if (f.length) [out addObject:f];
        }
        return out;
    }
    return @[];
}

void ATFillAgentPopup(NSPopUpButton *popup, NSString *selectedId) {
    [popup removeAllItems];
    NSInteger select = 0;
    for (uint32_t i = 0; i < at_agent_count(); i++) {
        const ATAgentInfo *a = at_agent_at(i);
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@(a->name) action:nil keyEquivalent:@""];
        NSImage *img = ATAgentImage(@(a->id));
        img.size = NSMakeSize(16, 16);
        item.image = img;
        item.representedObject = @(a->id);
        [popup.menu addItem:item];
        if (selectedId && [selectedId isEqualToString:@(a->id)]) select = (NSInteger)i;
        if (!selectedId && strcmp(a->id, "claude") == 0) select = (NSInteger)i;
    }
    [popup selectItemAtIndex:select];
}

NSString *ATSelectedAgentId(NSPopUpButton *popup) {
    id obj = popup.selectedItem.representedObject;
    if ([obj isKindOfClass:[NSString class]]) return obj;
    return @"claude";
}

#pragma mark - Quickstart

static NSString *ATTildePath(NSString *path) {
    NSString *home = NSHomeDirectory();
    if (home.length && [path hasPrefix:home]) {
        return [@"~" stringByAppendingString:[path substringFromIndex:home.length]];
    }
    return path ?: @"";
}

static const CGFloat kQCardW = 108;
static const CGFloat kQCardH = 92;
static const CGFloat kQCardGap = 12;
static const CGFloat kQStartH = 32;
static const CGFloat kQIcon = 32;
static const CGFloat kQIconTop = 16;
static const CGFloat kQLabelTop = 56;
static const CGFloat kQLabelH = 22;

@interface ATAgentCard : NSView
@property (nonatomic, copy) NSString *agentId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSImage *icon;
@property (nonatomic, assign) BOOL selected;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
@end

@implementation ATAgentCard
- (BOOL)isFlipped { return YES; }
- (BOOL)wantsLayer { return YES; }

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 10;
    self.layer.backgroundColor = ATQCard().CGColor;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = [NSColor clearColor].CGColor;
    return self;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.layer.borderColor = selected ? ATQAccent().CGColor : [NSColor clearColor].CGColor;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    CGFloat x = floor((NSWidth(self.bounds) - kQIcon) / 2.0);
    if (self.icon) {
        [self.icon drawInRect:NSMakeRect(x, kQIconTop, kQIcon, kQIcon)
                     fromRect:NSZeroRect
                    operation:NSCompositingOperationSourceOver
                     fraction:1.0
               respectFlipped:YES
                        hints:nil];
    }
    NSColor *tc = self.selected ? ATQText() : ATQMuted();
    NSFont *font = [NSFont fontWithName:@"Avenir Next" size:12] ?: [NSFont systemFontOfSize:12];
    NSString *t = self.title ?: @"";
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: tc,
    };
    NSSize sz = [t sizeWithAttributes:attrs];
    [t drawAtPoint:NSMakePoint(floor((NSWidth(self.bounds) - sz.width) / 2.0),
                               kQLabelTop + floor((kQLabelH - sz.height) / 2.0))
    withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.target && self.action) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.target performSelector:self.action withObject:self];
#pragma clang diagnostic pop
    }
}
@end

static NSTextField *ATLabel(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *t = [[NSTextField alloc] initWithFrame:NSZeroRect];
    t.stringValue = text;
    t.font = font;
    t.textColor = color;
    t.bezeled = NO;
    t.editable = NO;
    t.selectable = NO;
    t.drawsBackground = NO;
    t.alignment = NSTextAlignmentCenter;
    return t;
}

@implementation ATQuickstartView {
    NSTextField *_title;
    NSTextField *_sub;
    NSMutableArray<ATAgentCard *> *_cards;
    NSButton *_start;
    NSAttributedString *_homeLine;
    NSRect _homeHit;
    NSInteger _stop;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.selectedAgentId = @"claude";
    NSFont *titleFont = [NSFont fontWithName:@"Avenir Next" size:22] ?:
        [NSFont systemFontOfSize:22 weight:NSFontWeightMedium];
    NSFont *subFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _title = ATLabel(@"Quickstart", titleFont, ATQText());
    _sub = ATLabel(@"click an agent — folder is already set", subFont, ATQMuted());
    [self addSubview:_title];
    [self addSubview:_sub];
    _cards = [NSMutableArray new];
    for (uint32_t i = 0; i < at_agent_count(); i++) {
        const ATAgentInfo *a = at_agent_at(i);
        ATAgentCard *card = [[ATAgentCard alloc] initWithFrame:NSZeroRect];
        card.agentId = @(a->id);
        card.title = @(a->name);
        card.icon = ATAgentImage(@(a->id));
        card.icon.size = NSMakeSize(kQIcon, kQIcon);
        card.target = self;
        card.action = @selector(selectCard:);
        [self addSubview:card];
        [_cards addObject:card];
    }
    _start = [[NSButton alloc] initWithFrame:NSZeroRect];
    _start.bezelStyle = NSBezelStyleRounded;
    _start.font = [NSFont fontWithName:@"Avenir Next" size:13] ?: [NSFont systemFontOfSize:13];
    _start.target = self;
    _start.action = @selector(start:);
    [self addSubview:_start];
    [self restyleCards];
    [self reloadHome];
    _start.refusesFirstResponder = YES;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

- (void)keyDown:(NSEvent *)event {
    unsigned short kc = event.keyCode;
    NSInteger nStops = (NSInteger)_cards.count + 2;
    if (kc == 48 && !(event.modifierFlags & NSEventModifierFlagControl) &&
        !(event.modifierFlags & NSEventModifierFlagCommand)) {
        NSInteger dir = (event.modifierFlags & NSEventModifierFlagShift) ? -1 : 1;
        _stop = (_stop + dir) % nStops;
        if (_stop < 0) _stop += nStops;
        if (_stop < (NSInteger)_cards.count) {
            self.selectedAgentId = _cards[(NSUInteger)_stop].agentId;
            [self restyleCards];
        }
        [self restyleStart];
        [self setNeedsDisplay:YES];
        return;
    }
    NSWindowController *wc = self.window.windowController;
    if ([wc handleNavEvent:event]) return;
    if (kc == 123 || kc == 124) {
        if (!_cards.count) return;
        NSInteger cur = 0;
        for (NSUInteger i = 0; i < _cards.count; i++) {
            if ([_cards[i].agentId isEqualToString:self.selectedAgentId]) cur = (NSInteger)i;
        }
        NSInteger n = (NSInteger)_cards.count;
        NSInteger next = kc == 124 ? cur + 1 : cur - 1;
        if (next < 0) next = n - 1;
        if (next >= n) next = 0;
        _stop = next;
        self.selectedAgentId = _cards[(NSUInteger)next].agentId;
        [self restyleCards];
        [self restyleStart];
        [self setNeedsDisplay:YES];
        return;
    }
    if (kc == 36) {
        if (_stop == (NSInteger)_cards.count + 1) [self changeHome:self];
        else [self start:self];
        return;
    }
    NSString *ch = event.charactersIgnoringModifiers.lowercaseString;
    if ([ch isEqualToString:@"f"]) { [self changeHome:self]; return; }
    [super keyDown:event];
}

- (void)restyleStart {
    BOOL on = (_stop == (NSInteger)_cards.count);
    _start.wantsLayer = YES;
    _start.layer.borderWidth = on ? 2 : 0;
    _start.layer.borderColor = ATQAccent().CGColor;
    _start.layer.cornerRadius = 6;
}

- (void)reloadHome {
    NSString *shown = ATTildePath(self.homePath);
    if (shown.length) {
        _start.title = [NSString stringWithFormat:@"Start in %@", shown.lastPathComponent];
    } else {
        _start.title = @"Choose folder and start";
        shown = @"no folder yet";
    }
    NSFont *font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSDictionary *muted = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: ATQMuted(),
    };
    NSDictionary *accent = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: ATQAccent(),
    };
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:shown attributes:muted]];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:@" · " attributes:muted]];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"change folder" attributes:accent]];
    _homeLine = line;
    [self setNeedsDisplay:YES];
    self.needsLayout = YES;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATQBg() setFill];
    NSRectFill(self.bounds);
    if (_homeLine) {
        [_homeLine drawWithRect:_homeHit options:NSStringDrawingUsesLineFragmentOrigin];
        if (_stop == (NSInteger)_cards.count + 1) {
            [ATQAccent() setStroke];
            NSFrameRectWithWidth(NSInsetRect(_homeHit, -4, -2), 2);
        }
    }
}

- (void)layout {
    [super layout];
    const CGFloat titleH = 30;
    const CGFloat subH = 16;
    const CGFloat startH = kQStartH;
    const CGFloat changeH = 22;
    const CGFloat gapTitleSub = 6;
    const CGFloat gapSubCards = 28;
    const CGFloat gapCardsStart = 28;
    const CGFloat gapStartChange = 14;
    CGFloat stackH = titleH + gapTitleSub + subH + gapSubCards + kQCardH +
                     gapCardsStart + startH + gapStartChange + changeH;
    CGFloat y = floor((NSHeight(self.bounds) - stackH) / 2.0);
    if (y < 16) y = 16;
    CGFloat cx = NSMidX(self.bounds);
    _title.frame = NSMakeRect(0, y, NSWidth(self.bounds), titleH);
    y += titleH + gapTitleSub;
    _sub.frame = NSMakeRect(0, y, NSWidth(self.bounds), subH);
    y += subH + gapSubCards;
    NSUInteger n = _cards.count;
    CGFloat rowW = n * kQCardW + (n > 0 ? (n - 1) * kQCardGap : 0);
    CGFloat x = floor(cx - rowW / 2.0);
    for (ATAgentCard *card in _cards) {
        card.frame = NSMakeRect(x, y, kQCardW, kQCardH);
        x += kQCardW + kQCardGap;
    }
    y += kQCardH + gapCardsStart;
    _start.frame = NSMakeRect(floor(cx - 130), y, 260, startH);
    y += startH + gapStartChange;
    NSSize lineSz = _homeLine ? _homeLine.size : NSMakeSize(0, changeH);
    _homeHit = NSMakeRect(floor(cx - lineSz.width / 2.0), y, ceil(lineSz.width), MAX(lineSz.height, changeH));
    [self.window invalidateCursorRectsForView:self];
}

/* The folder line is a button, not a label — say so on hover. */
- (void)resetCursorRects {
    [super resetCursorRects];
    if (_homeLine) {
        [self addCursorRect:_homeHit cursor:[NSCursor pointingHandCursor]];
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    self.needsLayout = YES;
    [self layoutSubtreeIfNeeded];
    [self setNeedsDisplay:YES];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self layout];
}

- (void)restyleCards {
    for (ATAgentCard *card in _cards) {
        card.selected = [card.agentId isEqualToString:self.selectedAgentId];
    }
    [self restyleStart];
}

- (void)selectCard:(ATAgentCard *)sender {
    self.selectedAgentId = sender.agentId;
    [self restyleCards];
    [self start:sender];
}

- (void)start:(id)sender {
    (void)sender;
    if (self.onStart) self.onStart(self.selectedAgentId ?: @"claude");
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, _homeHit)) {
        [self changeHome:self];
        return;
    }
    [super mouseDown:event];
}

- (void)changeHome:(id)sender {
    (void)sender;
    if (self.onChangeHome) self.onChangeHome();
}

@end
