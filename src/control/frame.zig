const std = @import("std");

pub const magic = "ATR1";
pub const header_size: usize = 16;
pub const max_len: u32 = 1024 * 1024;
pub const proto: u16 = 1;
pub const flag_json: u8 = 1;

pub const Type = enum(u8) {
    hello = 1,
    hello_ok = 2,
    req = 3,
    res = 4,
    event = 5,
    err = 6,
};

pub const Header = struct {
    typ: Type,
    flags: u8,
    proto: u16,
    id: u32,
    len: u32,
};

pub const Frame = struct {
    typ: Type,
    flags: u8,
    proto: u16,
    id: u32,
    payload: []const u8,
};

pub const FrameError = error{
    BadMagic,
    BadType,
    TooLarge,
    Pipelined,
    Truncated,
};

pub fn encode(allocator: std.mem.Allocator, typ: Type, id: u32, payload: []const u8) ![]u8 {
    if (payload.len > max_len) return error.TooLarge;
    const total = header_size + payload.len;
    var buf = try allocator.alloc(u8, total);
    buf[0] = 'A';
    buf[1] = 'T';
    buf[2] = 'R';
    buf[3] = '1';
    buf[4] = @intFromEnum(typ);
    buf[5] = flag_json;
    std.mem.writeInt(u16, buf[6..8], proto, .little);
    std.mem.writeInt(u32, buf[8..12], id, .little);
    std.mem.writeInt(u32, buf[12..16], @intCast(payload.len), .little);
    @memcpy(buf[16..], payload);
    return buf;
}

pub fn decodeHeader(bytes: []const u8) FrameError!Header {
    if (bytes.len < header_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    const t: Type = switch (bytes[4]) {
        1 => .hello,
        2 => .hello_ok,
        3 => .req,
        4 => .res,
        5 => .event,
        6 => .err,
        else => return error.BadType,
    };
    const len = std.mem.readInt(u32, bytes[12..16], .little);
    if (len > max_len) return error.TooLarge;
    return .{
        .typ = t,
        .flags = bytes[5],
        .proto = std.mem.readInt(u16, bytes[6..8], .little),
        .id = std.mem.readInt(u32, bytes[8..12], .little),
        .len = len,
    };
}

pub const Conn = struct {
    buf: std.ArrayList(u8) = .empty,
    in_flight: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Conn {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Conn) void {
        self.buf.deinit(self.allocator);
    }

    /// Append `chunk`. Returns a frame when a complete message is buffered.
    /// `payload` is a slice of `self.buf` — copy it before the next feed.
    pub fn feed(self: *Conn, chunk: []const u8) FrameError!?Frame {
        self.buf.appendSlice(self.allocator, chunk) catch return error.TooLarge;
        return self.take();
    }

    pub fn take(self: *Conn) FrameError!?Frame {
        if (self.buf.items.len < header_size) return null;
        const hdr = try decodeHeader(self.buf.items);
        const need = header_size + hdr.len;
        if (self.buf.items.len < need) return null;
        if (hdr.typ == .req) {
            if (self.in_flight) return error.Pipelined;
            self.in_flight = true;
        } else if (hdr.typ == .res) {
            self.in_flight = false;
        }
        const payload = self.buf.items[header_size..need];
        return .{
            .typ = hdr.typ,
            .flags = hdr.flags,
            .proto = hdr.proto,
            .id = hdr.id,
            .payload = payload,
        };
    }

    pub fn finishReq(self: *Conn) void {
        self.in_flight = false;
    }

    pub fn consume(self: *Conn, frame: Frame) void {
        const need = header_size + frame.payload.len;
        const rest = self.buf.items[need..];
        std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
        self.buf.shrinkRetainingCapacity(rest.len);
    }
};

test "roundtrip hello" {
    const alloc = std.testing.allocator;
    const payload = "{\"client\":\"atctl\"}";
    const bytes = try encode(alloc, .hello, 7, payload);
    defer alloc.free(bytes);
    const hdr = try decodeHeader(bytes);
    try std.testing.expectEqual(Type.hello, hdr.typ);
    try std.testing.expectEqual(@as(u32, 7), hdr.id);
    try std.testing.expectEqual(payload.len, hdr.len);
    try std.testing.expectEqualStrings(payload, bytes[16..]);
}

test "truncated header" {
    try std.testing.expectError(error.Truncated, decodeHeader("ATR1xxxx"));
}

test "len over 1MiB" {
    var hdr: [16]u8 = undefined;
    hdr[0] = 'A';
    hdr[1] = 'T';
    hdr[2] = 'R';
    hdr[3] = '1';
    hdr[4] = 3;
    hdr[5] = 1;
    std.mem.writeInt(u16, hdr[6..8], 1, .little);
    std.mem.writeInt(u32, hdr[8..12], 1, .little);
    std.mem.writeInt(u32, hdr[12..16], max_len + 1, .little);
    try std.testing.expectError(error.TooLarge, decodeHeader(&hdr));
}

test "second req in flight" {
    const alloc = std.testing.allocator;
    const p = "{}";
    const a = try encode(alloc, .req, 1, p);
    defer alloc.free(a);
    const b = try encode(alloc, .req, 2, p);
    defer alloc.free(b);
    var conn = Conn.init(alloc);
    defer conn.deinit();
    const f1 = (try conn.feed(a)).?;
    try std.testing.expectEqual(Type.req, f1.typ);
    try std.testing.expectError(error.Pipelined, conn.feed(b));
}

test "reassembly across chunks" {
    const alloc = std.testing.allocator;
    const payload = "{\"op\":\"core.ping\"}";
    const bytes = try encode(alloc, .req, 9, payload);
    defer alloc.free(bytes);
    var conn = Conn.init(alloc);
    defer conn.deinit();
    try std.testing.expectEqual(@as(?Frame, null), try conn.feed(bytes[0..6]));
    const f = (try conn.feed(bytes[6..])).?;
    try std.testing.expectEqual(@as(u32, 9), f.id);
    try std.testing.expectEqualStrings(payload, f.payload);
}
