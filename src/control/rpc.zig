const std = @import("std");
const json = @import("../json.zig");
const bus = @import("bus.zig");

pub const Hello = struct {
    client: []const u8 = "",
    client_ver: i32 = 0,
    token: []const u8 = "",
    caps: bus.Cap = .{},
    caps_set: bool = false,
};

pub const Req = struct {
    op: []const u8 = "",
    args: []const u8 = "{}",
};

pub fn parseHello(src: []const u8) !Hello {
    var p = json.Parser{ .src = src };
    try p.eat('{');
    var h = Hello{};
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
        if (std.mem.eql(u8, k, "client")) {
            h.client = try p.string();
        } else if (std.mem.eql(u8, k, "client_ver")) {
            h.client_ver = try p.number();
        } else if (std.mem.eql(u8, k, "token")) {
            h.token = try p.string();
        } else if (std.mem.eql(u8, k, "caps")) {
            h.caps = try parseCapArray(&p);
            h.caps_set = true;
        } else {
            try p.skipValue();
        }
    }
    return h;
}

pub fn parseReq(src: []const u8) !Req {
    var p = json.Parser{ .src = src };
    try p.eat('{');
    var r = Req{};
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
        if (std.mem.eql(u8, k, "op")) {
            r.op = try p.string();
        } else if (std.mem.eql(u8, k, "args")) {
            r.args = try p.rawValue();
        } else {
            try p.skipValue();
        }
    }
    if (r.op.len == 0) return error.BadJson;
    return r;
}

pub const InputArgs = struct {
    pane: []const u8 = "",
    text: []const u8 = "",
    submit: bool = false,
    ensure: bool = false,
};

pub fn parseInputArgs(src: []const u8) !InputArgs {
    var p = json.Parser{ .src = src };
    try p.eat('{');
    var a = InputArgs{};
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
        if (std.mem.eql(u8, k, "pane")) {
            a.pane = try p.string();
        } else if (std.mem.eql(u8, k, "text")) {
            a.text = try p.string();
        } else if (std.mem.eql(u8, k, "submit")) {
            a.submit = try p.boolean();
        } else if (std.mem.eql(u8, k, "ensure")) {
            a.ensure = try p.boolean();
        } else {
            try p.skipValue();
        }
    }
    return a;
}

fn parseCapArray(p: *json.Parser) !bus.Cap {
    try p.eat('[');
    var cap = bus.Cap{};
    var first = true;
    while (true) {
        p.skipWs();
        if (p.peek() == ']') {
            p.i += 1;
            break;
        }
        if (!first) try p.eat(',');
        first = false;
        const name = try p.string();
        if (std.mem.eql(u8, name, "read")) cap.read = true;
        if (std.mem.eql(u8, name, "focus")) cap.focus = true;
        if (std.mem.eql(u8, name, "input")) cap.input = true;
        if (std.mem.eql(u8, name, "session")) cap.session = true;
        if (std.mem.eql(u8, name, "layout")) cap.layout = true;
        if (std.mem.eql(u8, name, "fs")) cap.fs = true;
        if (std.mem.eql(u8, name, "admin")) cap.admin = true;
        if (std.mem.eql(u8, name, "pair")) cap.pair = true;
    }
    return cap;
}

pub fn errCode(e: bus.BusError) []const u8 {
    return switch (e) {
        error.UnknownOp => "unknown_op",
        error.Denied => "denied",
        error.BadArgs => "bad_args",
        error.NotFound => "not_found",
        error.NotReady => "not_ready",
        error.WouldBlock => "would_block",
        error.Unavailable => "unavailable",
        error.Internal => "internal",
    };
}

test "parse req with submit bool" {
    const src = "{\"op\":\"pane.input\",\"args\":{\"pane\":\"abc\",\"text\":\"hi\",\"submit\":true}}";
    const r = try parseReq(src);
    try std.testing.expectEqualStrings("pane.input", r.op);
    const a = try parseInputArgs(r.args);
    try std.testing.expectEqualStrings("abc", a.pane);
    try std.testing.expectEqualStrings("hi", a.text);
    try std.testing.expect(a.submit);
}

test "parse hello caps" {
    const src = "{\"client\":\"atctl\",\"client_ver\":1,\"token\":\"\",\"caps\":[\"read\",\"pair\"]}";
    const h = try parseHello(src);
    try std.testing.expectEqualStrings("atctl", h.client);
    try std.testing.expect(h.caps.read);
    try std.testing.expect(h.caps.pair);
    try std.testing.expect(!h.caps.admin);
}
