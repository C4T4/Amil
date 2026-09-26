const std = @import("std");

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

var host_ptr: ?*PluginHost = null;

export fn at_plugin_abi() callconv(.c) c_int {
    return 1;
}

export fn at_plugin_name() callconv(.c) [*:0]const u8 {
    return "echo";
}

export fn at_plugin_init(host: *PluginHost) callconv(.c) c_int {
    host_ptr = host;
    if (host.log) |log| _ = log(1, "echo extension loaded");
    if (host.call) |call| {
        var out: ?[*:0]u8 = null;
        _ = call("core.ping", "{}", &out);
        if (out) |p| {
            if (host.free) |free_fn| free_fn(p);
        }
    }
    return 0;
}

export fn at_plugin_shutdown() callconv(.c) void {
    if (host_ptr) |h| {
        if (h.log) |log| _ = log(1, "echo extension unloaded");
    }
    host_ptr = null;
}
