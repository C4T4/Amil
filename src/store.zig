const std = @import("std");
const json = @import("json.zig");

extern fn at_macos_main() void;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn arc4random() u32;
extern "c" fn getpid() c_int;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(file: ?*anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, file: ?*anyopaque) usize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, file: ?*anyopaque) usize;
extern "c" fn fseek(file: ?*anyopaque, off: c_long, whence: c_int) c_int;
extern "c" fn ftell(file: ?*anyopaque) c_long;
extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;
const O_CLOEXEC: c_int = 0x01000000;

const gpa = std.heap.c_allocator;

var last_error: [:0]const u8 = "";
var error_buf: [256]u8 = undefined;

pub fn main() void {
    at_macos_main();
}

fn setError(msg: []const u8) void {
    const n = @min(msg.len, error_buf.len - 1);
    @memcpy(error_buf[0..n], msg[0..n]);
    error_buf[n] = 0;
    last_error = error_buf[0..n :0];
}

const NodeKind = enum(u8) { pane = 0, vert = 1, horiz = 2 };

const Node = struct {
    kind: NodeKind,
    ratio: u8,
    id: [:0]u8,
    agent: [:0]u8,
    session: [:0]u8,
    a: ?*Node,
    b: ?*Node,
};

const Tab = struct {
    id: [:0]u8,
    name: [:0]u8,
    agent: [:0]u8,
    session: [:0]u8,
    root: *Node,
    active_pane: [:0]u8,
};

const HistoryEntry = struct {
    session: [:0]u8,
    agent: [:0]u8,
    cwd: [:0]u8,
    title: [:0]u8,
    folders: [][:0]u8,
    updated: i64,
};

const Workspace = struct {
    id: [:0]u8,
    name: [:0]u8,
    agent: [:0]u8,
    folders: [][:0]u8,
    tabs: []Tab,
    active_tab: i32,
};

const Store = struct {
    dir: [:0]u8,
    home: [:0]u8,
    workspaces: []Workspace,
    history: []HistoryEntry,
    active: i32,
    dirty: bool,
    recovered: bool,
    layout_n: u32 = 0,
    layout_kind: [32]u8 = undefined,
    layout_ratio: [32]u8 = undefined,
    layout_a: [32]i32 = undefined,
    layout_b: [32]i32 = undefined,
    layout_id: [32][:0]const u8 = undefined,
    layout_agent: [32][:0]const u8 = undefined,
    layout_session: [32][:0]const u8 = undefined,
    layout_nodes: [32]*Node = undefined,

    fn deinit(self: *Store) void {
        for (self.workspaces) |*ws| {
            freeWorkspace(ws);
        }
        if (self.workspaces.len > 0) gpa.free(self.workspaces);
        for (self.history) |*h| freeHistory(h);
        if (self.history.len > 0) gpa.free(self.history);
        gpa.free(self.home);
        gpa.free(self.dir);
        gpa.destroy(self);
    }
};

fn freeNode(n: *Node) void {
    if (n.a) |a| freeNode(a);
    if (n.b) |b| freeNode(b);
    gpa.free(n.id);
    gpa.free(n.agent);
    gpa.free(n.session);
    gpa.destroy(n);
}

fn freeTab(t: *Tab) void {
    gpa.free(t.id);
    gpa.free(t.name);
    gpa.free(t.agent);
    gpa.free(t.session);
    gpa.free(t.active_pane);
    freeNode(t.root);
}

fn makeLeaf(id: []const u8, agent: []const u8, session: []const u8) !*Node {
    const n = try gpa.create(Node);
    n.* = .{
        .kind = .pane,
        .ratio = 50,
        .id = try dupZ(id),
        .agent = try dupZ(agent),
        .session = try dupZ(session),
        .a = null,
        .b = null,
    };
    return n;
}

fn firstLeaf(n: *Node) *Node {
    if (n.kind == .pane) return n;
    return firstLeaf(n.a.?);
}

fn findPane(n: *Node, id: []const u8) ?*Node {
    if (n.kind == .pane) {
        return if (std.mem.eql(u8, n.id, id)) n else null;
    }
    if (n.a) |a| {
        if (findPane(a, id)) |x| return x;
    }
    if (n.b) |b| {
        if (findPane(b, id)) |x| return x;
    }
    return null;
}

fn countLeaves(n: *Node) u32 {
    if (n.kind == .pane) return 1;
    return countLeaves(n.a.?) + countLeaves(n.b.?);
}

fn replaceChild(parent: *Node, old: *Node, new: *Node) void {
    if (parent.a == old) parent.a = new else parent.b = new;
}

fn findParent(n: *Node, child: *Node) ?*Node {
    if (n.kind == .pane) return null;
    if (n.a == child or n.b == child) return n;
    if (n.a) |a| {
        if (findParent(a, child)) |p| return p;
    }
    if (n.b) |b| {
        if (findParent(b, child)) |p| return p;
    }
    return null;
}

fn freeHistory(h: *HistoryEntry) void {
    gpa.free(h.session);
    gpa.free(h.agent);
    gpa.free(h.cwd);
    gpa.free(h.title);
    for (h.folders) |f| gpa.free(f);
    if (h.folders.len > 0) gpa.free(h.folders);
}

fn dupFolders(src: []const [:0]u8) ![][:0]u8 {
    if (src.len == 0) return &.{};
    const out = try gpa.alloc([:0]u8, src.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |f| gpa.free(f);
        gpa.free(out);
    }
    for (src) |f| {
        out[n] = try dupZ(f);
        n += 1;
    }
    return out;
}

fn setHistoryFolders(h: *HistoryEntry, folders: []const [:0]u8) void {
    if (folders.len == 0) return;
    const next = dupFolders(folders) catch return;
    for (h.folders) |f| gpa.free(f);
    if (h.folders.len > 0) gpa.free(h.folders);
    h.folders = next;
    if (!std.mem.eql(u8, h.cwd, next[0])) {
        if (dupZ(next[0])) |c| {
            gpa.free(h.cwd);
            h.cwd = c;
        } else |_| {}
    }
}

const history_cap: usize = 200;

fn touchHistory(store: *Store, session: []const u8, agent: []const u8, folders: []const [:0]u8) void {
    if (session.len == 0) return;
    const now = time(null);
    const cwd: []const u8 = if (folders.len > 0) folders[0] else "";
    for (store.history, 0..) |*h, i| {
        if (!std.mem.eql(u8, h.session, session)) continue;
        h.updated = now;
        if (agent.len > 0 and !std.mem.eql(u8, h.agent, agent)) {
            if (dupZ(agent)) |a| {
                gpa.free(h.agent);
                h.agent = a;
            } else |_| {}
        }
        setHistoryFolders(h, folders);
        if (i != 0) {
            const tmp = h.*;
            var j = i;
            while (j > 0) : (j -= 1) {
                store.history[j] = store.history[j - 1];
            }
            store.history[0] = tmp;
        }
        return;
    }
    const session_z = dupZ(session) catch return;
    const agent_z = dupZ(if (agent.len > 0) agent else "claude") catch {
        gpa.free(session_z);
        return;
    };
    const cwd_z = dupZ(cwd) catch {
        gpa.free(session_z);
        gpa.free(agent_z);
        return;
    };
    const title_z = dupZ("") catch {
        gpa.free(session_z);
        gpa.free(agent_z);
        gpa.free(cwd_z);
        return;
    };
    const folders_z = dupFolders(folders) catch {
        gpa.free(session_z);
        gpa.free(agent_z);
        gpa.free(cwd_z);
        gpa.free(title_z);
        return;
    };
    var entry = HistoryEntry{
        .session = session_z,
        .agent = agent_z,
        .cwd = cwd_z,
        .title = title_z,
        .folders = folders_z,
        .updated = now,
    };
    const copy_n = @min(store.history.len, history_cap - 1);
    if (store.history.len == history_cap) {
        freeHistory(&store.history[store.history.len - 1]);
    }
    const next = gpa.alloc(HistoryEntry, copy_n + 1) catch {
        freeHistory(&entry);
        return;
    };
    next[0] = entry;
    if (copy_n > 0) @memcpy(next[1 .. 1 + copy_n], store.history[0..copy_n]);
    if (store.history.len > 0) gpa.free(store.history);
    store.history = next;
}

