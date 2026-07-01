const std = @import("std");
const val = @import("value.zig");
const err = @import("error.zig");

pub fn clock(io: std.Io, args: []const val.LoxValue) err.Error!val.LoxValue {
    _ = args;
    const ts = std.Io.Clock.real.now(io);
    const ns: f64 = @floatFromInt(ts.toNanoseconds());
    return .{ .Number = ns / 1_000_000_000.0 };
}

pub fn sqrt(_: std.Io, args: []const val.LoxValue) err.Error!val.LoxValue {
    return switch (args[0]) {
        .Number => |num| .{ .Number = std.math.sqrt(num) },
        else => err.Error.RuntimeError,
    };
}

pub fn min(_: std.Io, args: []const val.LoxValue) err.Error!val.LoxValue {
    const a = switch (args[0]) {
        .Number => |num| num,
        else => return err.Error.RuntimeError,
    };

    const b = switch (args[1]) {
        .Number => |num| num,
        else => return err.Error.RuntimeError,
    };

    return .{ .Number = @min(a, b) };
}

pub fn max(_: std.Io, args: []const val.LoxValue) err.Error!val.LoxValue {
    const a = switch (args[0]) {
        .Number => |num| num,
        else => return err.Error.RuntimeError,
    };

    const b = switch (args[1]) {
        .Number => |num| num,
        else => return err.Error.RuntimeError,
    };

    return .{ .Number = @max(a, b) };
}
