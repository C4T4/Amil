#import "Queue.h"
#import "Agents.h"
#import "Keys.h"
#import "Theme.h"
#include "at_control.h"
#include "at_agents.h"
#include <string.h>

static const CGFloat kPad = 36;
static const CGFloat kRowH = 56;
static const CGFloat kBranchH = 40;
static const CGFloat kStageHeadH = 34;
static const CGFloat kAddRowH = 26;
static const CGFloat kStageGap = 10;
static const CGFloat kChipH = 26;
/* Right-hand controls of a branch row, measured in from the right edge. */
static const CGFloat kStepCtlW = 314;
/* Branches are indented so the parallel rail has somewhere to live. */
static const CGFloat kBranchIndent = 22;

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
    ATQHitBranchAdd,
    ATQHitStageName,
    ATQHitStageUp,
    ATQHitStageDown,
    ATQHitStageRemove,
    ATQHitStageFold,
    ATQHitStageAdd,
    ATQHitRun,
    ATQHitNewTab,
    ATQHitApprove,
    ATQHitDismiss,
    ATQHitOpen,
};

@interface ATQBranch : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *agent;
@end
@implementation ATQBranch
- (NSDictionary *)json {
    return @{
        @"name": self.name ?: @"do",
        @"kind": self.kind ?: @"agent",
        @"agent": self.agent ?: @"grok",
    };
}
+ (instancetype)from:(NSDictionary *)d {
    ATQBranch *b = [ATQBranch new];
    b.name = ([d[@"name"] isKindOfClass:[NSString class]] && [d[@"name"] length]) ? d[@"name"] : @"do";
    NSString *kind = d[@"kind"];
    b.kind = ([kind isKindOfClass:[NSString class]] && [kind isEqualToString:@"human"]) ? @"human" : @"agent";
    b.agent = ([d[@"agent"] isKindOfClass:[NSString class]] && [d[@"agent"] length]) ? d[@"agent"] : @"grok";
    return b;
}
+ (instancetype)named:(NSString *)name {
    ATQBranch *b = [ATQBranch new];
    b.name = name;
    b.kind = @"agent";
    b.agent = @"grok";
    return b;
}
@end

/* One stage, holding the branches that run at the same time. Sequential and
   parallel are not a switch: one branch is sequential, several are not. */
@interface ATQStage : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<ATQBranch *> *branches;
@property (nonatomic, assign) BOOL collapsed;
@end
@implementation ATQStage
- (NSDictionary *)json {
    NSMutableArray *bs = [NSMutableArray new];
    for (ATQBranch *b in self.branches) [bs addObject:[b json]];
    return @{ @"name": self.name ?: @"stage", @"branches": bs,
              @"collapsed": @(self.collapsed) };
}
+ (instancetype)from:(NSDictionary *)d {
    ATQStage *st = [ATQStage new];
    st.name = ([d[@"name"] isKindOfClass:[NSString class]] && [d[@"name"] length]) ? d[@"name"] : @"stage";
    st.collapsed = [d[@"collapsed"] isKindOfClass:[NSNumber class]] && [d[@"collapsed"] boolValue];
    st.branches = [NSMutableArray new];
    id arr = d[@"branches"];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (id x in arr) {
            if ([x isKindOfClass:[NSDictionary class]]) [st.branches addObject:[ATQBranch from:x]];
        }
    }
    if (!st.branches.count) [st.branches addObject:[ATQBranch named:@"do"]];
    return st;
}
+ (instancetype)named:(NSString *)name {
    ATQStage *st = [ATQStage new];
    st.name = name;
    st.branches = [NSMutableArray arrayWithObject:[ATQBranch named:name]];
    return st;
}
/* A v1 step is a stage with one branch. */
+ (instancetype)fromStep:(NSDictionary *)d {
    ATQBranch *b = [ATQBranch from:d];
    ATQStage *st = [ATQStage new];
    st.name = b.name;
    st.branches = [NSMutableArray arrayWithObject:b];
    return st;
}
@end

