#import "Queue.h"
#import "Agents.h"
#import "Keys.h"
#import "Theme.h"
#include "at_control.h"
#include "at_agents.h"
#include <string.h>

static const CGFloat kPad = 36;
static const CGFloat kRowH = 56;
static const CGFloat kModelH = 40;
static const CGFloat kStepGap = 8;
static const CGFloat kAddRowH = 26;
static const CGFloat kChipH = 28;
/* Right-hand controls of a model line, measured in from the right edge. */
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
    ATQHitWorkflowMenu = 1,
    ATQHitWorkflowNew,
    ATQHitFlowName,
    ATQHitStepName,
    ATQHitStepUp,
    ATQHitStepDown,
    ATQHitStepRemove,
    ATQHitStepAdd,
    ATQHitModelAgent,
    ATQHitModelKind,
    ATQHitModelAdd,
    ATQHitModelRemove,
    ATQHitRun,
    ATQHitNewTab,
    ATQHitApprove,
    ATQHitDismiss,
    ATQHitOpen,
};

/* Who does a step. A step with more than one of these runs them at the
   same time; models have no names of their own, the step has the name. */
@interface ATQModel : NSObject
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *agent;
@end
@implementation ATQModel
- (NSDictionary *)json {
    return @{ @"kind": self.kind ?: @"agent", @"agent": self.agent ?: @"grok" };
}
+ (instancetype)from:(NSDictionary *)d {
    ATQModel *m = [ATQModel new];
    NSString *kind = d[@"kind"];
    m.kind = ([kind isKindOfClass:[NSString class]] && [kind isEqualToString:@"human"]) ? @"human" : @"agent";
    m.agent = ([d[@"agent"] isKindOfClass:[NSString class]] && [d[@"agent"] length]) ? d[@"agent"] : @"grok";
    return m;
}
+ (instancetype)agent:(NSString *)agent {
    ATQModel *m = [ATQModel new];
    m.kind = @"agent";
    m.agent = agent ?: @"grok";
    return m;
}
@end