fn seedHistory(store: *Store) void {
    if (store.history.len > 0) return;
    for (store.workspaces) |ws| {
        for (ws.tabs) |t| {
            if (t.session.len == 0) continue;
            touchHistory(store, t.session, t.agent, ws.folders);
        }
    }
}

fn backfillHistoryFolders(store: *Store) void {
    for (store.history) |*h| {
        var found = false;
        for (store.workspaces) |ws| {
            for (ws.tabs) |t| {
                if (!std.mem.eql(u8, t.session, h.session)) continue;
                setHistoryFolders(h, ws.folders);
                found = true;
                break;
            }
            if (found) break;
        }
        if (h.folders.len == 0 and h.cwd.len > 0) {
            const one = gpa.alloc([:0]u8, 1) catch continue;
            one[0] = dupZ(h.cwd) catch {
                gpa.free(one);
                continue;
            };
            h.folders = one;
        }
    }
}

fn freeWorkspace(ws: *Workspace) void {
    gpa.free(ws.id);
    gpa.free(ws.name);
    gpa.free(ws.agent);
    for (ws.folders) |f| gpa.free(f);
    gpa.free(ws.folders);
    for (ws.tabs) |*t| freeTab(t);
    if (ws.tabs.len > 0) gpa.free(ws.tabs);
}

fn makeTab(agent: []const u8) !Tab {
    const id = try makeId();
    const nm = try dupZ("");
    const ag = try dupZ(agent);
    const sess = try dupZ("");
    const root = try makeLeaf(id, agent, "");
    const active = try dupZ(id);
    return .{
        .id = id,
        .name = nm,
        .agent = ag,
        .session = sess,
        .root = root,
        .active_pane = active,
    };
}

fn dupZ(s: []const u8) ![:0]u8 {
    return gpa.dupeZ(u8, s);
}

fn supportDir() ![:0]u8 {
    const home_c = getenv("HOME") orelse {
        setError("HOME is not set");
        return error.NoHome;
    };
    const home = std.mem.span(home_c);
    const path = try std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "ATerminal" });
    defer gpa.free(path);
    const path_z = try dupZ(path);
    defer gpa.free(path_z);
    _ = mkdir(path_z, 0o755);
    const ws_dir = try std.fs.path.join(gpa, &.{ path, "workspaces" });
    defer gpa.free(ws_dir);
    const ws_z = try dupZ(ws_dir);
    defer gpa.free(ws_z);
    _ = mkdir(ws_z, 0o755);
    return dupZ(path);
}

fn joinDir(dir: []const u8, name: []const u8) ![:0]u8 {
    const p = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(p);
    return dupZ(p);
}

fn statePath(dir: []const u8) ![:0]u8 {
    return joinDir(dir, "state.json");
}

fn recoveryPath(dir: []const u8) ![:0]u8 {
    return joinDir(dir, "state.recovery.json");
}

fn lockPath(dir: []const u8) ![:0]u8 {
    return joinDir(dir, "session.lock");
}

fn readFile(path: [:0]const u8) ![]u8 {
    const f = fopen(path, "rb") orelse return error.FileNotFound;
    defer _ = fclose(f);
    if (fseek(f, 0, 2) != 0) return error.ReadFailed;
    const sz = ftell(f);
    if (sz < 0) return error.ReadFailed;
    if (fseek(f, 0, 0) != 0) return error.ReadFailed;
    const buf = try gpa.alloc(u8, @intCast(sz));
    errdefer gpa.free(buf);
    const n = fread(buf.ptr, 1, buf.len, f);
    if (n != buf.len) return error.ReadFailed;
    return buf;
}

fn writeFile(path: [:0]const u8, data: []const u8) !void {
    const f = fopen(path, "wb") orelse return error.WriteFailed;
    defer _ = fclose(f);
    const n = fwrite(data.ptr, 1, data.len, f);
    if (n != data.len) return error.WriteFailed;
}

fn tmpPath(path: [:0]const u8) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, path);
    try buf.appendSlice(gpa, ".tmp");
    return dupZ(buf.items);
}

fn writeAtomic(path: [:0]const u8, data: []const u8) !void {
    const tmp = try tmpPath(path);
    defer gpa.free(tmp);
    const fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return error.WriteFailed;
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            _ = close(fd);
            _ = unlink(tmp);
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
    _ = fsync(fd);
    if (close(fd) != 0) {
        _ = unlink(tmp);
        return error.WriteFailed;
    }
    if (rename(tmp, path) != 0) {
        _ = unlink(tmp);
        return error.WriteFailed;
    }
    _ = chmod(path, 0o644);
}

fn writeLock(dir: []const u8) void {
    const path = lockPath(dir) catch return;
    defer gpa.free(path);
    var nbuf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&nbuf, "{d}\n", .{getpid()}) catch return;
    writeAtomic(path, s) catch {};
}

fn clearLock(dir: []const u8) void {
    const path = lockPath(dir) catch return;
    defer gpa.free(path);
    _ = unlink(path);
}

fn encodeNode(buf: *std.ArrayList(u8), n: *Node) !void {
    if (n.kind == .pane) {
        try append(buf, "{\"id\": \"");
        try jsonEscape(buf, n.id);
        try append(buf, "\", \"agent\": \"");
        try jsonEscape(buf, n.agent);
        try append(buf, "\", \"session\": \"");
        try jsonEscape(buf, n.session);
        try append(buf, "\"}");
        return;
    }
    try append(buf, "{\"dir\": \"");
    try append(buf, if (n.kind == .vert) "v" else "h");
    try append(buf, "\", \"ratio\": ");
    var nbuf: [8]u8 = undefined;
    const r = std.fmt.bufPrint(&nbuf, "{d}", .{n.ratio}) catch unreachable;
    try append(buf, r);
    try append(buf, ", \"a\": ");
    try encodeNode(buf, n.a.?);
    try append(buf, ", \"b\": ");
    try encodeNode(buf, n.b.?);
    try append(buf, "}");
}

