const std = @import("std");
const err = @import("error.zig");
const Chunk = @import("chunk.zig");

const ERROR_MARGIN = 0.000001;

pub const NativeFn = *const fn (io: std.Io, args: []const LoxValue) err.Error!LoxValue;

pub const LoxValue = union(enum) {
    Nil,
    Number: f64,
    Bool: bool,
    String: []const u8,
    Function: Function,
    Closure: Closure,
    Native: NativeFn,
    NaN,

    pub fn print(self: LoxValue, writer: *std.Io.Writer) !void {
        switch (self) {
            .Nil => try writer.print("nil", .{}),
            .Number => |n| try writer.print("{d}", .{n}),
            .Bool => |b| try writer.print("{}", .{b}),
            .String => |s| try writer.print("{s}", .{s}),
            .Function => |f| try writer.print("<{s}>", .{f.name orelse "script"}),
            .Closure => |cl| try writer.print("<fn {s}>", .{cl.function.name orelse "script"}),
            .Native => try writer.print("<native fn>", .{}),
            .NaN => try writer.print("NaN", .{}),
        }
    }

    pub fn tryNumber(self: LoxValue) err.Error!f64 {
        return switch (self) {
            .Number => |n| n,
            .NaN => std.math.nan(f64),
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
            .Closure => false,
            .Native => false,
            .NaN => true,
        };
    }

    pub fn less(self: LoxValue, other: LoxValue) err.Error!bool {
        return switch (self) {
            .Number => |l| switch (other) {
                .Number => |r| l < r,
                .NaN => false,
                else => err.Error.CompileError,
            },
            .NaN => switch (other) {
                .Number => false,
                .NaN => false,
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
            .Closure => err.Error.CompileError,
            .Native => err.Error.CompileError,
        };
    }

    fn asBool(self: LoxValue) bool {
        return switch (self) {
            .Bool => |b| b,
            .Nil => false,
            .NaN => false,
            else => false,
        };
    }
};

pub const Upvalue = struct {
    location: ?usize = null, // индекс в стеке, если upvalue ещё открыт
    value: LoxValue = .Nil, // значение, когда upvalue закрыт

    pub fn get(self: *const Upvalue, stack: []const LoxValue) LoxValue {
        if (self.location) |loc| {
            return stack[loc];
        } else {
            return self.value;
        }
    }

    pub fn set(self: *Upvalue, stack: []LoxValue, val: LoxValue) void {
        if (self.location) |loc| {
            stack[loc] = val;
        } else {
            self.value = val;
        }
    }
};

pub const Function = struct {
    arity: usize,
    chunk: Chunk,
    name: ?[]const u8,
    upvalue_count: usize,

    pub fn init(gpa: std.mem.Allocator, name: ?[]const u8) Function {
        return Function{
            .arity = 0,
            .chunk = Chunk.init(gpa),
            .name = name,
            .upvalue_count = 0,
        };
    }

    pub fn deinit(self: *Function) void {
        self.chunk.deinit();
    }
};

pub const Closure = struct {
    function: Function,
    upvalues: std.ArrayList(Upvalue),

    pub fn init(function: Function) Closure {
        return Closure{
            .function = function,
            .upvalues = .empty,
        };
    }
};
