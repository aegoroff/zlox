pub const VM = @This();

const std = @import("std");
const Chunk = @import("chunk.zig");
const err = @import("error.zig");
const val = @import("value.zig");
const Compiler = @import("compiler.zig");

const LoxValue = val.LoxValue;
const STACK_MAX: usize = 256;
const CONST_SIZE: usize = 1;
const CONST_LONG_SIZE: usize = 3;

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
stack: [STACK_MAX]LoxValue,
globals: std.StringHashMap(LoxValue),
stack_top: usize,

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) VM {
    return VM{
        .allocator = gpa,
        .writer = writer,
        .stack = undefined,
        .globals = std.StringHashMap(LoxValue).init(gpa),
        .stack_top = 0,
    };
}

pub fn deinit(self: *VM) void {
    self.globals.deinit();
}

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
            .JumpIfFalse => {
                const offset = chunk.readShort(ip);
                const v = try self.peek(0);
                ip += 2; // offset is two bytes
                if (v.isFalsee()) {
                    ip += offset;
                }
            },
            .Jump => {
                const offset = chunk.readShort(ip);
                ip += 2; // offset is two bytes
                ip += offset;
            },
            .Constant => {
                const value = chunk.readConstant(ip);
                try self.push(value);
                ip += CONST_SIZE;
            },
            .ConstantLong => {
                const value = chunk.readConstantLong(ip);
                try self.push(value);
                ip += CONST_LONG_SIZE;
            },
            .DefineGlobal => {
                try self.defineGlobal(chunk, ip);
                ip += CONST_SIZE;
            },
            .DefineGlobalLong => {
                try self.defineGlobal(chunk, ip);
                ip += CONST_LONG_SIZE;
            },
            .GetGlobal => {
                try self.getGlobal(chunk, ip, CONST_SIZE);
                ip += CONST_SIZE;
            },
            .GetGlobalLong => {
                try self.getGlobal(chunk, ip, CONST_LONG_SIZE);
                ip += CONST_LONG_SIZE;
            },
            .SetGlobal => {
                try self.setGlobal(chunk, ip, CONST_SIZE);
                ip += CONST_SIZE;
            },
            .SetGlobalLong => {
                try self.setGlobal(chunk, ip, CONST_LONG_SIZE);
                ip += CONST_LONG_SIZE;
            },
            .GetLocal => {
                const slot = chunk.readByte(ip);
                try self.push(self.stack[slot]);
                ip += 1;
            },
            .SetLocal => {
                const slot = chunk.readByte(ip);
                self.stack[slot] = try self.peek(slot);
                ip += 1;
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
                const lt = try a.less(b);
                const eq = a.equal(b);
                try self.push(.{ .Bool = !lt and !eq });
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

fn defineGlobal(self: *VM, chunk: *Chunk, ip: usize) !void {
    const name_value = chunk.readConstant(ip);
    const name = try name_value.tryString();
    const value = try self.peek(0);
    try self.globals.put(name, value);
    _ = try self.pop();
}

fn getGlobal(self: *VM, chunk: *Chunk, ip: usize, constant_size: usize) !void {
    const name_value = switch (constant_size) {
        CONST_SIZE => chunk.readConstant(ip),
        CONST_LONG_SIZE => chunk.readConstantLong(ip),
        else => return err.Error.CompileError,
    };
    const name = try name_value.tryString();
    if (self.globals.get(name)) |constant_value| {
        try self.push(constant_value);
    } else {
        return err.Error.RuntimeError;
    }
}

fn setGlobal(self: *VM, chunk: *Chunk, ip: usize, constant_size: usize) !void {
    const name_value = switch (constant_size) {
        CONST_SIZE => chunk.readConstant(ip),
        CONST_LONG_SIZE => chunk.readConstantLong(ip),
        else => return err.Error.CompileError,
    };
    const name = try name_value.tryString();
    if (!self.globals.contains(name)) {
        return err.Error.RuntimeError;
    }
    const new_value = try self.peek(0);
    try self.globals.put(name, new_value);
}

test "Simple add expression" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = init(std.testing.allocator, &writer.writer);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1 + 2;", false);

    // Assert
    try std.testing.expectEqualStrings("3\n", writer.written());
}

test "String concatentation" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = init(std.testing.allocator, &writer.writer);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"a\" + \"b\") + \"c\";", false);

    // Assert
    try std.testing.expectEqualStrings("abc\n", writer.written());
}
