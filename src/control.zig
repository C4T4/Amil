const std = @import("std");
const bus = @import("control/bus.zig");
const cmds = @import("control/cmds.zig");
const rpc = @import("control/rpc.zig");
const json = @import("json.zig");
const unix = @import("control/unix.zig");
const plugin = @import("control/plugin.zig");
const config_mod = @import("control/config.zig");

const gpa = std.heap.c_allocator;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
extern fn at_store_dir(ptr: ?*const anyopaque) ?[*:0]const u8;

const SIGPIPE: c_int = 13;

fn ignorePipe(_: c_int) callconv(.c) void {}

var started: bool = false;
var last_error: [:0]const u8 = "";
var error_buf: [256]u8 = undefined;
var store_ptr: ?*anyopaque = null;
var io_copy: unix.ControlIO = .{};
var have_io: bool = false;
pub const ControlUI = extern struct {
    ctx: ?*anyopaque = null,
    reload: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    focus_workspace: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) c_int = null,
    focus_tab: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int = null,
    focus_pane: ?*const fn (?*anyopaque, ?[*:0]const u8, c_int) callconv(.c) c_int = null,
    pane_write: ?*const fn (?*anyopaque, ?[*:0]const u8, ?*const anyopaque, usize, c_int) callconv(.c) c_int = null,
    pane_paste_path: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int = null,
    pane_paste_png: ?*const fn (?*anyopaque, ?[*:0]const u8, ?*const anyopaque, usize) callconv(.c) c_int = null,
    pane_activity: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) c_int = null,
    tab_activity: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) c_int = null,
    workspace_activity: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) c_int = null,
    tab_add: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int = null,
    tab_close: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int = null,
    pane_close: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) c_int = null,
    pane_split: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, c_int) callconv(.c) c_int = null,
    workspace_create: ?*const fn (?*anyopaque, ?[*:0]const u8, [*c]const ?[*:0]const u8, u32, ?[*:0]const u8) callconv(.c) c_int = null,
    workspace_close: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) c_int = null,
};
var ui_copy: ControlUI = .{};
var have_ui: bool = false;
var live_cfg: config_mod.Config = .{};
var plugin_dir_z: ?[:0]u8 = null;

const max_cat = 16;
const CatRow = struct {
    id: [33]u8 = [_]u8{0} ** 33,
    title: [48]u8 = [_]u8{0} ** 48,
    requires: [48]u8 = [_]u8{0} ** 48,
    present: bool = false,
    enabled: bool = false,
    loaded: bool = false,
};
var catalog: [max_cat]CatRow = undefined;
var catalog_n: u32 = 0;

fn setError(msg: []const u8) void {
    const n = @min(msg.len, error_buf.len - 1);
    @memcpy(error_buf[0..n], msg[0..n]);
    error_buf[n] = 0;
    last_error = error_buf[0..n :0];
}

fn fail(msg: []const u8) c_int {
    setError(msg);
    return -1;
}

export fn at_control_store() callconv(.c) ?*anyopaque {
    return store_ptr;
}

export fn at_control_start(store: ?*anyopaque, ui: ?*const anyopaque, io: ?*const anyopaque) callconv(.c) c_int {
    if (started) at_control_stop();
    _ = signal(SIGPIPE, ignorePipe);
    bus.reset();
    cmds.registerAll();
    store_ptr = store;
    started = true;
    if (ui) |p| {
        ui_copy = @as(*const ControlUI, @ptrCast(@alignCast(p))).*;
        have_ui = true;
        cmds.bindUi(ui_copy.ctx, ui_copy.reload, ui_copy.pane_write, ui_copy.pane_activity, ui_copy.tab_add, ui_copy.focus_workspace, ui_copy.focus_tab);
    }

    const off = getenv("ATERMINAL_CONTROL");
    if (off) |v| {
        if (v[0] == '0' and v[1] == 0) return 0;
    }
    const dir_c = at_store_dir(store) orelse return 0;
    const dir = std.mem.span(dir_c);
    const owned = readControlJson(dir);
    defer if (owned) |s| gpa.free(s);
    const cfg_src: []const u8 = owned orelse "{}";
    live_cfg = if (owned) |s| config_mod.parse(s) catch config_mod.Config{} else config_mod.Config{};
    if (io) |p| {
        io_copy = @as(*const unix.ControlIO, @ptrCast(@alignCast(p))).*;
        have_io = true;
        unix.start(dir, &io_copy, live_cfg.core and live_cfg.unix);
        if (live_cfg.core) plugin.loadAll(dir, live_cfg, &io_copy, cfg_src);
    }
    rebuildCatalog(dir);
    return 0;
}

