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
    var done_path_buf: [8]u8 = undefined;
    const done_name = std.fmt.bufPrint(&done_path_buf, "{d}/DONE", .{step}) catch return;
    const done_path = std.fs.path.join(gpa, &.{ dir, done_name }) catch return;
    defer gpa.free(done_path);
    if (exists(done_path)) {
        advance(dir, raw);
        return;
    }
    var pane_z_buf: [80]u8 = undefined;
    const pane_z = std.fmt.bufPrintZ(&pane_z_buf, "{{\"pane\":\"{s}\"}}", .{pane}) catch return;
    const act_json = callOp("pane.activity", pane_z.ptr) orelse return;
    defer gpa.free(act_json);
    const act_s = jsonGet(act_json, "activity");
    const act = std.fmt.parseInt(i32, act_s, 10) catch -1;
    const had = jsonGet(raw, "had_busy");
    if (act == 3 and !std.mem.eql(u8, had, "true")) {
        rewriteJob(dir, raw, "had_busy", "true", null, null);
        return;
    }
    const started_s = jsonGet(raw, "started_s");
    const started = std.fmt.parseInt(i64, started_s, 10) catch 0;
    const now = time(null);
    const idle = (act == 1 or act == 2) and std.mem.eql(u8, had, "true") and started > 0 and now >= started + 8;
    if (idle) advance(dir, raw);
}

fn sendPrompt(pane: []const u8, text: []const u8) void {
    var args: std.ArrayList(u8) = .empty;
    defer args.deinit(gpa);
    args.appendSlice(gpa, "{\"pane\":\"") catch return;
    args.appendSlice(gpa, pane) catch return;
    args.appendSlice(gpa, "\",\"submit\":true,\"text\":\"") catch return;
    escapeJson(&args, text);
    args.appendSlice(gpa, "\"}") catch return;
    const z = gpa.dupeZ(u8, args.items) catch return;
    defer gpa.free(z);
    const res = callOp("pane.input", z.ptr);
    if (res) |r| gpa.free(r);
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
    if (pane_owned == null) {
        var args_buf: [128]u8 = undefined;
        const args = std.fmt.bufPrintZ(&args_buf, "{{\"agent\":\"{s}\"}}", .{ag}) catch return;
        const res = callOp("tab.add", args.ptr) orelse return;
        const p = jsonGet(res, "pane");
        if (p.len > 0) savePane(dir, ag, p);
        gpa.free(res);
        pane_owned = loadPane(dir, ag);
    }
    defer if (pane_owned) |p| gpa.free(p);
    const pane = if (pane_owned) |p| std.mem.trim(u8, p, " \n\r\t") else "";
    if (pane.len == 0) return;
    rewriteJob(dir, raw, "pane", pane, "status", "running");
    const task = jsonGet(raw, "task");
    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(gpa);
    prompt.appendSlice(gpa, "You are stage ") catch return;
    prompt.appendSlice(gpa, skill) catch return;
    prompt.appendSlice(gpa, " in a pipeline. Do not wait for a human after this message.\nTask: ") catch return;
    prompt.appendSlice(gpa, task) catch return;
    prompt.appendSlice(gpa, "\nThis stage's only job is: ") catch return;
    prompt.appendSlice(gpa, skill) catch return;
    prompt.appendSlice(gpa, ".\nPrior stage artifacts are in ") catch return;
    prompt.appendSlice(gpa, dir) catch return;
    prompt.appendSlice(gpa, "\nWrite your output to ") catch return;
    prompt.appendSlice(gpa, sd) catch return;
    prompt.appendSlice(gpa, "/out.md\nWhen this stage is finished, write ") catch return;
    prompt.appendSlice(gpa, sd) catch return;
    prompt.appendSlice(gpa, "/DONE containing ok. Then stop.\n") catch return;
    sendPrompt(pane, prompt.items);
    var now_buf: [24]u8 = undefined;
    const now_s = std.fmt.bufPrint(&now_buf, "{d}", .{time(null)}) catch return;
    const jp = std.fs.path.join(gpa, &.{ dir, "job.json" }) catch return;
    defer gpa.free(jp);
    const raw2 = readFile(jp) orelse return;
    defer gpa.free(raw2);
    rewriteJob(dir, raw2, "started_s", now_s, "had_busy", "false");
}

fn rewriteJob(dir: []const u8, raw: []const u8, k1: []const u8, v1: []const u8, k2: ?[]const u8, v2: ?[]const u8) void {
    var id = jsonGet(raw, "id");
    if (id.len == 0) id = "job";
    const task = jsonGet(raw, "task");
    const agent = jsonGet(raw, "agent");
    var pane = jsonGet(raw, "pane");
    var status = jsonGet(raw, "status");
    var step = jsonGet(raw, "step");
    var had = jsonGet(raw, "had_busy");
    var started = jsonGet(raw, "started_s");
    const new_tab = jsonGet(raw, "new_tab");
    if (std.mem.eql(u8, k1, "pane")) pane = v1;
    if (std.mem.eql(u8, k1, "status")) status = v1;
    if (std.mem.eql(u8, k1, "step")) step = v1;
    if (std.mem.eql(u8, k1, "had_busy")) had = v1;
    var now_buf: [24]u8 = undefined;
    if (std.mem.eql(u8, k1, "started_s")) {
        if (std.mem.eql(u8, v1, "now")) {
            started = std.fmt.bufPrint(&now_buf, "{d}", .{time(null)}) catch "0";
        } else started = v1;
    }
    if (k2) |k| {
        const v = v2 orelse "";
        if (std.mem.eql(u8, k, "pane")) pane = v;
        if (std.mem.eql(u8, k, "status")) status = v;
        if (std.mem.eql(u8, k, "step")) step = v;
        if (std.mem.eql(u8, k, "had_busy")) had = v;
        if (std.mem.eql(u8, k, "started_s")) started = v;
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
    body.appendSlice(gpa, "\",\"had_busy\":") catch return;
    body.appendSlice(gpa, had) catch return;
    body.appendSlice(gpa, ",\"started_s\":") catch return;
    body.appendSlice(gpa, started) catch return;
    body.appendSlice(gpa, ",\"new_tab\":") catch return;
    body.appendSlice(gpa, if (new_tab.len > 0) new_tab else "false") catch return;
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
