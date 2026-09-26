#import "TermView.h"
#import "Agents.h"
#import "Keys.h"
#import "Theme.h"
#include "at_control.h"

#include <util.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <sys/stat.h>
#include <spawn.h>
#include <uuid/uuid.h>
#include <libproc.h>
#include <sys/resource.h>

extern char **environ;

#include <ghostty/vt.h>

static BOOL ATIsUUID(NSString *s) {
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

NSString *ATMakeUUID(void) {
    uuid_t u;
    uuid_generate_random(u);
    char buf[37];
    uuid_unparse_lower(u, buf);
    return @(buf);
}

/* GUI apps get PATH=/usr/bin:/bin; agent CLIs live in ~/.local/bin and friends. */
static void ATPathAdd(NSMutableArray<NSString *> *dirs, NSMutableSet<NSString *> *seen, NSString *dir) {
    if (!dir.length || [seen containsObject:dir]) return;
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return;
    [seen addObject:dir];
    [dirs addObject:dir];
}

static NSString *ATChildPATH(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    NSString *home = NSHomeDirectory();
    for (NSString *rel in @[ @".local/bin", @".grok/bin", @".cargo/bin", @".asdf/shims", @".bun/bin" ]) {
        ATPathAdd(dirs, seen, [home stringByAppendingPathComponent:rel]);
    }
    NSString *nvmAlias = [NSString stringWithContentsOfFile:
                          [home stringByAppendingPathComponent:@".nvm/alias/default"]
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    nvmAlias = [nvmAlias stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (nvmAlias.length && ![nvmAlias containsString:@"/"]) {
        NSString *ver = [nvmAlias hasPrefix:@"v"] ? nvmAlias : [@"v" stringByAppendingString:nvmAlias];
        ATPathAdd(dirs, seen, [home stringByAppendingPathComponent:
            [NSString stringWithFormat:@".nvm/versions/node/%@/bin", ver]]);
    }
    ATPathAdd(dirs, seen, @"/opt/homebrew/bin");
    ATPathAdd(dirs, seen, @"/usr/local/bin");
    NSString *old = NSProcessInfo.processInfo.environment[@"PATH"];
    if (!old.length) old = @"/usr/bin:/bin:/usr/sbin:/sbin";
    for (NSString *d in [old componentsSeparatedByString:@":"]) {
        if (!d.length || [seen containsObject:d]) continue;
        [seen addObject:d];
        [dirs addObject:d];
    }
    return [dirs componentsJoinedByString:@":"];
}

static NSString *ATResolveCmd(NSString *cmd, NSString *path) {
    if (!cmd.length) return nil;
    if ([cmd hasPrefix:@"/"]) {
        return [[NSFileManager defaultManager] isExecutableFileAtPath:cmd] ? cmd : nil;
    }
    for (NSString *d in [path componentsSeparatedByString:@":"]) {
        if (!d.length) continue;
        NSString *cand = [d stringByAppendingPathComponent:cmd];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:cand]) return cand;
    }
    return nil;
}

static NSString *ATClaudeProjectDir(NSString *cwd) {
    NSMutableString *slug = [NSMutableString stringWithCapacity:cwd.length];
    for (NSUInteger i = 0; i < cwd.length; i++) {
        unichar ch = [cwd characterAtIndex:i];
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
            [slug appendFormat:@"%C", ch];
        } else {
            [slug appendString:@"-"];
        }
    }
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@".claude/projects/%@", slug]];
}

static pid_t ATLiveGrokPid(NSString *sessionId) {
    if (!ATIsUUID(sessionId)) return 0;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".grok/active_sessions.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return 0;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSArray class]]) return 0;
    pid_t found = 0;
    for (id row in json) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSString *sid = row[@"session_id"];
        NSNumber *pidn = row[@"pid"];
        if (![sid isEqualToString:sessionId] || !pidn) continue;
        pid_t pid = pidn.intValue;
        if (pid <= 1) continue;
        if (kill(pid, 0) == 0) found = pid;
    }
    return found;
}

static NSSet<NSString *> *ATLiveGrokSessions(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".grok/active_sessions.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return [NSSet set];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSArray class]]) return [NSSet set];
    NSMutableSet<NSString *> *live = [NSMutableSet new];
    for (id row in json) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSString *sid = row[@"session_id"];
        NSNumber *pid = row[@"pid"];
        if (!ATIsUUID(sid) || !pid) continue;
        if (kill(pid.intValue, 0) == 0) [live addObject:sid];
    }
    return live;
}

/* Another grok (Grok Bot, a leftover PTY, a previous aterminal) may already
   hold this session. A second --resume then paints a stale snapshot. */
static void ATStopPid(pid_t pid) {
    if (pid <= 1) return;
    kill(pid, SIGTERM);
    for (int i = 0; i < 10; i++) {
        if (kill(pid, 0) != 0) return;
        usleep(50000);
    }
    kill(pid, SIGKILL);
    usleep(30000);
}

static BOOL ATGrokSessionDirExists(NSString *sessionId) {
    if (!ATIsUUID(sessionId)) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@".grok/sessions"];
    NSArray<NSString *> *cwds = [fm contentsOfDirectoryAtPath:root error:nil];
    for (NSString *name in cwds) {
        NSString *dir = [[root stringByAppendingPathComponent:name]
                         stringByAppendingPathComponent:sessionId];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) return YES;
    }
    return NO;
}

static NSString *ATNewestUUIDInDir(NSString *dir, BOOL wantDir, NSSet<NSString *> *skip) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSString *best = nil;
    NSDate *bestDate = nil;
    for (NSString *name in items) {
        NSString *stem = name;
        NSString *path = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) continue;
        if (wantDir) {
            if (!isDir) continue;
        } else {
            if (isDir || ![name.pathExtension isEqualToString:@"jsonl"]) continue;
            stem = name.stringByDeletingPathExtension;
        }
        if (!ATIsUUID(stem)) continue;
        if (skip && [skip containsObject:stem]) continue;
        NSDate *d = [fm attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (!bestDate || [d compare:bestDate] == NSOrderedDescending) {
            bestDate = d;
            best = stem;
        }
    }
    return best;
}

static NSString *ATCodexIdFromName(NSString *name) {
    NSString *stem = name;
    if ([stem.pathExtension isEqualToString:@"zst"]) stem = stem.stringByDeletingPathExtension;
    if ([stem.pathExtension isEqualToString:@"jsonl"]) stem = stem.stringByDeletingPathExtension;
    if (stem.length < 36) return nil;
    NSString *sid = [stem substringFromIndex:stem.length - 36];
    return ATIsUUID(sid) ? sid : nil;
}

static BOOL ATFileMentionsCwd(NSString *path, NSString *cwd) {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) return NO;
    NSData *data = [h readDataOfLength:8192];
    [h closeFile];
    if (!data.length) return NO;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s && cwd.length && [s containsString:cwd];
}

static NSString *ATFindCodex(NSString *cwd, NSDate *since) {
    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@".codex/sessions"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSString *best = nil;
    NSDate *bestDate = nil;
    for (NSInteger delta = 0; delta <= 1; delta++) {
        NSDate *day = [cal dateByAddingUnit:NSCalendarUnitDay value:-delta toDate:[NSDate date] options:0];
        NSDateComponents *c = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:day];
        NSString *dir = [root stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%04ld/%02ld/%02ld",
                          (long)c.year, (long)c.month, (long)c.day]];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in items) {
            NSString *sid = ATCodexIdFromName(name);
            if (!sid) continue;
            NSString *path = [dir stringByAppendingPathComponent:name];
            NSDate *d = [fm attributesOfItemAtPath:path error:nil][NSFileModificationDate];
            if (since && d && [d compare:since] == NSOrderedAscending) continue;
            if (cwd.length && !ATFileMentionsCwd(path, cwd)) continue;
            if (!bestDate || [d compare:bestDate] == NSOrderedDescending) {
                bestDate = d;
                best = sid;
            }
        }
    }
    return best;
}

NSString *ATFindSessionId(NSString *command, NSString *cwd) {
    if (!command.length || !cwd.length) return nil;
    if ([command isEqualToString:@"claude"]) return ATNewestUUIDInDir(ATClaudeProjectDir(cwd), NO, nil);
    if ([command isEqualToString:@"grok"]) {
        NSString *enc = [cwd stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
        NSString *dir = [[NSHomeDirectory() stringByAppendingPathComponent:@".grok/sessions"]
                         stringByAppendingPathComponent:enc];
        return ATNewestUUIDInDir(dir, YES, ATLiveGrokSessions());
    }
    if ([command isEqualToString:@"codex"]) return ATFindCodex(cwd, nil);
    return nil;
}

BOOL ATSessionExists(NSString *command, NSString *cwd, NSString *sessionId) {
    if (!command.length || !sessionId.length) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([command isEqualToString:@"claude"]) {
        if (!cwd.length) return NO;
        NSString *path = [ATClaudeProjectDir(cwd) stringByAppendingPathComponent:
                          [sessionId stringByAppendingPathExtension:@"jsonl"]];
        return [fm fileExistsAtPath:path];
    }
    if ([command isEqualToString:@"grok"]) {
        if (cwd.length) {
            NSString *enc = [cwd stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
            NSString *dir = [[[NSHomeDirectory() stringByAppendingPathComponent:@".grok/sessions"]
                              stringByAppendingPathComponent:enc]
                             stringByAppendingPathComponent:sessionId];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) return YES;
        }
        return ATGrokSessionDirExists(sessionId);
    }
    return YES;
}

@interface ATTermView ()
@property (nonatomic, copy, readwrite) NSString *cwd;
@property (nonatomic, copy, readwrite) NSString *command;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *folders;
@property (nonatomic, copy, readwrite) NSString *workspaceName;
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, assign) BOOL resumeSession;
- (void)captureCodexSession;
- (void)spawn;
- (void)spawnIfReady;
- (void)ioctlWinsize;
- (void)beginFirstFrameHold;
- (void)flushFirstFrame;
- (void)signalKidsWinch;
- (BOOL)attachBackgroundPty;
- (BOOL)launchBackgroundHelperArgv:(char **)argv cwd:(char *)cwd_c path:(char *)path_c;
- (void)armPty;
- (BOOL)modeOn:(GhosttyMode)mode;
- (void)scrollToBottom;
- (BOOL)scrollbarTrack:(NSRect *)track thumb:(NSRect *)thumb sb:(GhosttyTerminalScrollbar *)sb;
- (void)sendWheelMouseRows:(intptr_t)rows at:(NSPoint)p;
- (BOOL)pasteClipboardImage;
@end

