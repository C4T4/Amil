const std = @import("std");

pub const Parser = struct {
    src: []const u8,
    i: usize = 0,

    pub fn peek(self: *Parser) ?u8 {
        if (self.i >= self.src.len) return null;
        return self.src[self.i];
    }

    pub fn skipWs(self: *Parser) void {
        while (self.peek()) |ch| {
            if (ch != ' ' and ch != '\n' and ch != '\r' and ch != '\t') break;
            self.i += 1;
        }
    }

    pub fn eat(self: *Parser, ch: u8) !void {
        self.skipWs();
        if (self.peek() != ch) return error.BadJson;
        self.i += 1;
    }

    pub fn expectIdent(self: *Parser, ident: []const u8) !void {
        const s = try self.string();
        if (!std.mem.eql(u8, s, ident)) return error.BadJson;
    }

    /// Raw slice inside the quotes. Call unescapeAlloc if the value may contain escapes.
    pub fn string(self: *Parser) ![]const u8 {
        self.skipWs();
        try self.eat('"');
        const start = self.i;
        while (self.peek()) |ch| {
            if (ch == '"') {
                const out = self.src[start..self.i];
                self.i += 1;
                return out;
            }
            if (ch == '\\') self.i += 1;
            self.i += 1;
        }
        return error.BadJson;
    }

    pub fn number(self: *Parser) !i32 {
        self.skipWs();
        const start = self.i;
        if (self.peek() == '-') self.i += 1;
        while (self.peek()) |ch| {
            if (ch < '0' or ch > '9') break;
            self.i += 1;
        }
        if (start == self.i) return error.BadJson;
        return std.fmt.parseInt(i32, self.src[start..self.i], 10);
    }

    pub fn number64(self: *Parser) !i64 {
        self.skipWs();
        const start = self.i;
        if (self.peek() == '-') self.i += 1;
        while (self.peek()) |ch| {
            if (ch < '0' or ch > '9') break;
            self.i += 1;
        }
        if (start == self.i) return error.BadJson;
        return std.fmt.parseInt(i64, self.src[start..self.i], 10);
    }

    pub fn boolean(self: *Parser) !bool {
        self.skipWs();
        const rest = self.src[self.i..];
        if (rest.len >= 4 and std.mem.eql(u8, rest[0..4], "true")) {
            self.i += 4;
            return true;
        }
        if (rest.len >= 5 and std.mem.eql(u8, rest[0..5], "false")) {
            self.i += 5;
            return false;
        }
        return error.BadJson;
    }

    /// Inclusive slice of the next JSON value (object/array/string/number/bool/null).
    pub fn rawValue(self: *Parser) ![]const u8 {
        self.skipWs();
        const start = self.i;
        try self.skipValue();
        return self.src[start..self.i];
    }

    pub fn skipValue(self: *Parser) !void {
        self.skipWs();
        const ch = self.peek() orelse return error.BadJson;
        switch (ch) {
            '"' => {
                _ = try self.string();
            },
            '{' => {
                try self.eat('{');
                var first = true;
                while (true) {
                    self.skipWs();
                    if (self.peek() == '}') {
                        self.i += 1;
                        break;
                    }
                    if (!first) try self.eat(',');
                    first = false;
                    _ = try self.string();
                    try self.eat(':');
                    try self.skipValue();
                }
            },
            '[' => {
                try self.eat('[');
                var first = true;
                while (true) {
                    self.skipWs();
                    if (self.peek() == ']') {
                        self.i += 1;
                        break;
                    }
                    if (!first) try self.eat(',');
                    first = false;
                    try self.skipValue();
                }
            },
            't', 'f', 'n' => {
                while (self.peek()) |c| {
                    if (c < 'a' or c > 'z') break;
                    self.i += 1;
                }
            },
            else => {
                _ = try self.number();
            },
        }
    }
};

pub fn jsonEscape(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, ch),
        }
    }
}

pub fn unescapeAlloc(allocator: std.mem.Allocator, s: []const u8) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            const repl: u8 = switch (s[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"', '\\' => s[i],
                else => s[i],
            };
            try buf.append(allocator, repl);
        } else {
            try buf.append(allocator, s[i]);
        }
    }
    return allocator.dupeZ(u8, buf.items);
}

test "boolean true false" {
    var p = Parser{ .src = " true, false" };
    try std.testing.expect(try p.boolean());
    try p.eat(',');
    try std.testing.expect(!(try p.boolean()));
}

test "skip unknown object keys" {
    var p = Parser{ .src = "{\"a\":1,\"b\":{\"x\":true},\"c\":[1,2]}" };
    try p.eat('{');
    _ = try p.string();
    try p.eat(':');
    try std.testing.expectEqual(@as(i32, 1), try p.number());
    try p.eat(',');
    _ = try p.string();
    try p.eat(':');
    try p.skipValue();
    try p.eat(',');
    _ = try p.string();
    try p.eat(':');
    try p.skipValue();
    try p.eat('}');
}