fn encode(self: *Store) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try append(&buf, "{\n  \"active\": ");
    var nbuf: [16]u8 = undefined;
    const nstr = std.fmt.bufPrint(&nbuf, "{d}", .{self.active}) catch unreachable;
    try append(&buf, nstr);
    try append(&buf, ",\n  \"home\": \"");
    try jsonEscape(&buf, self.home);
    try append(&buf, "\",\n  \"workspaces\": [\n");
    for (self.workspaces, 0..) |ws, i| {
        try append(&buf, "    {\"id\": \"");
        try jsonEscape(&buf, ws.id);
        try append(&buf, "\", \"name\": \"");
        try jsonEscape(&buf, ws.name);
        try append(&buf, "\", \"default_agent\": \"");
        try jsonEscape(&buf, ws.agent);
        try append(&buf, "\", \"folders\": [");
        for (ws.folders, 0..) |f, j| {
            if (j != 0) try append(&buf, ", ");
            try append(&buf, "\"");
            try jsonEscape(&buf, f);
            try append(&buf, "\"");
        }
        try append(&buf, "], \"active_tab\": ");
        const tstr = std.fmt.bufPrint(&nbuf, "{d}", .{ws.active_tab}) catch unreachable;
        try append(&buf, tstr);
        try append(&buf, ", \"tabs\": [");
        for (ws.tabs, 0..) |tab, j| {
            if (j != 0) try append(&buf, ", ");
            try append(&buf, "{\"id\": \"");
            try jsonEscape(&buf, tab.id);
            try append(&buf, "\", \"name\": \"");
            try jsonEscape(&buf, tab.name);
            try append(&buf, "\", \"agent\": \"");
            try jsonEscape(&buf, tab.agent);
            try append(&buf, "\", \"session\": \"");
            try jsonEscape(&buf, tab.session);
            try append(&buf, "\", \"active_pane\": \"");
            try jsonEscape(&buf, tab.active_pane);
            if (tab.root.kind != .pane) {
                try append(&buf, "\", \"layout\": ");
                try encodeNode(&buf, tab.root);
                try append(&buf, "}");
            } else {
                try append(&buf, "\"}");
            }
        }
        try append(&buf, "]}");
        if (i + 1 != self.workspaces.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try append(&buf, "  ],\n  \"history\": [\n");
    var tbuf: [24]u8 = undefined;
    for (self.history, 0..) |h, i| {
        try append(&buf, "    {\"session\": \"");
        try jsonEscape(&buf, h.session);
        try append(&buf, "\", \"agent\": \"");
        try jsonEscape(&buf, h.agent);
        try append(&buf, "\", \"cwd\": \"");
        try jsonEscape(&buf, h.cwd);
        try append(&buf, "\", \"folders\": [");
        for (h.folders, 0..) |f, j| {
            if (j != 0) try append(&buf, ", ");
            try append(&buf, "\"");
            try jsonEscape(&buf, f);
            try append(&buf, "\"");
        }
        try append(&buf, "], \"title\": \"");
        try jsonEscape(&buf, h.title);
        try append(&buf, "\", \"updated\": ");
        const ts = std.fmt.bufPrint(&tbuf, "{d}", .{h.updated}) catch unreachable;
        try append(&buf, ts);
        try append(&buf, "}");
        if (i + 1 != self.history.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try append(&buf, "  ]\n}\n");
    return buf.toOwnedSlice(gpa);
}

fn append(buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.appendSlice(gpa, s);
}

fn jsonEscape(buf: *std.ArrayList(u8), s: []const u8) !void {
    return json.jsonEscape(gpa, buf, s);
}

fn save(self: *Store) !void {
    const bytes = try encode(self);
    defer gpa.free(bytes);
    const path = try statePath(self.dir);
    defer gpa.free(path);
    const rec = try recoveryPath(self.dir);
    defer gpa.free(rec);
    try writeAtomic(path, bytes);
    writeAtomic(rec, bytes) catch {};
    self.dirty = false;
}

const Parser = json.Parser;

fn unescapeAlloc(s: []const u8) ![:0]u8 {
    return json.unescapeAlloc(gpa, s);
}

fn loadFile(self: *Store, path: [:0]const u8) !void {
    const src = readFile(path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer gpa.free(src);
    try parseState(self, src);
}

fn load(self: *Store) void {
    const path = statePath(self.dir) catch return;
    defer gpa.free(path);
    if (loadFile(self, path)) |_| {
        return;
    } else |_| {
        const rec = recoveryPath(self.dir) catch return;
        defer gpa.free(rec);
        if (loadFile(self, rec)) |_| {
            self.recovered = true;
            save(self) catch {};
        } else |_| {}
    }
}

fn parseNode(p: *Parser) !*Node {
    try p.eat('{');
    var dir: ?[]const u8 = null;
    var ratio: i32 = 50;
    var id: ?[:0]u8 = null;
    var agent: ?[:0]u8 = null;
    var session: ?[:0]u8 = null;
    var a: ?*Node = null;
    var b: ?*Node = null;
    errdefer {
        if (id) |x| gpa.free(x);
        if (agent) |x| gpa.free(x);
        if (session) |x| gpa.free(x);
        if (a) |n| freeNode(n);
        if (b) |n| freeNode(n);
    }
    var first = true;
    while (true) {
        p.skipWs();
        if (p.peek() == '}') {
            p.i += 1;
            break;
        }
        if (!first) try p.eat(',');
        first = false;
        const k = try p.string();
        try p.eat(':');
        if (std.mem.eql(u8, k, "dir")) {
            dir = try p.string();
        } else if (std.mem.eql(u8, k, "ratio")) {
            ratio = try p.number();
        } else if (std.mem.eql(u8, k, "id")) {
            id = try unescapeAlloc(try p.string());
        } else if (std.mem.eql(u8, k, "agent")) {
            agent = try unescapeAlloc(try p.string());
        } else if (std.mem.eql(u8, k, "session") or std.mem.eql(u8, k, "session_id")) {
            session = try unescapeAlloc(try p.string());
        } else if (std.mem.eql(u8, k, "a")) {
            a = try parseNode(p);
        } else if (std.mem.eql(u8, k, "b")) {
            b = try parseNode(p);
        } else {
            try p.skipValue();
        }
    }
    if (dir != null and a != null and b != null) {
        const n = try gpa.create(Node);
        var r: u8 = 50;
        if (ratio < 20) r = 20 else if (ratio > 80) r = 80 else r = @intCast(ratio);
        n.* = .{
            .kind = if (dir.?.len > 0 and dir.?[0] == 'h') .horiz else .vert,
            .ratio = r,
            .id = id orelse try dupZ(""),
            .agent = agent orelse try dupZ(""),
            .session = session orelse try dupZ(""),
            .a = a,
            .b = b,
        };
        return n;
    }
    if (a) |n| freeNode(n);
    if (b) |n| freeNode(n);
    a = null;
    b = null;
    const n = try gpa.create(Node);
    n.* = .{
        .kind = .pane,
        .ratio = 50,
        .id = id orelse try makeId(),
        .agent = agent orelse try dupZ("claude"),
        .session = session orelse try dupZ(""),
        .a = null,
        .b = null,
    };
    return n;
}

fn parseState(self: *Store, src: []const u8) !void {

    var p = Parser{ .src = src };
    try p.eat('{');
    var active: i32 = -1;
    var home: ?[:0]u8 = null;
    var list: std.ArrayList(Workspace) = .empty;
    var history: std.ArrayList(HistoryEntry) = .empty;
    errdefer {
        if (home) |h| gpa.free(h);
        for (list.items) |*ws| freeWorkspace(ws);
        list.deinit(gpa);
        for (history.items) |*h| freeHistory(h);
        history.deinit(gpa);
    }

    var first_field = true;
    while (true) {
        p.skipWs();
        if (p.peek() == '}') {
            p.i += 1;
            break;
        }
        if (!first_field) try p.eat(',');
        first_field = false;
        const key = try p.string();
        try p.eat(':');
        if (std.mem.eql(u8, key, "active")) {
            active = try p.number();
        } else if (std.mem.eql(u8, key, "home")) {
            home = try unescapeAlloc(try p.string());
        } else if (std.mem.eql(u8, key, "workspaces")) {
            try p.eat('[');
            var first_ws = true;
            while (true) {
                p.skipWs();
                if (p.peek() == ']') {
                    p.i += 1;
                    break;
                }
                if (!first_ws) try p.eat(',');
                first_ws = false;
                try p.eat('{');
                var id: ?[:0]u8 = null;
                var name: ?[:0]u8 = null;
                var agent: ?[:0]u8 = null;
                var folders: std.ArrayList([:0]u8) = .empty;
                var tabs: std.ArrayList(Tab) = .empty;
                var active_tab: i32 = 0;
                errdefer {
                    if (id) |x| gpa.free(x);
                    if (name) |x| gpa.free(x);
                    if (agent) |x| gpa.free(x);
                    for (folders.items) |f| gpa.free(f);
                    folders.deinit(gpa);
                    for (tabs.items) |*t| freeTab(t);
                    tabs.deinit(gpa);
                }
                var first_k = true;
                while (true) {
                    p.skipWs();
                    if (p.peek() == '}') {
                        p.i += 1;
                        break;
                    }
                    if (!first_k) try p.eat(',');
                    first_k = false;
                    const k = try p.string();
                    try p.eat(':');
                    if (std.mem.eql(u8, k, "id")) {
                        id = try unescapeAlloc(try p.string());
                    } else if (std.mem.eql(u8, k, "name")) {
                        name = try unescapeAlloc(try p.string());
                    } else if (std.mem.eql(u8, k, "default_agent") or std.mem.eql(u8, k, "agent")) {
                        agent = try unescapeAlloc(try p.string());
                    } else if (std.mem.eql(u8, k, "folders")) {
                        try p.eat('[');
                        var first_f = true;
                        while (true) {
                            p.skipWs();
                            if (p.peek() == ']') {
                                p.i += 1;
                                break;
                            }
                            if (!first_f) try p.eat(',');
                            first_f = false;
                            try folders.append(gpa, try unescapeAlloc(try p.string()));
                        }
                    } else if (std.mem.eql(u8, k, "active_tab")) {
                        active_tab = try p.number();
                    } else if (std.mem.eql(u8, k, "tabs")) {
                        try p.eat('[');
                        var first_t = true;
                        while (true) {
                            p.skipWs();
                            if (p.peek() == ']') {
                                p.i += 1;
                                break;
                            }
                            if (!first_t) try p.eat(',');
                            first_t = false;
                            try p.eat('{');
                            var tid: ?[:0]u8 = null;
                            var tname: ?[:0]u8 = null;
                            var tagent: ?[:0]u8 = null;
                            var tsession: ?[:0]u8 = null;
                            var tactive: ?[:0]u8 = null;
                            var tlayout: ?*Node = null;
                            var first_tk = true;
                            while (true) {
                                p.skipWs();
                                if (p.peek() == '}') {
                                    p.i += 1;
                                    break;
                                }
                                if (!first_tk) try p.eat(',');
                                first_tk = false;
                                const tk = try p.string();
                                try p.eat(':');
                                if (std.mem.eql(u8, tk, "id")) {
                                    tid = try unescapeAlloc(try p.string());
                                } else if (std.mem.eql(u8, tk, "name")) {
                                    tname = try unescapeAlloc(try p.string());
                                } else if (std.mem.eql(u8, tk, "agent")) {
                                    tagent = try unescapeAlloc(try p.string());
                                } else if (std.mem.eql(u8, tk, "session") or std.mem.eql(u8, tk, "session_id")) {
                                    tsession = try unescapeAlloc(try p.string());
                                } else if (std.mem.eql(u8, tk, "active_pane")) {
                                    tactive = try unescapeAlloc(try p.string());
                                } else if (std.mem.eql(u8, tk, "layout")) {
                                    tlayout = try parseNode(&p);
                                } else {
                                    try p.skipValue();
                                }
                            }
                            const tid_z = tid orelse try makeId();
                            const tagent_z = tagent orelse try dupZ("claude");
                            const tsession_z = tsession orelse try dupZ("");
                            const root = tlayout orelse try makeLeaf(tid_z, tagent_z, tsession_z);
                            const active_z = tactive orelse try dupZ(firstLeaf(root).id);
                            try tabs.append(gpa, .{
                                .id = tid_z,
                                .name = tname orelse try dupZ(""),
                                .agent = tagent_z,
                                .session = tsession_z,
                                .root = root,
                                .active_pane = active_z,
                            });
                        }
                    } else {
                        try p.skipValue();
                    }
                }
                const agent_z = agent orelse try dupZ("claude");
                if (tabs.items.len == 0) {
                    try tabs.append(gpa, try makeTab(agent_z));
                }
                if (active_tab < 0 or @as(u32, @intCast(active_tab)) >= tabs.items.len) {
                    active_tab = 0;
                }
                try list.append(gpa, .{
                    .id = id orelse try dupZ("unknown"),
                    .name = name orelse try dupZ("untitled"),
                    .agent = agent_z,
                    .folders = try folders.toOwnedSlice(gpa),
                    .tabs = try tabs.toOwnedSlice(gpa),
                    .active_tab = active_tab,
                });
                tabs = .empty;
                folders = .empty;
            }
        } else if (std.mem.eql(u8, key, "history")) {
            try p.eat('[');
            var first_h = true;
            while (true) {
                p.skipWs();
                if (p.peek() == ']') {
                    p.i += 1;
                    break;
                }
                if (!first_h) try p.eat(',');
                first_h = false;
                try p.eat('{');
                var hsession: ?[:0]u8 = null;
                var hagent: ?[:0]u8 = null;
                var hcwd: ?[:0]u8 = null;
                var htitle: ?[:0]u8 = null;
                var hfolders: std.ArrayList([:0]u8) = .empty;
                var hupdated: i64 = 0;
                var first_hk = true;
                while (true) {
                    p.skipWs();
                    if (p.peek() == '}') {
                        p.i += 1;
                        break;
                    }
                    if (!first_hk) try p.eat(',');
                    first_hk = false;
                    const hk = try p.string();
                    try p.eat(':');
                    if (std.mem.eql(u8, hk, "session") or std.mem.eql(u8, hk, "session_id")) {
                        hsession = try unescapeAlloc(try p.string());
                    } else if (std.mem.eql(u8, hk, "agent")) {
                        hagent = try unescapeAlloc(try p.string());
                    } else if (std.mem.eql(u8, hk, "cwd")) {
                        hcwd = try unescapeAlloc(try p.string());
                    } else if (std.mem.eql(u8, hk, "title")) {
                        htitle = try unescapeAlloc(try p.string());
                    } else if (std.mem.eql(u8, hk, "updated")) {
                        hupdated = try p.number64();
                    } else if (std.mem.eql(u8, hk, "folders")) {
                        try p.eat('[');
                        var first_hf = true;
                        while (true) {
                            p.skipWs();
                            if (p.peek() == ']') {
                                p.i += 1;
                                break;
                            }
                            if (!first_hf) try p.eat(',');
                            first_hf = false;
                            try hfolders.append(gpa, try unescapeAlloc(try p.string()));
                        }
                    } else {
                        try p.skipValue();
                    }
                }
                const sid = hsession orelse {
                    if (hagent) |x| gpa.free(x);
                    if (hcwd) |x| gpa.free(x);
                    if (htitle) |x| gpa.free(x);
                    for (hfolders.items) |f| gpa.free(f);
                    hfolders.deinit(gpa);
                    continue;
                };
                if (sid.len == 0) {
                    gpa.free(sid);
                    if (hagent) |x| gpa.free(x);
                    if (hcwd) |x| gpa.free(x);
                    if (htitle) |x| gpa.free(x);
                    for (hfolders.items) |f| gpa.free(f);
                    hfolders.deinit(gpa);
                    continue;
                }
                var folders_slice: [][:0]u8 = &.{};
                if (hfolders.items.len > 0) {
                    folders_slice = try hfolders.toOwnedSlice(gpa);
                } else if (hcwd) |c| {
                    if (c.len > 0) {
                        const one = try gpa.alloc([:0]u8, 1);
                        one[0] = try dupZ(c);
                        folders_slice = one;
                    }
                }
                try history.append(gpa, .{
                    .session = sid,
                    .agent = hagent orelse try dupZ("claude"),
                    .cwd = hcwd orelse try dupZ(if (folders_slice.len > 0) folders_slice[0] else ""),
                    .title = htitle orelse try dupZ(""),
                    .folders = folders_slice,
                    .updated = hupdated,
                });
            }
        } else {
            try p.skipValue();
        }
    }

    for (self.workspaces) |*ws| freeWorkspace(ws);
    if (self.workspaces.len > 0) gpa.free(self.workspaces);
    self.workspaces = try list.toOwnedSlice(gpa);
    for (self.history) |*h| freeHistory(h);
    if (self.history.len > 0) gpa.free(self.history);
    self.history = try history.toOwnedSlice(gpa);
    if (self.home.len > 0) gpa.free(self.home);
    self.home = home orelse (dupZ("") catch return error.OutOfMemory);
    if (active >= 0 and @as(u32, @intCast(active)) < self.workspaces.len) {
        self.active = active;
    } else if (self.workspaces.len == 0) {
        self.active = -1;
    } else {
        self.active = 0;
    }
}

fn makeId() ![:0]u8 {
    var buf: [8]u8 = undefined;
    const n = arc4random();
    const s = std.fmt.bufPrint(&buf, "{x:0>8}", .{n}) catch unreachable;
    return dupZ(s);
}

fn asStore(ptr: ?*ATStore) ?*Store {
    return @ptrCast(@alignCast(ptr));
}

const ATStore = opaque {};

export fn at_store_open() callconv(.c) ?*ATStore {
    const store = gpa.create(Store) catch {
        setError("out of memory");
        return null;
    };
    const dir = supportDir() catch |err| {
        gpa.destroy(store);
        setError(@errorName(err));
        return null;
    };
    store.* = .{
        .dir = dir,
        .home = dupZ("") catch {
            gpa.free(dir);
            gpa.destroy(store);
            setError("out of memory");
            return null;
        },
        .workspaces = &.{},
        .history = &.{},
        .active = -1,
        .dirty = false,
        .recovered = false,
    };
    load(store);
    seedHistory(store);
    backfillHistoryFolders(store);
    if (store.home.len == 0 and store.workspaces.len > 0 and store.workspaces[0].folders.len > 0) {
        const seeded = dupZ(store.workspaces[0].folders[0]) catch null;
        if (seeded) |h| {
            gpa.free(store.home);
            store.home = h;
        }
    }
    save(store) catch {};
    writeLock(store.dir);
    return @ptrCast(store);
}

export fn at_store_close(ptr: ?*ATStore) callconv(.c) void {
    const store = asStore(ptr) orelse return;
    save(store) catch {};
    clearLock(store.dir);
    store.deinit();
}

export fn at_store_save(ptr: ?*ATStore) callconv(.c) c_int {
    const store = asStore(ptr) orelse {
        setError("null store");
        return -1;
    };
    save(store) catch |err| {
        setError(@errorName(err));
        return -1;
    };
    return 0;
}

export fn at_store_workspace_count(ptr: ?*const ATStore) callconv(.c) u32 {
    const store = asStore(@constCast(ptr)) orelse return 0;
    return @intCast(store.workspaces.len);
}

export fn at_store_active_index(ptr: ?*const ATStore) callconv(.c) i32 {
    const store = asStore(@constCast(ptr)) orelse return -1;
    return store.active;
}

export fn at_store_set_active(ptr: ?*ATStore, index: i32) callconv(.c) void {
    const store = asStore(ptr) orelse return;
    const next: i32 = blk: {
        if (index < 0 or @as(u32, @intCast(index)) >= store.workspaces.len) {
            break :blk if (store.workspaces.len == 0) @as(i32, -1) else 0;
        }
        break :blk index;
    };
    if (store.active == next) return;
    store.active = next;
    store.dirty = true;
    save(store) catch {};
}

export fn at_store_id(ptr: ?*const ATStore, index: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.workspaces.len) return null;
    return store.workspaces[index].id.ptr;
}

export fn at_store_name(ptr: ?*const ATStore, index: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.workspaces.len) return null;
    return store.workspaces[index].name.ptr;
}

export fn at_store_agent(ptr: ?*const ATStore, index: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.workspaces.len) return null;
    return store.workspaces[index].agent.ptr;
}

export fn at_store_folder_count(ptr: ?*const ATStore, index: u32) callconv(.c) u32 {
    const store = asStore(@constCast(ptr)) orelse return 0;
    if (index >= store.workspaces.len) return 0;
    return @intCast(store.workspaces[index].folders.len);
}

export fn at_store_folder(ptr: ?*const ATStore, index: u32, folder: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.workspaces.len) return null;
    const ws = store.workspaces[index];
    if (folder >= ws.folders.len) return null;
    return ws.folders[folder].ptr;
}