@interface ATQFlow : NSObject
@property (nonatomic, copy) NSString *fid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<ATQStage *> *stages;
@end
@implementation ATQFlow
- (NSDictionary *)json {
    NSMutableArray *st = [NSMutableArray new];
    for (ATQStage *s in self.stages) [st addObject:[s json]];
    return @{ @"id": self.fid ?: @"", @"name": self.name ?: @"Untitled",
              @"version": @2, @"stages": st };
}
+ (instancetype)from:(NSDictionary *)d pathId:(NSString *)pathId {
    ATQFlow *f = [ATQFlow new];
    f.fid = ([d[@"id"] isKindOfClass:[NSString class]] && [d[@"id"] length]) ? d[@"id"] : pathId;
    f.name = ([d[@"name"] isKindOfClass:[NSString class]] && [d[@"name"] length]) ? d[@"name"] : @"Untitled";
    f.stages = [NSMutableArray new];
    id stages = d[@"stages"];
    if ([stages isKindOfClass:[NSArray class]]) {
        for (id x in stages) {
            if ([x isKindOfClass:[NSDictionary class]]) [f.stages addObject:[ATQStage from:x]];
        }
    } else {
        /* v1 on disk: a flat step list. Read it as one stage per step and
           leave the file alone until the workflow is edited. */
        id steps = d[@"steps"];
        if ([steps isKindOfClass:[NSArray class]]) {
            for (id x in steps) {
                if ([x isKindOfClass:[NSDictionary class]]) [f.stages addObject:[ATQStage fromStep:x]];
            }
        }
    }
    if (!f.stages.count) [f.stages addObject:[ATQStage named:@"do"]];
    return f;
}
+ (instancetype)blank {
    ATQFlow *f = [ATQFlow new];
    f.fid = [[NSUUID UUID] UUIDString];
    f.name = @"Untitled";
    f.stages = [NSMutableArray arrayWithObject:[ATQStage named:@"do"]];
    return f;
}
/* Until branches run in parallel, a run is still a flat list of steps:
   every branch of every stage, in order. */
