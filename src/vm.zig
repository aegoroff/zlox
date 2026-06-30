pub const VM = @This();

const std = @import("std");
const Chunk = @import("chunk.zig");
const err = @import("error.zig");
const val = @import("value.zig");
const Compiler = @import("compiler.zig");

const LoxValue = val.LoxValue;
const FRAMES_MAX: usize = 64;
const STACK_MAX: usize = 256 * FRAMES_MAX;
const CONST_SIZE: usize = 1;
const CONST_LONG_SIZE: usize = 3;

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
io: std.Io,
stack: [STACK_MAX]LoxValue,
stack_top: usize,
globals: std.StringHashMap(LoxValue),
frames: [FRAMES_MAX]CallFrame,
frame_count: usize,

allocated_strings: std.ArrayList([]u8),

pub const CallFrame = struct {
    function: val.Function,
    slots_offset: usize, // points to vm's value's stack first value it can use
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io) !VM {
    var vm = VM{
        .allocator = gpa,
        .io = io,
        .writer = writer,
        .stack = undefined,
        .frames = undefined,
        .frame_count = 0,
        .globals = std.StringHashMap(LoxValue).init(gpa),
        .stack_top = 0,
        .allocated_strings = .empty,
    };
    try vm.defineNative("clock", clockNative);
    return vm;
}

pub fn deinit(self: *VM) void {
    self.globals.deinit();
    // Free all allocated strings from concatenation operations
    for (self.allocated_strings.items) |s| {
        self.allocator.free(s);
    }
    self.allocated_strings.deinit(self.allocator);
}

pub fn interpret(self: *VM, source: []const u8, print_code: bool) !void {
    var compiler = Compiler.init(self.allocator, self.writer, print_code);
    const func = compiler.compile(source) catch |compile_err| {
        compiler.deinit();
        return compile_err;
    };
    if (compiler.parser.hadError) {
        compiler.deinit();
        return err.Error.CompileError;
    }
    compiler.deinit();

    self.frames[self.frame_count] = CallFrame{
        .function = func,
        .slots_offset = self.stack_top,
    };
    self.frame_count += 1;
    errdefer {
        self.frame_count -= 1;
        self.frames[self.frame_count].function.deinit();
    }
    try self.run();

    // Clean up the frame after successful execution
    // Return opcode already decremented frame_count
    self.frames[self.frame_count].function.deinit();
}

fn push(self: *VM, value: LoxValue) err.Error!void {
    if (self.stack_top == STACK_MAX) {
        std.log.err("Stack overflow. Current stack top: {d}", .{self.stack_top});
        return err.Error.RuntimeError;
    }
    self.stack[self.stack_top] = value;
    self.stack_top += 1;
}

fn pop(self: *VM) err.Error!LoxValue {
    if (self.stack_top == 0) {
        std.log.err("Stack underflow. Stack is empty", .{});
        return err.Error.RuntimeError;
    }
    const result = self.stack[self.stack_top - 1];
    self.stack_top -= 1;
    return result;
}

fn peek(self: *VM, distance: usize) err.Error!LoxValue {
    if (self.stack_top < distance + 1) {
        std.log.err("Stack peek failed. Stack size is: {d} but requested distance is: {d}", .{ self.stack_top, distance });
        return err.Error.RuntimeError;
    }
    return self.stack[self.stack_top - 1 - distance];
}

fn call(self: *VM, function: val.Function, arg_count: usize) anyerror!bool {
    self.frames[self.frame_count] = CallFrame{
        .function = function,
        .slots_offset = self.stack_top - arg_count,
    };
    self.frame_count += 1;
    try self.run();
    return true;
}

fn callValue(self: *VM, value: LoxValue, arg_count: usize) anyerror!bool {
    return switch (value) {
        .Function => |f| try self.call(f, arg_count),
        else => {
            std.log.err("Can only call functions and classes.", .{});
            return err.Error.RuntimeError;
        },
    };
}

fn frame(self: *VM) *CallFrame {
    return &self.frames[self.frame_count - 1];
}

fn chunk(self: *VM) *Chunk {
    return &self.frame().function.chunk;
}

fn println(self: *VM) !void {
    try self.writer.print("\n", .{});
}