export fn at_store_add_workspace(
    ptr: ?*ATStore,
    name: ?[*:0]const u8,
    folders: ?[*]const [*:0]const u8,
    folder_count: u32,
    agent: ?[*:0]const u8,
) callconv(.c) c_int {
    const store = asStore(ptr) orelse {
        setError("null store");
        return -1;
    };
    if (name == null) {
        setError("name is required");
        return -1;
    }
    // A workspace with no folder is legal; the app runs it in the home folder.
    if (folder_count > 0 and folders == null) {
        setError("folder list is missing");
        return -1;
    }
    var folder_list = gpa.alloc([:0]u8, folder_count) catch {
        setError("out of memory");
        return -1;
    };
    var filled: usize = 0;
    errdefer {
        for (folder_list[0..filled]) |f| gpa.free(f);
        gpa.free(folder_list);
    }
    var i: u32 = 0;
    while (i < folder_count) : (i += 1) {
        const f = folders.?[i];
        folder_list[i] = dupZ(std.mem.span(f)) catch {
            setError("out of memory");
            return -1;
        };
        filled += 1;
    }
    const agent_s = std.mem.span(agent orelse "claude");
    var tab0 = makeTab(agent_s) catch {
        for (folder_list[0..filled]) |f| gpa.free(f);
        gpa.free(folder_list);
        setError("out of memory");
        return -1;
    };
    const tabs = gpa.alloc(Tab, 1) catch {
        freeTab(&tab0);
        for (folder_list[0..filled]) |f| gpa.free(f);
        gpa.free(folder_list);
        setError("out of memory");
        return -1;
    };
    tabs[0] = tab0;
    const ws = Workspace{
        .id = makeId() catch {
            setError("out of memory");
            return -1;
        },
        .name = dupZ(std.mem.span(name.?)) catch {
            setError("out of memory");
            return -1;
        },
        .agent = dupZ(agent_s) catch {
            setError("out of memory");
            return -1;
        },
        .folders = folder_list,
        .tabs = tabs,
        .active_tab = 0,
    };
    const new_slice = gpa.realloc(store.workspaces, store.workspaces.len + 1) catch {
        var tmp = ws;
        freeWorkspace(&tmp);
        setError("out of memory");
        return -1;
    };
    store.workspaces = new_slice;
    store.workspaces[store.workspaces.len - 1] = ws;
    store.active = @intCast(store.workspaces.len - 1);
    _ = at_store_save(ptr);
    return 0;
}

