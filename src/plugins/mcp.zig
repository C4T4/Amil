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

extern "c" fn socket(domain: c_int, typ: c_int, protocol: c_int) c_int;
extern "c" fn bind(s: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(s: c_int, backlog: c_uint) c_int;
extern "c" fn accept(s: c_int, addr: ?*anyopaque, addrlen: ?*c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn recv(s: c_int, buf: [*]u8, n: usize, flags: c_int) isize;
extern "c" fn send(s: c_int, buf: [*]const u8, n: usize, flags: c_int) isize;
extern "c" fn setsockopt(s: c_int, level: c_int, name: c_int, val: *const anyopaque, len: c_uint) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;

const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const SOL_SOCKET: c_int = 0xffff;
const SO_REUSEADDR: c_int = 4;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 4;

const sockaddr_in = extern struct {
    sin_len: u8 = 16,
    sin_family: u8 = AF_INET,
    sin_port: u16 = 0,
    sin_addr: u32 = 0,
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

fn htons(p: u16) u16 {
    return (p << 8) | (p >> 8);
}

var host_ptr: ?*PluginHost = null;
var listen_fd: c_int = -1;
var bound_port: u16 = 8765;

const tools_json =
    \\{"tools":[
    \\{"name":"workspace_list","description":"List ATerminal workspaces (id, name, agent, folders).","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"workspace_focus","description":"Focus a workspace by id.","inputSchema":{"type":"object","properties":{"workspace":{"type":"string"}},"required":["workspace"]}},
    \\{"name":"tab_list","description":"List tabs in a workspace.","inputSchema":{"type":"object","properties":{"workspace":{"type":"string"}}}},
    \\{"name":"tab_add","description":"Open a new agent tab. agent is grok, claude, codex, or gemini.","inputSchema":{"type":"object","properties":{"workspace":{"type":"string"},"agent":{"type":"string"}}}},
    \\{"name":"tab_focus","description":"Focus a tab.","inputSchema":{"type":"object","properties":{"workspace":{"type":"string"},"tab":{"type":"string"}},"required":["tab"]}},
    \\{"name":"pane_input","description":"Type into a pane PTY. submit true sends Return.","inputSchema":{"type":"object","properties":{"pane":{"type":"string"},"text":{"type":"string"},"submit":{"type":"boolean"}},"required":["pane","text"]}},
    \\{"name":"pane_activity","description":"0 none, 1 standby, 2 needs input, 3 working.","inputSchema":{"type":"object","properties":{"pane":{"type":"string"}},"required":["pane"]}},
    \\{"name":"pipeline_push","description":"Enqueue a pipeline job.","inputSchema":{"type":"object","properties":{"task":{"type":"string"},"new_tab":{"type":"boolean"}},"required":["task"]}}
    \\]}
;

fn toolToOp(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "workspace_list")) return "workspace.list";
    if (std.mem.eql(u8, name, "workspace_focus")) return "workspace.focus";
    if (std.mem.eql(u8, name, "tab_list")) return "tab.list";
    if (std.mem.eql(u8, name, "tab_add")) return "tab.add";
    if (std.mem.eql(u8, name, "tab_focus")) return "tab.focus";
    if (std.mem.eql(u8, name, "pane_input")) return "pane.input";
    if (std.mem.eql(u8, name, "pane_activity")) return "pane.activity";
    if (std.mem.eql(u8, name, "pipeline_push")) return "pipeline.push";
    return null;
}

export fn at_plugin_abi() callconv(.c) c_int {
    return 1;
}

export fn at_plugin_name() callconv(.c) [*:0]const u8 {
    return "mcp";
}

export fn at_plugin_init(host: *PluginHost) callconv(.c) c_int {
    host_ptr = host;
    bound_port = parsePort(host.config_json);
    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) return -1;
    var one: c_int = 1;
    _ = setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));
    _ = fcntl(listen_fd, F_SETFL, O_NONBLOCK);
    var addr = sockaddr_in{
        .sin_port = htons(bound_port),
        .sin_addr = 0x0100007f, // 127.0.0.1 little-endian
    };
    if (bind(listen_fd, &addr, @sizeOf(sockaddr_in)) != 0 or listen(listen_fd, 8) != 0) {
        _ = close(listen_fd);
        listen_fd = -1;
        return -1;
    }
    if (host.watch_fd) |w| {
        if (w(listen_fd, onAccept, null) != 0) {
            _ = close(listen_fd);
            listen_fd = -1;
            return -1;
        }
    }
    var msg: [64]u8 = undefined;
    const s = std.fmt.bufPrintZ(&msg, "mcp listening on 127.0.0.1:{d}", .{bound_port}) catch "mcp up";
    if (host.log) |l| _ = l(1, s);
    return 0;
}

