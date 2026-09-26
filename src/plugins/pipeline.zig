const std = @import("std");

const gpa = std.heap.c_allocator;

const PluginHost = extern struct {
    abi: u32,
    caps: u32,
    support_dir: ?[*:0]const u8,
    config_json: ?[*:0]const u8,
    call: ?*const fn (?[*:0]const u8, ?[*:0]const u8, *?[*:0]u8) callconv(.c) c_int,
    call_capped: ?*const fn (?[*:0]const u8, ?[*:0]const u8, *?[*:0]u8, u32) callconv(.c) c_int,
    free: ?*const fn (?[*:0]u8) callconv(.c) void,
    watch_fd: ?*const fn (c_int, ?*const fn (c_int, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) c_int,
    unwatch_fd: ?*const fn (c_int) callconv(.c) c_int,
    log: ?*const fn (c_int, ?[*:0]const u8) callconv(.c) c_int,
};

extern "c" fn kqueue() c_int;
extern "c" fn kevent(kq: c_int, ch: ?*const Kevent, nch: c_int, ev: ?*Kevent, nev: c_int, ts: ?*const Timespec) c_int;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn opendir(name: [*:0]const u8) ?*anyopaque;
extern "c" fn readdir(dir: ?*anyopaque) ?*std.c.dirent;
extern "c" fn closedir(dir: ?*anyopaque) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(file: ?*anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, file: ?*anyopaque) usize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, file: ?*anyopaque) usize;
extern "c" fn fseek(file: ?*anyopaque, off: c_long, whence: c_int) c_int;
extern "c" fn ftell(file: ?*anyopaque) c_long;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

const Kevent = extern struct {
    ident: usize,
    filter: i16,
    flags: u16,
    fflags: u32,
    data: isize,
    udata: ?*anyopaque,
};
const Timespec = extern struct { tv_sec: isize, tv_nsec: isize };

const EVFILT_TIMER: i16 = -7;
const EV_ADD: u16 = 0x0001;
const NOTE_SECONDS: u32 = 0x00000001;

var host_ptr: ?*PluginHost = null;
var kq_fd: c_int = -1;
var ticking: bool = false;

export fn at_plugin_abi() callconv(.c) c_int {
    return 1;
}

export fn at_plugin_name() callconv(.c) [*:0]const u8 {
    return "pipeline";
}

export fn at_plugin_init(host: *PluginHost) callconv(.c) c_int {
    host_ptr = host;
    if (host.log) |log| _ = log(1, "pipeline extension loaded");
    kq_fd = kqueue();
    if (kq_fd < 0) return -1;
    var ev = Kevent{
        .ident = 1,
        .filter = EVFILT_TIMER,
        .flags = EV_ADD,
        .fflags = NOTE_SECONDS,
        .data = 1,
        .udata = null,
    };
    if (kevent(kq_fd, &ev, 1, null, 0, null) < 0) return -1;
    if (host.watch_fd) |w| {
        if (w(kq_fd, onTimer, null) != 0) return -1;
    }
    return 0;
}

export fn at_plugin_shutdown() callconv(.c) void {
    if (host_ptr) |h| {
        if (h.unwatch_fd) |u| {
            if (kq_fd >= 0) _ = u(kq_fd);
        }
        if (h.log) |log| _ = log(1, "pipeline extension unloaded");
    }
    kq_fd = -1;
    host_ptr = null;
}

fn onTimer(fd: c_int, _: ?*anyopaque) callconv(.c) void {
    var ev: Kevent = undefined;
    var ts = Timespec{ .tv_sec = 0, .tv_nsec = 0 };
    _ = kevent(fd, null, 0, &ev, 1, &ts);
    if (ticking) return;
    ticking = true;
    tick();
    ticking = false;
}

fn logMsg(msg: [*:0]const u8) void {
    if (host_ptr) |h| {
        if (h.log) |l| _ = l(1, msg);
    }
}

fn supportDir() []const u8 {
    const h = host_ptr orelse return "";
    const d = h.support_dir orelse return "";
    return std.mem.span(d);
}

