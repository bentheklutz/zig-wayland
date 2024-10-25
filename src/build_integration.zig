const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const fs = std.fs;
const mem = std.mem;

/// Convenience wrapper for using zig-wayland-scanner at build time without
/// needing to fuss with a bunch of addArg calls.
/// Intended use is to grab the zig-wayland-scanner executable, make a run
/// step for it, then pass that step in to Scanner.init();
pub const Scanner = struct {
    run: *Step.Run,
    result: Build.LazyPath,

    /// Path to the system protocol directory, stored to avoid invoking pkg-config N times.
    wayland_xml_path: []const u8,
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
    };

    pub fn create(b: *Build, run_step: *Step.Run, options: Options) *Scanner {
        const wayland_xml_path = options.wayland_xml_path orelse blk: {
            const pc_output = b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-scanner" });
            break :blk b.pathJoin(&.{ mem.trim(u8, pc_output, &std.ascii.whitespace), "wayland.xml" });
        };
        const wayland_protocols_path = options.wayland_protocols_path orelse blk: {
            const pc_output = b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" });
            break :blk mem.trim(u8, pc_output, &std.ascii.whitespace);
        };

        run_step.addArg("-o");
        const result = run_step.addOutputFileArg("wayland.zig");

        run_step.addArg("-i");
        run_step.addFileArg(.{ .cwd_relative = wayland_xml_path });

        const scanner = b.allocator.create(Scanner) catch @panic("OOM");

        scanner.* = .{
            .result = result,
            .wayland_xml_path = wayland_xml_path,
            .wayland_protocols_path = wayland_protocols_path,
            .run = run_step,
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
