pub const Config = @This();

const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");

matches: yazap.ArgMatches,
allocator: std.mem.Allocator,
app: *yazap.App,
io: std.Io,
app_descr: []const u8,

const path_name: []const u8 = "PATH";
const printcode: []const u8 = "printcode";

pub fn init(gpa: std.mem.Allocator, io: std.Io, argv: []const [:0]const u8) !Config {
    const app_descr_template =
        \\Lox language zig interpreter {s} {s}
        \\Copyright (C) 2026 Alexander Egorov. All rights reserved.
    ;
    const query = std.Target.Query.fromTarget(&builtin.target);
    const app_descr = try std.fmt.allocPrint(
        gpa,
        app_descr_template,
        .{ build_options.version, @tagName(query.cpu_arch.?) },
    );
    errdefer gpa.free(app_descr);

    const app = try gpa.create(yazap.App);
    errdefer gpa.destroy(app);
    app.* = yazap.App.init(gpa, "zlox", app_descr);
    // From here the app owns an arena, its command tree and, after parsing, the
    // parse result. Only `deinit` releases those; destroying the struct frees
    // the pointer and leaks everything behind it. A bad command line, not just
    // a failed allocation, takes this path.
    errdefer app.deinit();

    var root_cmd = app.rootCommand();

    const printcode_opt = yazap.Arg.booleanOption(printcode, null, "Printing bytecode");
    const file_arg = yazap.Arg.positional(path_name, "Full path to file to interpret", null);

    try root_cmd.addArg(printcode_opt);
    try root_cmd.addArg(file_arg);

    const matches = try app.parseFrom(io, argv);

    return .{
        .matches = matches,
        .allocator = gpa,
        .app = app,
        .io = io,
        .app_descr = app_descr,
    };
}

pub fn getPathArgValue(self: *Config) ?[]const u8 {
    return self.matches.getSingleValue(path_name);
}

pub fn printCode(self: *Config) bool {
    return self.matches.containsArg(printcode);
}

pub fn deinit(self: *Config) void {
    self.app.deinit();
    self.allocator.destroy(self.app);
    self.allocator.free(self.app_descr);
}

test "a rejected command line releases the app" {
    // Arrange: an option the app does not define, so `parseFrom` fails after
    // the app has already built its command tree.
    const argv = [_][:0]const u8{"--no-such-option"};

    // Act
    const result = Config.init(std.testing.allocator, std.testing.io, &argv);

    // Assert: the testing allocator reports anything left behind when the test
    // ends, which is what this is here to catch.
    try std.testing.expectError(error.UnrecognizedOption, result);
}