- (NSArray *)stepsJson {
    NSMutableArray *out = [NSMutableArray new];
    for (ATQStage *s in self.stages) {
        for (ATQBranch *b in s.branches) [out addObject:[b json]];
    }
    return out;
}
- (ATQBranch *)firstBranch {
    for (ATQStage *s in self.stages) {
        if (s.branches.count) return s.branches[0];
    }
    return nil;
}
- (NSUInteger)branchCount {
    NSUInteger n = 0;
    for (ATQStage *s in self.stages) n += s.branches.count;
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

- (CGFloat)heightOfStage:(ATQStage *)st {
    if (st.collapsed) return kStageHeadH;
    return kStageHeadH + st.branches.count * kBranchH + kAddRowH;
}

- (CGFloat)stagesHeight {
    CGFloat h = 0;
    for (ATQStage *st in _flow.stages) h += [self heightOfStage:st] + kStageGap;
    return h;
}

/* "+ stage" sits under the last card; the run bar under a rule below it. */
- (CGFloat)addStageTop {
    return [self stepsTop] + [self stagesHeight];
}

- (CGFloat)taskTop {
    return [self addStageTop] + kAddRowH + 26;
}

- (CGFloat)contentHeight {
    CGFloat y = [self taskTop] + 32 + 34 + 20;
    if (ATPipelineBlocked()) y += 24;
    y += MAX(_jobs.count, 1) * (kRowH + 8);
    return y + 40;
}

- (void)layout {
    [super layout];
    /* Document view of a scroll view: own the height, follow the clip width. */
    NSClipView *clip = self.enclosingScrollView.contentView;
    if (clip) {
        CGFloat cw = NSWidth(clip.bounds);
        CGFloat ch = MAX(NSHeight(clip.bounds), [self contentHeight]);
        if (fabs(NSWidth(self.frame) - cw) > 0.5 || fabs(NSHeight(self.frame) - ch) > 0.5) {
            self.frame = NSMakeRect(0, 0, cw, ch);
            [self setNeedsDisplay:YES];
        }
    }
    CGFloat w = NSWidth(self.bounds);
    _field.frame = NSMakeRect(kPad + 1, [self taskTop] + 1, w - kPad * 2 - 200, 30);
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
    if (!task.length || ![_flow branchCount]) {
        NSBeep();
        return;
    }
    /* Branches do not run side by side yet: a run is still every branch of
       every stage, in order. */
    ATQBranch *first = [_flow firstBranch];
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

- (ATQStage *)stageAt:(NSInteger)i {
    if (i < 0 || (NSUInteger)i >= _flow.stages.count) return nil;
    return _flow.stages[(NSUInteger)i];
}

- (ATQBranch *)branchAtStage:(NSInteger)si index:(NSInteger)bi {
    ATQStage *st = [self stageAt:si];
    if (!st || bi < 0 || (NSUInteger)bi >= st.branches.count) return nil;
    return st.branches[(NSUInteger)bi];
}

- (void)moveBranchAtStage:(NSInteger)si index:(NSInteger)bi by:(NSInteger)delta {
    ATQStage *st = [self stageAt:si];
    if (!st) return;
    NSInteger dest = bi + delta;
    if (bi < 0 || (NSUInteger)bi >= st.branches.count) return;
    if (dest < 0 || (NSUInteger)dest >= st.branches.count) return;
    ATQBranch *b = st.branches[(NSUInteger)bi];
    [st.branches removeObjectAtIndex:(NSUInteger)bi];
    [st.branches insertObject:b atIndex:(NSUInteger)dest];
    [self stepChanged];
}

/* Removing the last branch of a stage removes the stage: an empty stage
   would be a step that does nothing. */
- (void)removeBranchAtStage:(NSInteger)si index:(NSInteger)bi {
    ATQStage *st = [self stageAt:si];
    if (!st || bi < 0 || (NSUInteger)bi >= st.branches.count) return;
    if (st.branches.count == 1) {
        [self removeStageAt:si];
        return;
    }
    [st.branches removeObjectAtIndex:(NSUInteger)bi];
    [self stepChanged];
}

- (void)addBranchToStage:(NSInteger)si {
    ATQStage *st = [self stageAt:si];
    if (!st) return;
    [st.branches addObject:[ATQBranch named:[NSString stringWithFormat:@"branch %lu",
                                             (unsigned long)(st.branches.count + 1)]]];
    st.collapsed = NO;
    [self stepChanged];
}

- (void)moveStageAt:(NSInteger)si by:(NSInteger)delta {
    NSInteger dest = si + delta;
    if (si < 0 || (NSUInteger)si >= _flow.stages.count) return;
    if (dest < 0 || (NSUInteger)dest >= _flow.stages.count) return;
    ATQStage *st = _flow.stages[(NSUInteger)si];
    [_flow.stages removeObjectAtIndex:(NSUInteger)si];
    [_flow.stages insertObject:st atIndex:(NSUInteger)dest];
    [self stepChanged];
}

- (void)removeStageAt:(NSInteger)si {
    if (_flow.stages.count <= 1) {
        NSBeep();
        return;
    }
    if (si < 0 || (NSUInteger)si >= _flow.stages.count) return;
    [_flow.stages removeObjectAtIndex:(NSUInteger)si];
    [self stepChanged];
}

- (void)addStage {
    [_flow.stages addObject:[ATQStage named:[NSString stringWithFormat:@"stage %lu",
                                             (unsigned long)(_flow.stages.count + 1)]]];
    [self stepChanged];
}

/* The agent chip opens the real agent list rather than cycling blindly. */
- (void)pickAgentForStage:(NSInteger)si branch:(NSInteger)bi at:(NSPoint)p {
    ATQBranch *branch = [self branchAtStage:si index:bi];
    if (!branch) return;
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
        it.representedObject = @{ @"s": @(si), @"i": @(bi), @"id": aid };
        NSImage *img = ATAgentImage(aid);
        img.size = NSMakeSize(14, 14);
        it.image = img;
        it.state = [branch.agent isEqualToString:aid] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:it];
    }
    [menu popUpMenuPositioningItem:nil atLocation:p inView:self];
}

