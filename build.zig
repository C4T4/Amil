const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/store.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "aterminal",
        .root_module = root,
    });
    root.addCMacro("GHOSTTY_STATIC", "1");
    root.addCSourceFiles(.{
        .files = &.{
            "src/macos/App.m",
            "src/macos/Agents.m",
            "src/macos/TermView.m",
            "src/macos/History.m",
            "src/macos/Settings.m",
            "src/macos/Queue.m",
            "src/macos/Git.m",
            "src/macos/SplitView.m",
        },
        .flags = &.{
            "-fobjc-arc",
            "-fmodules",
            "-Iinclude",
            "-Wall",
            "-Wextra",
        },
    });
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });
    root.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));
    root.linkFramework("Cocoa", .{});
    root.linkFramework("AppKit", .{});
    root.linkFramework("Foundation", .{});
    root.linkFramework("QuartzCore", .{});
    root.linkFramework("CoreText", .{});
    root.linkFramework("CoreGraphics", .{});

    const app_rel = "ATerminal.app";
    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = app_rel ++ "/Contents/MacOS" } },
    });
    const install_plist = b.addInstallFile(
        b.path("resources/Info.plist"),
        app_rel ++ "/Contents/Info.plist",
    );
    const install_icns = b.addInstallFile(
        b.path("resources/AppIcon.icns"),
        app_rel ++ "/Contents/Resources/AppIcon.icns",
    );
    const install_car = b.addInstallFile(
        b.path("resources/Assets.car"),
        app_rel ++ "/Contents/Resources/Assets.car",
    );
    const install_agents = b.addInstallDirectory(.{
        .source_dir = b.path("resources/agents"),
        .install_dir = .{ .custom = app_rel ++ "/Contents/Resources" },
        .install_subdir = "agents",
        .exclude_extensions = &.{ ".svg" },
    });

    const write_pkginfo = b.addWriteFiles();
    const pkginfo = write_pkginfo.add("PkgInfo", "APPL????");
    const install_pkginfo = b.addInstallFile(pkginfo, app_rel ++ "/Contents/PkgInfo");

    b.getInstallStep().dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&install_plist.step);
    b.getInstallStep().dependOn(&install_icns.step);
    b.getInstallStep().dependOn(&install_car.step);
    b.getInstallStep().dependOn(&install_agents.step);
    const pty_mod = b.createModule(.{
        .root_source_file = b.path("src/at-pty-root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const pty = b.addExecutable(.{
        .name = "at-pty",
        .root_module = pty_mod,
    });
    pty_mod.addCSourceFiles(.{
        .files = &.{"src/at-pty.c"},
        .flags = &.{ "-Wall", "-Wextra" },
    });
    pty_mod.linkSystemLibrary("util", .{});
    const install_pty = b.addInstallArtifact(pty, .{
        .dest_dir = .{ .override = .{ .custom = app_rel ++ "/Contents/MacOS" } },
    });
    b.getInstallStep().dependOn(&install_pty.step);

    b.getInstallStep().dependOn(&install_pkginfo.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ATerminal");
    run_step.dependOn(&run_cmd.step);

    const atctl_mod = b.createModule(.{
        .root_source_file = b.path("src/atctl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const atctl = b.addExecutable(.{
        .name = "atctl",
        .root_module = atctl_mod,
    });
    b.installArtifact(atctl);

    const echo_mod = b.createModule(.{
        .root_source_file = b.path("src/plugins/echo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const echo_lib = b.addLibrary(.{
        .name = "at-echo",
        .linkage = .dynamic,
        .root_module = echo_mod,
    });
    const install_echo = b.addInstallArtifact(echo_lib, .{
        .dest_dir = .{ .override = .{ .custom = "plugins" } },
    });
    const pipeline_mod = b.createModule(.{
        .root_source_file = b.path("src/plugins/pipeline.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const pipeline_lib = b.addLibrary(.{
        .name = "at-pipeline",
        .linkage = .dynamic,
        .root_module = pipeline_mod,
    });
    const install_pipeline = b.addInstallArtifact(pipeline_lib, .{
        .dest_dir = .{ .override = .{ .custom = "plugins" } },
    });
    const mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/plugins/mcp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const mcp_lib = b.addLibrary(.{
        .name = "at-mcp",
        .linkage = .dynamic,
        .root_module = mcp_mod,
    });
    const install_mcp = b.addInstallArtifact(mcp_lib, .{
        .dest_dir = .{ .override = .{ .custom = "plugins" } },
    });
    const plugins_step = b.step("plugins", "Build extension dylibs (not inside ATerminal.app)");
    plugins_step.dependOn(&install_echo.step);
    plugins_step.dependOn(&install_pipeline.step);
    plugins_step.dependOn(&install_mcp.step);

    const install_pipeline_app = b.addInstallArtifact(pipeline_lib, .{
        .dest_dir = .{ .override = .{ .custom = app_rel ++ "/Contents/PlugIns" } },
    });
    const install_mcp_app = b.addInstallArtifact(mcp_lib, .{
        .dest_dir = .{ .override = .{ .custom = app_rel ++ "/Contents/PlugIns" } },
    });
    b.getInstallStep().dependOn(&install_pipeline_app.step);
    b.getInstallStep().dependOn(&install_mcp_app.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/control_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const unit_tests = b.addTest(.{
        .name = "control-test",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run control-plane tests");
    test_step.dependOn(&run_tests.step);
}
