const std = @import("std");
const json = @import("../json.zig");

pub const max_plugins = 8;
pub const max_stem = 32;

pub fn isBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "core") or std.mem.eql(u8, name, "git") or std.mem.eql(u8, name, "background");
}

/// Comma-separated stems this extension needs. Empty if none.
pub fn requires(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "core")) return "";
    if (std.mem.eql(u8, name, "tailnet")) return "core, mcp";
    if (std.mem.eql(u8, name, "pipeline")) return "core";
    if (std.mem.eql(u8, name, "mcp")) return "core";
    return "core";
}

pub const Config = struct {
    core: bool = true,
    unix: bool = true,
    git: bool = true,
    background: bool = true,
    yolo: bool = false,
    max_clients: u8 = 8,
    plugin_n: u8 = 0,
    plugins: [max_plugins][max_stem]u8 = undefined,
    plugin_len: [max_plugins]u8 = undefined,
    extras: [2048]u8 = undefined,
    extras_len: u16 = 0,

    pub fn stem(self: *const Config, i: u8) []const u8 {
        return self.plugins[i][0..self.plugin_len[i]];
    }

    pub fn extrasSlice(self: *const Config) []const u8 {
        return self.extras[0..self.extras_len];
    }

    pub fn hasStem(self: *const Config, name: []const u8) bool {
        var i: u8 = 0;
        while (i < self.plugin_n) : (i += 1) {
            if (std.mem.eql(u8, self.stem(i), name)) return true;
        }
        return false;
    }

    pub fn setStem(self: *Config, name: []const u8, on: bool) void {
        if (isBuiltin(name)) {
            if (std.mem.eql(u8, name, "core")) {
                self.core = on;
                if (on) self.unix = true;
            }
            if (std.mem.eql(u8, name, "git")) self.git = on;
            if (std.mem.eql(u8, name, "background")) self.background = on;
            return;
        }
        if (on) {
            if (self.hasStem(name) or self.plugin_n >= max_plugins) return;
            const n: u8 = @intCast(@min(name.len, max_stem));
            const i = self.plugin_n;
            @memcpy(self.plugins[i][0..n], name[0..n]);
            self.plugin_len[i] = n;
            self.plugin_n += 1;
            return;
        }
        var i: u8 = 0;
        while (i < self.plugin_n) : (i += 1) {
            if (!std.mem.eql(u8, self.stem(i), name)) continue;
            var j = i;
            while (j + 1 < self.plugin_n) : (j += 1) {
                self.plugins[j] = self.plugins[j + 1];
                self.plugin_len[j] = self.plugin_len[j + 1];
            }
            self.plugin_n -= 1;
            return;
        }
    }
};

pub fn parse(src: []const u8) !Config {
    var p = json.Parser{ .src = src };
    try p.eat('{');
    var cfg = Config{};
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
        if (std.mem.eql(u8, k, "core")) {
            cfg.core = try p.boolean();
        } else if (std.mem.eql(u8, k, "unix")) {
            cfg.unix = try p.boolean();
        } else if (std.mem.eql(u8, k, "git")) {
            cfg.git = try p.boolean();
        } else if (std.mem.eql(u8, k, "background")) {
            cfg.background = try p.boolean();
        } else if (std.mem.eql(u8, k, "yolo")) {
            cfg.yolo = try p.boolean();
        } else if (std.mem.eql(u8, k, "max_clients")) {
            const n = try p.number();
            if (n < 1) cfg.max_clients = 1 else if (n > 8) cfg.max_clients = 8 else cfg.max_clients = @intCast(n);
        } else if (std.mem.eql(u8, k, "plugins")) {
            try parsePlugins(&p, &cfg);
        } else {
            const raw = try p.rawValue();
            if (cfg.extras_len + k.len + raw.len + 6 < cfg.extras.len) {
                var e = cfg.extras_len;
                cfg.extras[e] = ',';
                e += 1;
                cfg.extras[e] = ' ';
                e += 1;
                cfg.extras[e] = '"';
                e += 1;
                @memcpy(cfg.extras[e .. e + k.len], k);
                e += @intCast(k.len);
                cfg.extras[e] = '"';
                e += 1;
                cfg.extras[e] = ':';
                e += 1;
                cfg.extras[e] = ' ';
                e += 1;
                @memcpy(cfg.extras[e .. e + raw.len], raw);
                e += @intCast(raw.len);
                cfg.extras_len = e;
            }
        }
    }
    return cfg;
}

fn parsePlugins(p: *json.Parser, cfg: *Config) !void {
    try p.eat('[');
    var first = true;
    while (true) {
        p.skipWs();
        if (p.peek() == ']') {
            p.i += 1;
            break;
        }
        if (!first) try p.eat(',');
        first = false;
        const s = try p.string();
        if (isBuiltin(s)) {
            if (std.mem.eql(u8, s, "core")) cfg.core = true;
            if (std.mem.eql(u8, s, "git")) cfg.git = true;
            if (std.mem.eql(u8, s, "background")) cfg.background = true;
            continue;
        }
        if (cfg.plugin_n >= max_plugins) {
            try p.skipValue();
            continue;
        }
        const n: u8 = @intCast(@min(s.len, max_stem));
        const i = cfg.plugin_n;
        @memcpy(cfg.plugins[i][0..n], s[0..n]);
        cfg.plugin_len[i] = n;
        cfg.plugin_n += 1;
    }
}

test "parse control.json" {
    const src =
        \\{"unix":false,"plugins":["echo","mcp"],"http":{"port":1}}
    ;
    const cfg = try parse(src);
    try std.testing.expect(!cfg.unix);
    try std.testing.expectEqual(@as(u8, 2), cfg.plugin_n);
    try std.testing.expectEqualStrings("echo", cfg.stem(0));
    try std.testing.expectEqualStrings("mcp", cfg.stem(1));
}

test "missing file defaults" {
    const cfg = Config{};
    try std.testing.expect(cfg.core);
    try std.testing.expect(cfg.unix);
    try std.testing.expect(cfg.git);
    try std.testing.expectEqual(@as(u8, 0), cfg.plugin_n);
}

test "git builtin toggle" {
    var cfg = try parse("{\"git\":false}");
    try std.testing.expect(!cfg.git);
    cfg.setStem("git", true);
    try std.testing.expect(cfg.git);
}

test "yolo defaults off" {
    const cfg = Config{};
    try std.testing.expect(!cfg.yolo);
    const on = try parse("{\"yolo\":true}");
    try std.testing.expect(on.yolo);
}

test "background builtin default on" {
    const cfg = Config{};
    try std.testing.expect(cfg.background);
    var off = try parse("{\"background\":false}");
    try std.testing.expect(!off.background);
    off.setStem("background", true);
    try std.testing.expect(off.background);
}

test "preserve extra keys and toggle stem" {
    const src =
        \\{"unix":true,"plugins":["echo"],"http":{"port":9}}
    ;
    var cfg = try parse(src);
    try std.testing.expect(std.mem.indexOf(u8, cfg.extrasSlice(), "http") != null);
    cfg.setStem("mcp", true);
    try std.testing.expect(cfg.hasStem("mcp"));
    cfg.setStem("echo", false);
    try std.testing.expect(!cfg.hasStem("echo"));
}