export fn at_control_stop() callconv(.c) void {
    plugin.stop();
    unix.stop();
    bus.reset();
    store_ptr = null;
    have_io = false;
    have_ui = false;
    cmds.bindUi(null, null, null, null, null, null, null);
    catalog_n = 0;
    if (plugin_dir_z) |z| {
        gpa.free(z);
        plugin_dir_z = null;
    }
    started = false;
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(file: ?*anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, file: ?*anyopaque) usize;
extern "c" fn fseek(file: ?*anyopaque, off: c_long, whence: c_int) c_int;
extern "c" fn ftell(file: ?*anyopaque) c_long;

fn readControlJson(dir: []const u8) ?[]u8 {
    const joined = std.fs.path.join(gpa, &.{ dir, "control.json" }) catch return null;
    defer gpa.free(joined);
    const path = gpa.dupeZ(u8, joined) catch return null;
    defer gpa.free(path);
    const f = fopen(path, "rb") orelse return null;
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

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, file: ?*anyopaque) usize;

fn titleFor(stem: []const u8, out: *[48]u8) void {
    const t: []const u8 = if (std.mem.eql(u8, stem, "echo"))
        "Echo"
    else if (std.mem.eql(u8, stem, "mcp"))
        "MCP"
    else if (std.mem.eql(u8, stem, "http"))
        "HTTP"
    else if (std.mem.eql(u8, stem, "wow"))
        "World of Warcraft"
    else if (std.mem.eql(u8, stem, "tailnet"))
        "Tailscale"
    else if (std.mem.eql(u8, stem, "git"))
        "Git"
    else if (std.mem.eql(u8, stem, "background"))
        "Background"
    else if (std.mem.eql(u8, stem, "pipeline"))
        "Pipeline"
    else if (std.mem.eql(u8, stem, "core"))
        "Core"
    else
        stem;
    const n = @min(t.len, out.len - 1);
    @memcpy(out[0..n], t[0..n]);
    out[n] = 0;
}

fn addCat(stem: []const u8, dir: []const u8, env_dir: ?[]const u8) void {
    if (stem.len == 0 or catalog_n >= max_cat) return;
    var i: u32 = 0;
    while (i < catalog_n) : (i += 1) {
        const id = std.mem.sliceTo(&catalog[i].id, 0);
        if (std.mem.eql(u8, id, stem)) return;
    }
    var row = CatRow{};
    const n = @min(stem.len, 32);
    @memcpy(row.id[0..n], stem[0..n]);
    row.id[n] = 0;
    titleFor(stem, &row.title);
    const req = config_mod.requires(stem);
    const rn = @min(req.len, row.requires.len - 1);
    @memcpy(row.requires[0..rn], req[0..rn]);
    row.requires[rn] = 0;
    if (config_mod.isBuiltin(stem)) {
        row.present = true;
        if (std.mem.eql(u8, stem, "core")) {
            row.enabled = live_cfg.core;
            row.loaded = live_cfg.core;
        } else if (std.mem.eql(u8, stem, "git")) {
            row.enabled = live_cfg.git;
            row.loaded = live_cfg.core and live_cfg.git;
        } else if (std.mem.eql(u8, stem, "background")) {
            row.enabled = live_cfg.background;
            row.loaded = live_cfg.core and live_cfg.background;
        }
    } else {
        row.present = plugin.dylibPresent(dir, env_dir, stem);
        row.enabled = live_cfg.hasStem(stem);
        row.loaded = live_cfg.core and plugin.isLoaded(stem);
    }
    catalog[catalog_n] = row;
    catalog_n += 1;
}

fn rebuildCatalog(dir: []const u8) void {
    catalog_n = 0;
    const env_c = getenv("ATERMINAL_PLUGIN_DIR");
    const env_dir: ?[]const u8 = if (env_c) |e| std.mem.span(e) else null;
    const known = [_][]const u8{ "core", "git", "background", "pipeline", "mcp", "echo", "http", "wow", "tailnet" };
    for (known) |k| addCat(k, dir, env_dir);

    var names: [max_cat][32]u8 = undefined;
    var lens: [max_cat]u8 = undefined;
    var found: u8 = 0;
    if (env_dir) |ed| {
        found = plugin.scanDir(ed, names[0..], lens[0..], found);
    }
    const plug = std.fs.path.join(gpa, &.{ dir, "plugins" }) catch null;
    if (plug) |p| {
        defer gpa.free(p);
        found = plugin.scanDir(p, names[0..], lens[0..], found);
        if (plugin_dir_z) |z| gpa.free(z);
        plugin_dir_z = gpa.dupeZ(u8, p) catch null;
        if (plugin_dir_z) |z| _ = mkdir(z, 0o700);
    }
    if (plugin.bundlePlugInsDir()) |bd| {
        defer gpa.free(bd);
        found = plugin.scanDir(bd, names[0..], lens[0..], found);
    }
    var i: u8 = 0;
    while (i < found) : (i += 1) addCat(names[i][0..lens[i]], dir, env_dir);
    var e: u8 = 0;
    while (e < live_cfg.plugin_n) : (e += 1) addCat(live_cfg.stem(e), dir, env_dir);
}

fn supportPath() ?[]const u8 {
    const dir_c = at_store_dir(store_ptr) orelse return null;
    return std.mem.span(dir_c);
}

fn writeControlJson() !void {
    const dir = supportPath() orelse return error.Unavailable;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\n  \"core\": ");
    try buf.appendSlice(gpa, if (live_cfg.core) "true" else "false");
    try buf.appendSlice(gpa, ",\n  \"unix\": ");
    try buf.appendSlice(gpa, if (live_cfg.unix) "true" else "false");
    try buf.appendSlice(gpa, ",\n  \"git\": ");
    try buf.appendSlice(gpa, if (live_cfg.git) "true" else "false");
    try buf.appendSlice(gpa, ",\n  \"background\": ");
    try buf.appendSlice(gpa, if (live_cfg.background) "true" else "false");
    try buf.appendSlice(gpa, ",\n  \"yolo\": ");
    try buf.appendSlice(gpa, if (live_cfg.yolo) "true" else "false");
    try buf.appendSlice(gpa, ",\n  \"max_clients\": ");
    var nbuf: [8]u8 = undefined;
    const ns = try std.fmt.bufPrint(&nbuf, "{d}", .{live_cfg.max_clients});
    try buf.appendSlice(gpa, ns);
    try buf.appendSlice(gpa, ",\n  \"plugins\": [");
    var i: u8 = 0;
    while (i < live_cfg.plugin_n) : (i += 1) {
        if (i != 0) try buf.appendSlice(gpa, ", ");
        try buf.append(gpa, '"');
        try buf.appendSlice(gpa, live_cfg.stem(i));
        try buf.append(gpa, '"');
    }
    try buf.appendSlice(gpa, "]");
    try buf.appendSlice(gpa, live_cfg.extrasSlice());
    try buf.appendSlice(gpa, "\n}\n");
    const joined = try std.fs.path.join(gpa, &.{ dir, "control.json" });
    defer gpa.free(joined);
    const path = try gpa.dupeZ(u8, joined);
    defer gpa.free(path);
    const f = fopen(path, "wb") orelse return error.Unavailable;
    defer _ = fclose(f);
    const n = fwrite(buf.items.ptr, 1, buf.items.len, f);
    if (n != buf.items.len) return error.Unavailable;
    _ = chmod(path, 0o600);
}

