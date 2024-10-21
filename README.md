# zig-wayland

\*********************************************************************************
\* This repository is a fork of https://codeberg.org/ifreund/zig-wayland focused *
\* on maintaining compatibility with zig's unstable releases.                    *
\*********************************************************************************

Zig unstable bindings and protocol scanner for libwayland.

## Usage

A `Scanner` interface is provided which you may integrate with your `build.zig`:

```zig
const std = @import("std");
const Build = std.Build;

const Scanner = @import("zig-wayland").Scanner;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addCustomProtocol("protocol/private_foobar.xml");

    // Pass the maximum version implemented by your wayland server or client.
    // Requests, events, enums, etc. from newer versions will not be generated,
    // ensuring forwards compatibility with newer protocol xml.
    // This will also generate code for interfaces created using the provided
    // global interface, in this example wl_keyboard, wl_pointer, xdg_surface,
    // xdg_toplevel, etc. would be generated as well.
    scanner.generate("wl_seat", 4);
    scanner.generate("xdg_wm_base", 3);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("private_foobar_manager", 1);

    const exe = b.addExecutable(.{
        .name = "foobar",
        .root_source_file = .{ .path = "foobar.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("wayland", wayland);
    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");

    // TODO: remove when https://github.com/ziglang/zig/issues/131 is implemented
    scanner.addCSource(exe);

    b.installArtifact(exe);
}
```

Then, you may import the provided module in your project:

```zig
const wayland = @import("wayland");
const wl = wayland.client.wl;
```

There is an example project using zig-wayland here:
[hello-zig-wayland](https://codeberg.org/ifreund/hello-zig-wayland).

Note that zig-wayland does not currently do extensive verification of Wayland
protocol xml or provide good error messages if protocol xml is invalid. It is
recommend to use `wayland-scanner --strict` to debug protocol xml instead.

## Versioning

For now, zig-wayland versions are of the form `0.major.patch`. A major version
bump indicates a zig-wayland release that breaks API or requires a newer Zig
version to build. A patch version bump indicates a zig-wayland release that is
fully backwards compatible.

For unreleased versions, the `-dev` suffix is used (e.g. `0.1.0-dev`).

The version of zig-wayland currently has no direct relation to the upstream
libwayland version supported.

Breaking changes in zig-wayland's API will be necessary until a stable Zig 1.0
version is released, at which point I plan to switch to a new versioning scheme
and start the version numbers with `1` instead of `0`.

## License

zig-wayland is released under the MIT (expat) license.