/* Body-hash changes (streaming, spinner, tool output) count as work.
   Idle TUI chrome — clock, cursor, status — does not. */
static const NSTimeInterval kATBusyWindow = 0.8;
/* How long after a resize to ignore output, since the agent is only repainting. */
static const NSTimeInterval kATRedrawGrace = 1.2;
/* After the user hits Return, show working at least this long so a
   footer-only thinking spinner is not missed. */
static const NSTimeInterval kATTurnFloor = 3.0;

@implementation ATTermView {
    int _master;
    pid_t _pid;
    pid_t _helperPid;
    dispatch_source_t _src;
    GhosttyTerminal _term;
    CGFloat _cw;
    CGFloat _ch;
    CTFontRef _font;
    CTFontRef _fontBold;
    CTFontRef _fontItalic;
    CTFontRef _fontBoldItalic;
    BOOL _focused;
    BOOL _got_output;
    BOOL _asksInput;
    NSTimeInterval _lastOutput;
    NSTimeInterval _quietUntil;
    NSTimeInterval _turnUntil;
    uint64_t _bodyHash;
    ATActivity _paintedActivity;
    uint16_t _cols;
    uint16_t _rows;
    BOOL _hasSel;
    BOOL _dragging;
    BOOL _ptyMouseDown;
    BOOL _sbDrag;
    BOOL _pinScrollCol;
    BOOL _sbDidMove;
    CGFloat _sbLastY;
    BOOL _pendingClick;
    NSPoint _downPoint;
    NSEventModifierFlags _downMods;
    int _downButton;
    int _selX0, _selY0, _selX1, _selY1;
    NSDate *_spawnAt;
    int _codexTries;
    CGFloat _scrollPending;
    NSTimer *_spawnDebounce;
    NSTimer *_holdTimer;
    NSMutableData *_holdBuf;
    BOOL _holdUntilFirstFrame;
}

static void at_write_pty(GhosttyTerminal terminal, void *userdata,
                         const uint8_t *data, size_t len) {
    (void)terminal;
    ATTermView *self = (__bridge ATTermView *)userdata;
    [self writeBytes:data length:len];
}

static bool at_size_report(GhosttyTerminal terminal, void *userdata,
                           GhosttySizeReportSize *out_size) {
    (void)terminal;
    ATTermView *self = (__bridge ATTermView *)userdata;
    out_size->rows = self->_rows;
    out_size->columns = self->_cols;
    out_size->cell_width = (uint32_t)self->_cw;
    out_size->cell_height = (uint32_t)self->_ch;
    return true;
}

static bool at_device_attributes(GhosttyTerminal terminal, void *userdata,
                                 GhosttyDeviceAttributes *out_attrs) {
    (void)terminal;
    (void)userdata;
    out_attrs->primary.conformance_level = GHOSTTY_DA_CONFORMANCE_VT220;
    out_attrs->primary.features[0] = GHOSTTY_DA_FEATURE_COLUMNS_132;
    out_attrs->primary.features[1] = GHOSTTY_DA_FEATURE_SELECTIVE_ERASE;
    out_attrs->primary.features[2] = GHOSTTY_DA_FEATURE_ANSI_COLOR;
    out_attrs->primary.num_features = 3;
    out_attrs->secondary.device_type = GHOSTTY_DA_DEVICE_TYPE_VT220;
    out_attrs->secondary.firmware_version = 1;
    out_attrs->secondary.rom_cartridge = 0;
    out_attrs->tertiary.unit_id = 0;
    return true;
}

- (instancetype)initWithCwd:(NSString *)cwd
                    command:(NSString *)command
                    folders:(NSArray<NSString *> *)folders
                  workspace:(NSString *)workspace
                    session:(NSString *)session
                     resume:(BOOL)resume {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    self.cwd = cwd;
    self.command = command;
    self.folders = folders ?: (cwd.length ? @[cwd] : @[]);
    self.workspaceName = workspace ?: @"";
    self.sessionId = session.length ? session : nil;
    self.resumeSession = resume && self.sessionId.length;
    self.wantsLayer = YES;
    self.layer.backgroundColor = ATColorBg().CGColor;
    _master = -1;
    _pid = -1;
    _helperPid = -1;
    _term = NULL;
    _font = CTFontCreateWithName(CFSTR("Menlo"), 13.0, NULL);
    if (!_font) _font = CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, 13.0, NULL);
    _cw = 8;
    _ch = 16;
    if (_font) {
        _ch = ceil(CTFontGetAscent(_font) + CTFontGetDescent(_font) + CTFontGetLeading(_font));
        UniChar sp = 'M';
        CGGlyph g;
        CGSize adv;
        CTFontGetGlyphsForCharacters(_font, &sp, &g, 1);
        CTFontGetAdvancesForGlyphs(_font, kCTFontOrientationHorizontal, &g, &adv, 1);
        if (adv.width > 0) _cw = adv.width;
        _fontBold = CTFontCreateCopyWithSymbolicTraits(_font, 0, NULL, kCTFontBoldTrait, kCTFontBoldTrait);
        _fontItalic = CTFontCreateCopyWithSymbolicTraits(_font, 0, NULL, kCTFontItalicTrait, kCTFontItalicTrait);
        _fontBoldItalic = CTFontCreateCopyWithSymbolicTraits(_font, 0, NULL,
            kCTFontBoldTrait | kCTFontItalicTrait, kCTFontBoldTrait | kCTFontItalicTrait);
    }
    [self registerForDraggedTypes:@[NSPasteboardTypePNG, NSPasteboardTypeTIFF, NSPasteboardTypeFileURL]];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

- (void)dealloc {
    [_spawnDebounce invalidate];
    _spawnDebounce = nil;
    [_holdTimer invalidate];
    _holdTimer = nil;
    [self killChild];
    if (_term) {
        ghostty_terminal_free(_term);
        _term = NULL;
    }
    if (_font) CFRelease(_font);
    if (_fontBold) CFRelease(_fontBold);
    if (_fontItalic) CFRelease(_fontItalic);
    if (_fontBoldItalic) CFRelease(_fontBoldItalic);
}

- (void)killChild {
    [_holdTimer invalidate];
    _holdTimer = nil;
    _holdUntilFirstFrame = NO;
    _holdBuf = nil;
    if (_src) {
        dispatch_source_cancel(_src);
        _src = nil;
    }
    pid_t child = _pid;
    pid_t helper = _helperPid;
    _pid = -1;
    _helperPid = -1;
    int master = _master;
    _master = -1;
    _asksInput = NO;
    if (helper > 0) kill(helper, SIGTERM);
    else if (child > 0) kill(child, SIGTERM);
    if (master >= 0) close(master);
    pid_t reap = helper > 0 ? helper : child;
    if (reap > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (kill(reap, 0) == 0) kill(reap, SIGKILL);
            waitpid(reap, NULL, WNOHANG);
        });
    }
}

static int ATRecvFd(int sock) {
    char dummy = 0;
    struct iovec iov = { .iov_base = &dummy, .iov_len = 1 };
    char buf[CMSG_SPACE(sizeof(int))];
    memset(buf, 0, sizeof(buf));
    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = buf;
    msg.msg_controllen = sizeof(buf);
    if (recvmsg(sock, &msg, 0) < 0) return -1;
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    if (!c || c->cmsg_type != SCM_RIGHTS) return -1;
    int fd = -1;
    memcpy(&fd, CMSG_DATA(c), sizeof(int));
    return fd;
}

static NSString *ATPtySockPath(NSString *paneId) {
    if (!paneId.length) return nil;
    NSString *dir = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ATerminal"]
                     stringByAppendingPathComponent:@"pty"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0700}
                                                    error:nil];
    return [dir stringByAppendingPathComponent:[paneId stringByAppendingString:@".sock"]];
}

static pid_t ATPtyReadPid(NSString *sock) {
    NSString *p = [sock stringByAppendingString:@".pid"];
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return -1;
    int v = atoi(s.UTF8String);
    if (v <= 1) return -1;
    if (kill(v, 0) != 0) return -1;
    return v;
}

static NSString *ATPtyHelperPath(void) {
    NSString *here = [NSBundle mainBundle].executablePath.stringByDeletingLastPathComponent;
    NSString *p = [here stringByAppendingPathComponent:@"at-pty"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    return nil;
}

static uint64_t at_pid_footprint(pid_t pid) {
    if (pid <= 0) return 0;
    struct rusage_info_v4 ru;
    memset(&ru, 0, sizeof(ru));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t)&ru) != 0) return 0;
    return ru.ri_phys_footprint;
}

- (uint64_t)childFootprint {
    if (_pid <= 0) return 0;
    pid_t stack[256];
    int sp = 0;
    stack[sp++] = _pid;
    uint64_t sum = 0;
    int seen = 0;
    while (sp > 0 && seen < 256) {
        pid_t p = stack[--sp];
        sum += at_pid_footprint(p);
        seen++;
        pid_t kids[64];
        int nbytes = proc_listchildpids(p, kids, (int)sizeof(kids));
        if (nbytes <= 0) continue;
        int n = nbytes / (int)sizeof(pid_t);
        for (int i = 0; i < n && sp < 256; i++) {
            if (kids[i] > 1) stack[sp++] = kids[i];
        }
    }
    return sum;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self spawnIfReady];
    if (_pid > 0 || _master >= 0) [self resizeGrid];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [self.window layoutIfNeeded];
        [self spawnIfReady];
        if (_pid > 0 || _master >= 0) [self resizeGrid];
    }
}