export fn at_store_add_folder(ptr: ?*ATStore, index: u32, path: ?[*:0]const u8) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (index >= store.workspaces.len or path == null) {
        setError("bad folder add");
        return -1;
    }
    const copied = dupZ(std.mem.span(path.?)) catch {
        setError("out of memory");
        return -1;
    };
    const ws = &store.workspaces[index];
    const new_folders = gpa.realloc(ws.folders, ws.folders.len + 1) catch {
        gpa.free(copied);
        setError("out of memory");
        return -1;
    };
    ws.folders = new_folders;
    ws.folders[ws.folders.len - 1] = copied;
    _ = at_store_save(ptr);
    return 0;
}

export fn at_store_remove_folder(ptr: ?*ATStore, index: u32, folder: u32) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (index >= store.workspaces.len) return -1;
    const ws = &store.workspaces[index];
    if (folder >= ws.folders.len) return -1;
    if (ws.folders.len == 1) {
        setError("workspace needs at least one folder");
        return -1;
    }
    gpa.free(ws.folders[folder]);
    var i = folder;
    while (i + 1 < ws.folders.len) : (i += 1) {
        ws.folders[i] = ws.folders[i + 1];
    }
    ws.folders = gpa.realloc(ws.folders, ws.folders.len - 1) catch ws.folders[0 .. ws.folders.len - 1];
    _ = at_store_save(ptr);
    return 0;
}

