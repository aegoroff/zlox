const std = @import("std");
const err = @import("error.zig");
const Chunk = @import("chunk.zig");

const ERROR_MARGIN = 0.000001;

pub const NativeFn = *const fn (io: std.Io, args: []const LoxValue) err.Error!LoxValue;

pub const LoxValue = union(enum) {
    Nil,
    Number: f64,
    Bool: bool,
    String: *HeapString,
    Function: *Function,
    Closure: *Closure,
    Class: *Class,
    Instance: *Instance,
    Native: NativeFn,
    NaN,

    pub fn print(self: LoxValue, writer: *std.Io.Writer) !void {
        switch (self) {
            .Nil => try writer.print("nil", .{}),
            .Number => |n| try writer.print("{d}", .{n}),
            .Bool => |b| try writer.print("{}", .{b}),
            .String => |s| try writer.print("{s}", .{s.data}),
            .Function => |f| try writer.print("<{s}>", .{f.name orelse "script"}),
            .Class => |f| try writer.print("{s}", .{f.name}),
            .Instance => |f| try writer.print("{s} instance", .{f.klass.name}),
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
            .String => |s| s.data,
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
            .String => |l| std.mem.eql(u8, l.data, other.String.data),
            .Bool => |l| l == other.Bool,
            .Nil => true,
            .Function => false,
            .Closure => false,
            .Class => false,
            .Instance => false,
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
                .String => |r| std.mem.lessThan(u8, l.data, r.data),
                else => err.Error.CompileError,
            },
            .Bool => |l| switch (other) {
                .Bool => |r| !l and r,
                else => err.Error.CompileError,
            },
            .Nil => err.Error.CompileError,
            .Function => err.Error.CompileError,
            .Closure => err.Error.CompileError,
            .Class => err.Error.CompileError,
            .Instance => err.Error.CompileError,
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

pub const HeapString = struct {
    marked: bool = false,
    data: []const u8,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !*HeapString {
        const self = try allocator.create(HeapString);
        self.* = .{ .marked = false, .data = bytes };
        return self;
    }
};

pub const Upvalue = struct {
    location: *LoxValue,
    closed: LoxValue = .Nil,
    next: ?*Upvalue = null,
    marked: bool = false,

    pub fn get(self: *const Upvalue) LoxValue {
        return self.location.*;
    }

    pub fn set(self: *Upvalue, val: LoxValue) void {
        self.location.* = val;
    }

    pub fn close(self: *Upvalue) void {
        self.closed = self.location.*;
        self.location = &self.closed;
    }

    pub fn isClosed(self: *const Upvalue) bool {
        return self.location == &self.closed;
    }
};

pub const Function = struct {
    arity: usize,
    chunk: Chunk,
    name: ?[]const u8,
    upvalue_count: usize,
    marked: bool = false,

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

const UPVALUE_MAX: usize = 256;

pub const Closure = struct {
    function: *Function,
    upvalues: [UPVALUE_MAX]*Upvalue,
    upvalue_count: usize,
    marked: bool = false,

    pub fn init(function: *Function) Closure {
        return Closure{
            .function = function,
            .upvalues = [_]*Upvalue{undefined} ** UPVALUE_MAX,
            .upvalue_count = 0,
            .marked = false,
        };
    }
};

pub const Class = struct {
    name: []const u8,
    marked: bool = false,

    pub fn init(name: []const u8) Class {
        return Class{
            .name = name,
            .marked = false,
        };
    }
};

pub const Instance = struct {
    klass: *Class,
    fields: std.StringHashMap(LoxValue),
    marked: bool = false,

    pub fn init(gpa: std.mem.Allocator, klass: *Class) Instance {
        return Instance{
            .klass = klass,
            .fields = std.StringHashMap(LoxValue).init(gpa),
            .marked = false,
        };
    }
    pub fn deinit(self: *Instance) void {
        self.fields.deinit();
    }
};
