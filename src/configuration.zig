pub const Config = @This();

const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");

matches: yazap.ArgMatches,
allocator: std.mem.Allocator,
app: yazap.App,
io: std.Io,
app_descr: []const u8,

const path_name: []const u8 = "PATH";

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

    var app = yazap.App.init(gpa, "zlox", app_descr);

    var root_cmd = app.rootCommand();

    const file_arg = yazap.Arg.positional(path_name, "Full path to file to interpret", null);

    try root_cmd.addArg(file_arg);

    const matches = try app.parseFrom(io, argv);

    return Config{
        .matches = matches,
        .allocator = gpa,
        .app = app,
        .io = io,
        .app_descr = app_descr,
    };
}

pub fn getPathArgValue(match: yazap.ArgMatches) ?[]const u8 {
    return match.getSingleValue(path_name);
}

pub fn deinit(self: *Config) void {
    self.app.deinit();
    self.allocator.free(self.app_descr);
}
