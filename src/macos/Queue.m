#import "Queue.h"
#import "Agents.h"
#import "Keys.h"
#import "Theme.h"
#include "at_control.h"
#include "at_agents.h"
#include <string.h>

static const CGFloat kPad = 36;
static const CGFloat kRowH = 56;
static const CGFloat kStepH = 44;
static const CGFloat kChipH = 26;
/* Right-hand controls of a step row, measured in from the right edge. */
static const CGFloat kStepCtlW = 314;

static BOOL ATPipelineReady(void) {
    uint32_t n = at_control_ext_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *id = at_control_ext_id(i);
        if (id && strcmp(id, "pipeline") == 0)
            return at_control_ext_enabled(i) && at_control_ext_loaded(i);
    }
    return NO;
}

static NSString *ATPipelineBlocked(void) {
    uint32_t n = at_control_ext_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *id = at_control_ext_id(i);
        if (!id || strcmp(id, "pipeline") != 0) continue;
        if (at_control_ext_loaded(i)) return nil;
        if (at_control_ext_enabled(i) && !at_control_ext_present(i))
            return @"Pipeline is on, but the plugin isn’t installed in this app.";
        if (at_control_ext_enabled(i))
            return @"Pipeline is on, but it failed to load. Toggle it off and on in Settings.";
        return @"Turn on Pipeline in Settings, then come back here.";
    }
    return @"Turn on Pipeline in Settings, then come back here.";
}

static NSString *ATSupport(NSString *leaf) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ATerminal"]
            stringByAppendingPathComponent:leaf];
}

typedef NS_ENUM(NSInteger, ATQHit) {
    ATQHitWorkflow = 1,
    ATQHitWorkflowNew,
    ATQHitWorkflowDel,
    ATQHitFlowName,
    ATQHitStepName,
    ATQHitStepAgent,
    ATQHitStepKind,
    ATQHitStepRemove,
    ATQHitStepUp,
    ATQHitStepDown,
    ATQHitStepAdd,
    ATQHitRun,
    ATQHitNewTab,
    ATQHitApprove,
    ATQHitDismiss,
    ATQHitOpen,
};

@interface ATQStep : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *agent;
@end
@implementation ATQStep
- (NSDictionary *)json {
    return @{
        @"name": self.name ?: @"do",
        @"kind": self.kind ?: @"agent",
        @"agent": self.agent ?: @"grok",
    };
}
+ (instancetype)from:(NSDictionary *)d {
    ATQStep *s = [ATQStep new];
    s.name = ([d[@"name"] isKindOfClass:[NSString class]] && [d[@"name"] length]) ? d[@"name"] : @"do";
    NSString *kind = d[@"kind"];
    s.kind = ([kind isKindOfClass:[NSString class]] && [kind isEqualToString:@"human"]) ? @"human" : @"agent";
    s.agent = ([d[@"agent"] isKindOfClass:[NSString class]] && [d[@"agent"] length]) ? d[@"agent"] : @"grok";
    return s;
}
+ (instancetype)agent:(NSString *)name {
    ATQStep *s = [ATQStep new];
    s.name = name;
    s.kind = @"agent";
    s.agent = @"grok";
    return s;
}
@end

@interface ATQFlow : NSObject
@property (nonatomic, copy) NSString *fid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<ATQStep *> *steps;
@end
@implementation ATQFlow
- (NSDictionary *)json {
    NSMutableArray *st = [NSMutableArray new];
    for (ATQStep *s in self.steps) [st addObject:[s json]];
    return @{ @"id": self.fid ?: @"", @"name": self.name ?: @"Untitled", @"steps": st };
}
+ (instancetype)from:(NSDictionary *)d pathId:(NSString *)pathId {
    ATQFlow *f = [ATQFlow new];
    f.fid = ([d[@"id"] isKindOfClass:[NSString class]] && [d[@"id"] length]) ? d[@"id"] : pathId;
    f.name = ([d[@"name"] isKindOfClass:[NSString class]] && [d[@"name"] length]) ? d[@"name"] : @"Untitled";
    f.steps = [NSMutableArray new];
    id arr = d[@"steps"];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (id x in arr) {
            if ([x isKindOfClass:[NSDictionary class]]) [f.steps addObject:[ATQStep from:x]];
        }
    }
    if (!f.steps.count) [f.steps addObject:[ATQStep agent:@"do"]];
    return f;
}
+ (instancetype)blank {
    ATQFlow *f = [ATQFlow new];
    f.fid = [[NSUUID UUID] UUIDString];
    f.name = @"Untitled";
    f.steps = [NSMutableArray arrayWithObject:[ATQStep agent:@"do"]];
    return f;
}
@end

