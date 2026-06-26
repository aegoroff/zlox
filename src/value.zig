const std = @import("std");

pub const LoxValue = union(enum) {
    Number: f64,
    Bool: bool,

    pub fn print(self: LoxValue, writer: *std.Io.Writer) !void {
        switch (self) {
            .Number => |n| try writer.print("{d}", .{n}),
            .Bool => |b| try writer.print("{}", .{b}),
        }
    }
};
