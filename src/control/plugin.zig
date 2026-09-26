const std = @import("std");
const bus = @import("bus.zig");
const config_mod = @import("config.zig");
const unix = @import("unix.zig");

const gpa = std.heap.c_allocator;

extern fn at_control_call_capped(op: ?[*:0]const u8, json_args: ?[*:0]const u8, json_out: *?[*:0]u8, have: u32) c_int;
extern fn at_control_free(p: ?[*:0]u8) void;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

const max_slots = config_mod.max_plugins;

pub const PluginHost = extern struct {
    abi: u32 = 1,
    caps: u32 = 0,
    support_dir: ?[*:0]const u8 = null,
    config_json: ?[*:0]const u8 = null,
    call: ?*const fn (?[*:0]const u8, ?[*:0]const u8, *?[*:0]u8) callconv(.c) c_int = null,
    call_capped: ?*const fn (?[*:0]const u8, ?[*:0]const u8, *?[*:0]u8, u32) callconv(.c) c_int = null,
    free: ?*const fn (?[*:0]u8) callconv(.c) void = null,
    watch_fd: ?*const fn (c_int, ?*const fn (c_int, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) c_int = null,
    unwatch_fd: ?*const fn (c_int) callconv(.c) c_int = null,
    log: ?*const fn (c_int, ?[*:0]const u8) callconv(.c) c_int = null,
};

const Slot = struct {
    handle: ?*anyopaque = null,
    shutdown: ?*const fn () callconv(.c) void = null,
    mask: u32 = 0,
    host: PluginHost = .{},
    stem: [32]u8 = undefined,
    stem_len: u8 = 0,
};

var slots: [max_slots]Slot = undefined;
var nslots: u8 = 0;
var io_ref: ?*const unix.ControlIO = null;
var support_z: ?[:0]u8 = null;
var config_z: ?[:0]u8 = null;

fn maskFor(stem: []const u8) u32 {
    const base = bus.Cap{
        .read = true,
        .focus = true,
        .input = true,
        .session = true,
        .layout = true,
        .fs = true,
    };
    if (std.mem.eql(u8, stem, "wow")) {
        var c = base;
        c.fs = false;
        return c.toU32();
    }
    if (std.mem.eql(u8, stem, "pipeline")) {
        return base.toU32();
    }
    return base.toU32();
}

fn thunkCall(comptime i: usize) *const fn (?[*:0]const u8, ?[*:0]const u8, *?[*:0]u8) callconv(.c) c_int {
    return struct {
        fn f(op: ?[*:0]const u8, args: ?[*:0]const u8, out: *?[*:0]u8) callconv(.c) c_int {
            return at_control_call_capped(op, args, out, slots[i].mask);
        }
    }.f;
}

fn thunkCallCapped(comptime i: usize) *const fn (?[*:0]const u8, ?[*:0]const u8, *?[*:0]u8, u32) callconv(.c) c_int {
    return struct {
        fn f(op: ?[*:0]const u8, args: ?[*:0]const u8, out: *?[*:0]u8, have: u32) callconv(.c) c_int {
            return at_control_call_capped(op, args, out, slots[i].mask & have);
        }
    }.f;
}

const calls = [_](*const fn (?[*:0]const u8, ?[*:0]const u8, *?[*:0]u8) callconv(.c) c_int){
    thunkCall(0), thunkCall(1), thunkCall(2), thunkCall(3),
    thunkCall(4), thunkCall(5), thunkCall(6), thunkCall(7),
};
const capped = [_](*const fn (?[*:0]const u8, ?[*:0]const u8, *?[*:0]u8, u32) callconv(.c) c_int){
    thunkCallCapped(0), thunkCallCapped(1), thunkCallCapped(2), thunkCallCapped(3),
    thunkCallCapped(4), thunkCallCapped(5), thunkCallCapped(6), thunkCallCapped(7),
};

fn hostWatch(fd: c_int, on_read: ?*const fn (c_int, ?*anyopaque) callconv(.c) void, user: ?*anyopaque) callconv(.c) c_int {
    const io = io_ref orelse return -1;
    const w = io.watch_fd orelse return -1;
    return w(io.ctx, fd, on_read, user);
}

fn hostUnwatch(fd: c_int) callconv(.c) c_int {
    const io = io_ref orelse return -1;
    const u = io.unwatch_fd orelse return -1;
    return u(io.ctx, fd);
}

fn hostLog(level: c_int, msg: ?[*:0]const u8) callconv(.c) c_int {
    const m = msg orelse return 0;
    const tag: []const u8 = if (level <= 0) "err" else if (level == 1) "info" else "debug";
    std.debug.print("aterminal-ext {s}: {s}\n", .{ tag, std.mem.span(m) });
    return 0;
}

fn hostFree(p: ?[*:0]u8) callconv(.c) void {
    at_control_free(p);
}

fn pluginPath(dir: []const u8, stem: []const u8) ![:0]u8 {
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "libat-{s}.dylib", .{stem}) catch return error.BadArgs;
    const p = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(p);
    return gpa.dupeZ(u8, p);
}