- (void)spawnIfReady {
    if (_pid > 0 || _master >= 0) return;
    if (!self.window || !self.superview) return;
    NSSize s = self.bounds.size;
    if (s.width < 160 || s.height < 80) return;
    [_spawnDebounce invalidate];
    __weak ATTermView *weak = self;
    _spawnDebounce = [NSTimer scheduledTimerWithTimeInterval:0.12
                                                     repeats:NO
                                                       block:^(NSTimer *t) {
        (void)t;
        ATTermView *ss = weak;
        if (!ss) return;
        ss->_spawnDebounce = nil;
        if (ss->_pid > 0 || ss->_master >= 0) return;
        if (!ss.window || !ss.superview) return;
        NSSize now = ss.bounds.size;
        if (now.width < 160 || now.height < 80) return;
        [ss spawn];
    }];
}

- (void)resizeGrid {
    int cols = (int)((self.bounds.size.width - 12) / _cw);
    int rows = (int)((self.bounds.size.height - 8) / _ch);
    if (cols < 8) cols = 8;
    if (rows < 4) rows = 4;
    if (cols > 512) cols = 512;
    if (rows > 256) rows = 256;
    BOOL same = (_cols == (uint16_t)cols && _rows == (uint16_t)rows);
    _cols = (uint16_t)cols;
    _rows = (uint16_t)rows;
    if (_term) {
        ghostty_terminal_resize(_term, _cols, _rows, (uint32_t)_cw, (uint32_t)_ch);
    }
    if (_master >= 0 && !same) {
        [self ioctlWinsize];
        /* SIGWINCH makes the agent repaint its whole UI. That is real pty
           output but it is not work, so it must not read as activity. */
        _quietUntil = NSDate.timeIntervalSinceReferenceDate + kATRedrawGrace;
    }
    [self.window invalidateCursorRectsForView:self];
    [self setNeedsDisplay:YES];
}

- (void)ioctlWinsize {
    if (_master < 0) return;
    struct winsize ws = {
        .ws_col = _cols,
        .ws_row = _rows,
        .ws_xpixel = (unsigned short)(_cols * _cw),
        .ws_ypixel = (unsigned short)(_rows * _ch),
    };
    ioctl(_master, TIOCSWINSZ, &ws);
}

- (void)signalKidsWinch {
    pid_t root = _helperPid > 0 ? _helperPid : _pid;
    if (root <= 0) return;
    pid_t stack[256];
    int sp = 0;
    stack[sp++] = root;
    while (sp > 0) {
        pid_t p = stack[--sp];
        if (p > 1) kill(p, SIGWINCH);
        pid_t kids[64];
        int nbytes = proc_listchildpids(p, kids, (int)sizeof(kids));
        if (nbytes <= 0) continue;
        int n = nbytes / (int)sizeof(pid_t);
        for (int i = 0; i < n && sp < 256; i++) {
            if (kids[i] > 1) stack[sp++] = kids[i];
        }
    }
}

- (void)beginFirstFrameHold {
    _holdUntilFirstFrame = YES;
    _got_output = NO;
    _holdBuf = [NSMutableData data];
    [_holdTimer invalidate];
    __weak ATTermView *weak = self;
    _holdTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                 repeats:NO
                                                   block:^(NSTimer *t) {
        (void)t;
        [weak flushFirstFrame];
    }];
}

- (void)flushFirstFrame {
    _holdTimer = nil;
    if (!_holdUntilFirstFrame) return;
    if (_holdBuf.length == 0) {
        [self signalKidsWinch];
        __weak ATTermView *weak = self;
        _holdTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                     repeats:NO
                                                       block:^(NSTimer *t) {
            (void)t;
            ATTermView *ss = weak;
            if (!ss) return;
            ss->_holdUntilFirstFrame = NO;
            if (ss->_holdBuf.length && ss->_term) {
                ghostty_terminal_vt_write(ss->_term, ss->_holdBuf.bytes, ss->_holdBuf.length);
                ss->_got_output = YES;
            }
            ss->_holdBuf = nil;
            [ss setNeedsDisplay:YES];
        }];
        return;
    }
    if (_term)
        ghostty_terminal_vt_write(_term, _holdBuf.bytes, _holdBuf.length);
    _got_output = YES;
    _holdUntilFirstFrame = NO;
    _holdBuf = nil;
    _quietUntil = NSDate.timeIntervalSinceReferenceDate + kATRedrawGrace;
    [self setNeedsDisplay:YES];
}

- (BOOL)attachBackgroundPty {
    NSString *sockPath = ATPtySockPath(self.paneId);
    if (!sockPath.length) return NO;
    pid_t helper = ATPtyReadPid(sockPath);
    if (helper <= 0) return NO;
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) return NO;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *p = sockPath.fileSystemRepresentation;
    size_t n = strlen(p);
    if (n >= sizeof(addr.sun_path)) {
        close(s);
        return NO;
    }
    memcpy(addr.sun_path, p, n + 1);
    addr.sun_len = (unsigned char)(2 + n + 1);
    if (connect(s, (struct sockaddr *)&addr, addr.sun_len) != 0) {
        close(s);
        return NO;
    }
    int fd = ATRecvFd(s);
    close(s);
    if (fd < 0) return NO;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    _master = fd;
    _helperPid = helper;
    _pid = helper;
    return YES;
}

- (BOOL)launchBackgroundHelperArgv:(char **)argv cwd:(char *)cwd_c path:(char *)path_c {
    (void)cwd_c;
    NSString *helper = ATPtyHelperPath();
    NSString *sockPath = ATPtySockPath(self.paneId);
    if (!helper.length || !sockPath.length || !argv || !argv[0]) return NO;
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:helper,
        @"--cwd", self.cwd.length ? self.cwd : @"/",
        @"--sock", sockPath,
        @"--cols", [NSString stringWithFormat:@"%u", _cols],
        @"--rows", [NSString stringWithFormat:@"%u", _rows],
        @"--", nil];
    for (char **a = argv; *a; a++) [args addObject:@(*a)];
    const char **cargv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) cargv[i] = strdup(args[i].fileSystemRepresentation);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    const char *old_path = getenv("PATH");
    if (path_c) setenv("PATH", path_c, 1);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, helper.fileSystemRepresentation, NULL, &attr, (char **)cargv, environ);
    if (old_path) setenv("PATH", old_path, 1);
    posix_spawnattr_destroy(&attr);
    for (NSUInteger i = 0; i < args.count; i++) free((void *)cargv[i]);
    free(cargv);
    if (rc != 0 || pid <= 0) return NO;
    for (int i = 0; i < 40; i++) {
        usleep(50000);
        if (ATPtyReadPid(sockPath) > 0) return YES;
    }
    return ATPtyReadPid(sockPath) > 0;
}

- (void)armPty {
    if (_master < 0) return;
    dispatch_queue_t q = dispatch_get_main_queue();
    _src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_master, 0, q);
    __weak ATTermView *weak = self;
    dispatch_source_set_event_handler(_src, ^{ [weak onPTY]; });
    dispatch_resume(_src);
    [self beginFirstFrameHold];
    [self setNeedsDisplay:YES];
}