fn callOp(op: [*:0]const u8, args: [*:0]const u8) ?[:0]u8 {
    const h = host_ptr orelse return null;
    const call = h.call orelse return null;
    var out: ?[*:0]u8 = null;
    const rc = call(op, args, &out);
    if (out == null) return null;
    const s = std.mem.span(out.?);
    if (rc != 0) {
        if (h.free) |f| f(out);
        return null;
    }
    const copy = gpa.dupeZ(u8, s) catch {
        if (h.free) |f| f(out);
        return null;
    };
    if (h.free) |f| f(out);
    return copy;
}

fn skipString(src: []const u8, i: *usize) void {
    if (i.* >= src.len or src[i.*] != '"') return;
    i.* += 1;
    while (i.* < src.len) : (i.* += 1) {
        if (src[i.*] == '\\') {
            i.* += 1;
            continue;
        }
        if (src[i.*] == '"') {
            i.* += 1;
            return;
        }
    }
}

fn jsonRaw(src: []const u8, key: []const u8) []const u8 {
    var i: usize = 0;
    while (i + key.len + 3 < src.len) : (i += 1) {
        if (src[i] != '"') continue;
        if (!std.mem.eql(u8, src[i + 1 .. i + 1 + key.len], key)) continue;
        if (src[i + 1 + key.len] != '"') continue;
        var j = i + 1 + key.len + 1;
        while (j < src.len and (src[j] == ':' or src[j] == ' ' or src[j] == '\n' or src[j] == '\t')) j += 1;
        if (j >= src.len) return "";
        const start = j;
        const open = src[j];
        if (open == '"') {
            skipString(src, &j);
            return src[start..j];
        }
        if (open == '[' or open == '{') {
            var depth: i32 = 0;
            while (j < src.len) : (j += 1) {
                const c = src[j];
                if (c == '"') {
                    skipString(src, &j);
                    j -= 1;
                    continue;
                }
                if (c == '[' or c == '{') depth += 1;
                if (c == ']' or c == '}') {
                    depth -= 1;
                    if (depth == 0) return src[start .. j + 1];
                }
            }
            return "";
        }
        const end_start = j;
        while (j < src.len and src[j] != ',' and src[j] != '}' and src[j] != ']' and src[j] != ' ' and src[j] != '\n') j += 1;
        return src[end_start..j];
    }
    return "";
}

fn jsonGet(src: []const u8, key: []const u8) []const u8 {
    const raw = jsonRaw(src, key);
    if (raw.len >= 2 and raw[0] == '"') return raw[1 .. raw.len - 1];
    return raw;
}

fn stepNth(raw: []const u8, idx: u32) []const u8 {
    const arr = jsonRaw(raw, "steps");
    if (arr.len < 2 or arr[0] != '[') return "";
    const inner = arr[1 .. arr.len - 1];
    var n: u32 = 0;
    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\n' or inner[i] == '\t' or inner[i] == ',' or inner[i] == '\r')) i += 1;
        if (i >= inner.len) break;
        if (inner[i] != '{') break;
        const start = i;
        var depth: i32 = 0;
        while (i < inner.len) : (i += 1) {
            const c = inner[i];
            if (c == '"') {
                skipString(inner, &i);
                i -= 1;
                continue;
            }
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) {
                    const obj = inner[start .. i + 1];
                    if (n == idx) return obj;
                    n += 1;
                    i += 1;
                    break;
                }
            }
        } else break;
    }
    return "";
}

fn stepCount(raw: []const u8) u32 {
    var n: u32 = 0;
    while (stepNth(raw, n).len > 0) n += 1;
    return n;
}

fn isHuman(raw: []const u8, step: u32) bool {
    const obj = stepNth(raw, step);
    const kind = jsonGet(obj, "kind");
    if (std.mem.eql(u8, kind, "human")) return true;
    const name = jsonGet(obj, "name");
    return std.mem.eql(u8, name, "human");
}

fn readFile(path: []const u8) ?[]u8 {
    const z = gpa.dupeZ(u8, path) catch return null;
    defer gpa.free(z);
    const f = fopen(z, "rb") orelse return null;
    defer _ = fclose(f);
    if (fseek(f, 0, 2) != 0) return null;
    const sz = ftell(f);
    if (sz <= 0) return null;
    if (fseek(f, 0, 0) != 0) return null;
    const buf = gpa.alloc(u8, @intCast(sz)) catch return null;
    const n = fread(buf.ptr, 1, buf.len, f);
    if (n != buf.len) {
        gpa.free(buf);
        return null;
    }
    return buf;
}

