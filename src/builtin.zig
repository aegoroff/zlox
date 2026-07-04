const std = @import("std");
const val = @import("value.zig");
const LoxValue = val.LoxValue;
const err = @import("error.zig");

pub fn clock(io: std.Io, args: []const val.LoxValue) err.Error!val.LoxValue {
    if (args.len != 0) return err.Error.RuntimeError;
    const ts = std.Io.Clock.real.now(io);
    const ns: f64 = @floatFromInt(ts.toNanoseconds());
    return LoxValue.number(ns / 1_000_000_000.0);
}

pub fn sqrt(_: std.Io, args: []const val.LoxValue) err.Error!val.LoxValue {
    if (args.len != 1) return err.Error.RuntimeError;
    if (!args[0].isNumber()) return err.Error.RuntimeError;
    return LoxValue.number(std.math.sqrt(args[0].asNumber()));
}

pub fn min(_: std.Io, args: []const val.LoxValue) err.Error!val.LoxValue {
    if (args.len != 2) return err.Error.RuntimeError;
    if (!args[0].isNumber() or !args[1].isNumber()) return err.Error.RuntimeError;
    return LoxValue.number(@min(args[0].asNumber(), args[1].asNumber()));
}

pub fn max(_: std.Io, args: []const val.LoxValue) err.Error!val.LoxValue {
    if (args.len != 2) return err.Error.RuntimeError;
    if (!args[0].isNumber() or !args[1].isNumber()) return err.Error.RuntimeError;
    return LoxValue.number(@max(args[0].asNumber(), args[1].asNumber()));
}