@interface ATQStep : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<ATQModel *> *models;
@end
@implementation ATQStep
- (NSDictionary *)json {
    NSMutableArray *ms = [NSMutableArray new];
    for (ATQModel *m in self.models) [ms addObject:[m json]];
    return @{ @"name": self.name ?: @"do", @"models": ms };
}
+ (instancetype)from:(NSDictionary *)d {
    ATQStep *st = [ATQStep new];
    st.name = ([d[@"name"] isKindOfClass:[NSString class]] && [d[@"name"] length]) ? d[@"name"] : @"do";
    st.models = [NSMutableArray new];
    id arr = d[@"models"];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (id x in arr) {
            if ([x isKindOfClass:[NSDictionary class]]) [st.models addObject:[ATQModel from:x]];
        }
    } else {
        /* v1: the step carried one kind and one agent itself. */
        [st.models addObject:[ATQModel from:d]];
    }
    if (!st.models.count) [st.models addObject:[ATQModel agent:@"grok"]];
    return st;
}
+ (instancetype)named:(NSString *)name {
    ATQStep *st = [ATQStep new];
    st.name = name;
    st.models = [NSMutableArray arrayWithObject:[ATQModel agent:@"grok"]];
    return st;
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
    return @{ @"id": self.fid ?: @"", @"name": self.name ?: @"Untitled",
              @"version": @2, @"steps": st };
}
+ (instancetype)from:(NSDictionary *)d pathId:(NSString *)pathId {
    ATQFlow *f = [ATQFlow new];
    f.fid = ([d[@"id"] isKindOfClass:[NSString class]] && [d[@"id"] length]) ? d[@"id"] : pathId;
    f.name = ([d[@"name"] isKindOfClass:[NSString class]] && [d[@"name"] length]) ? d[@"name"] : @"Untitled";
    f.steps = [NSMutableArray new];
    id steps = d[@"steps"];
    if ([steps isKindOfClass:[NSArray class]]) {
        for (id x in steps) {
            if ([x isKindOfClass:[NSDictionary class]]) [f.steps addObject:[ATQStep from:x]];
        }
    } else if ([d[@"stages"] isKindOfClass:[NSArray class]]) {
        /* Short-lived shape that called a step a stage and a model a branch:
           one stage is one step, its branches are that step's models. */
        for (id x in d[@"stages"]) {
            if (![x isKindOfClass:[NSDictionary class]]) continue;
            ATQStep *st = [ATQStep new];
            st.name = ([x[@"name"] isKindOfClass:[NSString class]] && [x[@"name"] length])
                ? x[@"name"] : @"do";
            st.models = [NSMutableArray new];
            if ([x[@"branches"] isKindOfClass:[NSArray class]]) {
                for (id b in x[@"branches"]) {
                    if ([b isKindOfClass:[NSDictionary class]]) [st.models addObject:[ATQModel from:b]];
                }
            }
            if (!st.models.count) [st.models addObject:[ATQModel agent:@"grok"]];
            [f.steps addObject:st];
        }
    }
    if (!f.steps.count) [f.steps addObject:[ATQStep named:@"do"]];
    return f;
}
+ (instancetype)blankNumbered:(NSUInteger)n {
    ATQFlow *f = [ATQFlow new];
    f.fid = [[NSUUID UUID] UUIDString];
    f.name = n <= 1 ? @"Workflow" : [NSString stringWithFormat:@"Workflow %lu", (unsigned long)n];
    f.steps = [NSMutableArray arrayWithObject:[ATQStep named:@"do"]];
    return f;
}
- (NSArray *)stepsJson {
    NSMutableArray *out = [NSMutableArray new];
    for (ATQStep *s in self.steps) [out addObject:[s json]];
    return out;
}
- (NSUInteger)modelCount {
    NSUInteger n = 0;
    for (ATQStep *s in self.steps) n += s.models.count;
    return n;
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
    NSRect _nameRect;
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
    return 28 + 22 + kChipH + 20 + 22;
}

- (CGFloat)heightOfStep:(ATQStep *)st {
    return st.models.count * kModelH;
}

- (CGFloat)stepsHeight {
    CGFloat h = 0;
    for (ATQStep *st in _flow.steps) h += [self heightOfStep:st] + kStepGap;
    return h;
}

- (CGFloat)addStepTop {
    return [self stepsTop] + [self stepsHeight];
}

- (CGFloat)taskTop {
    return [self addStepTop] + kAddRowH + 26;
}

- (CGFloat)contentHeight {
    CGFloat y = [self taskTop] + 32 + 34 + 20;
    if (ATPipelineBlocked()) y += 24;
    y += MAX(_jobs.count, 1) * (kRowH + 8);
    return y + 40;
}

- (void)hit:(ATQHit)k i:(NSInteger)i rect:(NSRect)r {
    [self hit:k s:0 i:i rect:r];
}