fn writeFile(path: []const u8, bytes: []const u8) void {
    const z = gpa.dupeZ(u8, path) catch return;
    defer gpa.free(z);
    const f = fopen(z, "wb") orelse return;
    defer _ = fclose(f);
    _ = fwrite(bytes.ptr, 1, bytes.len, f);
}

fn exists(path: []const u8) bool {
    const z = gpa.dupeZ(u8, path) catch return false;
    defer gpa.free(z);
    return access(z, 0) == 0;
}

// One line per transition, next to the job. Without this the only record of
// what the pipeline tried is stderr, which nobody sees when the app is
// launched from Finder.
fn logLine(dir: []const u8, msg: []const u8) void {
    const path = std.fs.path.join(gpa, &.{ dir, "log" }) catch return;
    defer gpa.free(path);
    const z = gpa.dupeZ(u8, path) catch return;
    defer gpa.free(z);
    const f = fopen(z, "ab") orelse return;
    defer _ = fclose(f);
    var buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&buf, "{d} ", .{time(null)}) catch "";
    _ = fwrite(ts.ptr, 1, ts.len, f);
    _ = fwrite(msg.ptr, 1, msg.len, f);
    const nl: []const u8 = "\n";
    _ = fwrite(nl.ptr, 1, nl.len, f);
}

fn fail(dir: []const u8, raw: []const u8, reason: []const u8) void {
    logLine(dir, reason);
    rewriteJob(dir, raw, "status", "error", "reason", reason);
}

fn paneActivity(pane: []const u8) ?i32 {
    if (pane.len == 0) return null;
    var buf: [96]u8 = undefined;
    const args = std.fmt.bufPrintZ(&buf, "{{\"pane\":\"{s}\"}}", .{pane}) catch return null;
    const res = callOp("pane.activity", args.ptr) orelse return null;
    defer gpa.free(res);
    return std.fmt.parseInt(i32, jsonGet(res, "activity"), 10) catch null;
}

// pane.activity only fails when the UI has no view for the pane at all. That
// is usually fatal, but a job read back after a restart can be a few ticks
// early, so give it a window before calling it dead.
const kMaxMisses: u32 = 15;

fn noteMiss(dir: []const u8, raw: []const u8) void {
    const n = (std.fmt.parseInt(u32, jsonGet(raw, "misses"), 10) catch 0) + 1;
    if (n >= kMaxMisses) {
        fail(dir, raw, "the agent pane is gone");
        return;
    }
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    rewriteJob(dir, raw, "misses", s, null, null);
}

fn tick() void {
    const root = supportDir();
    if (root.len == 0) return;
    const qpath = std.fs.path.join(gpa, &.{ root, "queue" }) catch return;
    defer gpa.free(qpath);
    const qz = gpa.dupeZ(u8, qpath) catch return;
    defer gpa.free(qz);
    _ = mkdir(qz, 0o700);
    const d = opendir(qz) orelse return;
    defer _ = closedir(d);
    while (readdir(d)) |ent| {
        const name = ent.name[0..ent.namlen];
        if (name.len == 0 or name[0] == '.') continue;
        const job_dir = std.fs.path.join(gpa, &.{ qpath, name }) catch continue;
        defer gpa.free(job_dir);
        tickJob(job_dir);
    }
}