pub fn run(self: *VM) !void {
    var ip: usize = 0;
    while (ip < self.chunk().code.items.len) {
        const opcode = self.chunk().readOpcode(ip);
        ip += 1;
        switch (opcode) {
            .JumpIfFalse => {
                const offset = self.chunk().readShort(ip);
                const v = try self.peek(0);
                ip += 2; // offset is two bytes
                if (v.isFalsee()) {
                    ip += offset;
                }
            },
            .Jump => {
                const offset = self.chunk().readShort(ip);
                ip += 2; // offset is two bytes
                ip += offset;
            },
            .Loop => {
                const offset = self.chunk().readShort(ip);
                ip += 2; // offset is two bytes
                ip -= offset;
            },
            .Constant => {
                const value = self.chunk().readConstant(ip);
                try self.push(value);
                ip += CONST_SIZE;
            },
            .ConstantLong => {
                const value = self.chunk().readConstantLong(ip);
                try self.push(value);
                ip += CONST_LONG_SIZE;
            },
            .DefineGlobal => {
                try self.defineGlobal(ip);
                ip += CONST_SIZE;
            },
            .DefineGlobalLong => {
                try self.defineGlobal(ip);
                ip += CONST_LONG_SIZE;
            },
            .GetGlobal => {
                try self.getGlobal(ip, CONST_SIZE);
                ip += CONST_SIZE;
            },
            .GetGlobalLong => {
                try self.getGlobal(ip, CONST_LONG_SIZE);
                ip += CONST_LONG_SIZE;
            },
            .SetGlobal => {
                try self.setGlobal(ip, CONST_SIZE);
                ip += CONST_SIZE;
            },
            .SetGlobalLong => {
                try self.setGlobal(ip, CONST_LONG_SIZE);
                ip += CONST_LONG_SIZE;
            },
            .GetLocal => {
                const slots_offset = self.frame().slots_offset;
                const frame_offset = self.chunk().readByte(ip);
                try self.push(self.stack[slots_offset + frame_offset]);
                ip += 1;
            },
            .GetLocalLong => {
                const slots_offset = self.frame().slots_offset;
                const frame_offset = self.chunk().readThreeBytes(ip);
                try self.push(self.stack[slots_offset + frame_offset]);
                ip += CONST_LONG_SIZE;
            },
            .SetLocal => {
                const slots_offset = self.frame().slots_offset;
                const frame_offset = self.chunk().readByte(ip);
                self.stack[slots_offset + frame_offset] = try self.peek(0);
                ip += 1;
            },
            .SetLocalLong => {
                const slots_offset = self.frame().slots_offset;
                const frame_offset = self.chunk().readThreeBytes(ip);
                self.stack[slots_offset + frame_offset] = try self.peek(0);
                ip += CONST_LONG_SIZE;
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
                            try self.allocated_strings.append(self.allocator, result);
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
            .Pop => {
                _ = try self.pop();
            },
            .Call => {
                const arg_count = self.chunk().readByte(ip);
                const value = try self.peek(arg_count);
                if (!try self.callValue(value, arg_count)) {
                    return err.Error.RuntimeError;
                }
                // After call returns, frame_count is already decremented by call
                // Continue with next instruction
            },
            .Return => {
                self.frame_count -= 1;
                if (self.frame_count > 0) {
                    // Pop the return value if there is one, otherwise push nil
                    if (self.stack_top > self.frame().slots_offset) {
                        const value = try self.pop();
                        try self.push(value);
                    } else {
                        try self.push(.Nil);
                    }
                }
                break;
            },
            else => {},
        }
    }
}

fn defineGlobal(self: *VM, ip: usize) !void {
    const name_value = self.chunk().readConstant(ip);
    const name = try name_value.tryString();
    const value = try self.peek(0);
    try self.globals.put(name, value);
    _ = try self.pop();
}

fn getGlobal(self: *VM, ip: usize, constant_size: usize) !void {
    const name_value = switch (constant_size) {
        CONST_SIZE => self.chunk().readConstant(ip),
        CONST_LONG_SIZE => self.chunk().readConstantLong(ip),
        else => return err.Error.CompileError,
    };
    const name = try name_value.tryString();
    if (self.globals.get(name)) |constant_value| {
        try self.push(constant_value);
    } else {
        std.log.err("Unknown global: {s}. Current globals are:", .{name});
        var iterator = self.globals.iterator();
        while (iterator.next()) |e| {
            std.log.err(" - {s}", .{e.key_ptr.*});
        }

        return err.Error.RuntimeError;
    }
}

fn setGlobal(self: *VM, ip: usize, constant_size: usize) !void {
    const name_value = switch (constant_size) {
        CONST_SIZE => self.chunk().readConstant(ip),
        CONST_LONG_SIZE => self.chunk().readConstantLong(ip),
        else => return err.Error.CompileError,
    };
    const name = try name_value.tryString();
    if (!self.globals.contains(name)) {
        return err.Error.RuntimeError;
    }
    const new_value = try self.peek(0);
    try self.globals.put(name, new_value);
}

fn clockNative(io: std.Io, args: []const LoxValue) LoxValue {
    _ = args;
    const ts = std.Io.Clock.real.now(io);
    return .{ .Number = @floatFromInt(ts.toSeconds()) };
}

fn defineNative(self: *VM, name: []const u8, function: val.NativeFn) !void {
    try self.globals.put(name, .{ .Native = function });
}

test "Simple add expression" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
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
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"a\" + \"b\") + \"c\";", false);

    // Assert
    try std.testing.expectEqualStrings("abc\n", writer.written());
}