- (void)hit:(ATQHit)k s:(NSInteger)stage i:(NSInteger)i rect:(NSRect)r {
    [_hits addObject:@{ @"k": @(k), @"s": @(stage), @"i": @(i),
                        @"r": [NSValue valueWithRect:r] }];
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
        ATQFlow *f = [ATQFlow blankNumbered:1];
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
    if (!task.length || ![_flow modelCount]) {
        NSBeep();
        return;
    }
    ATQModel *first = _flow.steps.firstObject.models.firstObject;
    NSDictionary *args = @{
        @"task": task,
        @"new_tab": @(_newTabOn),
        @"workflow": _flow.fid ?: @"",
        @"agent": first.agent ?: @"grok",
        @"steps": [_flow stepsJson],
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

- (ATQStep *)stepAt:(NSInteger)i {
    if (i < 0 || (NSUInteger)i >= _flow.steps.count) return nil;
    return _flow.steps[(NSUInteger)i];
}

- (ATQModel *)modelAtStep:(NSInteger)si index:(NSInteger)mi {
    ATQStep *st = [self stepAt:si];
    if (!st || mi < 0 || (NSUInteger)mi >= st.models.count) return nil;
    return st.models[(NSUInteger)mi];
}

- (void)moveStepAt:(NSInteger)si by:(NSInteger)delta {
    NSInteger dest = si + delta;
    if (si < 0 || (NSUInteger)si >= _flow.steps.count) return;
    if (dest < 0 || (NSUInteger)dest >= _flow.steps.count) return;
    ATQStep *st = _flow.steps[(NSUInteger)si];
    [_flow.steps removeObjectAtIndex:(NSUInteger)si];
    [_flow.steps insertObject:st atIndex:(NSUInteger)dest];
    [self stepChanged];
}

- (void)removeStepAt:(NSInteger)si {
    if (_flow.steps.count <= 1) {
        NSBeep();
        return;
    }
    if (si < 0 || (NSUInteger)si >= _flow.steps.count) return;
    [_flow.steps removeObjectAtIndex:(NSUInteger)si];
    [self stepChanged];
}

- (void)addStep {
    [_flow.steps addObject:[ATQStep named:[NSString stringWithFormat:@"step %lu",
                                           (unsigned long)(_flow.steps.count + 1)]]];
    [self stepChanged];
}

/* A second model on a step is what makes it parallel. */
- (void)addModelToStep:(NSInteger)si {
    ATQStep *st = [self stepAt:si];
    if (!st) return;
    [st.models addObject:[ATQModel agent:st.models.lastObject.agent ?: @"grok"]];
    [self stepChanged];
}

- (void)removeModelAtStep:(NSInteger)si index:(NSInteger)mi {
    ATQStep *st = [self stepAt:si];
    if (!st || mi < 0 || (NSUInteger)mi >= st.models.count) return;
    if (st.models.count == 1) {
        [self removeStepAt:si];
        return;
    }
    [st.models removeObjectAtIndex:(NSUInteger)mi];
    [self stepChanged];
}

- (void)pickAgentForStep:(NSInteger)si model:(NSInteger)mi at:(NSPoint)p {
    ATQModel *model = [self modelAtStep:si index:mi];
    if (!model) return;
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
        it.representedObject = @{ @"s": @(si), @"i": @(mi), @"id": aid };
        NSImage *img = ATAgentImage(aid);
        img.size = NSMakeSize(14, 14);
        it.image = img;
        it.state = [model.agent isEqualToString:aid] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:it];
    }
    [menu popUpMenuPositioningItem:nil atLocation:p inView:self];
}

- (void)agentPicked:(NSMenuItem *)item {
    NSDictionary *d = item.representedObject;
    if (![d isKindOfClass:[NSDictionary class]]) return;
    ATQModel *m = [self modelAtStep:[d[@"s"] integerValue] index:[d[@"i"] integerValue]];
    if (!m) return;
    m.agent = d[@"id"];
    m.kind = @"agent";
    [self stepChanged];
}

/* The workflow list is a menu, not a third row of tabs: the window already
   has workspace tabs and session tabs above this page. */
- (void)workflowMenuAt:(NSPoint)p {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Workflows"];
    for (NSUInteger i = 0; i < _flows.count; i++) {
        ATQFlow *f = _flows[i];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:(f.name.length ? f.name : @"Untitled")
                                                    action:@selector(workflowPicked:)
                                             keyEquivalent:@""];
        it.target = self;
        it.representedObject = @(i);
        it.state = (f == _flow) ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:it];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *ren = [[NSMenuItem alloc] initWithTitle:@"Rename…"
                                                 action:@selector(renameWorkflow:) keyEquivalent:@""];
    ren.target = self;
    [menu addItem:ren];
    NSMenuItem *del = [[NSMenuItem alloc] initWithTitle:@"Delete this workflow"
                                                 action:@selector(deleteWorkflow:) keyEquivalent:@""];
    del.target = self;
    del.enabled = _flows.count > 1;
    [menu addItem:del];
    [menu popUpMenuPositioningItem:nil atLocation:p inView:self];
}