fn tickJob(dir: []const u8) void {
    const jp = std.fs.path.join(gpa, &.{ dir, "job.json" }) catch return;
    defer gpa.free(jp);
    const raw = readFile(jp) orelse return;
    defer gpa.free(raw);
    const status = jsonGet(raw, "status");
    if (std.mem.eql(u8, status, "done") or std.mem.eql(u8, status, "error")) return;
    if (std.mem.eql(u8, status, "human")) {
        const ap = std.fs.path.join(gpa, &.{ dir, "APPROVE" }) catch return;
        defer gpa.free(ap);
        if (exists(ap)) advance(dir, raw);
        return;
    }
    if (std.mem.eql(u8, status, "queued")) {
        startStep(dir, raw, 0);
        return;
    }
    const pane = jsonGet(raw, "pane");
    const step_s = jsonGet(raw, "step");
    const step: u32 = std.fmt.parseInt(u32, step_s, 10) catch 0;
    if (std.mem.eql(u8, status, "arming")) {
        armStep(dir, raw, step, pane);
        return;
    }
    var done_path_buf: [8]u8 = undefined;
    const done_name = std.fmt.bufPrint(&done_path_buf, "{d}/DONE", .{step}) catch return;
    const done_path = std.fs.path.join(gpa, &.{ dir, done_name }) catch return;
    defer gpa.free(done_path);
    if (exists(done_path)) {
        advance(dir, raw);
        return;
    }
    const act = paneActivity(pane) orelse {
        noteMiss(dir, raw);
        return;
    };
    // 0 = no process. The agent we were talking to is dead; say so.
    if (act == 0) {
        fail(dir, raw, "the agent exited before the step finished");
        return;
    }
    // 2 = the agent is asking the user. Never skip that step.
    if (act == 2) {
        if (!std.mem.eql(u8, status, "needs_you"))
            rewriteJob(dir, raw, "status", "needs_you", null, null);
        return;
    }
    if (std.mem.eql(u8, status, "needs_you"))
        rewriteJob(dir, raw, "status", "running", null, null);
    const had = jsonGet(raw, "had_busy");
    if (act == 3 and !std.mem.eql(u8, had, "true")) {
        rewriteJob(dir, raw, "had_busy", "true", null, null);
        return;
    }
    const started_s = jsonGet(raw, "started_s");
    const started = std.fmt.parseInt(i64, started_s, 10) catch 0;
    const now = time(null);
    const idle = act == 1 and std.mem.eql(u8, had, "true") and started > 0 and now >= started + 12;
    if (idle) advance(dir, raw);
}

fn readCapped(path: []const u8, max: usize) []u8 {
    const raw = readFile(path) orelse return "";
    if (raw.len <= max) return raw;
    const cut = gpa.dupe(u8, raw[0..max]) catch {
        gpa.free(raw);
        return "";
    };
    gpa.free(raw);
    return cut;
}

fn sendPrompt(pane: []const u8, text: []const u8) bool {
    var args: std.ArrayList(u8) = .empty;
    defer args.deinit(gpa);
    args.appendSlice(gpa, "{\"pane\":\"") catch return false;
    args.appendSlice(gpa, pane) catch return false;
    args.appendSlice(gpa, "\",\"submit\":true,\"text\":\"") catch return false;
    escapeJson(&args, text);
    args.appendSlice(gpa, "\"}") catch return false;
    const z = gpa.dupeZ(u8, args.items) catch return false;
    defer gpa.free(z);
    const res = callOp("pane.input", z.ptr) orelse return false;
    gpa.free(res);
    return true;
}

fn escapeJson(buf: *std.ArrayList(u8), s: []const u8) void {
    for (s) |ch| {
        switch (ch) {
            '"' => buf.appendSlice(gpa, "\\\"") catch return,
            '\\' => buf.appendSlice(gpa, "\\\\") catch return,
            '\n' => buf.appendSlice(gpa, "\\n") catch return,
            '\r' => buf.appendSlice(gpa, "\\r") catch return,
            else => buf.append(gpa, ch) catch return,
        }
    }
}

fn advance(dir: []const u8, raw: []const u8) void {
    const step_s = jsonGet(raw, "step");
    const step = std.fmt.parseInt(u32, step_s, 10) catch 0;
    const next = step + 1;
    const n = stepCount(raw);
    if (n == 0 or next >= n) {
        rewriteJob(dir, raw, "status", "done", null, null);
        logMsg("pipeline job done");
        return;
    }
    var nbuf: [16]u8 = undefined;
    const ns = std.fmt.bufPrint(&nbuf, "{d}", .{next}) catch return;
    rewriteJob(dir, raw, "step", ns, "had_busy", "false");
    const raw2 = blk: {
        const jp = std.fs.path.join(gpa, &.{ dir, "job.json" }) catch return;
        defer gpa.free(jp);
        break :blk readFile(jp) orelse return;
    };
    defer gpa.free(raw2);
    startStep(dir, raw2, next);
}

fn nthCsv(s: []const u8, idx: u32) []const u8 {
    var n: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == ',') {
            if (n == idx) return std.mem.trim(u8, s[start..i], " ");
            n += 1;
            start = i + 1;
        }
    }
    return "";
}

