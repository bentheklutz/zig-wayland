const std = @import("std");
const Build = std.Build;
const fs = std.fs;
const mem = std.mem;

const Scanner = @import("src/build_integration.zig").Scanner;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner_exe = b.addExecutable(.{
        .name = "zig-wayland-scanner",
        .target = target,
        .root_source_file = b.path("src/scanner.zig"),
        .optimize = optimize,
    });

    const scanner_run = b.addRunArtifact(scanner_exe);
    const scanner = Scanner.create(b, scanner_run, .{});
    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_seat", 1);
    scanner.generate("wl_shm", 2);
    scanner.generate("wl_output", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    const test_step = b.step("test", "Run the tests");
    {
        const scanner_tests = b.addTest(.{
            .root_source_file = b.path("src/scanner.zig"),
            .target = target,
            .optimize = optimize,
        });

        scanner_tests.root_module.addImport("wayland", wayland);

        test_step.dependOn(&scanner_tests.step);
    }
    {
        const ref_all = b.addTest(.{
            .root_source_file = b.path("src/ref_all.zig"),
            .target = target,
            .optimize = optimize,
        });

        ref_all.root_module.addImport("wayland", wayland);
        scanner.addCSource(ref_all);
        ref_all.linkLibC();
        ref_all.linkSystemLibrary("wayland-client");
        ref_all.linkSystemLibrary("wayland-server");
        ref_all.linkSystemLibrary("wayland-egl");
        ref_all.linkSystemLibrary("wayland-cursor");
        test_step.dependOn(&ref_all.step);
    }
}