test "string equal false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"a\" == \"b\");", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "string not equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"a\" != \"c\");", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "string equal true" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"ab\" == \"ab\");", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "string greater false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"aa\" > \"bb\");", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "string greater true" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"bb\" > \"aa\");", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "string greater or equal true" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"bba\" >= \"aaa\");", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "string less or equal false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"bba\" <= \"aaa\");", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "number equal false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1 == 2;", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "number equal true" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 2 == 2;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "number greater or equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 3 >= 3;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "number greater or equal two" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 3 >= 2;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "number less or equal false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 3 <= 1;", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "expression less or equal false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (3 - 1) * 200 <= 1;", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "comparison with equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 3 > 1 == true;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "number less or equal equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 20 <= 20;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "number less or equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 40 <= 50;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "not nil" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print !nil;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "not number" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print !1;", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "not string" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print !\"s\";", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "two ands + or" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 40 <= 50 and 1 > 2 or 2 < 3;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "three ands" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 40 <= 50 and 1 < 2 and 2 < 3;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "decrement prefix" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print --1;", false);

    // Assert
    try std.testing.expectEqualStrings("1\n", writer.written());
}

test "subtract same numbers" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1 - 1;", false);

    // Assert
    try std.testing.expectEqualStrings("0\n", writer.written());
}

test "subtract negative result" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1 - 2;", false);

    // Assert
    try std.testing.expectEqualStrings("-1\n", writer.written());
}

test "subtract positive result" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 2 - 1;", false);

    // Assert
    try std.testing.expectEqualStrings("1\n", writer.written());
}

test "add numbers" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 2 + 3;", false);

    // Assert
    try std.testing.expectEqualStrings("5\n", writer.written());
}

test "add and subtract" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 2 + 3 - 1;", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "add and divide" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 3 + 3 / 3;", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "parentheses add and divide" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (3 + 3) / 3;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "divide numbers" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 4 / 2;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "divide by one" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 4 / 1;", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "divide by negative" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 5 / -1;", false);

    // Assert
    try std.testing.expectEqualStrings("-5\n", writer.written());
}

test "nested expression one" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (5 - (3-1)) + -1;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "nested expression two" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (5 - (3-1)) * -1;", false);

    // Assert
    try std.testing.expectEqualStrings("-3\n", writer.written());
}

test "nested expression three" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print ((5 - (3-1)) * -2) / 4;", false);

    // Assert
    try std.testing.expectEqualStrings("-1.5\n", writer.written());
}

test "nested expression four" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print ((5 - (3-1) + 3) * -2) / 4;", false);

    // Assert
    try std.testing.expectEqualStrings("-3\n", writer.written());
}

test "variables assignment and print" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = 1; var y = x + 1; print x; print y;", false);

    // Assert
    try std.testing.expectEqualStrings("1\n2\n", writer.written());
}

test "multiple prints" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1; print 2;", false);

    // Assert
    try std.testing.expectEqualStrings("1\n2\n", writer.written());
}

test "print with block" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1; { print 3; }", false);

    // Assert
    try std.testing.expectEqualStrings("1\n3\n", writer.written());
}

test "block scope variable" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var y = 1; { var x = 2; print x; } print y;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n1\n", writer.written());
}

test "block scope shadow" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = 1; { var x = 2; print x; }", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "nested blocks" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = 1; { var x = 2; print x; { var x = 3; print x; } } print x;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n3\n1\n", writer.written());
}

test "if positive" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = 1; if (x > 0) { print x; }", false);

    // Assert
    try std.testing.expectEqualStrings("1\n", writer.written());
}

test "if negative" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = -1; if (x > 0) { print x; } print 2;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "if else positive" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = 1; if (x > 0) { print x; } else { print 2; }", false);

    // Assert
    try std.testing.expectEqualStrings("1\n", writer.written());
}

test "if else negative" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = -1; if (x > 0) { print x; } else { print 2; }", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "while test" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var i = 0; while (i < 10) i = i + 1; print i;", false);

    // Assert
    try std.testing.expectEqualStrings("10\n", writer.written());
}

test "for test" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("for(var i = 0; i < 3; i = i + 1) print i;", false);

    // Assert
    try std.testing.expectEqualStrings("0\n1\n2\n", writer.written());
}

test "for test without initializer" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var i = 0; for(; i < 3; i = i + 1) print i;", false);

    // Assert
    try std.testing.expectEqualStrings("0\n1\n2\n", writer.written());
}