export fn at_store_remove_workspace(ptr: ?*ATStore, index: u32) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (index >= store.workspaces.len) return -1;
    freeWorkspace(&store.workspaces[index]);
    var i = index;
    while (i + 1 < store.workspaces.len) : (i += 1) {
        store.workspaces[i] = store.workspaces[i + 1];
    }
    store.workspaces = gpa.realloc(store.workspaces, store.workspaces.len - 1) catch store.workspaces[0 .. store.workspaces.len - 1];
    if (store.workspaces.len == 0) {
        store.active = -1;
    } else if (store.active >= @as(i32, @intCast(store.workspaces.len))) {
        store.active = @intCast(store.workspaces.len - 1);
    }
    _ = at_store_save(ptr);
    return 0;
}

export fn at_store_set_name(ptr: ?*ATStore, index: u32, name: ?[*:0]const u8) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (index >= store.workspaces.len or name == null) return -1;
    const span = std.mem.span(name.?);
    if (span.len == 0) {
        setError("workspace name required");
        return -1;
    }
    const copied = dupZ(span) catch {
        setError("out of memory");
        return -1;
    };
    gpa.free(store.workspaces[index].name);
    store.workspaces[index].name = copied;
    _ = at_store_save(ptr);
    return 0;
}

export fn at_store_set_agent(ptr: ?*ATStore, index: u32, agent: ?[*:0]const u8) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (index >= store.workspaces.len or agent == null) return -1;
    const copied = dupZ(std.mem.span(agent.?)) catch return -1;
    gpa.free(store.workspaces[index].agent);
    store.workspaces[index].agent = copied;
    _ = at_store_save(ptr);
    return 0;
}

export fn at_store_tab_count(ptr: ?*const ATStore, workspace: u32) callconv(.c) u32 {
    const store = asStore(@constCast(ptr)) orelse return 0;
    if (workspace >= store.workspaces.len) return 0;
    return @intCast(store.workspaces[workspace].tabs.len);
}

export fn at_store_active_tab(ptr: ?*const ATStore, workspace: u32) callconv(.c) i32 {
    const store = asStore(@constCast(ptr)) orelse return -1;
    if (workspace >= store.workspaces.len) return -1;
    return store.workspaces[workspace].active_tab;
}

export fn at_store_set_active_tab(ptr: ?*ATStore, workspace: u32, tab: i32) callconv(.c) void {
    const store = asStore(ptr) orelse return;
    if (workspace >= store.workspaces.len) return;
    const ws = &store.workspaces[workspace];
    if (ws.tabs.len == 0) return;
    if (tab < 0 or @as(u32, @intCast(tab)) >= ws.tabs.len) return;
    if (ws.active_tab == tab) return;
    ws.active_tab = tab;
    store.dirty = true;
    save(store) catch {};
}

export fn at_store_tab_id(ptr: ?*const ATStore, workspace: u32, tab: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (workspace >= store.workspaces.len) return null;
    const ws = store.workspaces[workspace];
    if (tab >= ws.tabs.len) return null;
    return ws.tabs[tab].id.ptr;
}

export fn at_store_tab_agent(ptr: ?*const ATStore, workspace: u32, tab: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (workspace >= store.workspaces.len) return null;
    const ws = store.workspaces[workspace];
    if (tab >= ws.tabs.len) return null;
    return ws.tabs[tab].agent.ptr;
}

// Null when unnamed, so the UI falls back to the agent's display name.
export fn at_store_tab_name(ptr: ?*const ATStore, workspace: u32, tab: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (workspace >= store.workspaces.len) return null;
    const ws = store.workspaces[workspace];
    if (tab >= ws.tabs.len) return null;
    if (ws.tabs[tab].name.len == 0) return null;
    return ws.tabs[tab].name.ptr;
}

// An empty name clears it, restoring the agent fallback.
export fn at_store_set_tab_name(ptr: ?*ATStore, workspace: u32, tab: u32, name: ?[*:0]const u8) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (workspace >= store.workspaces.len or name == null) return -1;
    const ws = &store.workspaces[workspace];
    if (tab >= ws.tabs.len) return -1;
    const copied = dupZ(std.mem.span(name.?)) catch {
        setError("out of memory");
        return -1;
    };
    gpa.free(ws.tabs[tab].name);
    ws.tabs[tab].name = copied;
    _ = at_store_save(ptr);
    return 0;
}

