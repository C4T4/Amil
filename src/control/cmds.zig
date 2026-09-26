const std = @import("std");
const bus = @import("bus.zig");
const rpc = @import("rpc.zig");
const json = @import("../json.zig");

const gpa = std.heap.c_allocator;

extern fn at_store_dir(ptr: ?*const anyopaque) ?[*:0]const u8;
extern fn at_store_workspace_count(ptr: ?*const anyopaque) u32;
extern fn at_store_id(ptr: ?*const anyopaque, index: u32) ?[*:0]const u8;
extern fn at_store_active_index(ptr: ?*const anyopaque) i32;
extern fn at_store_add_tab(ptr: ?*anyopaque, workspace: u32, agent: ?[*:0]const u8) c_int;
extern fn at_store_tab_count(ptr: ?*const anyopaque, workspace: u32) u32;
extern fn at_store_tab_id(ptr: ?*const anyopaque, workspace: u32, tab: u32) ?[*:0]const u8;
extern fn at_store_layout_build(ptr: ?*anyopaque, workspace: u32, tab: u32) c_int;
extern fn at_store_layout_pane_id(ptr: ?*const anyopaque, index: u32) ?[*:0]const u8;
extern fn at_store_name(ptr: ?*const anyopaque, index: u32) ?[*:0]const u8;
extern fn at_store_agent(ptr: ?*const anyopaque, index: u32) ?[*:0]const u8;
extern fn at_store_folder_count(ptr: ?*const anyopaque, index: u32) u32;
extern fn at_store_folder(ptr: ?*const anyopaque, index: u32, folder: u32) ?[*:0]const u8;
extern fn at_store_tab_agent(ptr: ?*const anyopaque, workspace: u32, tab: u32) ?[*:0]const u8;
extern fn at_store_tab_name(ptr: ?*const anyopaque, workspace: u32, tab: u32) ?[*:0]const u8;
extern fn at_store_set_active(ptr: ?*anyopaque, index: i32) void;
extern fn at_store_set_active_tab(ptr: ?*anyopaque, workspace: u32, tab: i32) c_int;

extern fn at_control_store() ?*anyopaque;

var dummy: u8 = 0;
var ui_ctx: ?*anyopaque = null;
var ui_reload: ?*const fn (?*anyopaque) callconv(.c) c_int = null;
var ui_pane_write: ?*const fn (?*anyopaque, ?[*:0]const u8, ?*const anyopaque, usize, c_int) callconv(.c) c_int = null;
var ui_pane_activity: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) c_int = null;
var ui_tab_add: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int = null;
var ui_focus_ws: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) c_int = null;
var ui_focus_tab: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int = null;

pub fn bindUi(
    ctx: ?*anyopaque,
    reload: ?*const fn (?*anyopaque) callconv(.c) c_int,
    pane_write: ?*const fn (?*anyopaque, ?[*:0]const u8, ?*const anyopaque, usize, c_int) callconv(.c) c_int,
    pane_activity: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) c_int,
    tab_add: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int,
    focus_ws: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) c_int,
    focus_tab: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int,
) void {
    ui_ctx = ctx;
    ui_reload = reload;
    ui_pane_write = pane_write;
    ui_pane_activity = pane_activity;
    ui_tab_add = tab_add;
    ui_focus_ws = focus_ws;
    ui_focus_tab = focus_tab;
}

extern fn getpid() c_int;
extern fn time(t: ?*i64) i64;

var started_s: i64 = 0;

fn nowMs() i64 {
    return time(null) * 1000;
}

fn ping(_: *anyopaque, _: []const u8, _: bus.Cap, out: *std.ArrayList(u8)) bus.BusError!void {
    var buf: [96]u8 = undefined;
    const pid = getpid();
    const up: i64 = if (started_s == 0) 0 else nowMs() - started_s * 1000;
    const s = std.fmt.bufPrint(&buf, "{{\"pid\":{d},\"uptime_ms\":{d},\"clients\":0}}", .{
        pid,
        up,
    }) catch return error.Internal;
    out.appendSlice(gpa, s) catch return error.Internal;
}

