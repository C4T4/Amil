const std = @import("std");
const bus = @import("bus.zig");
const frame = @import("frame.zig");
const rpc = @import("rpc.zig");
const json = @import("../json.zig");

const gpa = std.heap.c_allocator;

pub const ControlIO = extern struct {
    ctx: ?*anyopaque = null,
    watch_fd: ?*const fn (
        ctx: ?*anyopaque,
        fd: c_int,
        on_read: ?*const fn (c_int, ?*anyopaque) callconv(.c) void,
        user: ?*anyopaque,
    ) callconv(.c) c_int = null,
    unwatch_fd: ?*const fn (ctx: ?*anyopaque, fd: c_int) callconv(.c) c_int = null,
};

extern "c" fn socket(domain: c_int, typ: c_int, protocol: c_int) c_int;
extern "c" fn bind(s: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(s: c_int, backlog: c_uint) c_int;
extern "c" fn connect(s: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn accept(s: c_int, addr: ?*anyopaque, addrlen: ?*c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn setsockopt(s: c_int, level: c_int, name: c_int, val: *const anyopaque, len: c_uint) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn getpeereid(s: c_int, euid: *c_uint, egid: *c_uint) c_int;
extern "c" fn getpid() c_int;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn __error() *c_int;
extern fn at_control_call_capped(op: ?[*:0]const u8, json_args: ?[*:0]const u8, json_out: *?[*:0]u8, have: u32) c_int;
extern fn at_control_free(p: ?[*:0]u8) void;

const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const F_GETFD: c_int = 1;
const F_SETFD: c_int = 2;
const FD_CLOEXEC: c_int = 1;
const O_NONBLOCK: c_int = 4;
const SOL_SOCKET: c_int = 0xffff;
const SO_NOSIGPIPE: c_int = 0x1022;
const EAGAIN: c_int = 35;

const sockaddr_un = extern struct {
    sun_len: u8,
    sun_family: u8,
    sun_path: [104]u8,
};

const max_clients: usize = 8;
const read_chunk: usize = 4096;

const Client = struct {
    fd: c_int = -1,
    conn: frame.Conn,
    granted: bus.Cap = .{},
    hello_ok: bool = false,
    hello_at: i64 = 0,
};

var io_ref: ?*const ControlIO = null;
var listen_fd: c_int = -1;
var bound_path: ?[:0]u8 = null;
var clients: [max_clients]Client = undefined;
var nclients: u8 = 0;
var support_dir: []const u8 = "";
var running: bool = false;

fn errno() c_int {
    return __error().*;
}

fn setCloexecNonblockNosig(fd: c_int) void {
    const fdfl = fcntl(fd, F_GETFD, @as(c_int, 0));
    if (fdfl >= 0) _ = fcntl(fd, F_SETFD, fdfl | FD_CLOEXEC);
    const fl = fcntl(fd, F_GETFL, @as(c_int, 0));
    if (fl >= 0) _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    var one: c_int = 1;
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, @sizeOf(c_int));
}

fn makeAddr(path: []const u8) sockaddr_un {
    var addr: sockaddr_un = std.mem.zeroes(sockaddr_un);
    addr.sun_family = AF_UNIX;
    const n = @min(path.len, addr.sun_path.len - 1);
    @memcpy(addr.sun_path[0..n], path[0..n]);
    addr.sun_len = @intCast(2 + n + 1);
    return addr;
}

pub fn sockDir(dir: []const u8, allocator: std.mem.Allocator) ![:0]u8 {
    const p = try std.fs.path.join(allocator, &.{ dir, "control" });
    defer allocator.free(p);
    return allocator.dupeZ(u8, p);
}

pub fn sockPath(dir: []const u8, allocator: std.mem.Allocator) ![:0]u8 {
    const p = try std.fs.path.join(allocator, &.{ dir, "control", "control.sock" });
    defer allocator.free(p);
    return allocator.dupeZ(u8, p);
}

pub fn clientCount() u8 {
    return nclients;
}

pub fn start(dir: []const u8, io: *const ControlIO, unix_on: bool) void {
    stop();
    if (!unix_on) return;
    if (io.watch_fd == null or io.unwatch_fd == null) return;
    support_dir = dir;
    io_ref = io;
    const d = sockDir(dir, gpa) catch return;
    defer gpa.free(d);
    _ = mkdir(d, 0o700);
    const path = sockPath(dir, gpa) catch return;

    const probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe >= 0) {
        setCloexecNonblockNosig(probe);
        var addr = makeAddr(path);
        const rc = connect(probe, &addr, addr.sun_len);
        _ = close(probe);
        if (rc == 0) {
            gpa.free(path);
            return;
        }
    }
    _ = unlink(path);

    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        gpa.free(path);
        return;
    }
    setCloexecNonblockNosig(fd);
    var addr = makeAddr(path);
    if (bind(fd, &addr, addr.sun_len) != 0 or listen(fd, 8) != 0) {
        _ = close(fd);
        gpa.free(path);
        return;
    }
    _ = chmod(path, 0o600);
    listen_fd = fd;
    bound_path = path;
    if (io.watch_fd.?(io.ctx, fd, onListen, null) != 0) {
        _ = close(fd);
        listen_fd = -1;
        gpa.free(path);
        bound_path = null;
        return;
    }
    running = true;
}