fn stageAgent(raw: []const u8, step: u32) []const u8 {
    const obj = stepNth(raw, step);
    const from_step = jsonGet(obj, "agent");
    if (from_step.len > 0 and !std.mem.eql(u8, from_step, "human")) return from_step;
    const list = jsonGet(raw, "agents");
    const from_list = nthCsv(list, step);
    if (from_list.len > 0 and !std.mem.eql(u8, from_list, "human")) return from_list;
    const fallback = jsonGet(raw, "agent");
    if (fallback.len > 0) return fallback;
    return "grok";
}

fn loadPane(dir: []const u8, agent: []const u8) ?[]u8 {
    const name = std.fmt.allocPrint(gpa, "pane-{s}", .{agent}) catch return null;
    defer gpa.free(name);
    const path = std.fs.path.join(gpa, &.{ dir, name }) catch return null;
    defer gpa.free(path);
    const raw = readFile(path) orelse return null;
    const t = std.mem.trim(u8, raw, " \n\r\t");
    if (t.len == 0) {
        gpa.free(raw);
        return null;
    }
    return raw;
}

fn savePane(dir: []const u8, agent: []const u8, pane: []const u8) void {
    const name = std.fmt.allocPrint(gpa, "pane-{s}", .{agent}) catch return;
    defer gpa.free(name);
    const path = std.fs.path.join(gpa, &.{ dir, name }) catch return;
    defer gpa.free(path);
    writeFile(path, pane);
}

fn loadTab(dir: []const u8, agent: []const u8) ?[]u8 {
    const name = std.fmt.allocPrint(gpa, "tab-{s}", .{agent}) catch return null;
    defer gpa.free(name);
    const path = std.fs.path.join(gpa, &.{ dir, name }) catch return null;
    defer gpa.free(path);
    return readFile(path);
}

fn saveTab(dir: []const u8, agent: []const u8, tab: []const u8) void {
    const name = std.fmt.allocPrint(gpa, "tab-{s}", .{agent}) catch return;
    defer gpa.free(name);
    const path = std.fs.path.join(gpa, &.{ dir, name }) catch return;
    defer gpa.free(path);
    writeFile(path, tab);
}

fn focusTab(tab: []const u8) void {
    if (tab.len == 0) return;
    var args: std.ArrayList(u8) = .empty;
    defer args.deinit(gpa);
    args.appendSlice(gpa, "{\"tab\":\"") catch return;
    escapeJson(&args, tab);
    args.appendSlice(gpa, "\"}") catch return;
    const z = gpa.dupeZ(u8, args.items) catch return;
    defer gpa.free(z);
    const res = callOp("tab.focus", z.ptr);
    if (res) |r| gpa.free(r);
}

