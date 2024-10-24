const std = @import("std");
const Build = std.Build;
const fs = std.fs;
const mem = std.mem;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{ .zig_wayland_path = "." });

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 2);
    scanner.generate("wl_output", 1);

    inline for ([_][]const u8{ "globals", "list", "listener", "seats" }) |example| {
        const exe = b.addExecutable(.{
            .name = example,
            .root_source_file = b.path("example/" ++ example ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("wayland", wayland);
        scanner.addCSource(exe);
        exe.linkLibC();
        exe.linkSystemLibrary("wayland-client");

        b.installArtifact(exe);
    }

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

pub const Scanner = struct {
    run: *Build.Step.Run,
    result: Build.LazyPath,

    /// Path to the system protocol directory, stored to avoid invoking pkg-config N times.
    wayland_protocols_path: []const u8,

    // TODO remove these when the workaround for zig issue #131 is no longer needed.
    compiles: std.ArrayListUnmanaged(*Build.Step.Compile) = .{},
    c_sources: std.ArrayListUnmanaged(Build.LazyPath) = .{},

    pub const Options = struct {
        /// Path to the wayland.xml file.
        /// If null, the output of `pkg-config --variable=pkgdatadir wayland-scanner` will be used.
        wayland_xml_path: ?[]const u8 = null,
        /// Path to the wayland-protocols installation.
        /// If null, the output of `pkg-config --variable=pkgdatadir wayland-protocols` will be used.
        wayland_protocols_path: ?[]const u8 = null,

        /// Path to this library for building zig-wayland-scanner (if vendoring within your own project)
        /// If null, zig-wayland-scanner is built from the package cache
        /// Note that this was "free" using @src in zig 0.13.0, but 0.14.0 makes @src paths relative to
        /// the build, which for Scanner.create(...) is actually the parent build.
        zig_wayland_path: ?[]const u8 = null,
    };

    pub fn create(b: *Build, options: Options) *Scanner {
        const wayland_xml_path = options.wayland_xml_path orelse blk: {
            const pc_output = b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-scanner" });
            break :blk b.pathJoin(&.{ mem.trim(u8, pc_output, &std.ascii.whitespace), "wayland.xml" });
        };
        const wayland_protocols_path = options.wayland_protocols_path orelse blk: {
            const pc_output = b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" });
            break :blk mem.trim(u8, pc_output, &std.ascii.whitespace);
        };

        const zig_wayland_path = options.zig_wayland_path orelse blk: {
            const cache_root = b.graph.global_cache_root;
            const fd_path = std.fmt.allocPrint(b.allocator, "/proc/self/fd/{d}", .{cache_root.handle.fd}) catch @panic("OOM");
            var path_buf: [fs.max_path_bytes]u8 = std.mem.zeroes([fs.max_path_bytes]u8);
            const cache_root_path = fs.readLinkAbsolute(fd_path, &path_buf) catch @panic(fd_path);

            const deps = b.available_deps;
            const zig_wayland_hash = for (deps) |dep| {
                if (mem.eql(u8, dep.@"0", "zig-wayland")) {
                    break dep.@"1";
                }
            } else null;
            break :blk std.fmt.allocPrint(b.allocator, "{s}/p/{s}", .{ cache_root_path, zig_wayland_hash.? }) catch @panic("OOM");
        };

        const exe = b.addExecutable(.{
            .name = "zig-wayland-scanner",
            .root_source_file = .{ .cwd_relative = fs.path.join(b.allocator, &[_][]const u8{ zig_wayland_path, "src/scanner.zig" }) catch @panic("OOM") },
            .target = b.host,
        });

        const run = b.addRunArtifact(exe);

        run.addArg("-o");
        const result = run.addOutputFileArg("wayland.zig");

        run.addArg("-i");
        run.addFileArg(.{ .cwd_relative = wayland_xml_path });

        const scanner = b.allocator.create(Scanner) catch @panic("OOM");
        scanner.* = .{
            .run = run,
            .result = result,
            .wayland_protocols_path = wayland_protocols_path,
        };

        return scanner;
    }

    /// Scan protocol xml provided by the wayland-protocols package at the given path
    /// relative to the wayland-protocols installation. (e.g. "stable/xdg-shell/xdg-shell.xml")
    pub fn addSystemProtocol(scanner: *Scanner, relative_path: []const u8) void {
        const b = scanner.run.step.owner;
        const full_path = b.pathJoin(&.{ scanner.wayland_protocols_path, relative_path });

        scanner.run.addArg("-i");
        scanner.run.addFileArg(.{ .cwd_relative = full_path });

        scanner.generateCSource(full_path);
    }

    /// Scan the protocol xml at the given path.
    pub fn addCustomProtocol(scanner: *Scanner, path: []const u8) void {
        // TODO should this take an std.Build.LazyPath instead? I think the answer is yes but
        // I haven't looked closely enough to justify the breaking change to myself yet.

        scanner.run.addArg("-i");
        scanner.run.addFileArg(.{ .cwd_relative = path });

        scanner.generateCSource(path);
    }

    /// Generate code for the given global interface at the given version,
    /// as well as all interfaces that can be created using it at that version.
    /// If the version found in the protocol xml is less than the requested version,
    /// an error will be printed and code generation will fail.
    /// Code is always generated for wl_display, wl_registry, wl_callback, and wl_buffer.
    pub fn generate(scanner: *Scanner, global_interface: []const u8, version: u32) void {
        var buffer: [32]u8 = undefined;
        const version_str = std.fmt.bufPrint(&buffer, "{}", .{version}) catch unreachable;

        scanner.run.addArgs(&.{ "-g", global_interface, version_str });
    }

    /// Generate and add the necessary C source to the compilation unit.
    /// Once https://github.com/ziglang/zig/issues/131 is resolved we can remove this.
    pub fn addCSource(scanner: *Scanner, compile: *Build.Step.Compile) void {
        const b = scanner.run.step.owner;

        for (scanner.c_sources.items) |c_source| {
            compile.addCSourceFile(.{
                .file = c_source,
                .flags = &.{ "-std=c99", "-O2" },
            });
        }

        scanner.compiles.append(b.allocator, compile) catch @panic("OOM");
    }

    /// Once https://github.com/ziglang/zig/issues/131 is resolved we can remove this.
    fn generateCSource(scanner: *Scanner, protocol: []const u8) void {
        const b = scanner.run.step.owner;
        const cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code", protocol });

        const out_name = mem.concat(b.allocator, u8, &.{ fs.path.stem(protocol), "-protocol.c" }) catch @panic("OOM");

        const c_source = cmd.addOutputFileArg(out_name);

        for (scanner.compiles.items) |compile| {
            compile.addCSourceFile(.{
                .file = c_source,
                .flags = &.{ "-std=c99", "-O2" },
            });
        }

        scanner.c_sources.append(b.allocator, c_source) catch @panic("OOM");
    }
};