- (void)spawn {
    [self resizeGrid];
    if (ghostty_terminal_new(NULL, &_term, _cols, _rows) != GHOSTTY_SUCCESS) {
        _term = NULL;
        return;
    }
    static const GhosttyColorRgb kAnsi[16] = {
        {28, 29, 32}, {196, 122, 118}, {138, 176, 142}, {210, 176, 112},
        {122, 154, 184}, {176, 142, 168}, {126, 176, 168}, {200, 196, 188},
        {92, 88, 84}, {220, 150, 144}, {166, 204, 168}, {228, 200, 140},
        {154, 180, 206}, {204, 170, 196}, {158, 204, 196}, {236, 232, 224},
    };
    GhosttyColorRgb bg = {14, 15, 16};
    GhosttyColorRgb fg = {214, 211, 204};
    GhosttyColorRgb cur = {196, 165, 116};
    GhosttyColorRgb pal[256];
    ghostty_color_palette_default(pal);
    for (int i = 0; i < 16; i++) pal[i] = kAnsi[i];
    GhosttyColorPaletteMask skip = {0};
    for (int i = 0; i < 16; i++) GHOSTTY_COLOR_PALETTE_MASK_SET(&skip, i);
    ghostty_color_palette_generate(pal, &skip, &bg, &fg, true, pal);
    ghostty_terminal_set(_term, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg);
    ghostty_terminal_set(_term, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg);
    ghostty_terminal_set(_term, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cur);
    ghostty_terminal_set(_term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, pal);
    size_t scrollback = 10000;
    ghostty_terminal_set(_term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback);
    ghostty_terminal_resize(_term, _cols, _rows, (uint32_t)_cw, (uint32_t)_ch);
    void *ud = (__bridge void *)self;
    ghostty_terminal_set(_term, GHOSTTY_TERMINAL_OPT_USERDATA, ud);
    ghostty_terminal_set(_term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)at_write_pty);
    ghostty_terminal_set(_term, GHOSTTY_TERMINAL_OPT_SIZE, (const void *)at_size_report);
    ghostty_terminal_set(_term, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, (const void *)at_device_attributes);

    NSArray<NSString *> *folders = self.folders ?: @[];
    char *cwd_c = self.cwd.length ? strdup(self.cwd.fileSystemRepresentation) : NULL;
    char *ws_c = self.workspaceName.length ? strdup(self.workspaceName.UTF8String) : NULL;
    char *folders_joined = folders.count
        ? strdup([folders componentsJoinedByString:@"\n"].UTF8String)
        : NULL;
    char **folder_cs = calloc(folders.count, sizeof(char *));
    for (NSUInteger i = 0; i < folders.count; i++) {
        folder_cs[i] = strdup(folders[i].fileSystemRepresentation);
    }
    BOOL claude = [self.command isEqualToString:@"claude"];
    BOOL grok = [self.command isEqualToString:@"grok"];
    BOOL gemini = [self.command isEqualToString:@"gemini"];
    BOOL codex = [self.command isEqualToString:@"codex"];
    BOOL addDirs = claude || grok || gemini || codex;
    NSString *sid = self.sessionId;
    BOOL resume = self.resumeSession && sid.length;
    if (sid.length && grok && ATSessionExists(@"grok", self.cwd, sid)) resume = YES;
    if (resume && grok) {
        pid_t other = ATLiveGrokPid(sid);
        if (other > 0) ATStopPid(other);
    }
    BOOL pinNew = !resume && sid.length && (claude || grok || gemini);
    NSUInteger extra = (resume || pinNew) ? 2 : 0;
    NSArray<NSString *> *agentFlags = ATAgentFlagsForCommand(self.command);
    NSUInteger argc = 1 + extra + agentFlags.count;
    if (addDirs && folders.count > 1) argc += (folders.count - 1) * 2;
    char **argv = NULL;
    char *cmd_c = self.command.length ? strdup(self.command.fileSystemRepresentation) : NULL;
    NSString *childPath = ATChildPATH();
    char *path_c = childPath.length ? strdup(childPath.UTF8String) : NULL;
    NSString *resolved = ATResolveCmd(self.command, childPath);
    char *exe_c = resolved.length ? strdup(resolved.fileSystemRepresentation) : NULL;
    if (cmd_c) {
        argv = calloc(argc + 1, sizeof(char *));
        argv[0] = cmd_c;
        NSUInteger ai = 1;
        if (resume) {
            if (codex) {
                argv[ai++] = strdup("resume");
                argv[ai++] = strdup(sid.UTF8String);
            } else {
                argv[ai++] = strdup("--resume");
                argv[ai++] = strdup(sid.UTF8String);
            }
        } else if (pinNew) {
            argv[ai++] = strdup("--session-id");
            argv[ai++] = strdup(sid.UTF8String);
        }
        if (addDirs) {
            for (NSUInteger i = 1; i < folders.count; i++) {
                argv[ai++] = strdup("--add-dir");
                argv[ai++] = strdup(folder_cs[i] ? folder_cs[i] : "");
            }
        }
        for (NSString *f in agentFlags) argv[ai++] = strdup(f.UTF8String);
    }

    BOOL useBg = at_control_background_on() && self.paneId.length && ATPtyHelperPath().length;
    if (useBg && [self attachBackgroundPty]) {
        if (cwd_c) free(cwd_c);
        if (ws_c) free(ws_c);
        if (folders_joined) free(folders_joined);
        if (path_c) free(path_c);
        if (exe_c) free(exe_c);
        if (argv) {
            for (NSUInteger i = 1; i < argc; i++) free(argv[i]);
            free(argv);
        }
        free(cmd_c);
        for (NSUInteger i = 0; i < folders.count; i++) free(folder_cs[i]);
        free(folder_cs);
        [self armPty];
        [self signalKidsWinch];
        return;
    }
    if (useBg && argv && [self launchBackgroundHelperArgv:argv cwd:cwd_c path:path_c] &&
        [self attachBackgroundPty]) {
        if (cwd_c) free(cwd_c);
        if (ws_c) free(ws_c);
        if (folders_joined) free(folders_joined);
        if (path_c) free(path_c);
        if (exe_c) free(exe_c);
        if (argv) {
            for (NSUInteger i = 1; i < argc; i++) free(argv[i]);
            free(argv);
        }
        free(cmd_c);
        for (NSUInteger i = 0; i < folders.count; i++) free(folder_cs[i]);
        free(folder_cs);
        [self armPty];
        return;
    }

    struct winsize ws = { .ws_col = _cols, .ws_row = _rows };
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        free(cwd_c); free(ws_c); free(folders_joined); free(cmd_c);
        free(path_c); free(exe_c);
        if (argv) {
            for (NSUInteger i = 1; i < argc; i++) free(argv[i]);
            free(argv);
        }
        for (NSUInteger i = 0; i < folders.count; i++) free(folder_cs[i]);
        free(folder_cs);
        return;
    }
    if (pid == 0) {
        if (cwd_c && cwd_c[0]) chdir(cwd_c);
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("LANG", "en_US.UTF-8", 1);
        if (path_c) setenv("PATH", path_c, 1);
        if (ws_c) setenv("ATERMINAL_WORKSPACE", ws_c, 1);
        if (cwd_c) setenv("ATERMINAL_CWD", cwd_c, 1);
        if (folders_joined) setenv("ATERMINAL_FOLDERS", folders_joined, 1);
        for (NSUInteger i = 0; i < folders.count; i++) {
            char key[32];
            snprintf(key, sizeof(key), "ATERMINAL_FOLDER_%lu", (unsigned long)i);
            if (folder_cs[i]) setenv(key, folder_cs[i], 1);
        }
        if (argv) {
            if (exe_c) execv(exe_c, argv);
            else if (cmd_c) execvp(cmd_c, argv);
            dprintf(STDERR_FILENO, "aterminal: %s: %s\n",
                    exe_c ? exe_c : cmd_c, strerror(errno));
        } else {
            const char *shell = getenv("SHELL");
            if (!shell || !shell[0]) shell = "/bin/zsh";
            execl(shell, shell, "-l", (char *)NULL);
        }
        _exit(127);
    }
    free(cwd_c); free(ws_c); free(folders_joined); free(path_c); free(exe_c);
    if (argv) {
        for (NSUInteger i = 1; i < argc; i++) free(argv[i]);
        free(argv);
    }
    free(cmd_c);
    for (NSUInteger i = 0; i < folders.count; i++) free(folder_cs[i]);
    free(folder_cs);
    _master = master;
    _pid = pid;
    int flags = fcntl(master, F_GETFL, 0);
    fcntl(master, F_SETFL, flags | O_NONBLOCK);
    [self armPty];
    if (codex && !self.sessionId.length) {
        _spawnAt = [NSDate date];
        _codexTries = 0;
        [self captureCodexSession];
    }
}

- (void)captureCodexSession {
    if (self.sessionId.length || _pid <= 0) return;
    if (_codexTries > 8) return;
    _codexTries += 1;
    __weak ATTermView *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ATTermView *self = weak;
        if (!self || self.sessionId.length) return;
        NSString *sid = ATFindCodex(self.cwd, self->_spawnAt);
        if (sid.length) {
            self.sessionId = sid;
            if (self.onSession) self.onSession(sid);
            return;
        }
        [self captureCodexSession];
    });
}

/* Hash visible conversation cells, skipping header/footer chrome so a
   clock or caret blink does not look like the agent working. */
static uint64_t ATViewportBodyHash(GhosttyTerminal term, uint16_t cols, uint16_t rows) {
    if (!term || cols == 0 || rows == 0) return 0;
    uint16_t y0 = rows > 8 ? 1 : 0;
    uint16_t y1 = rows > 6 ? (uint16_t)(rows - 2) : rows;
    uint64_t h = 1469598103934665603ull;
    for (uint16_t row = y0; row < y1; row++) {
        for (uint16_t col = 0; col < cols; col++) {
            GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
            GhosttyPoint pt = {
                .tag = GHOSTTY_POINT_TAG_VIEWPORT,
                .value = { .coordinate = { .x = col, .y = row } },
            };
            uint32_t cp = 32;
            if (ghostty_terminal_grid_ref(term, pt, &ref) == GHOSTTY_SUCCESS) {
                GhosttyCell gcell;
                if (ghostty_grid_ref_cell(&ref, &gcell) == GHOSTTY_SUCCESS) {
                    bool has_text = false;
                    ghostty_cell_get(gcell, GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);
                    if (has_text) ghostty_cell_get(gcell, GHOSTTY_CELL_DATA_CODEPOINT, &cp);
                }
            }
            h ^= (uint64_t)cp + (uint64_t)col + ((uint64_t)row << 16);
            h *= 1099511628211ull;
        }
    }
    return h;
}

/* Permission prompts and AskUserQuestion forms (Enter to select / Allow once).
   Idle chat prompt must not match. Whitespace is collapsed so padded TUI
   labels still hit. */
static BOOL ATViewportAsksInput(GhosttyTerminal term, uint16_t cols, uint16_t rows) {
    if (!term || cols == 0 || rows == 0) return NO;
    uint16_t tcols = cols, trows = rows;
    ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &tcols);
    ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ROWS, &trows);
    if (tcols == 0 || trows == 0) return NO;
    char raw[16384];
    size_t n = 0;
    int space = 1;
    for (uint16_t row = 0; row < trows && n + 2 < sizeof(raw); row++) {
        for (uint16_t col = 0; col < tcols && n + 2 < sizeof(raw); col++) {
            GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
            GhosttyPoint pt = {
                .tag = GHOSTTY_POINT_TAG_VIEWPORT,
                .value = { .coordinate = { .x = col, .y = row } },
            };
            uint32_t cp = 0;
            if (ghostty_terminal_grid_ref(term, pt, &ref) == GHOSTTY_SUCCESS) {
                GhosttyCell gcell;
                if (ghostty_grid_ref_cell(&ref, &gcell) == GHOSTTY_SUCCESS) {
                    bool has_text = false;
                    ghostty_cell_get(gcell, GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);
                    if (has_text) ghostty_cell_get(gcell, GHOSTTY_CELL_DATA_CODEPOINT, &cp);
                }
            }
            char ch = 0;
            if (cp >= 'A' && cp <= 'Z') ch = (char)(cp - 'A' + 'a');
            else if (cp >= 'a' && cp <= 'z') ch = (char)cp;
            else if (cp >= '0' && cp <= '9') ch = (char)cp;
            else if (cp == '/' || cp == '[' || cp == ']' || cp == '(' || cp == ')' ||
                     cp == '?' || cp == '.' || cp == ',' || cp == '\'' || cp == '-') {
                ch = (char)cp;
            }
            if (!ch) {
                if (!space && n + 1 < sizeof(raw)) {
                    raw[n++] = ' ';
                    space = 1;
                }
                continue;
            }
            raw[n++] = ch;
            space = 0;
        }
        if (!space && n + 1 < sizeof(raw)) {
            raw[n++] = ' ';
            space = 1;
        }
    }
    raw[n] = 0;
    static const char *needles[] = {
        "enter to select",
        "arrow keys to navigate",
        "esc to cancel",
        "tab/arrow",
        "type something",
        "allow once",
        "always allow",
        "reject once",
        "reject always",
        "waiting for authorization",
        "waiting for approval",
        "trust the session",
        "don't ask again",
        "dont ask again",
        "yes, and don't ask",
        "always allow this command",
        "allow this command",
        "allow this kind",
        "[y/n]",
        "(y/n)",
        "do you want to proceed",
        "approve this",
        NULL,
    };
    for (const char **p = needles; *p; p++) {
        if (strstr(raw, *p)) return YES;
    }
    return NO;
}