fn caps(_: *anyopaque, _: []const u8, have: bus.Cap, out: *std.ArrayList(u8)) bus.BusError!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "{\"caps\":[") catch return error.Internal;
    var first = true;
    const fields = .{
        .{ "read", have.read },
        .{ "focus", have.focus },
        .{ "input", have.input },
        .{ "session", have.session },
        .{ "layout", have.layout },
        .{ "fs", have.fs },
        .{ "admin", have.admin },
        .{ "pair", have.pair },
    };
    inline for (fields) |f| {
        if (f[1]) {
            if (!first) buf.append(gpa, ',') catch return error.Internal;
            first = false;
            buf.append(gpa, '"') catch return error.Internal;
            buf.appendSlice(gpa, f[0]) catch return error.Internal;
            buf.append(gpa, '"') catch return error.Internal;
        }
    }
    buf.appendSlice(gpa, "],\"ops\":[") catch return error.Internal;
    first = true;
    var i: u8 = 0;
    while (i < bus.opCount()) : (i += 1) {
        const name = bus.opName(i) orelse break;
        if (!first) buf.append(gpa, ',') catch return error.Internal;
        first = false;
        buf.append(gpa, '"') catch return error.Internal;
        buf.appendSlice(gpa, name) catch return error.Internal;
        buf.append(gpa, '"') catch return error.Internal;
    }
    buf.appendSlice(gpa, "]}") catch return error.Internal;
    out.appendSlice(gpa, buf.items) catch return error.Internal;
}

fn paneInput(_: *anyopaque, args: []const u8, _: bus.Cap, out: *std.ArrayList(u8)) bus.BusError!void {
    const a = rpc.parseInputArgs(args) catch return error.BadArgs;
    if (a.pane.len == 0) return error.BadArgs;
    const write = ui_pane_write orelse return error.Unavailable;
    const pane_z = gpa.dupeZ(u8, a.pane) catch return error.Internal;
    defer gpa.free(pane_z);
    const text_z = json.unescapeAlloc(gpa, a.text) catch return error.Internal;
    defer gpa.free(text_z);
    const rc = write(ui_ctx, pane_z.ptr, text_z.ptr, text_z.len, if (a.submit) 1 else 0);
    if (rc != 0) return error.NotFound;
    out.appendSlice(gpa, "{}") catch return error.Internal;
}

