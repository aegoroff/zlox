pub const VM = @This();

const std = @import("std");
const Chunk = @import("chunk.zig");
const err = @import("error.zig");
const val = @import("value.zig");
const Compiler = @import("compiler.zig");

const LoxValue = val.LoxValue;
const STACK_MAX: usize = 256;

allocator: std.mem.Allocator,
chunk: *Chunk,
writer: *std.Io.Writer,
stack: [STACK_MAX]LoxValue,
stack_top: usize,

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) VM {
    return VM{
        .allocator = gpa,
        .chunk = undefined,
        .writer = writer,
        .stack = undefined,
        .stack_top = 0,
    };
}

pub fn deinit(_: *VM) void {}

pub fn interpret(self: *VM, source: []const u8) !void {
    var chunk = Chunk.init(self.allocator);
    defer chunk.deinit();
    var compile = Compiler.init(self.allocator);
    try compile.compile(source, &chunk);
}

fn push(self: *VM, value: LoxValue) err.Error!void {
    if (self.stack_top == STACK_MAX) {
        return err.Error.RuntimeError;
    }
    self.stack[self.stack_top] = value;
    self.stack_top += 1;
}

fn pop(self: *VM) err.Error!LoxValue {
    if (self.stack_top == 0) {
        return err.Error.RuntimeError;
    }
    const result = self.stack[self.stack_top - 1];
    self.stack_top -= 1;
    return result;
}

fn println(self: *VM) !void {
    try self.writer.print("\n", .{});
}

pub fn run(self: *VM) !void {
    var ip: usize = 0;
    while (ip < self.chunk.code.items.len) {
        const opcode = self.chunk.readOpcode(ip);
        ip += 1;
        switch (opcode) {
            .Constant => {
                const value = self.chunk.readConstant(ip);
                ip += 1;
                try self.push(value);
            },
            .ConstantLong => {
                const value = self.chunk.readConstantLong(ip);
                ip += 3;
                try self.push(value);
            },
            .Negate => {
                const value = try self.pop();
                try self.push(.{ .Number = -try value.tryNumber() });
            },
            .Add => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(.{ .Number = try a.tryNumber() + try b.tryNumber() });
            },
            .Subtract => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(.{ .Number = try a.tryNumber() - try b.tryNumber() });
            },
            .Multiply => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(.{ .Number = try a.tryNumber() * try b.tryNumber() });
            },
            .Divide => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(.{ .Number = try a.tryNumber() / try b.tryNumber() });
            },
            .Return => {
                const value = try self.pop();
                try value.print(self.writer);
                try self.println();
                break;
            },
            else => {},
        }
    }
}