@interface ATQueueView () <NSTextFieldDelegate>
- (CGFloat)stepsTop;
@end

@implementation ATQueueView {
    NSTextField *_field;
    NSMutableArray<ATQFlow *> *_flows;
    ATQFlow *_flow;
    NSMutableArray<NSDictionary *> *_jobs;
    NSMutableArray<NSDictionary *> *_hits;
    NSTimer *_tick;
    NSTextField *_edit;
    void (^_editCommit)(NSString *);
    BOOL _editing;
    BOOL _newTabOn;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _flows = [NSMutableArray new];
    _jobs = [NSMutableArray new];
    _hits = [NSMutableArray new];
    self.wantsLayer = YES;
    _field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _field.placeholderString = @"Task for this run…";
    _field.font = [NSFont fontWithName:@"Avenir Next" size:14] ?: [NSFont systemFontOfSize:14];
    _field.textColor = ATColorText();
    _field.backgroundColor = ATColorSurface();
    _field.drawsBackground = YES;
    _field.bezeled = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.delegate = self;
    [self addSubview:_field];
    [self loadFlows];
    [self reload];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [_tick invalidate];
    _tick = nil;
    if (self.window) {
        _tick = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(reload)
                                               userInfo:nil repeats:YES];
        _tick.tolerance = 0.4;
    }
}

- (void)dealloc {
    [_tick invalidate];
}