fn paneActivity(_: *anyopaque, args: []const u8, _: bus.Cap, out: *std.ArrayList(u8)) bus.BusError!void {
    const a = rpc.parseInputArgs(args) catch return error.BadArgs;
    if (a.pane.len == 0) return error.BadArgs;
    const act = ui_pane_activity orelse return error.Unavailable;
    const pane_z = gpa.dupeZ(u8, a.pane) catch return error.Internal;
    defer gpa.free(pane_z);
    const v = act(ui_ctx, pane_z.ptr);
    if (v < 0) return error.NotFound;
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{{\"activity\":{d}}}", .{v}) catch return error.Internal;
    out.appendSlice(gpa, s) catch return error.Internal;
}

fn tabAdd(_: *anyopaque, args: []const u8, _: bus.Cap, out: *std.ArrayList(u8)) bus.BusError!void {
    const add = ui_tab_add orelse return error.Unavailable;
    var p = json.Parser{ .src = args };
    p.eat('{') catch return error.BadArgs;
    var ws: []const u8 = "";
    var agent: []const u8 = "grok";
    var first = true;
    while (true) {
        p.skipWs();
        if (p.peek() == '}') break;
        if (!first) p.eat(',') catch return error.BadArgs;
        first = false;
        const k = p.string() catch return error.BadArgs;
        p.eat(':') catch return error.BadArgs;
        if (std.mem.eql(u8, k, "workspace")) {
            ws = p.string() catch return error.BadArgs;
        } else if (std.mem.eql(u8, k, "agent")) {
            agent = p.string() catch return error.BadArgs;
        } else {
            p.skipValue() catch return error.BadArgs;
        }
    }
    const ws_z = gpa.dupeZ(u8, ws) catch return error.Internal;
    defer gpa.free(ws_z);
    const ag_z = gpa.dupeZ(u8, agent) catch return error.Internal;
    defer gpa.free(ag_z);
    const rc = add(ui_ctx, if (ws.len > 0) ws_z.ptr else null, ag_z.ptr, null);
    if (rc != 0) return error.Internal;
    const store = at_control_store() orelse return error.Unavailable;
    var wi: i32 = at_store_active_index(store);
    if (ws.len > 0) {
        const nws = at_store_workspace_count(store);
        var i: u32 = 0;
        wi = -1;
        while (i < nws) : (i += 1) {
            const id = at_store_id(store, i) orelse continue;
            if (std.mem.eql(u8, std.mem.span(id), ws)) {
                wi = @intCast(i);
                break;
            }
        }
    }
    if (wi < 0) return error.NotFound;
    const ntab = at_store_tab_count(store, @intCast(wi));
    if (ntab == 0) return error.Internal;
    const tid = at_store_tab_id(store, @intCast(wi), ntab - 1) orelse return error.Internal;
    _ = at_store_layout_build(store, @intCast(wi), ntab - 1);
    const pane = at_store_layout_pane_id(store, 0) orelse tid;
    out.appendSlice(gpa, "{\"tab\":\"") catch return error.Internal;
    out.appendSlice(gpa, std.mem.span(tid)) catch return error.Internal;
    out.appendSlice(gpa, "\",\"pane\":\"") catch return error.Internal;
    out.appendSlice(gpa, std.mem.span(pane)) catch return error.Internal;
    out.appendSlice(gpa, "\"}") catch return error.Internal;
}

fn pipelinePush(_: *anyopaque, args: []const u8, _: bus.Cap, out: *std.ArrayList(u8)) bus.BusError!void {
    var p = json.Parser{ .src = args };
    p.eat('{') catch return error.BadArgs;
    var task: []const u8 = "";
    var agent: []const u8 = "grok";
    var workflow: []const u8 = "";
    var steps_raw: []const u8 = "";
    var new_tab: bool = false;
    var first = true;
    while (true) {
        p.skipWs();
        if (p.peek() == '}') break;
        if (!first) p.eat(',') catch return error.BadArgs;
        first = false;
        const k = p.string() catch return error.BadArgs;
        p.eat(':') catch return error.BadArgs;
        if (std.mem.eql(u8, k, "task")) {
            task = p.string() catch return error.BadArgs;
        } else if (std.mem.eql(u8, k, "agent")) {
            agent = p.string() catch return error.BadArgs;
        } else if (std.mem.eql(u8, k, "workflow")) {
            workflow = p.string() catch return error.BadArgs;
        } else if (std.mem.eql(u8, k, "steps")) {
            steps_raw = p.rawValue() catch return error.BadArgs;
        } else if (std.mem.eql(u8, k, "new_tab")) {
            new_tab = p.boolean() catch return error.BadArgs;
        } else {
            p.skipValue() catch return error.BadArgs;
        }
    }
    if (task.len == 0) return error.BadArgs;
    if (steps_raw.len < 2 or steps_raw[0] != '[') {
        steps_raw = "[{\"name\":\"do\",\"kind\":\"agent\",\"agent\":\"grok\"}]";
    }
    const store = at_control_store() orelse return error.Unavailable;
    const dir_c = at_store_dir(store) orelse return error.Unavailable;
    const dir = std.mem.span(dir_c);
    var id_buf: [16]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{x}", .{@as(u64, @intCast(time(null)))}) catch return error.Internal;
    const qdir = std.fs.path.join(gpa, &.{ dir, "queue", id }) catch return error.Internal;
    defer gpa.free(qdir);
    const qz = gpa.dupeZ(u8, qdir) catch return error.Internal;
    defer gpa.free(qz);
    mkdirParents(qz);
    const path = std.fs.path.join(gpa, &.{ qdir, "job.json" }) catch return error.Internal;
    defer gpa.free(path);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    body.appendSlice(gpa, "{\"id\":\"") catch return error.Internal;
    body.appendSlice(gpa, id) catch return error.Internal;
    body.appendSlice(gpa, "\",\"status\":\"queued\",\"step\":0,\"agent\":\"") catch return error.Internal;
    json.jsonEscape(gpa, &body, agent) catch return error.Internal;
    body.appendSlice(gpa, "\",\"task\":\"") catch return error.Internal;
    const task_u = json.unescapeAlloc(gpa, task) catch return error.Internal;
    defer gpa.free(task_u);
    json.jsonEscape(gpa, &body, task_u) catch return error.Internal;
    body.appendSlice(gpa, "\",\"pane\":\"\",\"had_busy\":false,\"started_s\":0,\"new_tab\":") catch return error.Internal;
    body.appendSlice(gpa, if (new_tab) "true" else "false") catch return error.Internal;
    if (workflow.len > 0) {
        body.appendSlice(gpa, ",\"workflow\":\"") catch return error.Internal;
        json.jsonEscape(gpa, &body, workflow) catch return error.Internal;
        body.appendSlice(gpa, "\"") catch return error.Internal;
    }
    body.appendSlice(gpa, ",\"steps\":") catch return error.Internal;
    body.appendSlice(gpa, steps_raw) catch return error.Internal;
    body.appendSlice(gpa, "}\n") catch return error.Internal;
    writeFile(path, body.items) catch return error.Internal;
    out.appendSlice(gpa, "{\"id\":\"") catch return error.Internal;
    out.appendSlice(gpa, id) catch return error.Internal;
    out.appendSlice(gpa, "\"}") catch return error.Internal;
}

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

fn mkdirParents(path: [*:0]const u8) void {
    var buf: [512]u8 = undefined;
    const s = std.mem.span(path);
    if (s.len >= buf.len) return;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (buf[i] == '/') {
            buf[i] = 0;
            _ = mkdir(@ptrCast(&buf), 0o700);
            buf[i] = '/';
        }
    }
    _ = mkdir(path, 0o700);
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(file: ?*anyopaque) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, file: ?*anyopaque) usize;

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    const f = fopen(z, "wb") orelse return error.Internal;
    defer _ = fclose(f);
    const n = fwrite(bytes.ptr, 1, bytes.len, f);
    if (n != bytes.len) return error.Internal;
}