fn applyLive() c_int {
    writeControlJson() catch return fail("could not write control.json");
    const dir = supportPath() orelse return fail("no support dir");
    plugin.stop();
    unix.stop();
    if (have_io) {
        const owned = readControlJson(dir);
        defer if (owned) |s| gpa.free(s);
        const src: []const u8 = owned orelse "{}";
        unix.start(dir, &io_copy, live_cfg.core and live_cfg.unix);
        if (live_cfg.core) plugin.loadAll(dir, live_cfg, &io_copy, src);
    }
    rebuildCatalog(dir);
    return 0;
}

fn envForcedOff() bool {
    const off = getenv("ATERMINAL_CONTROL") orelse return false;
    return off[0] == '0' and off[1] == 0;
}

export fn at_control_forced_off() callconv(.c) c_int {
    return if (envForcedOff()) 1 else 0;
}

fn stemOn(name: []const u8) bool {
    if (std.mem.eql(u8, name, "core")) return live_cfg.core;
    if (std.mem.eql(u8, name, "git")) return live_cfg.git;
    if (std.mem.eql(u8, name, "background")) return live_cfg.background;
    if (std.mem.eql(u8, name, "unix")) return live_cfg.unix;
    return live_cfg.hasStem(name);
}

fn depsMet(name: []const u8) bool {
    const req = config_mod.requires(name);
    if (req.len == 0) return true;
    var it = std.mem.splitScalar(u8, req, ',');
    while (it.next()) |part| {
        const d = std.mem.trim(u8, part, " ");
        if (d.len == 0) continue;
        if (!stemOn(d)) return false;
    }
    return true;
}

