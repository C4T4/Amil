#import "Queue.h"
#import "Agents.h"
#import "Keys.h"
#import "Theme.h"
#include "at_control.h"
#include "at_agents.h"
#include <string.h>

static const CGFloat kPad = 36;
static const CGFloat kRowH = 56;
static const CGFloat kStepH = 36;
static const CGFloat kChipH = 26;

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

static NSString *ATNextAgent(NSString *cur) {
    uint32_t n = at_agent_count();
    if (!n) return @"grok";
    uint32_t found = 0;
    const char *c = cur.UTF8String ?: "";
    for (uint32_t i = 0; i < n; i++) {
        if (strcmp(at_agent_at(i)->id, c) == 0) {
            found = i;
            break;
        }
    }
    return @(at_agent_at((found + 1) % n)->id);
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
    ATQHitStepAdd,
    ATQHitApprove,
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
@end

@implementation ATQueueView {
    NSTextField *_field;
    NSButton *_run;
    NSButton *_newTab;
    NSMutableArray<ATQFlow *> *_flows;
    ATQFlow *_flow;
    NSMutableArray<NSDictionary *> *_jobs;
    NSMutableArray<NSDictionary *> *_hits;
    NSTimer *_tick;
    NSTextField *_edit;
    void (^_editCommit)(NSString *);
    BOOL _editing;
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
    _run = [NSButton buttonWithTitle:@"Run" target:self action:@selector(run:)];
    _run.bezelStyle = NSBezelStyleRounded;
    [self addSubview:_run];
    _newTab = [NSButton checkboxWithTitle:@"New tab" target:nil action:nil];
    _newTab.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _newTab.contentTintColor = ATColorMuted();
    _newTab.state = NSControlStateValueOff;
    [self addSubview:_newTab];
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

- (CGFloat)chromeBottom {
    NSUInteger n = _flow.steps.count;
    return 28 + 22 + kChipH + 16 + 22 + n * kStepH + 28;
}

- (void)layout {
    [super layout];
    CGFloat y = [self chromeBottom] + 8;
    CGFloat w = NSWidth(self.bounds);
    _field.frame = NSMakeRect(kPad, y, w - kPad * 2 - 88 - 92, 28);
    _newTab.frame = NSMakeRect(w - kPad - 80 - 92, y, 88, 28);
    _run.frame = NSMakeRect(w - kPad - 80, y - 1, 80, 30);
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
    BOOL on = ATPipelineReady();
    _field.enabled = on;
    _run.enabled = on;
    _newTab.enabled = on;
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
        @"new_tab": @(_newTab.state == NSControlStateValueOn),
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
    if (n.object == _edit) [self finishEdit:YES];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATColorBg() setFill];
    NSRectFill(self.bounds);
    [_hits removeAllObjects];
    CGFloat w = NSWidth(self.bounds);
    CGFloat y = 28;
    [@"QUEUE" drawAtPoint:NSMakePoint(kPad, y) withAttributes:self.headAttrs];
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
        if (x + cw > w - kPad - 40) break;
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
    y += 20;
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
    NSArray<ATQStep *> *steps = _flow.steps;
    for (NSUInteger i = 0; i < steps.count; i++) {
        ATQStep *s = steps[i];
        NSRect row = NSMakeRect(kPad, y, w - kPad * 2, kStepH - 4);
        [[ATColorSurface() colorWithAlphaComponent:0.7] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:row xRadius:7 yRadius:7] fill];
        NSString *idx = [NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)];
        [idx drawAtPoint:NSMakePoint(row.origin.x + 10, y + 7) withAttributes:metaA];
        NSString *nm = s.name.length ? s.name : @"do";
        NSRect nameR = NSMakeRect(row.origin.x + 32, y, 180, kStepH - 4);
        [nm drawInRect:NSMakeRect(nameR.origin.x, y + 6, 176, 18) withAttributes:titleA];
        [self hit:ATQHitStepName i:(NSInteger)i rect:nameR];

        BOOL human = [s.kind isEqualToString:@"human"];
        if (!human) {
            NSString *ag = ATAgentDisplayName(s.agent);
            NSSize asz = [ag sizeWithAttributes:metaA];
            NSRect agR = NSMakeRect(row.origin.x + 220, y + 4, MAX(asz.width + 12, 56), 22);
            [[ATColorHair() colorWithAlphaComponent:0.8] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:agR xRadius:5 yRadius:5] fill];
            [ag drawAtPoint:NSMakePoint(agR.origin.x + 6, y + 8) withAttributes:metaA];
            [self hit:ATQHitStepAgent i:(NSInteger)i rect:agR];
        }

        NSString *klab = human ? @"human" : @"agent";
        NSSize ksz = [klab sizeWithAttributes:metaA];
        NSRect kR = NSMakeRect(NSMaxX(row) - 28 - ksz.width - 16, y + 4, ksz.width + 12, 22);
        if (human) [ATColorAccent() setFill];
        else [[ATColorHair() colorWithAlphaComponent:0.8] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:kR xRadius:5 yRadius:5] fill];
        NSDictionary *kattr = human
            ? @{ NSFontAttributeName: self.metaFont, NSForegroundColorAttributeName: ATColorBg() }
            : metaA;
        [klab drawAtPoint:NSMakePoint(kR.origin.x + 6, y + 8) withAttributes:kattr];
        [self hit:ATQHitStepKind i:(NSInteger)i rect:kR];

        NSRect rm = NSMakeRect(NSMaxX(row) - 22, y + 6, 16, 18);
        [@"×" drawAtPoint:NSMakePoint(rm.origin.x, y + 5) withAttributes:metaA];
        [self hit:ATQHitStepRemove i:(NSInteger)i rect:rm];
        y += kStepH;
    }
    NSRect add = NSMakeRect(kPad, y, 110, 24);
    [@"+  add step" drawAtPoint:NSMakePoint(add.origin.x + 2, y + 4) withAttributes:metaA];
    [self hit:ATQHitStepAdd i:0 rect:add];
    y = [self chromeBottom] + 48;

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
        int si = 0;
        if ([job[@"step"] isKindOfClass:[NSNumber class]]) si = [job[@"step"] intValue];
        else if ([job[@"step"] isKindOfClass:[NSString class]]) si = [job[@"step"] intValue];
        NSMutableString *pipe = [NSMutableString new];
        NSArray *sts = [job[@"steps"] isKindOfClass:[NSArray class]] ? job[@"steps"] : @[];
        if (!sts.count) [pipe appendString:@"(no steps)"];
        for (NSUInteger s = 0; s < sts.count; s++) {
            if (s) [pipe appendString:@" → "];
            NSString *name = @"step";
            if ([sts[s] isKindOfClass:[NSDictionary class]] && [sts[s][@"name"] isKindOfClass:[NSString class]])
                name = sts[s][@"name"];
            if ([st isEqualToString:@"done"]) [pipe appendFormat:@"[%@]", name];
            else if (s < (NSUInteger)si) [pipe appendFormat:@"[%@]", name];
            else if (s == (NSUInteger)si) [pipe appendFormat:@"{%@}", name];
            else [pipe appendString:name];
        }
        NSString *meta = [NSString stringWithFormat:@"%@ · %@", st, pipe];
        NSRect row = NSMakeRect(kPad, y, w - kPad * 2, kRowH);
        [[ATColorSurface() colorWithAlphaComponent:0.7] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:row xRadius:8 yRadius:8] fill];
        [task drawInRect:NSMakeRect(row.origin.x + 12, y + 10, row.size.width - 100, 20)
          withAttributes:titleA];
        [meta drawAtPoint:NSMakePoint(row.origin.x + 12, y + 32) withAttributes:metaA];
        if ([st isEqualToString:@"human"]) {
            NSString *lab = @"Approve";
            NSSize sz = [lab sizeWithAttributes:titleA];
            NSRect hit = NSMakeRect(NSMaxX(row) - sz.width - 20, y + (kRowH - 22) / 2.0, sz.width + 8, 22);
            [ATColorAccent() setFill];
            [[NSBezierPath bezierPathWithRoundedRect:hit xRadius:6 yRadius:6] fill];
            [lab drawAtPoint:NSMakePoint(hit.origin.x + 4, hit.origin.y + 2) withAttributes:onDark];
            [_hits addObject:@{
                @"k": @(ATQHitApprove),
                @"i": @0,
                @"r": [NSValue valueWithRect:hit],
                @"dir": job[@"dir"] ?: @"",
            }];
        }
        y += kRowH + 8;
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (_edit && !NSPointInRect(p, _edit.frame)) [self finishEdit:YES];
    for (NSDictionary *h in _hits) {
        NSRect r = [h[@"r"] rectValue];
        if (!NSPointInRect(p, r)) continue;
        ATQHit k = [h[@"k"] integerValue];
        NSInteger i = [h[@"i"] integerValue];
        switch (k) {
        case ATQHitWorkflow:
            [self saveCurrent];
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
                NSString *t = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (t.length) s.name = t;
                [self saveCurrent];
            }];
            return;
        }
        case ATQHitStepAgent: {
            if ((NSUInteger)i >= _flow.steps.count) return;
            ATQStep *s = _flow.steps[(NSUInteger)i];
            s.agent = ATNextAgent(s.agent);
            [self saveCurrent];
            [self setNeedsDisplay:YES];
            return;
        }
        case ATQHitStepKind: {
            if ((NSUInteger)i >= _flow.steps.count) return;
            ATQStep *s = _flow.steps[(NSUInteger)i];
            s.kind = [s.kind isEqualToString:@"human"] ? @"agent" : @"human";
            [self saveCurrent];
            [self setNeedsDisplay:YES];
            return;
        }
        case ATQHitStepRemove: {
            if (_flow.steps.count <= 1) {
                NSBeep();
                return;
            }
            if ((NSUInteger)i < _flow.steps.count) [_flow.steps removeObjectAtIndex:(NSUInteger)i];
            [self saveCurrent];
            [self setNeedsDisplay:YES];
            [self setNeedsLayout:YES];
            return;
        }
        case ATQHitStepAdd: {
            NSUInteger n = _flow.steps.count + 1;
            [_flow.steps addObject:[ATQStep agent:[NSString stringWithFormat:@"step %lu", (unsigned long)n]]];
            [self saveCurrent];
            [self setNeedsDisplay:YES];
            [self setNeedsLayout:YES];
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