export fn at_plugin_shutdown() callconv(.c) void {
    if (host_ptr) |h| {
        if (h.unwatch_fd) |u| {
            if (listen_fd >= 0) _ = u(listen_fd);
        }
    }
    listen_fd = -1;
    host_ptr = null;
}

fn parsePort(cfg: ?[*:0]const u8) u16 {
    const s = if (cfg) |c| std.mem.span(c) else "";
    const key = "\"port\"";
    if (std.mem.indexOf(u8, s, key)) |i| {
        var j = i + key.len;
        while (j < s.len and (s[j] == ':' or s[j] == ' ')) j += 1;
        var n: u32 = 0;
        while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {
            n = n * 10 + (s[j] - '0');
        }
        if (n > 0 and n < 65536) return @intCast(n);
    }
    return 8765;
}

fn onAccept(fd: c_int, _: ?*anyopaque) callconv(.c) void {
    const cfd = accept(fd, null, null);
    if (cfd < 0) return;
    _ = fcntl(cfd, F_SETFL, O_NONBLOCK);
    var buf: [16384]u8 = undefined;
    const n = recv(cfd, &buf, buf.len, 0);
    if (n <= 0) {
        _ = close(cfd);
        return;
    }
    const req = buf[0..@intCast(n)];
    handleHttp(cfd, req);
    _ = close(cfd);
}

fn handleHttp(cfd: c_int, req: []const u8) void {
    if (std.mem.startsWith(u8, req, "GET ")) {
        reply(cfd, 200, "text/plain", "aterminal mcp\n");
        return;
    }
    const body = httpBody(req) orelse {
        reply(cfd, 400, "text/plain", "no body\n");
        return;
    };
    const method = jsonStr(body, "method");
    const id = jsonRaw(body, "id");
    if (std.mem.eql(u8, method, "initialize")) {
        const result =
            \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"aterminal","version":"1"}}
        ;
        rpcOk(cfd, id, result);
        return;
    }
    if (std.mem.eql(u8, method, "tools/list") or std.mem.eql(u8, method, "tools.list")) {
        rpcOk(cfd, id, tools_json);
        return;
    }
    if (std.mem.eql(u8, method, "notifications/initialized") or method.len == 0) {
        reply(cfd, 202, "text/plain", "");
        return;
    }
    if (std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, method, "tools.call")) {
        const name = jsonStr(body, "name");
        const op = toolToOp(name) orelse {
            rpcErr(cfd, id, "unknown tool");
            return;
        };
        var args = jsonObj(body, "arguments");
        if (args.len == 0) args = "{}";
        const out = callOp(op, args) orelse {
            rpcErr(cfd, id, "call failed");
            return;
        };
        defer gpa.free(out);
        rpcToolResult(cfd, id, out);
        return;
    }
    rpcErr(cfd, id, "unknown method");
}

fn callOp(op: []const u8, args: []const u8) ?[:0]u8 {
    const h = host_ptr orelse return null;
    const call = h.call orelse return null;
    const op_z = gpa.dupeZ(u8, op) catch return null;
    defer gpa.free(op_z);
    const args_z = gpa.dupeZ(u8, args) catch return null;
    defer gpa.free(args_z);
    var out: ?[*:0]u8 = null;
    const rc = call(op_z.ptr, args_z.ptr, &out);
    if (out == null) return null;
    const s = std.mem.span(out.?);
    const copy = gpa.dupeZ(u8, s) catch {
        if (h.free) |f| f(out);
        return null;
    };
    if (h.free) |f| f(out);
    if (rc != 0) {
        gpa.free(copy);
        return null;
    }
    return copy;
}

fn httpBody(req: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return null;
    return req[sep + 4 ..];
}

