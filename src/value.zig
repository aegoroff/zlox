const std = @import("std");
const err = @import("error.zig");

const ERROR_MARGIN = 0.000001;

pub const LoxValue = union(enum) {
    Nil,
    Number: f64,
    Bool: bool,

    pub fn print(self: LoxValue, writer: *std.Io.Writer) !void {
        switch (self) {
            .Nil => try writer.print("nil", .{}),
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

    pub fn isFalsee(self: LoxValue) bool {
        return switch (self) {
            .Bool => |n| !n,
            .Nil => true,
            else => false,
        };
    }

    pub fn equal(self: LoxValue, other: LoxValue) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);

        if (self_tag != other_tag) {
            const is_self_bool_like = (self_tag == .Bool or self_tag == .Nil);
            const is_other_bool_like = (other_tag == .Bool or other_tag == .Nil);

            if (is_self_bool_like and is_other_bool_like) {
                return self.asBool() == other.asBool();
            }
            return false;
        }

        return switch (self) {
            .Number => |l| @abs(l - other.Number) < ERROR_MARGIN,
            //.String => |l| std.mem.eql(u8, l, other.String),
            .Bool => |l| l == other.Bool,
            .Nil => true,
        };
    }

    pub fn less(self: LoxValue, other: LoxValue) err.Error!bool {
        return switch (self) {
            .Number => |l| switch (other) {
                .Number => |r| l < r,
                else => err.Error.RuntimeError,
            },
            // .String => |l| switch (other) {
            //     .String => |r| std.mem.lessThan(u8, l, r),
            //     else => err.Error.RuntimeError,
            // },
            .Bool => |l| switch (other) {
                .Bool => |r| !l and r,
                else => err.Error.RuntimeError,
            },
            .Nil => err.Error.RuntimeError,
        };
    }

    fn asBool(self: LoxValue) bool {
        return switch (self) {
            .Bool => |b| b,
            .Nil => false,
            else => false,
        };
    }
};