fn startStep(dir: []const u8, raw: []const u8, step: u32) void {
    const n = stepCount(raw);
    if (n == 0 or step >= n) {
        rewriteJob(dir, raw, "status", "done", null, null);
        return;
    }
    const obj = stepNth(raw, step);
    var skill = jsonGet(obj, "name");
    if (skill.len == 0) skill = "do";
    if (isHuman(raw, step)) {
        rewriteJob(dir, raw, "status", "human", "pane", "");
        logMsg("pipeline waiting for human");
        return;
    }
    var dbuf: [8]u8 = undefined;
    const dname = std.fmt.bufPrint(&dbuf, "{d}", .{step}) catch return;
    const sd = std.fs.path.join(gpa, &.{ dir, dname }) catch return;
    defer gpa.free(sd);
    const sdz = gpa.dupeZ(u8, sd) catch return;
    defer gpa.free(sdz);
    _ = mkdir(sdz, 0o700);
    const ag = stageAgent(raw, step);
    const fresh = std.mem.eql(u8, jsonGet(raw, "new_tab"), "true");
    var pane_owned: ?[]u8 = if (fresh) null else loadPane(dir, ag);
    var tab_owned: ?[]u8 = if (fresh) null else loadTab(dir, ag);
    var made_tab = false;
    if (pane_owned == null) {
        var args_buf: [128]u8 = undefined;
        const args = std.fmt.bufPrintZ(&args_buf, "{{\"agent\":\"{s}\"}}", .{ag}) catch return;
        const res = callOp("tab.add", args.ptr) orelse {
            fail(dir, raw, "could not open a tab for the agent");
            return;
        };
        const p = jsonGet(res, "pane");
        const t = jsonGet(res, "tab");
        if (p.len > 0) savePane(dir, ag, p);
        if (t.len > 0) saveTab(dir, ag, t);
        gpa.free(res);
        if (tab_owned) |old| gpa.free(old);
        pane_owned = loadPane(dir, ag);
        tab_owned = loadTab(dir, ag);
        made_tab = true;
    }
    defer if (pane_owned) |p| gpa.free(p);
    defer if (tab_owned) |t| gpa.free(t);
    const pane = if (pane_owned) |p| std.mem.trim(u8, p, " \n\r\t") else "";
    const tab = if (tab_owned) |t| std.mem.trim(u8, t, " \n\r\t") else "";
    if (pane.len == 0) {
        fail(dir, raw, "the new tab reported no pane");
        return;
    }
    // Focus is what mounts a freshly created tab, so a new tab has to be
    // shown. A reused one is already alive: leave the user where they are.
    if (made_tab) focusTab(tab);
    rewriteJob(dir, raw, "pane", pane, "status", "arming");
    if (tab.len > 0) {
        const jp0 = std.fs.path.join(gpa, &.{ dir, "job.json" }) catch return;
        defer gpa.free(jp0);
        const raw_tab = readFile(jp0) orelse return;
        defer gpa.free(raw_tab);
        rewriteJob(dir, raw_tab, "tab", tab, null, null);
    }
    const task = jsonGet(raw, "task");
    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(gpa);
    var nbuf: [16]u8 = undefined;
    const nth = std.fmt.bufPrint(&nbuf, "{d} of {d}", .{ step + 1, n }) catch "1";
    prompt.appendSlice(gpa, "Workflow step ") catch return;
    prompt.appendSlice(gpa, nth) catch return;
    prompt.appendSlice(gpa, ": ") catch return;
    prompt.appendSlice(gpa, skill) catch return;
    prompt.appendSlice(gpa, "\nSteps: ") catch return;
    var si: u32 = 0;
    while (si < n) : (si += 1) {
        if (si > 0) prompt.appendSlice(gpa, " → ") catch return;
        if (si == step) prompt.appendSlice(gpa, "[") catch return;
        const sn = jsonGet(stepNth(raw, si), "name");
        prompt.appendSlice(gpa, if (sn.len > 0) sn else "step") catch return;
        if (si == step) prompt.appendSlice(gpa, "]") catch return;
    }
    prompt.appendSlice(gpa, "\nTask: ") catch return;
    prompt.appendSlice(gpa, task) catch return;
    prompt.appendSlice(gpa, "\n") catch return;
    if (step > 0) {
        var prev_buf: [32]u8 = undefined;
        const prev_rel = std.fmt.bufPrint(&prev_buf, "{d}/out.md", .{step - 1}) catch "";
        if (prev_rel.len > 0) {
            const prev_path = std.fs.path.join(gpa, &.{ dir, prev_rel }) catch "";
            if (prev_path.len > 0) {
                const prev = readCapped(prev_path, 6000);
                if (prev.len > 0) {
                    const prev_name = jsonGet(stepNth(raw, step - 1), "name");
                    prompt.appendSlice(gpa, "Previous step \"") catch return;
                    prompt.appendSlice(gpa, if (prev_name.len > 0) prev_name else "step") catch return;
                    prompt.appendSlice(gpa, "\" wrote:\n") catch return;
                    prompt.appendSlice(gpa, prev) catch return;
                    prompt.appendSlice(gpa, "\n") catch return;
                }
                if (prev.len > 0) gpa.free(prev);
                gpa.free(prev_path);
            }
        }
    }
    prompt.appendSlice(gpa, "Do only the step in brackets. Do not start the next step and do not ask the user to continue.\nWrite the result to ") catch return;
    prompt.appendSlice(gpa, sd) catch return;
    prompt.appendSlice(gpa, "/out.md\nWhen that file is written, create ") catch return;
    prompt.appendSlice(gpa, sd) catch return;
    prompt.appendSlice(gpa, "/DONE containing ok, then stop.\n") catch return;
    // The tab we just asked for has no pty yet — its process is still being
    // spawned. Park the prompt and let the tick send it once the pane can
    // take keystrokes. Typing now would go straight into the void.
    const pp = std.fs.path.join(gpa, &.{ sd, "prompt.txt" }) catch return;
    defer gpa.free(pp);
    writeFile(pp, prompt.items);
    var now_buf: [24]u8 = undefined;
    const now_s = std.fmt.bufPrint(&now_buf, "{d}", .{time(null)}) catch return;
    const jp = std.fs.path.join(gpa, &.{ dir, "job.json" }) catch return;
    defer gpa.free(jp);
    const raw2 = readFile(jp) orelse return;
    defer gpa.free(raw2);
    rewriteJob(dir, raw2, "started_s", now_s, "had_busy", "false");
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "step {d} armed on pane {s}", .{ step + 1, pane }) catch "step armed";
    logLine(dir, msg);
}