pub fn stop() void {
    const io = io_ref;
    var i: u8 = 0;
    while (i < nclients) : (i += 1) {
        const fd = clients[i].fd;
        clients[i].conn.deinit();
        clients[i].fd = -1;
        if (io) |o| {
            if (o.unwatch_fd) |u| _ = u(o.ctx, fd);
        }
    }
    nclients = 0;
    if (listen_fd >= 0) {
        const fd = listen_fd;
        listen_fd = -1;
        if (io) |o| {
            if (o.unwatch_fd) |u| _ = u(o.ctx, fd);
        } else {
            _ = close(fd);
        }
    }
    if (bound_path) |p| {
        _ = unlink(p);
        gpa.free(p);
        bound_path = null;
    }
    io_ref = null;
    running = false;
}

fn onListen(_: c_int, _: ?*anyopaque) callconv(.c) void {
    acceptLoop();
}

fn acceptLoop() void {
    const io = io_ref orelse return;
    while (true) {
        const fd = accept(listen_fd, null, null);
        if (fd < 0) {
            if (errno() == EAGAIN) return;
            return;
        }
        setCloexecNonblockNosig(fd);
        if (nclients >= max_clients) {
            _ = close(fd);
            continue;
        }
        var uid: c_uint = 0;
        var gid: c_uint = 0;
        if (getpeereid(fd, &uid, &gid) != 0 or uid != getuid()) {
            _ = close(fd);
            continue;
        }
        if (io.watch_fd.?(io.ctx, fd, onClient, null) != 0) {
            _ = close(fd);
            continue;
        }
        clients[nclients] = .{
            .fd = fd,
            .conn = frame.Conn.init(gpa),
            .hello_at = time(null),
        };
        nclients += 1;
    }
}

fn onClient(fd: c_int, _: ?*anyopaque) callconv(.c) void {
    const idx = findClient(fd) orelse return;
    var buf: [read_chunk]u8 = undefined;
    const n = read(fd, &buf, buf.len);
    if (n == 0 or (n < 0 and errno() != EAGAIN)) {
        drop(idx);
        return;
    }
    if (n < 0) return;
    var c = &clients[idx];
    if (!c.hello_ok) {
        const now = time(null);
        if (c.hello_at != 0 and now > c.hello_at + 60) {
            drop(idx);
            return;
        }
    }
    const fr = c.conn.feed(buf[0..@intCast(n)]) catch {
        drop(idx);
        return;
    };
    handleAvailable(idx, fr);
}

fn handleAvailable(idx: u8, first: ?frame.Frame) void {
    var maybe = first;
    while (maybe) |fr| {
        const payload_copy: []u8 = gpa.dupe(u8, fr.payload) catch {
            drop(idx);
            return;
        };
        clients[idx].conn.consume(fr);
        handleFrame(idx, fr.typ, fr.id, payload_copy);
        gpa.free(payload_copy);
        if (findClientByIndex(idx) == null) return;
        maybe = clients[idx].conn.take() catch {
            drop(idx);
            return;
        };
    }
}

fn findClientByIndex(idx: u8) ?*Client {
    if (idx >= nclients) return null;
    return &clients[idx];
}