- (void)agentPicked:(NSMenuItem *)item {
    NSDictionary *d = item.representedObject;
    if (![d isKindOfClass:[NSDictionary class]]) return;
    ATQBranch *b = [self branchAtStage:[d[@"s"] integerValue] index:[d[@"i"] integerValue]];
    if (!b) return;
    b.agent = d[@"id"];
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
    for (NSUInteger si = 0; si < _flow.stages.count; si++) {
        ATQStage *stage = _flow.stages[si];
        CGFloat cardH = [self heightOfStage:stage];
        NSRect card = NSMakeRect(kPad, sy, w - kPad * 2, cardH);
        [[ATColorSurface() colorWithAlphaComponent:0.55] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:card xRadius:9 yRadius:9] fill];

        /* header ---------------------------------------------------- */
        CGFloat hy = sy + kStageHeadH / 2;
        NSString *idx = [NSString stringWithFormat:@"%lu", (unsigned long)(si + 1)];
        NSSize is = [idx sizeWithAttributes:metaA];
        [idx drawAtPoint:NSMakePoint(card.origin.x + 14, hy - is.height / 2) withAttributes:metaA];
        NSString *sname = stage.name.length ? stage.name : @"stage";
        NSSize ss = [sname sizeWithAttributes:titleA];
        NSRect snameR = NSMakeRect(card.origin.x + 34, sy, 260, kStageHeadH);
        [sname drawInRect:NSMakeRect(snameR.origin.x, hy - ss.height / 2, 260, ss.height)
           withAttributes:titleA];
        [self hit:ATQHitStageName s:(NSInteger)si i:0 rect:snameR];

        BOOL parallel = stage.branches.count > 1;
        BOOL human = stage.branches.count == 1 && [stage.branches[0].kind isEqualToString:@"human"];
        NSString *note = human ? @"human"
            : (parallel ? [NSString stringWithFormat:@"runs together · %lu branches",
                           (unsigned long)stage.branches.count]
                        : @"1 branch");
        if (stage.collapsed) {
            NSMutableArray *who = [NSMutableArray new];
            for (ATQBranch *b in stage.branches)
                [who addObject:[b.kind isEqualToString:@"human"] ? @"you" : ATAgentDisplayName(b.agent)];
            note = [NSString stringWithFormat:@"%@ · %@", note, [who componentsJoinedByString:@", "]];
        }
        NSSize ns = [note sizeWithAttributes:metaA];
        CGFloat noteRight = right - 108;
        [note drawAtPoint:NSMakePoint(noteRight - ns.width, hy - ns.height / 2) withAttributes:metaA];

        struct { NSString *g; ATQHit k; CGFloat off; } sctl[] = {
            { stage.collapsed ? @"›" : @"⌄", ATQHitStageFold, 96 },
            { @"↑", ATQHitStageUp, 70 },
            { @"↓", ATQHitStageDown, 46 },
            { @"×", ATQHitStageRemove, 22 },
        };
        for (int g = 0; g < 4; g++) {
            NSRect gr = NSMakeRect(right - sctl[g].off, hy - 11, 22, 22);
            NSSize gs = [sctl[g].g sizeWithAttributes:metaA];
            [sctl[g].g drawAtPoint:NSMakePoint(NSMidX(gr) - gs.width / 2, hy - gs.height / 2)
                    withAttributes:metaA];
            [self hit:sctl[g].k s:(NSInteger)si i:0 rect:gr];
        }
        if (stage.collapsed) {
            sy += cardH + kStageGap;
            continue;
        }

        /* the rail marks the branches that run at the same time ------ */
        CGFloat by = sy + kStageHeadH;
        if (parallel) {
            [[ATColorAccent() colorWithAlphaComponent:0.55] setFill];
            NSRectFill(NSMakeRect(card.origin.x + 20, by + 8,
                                  2, stage.branches.count * kBranchH - 16));
        }

        for (NSUInteger bi = 0; bi < stage.branches.count; bi++) {
            ATQBranch *b = stage.branches[bi];
            BOOL bhuman = [b.kind isEqualToString:@"human"];
            NSRect row = NSMakeRect(card.origin.x + kBranchIndent + 8, by,
                                    card.size.width - kBranchIndent - 16, kBranchH);
            CGFloat mid = NSMidY(row);

            NSString *nm = b.name.length ? b.name : @"do";
            CGFloat nameX = row.origin.x + 10;
            CGFloat nameW = MAX(70, right - kStepCtlW - 16 - nameX);
            NSRect nameR = NSMakeRect(nameX, row.origin.y, nameW, row.size.height);
            NSSize nsz = [nm sizeWithAttributes:titleA];
            [nm drawInRect:NSMakeRect(nameX, mid - nsz.height / 2, nameW, nsz.height)
            withAttributes:titleA];
            [self hit:ATQHitStepName s:(NSInteger)si i:(NSInteger)bi rect:nameR];

            struct { NSString *g; ATQHit k; CGFloat off; } bctl[] = {
                { @"×", ATQHitStepRemove, 22 },
                { @"↓", ATQHitStepDown, 46 },
                { @"↑", ATQHitStepUp, 70 },
            };
            for (int g = 0; g < 3; g++) {
                NSRect gr = NSMakeRect(right - bctl[g].off, mid - 11, 22, 22);
                NSSize gs = [bctl[g].g sizeWithAttributes:metaA];
                [bctl[g].g drawAtPoint:NSMakePoint(NSMidX(gr) - gs.width / 2, mid - gs.height / 2)
                        withAttributes:metaA];
                [self hit:bctl[g].k s:(NSInteger)si i:(NSInteger)bi rect:gr];
            }

            CGFloat pillW = 116, pillH = 24;
            NSRect pill = NSMakeRect(right - 70 - 12 - pillW, mid - pillH / 2, pillW, pillH);
            [[ATColorHair() colorWithAlphaComponent:0.7] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:12 yRadius:12] fill];
            NSRect live = NSMakeRect(bhuman ? NSMidX(pill) : pill.origin.x, pill.origin.y,
                                     pillW / 2, pillH);
            [ATColorAccent() setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(live, 2, 2) xRadius:10 yRadius:10] fill];
            NSString *labs[2] = { @"agent", @"human" };
            for (int h = 0; h < 2; h++) {
                BOOL lit = (h == 1) == bhuman;
                NSSize ls = [labs[h] sizeWithAttributes:metaA];
                CGFloat cx = pill.origin.x + pillW / 4 + (h ? pillW / 2 : 0);
                [labs[h] drawAtPoint:NSMakePoint(cx - ls.width / 2, mid - ls.height / 2)
                      withAttributes:lit ? onDarkMeta : metaA];
            }
            [self hit:ATQHitStepKind s:(NSInteger)si i:(NSInteger)bi rect:pill];

            if (!bhuman) {
                CGFloat chipW = 104, chipH = 24;
                NSRect chip = NSMakeRect(pill.origin.x - 12 - chipW, mid - chipH / 2, chipW, chipH);
                [[ATColorHair() colorWithAlphaComponent:0.7] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:6 yRadius:6] fill];
                NSImage *icon = ATAgentImage(b.agent);
                icon.size = NSMakeSize(13, 13);
                [icon drawInRect:NSMakeRect(chip.origin.x + 8, mid - 6.5, 13, 13)
                        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
                NSString *an = ATAgentDisplayName(b.agent);
                NSSize as = [an sizeWithAttributes:metaA];
                [an drawInRect:NSMakeRect(chip.origin.x + 27, mid - as.height / 2, chipW - 43, as.height)
                withAttributes:metaA];
                NSSize cs = [@"⌄" sizeWithAttributes:metaA];
                [@"⌄" drawAtPoint:NSMakePoint(NSMaxX(chip) - 8 - cs.width, mid - cs.height / 2 - 2)
                   withAttributes:metaA];
                [self hit:ATQHitStepAgent s:(NSInteger)si i:(NSInteger)bi rect:chip];
            }
            by += kBranchH;
        }

        NSRect addB = NSMakeRect(card.origin.x + kBranchIndent + 18, by, 86, kAddRowH - 4);
        NSSize abs_ = [@"+  branch" sizeWithAttributes:metaA];
        [@"+  branch" drawAtPoint:NSMakePoint(addB.origin.x, by + (kAddRowH - 4 - abs_.height) / 2)
                   withAttributes:metaA];
        [self hit:ATQHitBranchAdd s:(NSInteger)si i:0 rect:addB];
        sy += cardH + kStageGap;
    }

    CGFloat ay = [self addStageTop];
    NSRect addS = NSMakeRect(kPad, ay, 86, kAddRowH - 4);
    NSSize ads = [@"+  stage" sizeWithAttributes:metaA];
    [@"+  stage" drawAtPoint:NSMakePoint(kPad, ay + (kAddRowH - 4 - ads.height) / 2) withAttributes:metaA];
    [self hit:ATQHitStageAdd i:0 rect:addS];

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
        NSInteger sIdx = [h[@"s"] integerValue];
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
            ATQBranch *b = [self branchAtStage:sIdx index:i];
            if (!b) return;
            [self editIn:r text:b.name commit:^(NSString *name) {
                NSString *t = [name stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (t.length) b.name = t;
                [self saveCurrent];
            }];
            return;
        }
        case ATQHitStageName: {
            ATQStage *st = [self stageAt:sIdx];
            if (!st) return;
            [self editIn:r text:st.name commit:^(NSString *name) {
                NSString *t = [name stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (t.length) st.name = t;
                [self saveCurrent];
            }];
            return;
        }
        case ATQHitStepAgent:
            [self pickAgentForStage:sIdx branch:i at:NSMakePoint(r.origin.x, NSMaxY(r) + 2)];
            return;
        case ATQHitStepKind: {
            ATQBranch *b = [self branchAtStage:sIdx index:i];
            if (!b) return;
            b.kind = (p.x > NSMidX(r)) ? @"human" : @"agent";
            [self stepChanged];
            return;
        }
        case ATQHitStepUp:
            [self moveBranchAtStage:sIdx index:i by:-1];
            return;
        case ATQHitStepDown:
            [self moveBranchAtStage:sIdx index:i by:1];
            return;
        case ATQHitStepRemove:
            [self removeBranchAtStage:sIdx index:i];
            return;
        case ATQHitBranchAdd:
            [self addBranchToStage:sIdx];
            return;
        case ATQHitStageUp:
            [self moveStageAt:sIdx by:-1];
            return;
        case ATQHitStageDown:
            [self moveStageAt:sIdx by:1];
            return;
        case ATQHitStageRemove:
            [self removeStageAt:sIdx];
            return;
        case ATQHitStageFold: {
            ATQStage *st = [self stageAt:sIdx];
            if (!st) return;
            st.collapsed = !st.collapsed;
            [self stepChanged];
            return;
        }
        case ATQHitStageAdd:
            [self addStage];
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