- (NSFont *)headFont {
    return [NSFont fontWithName:@"Avenir Next" size:11] ?: [NSFont systemFontOfSize:11];
}
- (NSFont *)titleFont {
    return [NSFont fontWithName:@"Avenir Next" size:14] ?: [NSFont systemFontOfSize:14];
}
- (NSFont *)metaFont {
    return [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
}

- (NSDictionary *)headAttrs {
    return @{
        NSFontAttributeName: self.headFont,
        NSForegroundColorAttributeName: ATColorMuted(),
        NSKernAttributeName: @1.4,
    };
}

- (NSUInteger)chipRowsForWidth:(CGFloat)w {
    if (w < 1) w = 800;
    CGFloat x = kPad;
    NSUInteger rows = 1;
    NSDictionary *attrs = @{ NSFontAttributeName: self.metaFont };
    for (ATQFlow *f in _flows) {
        NSString *title = f.name.length ? f.name : @"Untitled";
        CGFloat cw = MIN([title sizeWithAttributes:attrs].width + 20, 180);
        if (f == _flow) cw += 18;
        if (x > kPad && x + cw > w - kPad) {
            rows++;
            x = kPad;
        }
        x += cw + 6;
    }
    if (x > kPad && x + 28 > w - kPad) rows++;
    return MAX(rows, 1);
}

- (CGFloat)stepsTop {
    NSUInteger rows = [self chipRowsForWidth:NSWidth(self.bounds)];
    return 28 + 22 + 18 + rows * (kChipH + 6) - 6 + 16 + 22;
}

/* Below the last step sits "add step", then a rule, then the run bar. */
- (CGFloat)addStepTop {
    return [self stepsTop] + _flow.steps.count * kStepH + 6;
}

- (CGFloat)taskTop {
    return [self addStepTop] + 26 + 26;
}

- (void)layout {
    [super layout];
    CGFloat w = NSWidth(self.bounds);
    _field.frame = NSMakeRect(kPad + 1, [self taskTop] + 1, w - kPad * 2 - 200, 30);
}

- (void)hit:(ATQHit)k i:(NSInteger)i rect:(NSRect)r {
    [_hits addObject:@{ @"k": @(k), @"i": @(i), @"r": [NSValue valueWithRect:r] }];
}

- (void)loadFlows {
    [_flows removeAllObjects];
    NSString *root = ATSupport(@"workflows");
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil];
    names = [names sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        if (![name.pathExtension isEqualToString:@"json"]) continue;
        NSString *path = [root stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        [_flows addObject:[ATQFlow from:obj pathId:name.stringByDeletingPathExtension]];
    }
    if (!_flows.count) {
        ATQFlow *f = [ATQFlow blank];
        f.name = @"Untitled";
        [_flows addObject:f];
        [self saveFlow:f];
    }
    if (!_flow) _flow = _flows.firstObject;
    else {
        NSString *id = _flow.fid;
        ATQFlow *keep = nil;
        for (ATQFlow *f in _flows) {
            if ([f.fid isEqualToString:id]) {
                keep = f;
                break;
            }
        }
        _flow = keep ?: _flows.firstObject;
    }
}

- (void)saveFlow:(ATQFlow *)f {
    if (!f.fid.length) return;
    NSString *root = ATSupport(@"workflows");
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [[root stringByAppendingPathComponent:f.fid] stringByAppendingPathExtension:@"json"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:[f json] options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path atomically:YES];
}

- (void)saveCurrent {
    if (_flow) [self saveFlow:_flow];
}

- (void)reload {
    [_jobs removeAllObjects];
    NSString *root = ATSupport(@"queue");
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil];
    names = [names sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names.reverseObjectEnumerator) {
        if ([name hasPrefix:@"."]) continue;
        NSString *path = [[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"job.json"];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *job = [obj mutableCopy];
        job[@"dir"] = [root stringByAppendingPathComponent:name];
        [_jobs addObject:job];
    }
    _field.enabled = ATPipelineReady();
    if (!_editing) {
        [self setNeedsDisplay:YES];
        [self setNeedsLayout:YES];
    }
}

- (void)run:(id)sender {
    (void)sender;
    if (!ATPipelineReady()) return;
    [self finishEdit:YES];
    [self saveCurrent];
    NSString *task = [_field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!task.length || !_flow.steps.count) {
        NSBeep();
        return;
    }
    NSMutableArray *steps = [NSMutableArray new];
    for (ATQStep *s in _flow.steps) [steps addObject:[s json]];
    NSDictionary *args = @{
        @"task": task,
        @"new_tab": @(_newTabOn),
        @"workflow": _flow.fid ?: @"",
        @"agent": _flow.steps.firstObject.agent ?: @"grok",
        @"steps": steps,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    char *out = NULL;
    int rc = at_control_call("pipeline.push", json.UTF8String, &out);
    if (out) at_control_free(out);
    if (rc != 0) {
        NSBeep();
        return;
    }
    _field.stringValue = @"";
    [self reload];
}

- (void)finishEdit:(BOOL)apply {
    if (!_edit) return;
    NSString *value = _edit.stringValue;
    void (^commit)(NSString *) = _editCommit;
    _edit.delegate = nil;
    [_edit removeFromSuperview];
    _edit = nil;
    _editCommit = nil;
    _editing = NO;
    if (apply && commit) commit(value);
    [self setNeedsDisplay:YES];
}

- (void)editIn:(NSRect)r text:(NSString *)text commit:(void (^)(NSString *))commit {
    [self finishEdit:YES];
    NSRect box = NSInsetRect(r, 4, 4);
    if (box.size.width < 80) box.size.width = 80;
    NSTextField *f = [[NSTextField alloc] initWithFrame:box];
    f.stringValue = text ?: @"";
    f.font = self.titleFont;
    f.textColor = ATColorText();
    f.backgroundColor = ATColorSurface();
    f.drawsBackground = YES;
    f.bezeled = NO;
    f.focusRingType = NSFocusRingTypeNone;
    _edit = f;
    _editCommit = [commit copy];
    _editing = YES;
    [self addSubview:f];
    [self.window makeFirstResponder:f];
    [f selectText:nil];
    f.delegate = self;
}

- (BOOL)control:(NSTextField *)control textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    (void)tv;
    if (control == _edit) {
        if (sel == @selector(insertNewline:)) {
            [self finishEdit:YES];
            return YES;
        }
        if (sel == @selector(cancelOperation:)) {
            [self finishEdit:NO];
            return YES;
        }
        return NO;
    }
    if (sel == @selector(insertNewline:)) {
        [self run:nil];
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)n {
    if (n.object == _edit) {
        [self finishEdit:YES];
        return;
    }
}

- (void)stepChanged {
    [self saveCurrent];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)moveStep:(NSInteger)delta from:(NSInteger)index {
    if (index < 0 || (NSUInteger)index >= _flow.steps.count) return;
    NSInteger dest = index + delta;
    if (dest < 0 || (NSUInteger)dest >= _flow.steps.count) return;
    ATQStep *s = _flow.steps[(NSUInteger)index];
    [_flow.steps removeObjectAtIndex:(NSUInteger)index];
    [_flow.steps insertObject:s atIndex:(NSUInteger)dest];
    [self stepChanged];
}

- (void)removeStepAt:(NSInteger)index {
    if (_flow.steps.count <= 1) {
        NSBeep();
        return;
    }
    if (index < 0 || (NSUInteger)index >= _flow.steps.count) return;
    [_flow.steps removeObjectAtIndex:(NSUInteger)index];
    [self stepChanged];
}

- (void)addStep {
    NSUInteger n = _flow.steps.count + 1;
    [_flow.steps addObject:[ATQStep agent:[NSString stringWithFormat:@"step %lu", (unsigned long)n]]];
    [self stepChanged];
}

/* The agent chip opens the real agent list rather than cycling blindly. */
- (void)pickAgentFor:(NSInteger)index at:(NSPoint)p {
    if (index < 0 || (NSUInteger)index >= _flow.steps.count) return;
    ATQStep *step = _flow.steps[(NSUInteger)index];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Agent"];
    uint32_t n = at_agent_count();
    for (uint32_t i = 0; i < n; i++) {
        const ATAgentInfo *a = at_agent_at(i);
        if (!a || !a->id) continue;
        NSString *aid = @(a->id);
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:ATAgentDisplayName(aid)
                                                    action:@selector(agentPicked:)
                                             keyEquivalent:@""];
        it.target = self;
        it.representedObject = @{ @"i": @(index), @"id": aid };
        NSImage *img = ATAgentImage(aid);
        img.size = NSMakeSize(14, 14);
        it.image = img;
        it.state = [step.agent isEqualToString:aid] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:it];
    }
    [menu popUpMenuPositioningItem:nil atLocation:p inView:self];
}