fn handleFrame(idx: u8, typ: frame.Type, id: u32, payload: []const u8) void {
    var c = &clients[idx];
    if (!c.hello_ok) {
        if (typ != .hello) {
            drop(idx);
            return;
        }
        const hello = rpc.parseHello(payload) catch {
            drop(idx);
            return;
        };
        if (hello.token.len != 0) {
            drop(idx);
            return;
        }
        var granted = bus.local_default;
        if (hello.caps_set) granted = granted.intersect(hello.caps);
        granted = granted.withoutAdmin();
        c.granted = granted;
        c.hello_ok = true;
        sendHelloOk(c, id, granted);
        return;
    }
    if (typ != .req) {
        drop(idx);
        return;
    }
    const req = rpc.parseReq(payload) catch {
        sendErr(c, id, "bad_args", "bad request");
        c.conn.finishReq();
        return;
    };
    var out: ?[*:0]u8 = null;
    const op_z = gpa.dupeZ(u8, req.op) catch {
        sendErr(c, id, "internal", "oom");
        c.conn.finishReq();
        return;
    };
    defer gpa.free(op_z);
    const args_z = gpa.dupeZ(u8, req.args) catch {
        sendErr(c, id, "internal", "oom");
        c.conn.finishReq();
        return;
    };
    defer gpa.free(args_z);
    _ = at_control_call_capped(op_z.ptr, args_z.ptr, &out, c.granted.toU32());
    const body = if (out) |p| std.mem.span(p) else "{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"no result\"}}";
    sendRaw(c, .res, id, body);
    if (out) |p| at_control_free(p);
    c.conn.finishReq();
}

fn sendHelloOk(c: *Client, id: u32, granted: bus.Cap) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "{\"server\":\"aterminal\",\"proto\":1,\"pid\":") catch return;
    var nbuf: [32]u8 = undefined;
    const ps = std.fmt.bufPrint(&nbuf, "{d}", .{getpid()}) catch return;
    buf.appendSlice(gpa, ps) catch return;
    buf.appendSlice(gpa, ",\"support_dir\":\"") catch return;
    json.jsonEscape(gpa, &buf, support_dir) catch return;
    buf.appendSlice(gpa, "\",\"caps\":[") catch return;
    appendCaps(&buf, granted) catch return;
    buf.appendSlice(gpa, "],\"ops\":[") catch return;
    appendOps(&buf) catch return;
    buf.appendSlice(gpa, "]}") catch return;
    sendRaw(c, .hello_ok, id, buf.items);
}

fn appendCaps(buf: *std.ArrayList(u8), cap: bus.Cap) !void {
    const bits = [_]bool{ cap.read, cap.focus, cap.input, cap.session, cap.layout, cap.fs, cap.admin, cap.pair };
    var first = true;
    for (bus.names, bits) |name, on| {
        if (!on) continue;
        if (!first) try buf.append(gpa, ',');
        first = false;
        try buf.append(gpa, '"');
        try buf.appendSlice(gpa, name);
        try buf.append(gpa, '"');
    }
}

fn appendOps(buf: *std.ArrayList(u8)) !void {
    var first = true;
    var i: u8 = 0;
    while (i < bus.opCount()) : (i += 1) {
        const name = bus.opName(i) orelse break;
        if (!first) try buf.append(gpa, ',');
        first = false;
        try buf.append(gpa, '"');
        try buf.appendSlice(gpa, name);
        try buf.append(gpa, '"');
    }
}

fn sendErr(c: *Client, id: u32, code: []const u8, message: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "{\"ok\":false,\"error\":{\"code\":\"") catch return;
    buf.appendSlice(gpa, code) catch return;
    buf.appendSlice(gpa, "\",\"message\":\"") catch return;
    json.jsonEscape(gpa, &buf, message) catch return;
    buf.appendSlice(gpa, "\"}}") catch return;
    sendRaw(c, .res, id, buf.items);
}

fn sendRaw(c: *Client, typ: frame.Type, id: u32, payload: []const u8) void {
    const bytes = frame.encode(gpa, typ, id, payload) catch return;
    defer gpa.free(bytes);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(c.fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0) return;
        off += @intCast(n);
    }
}

fn findClient(fd: c_int) ?u8 {
    var i: u8 = 0;
    while (i < nclients) : (i += 1) {
        if (clients[i].fd == fd) return i;
    }
    return null;
}

fn drop(idx: u8) void {
    if (idx >= nclients) return;
    const fd = clients[idx].fd;
    clients[idx].conn.deinit();
    const last = nclients - 1;
    if (idx != last) clients[idx] = clients[last];
    clients[last].fd = -1;
    nclients -= 1;
    if (io_ref) |io| {
        if (io.unwatch_fd) |u| _ = u(io.ctx, fd);
    }
}