fn findWs(store: ?*anyopaque, id: []const u8) i32 {
    if (id.len == 0) return at_store_active_index(store);
    const n = at_store_workspace_count(store);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const wid = at_store_id(store, i) orelse continue;
        if (std.mem.eql(u8, std.mem.span(wid), id)) return @intCast(i);
    }
    return -1;
}

fn parseField(args: []const u8, key: []const u8) []const u8 {
    var p = json.Parser{ .src = args };
    p.eat('{') catch return "";
    var first = true;
    while (true) {
        p.skipWs();
        if (p.peek() == '}' or p.peek() == null) return "";
        if (!first) p.eat(',') catch return "";
        first = false;
        const k = p.string() catch return "";
        p.eat(':') catch return "";
        if (std.mem.eql(u8, k, key)) return p.string() catch "";
        p.skipValue() catch return "";
    }
}

fn workspaceList(_: *anyopaque, _: []const u8, _: bus.Cap, out: *std.ArrayList(u8)) bus.BusError!void {
    const store = at_control_store() orelse return error.Unavailable;
    out.appendSlice(gpa, "{\"workspaces\":[") catch return error.Internal;
    const n = at_store_workspace_count(store);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (i != 0) out.append(gpa, ',') catch return error.Internal;
        out.appendSlice(gpa, "{\"id\":\"") catch return error.Internal;
        if (at_store_id(store, i)) |id| json.jsonEscape(gpa, out, std.mem.span(id)) catch return error.Internal;
        out.appendSlice(gpa, "\",\"name\":\"") catch return error.Internal;
        if (at_store_name(store, i)) |nm| json.jsonEscape(gpa, out, std.mem.span(nm)) catch return error.Internal;
        out.appendSlice(gpa, "\",\"agent\":\"") catch return error.Internal;
        if (at_store_agent(store, i)) |ag| json.jsonEscape(gpa, out, std.mem.span(ag)) catch return error.Internal;
        out.appendSlice(gpa, "\",\"folders\":[") catch return error.Internal;
        const nf = at_store_folder_count(store, i);
        var f: u32 = 0;
        while (f < nf) : (f += 1) {
            if (f != 0) out.append(gpa, ',') catch return error.Internal;
            out.append(gpa, '"') catch return error.Internal;
            if (at_store_folder(store, i, f)) |p| json.jsonEscape(gpa, out, std.mem.span(p)) catch return error.Internal;
            out.append(gpa, '"') catch return error.Internal;
        }
        out.appendSlice(gpa, "]}") catch return error.Internal;
    }
    out.appendSlice(gpa, "]}") catch return error.Internal;
}

