const std = @import("std");
const err = @import("error.zig");
const Chunk = @import("chunk.zig");

const ERROR_MARGIN = 0.000001;

pub const LoxValue = union(enum) {
    Nil,
    Number: f64,
    Bool: bool,
    String: []const u8,
    Function: Function,

    pub fn print(self: LoxValue, writer: *std.Io.Writer) !void {
        switch (self) {
            .Nil => try writer.print("nil", .{}),
            .Number => |n| try writer.print("{d}", .{n}),
            .Bool => |b| try writer.print("{}", .{b}),
            .String => |s| try writer.print("{s}", .{s}),
            .Function => |f| try writer.print("<{s}>", .{f.name}),
        }
    }

    pub fn tryNumber(self: LoxValue) err.Error!f64 {
        return switch (self) {
            .Number => |n| n,
            else => return err.Error.RuntimeError,
        };
    }

    pub fn tryString(self: LoxValue) err.Error![]const u8 {
        return switch (self) {
            .String => |s| s,
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
            .String => |l| std.mem.eql(u8, l, other.String),
            .Bool => |l| l == other.Bool,
            .Nil => true,
            .Function => false,
        };
    }

    pub fn less(self: LoxValue, other: LoxValue) err.Error!bool {
        return switch (self) {
            .Number => |l| switch (other) {
                .Number => |r| l < r,
                else => err.Error.CompileError,
            },
            .String => |l| switch (other) {
                .String => |r| std.mem.lessThan(u8, l, r),
                else => err.Error.CompileError,
            },
            .Bool => |l| switch (other) {
                .Bool => |r| !l and r,
                else => err.Error.CompileError,
            },
            .Nil => err.Error.CompileError,
            .Function => err.Error.CompileError,
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

pub const Function = struct {
    arity: usize,
    chunk: Chunk,
    name: ?[]const u8,

    pub fn init(gpa: std.mem.Allocator, name: ?[]const u8) Function {
        return Function{
            .arity = 0,
            .chunk = Chunk.init(gpa),
            .name = name,
        };
    }

    pub fn deinit(self: *Function) void {
        self.chunk.deinit();
    }
};
