export fn at_store_dir(_: ?*const anyopaque) callconv(.c) ?[*:0]const u8 {
    return null;
}
export fn at_store_workspace_count(_: ?*const anyopaque) callconv(.c) u32 {
    return 0;
}
export fn at_store_id(_: ?*const anyopaque, _: u32) callconv(.c) ?[*:0]const u8 {
    return null;
}
export fn at_store_active_index(_: ?*const anyopaque) callconv(.c) i32 {
    return -1;
}
export fn at_store_add_tab(_: ?*anyopaque, _: u32, _: ?[*:0]const u8) callconv(.c) c_int {
    return -1;
}
export fn at_store_tab_count(_: ?*const anyopaque, _: u32) callconv(.c) u32 {
    return 0;
}
export fn at_store_tab_id(_: ?*const anyopaque, _: u32, _: u32) callconv(.c) ?[*:0]const u8 {
    return null;
}
export fn at_store_layout_build(_: ?*anyopaque, _: u32, _: u32) callconv(.c) c_int {
    return -1;
}
export fn at_store_layout_pane_id(_: ?*const anyopaque, _: u32) callconv(.c) ?[*:0]const u8 {
    return null;
}
export fn at_store_name(_: ?*const anyopaque, _: u32) callconv(.c) ?[*:0]const u8 {
    return null;
}
export fn at_store_agent(_: ?*const anyopaque, _: u32) callconv(.c) ?[*:0]const u8 {
    return null;
}
export fn at_store_folder_count(_: ?*const anyopaque, _: u32) callconv(.c) u32 {
    return 0;
}
export fn at_store_folder(_: ?*const anyopaque, _: u32, _: u32) callconv(.c) ?[*:0]const u8 {
    return null;
}
export fn at_store_tab_agent(_: ?*const anyopaque, _: u32, _: u32) callconv(.c) ?[*:0]const u8 {
    return null;
}
export fn at_store_tab_name(_: ?*const anyopaque, _: u32, _: u32) callconv(.c) ?[*:0]const u8 {
    return null;
}
export fn at_store_set_active(_: ?*anyopaque, _: i32) callconv(.c) void {}
export fn at_store_set_active_tab(_: ?*anyopaque, _: u32, _: i32) callconv(.c) c_int {
    return -1;
}

test {
    _ = @import("json.zig");
    _ = @import("control/bus.zig");
    _ = @import("control/frame.zig");
    _ = @import("control/rpc.zig");
    _ = @import("control/cmds.zig");
    _ = @import("control/config.zig");
    _ = @import("control/plugin.zig");
    _ = @import("control.zig");
}