fn tabList(_: *anyopaque, args: []const u8, _: bus.Cap, out: *std.ArrayList(u8)) bus.BusError!void {
    const store = at_control_store() orelse return error.Unavailable;
    const ws = parseField(args, "workspace");
    const wi = findWs(store, ws);
    if (wi < 0) return error.NotFound;
    out.appendSlice(gpa, "{\"tabs\":[") catch return error.Internal;
    const n = at_store_tab_count(store, @intCast(wi));
    var t: u32 = 0;
    while (t < n) : (t += 1) {
        if (t != 0) out.append(gpa, ',') catch return error.Internal;
        out.appendSlice(gpa, "{\"id\":\"") catch return error.Internal;
        if (at_store_tab_id(store, @intCast(wi), t)) |id| json.jsonEscape(gpa, out, std.mem.span(id)) catch return error.Internal;
        out.appendSlice(gpa, "\",\"agent\":\"") catch return error.Internal;
        if (at_store_tab_agent(store, @intCast(wi), t)) |ag| json.jsonEscape(gpa, out, std.mem.span(ag)) catch return error.Internal;
        out.appendSlice(gpa, "\",\"name\":\"") catch return error.Internal;
        if (at_store_tab_name(store, @intCast(wi), t)) |nm| json.jsonEscape(gpa, out, std.mem.span(nm)) catch return error.Internal;
        out.appendSlice(gpa, "\"}") catch return error.Internal;
    }
    out.appendSlice(gpa, "]}") catch return error.Internal;
}

fn workspaceFocus(_: *anyopaque, args: []const u8, _: bus.Cap, out: *std.ArrayList(u8)) bus.BusError!void {
    const store = at_control_store() orelse return error.Unavailable;
    const ws = parseField(args, "workspace");
    if (ws.len == 0) return error.BadArgs;
    const wi = findWs(store, ws);
    if (wi < 0) return error.NotFound;
    at_store_set_active(store, wi);
    const z = gpa.dupeZ(u8, ws) catch return error.Internal;
    defer gpa.free(z);
    if (ui_focus_ws) |f| {
        if (f(ui_ctx, z.ptr) != 0) return error.Internal;
    } else if (ui_reload) |r| _ = r(ui_ctx);
    out.appendSlice(gpa, "{}") catch return error.Internal;
}

fn tabFocus(_: *anyopaque, args: []const u8, _: bus.Cap, out: *std.ArrayList(u8)) bus.BusError!void {
    const store = at_control_store() orelse return error.Unavailable;
    const ws = parseField(args, "workspace");
    const tab = parseField(args, "tab");
    if (tab.len == 0) return error.BadArgs;
    const wi = findWs(store, ws);
    if (wi < 0) return error.NotFound;
    const n = at_store_tab_count(store, @intCast(wi));
    var ti: i32 = -1;
    var t: u32 = 0;
    while (t < n) : (t += 1) {
        const id = at_store_tab_id(store, @intCast(wi), t) orelse continue;
        if (std.mem.eql(u8, std.mem.span(id), tab)) {
            ti = @intCast(t);
            break;
        }
    }
    if (ti < 0) return error.NotFound;
    at_store_set_active(store, wi);
    _ = at_store_set_active_tab(store, @intCast(wi), ti);
    const ws_z = gpa.dupeZ(u8, if (ws.len > 0) ws else std.mem.span(at_store_id(store, @intCast(wi)) orelse return error.Internal)) catch return error.Internal;
    defer gpa.free(ws_z);
    const tab_z = gpa.dupeZ(u8, tab) catch return error.Internal;
    defer gpa.free(tab_z);
    if (ui_focus_tab) |f| {
        if (f(ui_ctx, ws_z.ptr, tab_z.ptr) != 0) return error.Internal;
    } else if (ui_reload) |r| _ = r(ui_ctx);
    out.appendSlice(gpa, "{}") catch return error.Internal;
}

pub fn registerAll() void {
    started_s = time(null);
    const ctx: *anyopaque = @ptrCast(&dummy);
    bus.register("core.ping", .{}, ctx, ping) catch {};
    bus.register("core.caps", .{}, ctx, caps) catch {};
    bus.register("pane.input", .{ .input = true }, ctx, paneInput) catch {};
    bus.register("pane.activity", .{ .read = true }, ctx, paneActivity) catch {};
    bus.register("tab.add", .{ .session = true }, ctx, tabAdd) catch {};
    bus.register("tab.list", .{ .read = true }, ctx, tabList) catch {};
    bus.register("tab.focus", .{ .focus = true }, ctx, tabFocus) catch {};
    bus.register("workspace.list", .{ .read = true }, ctx, workspaceList) catch {};
    bus.register("workspace.focus", .{ .focus = true }, ctx, workspaceFocus) catch {};
    bus.register("pipeline.push", .{ .fs = true, .session = true }, ctx, pipelinePush) catch {};
}

test "cmds ping registers" {
    bus.reset();
    registerAll();
    try std.testing.expect(bus.opCount() >= 2);
    try std.testing.expectEqualStrings("core.ping", bus.opName(0).?);
}