export fn at_store_tab_session(ptr: ?*const ATStore, workspace: u32, tab: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (workspace >= store.workspaces.len) return null;
    const ws = store.workspaces[workspace];
    if (tab >= ws.tabs.len) return null;
    if (ws.tabs[tab].session.len == 0) return null;
    return ws.tabs[tab].session.ptr;
}

export fn at_store_set_tab_session(ptr: ?*ATStore, tab_id: ?[*:0]const u8, session: ?[*:0]const u8) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (tab_id == null or session == null) {
        setError("tab session required");
        return -1;
    }
    const want = std.mem.span(tab_id.?);
    const incoming = std.mem.span(session.?);
    for (store.workspaces) |*ws| {
        for (ws.tabs) |*t| {
            const pane = findPane(t.root, want);
            const hit_tab = std.mem.eql(u8, t.id, want);
            if (pane == null and !hit_tab) continue;
            if (pane) |pn| {
                if (!std.mem.eql(u8, pn.session, incoming)) {
                    const copied = dupZ(incoming) catch {
                        setError("out of memory");
                        return -1;
                    };
                    gpa.free(pn.session);
                    pn.session = copied;
                }
            }
            if (hit_tab and !std.mem.eql(u8, t.session, incoming)) {
                const copied = dupZ(incoming) catch {
                    setError("out of memory");
                    return -1;
                };
                gpa.free(t.session);
                t.session = copied;
            }
            const ag = if (pane) |pn| pn.agent else t.agent;
            touchHistory(store, incoming, ag, ws.folders);
            store.dirty = true;
            save(store) catch {};
            return 0;
        }
    }
    setError("tab not found");
    return -1;
}

fn flatten(store: *Store, n: *Node) i32 {
    if (store.layout_n >= 32) return -1;
    const i: i32 = @intCast(store.layout_n);
    store.layout_n += 1;
    const idx: usize = @intCast(i);
    store.layout_nodes[idx] = n;
    if (n.kind == .pane) {
        store.layout_kind[idx] = 0;
        store.layout_ratio[idx] = 50;
        store.layout_a[idx] = -1;
        store.layout_b[idx] = -1;
        store.layout_id[idx] = n.id;
        store.layout_agent[idx] = n.agent;
        store.layout_session[idx] = n.session;
        return i;
    }
    const a = flatten(store, n.a.?);
    const b = flatten(store, n.b.?);
    store.layout_kind[idx] = if (n.kind == .vert) 1 else 2;
    store.layout_ratio[idx] = n.ratio;
    store.layout_a[idx] = a;
    store.layout_b[idx] = b;
    store.layout_id[idx] = n.id;
    store.layout_agent[idx] = n.agent;
    store.layout_session[idx] = n.session;
    return i;
}

export fn at_store_layout_build(ptr: ?*ATStore, workspace: u32, tab: u32) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (workspace >= store.workspaces.len) return -1;
    const ws = &store.workspaces[workspace];
    if (tab >= ws.tabs.len) return -1;
    store.layout_n = 0;
    _ = flatten(store, ws.tabs[tab].root);
    return 0;
}

export fn at_store_layout_count(ptr: ?*const ATStore) callconv(.c) u32 {
    const store = asStore(@constCast(ptr)) orelse return 0;
    return store.layout_n;
}

export fn at_store_layout_kind(ptr: ?*const ATStore, index: u32) callconv(.c) u8 {
    const store = asStore(@constCast(ptr)) orelse return 0;
    if (index >= store.layout_n) return 0;
    return store.layout_kind[index];
}

export fn at_store_layout_ratio(ptr: ?*const ATStore, index: u32) callconv(.c) f32 {
    const store = asStore(@constCast(ptr)) orelse return 0.5;
    if (index >= store.layout_n) return 0.5;
    return @as(f32, @floatFromInt(store.layout_ratio[index])) / 100.0;
}

export fn at_store_layout_a(ptr: ?*const ATStore, index: u32) callconv(.c) i32 {
    const store = asStore(@constCast(ptr)) orelse return -1;
    if (index >= store.layout_n) return -1;
    return store.layout_a[index];
}

export fn at_store_layout_b(ptr: ?*const ATStore, index: u32) callconv(.c) i32 {
    const store = asStore(@constCast(ptr)) orelse return -1;
    if (index >= store.layout_n) return -1;
    return store.layout_b[index];
}

export fn at_store_layout_pane_id(ptr: ?*const ATStore, index: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.layout_n) return null;
    if (store.layout_kind[index] != 0) return null;
    return store.layout_id[index].ptr;
}

export fn at_store_layout_pane_agent(ptr: ?*const ATStore, index: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.layout_n) return null;
    if (store.layout_kind[index] != 0) return null;
    return store.layout_agent[index].ptr;
}

export fn at_store_layout_pane_session(ptr: ?*const ATStore, index: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.layout_n) return null;
    if (store.layout_kind[index] != 0) return null;
    if (store.layout_session[index].len == 0) return null;
    return store.layout_session[index].ptr;
}

export fn at_store_active_pane(ptr: ?*const ATStore, workspace: u32, tab: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (workspace >= store.workspaces.len) return null;
    const ws = store.workspaces[workspace];
    if (tab >= ws.tabs.len) return null;
    return ws.tabs[tab].active_pane.ptr;
}

export fn at_store_set_active_pane(ptr: ?*ATStore, workspace: u32, tab: u32, pane_id: ?[*:0]const u8) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (workspace >= store.workspaces.len or pane_id == null) return -1;
    const ws = &store.workspaces[workspace];
    if (tab >= ws.tabs.len) return -1;
    const id = std.mem.span(pane_id.?);
    if (findPane(ws.tabs[tab].root, id) == null) return -1;
    if (std.mem.eql(u8, ws.tabs[tab].active_pane, id)) return 0;
    const copied = dupZ(id) catch return -1;
    gpa.free(ws.tabs[tab].active_pane);
    ws.tabs[tab].active_pane = copied;
    store.dirty = true;
    save(store) catch {};
    return 0;
}

export fn at_store_set_split_ratio(ptr: ?*ATStore, index: u32, ratio: f32) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (index >= store.layout_n) return -1;
    var r = ratio;
    if (r < 0.2) r = 0.2;
    if (r > 0.8) r = 0.8;
    const q: u8 = @intFromFloat(r * 100.0);
    store.layout_nodes[index].ratio = q;
    store.layout_ratio[index] = q;
    store.dirty = true;
    save(store) catch {};
    return 0;
}