- (void)agentPicked:(NSMenuItem *)item {
    NSDictionary *d = item.representedObject;
    if (![d isKindOfClass:[NSDictionary class]]) return;
    NSInteger i = [d[@"i"] integerValue];
    if (i < 0 || (NSUInteger)i >= _flow.steps.count) return;
    _flow.steps[(NSUInteger)i].agent = d[@"id"];
    [self stepChanged];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATColorBg() setFill];
    NSRectFill(self.bounds);
    [_hits removeAllObjects];
    CGFloat w = NSWidth(self.bounds);
    CGFloat y = 28;
    [@"PIPELINE" drawAtPoint:NSMakePoint(kPad, y) withAttributes:self.headAttrs];
    y += 22;
    [@"WORKFLOWS" drawAtPoint:NSMakePoint(kPad, y) withAttributes:self.headAttrs];
    y += 18;
    CGFloat x = kPad;
    NSDictionary *chipA = @{
        NSFontAttributeName: self.metaFont,
        NSForegroundColorAttributeName: ATColorText(),
    };
    NSDictionary *chipMuted = @{
        NSFontAttributeName: self.metaFont,
        NSForegroundColorAttributeName: ATColorMuted(),
    };
    for (NSUInteger i = 0; i < _flows.count; i++) {
        ATQFlow *f = _flows[i];
        BOOL on = f == _flow;
        NSString *title = f.name.length ? f.name : @"Untitled";
        NSSize sz = [title sizeWithAttributes:on ? chipA : chipMuted];
        CGFloat cw = MIN(sz.width + 20, 180);
        if (on) cw += 18;
        if (x > kPad && x + cw > w - kPad) {
            x = kPad;
            y += kChipH + 6;
        }
        NSRect chip = NSMakeRect(x, y, cw, kChipH);
        [[ATColorSurface() colorWithAlphaComponent:on ? 0.95 : 0.55] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:6 yRadius:6] fill];
        [title drawInRect:NSMakeRect(chip.origin.x + 8, y + 5, cw - (on ? 26 : 12), 16)
           withAttributes:on ? chipA : chipMuted];
        [self hit:ATQHitWorkflow i:(NSInteger)i rect:chip];
        if (on) {
            [ATColorAccent() setFill];
            NSRectFill(NSMakeRect(chip.origin.x + 8, y + kChipH - 2, cw - 16, 2));
            NSRect xhit = NSMakeRect(NSMaxX(chip) - 18, y + 4, 14, 16);
            [@"×" drawAtPoint:NSMakePoint(xhit.origin.x, y + 3) withAttributes:chipMuted];
            [self hit:ATQHitWorkflowDel i:(NSInteger)i rect:xhit];
            [self hit:ATQHitFlowName i:(NSInteger)i rect:NSMakeRect(chip.origin.x, y, cw - 18, kChipH)];
        }
        x = NSMaxX(chip) + 6;
    }
    NSRect plus = NSMakeRect(x, y, 28, kChipH);
    [[ATColorSurface() colorWithAlphaComponent:0.55] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:plus xRadius:6 yRadius:6] fill];
    [@"+" drawAtPoint:NSMakePoint(plus.origin.x + 9, y + 3) withAttributes:chipMuted];
    [self hit:ATQHitWorkflowNew i:0 rect:plus];
    y += kChipH + 16;

    [@"STEPS" drawAtPoint:NSMakePoint(kPad, y) withAttributes:self.headAttrs];
    NSDictionary *titleA = @{
        NSFontAttributeName: self.titleFont,
        NSForegroundColorAttributeName: ATColorText(),
    };
    NSDictionary *metaA = @{
        NSFontAttributeName: self.metaFont,
        NSForegroundColorAttributeName: ATColorMuted(),
    };
    NSDictionary *onDark = @{
        NSFontAttributeName: self.titleFont,
        NSForegroundColorAttributeName: ATColorBg(),
    };
    NSDictionary *onDarkMeta = @{
        NSFontAttributeName: self.metaFont,
        NSForegroundColorAttributeName: ATColorBg(),
    };
    CGFloat right = w - kPad;
    CGFloat sy = [self stepsTop];
    for (NSUInteger i = 0; i < _flow.steps.count; i++) {
        ATQStep *s = _flow.steps[i];
        BOOL human = [s.kind isEqualToString:@"human"];
        NSRect row = NSMakeRect(kPad, sy, w - kPad * 2, kStepH - 6);
        [[ATColorSurface() colorWithAlphaComponent:0.7] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:row xRadius:8 yRadius:8] fill];
        CGFloat mid = NSMidY(row);

        NSString *idx = [NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)];
        NSSize isz = [idx sizeWithAttributes:metaA];
        [idx drawAtPoint:NSMakePoint(row.origin.x + 14, mid - isz.height / 2) withAttributes:metaA];

        /* name — click to rename in place */
        NSString *nm = s.name.length ? s.name : @"do";
        CGFloat nameX = row.origin.x + 36;
        CGFloat nameW = MAX(80, right - kStepCtlW - 16 - nameX);
        NSRect nameR = NSMakeRect(nameX, row.origin.y, nameW, row.size.height);
        NSSize nsz = [nm sizeWithAttributes:titleA];
        [nm drawInRect:NSMakeRect(nameX, mid - nsz.height / 2, nameW, nsz.height) withAttributes:titleA];
        [self hit:ATQHitStepName i:(NSInteger)i rect:nameR];

        /* × ↓ ↑ */
        struct { NSString *g; ATQHit k; CGFloat off; } glyphs[] = {
            { @"×", ATQHitStepRemove, 22 },
            { @"↓", ATQHitStepDown, 46 },
            { @"↑", ATQHitStepUp, 70 },
        };
        for (int g = 0; g < 3; g++) {
            NSRect gr = NSMakeRect(right - glyphs[g].off, mid - 11, 22, 22);
            NSSize gs = [glyphs[g].g sizeWithAttributes:metaA];
            [glyphs[g].g drawAtPoint:NSMakePoint(NSMidX(gr) - gs.width / 2, mid - gs.height / 2)
                      withAttributes:metaA];
            [self hit:glyphs[g].k i:(NSInteger)i rect:gr];
        }

        /* agent | human, one pill, the live half filled */
        CGFloat pillW = 116, pillH = 24;
        NSRect pill = NSMakeRect(right - 70 - 12 - pillW, mid - pillH / 2, pillW, pillH);
        [[ATColorHair() colorWithAlphaComponent:0.7] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:12 yRadius:12] fill];
        NSRect live = NSMakeRect(human ? NSMidX(pill) : pill.origin.x, pill.origin.y,
                                 pillW / 2, pillH);
        [ATColorAccent() setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(live, 2, 2) xRadius:10 yRadius:10] fill];
        NSString *labs[2] = { @"agent", @"human" };
        for (int h = 0; h < 2; h++) {
            BOOL lit = (h == 1) == human;
            NSSize ls = [labs[h] sizeWithAttributes:metaA];
            CGFloat cx = pill.origin.x + pillW / 4 + (h ? pillW / 2 : 0);
            [labs[h] drawAtPoint:NSMakePoint(cx - ls.width / 2, mid - ls.height / 2)
                  withAttributes:lit ? onDarkMeta : metaA];
        }
        [self hit:ATQHitStepKind i:(NSInteger)i rect:pill];

        /* agent chip — opens the agent menu; meaningless on a human step */
        if (!human) {
            CGFloat chipW = 104, chipH = 24;
            NSRect chip = NSMakeRect(pill.origin.x - 12 - chipW, mid - chipH / 2, chipW, chipH);
            [[ATColorHair() colorWithAlphaComponent:0.7] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:6 yRadius:6] fill];
            NSImage *icon = ATAgentImage(s.agent);
            icon.size = NSMakeSize(13, 13);
            [icon drawInRect:NSMakeRect(chip.origin.x + 8, mid - 6.5, 13, 13)
                    fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
            NSString *an = ATAgentDisplayName(s.agent);
            NSSize as = [an sizeWithAttributes:metaA];
            [an drawInRect:NSMakeRect(chip.origin.x + 27, mid - as.height / 2, chipW - 27 - 16, as.height)
            withAttributes:metaA];
            NSSize cs = [@"⌄" sizeWithAttributes:metaA];
            [@"⌄" drawAtPoint:NSMakePoint(NSMaxX(chip) - 8 - cs.width, mid - cs.height / 2 - 2)
               withAttributes:metaA];
            [self hit:ATQHitStepAgent i:(NSInteger)i rect:chip];
        }
        sy += kStepH;
    }

    CGFloat ay = [self addStepTop];
    NSRect add = NSMakeRect(kPad, ay, 96, 22);
    NSSize adds = [@"+  add step" sizeWithAttributes:metaA];
    [@"+  add step" drawAtPoint:NSMakePoint(kPad, ay + (22 - adds.height) / 2) withAttributes:metaA];
    [self hit:ATQHitStepAdd i:0 rect:add];

    /* the rule that separates building a workflow from running one */
    CGFloat ty = [self taskTop];
    [[ATColorHair() colorWithAlphaComponent:0.6] setFill];
    NSRectFill(NSMakeRect(kPad, ty - 15, w - kPad * 2, 1));

    NSRect fieldBox = NSMakeRect(kPad, ty, w - kPad * 2 - 198, 32);
    [[ATColorSurface() colorWithAlphaComponent:0.7] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fieldBox xRadius:7 yRadius:7] fill];

    NSRect ntBox = NSMakeRect(right - 178, ty + 8, 16, 16);
    [[ATColorHair() colorWithAlphaComponent:0.8] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:ntBox xRadius:4 yRadius:4] fill];
    if (_newTabOn) {
        [ATColorAccent() setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(ntBox, 4, 4) xRadius:2 yRadius:2] fill];
    }
    NSSize nts = [@"new tab" sizeWithAttributes:metaA];
    [@"new tab" drawAtPoint:NSMakePoint(NSMaxX(ntBox) + 8, ty + 16 - nts.height / 2) withAttributes:metaA];
    [self hit:ATQHitNewTab i:0 rect:NSMakeRect(ntBox.origin.x, ty, 90, 32)];

    NSRect runR = NSMakeRect(right - 74, ty, 74, 32);
    BOOL canRun = ATPipelineReady();
    [(canRun ? ATColorAccent() : [ATColorHair() colorWithAlphaComponent:0.8]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:runR xRadius:7 yRadius:7] fill];
    NSSize rs = [@"Run" sizeWithAttributes:titleA];
    [@"Run" drawAtPoint:NSMakePoint(NSMidX(runR) - rs.width / 2, NSMidY(runR) - rs.height / 2)
         withAttributes:canRun ? onDark : metaA];
    if (canRun) [self hit:ATQHitRun i:0 rect:runR];

    y = ty + 32 + 34;

    NSString *blocked = ATPipelineBlocked();
    if (blocked) {
        NSDictionary *warn = @{
            NSFontAttributeName: self.metaFont,
            NSForegroundColorAttributeName: ATColorAccent(),
        };
        [blocked drawAtPoint:NSMakePoint(kPad, y) withAttributes:warn];
        y += 24;
    }
    [@"RUNS" drawAtPoint:NSMakePoint(kPad, y) withAttributes:self.headAttrs];
    y += 20;
    if (_jobs.count == 0 && ATPipelineReady()) {
        [@"No runs yet. Set the steps, type a task, Run." drawAtPoint:NSMakePoint(kPad, y) withAttributes:metaA];
        return;
    }
    for (NSDictionary *job in _jobs) {
        NSString *task = [job[@"task"] isKindOfClass:[NSString class]] ? job[@"task"] : @"";
        NSString *st = [job[@"status"] isKindOfClass:[NSString class]] ? job[@"status"] : @"";
        NSString *reason = [job[@"reason"] isKindOfClass:[NSString class]] ? job[@"reason"] : @"";
        int si = 0;
        if ([job[@"step"] isKindOfClass:[NSNumber class]]) si = [job[@"step"] intValue];
        else if ([job[@"step"] isKindOfClass:[NSString class]]) si = [job[@"step"] intValue];
        NSArray *sts = [job[@"steps"] isKindOfClass:[NSArray class]] ? job[@"steps"] : @[];
        NSMutableString *pipe = [NSMutableString new];
        for (NSUInteger s = 0; s < sts.count; s++) {
            if (s) [pipe appendString:@"  →  "];
            NSString *name = @"step";
            if ([sts[s] isKindOfClass:[NSDictionary class]] && [sts[s][@"name"] isKindOfClass:[NSString class]])
                name = sts[s][@"name"];
            if ([st isEqualToString:@"done"] || s < (NSUInteger)si) [pipe appendFormat:@"%@ ✓", name];
            else if (s == (NSUInteger)si) [pipe appendFormat:@"▸ %@", name];
            else [pipe appendString:name];
        }
        BOOL failed = [st isEqualToString:@"error"];
        BOOL finished = failed || [st isEqualToString:@"done"];
        NSString *shown = st;
        if ([st isEqualToString:@"needs_you"]) shown = @"needs you";
        else if ([st isEqualToString:@"human"]) shown = @"waiting for you";
        else if ([st isEqualToString:@"arming"]) shown = @"starting the agent";
        else if (failed) shown = @"failed";
        NSString *tail = failed && reason.length ? reason : pipe;
        NSString *meta = tail.length ? [NSString stringWithFormat:@"%@  ·  %@", shown, tail] : shown;
        NSRect row = NSMakeRect(kPad, y, w - kPad * 2, kRowH);
        NSString *tabId = [job[@"tab"] isKindOfClass:[NSString class]] ? job[@"tab"] : @"";
        if (tabId.length) {
            [_hits addObject:@{
                @"k": @(ATQHitOpen),
                @"i": @0,
                @"r": [NSValue valueWithRect:row],
                @"tab": tabId,
            }];
        }
        [[ATColorSurface() colorWithAlphaComponent:0.7] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:row xRadius:8 yRadius:8] fill];
        if (failed) {
            [ATColorAccent() setFill];
            NSRectFill(NSMakeRect(row.origin.x, y + 10, 2, kRowH - 20));
        }
        CGFloat rightEdge = NSMaxX(row) - 12;

        /* finished runs can be cleared away; they are not news any more */
        if (finished) {
            NSRect x = NSMakeRect(rightEdge - 20, y + (kRowH - 22) / 2.0, 22, 22);
            NSSize xs = [@"×" sizeWithAttributes:metaA];
            [@"×" drawAtPoint:NSMakePoint(NSMidX(x) - xs.width / 2, NSMidY(x) - xs.height / 2)
               withAttributes:metaA];
            [_hits addObject:@{
                @"k": @(ATQHitDismiss),
                @"i": @0,
                @"r": [NSValue valueWithRect:x],
                @"dir": job[@"dir"] ?: @"",
            }];
            rightEdge -= 30;
        }
        if ([st isEqualToString:@"human"]) {
            NSString *lab = @"Approve";
            NSSize sz = [lab sizeWithAttributes:titleA];
            NSRect hit = NSMakeRect(rightEdge - sz.width - 16, y + (kRowH - 24) / 2.0, sz.width + 16, 24);
            [ATColorAccent() setFill];
            [[NSBezierPath bezierPathWithRoundedRect:hit xRadius:6 yRadius:6] fill];
            [lab drawAtPoint:NSMakePoint(NSMidX(hit) - sz.width / 2, NSMidY(hit) - sz.height / 2)
              withAttributes:onDark];
            [_hits addObject:@{
                @"k": @(ATQHitApprove),
                @"i": @0,
                @"r": [NSValue valueWithRect:hit],
                @"dir": job[@"dir"] ?: @"",
            }];
            rightEdge = hit.origin.x - 12;
        }
        CGFloat textW = MAX(60, rightEdge - (row.origin.x + 14));
        [task drawInRect:NSMakeRect(row.origin.x + 14, y + 11, textW, 20) withAttributes:titleA];
        [meta drawInRect:NSMakeRect(row.origin.x + 14, y + 33, textW, 16) withAttributes:metaA];
        y += kRowH + 8;
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (_edit && !NSPointInRect(p, _edit.frame)) [self finishEdit:YES];
    for (NSDictionary *h in [_hits reverseObjectEnumerator]) {
        NSRect r = [h[@"r"] rectValue];
        if (!NSPointInRect(p, r)) continue;
        ATQHit k = [h[@"k"] integerValue];
        NSInteger i = [h[@"i"] integerValue];
        switch (k) {
        case ATQHitWorkflow:
            if ((NSUInteger)i < _flows.count) _flow = _flows[(NSUInteger)i];
            [self setNeedsDisplay:YES];
            [self setNeedsLayout:YES];
            return;
        case ATQHitFlowName: {
            ATQFlow *f = _flow;
            [self editIn:r text:f.name commit:^(NSString *name) {
                NSString *t = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (t.length) f.name = t;
                [self saveFlow:f];
            }];
            return;
        }
        case ATQHitWorkflowNew: {
            [self saveCurrent];
            ATQFlow *f = [ATQFlow blank];
            [_flows addObject:f];
            _flow = f;
            [self saveFlow:f];
            [self setNeedsDisplay:YES];
            [self setNeedsLayout:YES];
            return;
        }
        case ATQHitWorkflowDel: {
            if (_flows.count <= 1) {
                NSBeep();
                return;
            }
            ATQFlow *f = ((NSUInteger)i < _flows.count) ? _flows[(NSUInteger)i] : _flow;
            NSString *path = [[ATSupport(@"workflows") stringByAppendingPathComponent:f.fid]
                              stringByAppendingPathExtension:@"json"];
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            [_flows removeObject:f];
            _flow = _flows.firstObject;
            [self setNeedsDisplay:YES];
            [self setNeedsLayout:YES];
            return;
        }
        case ATQHitStepName: {
            if ((NSUInteger)i >= _flow.steps.count) return;
            ATQStep *s = _flow.steps[(NSUInteger)i];
            [self editIn:r text:s.name commit:^(NSString *name) {
                NSString *t = [name stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (t.length) s.name = t;
                [self saveCurrent];
            }];
            return;
        }
        case ATQHitStepAgent:
            [self pickAgentFor:i at:NSMakePoint(r.origin.x, NSMaxY(r) + 2)];
            return;
        case ATQHitStepKind: {
            if ((NSUInteger)i >= _flow.steps.count) return;
            _flow.steps[(NSUInteger)i].kind = (p.x > NSMidX(r)) ? @"human" : @"agent";
            [self stepChanged];
            return;
        }
        case ATQHitStepUp:
            [self moveStep:-1 from:i];
            return;
        case ATQHitStepDown:
            [self moveStep:1 from:i];
            return;
        case ATQHitStepRemove:
            [self removeStepAt:i];
            return;
        case ATQHitStepAdd:
            [self addStep];
            return;
        case ATQHitNewTab:
            _newTabOn = !_newTabOn;
            [self setNeedsDisplay:YES];
            return;
        case ATQHitRun:
            [self run:nil];
            return;
        case ATQHitOpen: {
            NSString *tab = h[@"tab"];
            if (!tab.length) return;
            NSString *args = [NSString stringWithFormat:@"{\"tab\":\"%@\"}", tab];
            char *out = NULL;
            at_control_call("tab.focus", args.UTF8String, &out);
            if (out) at_control_free(out);
            return;
        }
        case ATQHitDismiss: {
            NSString *dir = h[@"dir"];
            if (!dir.length) return;
            [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
            [self reload];
            return;
        }
        case ATQHitApprove: {
            NSString *dir = h[@"dir"];
            if (!dir.length) return;
            NSString *path = [dir stringByAppendingPathComponent:@"APPROVE"];
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [self reload];
            return;
        }
        default:
            break;
        }
        return;
    }
    [self.window makeFirstResponder:_field];
}

- (void)keyDown:(NSEvent *)event {
    NSWindowController *wc = self.window.windowController;
    if ([wc handleNavEvent:event]) return;
    [super keyDown:event];
}

@end
