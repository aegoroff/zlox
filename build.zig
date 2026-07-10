const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const use_mimalloc = b.option(bool, "mimalloc", "Use mimalloc as the heap allocator") orelse true;

    const target = resolveTarget(b);
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();

    const version_opt = b.option([]const u8, "version", "The version of the app") orelse "0.1.0-dev";
    options.addOption([]const u8, "version", version_opt);

    options.addOption(bool, "use_mimalloc", use_mimalloc);

    const yazap = b.dependency("yazap", .{});
    const fehler = b.dependency("fehler", .{});

    const options_mod = options.createModule();

    const deps = ModuleDeps{
        .yazap = yazap,
        .fehler = fehler,
        .options_mod = options_mod,
    };

    const zlox_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    deps.applyTo(zlox_mod);

    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse (optimize != .Debug);
    const exe = b.addExecutable(.{
        .name = "zlox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("zlox", zlox_mod);
    exe.root_module.addImport("build_options", options_mod);

    if (use_mimalloc) {
        const mimalloc_src = b.dependency("mimalloc-src", .{});
        const root = exe.root_module;

        const translate_mi = b.addTranslateC(.{
            .root_source_file = mimalloc_src.path("include/mimalloc.h"),
            .target = target,
            .optimize = optimize,
        });

        root.addIncludePath(mimalloc_src.path("include"));
        root.addCSourceFile(.{
            .file = mimalloc_src.path("src/static.c"),
            .flags = &.{"-Wno-error=date-time"},
        });

        if (target.result.isMuslLibC()) {
            root.addCMacro("MI_LIBC_MUSL", "1");
        }
        switch (optimize) {
            .ReleaseFast, .ReleaseSmall => root.addCMacro("NDEBUG", "1"),
            .Debug, .ReleaseSafe => {},
        }

        const mimalloc_mod = b.createModule(.{
            .root_source_file = b.path("src/mimalloc/allocator.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mimalloc_mod.addImport("mi", translate_mi.createModule());
        root.addImport("mimalloc", mimalloc_mod);
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Runs `test` blocks from the zlox library module (compiler, vm, scanner, …).
    const zlox_tests = b.addTest(.{
        .root_module = zlox_mod,
    });

    const run_zlox_tests = b.addRunArtifact(zlox_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_zlox_tests.step);
}

const ModuleDeps = struct {
    yazap: *std.Build.Dependency,
    fehler: *std.Build.Dependency,
    options_mod: *std.Build.Module,

    fn applyTo(self: ModuleDeps, mod: *std.Build.Module) void {
        mod.addImport("yazap", self.yazap.module("yazap"));
        mod.addImport("fehler", self.fehler.module("fehler"));
        mod.addImport("build_options", self.options_mod);
    }
};

// Pin glibc on the default Linux-gnu target so Zig links against its
// bundled CRT instead of the system crt1.o. GCC >= 15 emits a .sframe
// section there that Zig 0.16's linker cannot handle.
const pinned_glibc: std.Target.Query.SemanticVersion = .{
    .major = 2,
    .minor = 38,
    .patch = 0,
};

fn materializeHostTriple(query: *std.Target.Query) void {
    if (query.cpu_arch == null) query.cpu_arch = builtin.cpu.arch;
    if (query.os_tag == null) query.os_tag = builtin.target.os.tag;
    if (query.abi == null) query.abi = builtin.target.abi;
}

fn needsHostTripleMaterialization(query: std.Target.Query) bool {
    if (query.cpu_arch != null or query.os_tag != null) return false;
    return switch (query.cpu_model) {
        .native, .explicit => true,
        .baseline, .determined_by_arch_os => false,
    };
}

fn resolveTarget(b: *std.Build) std.Build.ResolvedTarget {
    const default_target: std.Target.Query = .{
        .abi = .gnu,
        .glibc_version = pinned_glibc,
    };

    var query = b.standardTargetOptionsQueryOnly(.{
        .default_target = default_target,
    });

    // `-Dcpu=...` without `-Dtarget` parses arch/os as "native"; use the host triple.
    if (needsHostTripleMaterialization(query)) {
        materializeHostTriple(&query);
    }

    // `-Dcpu=native` parses "native" without inheriting `default_target.glibc_version`.
    if (query.glibc_version == null) {
        const os = query.os_tag orelse builtin.target.os.tag;
        if (os == .linux) {
            const abi = query.abi orelse builtin.target.abi;
            if (abi.isGnu()) {
                query.glibc_version = pinned_glibc;
            }
        }
    }

    return b.resolveTargetQuery(query);
}