export fn at_store_split(ptr: ?*ATStore, workspace: u32, tab: u32, horiz: c_int) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (workspace >= store.workspaces.len) return -1;
    const ws = &store.workspaces[workspace];
    if (tab >= ws.tabs.len) return -1;
    if (countLeaves(ws.tabs[tab].root) >= 8) {
        setError("too many splits");
        return -1;
    }
    const t = &ws.tabs[tab];
    const target = findPane(t.root, t.active_pane) orelse firstLeaf(t.root);
    const new_id = makeId() catch return -1;
    const leaf = makeLeaf(new_id, target.agent, "") catch {
        gpa.free(new_id);
        return -1;
    };
    gpa.free(new_id);
    const wrap = gpa.create(Node) catch {
        freeNode(leaf);
        return -1;
    };
    wrap.* = .{
        .kind = if (horiz != 0) .horiz else .vert,
        .ratio = 50,
        .id = dupZ("") catch {
            gpa.destroy(wrap);
            freeNode(leaf);
            return -1;
        },
        .agent = dupZ("") catch {
            gpa.free(wrap.id);
            gpa.destroy(wrap);
            freeNode(leaf);
            return -1;
        },
        .session = dupZ("") catch {
            gpa.free(wrap.id);
            gpa.free(wrap.agent);
            gpa.destroy(wrap);
            freeNode(leaf);
            return -1;
        },
        .a = target,
        .b = leaf,
    };
    if (t.root == target) {
        t.root = wrap;
    } else if (findParent(t.root, target)) |parent| {
        replaceChild(parent, target, wrap);
    } else {
        freeNode(wrap);
        return -1;
    }
    const copied = dupZ(leaf.id) catch return -1;
    gpa.free(t.active_pane);
    t.active_pane = copied;
    store.dirty = true;
    save(store) catch {};
    return 0;
}

export fn at_store_close_pane(ptr: ?*ATStore, workspace: u32, tab: u32, pane_id: ?[*:0]const u8) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (workspace >= store.workspaces.len or pane_id == null) return -1;
    const ws = &store.workspaces[workspace];
    if (tab >= ws.tabs.len) return -1;
    const t = &ws.tabs[tab];
    const id = std.mem.span(pane_id.?);
    if (countLeaves(t.root) <= 1) {
        setError("last pane");
        return -1;
    }
    const leaf = findPane(t.root, id) orelse return -1;
    const parent = findParent(t.root, leaf) orelse return -1;
    const keep = if (parent.a == leaf) parent.b.? else parent.a.?;
    if (t.root == parent) {
        t.root = keep;
    } else if (findParent(t.root, parent)) |gp| {
        replaceChild(gp, parent, keep);
    } else return -1;
    parent.a = null;
    parent.b = null;
    freeNode(leaf);
    freeNode(parent);
    if (std.mem.eql(u8, t.active_pane, id)) {
        const copied = dupZ(firstLeaf(t.root).id) catch return -1;
        gpa.free(t.active_pane);
        t.active_pane = copied;
    }
    store.dirty = true;
    save(store) catch {};
    return 0;
}

export fn at_store_history_count(ptr: ?*const ATStore) callconv(.c) u32 {
    const store = asStore(@constCast(ptr)) orelse return 0;
    return @intCast(store.history.len);
}

export fn at_store_history_session(ptr: ?*const ATStore, index: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.history.len) return null;
    return store.history[index].session.ptr;
}

export fn at_store_history_agent(ptr: ?*const ATStore, index: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.history.len) return null;
    return store.history[index].agent.ptr;
}

export fn at_store_history_cwd(ptr: ?*const ATStore, index: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.history.len) return null;
    const h = store.history[index];
    if (h.folders.len > 0) return h.folders[0].ptr;
    if (h.cwd.len == 0) return null;
    return h.cwd.ptr;
}

export fn at_store_history_folder_count(ptr: ?*const ATStore, index: u32) callconv(.c) u32 {
    const store = asStore(@constCast(ptr)) orelse return 0;
    if (index >= store.history.len) return 0;
    return @intCast(store.history[index].folders.len);
}

export fn at_store_history_folder(ptr: ?*const ATStore, index: u32, folder: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.history.len) return null;
    const h = store.history[index];
    if (folder >= h.folders.len) return null;
    return h.folders[folder].ptr;
}

export fn at_store_history_title(ptr: ?*const ATStore, index: u32) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (index >= store.history.len) return null;
    if (store.history[index].title.len == 0) return null;
    return store.history[index].title.ptr;
}

export fn at_store_history_updated(ptr: ?*const ATStore, index: u32) callconv(.c) i64 {
    const store = asStore(@constCast(ptr)) orelse return 0;
    if (index >= store.history.len) return 0;
    return store.history[index].updated;
}

export fn at_store_add_tab(ptr: ?*ATStore, workspace: u32, agent: ?[*:0]const u8) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (workspace >= store.workspaces.len or agent == null) return -1;
    const ws = &store.workspaces[workspace];
    var tab = makeTab(std.mem.span(agent.?)) catch {
        setError("out of memory");
        return -1;
    };
    const next = gpa.realloc(ws.tabs, ws.tabs.len + 1) catch {
        freeTab(&tab);
        setError("out of memory");
        return -1;
    };
    ws.tabs = next;
    ws.tabs[ws.tabs.len - 1] = tab;
    ws.active_tab = @intCast(ws.tabs.len - 1);
    if (dupZ(std.mem.span(agent.?))) |copied| {
        gpa.free(ws.agent);
        ws.agent = copied;
    } else |_| {}
    store.dirty = true;
    save(store) catch {};
    return 0;
}

export fn at_store_remove_tab(ptr: ?*ATStore, workspace: u32, tab: u32) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (workspace >= store.workspaces.len) return -1;
    const ws = &store.workspaces[workspace];
    if (tab >= ws.tabs.len) return -1;
    if (ws.tabs.len == 1) {
        setError("need at least one tab");
        return -1;
    }
    freeTab(&ws.tabs[tab]);
    var i = tab;
    while (i + 1 < ws.tabs.len) : (i += 1) {
        ws.tabs[i] = ws.tabs[i + 1];
    }
    ws.tabs = gpa.realloc(ws.tabs, ws.tabs.len - 1) catch ws.tabs[0 .. ws.tabs.len - 1];
    if (ws.active_tab >= @as(i32, @intCast(ws.tabs.len))) {
        ws.active_tab = @intCast(ws.tabs.len - 1);
    }
    store.dirty = true;
    save(store) catch {};
    return 0;
}

export fn at_store_error() callconv(.c) [*:0]const u8 {
    return last_error.ptr;
}

export fn at_store_dir(ptr: ?*const ATStore) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    return store.dir.ptr;
}

export fn at_store_recovered(ptr: ?*const ATStore) callconv(.c) c_int {
    const store = asStore(@constCast(ptr)) orelse return 0;
    return if (store.recovered) 1 else 0;
}

export fn at_store_home(ptr: ?*const ATStore) callconv(.c) ?[*:0]const u8 {
    const store = asStore(@constCast(ptr)) orelse return null;
    if (store.home.len == 0) return null;
    return store.home.ptr;
}

export fn at_store_set_home(ptr: ?*ATStore, path: ?[*:0]const u8) callconv(.c) c_int {
    const store = asStore(ptr) orelse return -1;
    if (path == null or path.?[0] == 0) {
        setError("home folder required");
        return -1;
    }
    const copied = dupZ(std.mem.span(path.?)) catch {
        setError("out of memory");
        return -1;
    };
    if (store.home.len > 0) gpa.free(store.home);
    store.home = copied;
    store.dirty = true;
    save(store) catch |err| {
        setError(@errorName(err));
        return -1;
    };
    return 0;
}

comptime {
    _ = @import("control.zig");
}
