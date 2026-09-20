const std = @import("std");

pub const Error = error{
    CompileError,
    RuntimeError,
    /// The script could not be read. Raised where the read fails, which is
    /// also where the path the caller typed is still around to name.
    IoError,
};

pub const EXIT_COMPILE_ERROR: u8 = 65;
pub const EXIT_RUNTIME_ERROR: u8 = 70;
pub const EXIT_IO_ERROR: u8 = 74;
pub const EXIT_DEBUG_ERROR: u8 = 1;

pub fn exitCode(e: anyerror) u8 {
    // Unlike the other two this one keeps its code in a debug build. The other
    // codes collapse to 1 there because a debug build is run to inspect a
    // failure; an unreadable script is not a failure to inspect, it is a
    // mistyped path, and the caller deserves the same answer either way.
    if (e == Error.IoError) return EXIT_IO_ERROR;
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

test "exit code of an unreadable script does not depend on the build mode" {
    // Arrange, Act, Assert
    try std.testing.expectEqual(EXIT_IO_ERROR, exitCode(Error.IoError));
}