- (void)onPTY {
    if (_master < 0 || !_term) return;
    uint8_t buf[8192];
    BOOL wrote = NO;
    for (;;) {
        ssize_t n = read(_master, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            [self killChild];
            break;
        }
        if (n == 0) {
            [self killChild];
            break;
        }
        wrote = YES;
        if (_holdUntilFirstFrame) {
            if (!_holdBuf) _holdBuf = [NSMutableData data];
            [_holdBuf appendBytes:buf length:(NSUInteger)n];
            [_holdTimer invalidate];
            __weak ATTermView *weak = self;
            _holdTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                         repeats:NO
                                                           block:^(NSTimer *t) {
                (void)t;
                [weak flushFirstFrame];
            }];
            continue;
        }
        _got_output = YES;
        ghostty_terminal_vt_write(_term, buf, (size_t)n);
    }
    if (_holdUntilFirstFrame) return;
    if (wrote) {
        uint64_t hash = ATViewportBodyHash(_term, _cols, _rows);
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (now >= _quietUntil && hash != _bodyHash) _lastOutput = now;
        _bodyHash = hash;
        _asksInput = ATViewportAsksInput(_term, _cols, _rows);
        [self setNeedsDisplay:YES];
    }
}

- (BOOL)isBusy {
    if (_pid <= 0) return NO;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now < _turnUntil) return YES;
    return _lastOutput > 0 && now - _lastOutput < kATBusyWindow;
}

- (void)noteSeen {
}

- (ATActivity)activity {
    if (_pid <= 0) return ATActivityNone;
    if (_asksInput) return ATActivityNeedsInput;
    if ([self isBusy]) return ATActivityWorking;
    return ATActivityStandby;
}

- (BOOL)activityNeedsPaint {
    if (_term && _pid > 0) _asksInput = ATViewportAsksInput(_term, _cols, _rows);
    ATActivity a = self.activity;
    BOOL pulse = (a == ATActivityWorking);
    BOOL changed = (a != _paintedActivity);
    _paintedActivity = a;
    return pulse || changed;
}

- (void)screenCellAtPoint:(NSPoint)p col:(int *)col row:(int *)row {
    if (!_term) {
        *col = 0;
        *row = 0;
        return;
    }
    int c = (int)floor((p.x - 6) / _cw);
    int r = (int)floor((p.y - 4) / _ch);
    if (c < 0) c = 0;
    if (r < 0) r = 0;
    if (c >= (int)_cols) c = (int)_cols - 1;
    if (r >= (int)_rows) r = (int)_rows - 1;
    GhosttyTerminalScrollbar sb = {0};
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb);
    *col = c;
    *row = (int)sb.offset + r;
}

- (BOOL)cellSelectedAtCol:(int)col screenRow:(int)row {
    if (!_hasSel) return NO;
    int x0 = _selX0, y0 = _selY0, x1 = _selX1, y1 = _selY1;
    if (y0 > y1 || (y0 == y1 && x0 > x1)) {
        int tx = x0, ty = y0;
        x0 = x1; y0 = y1; x1 = tx; y1 = ty;
    }
    if (row < y0 || row > y1) return NO;
    if (y0 == y1) return col >= x0 && col <= x1;
    if (row == y0) return col >= x0;
    if (row == y1) return col <= x1;
    return YES;
}

static GhosttyColorRgb ATStyleRgb(GhosttyStyleColor c, const GhosttyColorRgb *pal, GhosttyColorRgb fb) {
    if (c.tag == GHOSTTY_STYLE_COLOR_RGB) return c.value.rgb;
    if (c.tag == GHOSTTY_STYLE_COLOR_PALETTE) return pal[c.value.palette];
    return fb;
}

static NSColor *ATNSRgb(GhosttyColorRgb c) {
    return [NSColor colorWithCalibratedRed:c.r / 255.0 green:c.g / 255.0 blue:c.b / 255.0 alpha:1];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    GhosttyColorRgb defBg = {14, 15, 16};
    GhosttyColorRgb defFg = {214, 211, 204};
    NSColor *selBg = [NSColor colorWithCalibratedRed:0.769 green:0.647 blue:0.455 alpha:0.28];
    NSFont *plain = _font ? (__bridge NSFont *)_font : [NSFont fontWithName:@"Menlo" size:13];
    CGFloat x0 = 6, y0 = 4;
    if (!_term) {
        [ATNSRgb(defBg) setFill];
        NSRectFill(self.bounds);
        if (!_got_output) {
            NSString *name = self.command.length ? self.command : @"shell";
            NSString *msg = [NSString stringWithFormat:@"starting %@…", name];
            NSDictionary *wait = @{
                NSFontAttributeName: plain,
                NSForegroundColorAttributeName: ATColorMuted(),
            };
            [msg drawAtPoint:NSMakePoint(x0, y0) withAttributes:wait];
        }
        return;
    }
    GhosttyColorRgb pal[256];
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, pal);
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &defBg);
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &defFg);
    [ATNSRgb(defBg) setFill];
    NSRectFill(self.bounds);
    if (!_got_output) {
        NSString *name = self.command.length ? self.command : @"shell";
        NSString *msg = [NSString stringWithFormat:@"starting %@…", name];
        NSDictionary *wait = @{
            NSFontAttributeName: plain,
            NSForegroundColorAttributeName: ATColorMuted(),
        };
        [msg drawAtPoint:NSMakePoint(x0, y0) withAttributes:wait];
        return;
    }
    uint16_t cols = 0, rows = 0;
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    GhosttyTerminalScrollbar sb = {0};
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb);
    NSFont *bold = _fontBold ? (__bridge NSFont *)_fontBold : plain;
    NSFont *italic = _fontItalic ? (__bridge NSFont *)_fontItalic : plain;
    NSFont *boldIt = _fontBoldItalic ? (__bridge NSFont *)_fontBoldItalic : bold;
    uint32_t lastFg = 0xFFFFFFFF;
    NSFont *lastFont = nil;
    NSDictionary *attrs = nil;
    for (uint16_t row = 0; row < rows; row++) {
        int screen_y = (int)sb.offset + (int)row;
        for (uint16_t col = 0; col < cols; col++) {
            GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
            GhosttyPoint pt = {
                .tag = GHOSTTY_POINT_TAG_VIEWPORT,
                .value = { .coordinate = { .x = col, .y = row } },
            };
            if (ghostty_terminal_grid_ref(_term, pt, &ref) != GHOSTTY_SUCCESS) continue;
            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            ghostty_grid_ref_style(&ref, &style);
            GhosttyColorRgb bgc = ATStyleRgb(style.bg_color, pal, defBg);
            GhosttyColorRgb fgc = ATStyleRgb(style.fg_color, pal, defFg);
            if (style.inverse) {
                GhosttyColorRgb tmp = bgc;
                bgc = fgc;
                fgc = tmp;
            }
            if (style.faint) {
                fgc.r = (uint8_t)((fgc.r + bgc.r) / 2);
                fgc.g = (uint8_t)((fgc.g + bgc.g) / 2);
                fgc.b = (uint8_t)((fgc.b + bgc.b) / 2);
            }
            NSRect cell = NSMakeRect(x0 + col * _cw, y0 + row * _ch, _cw, _ch);
            BOOL coloredBg = (bgc.r != defBg.r || bgc.g != defBg.g || bgc.b != defBg.b);
            if (coloredBg) {
                [ATNSRgb(bgc) setFill];
                NSRectFill(cell);
            }
            if ([self cellSelectedAtCol:col screenRow:screen_y]) {
                [selBg setFill];
                NSRectFill(cell);
            }
            if (style.invisible) continue;
            GhosttyCell gcell;
            if (ghostty_grid_ref_cell(&ref, &gcell) != GHOSTTY_SUCCESS) continue;
            GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
            ghostty_cell_get(gcell, GHOSTTY_CELL_DATA_WIDE, &wide);
            bool has_text = false;
            ghostty_cell_get(gcell, GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);
            if ((wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) && !has_text)
                continue;
            if (has_text) {
                uint32_t cp = 0;
                ghostty_cell_get(gcell, GHOSTTY_CELL_DATA_CODEPOINT, &cp);
                if (cp) {
                    NSFont *use = style.bold
                        ? (style.italic ? boldIt : bold)
                        : (style.italic ? italic : plain);
                    uint32_t packed = ((uint32_t)fgc.r << 16) | ((uint32_t)fgc.g << 8) | fgc.b;
                    if (packed != lastFg || use != lastFont) {
                        lastFg = packed;
                        lastFont = use;
                        attrs = @{
                            NSFontAttributeName: use,
                            NSForegroundColorAttributeName: ATNSRgb(fgc),
                        };
                    }
                    NSString *glyph;
                    if (cp > 0xFFFF) {
                        unichar surr[2] = {
                            (unichar)(0xD800 + ((cp - 0x10000) >> 10)),
                            (unichar)(0xDC00 + ((cp - 0x10000) & 0x3FF)),
                        };
                        glyph = [NSString stringWithCharacters:surr length:2];
                    } else {
                        unichar u = (unichar)cp;
                        glyph = [NSString stringWithCharacters:&u length:1];
                    }
                    [glyph drawAtPoint:NSMakePoint(cell.origin.x, cell.origin.y) withAttributes:attrs];
                }
            }
            if (style.underline) {
                [ATNSRgb(fgc) setFill];
                NSRectFill(NSMakeRect(cell.origin.x, NSMaxY(cell) - 1, _cw, 1));
            }
            if (style.strikethrough) {
                [ATNSRgb(fgc) setFill];
                NSRectFill(NSMakeRect(cell.origin.x, cell.origin.y + floor(_ch * 0.55), _cw, 1));
            }
        }
    }
    bool vis = true;
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &vis);
    uint16_t cx = 0, cy = 0;
    size_t sb_rows = 0;
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx);
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy);
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &sb_rows);
    int vp_y = (int)sb_rows + (int)cy - (int)sb.offset;
    if (_focused && vis && vp_y >= 0 && vp_y < (int)rows) {
        NSRect caret = NSMakeRect(x0 + cx * _cw, y0 + vp_y * _ch, 2, _ch);
        [ATColorAccent() setFill];
        NSRectFill(caret);
    }
    NSRect track, thumb;
    GhosttyTerminalScrollbar sbar = {0};
    if ([self scrollbarTrack:&track thumb:&thumb sb:&sbar]) {
        [[ATColorMuted() colorWithAlphaComponent:0.18] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:3.5 yRadius:3.5] fill];
        BOOL live = (sbar.offset + sbar.len >= sbar.total);
        [(live ? [ATColorMuted() colorWithAlphaComponent:0.45] : ATColorAccent()) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:thumb xRadius:3.5 yRadius:3.5] fill];
    }
}