extern "c" fn _NSGetExecutablePath(buf: [*c]u8, bufsize: *u32) c_int;

fn plugInsBesideExe(exe: []const u8) ?[:0]u8 {
    const macos_dir = std.fs.path.dirname(exe) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(macos_dir), "MacOS")) return null;
    const contents = std.fs.path.dirname(macos_dir) orelse return null;
    const joined = std.fs.path.join(gpa, &.{ contents, "PlugIns" }) catch return null;
    defer gpa.free(joined);
    return gpa.dupeZ(u8, joined) catch null;
}

pub fn bundlePlugInsDir() ?[:0]u8 {
    var size: u32 = 1024;
    var stack: [1024]u8 = undefined;
    if (_NSGetExecutablePath(&stack[0], &size) == 0) {
        return plugInsBesideExe(std.mem.sliceTo(stack[0..], 0));
    }
    if (size == 0 or size > 8192) return null;
    const heap = gpa.alloc(u8, size) catch return null;
    defer gpa.free(heap);
    var sz = size;
    if (_NSGetExecutablePath(heap.ptr, &sz) != 0) return null;
    return plugInsBesideExe(std.mem.sliceTo(heap.ptr, 0));
}

fn tryLoadStem(dir: []const u8, stem: []const u8) bool {
    const before = nslots;
    const p = pluginPath(dir, stem) catch return false;
    defer gpa.free(p);
    tryLoad(p, stem);
    return nslots > before;
}

fn tryLoad(path: [:0]const u8, stem: []const u8) void {
    if (nslots >= max_slots) return;
    const h = std.c.dlopen(path, .{ .NOW = true, .LOCAL = true }) orelse return;
    const abi_sym = std.c.dlsym(h, "at_plugin_abi") orelse {
        _ = std.c.dlclose(h);
        return;
    };
    const abi_fn: *const fn () callconv(.c) c_int = @ptrCast(@alignCast(abi_sym));
    if (abi_fn() != 1) {
        _ = std.c.dlclose(h);
        return;
    }
    const init_sym = std.c.dlsym(h, "at_plugin_init") orelse {
        _ = std.c.dlclose(h);
        return;
    };
    const init_fn: *const fn (*PluginHost) callconv(.c) c_int = @ptrCast(@alignCast(init_sym));
    const shut_sym = std.c.dlsym(h, "at_plugin_shutdown");
    const i = nslots;
    const sn: u8 = @intCast(@min(stem.len, 32));
    slots[i] = .{
        .handle = h,
        .shutdown = if (shut_sym) |s| @ptrCast(@alignCast(s)) else null,
        .mask = maskFor(stem),
        .stem_len = sn,
        .host = .{
            .abi = 1,
            .caps = maskFor(stem),
            .support_dir = if (support_z) |z| z.ptr else null,
            .config_json = if (config_z) |z| z.ptr else null,
            .call = calls[i],
            .call_capped = capped[i],
            .free = hostFree,
            .watch_fd = hostWatch,
            .unwatch_fd = hostUnwatch,
            .log = hostLog,
        },
    };
    @memcpy(slots[i].stem[0..sn], stem[0..sn]);
    if (init_fn(&slots[i].host) != 0) {
        _ = std.c.dlclose(h);
        slots[i] = .{};
        return;
    }
    nslots += 1;
}

