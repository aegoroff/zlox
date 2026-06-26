const std = @import("std");
const err = @import("error.zig");

pub const LoxValue = union(enum) {
    Number: f64,
    Bool: bool,

    pub fn print(self: LoxValue, writer: *std.Io.Writer) !void {
        switch (self) {
            .Number => |n| try writer.print("{d}", .{n}),
            .Bool => |b| try writer.print("{}", .{b}),
        }
    }

    pub fn tryNumber(self: LoxValue) err.Error!f64 {
        return switch (self) {
            .Number => |n| n,
            else => return err.Error.RuntimeError,
        };
    }
};