- (BOOL)becomeFirstResponder {
    _focused = YES;
    [self noteSeen];
    [self setNeedsDisplay:YES];
    return [super becomeFirstResponder];
}

- (BOOL)resignFirstResponder {
    _focused = NO;
    [self setNeedsDisplay:YES];
    return [super resignFirstResponder];
}

- (void)writeBytes:(const void *)p length:(size_t)n {
    if (_master < 0 || n == 0) return;
    const uint8_t *b = p;
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(_master, b + off, n - off);
        if (w < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            break;
        }
        off += (size_t)w;
    }
}

- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags m = event.modifierFlags;
    NSWindowController *wc = self.window.windowController;
    if ([wc handleNavEvent:event]) return;
    if (m & NSEventModifierFlagCommand) {
        NSString *ch = event.charactersIgnoringModifiers.lowercaseString;
        if ([ch isEqualToString:@"c"]) {
            if (_hasSel) [self copy:nil];
            else {
                uint8_t b = 0x03;
                [self writeBytes:&b length:1];
            }
            return;
        }
        if ([ch isEqualToString:@"v"]) {
            [self paste:nil];
            return;
        }
        if ([ch isEqualToString:@"a"]) {
            [self selectAll:nil];
            return;
        }
        [super keyDown:event];
        return;
    }
    unsigned short kc = event.keyCode;
    const char *seq = NULL;
    switch (kc) {
        case 126: seq = (m & NSEventModifierFlagShift) ? "\x1b[1;2A" : "\x1b[A"; break;
        case 125: seq = (m & NSEventModifierFlagShift) ? "\x1b[1;2B" : "\x1b[B"; break;
        case 124: seq = (m & NSEventModifierFlagShift) ? "\x1b[1;2C" : "\x1b[C"; break;
        case 123: seq = (m & NSEventModifierFlagShift) ? "\x1b[1;2D" : "\x1b[D"; break;
        case 36:
            /* Shift/Option+Return = newline; Return = submit. */
            seq = (m & (NSEventModifierFlagShift | NSEventModifierFlagOption)) ? "\n" : "\r";
            break;
        case 48: seq = "\t"; break;
        case 51: seq = "\x7f"; break;
        case 53: seq = "\x1b"; break;
        default: break;
    }
    if (seq) {
        [self scrollToBottom];
        [self writeBytes:seq length:strlen(seq)];
        if (kc == 36 && seq && seq[0] == '\r') {
            NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
            _lastOutput = now;
            _turnUntil = now + kATTurnFloor;
        }
        return;
    }
    if (m & NSEventModifierFlagControl) {
        NSString *c = event.charactersIgnoringModifiers;
        if (c.length == 1) {
            unichar u = [c characterAtIndex:0];
            if (u == 'v' || u == 'V') {
                if ([self pasteClipboardImage]) return;
            }
            if (u >= 'a' && u <= 'z') {
                uint8_t b = (uint8_t)(u - 'a' + 1);
                [self writeBytes:&b length:1];
                return;
            }
        }
    }
    NSString *chars = event.characters;
    if (chars.length == 0) return;
    [self scrollToBottom];
    const char *utf = chars.UTF8String;
    if (utf) [self writeBytes:utf length:strlen(utf)];
}

- (BOOL)modeOn:(GhosttyMode)mode {
    GhosttyTerminalModeConfig cfg = { .mode = mode, .value = false };
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_MODE, &cfg);
    return cfg.value;
}

- (BOOL)ptyMouseTracking {
    if (!_term) return NO;
    bool tracking = false;
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking);
    return tracking;
}

- (void)sendMouse:(GhosttyMouseAction)action
           button:(GhosttyMouseButton)button
               at:(NSPoint)p
              mods:(NSEventModifierFlags)mods {
    if (!_term) return;
    GhosttyMouseEncoder enc = NULL;
    if (ghostty_mouse_encoder_new(NULL, &enc) != GHOSTTY_SUCCESS) return;
    ghostty_mouse_encoder_setopt_from_terminal(enc, _term);
    /* 1000-only TUIs drop motion, so a drag never moves their thumb.
       Encode as 1002 + SGR so the press and the drag are the same protocol. */
    GhosttyMouseTrackingMode drag_mode = GHOSTTY_MOUSE_TRACKING_BUTTON;
    GhosttyMouseFormat drag_fmt = GHOSTTY_MOUSE_FORMAT_SGR;
    ghostty_mouse_encoder_setopt(enc, GHOSTTY_MOUSE_ENCODER_OPT_EVENT, &drag_mode);
    ghostty_mouse_encoder_setopt(enc, GHOSTTY_MOUSE_ENCODER_OPT_FORMAT, &drag_fmt);
    GhosttyMouseEncoderSize sz = {
        .size = sizeof(GhosttyMouseEncoderSize),
        .screen_width = (uint32_t)self.bounds.size.width,
        .screen_height = (uint32_t)self.bounds.size.height,
        .cell_width = (uint32_t)MAX(_cw, 1),
        .cell_height = (uint32_t)MAX(_ch, 1),
        .padding_left = 6,
        .padding_top = 4,
    };
    ghostty_mouse_encoder_setopt(enc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &sz);
    bool held = (action != GHOSTTY_MOUSE_ACTION_RELEASE);
    ghostty_mouse_encoder_setopt(enc, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &held);
    GhosttyMouseEvent ev = NULL;
    if (ghostty_mouse_event_new(NULL, &ev) != GHOSTTY_SUCCESS) {
        ghostty_mouse_encoder_free(enc);
        return;
    }
    ghostty_mouse_event_set_action(ev, action);
    ghostty_mouse_event_set_button(ev, button);
    ghostty_mouse_event_set_position(ev, (GhosttyMousePosition){ .x = (float)p.x, .y = (float)p.y });
    GhosttyMods gm = 0;
    if (mods & NSEventModifierFlagShift) gm |= GHOSTTY_MODS_SHIFT;
    if (mods & NSEventModifierFlagControl) gm |= GHOSTTY_MODS_CTRL;
    if (mods & NSEventModifierFlagOption) gm |= GHOSTTY_MODS_ALT;
    if (mods & NSEventModifierFlagCommand) gm |= GHOSTTY_MODS_SUPER;
    ghostty_mouse_event_set_mods(ev, gm);
    char buf[128];
    size_t written = 0;
    if (ghostty_mouse_encoder_encode(enc, ev, buf, sizeof(buf), &written) == GHOSTTY_SUCCESS && written > 0) {
        [self writeBytes:buf length:written];
    }
    ghostty_mouse_event_free(ev);
    ghostty_mouse_encoder_free(enc);
}

- (void)sendWheelMouseRows:(intptr_t)rows at:(NSPoint)p {
    GhosttyMouseEncoder enc = NULL;
    if (ghostty_mouse_encoder_new(NULL, &enc) != GHOSTTY_SUCCESS) return;
    ghostty_mouse_encoder_setopt_from_terminal(enc, _term);
    GhosttyMouseEncoderSize sz = {
        .size = sizeof(GhosttyMouseEncoderSize),
        .screen_width = (uint32_t)self.bounds.size.width,
        .screen_height = (uint32_t)self.bounds.size.height,
        .cell_width = (uint32_t)MAX(_cw, 1),
        .cell_height = (uint32_t)MAX(_ch, 1),
        .padding_left = 6,
        .padding_top = 4,
    };
    ghostty_mouse_encoder_setopt(enc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &sz);
    GhosttyMouseEvent ev = NULL;
    if (ghostty_mouse_event_new(NULL, &ev) != GHOSTTY_SUCCESS) {
        ghostty_mouse_encoder_free(enc);
        return;
    }
    ghostty_mouse_event_set_action(ev, GHOSTTY_MOUSE_ACTION_PRESS);
    ghostty_mouse_event_set_position(ev, (GhosttyMousePosition){ .x = (float)p.x, .y = (float)p.y });
    BOOL up = rows < 0;
    int n = (int)(up ? -rows : rows);
    if (n > 3) n = 3;
    ghostty_mouse_event_set_button(ev, up ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE);
    char buf[128];
    for (int i = 0; i < n; i++) {
        size_t written = 0;
        if (ghostty_mouse_encoder_encode(enc, ev, buf, sizeof(buf), &written) == GHOSTTY_SUCCESS && written > 0) {
            [self writeBytes:buf length:written];
        }
    }
    ghostty_mouse_event_free(ev);
    ghostty_mouse_encoder_free(enc);
}

