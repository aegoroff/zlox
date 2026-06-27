pub const VM = @This();

const std = @import("std");
const Chunk = @import("chunk.zig");
const err = @import("error.zig");
const val = @import("value.zig");
const Compiler = @import("compiler.zig");

const LoxValue = val.LoxValue;
const STACK_MAX: usize = 256;

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
stack: [STACK_MAX]LoxValue,
stack_top: usize,

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) VM {
    return VM{
        .allocator = gpa,
        .writer = writer,
        .stack = undefined,
        .stack_top = 0,
    };
}

pub fn deinit(_: *VM) void {}

pub fn interpret(self: *VM, source: []const u8, print_code: bool) !void {
    var chunk = Chunk.init(self.allocator);
    defer chunk.deinit();
    var compile = Compiler.init(self.allocator, self.writer, print_code);
    try compile.compile(source, &chunk);
    try self.run(&chunk);
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

fn peek(self: *VM, distance: usize) err.Error!LoxValue {
    if (self.stack_top < distance + 1) {
        return err.Error.RuntimeError;
    }
    return self.stack[self.stack_top - 1 - distance];
}

fn println(self: *VM) !void {
    try self.writer.print("\n", .{});
}

pub fn run(self: *VM, chunk: *Chunk) !void {
    var ip: usize = 0;
    while (ip < chunk.code.items.len) {
        const opcode = chunk.readOpcode(ip);
        ip += 1;
        switch (opcode) {
            .Constant => {
                const value = chunk.readConstant(ip);
                ip += 1;
                try self.push(value);
            },
            .ConstantLong => {
                const value = chunk.readConstantLong(ip);
                ip += 3;
                try self.push(value);
            },
            .Nil => {
                try self.push(.Nil);
            },
            .True => {
                try self.push(.{ .Bool = true });
            },
            .False => {
                try self.push(.{ .Bool = false });
            },
            .Equal => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(.{ .Bool = a.equal(b) });
            },
            .Less => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(.{ .Bool = try a.less(b) });
            },
            .Greater => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(.{ .Bool = a.equal(b) });
            },
            .Negate => {
                const value = try self.pop();
                try self.push(.{ .Number = -try value.tryNumber() });
            },
            .Not => {
                const value = try self.pop();
                try self.push(.{ .Bool = value.isFalsee() });
            },
            .Add => {
                const b = try self.pop();
                const a = try self.pop();

                switch (a) {
                    .Number => |an| switch (b) {
                        .Number => |bn| try self.push(.{ .Number = an + bn }),
                        else => return err.Error.RuntimeError,
                    },
                    .String => |as| switch (b) {
                        .String => |bs| {
                            const result = try std.mem.concat(self.allocator, u8, &[_][]const u8{ as, bs });
                            try self.push(.{ .String = result });
                        },
                        else => return err.Error.RuntimeError,
                    },
                    else => return err.Error.RuntimeError,
                }
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
            .Print => {
                const value = try self.pop();
                try value.print(self.writer);
                try self.println();
            },
            .Return => break,
            else => {},
        }
    }
}