fn enableDeps(name: []const u8) void {
    const req = config_mod.requires(name);
    var it = std.mem.splitScalar(u8, req, ',');
    while (it.next()) |part| {
        const d = std.mem.trim(u8, part, " ");
        if (d.len == 0) continue;
        live_cfg.setStem(d, true);
        enableDeps(d);
    }
}

export fn at_control_unix_on() callconv(.c) c_int {
    return if (live_cfg.core and live_cfg.unix) 1 else 0;
}

export fn at_control_set_unix(on: c_int) callconv(.c) c_int {
    if (!started) return fail("control not started");
    live_cfg.unix = on != 0;
    return applyLive();
}

export fn at_control_git_on() callconv(.c) c_int {
    return if (live_cfg.core and live_cfg.git) 1 else 0;
}

export fn at_control_background_on() callconv(.c) c_int {
    return if (live_cfg.core and live_cfg.background) 1 else 0;
}

export fn at_control_yolo() callconv(.c) c_int {
    return if (live_cfg.yolo) 1 else 0;
}

export fn at_control_set_yolo(on: c_int) callconv(.c) c_int {
    if (!started) return fail("control not started");
    live_cfg.yolo = on != 0;
    return applyLive();
}

export fn at_control_ext_count() callconv(.c) u32 {
    return catalog_n;
}

export fn at_control_ext_id(i: u32) callconv(.c) ?[*:0]const u8 {
    if (i >= catalog_n) return null;
    return @ptrCast(&catalog[i].id);
}

export fn at_control_ext_title(i: u32) callconv(.c) ?[*:0]const u8 {
    if (i >= catalog_n) return null;
    return @ptrCast(&catalog[i].title);
}

export fn at_control_ext_enabled(i: u32) callconv(.c) c_int {
    if (i >= catalog_n) return 0;
    return if (catalog[i].enabled) 1 else 0;
}

export fn at_control_ext_loaded(i: u32) callconv(.c) c_int {
    if (i >= catalog_n) return 0;
    return if (catalog[i].loaded) 1 else 0;
}

export fn at_control_ext_present(i: u32) callconv(.c) c_int {
    if (i >= catalog_n) return 0;
    return if (catalog[i].present) 1 else 0;
}

export fn at_control_ext_requires(i: u32) callconv(.c) ?[*:0]const u8 {
    if (i >= catalog_n) return null;
    if (catalog[i].requires[0] == 0) return null;
    return @ptrCast(&catalog[i].requires);
}

export fn at_control_ext_deps_ok(i: u32) callconv(.c) c_int {
    if (i >= catalog_n) return 0;
    const id = std.mem.sliceTo(&catalog[i].id, 0);
    return if (depsMet(id)) 1 else 0;
}

export fn at_control_set_ext(id: ?[*:0]const u8, on: c_int) callconv(.c) c_int {
    if (!started) return fail("control not started");
    const name = std.mem.span(id orelse return fail("missing id"));
    if (on != 0) enableDeps(name);
    live_cfg.setStem(name, on != 0);
    if (config_mod.isBuiltin(name)) {
        writeControlJson() catch return fail("could not write control.json");
        if (supportPath()) |dir| rebuildCatalog(dir);
        return 0;
    }
    return applyLive();
}