- (void)applyScrollRows:(intptr_t)rows at:(NSPoint)p shift:(BOOL)shift {
    if (rows == 0) return;
    if (rows > 8) rows = 8;
    if (rows < -8) rows = -8;
    if (shift) {
        GhosttyTerminalScrollViewport b = {
            .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA,
            .value = { .delta = rows },
        };
        ghostty_terminal_scroll_viewport(_term, b);
        [self setNeedsDisplay:YES];
        return;
    }
    bool tracking = false;
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking);
    GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    if (screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE && !tracking && [self modeOn:GHOSTTY_MODE_ALT_SCROLL]) {
        BOOL appKeys = [self modeOn:GHOSTTY_MODE_DECCKM];
        BOOL up = rows < 0;
        const char *seq = up ? (appKeys ? "\x1bOA" : "\x1b[A")
                             : (appKeys ? "\x1bOB" : "\x1b[B");
        int n = (int)(up ? -rows : rows);
        size_t len = strlen(seq);
        for (int i = 0; i < n; i++) [self writeBytes:seq length:len];
        return;
    }
    if (tracking) {
        [self sendWheelMouseRows:rows at:p];
        return;
    }
    GhosttyTerminalScrollViewport b = {
        .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA,
        .value = { .delta = rows },
    };
    ghostty_terminal_scroll_viewport(_term, b);
    [self setNeedsDisplay:YES];
}

- (void)scrollWheel:(NSEvent *)event {
    if (!_term) return;
    CGFloat dy = event.scrollingDeltaY;
    if (!event.hasPreciseScrollingDeltas) {
        if (dy > 0) dy = MAX(dy, 1);
        else if (dy < 0) dy = MIN(dy, -1);
        dy *= _ch;
    } else {
        dy *= 0.28;
    }
    if (dy == 0) return;
    if (_scrollPending * dy < 0) _scrollPending = 0;
    _scrollPending += dy;
    if (fabs(_scrollPending) < _ch) return;
    intptr_t rows = (intptr_t)(_scrollPending / _ch);
    if (rows == 0) return;
    _scrollPending -= rows * _ch;
    rows = -rows;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    [self applyScrollRows:rows at:p shift:(event.modifierFlags & NSEventModifierFlagShift) != 0];
}

- (BOOL)hitScrollStrip:(NSPoint)p {
    return p.x >= NSWidth(self.bounds) - 22;
}

- (void)dragScrollStrip:(NSPoint)p {
    NSRect track, thumb;
    if ([self scrollbarTrack:&track thumb:&thumb sb:NULL]) {
        [self scrollFromPoint:p];
        _sbDidMove = YES;
        return;
    }
    CGFloat dy = p.y - _sbLastY;
    if (fabs(dy) < _ch * 0.6) return;
    intptr_t rows = (intptr_t)(dy / _ch);
    if (rows == 0) rows = (dy > 0) ? 1 : -1;
    _sbLastY = p.y;
    _sbDidMove = YES;
    [self applyScrollRows:rows at:p shift:NO];
}

- (BOOL)altScreen {
    if (!_term) return NO;
    GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
}

- (NSPoint)pointOnLastCol:(NSPoint)p {
    if (_cols < 1) return p;
    CGFloat x = 6 + ((CGFloat)_cols - 0.5) * _cw;
    return NSMakePoint(x, p.y);
}

- (NSPoint)mousePointForEventAt:(NSPoint)p {
    return _pinScrollCol ? [self pointOnLastCol:p] : p;
}

- (BOOL)scrollbarTrack:(NSRect *)track thumb:(NSRect *)thumb sb:(GhosttyTerminalScrollbar *)sb {
    if (!_term) return NO;
    /* Grok/Claude own the scrollbar on the alt screen. Our overlay sits on
       top of it and stays pinned at the bottom, so the thumb looks stuck. */
    if ([self altScreen]) return NO;
    GhosttyTerminalScrollbar s = {0};
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &s);
    if (s.total <= s.len) return NO;
    CGFloat w = 11, pad = 3;
    NSRect tr = NSMakeRect(NSWidth(self.bounds) - w - pad, 4, w, NSHeight(self.bounds) - 8);
    if (tr.size.height < 24) return NO;
    CGFloat frac = (CGFloat)s.len / (CGFloat)s.total;
    CGFloat th = MAX(18.0, tr.size.height * frac);
    CGFloat span = (CGFloat)(s.total - s.len);
    CGFloat ty = tr.origin.y;
    if (span > 0) ty += (tr.size.height - th) * ((CGFloat)s.offset / span);
    if (track) *track = tr;
    if (thumb) *thumb = NSMakeRect(tr.origin.x, ty, tr.size.width, th);
    if (sb) *sb = s;
    return YES;
}

- (void)scrollToBottom {
    if (!_term) return;
    GhosttyTerminalScrollViewport b = { .tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM };
    ghostty_terminal_scroll_viewport(_term, b);
    [self setNeedsDisplay:YES];
}

- (void)scrollToOffset:(uint64_t)offset {
    if (!_term) return;
    GhosttyTerminalScrollViewport b = {
        .tag = GHOSTTY_SCROLL_VIEWPORT_ROW,
        .value = { .row = (size_t)offset },
    };
    ghostty_terminal_scroll_viewport(_term, b);
    [self setNeedsDisplay:YES];
}

- (void)scrollFromPoint:(NSPoint)p {
    NSRect track, thumb;
    GhosttyTerminalScrollbar s = {0};
    if (![self scrollbarTrack:&track thumb:&thumb sb:&s]) return;
    CGFloat th = thumb.size.height;
    CGFloat usable = track.size.height - th;
    if (usable < 1) return;
    CGFloat t = (p.y - track.origin.y - th / 2.0) / usable;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    uint64_t maxOff = s.total > s.len ? s.total - s.len : 0;
    [self scrollToOffset:(uint64_t)(t * (CGFloat)maxOff)];
}

- (uint32_t)codepointAtCol:(int)col screenRow:(int)row {
    if (!_term || col < 0 || row < 0) return 0;
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    GhosttyPoint pt = {
        .tag = GHOSTTY_POINT_TAG_SCREEN,
        .value = { .coordinate = { .x = (uint16_t)col, .y = (uint32_t)row } },
    };
    if (ghostty_terminal_grid_ref(_term, pt, &ref) != GHOSTTY_SUCCESS) return 0;
    GhosttyCell gcell;
    if (ghostty_grid_ref_cell(&ref, &gcell) != GHOSTTY_SUCCESS) return 0;
    bool has_text = false;
    ghostty_cell_get(gcell, GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);
    if (!has_text) return 0;
    uint32_t cp = 0;
    ghostty_cell_get(gcell, GHOSTTY_CELL_DATA_CODEPOINT, &cp);
    return cp;
}

static BOOL ATWordChar(uint32_t cp) {
    if (cp >= '0' && cp <= '9') return YES;
    if (cp >= 'A' && cp <= 'Z') return YES;
    if (cp >= 'a' && cp <= 'z') return YES;
    if (cp == '_' || cp == '-' || cp == '.' || cp == '/') return YES;
    return cp > 127;
}

- (void)expandSelWord {
    int col = _selX0, row = _selY0;
    while (col > 0 && ATWordChar([self codepointAtCol:col - 1 screenRow:row])) col--;
    _selX0 = col;
    col = _selX1;
    while (col + 1 < (int)_cols && ATWordChar([self codepointAtCol:col + 1 screenRow:row])) col++;
    _selX1 = col;
    _selY1 = row;
    _hasSel = YES;
}

- (void)expandSelLine {
    _selX0 = 0;
    _selX1 = (int)_cols > 0 ? (int)_cols - 1 : 0;
    _selY1 = _selY0;
    _hasSel = YES;
}

