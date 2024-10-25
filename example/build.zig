const std = @import("std");
const Build = std.Build;
const Scanner = @import("zig-wayland").Scanner;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner_exe = b.dependency("zig-wayland", .{}).artifact("zig-wayland-scanner");
    const scanner_run = b.addRunArtifact(scanner_exe);

    const scanner = Scanner.create(b, scanner_run, .{});
    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 2);
    scanner.generate("wl_output", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    const example_names = [_][]const u8{ "globals", "list", "listener", "seats" };

    inline for (example_names) |example| {
        const exe = b.addExecutable(.{
            .name = example,
            .root_source_file = b.path(example ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("wayland", wayland);
        scanner.addCSource(exe);
        exe.linkLibC();
        exe.linkSystemLibrary("wayland-client");

        b.installArtifact(exe);
    }
}