- (void)workflowPicked:(NSMenuItem *)item {
    NSUInteger i = (NSUInteger)[item.representedObject integerValue];
    if (i >= _flows.count) return;
    _flow = _flows[i];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)renameWorkflow:(id)sender {
    (void)sender;
    ATQFlow *f = _flow;
    if (!f) return;
    [self editIn:_nameRect text:f.name commit:^(NSString *name) {
        NSString *t = [name stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) f.name = t;
        [self saveFlow:f];
    }];
}

- (void)deleteWorkflow:(id)sender {
    (void)sender;
    if (_flows.count <= 1) {
        NSBeep();
        return;
    }
    ATQFlow *f = _flow;
    NSString *path = [[ATSupport(@"workflows") stringByAppendingPathComponent:f.fid]
                      stringByAppendingPathExtension:@"json"];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [_flows removeObject:f];
    _flow = _flows.firstObject;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)newWorkflow {
    [self saveCurrent];
    ATQFlow *f = [ATQFlow blankNumbered:_flows.count + 1];
    [_flows addObject:f];
    _flow = f;
    [self saveFlow:f];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATColorBg() setFill];
    NSRectFill(self.bounds);
    [_hits removeAllObjects];
    CGFloat w = NSWidth(self.bounds);
    CGFloat right = w - kPad;
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

    CGFloat y = 28;
    [@"PIPELINE" drawAtPoint:NSMakePoint(kPad, y) withAttributes:self.headAttrs];
    y += 22;

    /* one workflow, named, with a menu for the rest */
    NSString *fname = _flow.name.length ? _flow.name : @"Untitled";
    NSSize fs = [fname sizeWithAttributes:titleA];
    CGFloat pickW = MIN(MAX(fs.width + 46, 160), 320);
    NSRect pick = NSMakeRect(kPad, y, pickW, kChipH);
    [[ATColorSurface() colorWithAlphaComponent:0.8] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pick xRadius:7 yRadius:7] fill];
    _nameRect = NSMakeRect(pick.origin.x + 10, y, pickW - 34, kChipH);
    [fname drawInRect:NSMakeRect(pick.origin.x + 12, NSMidY(pick) - fs.height / 2,
                                 pickW - 38, fs.height)
       withAttributes:titleA];
    NSSize cs = [@"⌄" sizeWithAttributes:metaA];
    [@"⌄" drawAtPoint:NSMakePoint(NSMaxX(pick) - 14 - cs.width / 2, NSMidY(pick) - cs.height / 2 - 2)
       withAttributes:metaA];
    [self hit:ATQHitWorkflowMenu i:0 rect:pick];

    NSString *newLab = @"+  new workflow";
    NSSize nls = [newLab sizeWithAttributes:metaA];
    NSRect newR = NSMakeRect(NSMaxX(pick) + 16, y, nls.width + 8, kChipH);
    [newLab drawAtPoint:NSMakePoint(newR.origin.x, NSMidY(newR) - nls.height / 2) withAttributes:metaA];
    [self hit:ATQHitWorkflowNew i:0 rect:newR];
    y += kChipH + 20;

    [@"STEPS" drawAtPoint:NSMakePoint(kPad, y) withAttributes:self.headAttrs];

    CGFloat sy = [self stepsTop];
    for (NSUInteger si = 0; si < _flow.steps.count; si++) {
        ATQStep *step = _flow.steps[si];
        BOOL together = step.models.count > 1;
        NSRect card = NSMakeRect(kPad, sy, w - kPad * 2, [self heightOfStep:step]);
        [[ATColorSurface() colorWithAlphaComponent:0.7] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:card xRadius:8 yRadius:8] fill];

        /* the rail says these models work on the step at the same time */
        if (together) {
            [[ATColorAccent() colorWithAlphaComponent:0.5] setFill];
            NSRectFill(NSMakeRect(card.origin.x + 112, sy + kModelH - 6,
                                  2, (step.models.count - 1) * kModelH - 8));
        }

        for (NSUInteger mi = 0; mi < step.models.count; mi++) {
            ATQModel *m = step.models[mi];
            BOOL human = [m.kind isEqualToString:@"human"];
            BOOL firstLine = (mi == 0);
            BOOL lastLine = (mi + 1 == step.models.count);
            CGFloat mid = sy + mi * kModelH + kModelH / 2;

            if (firstLine) {
                NSString *idx = [NSString stringWithFormat:@"%lu", (unsigned long)(si + 1)];
                NSSize is = [idx sizeWithAttributes:metaA];
                [idx drawAtPoint:NSMakePoint(card.origin.x + 14, mid - is.height / 2)
                  withAttributes:metaA];
                NSString *nm = step.name.length ? step.name : @"do";
                CGFloat nameX = card.origin.x + 36;
                CGFloat nameW = MAX(70, right - kStepCtlW - 16 - nameX);
                NSSize nsz = [nm sizeWithAttributes:titleA];
                [nm drawInRect:NSMakeRect(nameX, mid - nsz.height / 2, nameW, nsz.height)
                withAttributes:titleA];
                [self hit:ATQHitStepName s:(NSInteger)si i:0
                     rect:NSMakeRect(nameX, mid - kModelH / 2, nameW, kModelH)];
            } else if (mi == 1) {
                NSString *lab = @"at the same time";
                NSSize ls = [lab sizeWithAttributes:metaA];
                [lab drawAtPoint:NSMakePoint(card.origin.x + 36, mid - ls.height / 2)
                  withAttributes:metaA];
            }

            /* step controls on the first line, remove-this-model after it */
            if (firstLine) {
                struct { NSString *g; ATQHit k; CGFloat off; } ctl[] = {
                    { @"×", ATQHitStepRemove, 22 },
                    { @"↓", ATQHitStepDown, 46 },
                    { @"↑", ATQHitStepUp, 70 },
                };
                for (int g = 0; g < 3; g++) {
                    NSRect gr = NSMakeRect(right - ctl[g].off, mid - 11, 22, 22);
                    NSSize gs = [ctl[g].g sizeWithAttributes:metaA];
                    [ctl[g].g drawAtPoint:NSMakePoint(NSMidX(gr) - gs.width / 2, mid - gs.height / 2)
                           withAttributes:metaA];
                    [self hit:ctl[g].k s:(NSInteger)si i:0 rect:gr];
                }
            } else {
                NSRect gr = NSMakeRect(right - 22, mid - 11, 22, 22);
                NSSize gs = [@"×" sizeWithAttributes:metaA];
                [@"×" drawAtPoint:NSMakePoint(NSMidX(gr) - gs.width / 2, mid - gs.height / 2)
                   withAttributes:metaA];
                [self hit:ATQHitModelRemove s:(NSInteger)si i:(NSInteger)mi rect:gr];
            }

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
            [self hit:ATQHitModelKind s:(NSInteger)si i:(NSInteger)mi rect:pill];

            /* the + that makes a step parallel sits after the last model */
            CGFloat plusW = 24;
            NSRect plus = NSMakeRect(pill.origin.x - 12 - plusW, mid - 12, plusW, 24);
            if (lastLine) {
                [[ATColorHair() colorWithAlphaComponent:0.5] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:plus xRadius:6 yRadius:6] fill];
                NSSize ps = [@"+" sizeWithAttributes:metaA];
                [@"+" drawAtPoint:NSMakePoint(NSMidX(plus) - ps.width / 2, mid - ps.height / 2)
                   withAttributes:metaA];
                [self hit:ATQHitModelAdd s:(NSInteger)si i:0 rect:plus];
            }

            if (!human) {
                CGFloat chipW = 104, chipH = 24;
                NSRect chip = NSMakeRect(plus.origin.x - 10 - chipW, mid - chipH / 2, chipW, chipH);
                [[ATColorHair() colorWithAlphaComponent:0.7] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:6 yRadius:6] fill];
                NSImage *icon = ATAgentImage(m.agent);
                icon.size = NSMakeSize(13, 13);
                [icon drawInRect:NSMakeRect(chip.origin.x + 8, mid - 6.5, 13, 13)
                        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
                NSString *an = ATAgentDisplayName(m.agent);
                NSSize as = [an sizeWithAttributes:metaA];
                [an drawInRect:NSMakeRect(chip.origin.x + 27, mid - as.height / 2, chipW - 43, as.height)
                withAttributes:metaA];
                NSSize dcs = [@"⌄" sizeWithAttributes:metaA];
                [@"⌄" drawAtPoint:NSMakePoint(NSMaxX(chip) - 8 - dcs.width, mid - dcs.height / 2 - 2)
                   withAttributes:metaA];
                [self hit:ATQHitModelAgent s:(NSInteger)si i:(NSInteger)mi rect:chip];
            } else {
                NSString *you = @"you";
                NSSize ys = [you sizeWithAttributes:metaA];
                [you drawAtPoint:NSMakePoint(plus.origin.x - 10 - 104 + 8, mid - ys.height / 2)
                  withAttributes:metaA];
            }
        }
        sy += [self heightOfStep:step] + kStepGap;
    }

    CGFloat ay = [self addStepTop];
    NSRect addS = NSMakeRect(kPad, ay, 86, kAddRowH - 4);
    NSSize ads = [@"+  step" sizeWithAttributes:metaA];
    [@"+  step" drawAtPoint:NSMakePoint(kPad, ay + (kAddRowH - 4 - ads.height) / 2) withAttributes:metaA];
    [self hit:ATQHitStepAdd i:0 rect:addS];

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
        NSInteger sIdx = [h[@"s"] integerValue];
        switch (k) {
        case ATQHitWorkflowMenu:
            [self workflowMenuAt:NSMakePoint(r.origin.x, NSMaxY(r) + 2)];
            return;
        case ATQHitWorkflowNew:
            [self newWorkflow];
            return;
        case ATQHitFlowName:
            [self renameWorkflow:nil];
            return;
        case ATQHitStepName: {
            ATQStep *st = [self stepAt:sIdx];
            if (!st) return;
            [self editIn:r text:st.name commit:^(NSString *name) {
                NSString *t = [name stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (t.length) st.name = t;
                [self saveCurrent];
            }];
            return;
        }
        case ATQHitStepUp:
            [self moveStepAt:sIdx by:-1];
            return;
        case ATQHitStepDown:
            [self moveStepAt:sIdx by:1];
            return;
        case ATQHitStepRemove:
            [self removeStepAt:sIdx];
            return;
        case ATQHitStepAdd:
            [self addStep];
            return;
        case ATQHitModelAgent:
            [self pickAgentForStep:sIdx model:i at:NSMakePoint(r.origin.x, NSMaxY(r) + 2)];
            return;
        case ATQHitModelKind: {
            ATQModel *m = [self modelAtStep:sIdx index:i];
            if (!m) return;
            m.kind = (p.x > NSMidX(r)) ? @"human" : @"agent";
            [self stepChanged];
            return;
        }
        case ATQHitModelAdd:
            [self addModelToStep:sIdx];
            return;
        case ATQHitModelRemove:
            [self removeModelAtStep:sIdx index:i];
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
