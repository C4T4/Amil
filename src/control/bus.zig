const std = @import("std");

pub const Cap = packed struct(u32) {
    read: bool = false,
    focus: bool = false,
    input: bool = false,
    session: bool = false,
    layout: bool = false,
    fs: bool = false,
    admin: bool = false,
    pair: bool = false,
    _pad: u24 = 0,

    pub fn none() Cap {
        return .{};
    }

    pub fn fromU32(v: u32) Cap {
        return @bitCast(v);
    }

    pub fn toU32(self: Cap) u32 {
        return @bitCast(self);
    }

    pub fn contains(self: Cap, need: Cap) bool {
        const have: u32 = @bitCast(self);
        const n: u32 = @bitCast(need);
        return have & n == n;
    }

    pub fn intersect(self: Cap, other: Cap) Cap {
        return fromU32(self.toU32() & other.toU32());
    }

    pub fn withoutAdmin(self: Cap) Cap {
        var c = self;
        c.admin = false;
        return c;
    }
};

pub const local_default = Cap{
    .read = true,
    .focus = true,
    .input = true,
    .session = true,
    .layout = true,
    .fs = true,
    .pair = true,
};

pub const names = [_][]const u8{ "read", "focus", "input", "session", "layout", "fs", "admin", "pair" };

pub const BusError = error{
    UnknownOp,
    Denied,
    BadArgs,
    NotFound,
    NotReady,
    WouldBlock,
    Unavailable,
    Internal,
};

pub const Handler = *const fn (
    ctx: *anyopaque,
    args: []const u8,
    have: Cap,
    out: *std.ArrayList(u8),
) BusError!void;

pub const max_ops = 64;
pub const max_name = 32;

const Entry = struct {
    name: [max_name]u8 = undefined,
    name_len: u8 = 0,
    need: Cap = .{},
    ctx: *anyopaque = undefined,
    handler: Handler = undefined,
};

var entries: [max_ops]Entry = undefined;
var count: u8 = 0;

pub fn reset() void {
    count = 0;
}

pub fn register(name: []const u8, need: Cap, ctx: *anyopaque, handler: Handler) BusError!void {
    if (name.len == 0 or name.len > max_name) return error.BadArgs;
    if (count >= max_ops) return error.Internal;
    if (findIndex(name) != null) return error.BadArgs;
    var e: Entry = .{
        .name_len = @intCast(name.len),
        .need = need,
        .ctx = ctx,
        .handler = handler,
    };
    @memcpy(e.name[0..name.len], name);
    entries[count] = e;
    count += 1;
}

fn findIndex(name: []const u8) ?u8 {
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        const e = entries[i];
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) return i;
    }
    return null;
}

pub fn dispatch(name: []const u8, args: []const u8, have: Cap, out: *std.ArrayList(u8)) BusError!void {
    const idx = findIndex(name) orelse return error.UnknownOp;
    const e = entries[idx];
    if (!have.contains(e.need)) return error.Denied;
    return e.handler(e.ctx, args, have, out);
}

pub fn opCount() u8 {
    return count;
}

pub fn opName(i: u8) ?[]const u8 {
    if (i >= count) return null;
    return entries[i].name[0..entries[i].name_len];
}

test "register and ping" {
    reset();
    const H = struct {
        fn ping(_: *anyopaque, _: []const u8, _: Cap, out: *std.ArrayList(u8)) BusError!void {
            out.appendSlice(std.testing.allocator, "{\"pid\":1}") catch return error.Internal;
        }
    };
    try register("core.ping", .{}, @ptrFromInt(1), H.ping);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try dispatch("core.ping", "{}", .{}, &out);
    try std.testing.expectEqualStrings("{\"pid\":1}", out.items);
}

test "unknown op" {
    reset();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownOp, dispatch("nope.list", "{}", .{}, &out));
}

test "cap deny" {
    reset();
    const H = struct {
        fn input(_: *anyopaque, _: []const u8, _: Cap, out: *std.ArrayList(u8)) BusError!void {
            out.appendSlice(std.testing.allocator, "{}") catch return error.Internal;
        }
    };
    try register("pane.input", .{ .input = true }, @ptrFromInt(1), H.input);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const read_only = Cap{ .read = true };
    try std.testing.expectError(error.Denied, dispatch("pane.input", "{}", read_only, &out));
    try dispatch("pane.input", "{}", .{ .input = true }, &out);
}