// How long the agent gets to come up before we call it broken.
const kArmTimeout: i64 = 45;
// A TUI that has just settled needs a beat before it owns the keyboard.
const kArmSettle: i64 = 2;

fn armStep(dir: []const u8, raw: []const u8, step: u32, pane: []const u8) void {
    if (pane.len == 0) {
        fail(dir, raw, "no pane to send the step to");
        return;
    }
    const started = std.fmt.parseInt(i64, jsonGet(raw, "started_s"), 10) catch 0;
    const now = time(null);
    const act = paneActivity(pane) orelse {
        noteMiss(dir, raw);
        return;
    };
    if (act == 0) {
        if (started > 0 and now >= started + kArmTimeout)
            fail(dir, raw, "the agent never started — open its tab to see why");
        return;
    }
    // 3 = still working: booting. Remember it, so a later standby means ready.
    if (act == 3) {
        if (!std.mem.eql(u8, jsonGet(raw, "had_busy"), "true"))
            rewriteJob(dir, raw, "had_busy", "true", null, null);
        return;
    }
    if (started > 0 and now < started + kArmSettle) return;
    var dbuf: [24]u8 = undefined;
    const dname = std.fmt.bufPrint(&dbuf, "{d}/prompt.txt", .{step}) catch return;
    const pp = std.fs.path.join(gpa, &.{ dir, dname }) catch return;
    defer gpa.free(pp);
    const prompt = readFile(pp) orelse {
        fail(dir, raw, "the step prompt went missing");
        return;
    };
    defer gpa.free(prompt);
    if (!sendPrompt(pane, prompt)) {
        if (started > 0 and now >= started + kArmTimeout)
            fail(dir, raw, "the agent pane would not take the prompt");
        return;
    }
    var now_buf: [24]u8 = undefined;
    const now_s = std.fmt.bufPrint(&now_buf, "{d}", .{now}) catch return;
    rewriteJob(dir, raw, "status", "running", "started_s", now_s);
    const jp = std.fs.path.join(gpa, &.{ dir, "job.json" }) catch return;
    defer gpa.free(jp);
    const raw2 = readFile(jp) orelse return;
    defer gpa.free(raw2);
    rewriteJob(dir, raw2, "had_busy", "false", null, null);
    var msg_buf: [48]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "step {d} prompt sent", .{step + 1}) catch "prompt sent";
    logLine(dir, msg);
}