export fn at_control_apply() callconv(.c) c_int {
    if (!started) return fail("control not started");
    return applyLive();
}

export fn at_control_plugin_dir() callconv(.c) ?[*:0]const u8 {
    return if (plugin_dir_z) |z| z.ptr else null;
}

export fn at_control_error() callconv(.c) [*:0]const u8 {
    return last_error.ptr;
}

export fn at_control_free(p: ?[*:0]u8) callconv(.c) void {
    if (p) |ptr| gpa.free(std.mem.span(ptr));
}

export fn at_control_emit(json_event: ?[*:0]const u8) callconv(.c) void {
    _ = json_event;
}

export fn at_control_call(op: ?[*:0]const u8, json_args: ?[*:0]const u8, json_out: *?[*:0]u8) callconv(.c) c_int {
    return at_control_call_capped(op, json_args, json_out, 0xffff);
}

export fn at_control_call_capped(
    op: ?[*:0]const u8,
    json_args: ?[*:0]const u8,
    json_out: *?[*:0]u8,
    have: u32,
) callconv(.c) c_int {
    json_out.* = null;
    if (!started) return fail("control not started");
    const name = std.mem.span(op orelse return fail("missing op"));
    const args = if (json_args) |a| std.mem.span(a) else "{}";
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(gpa);
    const cap = bus.Cap.fromU32(have);
    if (bus.dispatch(name, args, cap, &result)) |_| {
        return finishOk(result.items, json_out);
    } else |err| {
        return finishErr(rpc.errCode(err), errMessage(err), json_out);
    }
}

fn errMessage(err: bus.BusError) []const u8 {
    return switch (err) {
        error.UnknownOp => "unknown op",
        error.Denied => "capability denied",
        error.BadArgs => "bad args",
        error.NotFound => "not found",
        error.NotReady => "not ready",
        error.WouldBlock => "would block",
        error.Unavailable => "unavailable",
        error.Internal => "internal",
    };
}

fn finishOk(result: []const u8, json_out: *?[*:0]u8) c_int {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "{\"ok\":true,\"result\":") catch return fail("out of memory");
    const body = if (result.len == 0) "{}" else result;
    buf.appendSlice(gpa, body) catch return fail("out of memory");
    buf.appendSlice(gpa, "}") catch return fail("out of memory");
    const z = gpa.dupeZ(u8, buf.items) catch return fail("out of memory");
    json_out.* = z.ptr;
    return 0;
}

fn finishErr(code: []const u8, message: []const u8, json_out: *?[*:0]u8) c_int {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "{\"ok\":false,\"error\":{\"code\":\"") catch return fail("out of memory");
    buf.appendSlice(gpa, code) catch return fail("out of memory");
    buf.appendSlice(gpa, "\",\"message\":\"") catch return fail("out of memory");
    json.jsonEscape(gpa, &buf, message) catch return fail("out of memory");
    buf.appendSlice(gpa, "\"}}") catch return fail("out of memory");
    const z = gpa.dupeZ(u8, buf.items) catch return fail("out of memory");
    json_out.* = z.ptr;
    setError(message);
    return -1;
}

test "call capped ping and deny" {
    var out: ?[*:0]u8 = null;
    try std.testing.expectEqual(@as(c_int, -1), at_control_call_capped("core.ping", "{}", &out, 0));
    try std.testing.expect(out == null);

    try std.testing.expectEqual(@as(c_int, 0), at_control_start(null, null, null));
    defer at_control_stop();

    try std.testing.expectEqual(@as(c_int, 0), at_control_call_capped("core.ping", "{}", &out, 0));
    try std.testing.expect(out != null);
    const ping = std.mem.span(out.?);
    try std.testing.expect(std.mem.indexOf(u8, ping, "\"ok\":true") != null);
    at_control_free(out);
    out = null;

    try std.testing.expectEqual(@as(c_int, -1), at_control_call_capped("nope.x", "{}", &out, 0xffff));
    const err = std.mem.span(out.?);
    try std.testing.expect(std.mem.indexOf(u8, err, "unknown_op") != null);
    at_control_free(out);
}
