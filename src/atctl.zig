const std = @import("std");
const frame = @import("control/frame.zig");

extern "c" fn socket(domain: c_int, typ: c_int, protocol: c_int) c_int;
extern "c" fn connect(s: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;

const sockaddr_un = extern struct {
    sun_len: u8,
    sun_family: u8,
    sun_path: [104]u8,
};

fn sockPath(allocator: std.mem.Allocator) ![:0]u8 {
    const home_c = getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_c);
    const p = try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "ATerminal", "control", "control.sock" });
    defer allocator.free(p);
    return allocator.dupeZ(u8, p);
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.Write;
        off += @intCast(n);
    }
}

fn readFrame(fd: c_int, conn: *frame.Conn) !frame.Frame {
    var buf: [4096]u8 = undefined;
    while (true) {
        if (try conn.take()) |fr| return fr;
        const n = read(fd, &buf, buf.len);
        if (n <= 0) return error.Read;
        if (try conn.feed(buf[0..@intCast(n)])) |fr| return fr;
    }
}

extern fn _NSGetArgc() *c_int;
extern fn _NSGetArgv() *[*][*:0]u8;

pub fn main() !void {
    const gpa = std.heap.c_allocator;
    const argc: usize = @intCast(_NSGetArgc().*);
    const argv = _NSGetArgv().*;
    const cmd: []const u8 = if (argc >= 2) std.mem.span(argv[1]) else "ping";
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        std.debug.print("atctl ping\natctl pipeline <task>\n", .{});
        return;
    }
    var req_buf: std.ArrayList(u8) = .empty;
    defer req_buf.deinit(gpa);
    if (std.mem.eql(u8, cmd, "ping")) {
        try req_buf.appendSlice(gpa, "{\"op\":\"core.ping\",\"args\":{}}");
    } else if (std.mem.eql(u8, cmd, "pipeline")) {
        if (argc < 3) {
            std.debug.print("atctl pipeline <task>\n", .{});
            std.process.exit(2);
        }
        try req_buf.appendSlice(gpa, "{\"op\":\"pipeline.push\",\"args\":{\"task\":\"");
        const task = std.mem.span(argv[2]);
        for (task) |ch| {
            switch (ch) {
                '"' => try req_buf.appendSlice(gpa, "\\\""),
                '\\' => try req_buf.appendSlice(gpa, "\\\\"),
                '\n' => try req_buf.appendSlice(gpa, "\\n"),
                else => try req_buf.append(gpa, ch),
            }
        }
        try req_buf.appendSlice(gpa, "\"}}");
    } else {
        std.debug.print("unknown command: {s}\n", .{cmd});
        std.process.exit(2);
    }

    const path = sockPath(gpa) catch {
        std.debug.print("HOME is not set\n", .{});
        std.process.exit(1);
    };
    defer gpa.free(path);

    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        std.debug.print("socket failed\n", .{});
        std.process.exit(1);
    }
    defer _ = close(fd);
    var addr = std.mem.zeroes(sockaddr_un);
    addr.sun_family = AF_UNIX;
    const n = @min(path.len, addr.sun_path.len - 1);
    @memcpy(addr.sun_path[0..n], path[0..n]);
    addr.sun_len = @intCast(2 + n + 1);
    if (connect(fd, &addr, addr.sun_len) != 0) {
        std.debug.print("not connected (is Amil running?)\n", .{});
        std.process.exit(1);
    }

    const hello = "{\"client\":\"atctl\",\"client_ver\":1,\"token\":\"\",\"caps\":[\"read\",\"focus\",\"input\",\"session\",\"layout\",\"fs\",\"pair\"]}";
    const hbytes = try frame.encode(gpa, .hello, 1, hello);
    defer gpa.free(hbytes);
    try writeAll(fd, hbytes);

    var conn = frame.Conn.init(gpa);
    defer conn.deinit();
    const hok = try readFrame(fd, &conn);
    if (hok.typ != .hello_ok) {
        std.debug.print("expected hello-ok\n", .{});
        std.process.exit(1);
    }
    conn.consume(hok);

    const rbytes = try frame.encode(gpa, .req, 2, req_buf.items);
    defer gpa.free(rbytes);
    try writeAll(fd, rbytes);
    const res = try readFrame(fd, &conn);
    if (res.typ != .res) {
        std.debug.print("expected res\n", .{});
        std.process.exit(1);
    }
    std.debug.print("{s}\n", .{res.payload});
}