fn rewriteJob(dir: []const u8, raw: []const u8, k1: []const u8, v1: []const u8, k2: ?[]const u8, v2: ?[]const u8) void {
    var id = jsonGet(raw, "id");
    if (id.len == 0) id = "job";
    const task = jsonGet(raw, "task");
    const agent = jsonGet(raw, "agent");
    var pane = jsonGet(raw, "pane");
    var tab = jsonGet(raw, "tab");
    var status = jsonGet(raw, "status");
    var step = jsonGet(raw, "step");
    var had = jsonGet(raw, "had_busy");
    var started = jsonGet(raw, "started_s");
    var reason = jsonGet(raw, "reason");
    // Any write at all means the UI answered us this tick, so the miss count
    // only survives while nothing else is happening.
    var misses: []const u8 = "0";
    const new_tab = jsonGet(raw, "new_tab");
    if (std.mem.eql(u8, k1, "pane")) pane = v1;
    if (std.mem.eql(u8, k1, "tab")) tab = v1;
    if (std.mem.eql(u8, k1, "status")) status = v1;
    if (std.mem.eql(u8, k1, "step")) step = v1;
    if (std.mem.eql(u8, k1, "had_busy")) had = v1;
    if (std.mem.eql(u8, k1, "misses")) misses = v1;
    if (std.mem.eql(u8, k1, "reason")) reason = v1;
    var now_buf: [24]u8 = undefined;
    if (std.mem.eql(u8, k1, "started_s")) {
        if (std.mem.eql(u8, v1, "now")) {
            started = std.fmt.bufPrint(&now_buf, "{d}", .{time(null)}) catch "0";
        } else started = v1;
    }
    if (k2) |k| {
        const v = v2 orelse "";
        if (std.mem.eql(u8, k, "pane")) pane = v;
        if (std.mem.eql(u8, k, "tab")) tab = v;
        if (std.mem.eql(u8, k, "status")) status = v;
        if (std.mem.eql(u8, k, "step")) step = v;
        if (std.mem.eql(u8, k, "had_busy")) had = v;
        if (std.mem.eql(u8, k, "started_s")) started = v;
        if (std.mem.eql(u8, k, "misses")) misses = v;
        if (std.mem.eql(u8, k, "reason")) reason = v;
    }
    if (status.len == 0) status = "queued";
    if (step.len == 0) step = "0";
    if (had.len == 0) had = "false";
    if (started.len == 0) started = "0";
    if (agent.len == 0) return;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    body.appendSlice(gpa, "{\"id\":\"") catch return;
    body.appendSlice(gpa, id) catch return;
    body.appendSlice(gpa, "\",\"status\":\"") catch return;
    body.appendSlice(gpa, status) catch return;
    body.appendSlice(gpa, "\",\"step\":") catch return;
    body.appendSlice(gpa, step) catch return;
    body.appendSlice(gpa, ",\"agent\":\"") catch return;
    body.appendSlice(gpa, agent) catch return;
    body.appendSlice(gpa, "\",\"task\":\"") catch return;
    body.appendSlice(gpa, task) catch return;
    body.appendSlice(gpa, "\",\"pane\":\"") catch return;
    body.appendSlice(gpa, pane) catch return;
    if (tab.len > 0) {
        body.appendSlice(gpa, "\",\"tab\":\"") catch return;
        body.appendSlice(gpa, tab) catch return;
    }
    body.appendSlice(gpa, "\",\"had_busy\":") catch return;
    body.appendSlice(gpa, had) catch return;
    body.appendSlice(gpa, ",\"started_s\":") catch return;
    body.appendSlice(gpa, started) catch return;
    body.appendSlice(gpa, ",\"new_tab\":") catch return;
    body.appendSlice(gpa, if (new_tab.len > 0) new_tab else "false") catch return;
    body.appendSlice(gpa, ",\"misses\":") catch return;
    body.appendSlice(gpa, if (misses.len > 0) misses else "0") catch return;
    if (reason.len > 0) {
        body.appendSlice(gpa, ",\"reason\":\"") catch return;
        escapeJson(&body, reason);
        body.appendSlice(gpa, "\"") catch return;
    }
    const workflow = jsonGet(raw, "workflow");
    if (workflow.len > 0) {
        body.appendSlice(gpa, ",\"workflow\":\"") catch return;
        body.appendSlice(gpa, workflow) catch return;
        body.appendSlice(gpa, "\"") catch return;
    }
    const steps = jsonRaw(raw, "steps");
    if (steps.len > 0) {
        body.appendSlice(gpa, ",\"steps\":") catch return;
        body.appendSlice(gpa, steps) catch return;
    }
    const agents = jsonGet(raw, "agents");
    if (agents.len > 0) {
        body.appendSlice(gpa, ",\"agents\":\"") catch return;
        body.appendSlice(gpa, agents) catch return;
        body.appendSlice(gpa, "\"") catch return;
    }
    body.appendSlice(gpa, "}\n") catch return;
    const jp = std.fs.path.join(gpa, &.{ dir, "job.json" }) catch return;
    defer gpa.free(jp);
    writeFile(jp, body.items);
}