pub fn loadAll(dir: []const u8, cfg: config_mod.Config, io: *const unix.ControlIO, config_src: []const u8) void {
    stop();
    io_ref = io;
    support_z = gpa.dupeZ(u8, dir) catch return;
    config_z = gpa.dupeZ(u8, config_src) catch return;

    const env_dir_c = getenv("ATERMINAL_PLUGIN_DIR");
    const env_dir: ?[]const u8 = if (env_dir_c) |e| std.mem.span(e) else null;
    const bundle_dir = bundlePlugInsDir();
    defer if (bundle_dir) |z| gpa.free(z);

    var i: u8 = 0;
    while (i < cfg.plugin_n) : (i += 1) {
        const stem = cfg.stem(i);
        if (config_mod.isBuiltin(stem)) continue;
        if (env_dir) |ed| {
            if (tryLoadStem(ed, stem)) continue;
        }
        const fallback = std.fs.path.join(gpa, &.{ dir, "plugins" }) catch null;
        if (fallback) |fb| {
            defer gpa.free(fb);
            if (tryLoadStem(fb, stem)) continue;
        }
        if (bundle_dir) |bd| {
            _ = tryLoadStem(bd, stem);
        }
    }
}

pub fn stop() void {
    var i: u8 = 0;
    while (i < nslots) : (i += 1) {
        if (slots[i].shutdown) |s| s();
        if (slots[i].handle) |h| _ = std.c.dlclose(h);
        slots[i] = .{};
    }
    nslots = 0;
    if (support_z) |z| {
        gpa.free(z);
        support_z = null;
    }
    if (config_z) |z| {
        gpa.free(z);
        config_z = null;
    }
    io_ref = null;
}

pub fn loadedCount() u8 {
    return nslots;
}

pub fn isLoaded(stem: []const u8) bool {
    var i: u8 = 0;
    while (i < nslots) : (i += 1) {
        if (std.mem.eql(u8, slots[i].stem[0..slots[i].stem_len], stem)) return true;
    }
    return false;
}

pub fn dylibExists(dir: []const u8, stem: []const u8) bool {
    const p = pluginPath(dir, stem) catch return false;
    defer gpa.free(p);
    const f = fopen(p, "rb") orelse return false;
    _ = fclose(f);
    return true;
}

pub fn dylibPresent(support_dir: []const u8, env_dir: ?[]const u8, stem: []const u8) bool {
    const plug = std.fs.path.join(gpa, &.{ support_dir, "plugins" }) catch support_dir;
    defer if (plug.ptr != support_dir.ptr) gpa.free(plug);
    if (dylibExists(plug, stem)) return true;
    if (env_dir) |ed| {
        if (dylibExists(ed, stem)) return true;
    }
    if (bundlePlugInsDir()) |bd| {
        defer gpa.free(bd);
        if (dylibExists(bd, stem)) return true;
    }
    return false;
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(file: ?*anyopaque) c_int;
extern "c" fn opendir(name: [*:0]const u8) ?*anyopaque;
extern "c" fn readdir(dir: ?*anyopaque) ?*std.c.dirent;
extern "c" fn closedir(dir: ?*anyopaque) c_int;

/// Append stems found as libat-STEM.dylib in dir. Returns new count.
pub fn scanDir(dir: []const u8, names: [][32]u8, lens: []u8, start: u8) u8 {
    var n = start;
    const path = gpa.dupeZ(u8, dir) catch return n;
    defer gpa.free(path);
    const d = opendir(path) orelse return n;
    defer _ = closedir(d);
    while (readdir(d)) |ent| {
        const name = ent.name[0..ent.namlen];
        if (name.len < 12) continue;
        if (!std.mem.startsWith(u8, name, "libat-")) continue;
        if (!std.mem.endsWith(u8, name, ".dylib")) continue;
        const stem = name["libat-".len .. name.len - ".dylib".len];
        if (stem.len == 0 or stem.len > 32) continue;
        var dup = false;
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            if (std.mem.eql(u8, names[i][0..lens[i]], stem)) {
                dup = true;
                break;
            }
        }
        if (dup or n >= names.len) continue;
        const sl: u8 = @intCast(stem.len);
        @memcpy(names[n][0..sl], stem);
        lens[n] = sl;
        n += 1;
    }
    return n;
}

test "wow mask strips fs" {
    const wow = maskFor("wow");
    const mcp = maskFor("mcp");
    try std.testing.expect(wow & (1 << 5) == 0);
    try std.testing.expect(mcp & (1 << 5) != 0);
    try std.testing.expect(wow & (1 << 6) == 0);
    try std.testing.expect(mcp & (1 << 7) == 0);
}
