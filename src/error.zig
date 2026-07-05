const std = @import("std");

pub const Error = error{
    CompileError,
    RuntimeError,
};

pub const EXIT_COMPILE_ERROR: u8 = 65;
pub const EXIT_RUNTIME_ERROR: u8 = 70;
pub const EXIT_DEBUG_ERROR: u8 = 1;

pub fn exitCode(e: anyerror) u8 {
    if (@import("builtin").mode == .Debug) return EXIT_DEBUG_ERROR;
    return switch (e) {
        Error.CompileError => EXIT_COMPILE_ERROR,
        Error.RuntimeError => EXIT_RUNTIME_ERROR,
        else => EXIT_DEBUG_ERROR,
    };
}

test "exit code" {
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(EXIT_DEBUG_ERROR, exitCode(Error.CompileError));
        try std.testing.expectEqual(EXIT_DEBUG_ERROR, exitCode(Error.RuntimeError));
    } else {
        try std.testing.expectEqual(EXIT_COMPILE_ERROR, exitCode(Error.CompileError));
        try std.testing.expectEqual(EXIT_RUNTIME_ERROR, exitCode(Error.RuntimeError));
    }
}
