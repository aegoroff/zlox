const std = @import("std");
const val = @import("value.zig");
const LoxValue = val.LoxValue;
const NativeResult = val.NativeResult;

/// Seconds of CPU this process has used, which is what the book's `clock()`
/// reports - it is C's `clock()` over `CLOCKS_PER_SEC`. Reading a wall clock
/// instead gives the same answer for `clock() - start`, the only use the
/// book's benchmarks put it to, but makes a bare `print clock();` print the
/// Unix time.
pub fn clock(io: std.Io, args: []const LoxValue) NativeResult {
    if (args.len != 0) return .{ .failure = "clock() expects no arguments." };
    const ts = std.Io.Clock.cpu_process.now(io);
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

test "clock measures from the start of the process" {
    // Arrange, Act
    const first = clock(std.testing.io, &.{}).value.asNumber();
    var spin: f64 = 0;
    var i: usize = 0;
    while (i < 200_000) : (i += 1) spin += @floatFromInt(i);
    const second = clock(std.testing.io, &.{}).value.asNumber();

    // Assert: seconds since the process began, so a small number that does not
    // go backwards - not the ten-digit Unix time a wall clock would give.
    try std.testing.expect(first >= 0);
    try std.testing.expect(second >= first);
    try std.testing.expect(second < 3600);
    try std.testing.expect(spin > 0);
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
