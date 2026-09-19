const std = @import("std");
const val = @import("value.zig");
const LoxValue = val.LoxValue;
const NativeResult = val.NativeResult;

pub fn clock(io: std.Io, args: []const LoxValue) NativeResult {
    if (args.len != 0) return .{ .failure = "clock() expects no arguments." };
    const ts = std.Io.Clock.real.now(io);
    const ns: f64 = @floatFromInt(ts.toNanoseconds());
    return .{ .value = LoxValue.number(ns / 1_000_000_000.0) };
}

pub fn sqrt(_: std.Io, args: []const LoxValue) NativeResult {
    if (args.len != 1) return .{ .failure = "sqrt() expects 1 argument." };
    if (!args[0].isNumber()) return .{ .failure = "sqrt() expects a number." };
    return .{ .value = LoxValue.number(std.math.sqrt(args[0].asNumber())) };
}

pub fn min(_: std.Io, args: []const LoxValue) NativeResult {
    if (args.len != 2) return .{ .failure = "min() expects 2 arguments." };
    if (!args[0].isNumber() or !args[1].isNumber()) return .{ .failure = "min() expects numbers." };
    return .{ .value = LoxValue.number(@min(args[0].asNumber(), args[1].asNumber())) };
}

pub fn max(_: std.Io, args: []const LoxValue) NativeResult {
    if (args.len != 2) return .{ .failure = "max() expects 2 arguments." };
    if (!args[0].isNumber() or !args[1].isNumber()) return .{ .failure = "max() expects numbers." };
    return .{ .value = LoxValue.number(@max(args[0].asNumber(), args[1].asNumber())) };
}

test "clock rejects arguments" {
    // Arrange
    const args = [_]LoxValue{LoxValue.number(1)};

    // Act
    const result = clock(std.testing.io, &args);

    // Assert
    try std.testing.expectEqualStrings("clock() expects no arguments.", result.failure);
}

test "sqrt rejects a wrong argument count" {
    // Arrange
    const args = [_]LoxValue{ LoxValue.number(1), LoxValue.number(2) };

    // Act
    const result = sqrt(std.testing.io, &args);

    // Assert
    try std.testing.expectEqualStrings("sqrt() expects 1 argument.", result.failure);
}

test "sqrt rejects a non-number" {
    // Arrange
    const args = [_]LoxValue{LoxValue.nil};

    // Act
    const result = sqrt(std.testing.io, &args);

    // Assert
    try std.testing.expectEqualStrings("sqrt() expects a number.", result.failure);
}

test "min rejects a non-number" {
    // Arrange
    const args = [_]LoxValue{ LoxValue.number(1), LoxValue.boolean(true) };

    // Act
    const result = min(std.testing.io, &args);

    // Assert
    try std.testing.expectEqualStrings("min() expects numbers.", result.failure);
}

test "max rejects a wrong argument count" {
    // Arrange
    const args = [_]LoxValue{LoxValue.number(1)};

    // Act
    const result = max(std.testing.io, &args);

    // Assert
    try std.testing.expectEqualStrings("max() expects 2 arguments.", result.failure);
}
