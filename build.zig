const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();

    const version_opt = b.option([]const u8, "version", "The version of the app") orelse "0.1.0-dev";
    options.addOption([]const u8, "version", version_opt);

    const yazap = b.dependency("yazap", .{});
    const fehler = b.dependency("fehler", .{});

    const deps = ModuleDeps{
        .b = b,
        .yazap = yazap,
        .fehler = fehler,
        .options = options,
    };

    const strip = optimize != .Debug;
    const exe = b.addExecutable(.{
        .name = "zlox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    deps.applyTo(exe.root_module);

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

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    deps.applyTo(exe_tests.root_module);

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

const ModuleDeps = struct {
    b: *std.Build,
    yazap: *std.Build.Dependency,
    fehler: *std.Build.Dependency,
    options: *std.Build.Step.Options,

    fn applyTo(self: ModuleDeps, mod: *std.Build.Module) void {
        mod.addImport("yazap", self.yazap.module("yazap"));
        mod.addImport("fehler", self.fehler.module("fehler"));
        mod.addImport("build_options", self.options.createModule());
    }
};