fn jsonStr(src: []const u8, key: []const u8) []const u8 {
    const q = key;
    var i: usize = 0;
    while (i + key.len + 3 < src.len) : (i += 1) {
        if (src[i] != '"') continue;
        if (!std.mem.eql(u8, src[i + 1 .. i + 1 + key.len], q)) continue;
        if (src[i + 1 + key.len] != '"') continue;
        var j = i + 1 + key.len + 1;
        while (j < src.len and (src[j] == ':' or src[j] == ' ')) j += 1;
        if (j >= src.len or src[j] != '"') return "";
        const start = j + 1;
        var k = start;
        while (k < src.len and src[k] != '"') {
            if (src[k] == '\\') k += 1;
            k += 1;
        }
        return src[start..k];
    }
    return "";
}

fn jsonRaw(src: []const u8, key: []const u8) []const u8 {
    var i: usize = 0;
    while (i + key.len + 3 < src.len) : (i += 1) {
        if (src[i] != '"') continue;
        if (!std.mem.eql(u8, src[i + 1 .. i + 1 + key.len], key)) continue;
        if (src[i + 1 + key.len] != '"') continue;
        var j = i + 1 + key.len + 1;
        while (j < src.len and (src[j] == ':' or src[j] == ' ')) j += 1;
        if (j >= src.len) return "null";
        const start = j;
        if (src[j] == '"') {
            j += 1;
            while (j < src.len and src[j] != '"') {
                if (src[j] == '\\') j += 1;
                j += 1;
            }
            if (j < src.len) j += 1;
            return src[start..j];
        }
        while (j < src.len and src[j] != ',' and src[j] != '}' and src[j] != ' ') j += 1;
        return src[start..j];
    }
    return "null";
}

fn jsonObj(src: []const u8, key: []const u8) []const u8 {
    var i: usize = 0;
    while (i + key.len + 3 < src.len) : (i += 1) {
        if (src[i] != '"') continue;
        if (!std.mem.eql(u8, src[i + 1 .. i + 1 + key.len], key)) continue;
        if (src[i + 1 + key.len] != '"') continue;
        var j = i + 1 + key.len + 1;
        while (j < src.len and (src[j] == ':' or src[j] == ' ')) j += 1;
        if (j >= src.len or src[j] != '{') return "";
        const start = j;
        var depth: u32 = 0;
        while (j < src.len) : (j += 1) {
            if (src[j] == '{') depth += 1;
            if (src[j] == '}') {
                depth -= 1;
                if (depth == 0) return src[start .. j + 1];
            }
        }
    }
    return "";
}

fn reply(cfd: c_int, code: u16, ctype: []const u8, body: []const u8) void {
    var head: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "HTTP/1.1 {d} OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
        code,
        ctype,
        body.len,
    }) catch return;
    _ = send(cfd, h.ptr, h.len, 0);
    if (body.len > 0) _ = send(cfd, body.ptr, body.len, 0);
}

fn rpcOk(cfd: c_int, id: []const u8, result: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    buf.appendSlice(gpa, id) catch return;
    buf.appendSlice(gpa, ",\"result\":") catch return;
    buf.appendSlice(gpa, result) catch return;
    buf.appendSlice(gpa, "}") catch return;
    reply(cfd, 200, "application/json", buf.items);
}

fn rpcErr(cfd: c_int, id: []const u8, msg: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    buf.appendSlice(gpa, id) catch return;
    buf.appendSlice(gpa, ",\"error\":{\"code\":-32000,\"message\":\"") catch return;
    buf.appendSlice(gpa, msg) catch return;
    buf.appendSlice(gpa, "\"}}") catch return;
    reply(cfd, 200, "application/json", buf.items);
}

fn rpcToolResult(cfd: c_int, id: []const u8, text: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    buf.appendSlice(gpa, id) catch return;
    buf.appendSlice(gpa, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"") catch return;
    for (text) |ch| {
        switch (ch) {
            '"' => buf.appendSlice(gpa, "\\\"") catch return,
            '\\' => buf.appendSlice(gpa, "\\\\") catch return,
            '\n' => buf.appendSlice(gpa, "\\n") catch return,
            '\r' => {},
            else => buf.append(gpa, ch) catch return,
        }
    }
    buf.appendSlice(gpa, "\"}]}}") catch return;
    reply(cfd, 200, "application/json", buf.items);
}