- (void)selectAll:(id)sender {
    (void)sender;
    if (!_term) return;
    GhosttyTerminalScrollbar s = {0};
    ghostty_terminal_get(_term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &s);
    _selX0 = 0;
    _selY0 = 0;
    _selX1 = (int)_cols > 0 ? (int)_cols - 1 : 0;
    _selY1 = s.total > 0 ? (int)s.total - 1 : (int)_rows - 1;
    _hasSel = YES;
    [self setNeedsDisplay:YES];
    [self copy:nil];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (void)resetCursorRects {
    NSRect strip = NSMakeRect(NSWidth(self.bounds) - 22, 0, 22, NSHeight(self.bounds));
    [self addCursorRect:strip cursor:[NSCursor resizeUpDownCursor]];
}

- (void)beginSelectAt:(NSPoint)p clicks:(NSInteger)clicks {
    int col = 0, row = 0;
    [self screenCellAtPoint:p col:&col row:&row];
    _selX0 = _selX1 = col;
    _selY0 = _selY1 = row;
    if (clicks >= 3) [self expandSelLine];
    else if (clicks == 2) [self expandSelWord];
    else _hasSel = NO;
    _dragging = YES;
    _ptyMouseDown = NO;
    _pendingClick = NO;
    [self setNeedsDisplay:YES];
    if (_hasSel) [self copySelection];
}

- (GhosttyMouseButton)mouseButtonForEvent:(NSEvent *)event {
    return event.buttonNumber == 1 ? GHOSTTY_MOUSE_BUTTON_RIGHT : GHOSTTY_MOUSE_BUTTON_LEFT;
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    if (self.paneId.length && self.onFocus) self.onFocus(self.paneId);
    if (!_term) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    NSRect track, thumb;
    /* Ghostty overlay (primary scrollback) — drag the thumb we drew. */
    if (!shift && [self scrollbarTrack:&track thumb:&thumb sb:NULL] &&
        NSPointInRect(p, NSInsetRect(track, -8, 0))) {
        _sbDrag = YES;
        _sbDidMove = NO;
        _sbLastY = p.y;
        [self dragScrollStrip:p];
        return;
    }
    if (event.clickCount >= 2) {
        [self beginSelectAt:p clicks:event.clickCount];
        return;
    }
    /* TUI scrollbar (Grok/Claude): let the app see press/motion so its
       own thumb moves. Do not steal the strip for wheel ticks. */
    if ([self ptyMouseTracking] && !shift) {
        _ptyMouseDown = YES;
        _pinScrollCol = [self hitScrollStrip:p];
        _pendingClick = NO;
        _dragging = NO;
        _downPoint = p;
        _downMods = event.modifierFlags;
        _downButton = (int)event.buttonNumber;
        [self sendMouse:GHOSTTY_MOUSE_ACTION_PRESS
                 button:[self mouseButtonForEvent:event]
                     at:[self mousePointForEventAt:p]
                   mods:event.modifierFlags];
        return;
    }
    if (!shift && [self hitScrollStrip:p]) {
        _sbDrag = YES;
        _sbDidMove = NO;
        _sbLastY = p.y;
        [self dragScrollStrip:p];
        return;
    }
    [self beginSelectAt:p clicks:event.clickCount];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_term) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (_sbDrag) {
        [self dragScrollStrip:p];
        return;
    }
    if (_ptyMouseDown) {
        [self sendMouse:GHOSTTY_MOUSE_ACTION_MOTION
                 button:(_downButton == 1 ? GHOSTTY_MOUSE_BUTTON_RIGHT : GHOSTTY_MOUSE_BUTTON_LEFT)
                     at:[self mousePointForEventAt:p]
                   mods:event.modifierFlags];
        return;
    }
    if (!_dragging) return;
    int col = 0, row = 0;
    [self screenCellAtPoint:p col:&col row:&row];
    _selX1 = col;
    _selY1 = row;
    _hasSel = (_selX0 != _selX1 || _selY0 != _selY1);
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (_sbDrag) {
        _sbDrag = NO;
        return;
    }
    if (_ptyMouseDown) {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        [self sendMouse:GHOSTTY_MOUSE_ACTION_RELEASE
                 button:(_downButton == 1 ? GHOSTTY_MOUSE_BUTTON_RIGHT : GHOSTTY_MOUSE_BUTTON_LEFT)
                     at:[self mousePointForEventAt:p]
                   mods:event.modifierFlags];
        _ptyMouseDown = NO;
        _pinScrollCol = NO;
        return;
    }
    _dragging = NO;
    if (_hasSel) [self copySelection];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event;
    id wc = self.window.windowController;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Terminal"];
    NSMenuItem *sr = [[NSMenuItem alloc] initWithTitle:@"Split Right" action:@selector(splitRight) keyEquivalent:@""];
    sr.target = wc;
    [menu addItem:sr];
    NSMenuItem *sd = [[NSMenuItem alloc] initWithTitle:@"Split Down" action:@selector(splitDown) keyEquivalent:@""];
    sd.target = wc;
    [menu addItem:sd];
    NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:@"Close Pane" action:@selector(closeSession) keyEquivalent:@""];
    close.target = wc;
    [menu addItem:close];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *copy = [[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    copy.target = self;
    [menu addItem:copy];
    NSMenuItem *paste = [[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];
    paste.target = self;
    [menu addItem:paste];
    return menu;
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    if (item.action == @selector(copy:)) return _hasSel;
    if (item.action == @selector(paste:)) return YES;
    if (item.action == @selector(selectAll:)) return YES;
    return YES;
}

- (NSString *)pasteDir {
    NSString *root = self.cwd.length ? self.cwd : NSTemporaryDirectory();
    NSString *dir = [root stringByAppendingPathComponent:@".aterminal-paste"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (void)insertPath:(NSString *)path {
    if (!path.length) return;
    NSString *s = [self.command isEqualToString:@"claude"]
        ? [NSString stringWithFormat:@"@%@ ", path]
        : [NSString stringWithFormat:@"%@ ", path];
    const char *utf = s.fileSystemRepresentation;
    if (utf) [self writeBytes:utf length:strlen(utf)];
}

- (NSString *)writePNG:(NSData *)png {
    if (!png.length) return nil;
    NSString *name = [NSString stringWithFormat:@"paste-%ld.png", (long)[[NSDate date] timeIntervalSince1970]];
    NSString *path = [[self pasteDir] stringByAppendingPathComponent:name];
    if (![png writeToFile:path atomically:YES]) return nil;
    return path;
}

- (BOOL)pasteClipboardImage {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSData *png = [pb dataForType:NSPasteboardTypePNG];
    if (!png.length) {
        NSData *tiff = [pb dataForType:NSPasteboardTypeTIFF];
        if (tiff.length) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:tiff];
            png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        }
    }
    if (png.length) {
        NSString *path = [self writePNG:png];
        if (!path) return NO;
        [self insertPath:path];
        return YES;
    }
    NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]]
                                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    BOOL any = NO;
    for (NSURL *u in urls) {
        NSString *path = u.path;
        if (!path.length) continue;
        NSString *ext = path.pathExtension.lowercaseString;
        static NSSet *imgExt;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            imgExt = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"gif", @"webp", @"tif", @"tiff", @"bmp", @"heic", nil];
        });
        if (![imgExt containsObject:ext]) continue;
        [self insertPath:path];
        any = YES;
    }
    return any;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = sender.draggingPasteboard;
    NSData *png = [pb dataForType:NSPasteboardTypePNG];
    if (!png.length) {
        NSData *tiff = [pb dataForType:NSPasteboardTypeTIFF];
        if (tiff.length) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:tiff];
            png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        }
    }
    if (png.length) {
        NSString *path = [self writePNG:png];
        if (path) {
            [self insertPath:path];
            return YES;
        }
    }
    NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]]
                                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    BOOL any = NO;
    for (NSURL *u in urls) {
        if (u.path.length) {
            [self insertPath:u.path];
            any = YES;
        }
    }
    return any;
}

- (void)paste:(id)sender {
    (void)sender;
    [self scrollToBottom];
    if ([self pasteClipboardImage]) return;
    NSString *s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (!s.length) return;
    const char *utf = s.UTF8String;
    if (utf) [self writeBytes:utf length:strlen(utf)];
}

- (void)selBoundsX0:(int *)x0 y0:(int *)y0 x1:(int *)x1 y1:(int *)y1 {
    *x0 = _selX0;
    *y0 = _selY0;
    *x1 = _selX1;
    *y1 = _selY1;
    if (*y0 > *y1 || (*y0 == *y1 && *x0 > *x1)) {
        int tx = *x0, ty = *y0;
        *x0 = *x1;
        *y0 = *y1;
        *x1 = tx;
        *y1 = ty;
    }
}

- (NSString *)selectedText {
    if (!_term || !_hasSel) return nil;
    int x0, y0, x1, y1;
    [self selBoundsX0:&x0 y0:&y0 x1:&x1 y1:&y1];
    if (y0 == y1 && x0 == x1) return nil;
    NSMutableString *out = [NSMutableString new];
    for (int row = y0; row <= y1; row++) {
        int a = (row == y0) ? x0 : 0;
        int b = (row == y1) ? x1 : (int)_cols - 1;
        NSMutableString *line = [NSMutableString new];
        for (int col = a; col <= b; col++) {
            uint32_t cp = [self codepointAtCol:col screenRow:row];
            if (cp == 0 || cp == 32) {
                [line appendString:@" "];
                continue;
            }
            if (cp < 0x80) {
                [line appendFormat:@"%c", (char)cp];
            } else {
                char utf[8];
                NSUInteger n = 0;
                if (cp <= 0x7FF) {
                    utf[n++] = (char)(0xC0 | (cp >> 6));
                    utf[n++] = (char)(0x80 | (cp & 0x3F));
                } else if (cp <= 0xFFFF) {
                    utf[n++] = (char)(0xE0 | (cp >> 12));
                    utf[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                    utf[n++] = (char)(0x80 | (cp & 0x3F));
                } else {
                    utf[n++] = (char)(0xF0 | (cp >> 18));
                    utf[n++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                    utf[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                    utf[n++] = (char)(0x80 | (cp & 0x3F));
                }
                [line appendString:[[NSString alloc] initWithBytes:utf length:n encoding:NSUTF8StringEncoding] ?: @""];
            }
        }
        while (line.length && [line characterAtIndex:line.length - 1] == ' ')
            [line deleteCharactersInRange:NSMakeRange(line.length - 1, 1)];
        [out appendString:line];
        if (row != y1) [out appendString:@"\n"];
    }
    return out.length ? out : nil;
}

- (void)copySelection {
    NSString *text = [self selectedText];
    if (!text.length) return;
    NSPasteboard *board = [NSPasteboard generalPasteboard];
    [board clearContents];
    [board setString:text forType:NSPasteboardTypeString];
}

- (void)copy:(id)sender {
    (void)sender;
    [self copySelection];
}

- (void)insertText:(id)insertString replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    NSString *s = [insertString isKindOfClass:[NSAttributedString class]]
        ? [(NSAttributedString *)insertString string]
        : (NSString *)insertString;
    const char *utf = s.UTF8String;
    if (utf) [self writeBytes:utf length:strlen(utf)];
}

@end
