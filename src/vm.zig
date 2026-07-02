pub const VM = @This();

const std = @import("std");
const Chunk = @import("chunk.zig");
const err = @import("error.zig");
const val = @import("value.zig");
const mem = @import("memory.zig");
const builtin = @import("builtin.zig");
const Compiler = @import("compiler.zig");

const LoxValue = val.LoxValue;
const FRAMES_MAX: usize = 64;
const STACK_MAX: usize = 256 * FRAMES_MAX;
const CONST_SIZE: usize = 1;
const CONST_LONG_SIZE: usize = 3;

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
io: std.Io,
stack: []LoxValue,
stack_top: usize,
globals: std.StringHashMap(LoxValue),
frames: []CallFrame,
frame_count: usize,

heap: mem.Heap,
open_upvalues: ?*val.Upvalue,

pub const CallFrame = struct {
    closure: *val.Closure,
    slots_offset: usize, // points to vm's value's stack first value it can use
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io) !VM {
    const stack = try gpa.alloc(LoxValue, STACK_MAX);
    @memset(stack, .Nil);

    const frames = try gpa.alloc(CallFrame, FRAMES_MAX);
    @memset(frames, CallFrame{ .closure = undefined, .slots_offset = 0 });

    var vm = VM{
        .allocator = gpa,
        .io = io,
        .writer = writer,
        .stack = stack,
        .frames = frames,
        .frame_count = 0,
        .globals = std.StringHashMap(LoxValue).init(gpa),
        .stack_top = 0,
        .heap = mem.Heap.init(gpa),
        .open_upvalues = null,
    };
    errdefer {
        gpa.free(stack);
        gpa.free(frames);
    }
    try vm.defineNative("clock", builtin.clock);
    try vm.defineNative("max", builtin.max);
    try vm.defineNative("min", builtin.min);
    try vm.defineNative("sqrt", builtin.sqrt);
    return vm;
}

pub fn deinit(self: *VM) void {
    // Don't free functions/closures from globals - heap.deinit() will do it
    self.globals.deinit();

    self.heap.deinit();
    self.allocator.free(self.stack);
    self.allocator.free(self.frames);
}

pub fn interpret(self: *VM, source: []const u8, print_code: bool) !void {
    return self.interpretWithFilename(source, print_code, "<stdin>");
}

pub fn interpretWithFilename(self: *VM, source: []const u8, print_code: bool, filename: []const u8) !void {
    var compiler = Compiler.init(self.allocator, self.writer, print_code, filename);
    defer compiler.deinit();

    const func = compiler.compile(source) catch |compile_err| {
        return compile_err;
    };

    if (compiler.parser.hadError) {
        // Function will be freed in compiler.deinit()
        return err.Error.CompileError;
    }

    // func is already on heap, add to heap tracking
    try self.trackFunctionRecursively(func);

    // Cancel function free in compiler.deinit() - set to null
    compiler.current.function = null;

    // Allocate closure on heap
    const closure_ptr = try self.allocator.create(val.Closure);
    closure_ptr.* = val.Closure.init(self.allocator, func);
    try self.heap.trackObject(.{ .closure = closure_ptr }, @sizeOf(val.Closure));

    try self.push(.{ .Closure = closure_ptr });
    _ = try self.call(closure_ptr, 0);
    _ = try self.pop();
}

fn trackFunctionRecursively(self: *VM, func: *val.Function) !void {
    try self.heap.trackObject(.{ .function = func }, @sizeOf(val.Function));
    for (func.chunk.constants.items) |c| {
        if (c == .Function) try self.trackFunctionRecursively(c.Function);
    }
}

fn defineNative(self: *VM, name: []const u8, function: val.NativeFn) !void {
    try self.globals.put(name, .{ .Native = function });
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

fn call(self: *VM, closure: *val.Closure, arg_count: usize) anyerror!bool {
    self.frames[self.frame_count] = CallFrame{
        .closure = closure,
        .slots_offset = self.stack_top - arg_count,
    };
    self.frame_count += 1;
    try self.run();
    return true;
}

fn callValue(self: *VM, value: LoxValue, arg_count: usize) anyerror!bool {
    return switch (value) {
        .Closure => |f| try self.call(f, arg_count),
        .Native => |native_fn| {
            const args_start = self.stack_top - arg_count;
            const result = try native_fn(self.io, self.stack[args_start..self.stack_top]);
            self.stack_top -= arg_count + 1;
            try self.push(result);
            return true;
        },
        else => {
            std.log.err("Can only call functions and classes.", .{});
            return err.Error.RuntimeError;
        },
    };
}

fn captureUpvalue(self: *VM, location: usize) !*val.Upvalue {
    const slot = &self.stack[location];

    var prev: ?*val.Upvalue = null;
    var current = self.open_upvalues;
    while (current) |upvalue| {
        if (upvalue.location == slot) {
            return upvalue;
        } else if (@intFromPtr(upvalue.location) < @intFromPtr(slot)) {
            break;
        }
        prev = upvalue;
        current = upvalue.next;
    }

    const created = try self.allocator.create(val.Upvalue);
    created.* = .{
        .location = slot,
        .closed = .Nil,
        .next = null,
        .marked = false,
    };
    try self.heap.trackObject(.{ .upvalue = created }, @sizeOf(val.Upvalue));

    if (prev) |p| {
        created.next = p.next;
        p.next = created;
    } else {
        created.next = self.open_upvalues;
        self.open_upvalues = created;
    }

    return created;
}

fn closeUpvalues(self: *VM, last: usize) void {
    while (self.open_upvalues) |upvalue| {
        if (@intFromPtr(upvalue.location) >= last) {
            self.open_upvalues = upvalue.next;
            upvalue.close();
        } else {
            break;
        }
    }
}

fn frame(self: *VM) *CallFrame {
    return &self.frames[self.frame_count - 1];
}

fn chunk(self: *VM) *Chunk {
    return &self.frame().closure.function.chunk;
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
            .GetUpvalue => {
                const slot = self.chunk().readByte(ip);
                const upvalue = self.frame().closure.upvalues[slot];
                try self.push(upvalue.get());
                ip += 1;
            },
            .SetUpvalue => {
                const slot = self.chunk().readByte(ip);
                const value = try self.peek(0);
                self.frame().closure.upvalues[slot].set(value);
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
                            const heap_str = try mem.HeapString.init(self.allocator, result);
                            try self.heap.trackObject(.{ .string = heap_str }, @sizeOf(mem.HeapString) + result.len);
                            try self.push(.{ .String = heap_str.data });

                            // Check if we need to run GC
                            if (self.heap.shouldCollect()) {
                                try self.collectGarbage();
                            }
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
                const bn = try b.tryNumber();
                if (bn == 0) {
                    try self.push(.NaN);
                } else {
                    const an = try a.tryNumber();
                    try self.push(.{ .Number = an / bn });
                }
            },
            .Print => {
                const value = try self.pop();
                try value.print(self.writer);
                try self.println();
            },
            .Pop => {
                _ = try self.pop();
            },
            .Closure => {
                const function = self.chunk().readConstant(ip).Function;
                ip += CONST_SIZE;

                const closure_ptr = try self.allocator.create(val.Closure);
                closure_ptr.* = val.Closure.init(self.allocator, function);
                try self.heap.trackObject(.{ .closure = closure_ptr }, @sizeOf(val.Closure));

                const current_frame = self.frame();
                const slots_offset = current_frame.slots_offset;
                for (0..function.upvalue_count) |_| {
                    const is_local = self.chunk().readByte(ip);
                    const index = self.chunk().readByte(ip + 1);
                    ip += 2;
                    const upvalue: *val.Upvalue = if (is_local == 1)
                        try self.captureUpvalue(slots_offset + index)
                    else
                        current_frame.closure.upvalues[index];
                    closure_ptr.upvalues[closure_ptr.upvalue_count] = upvalue;
                    closure_ptr.upvalue_count += 1;
                }
                try self.push(.{ .Closure = closure_ptr });
            },
            .Call => {
                const arg_count = self.chunk().readByte(ip);
                ip += 1;
                const value = try self.peek(arg_count);
                if (!try self.callValue(value, arg_count)) {
                    return err.Error.RuntimeError;
                }
                // After call returns, frame_count is already decremented by Return
                // Continue with next instruction
            },
            .Return => {
                const result = if (self.stack_top > 0) try self.pop() else .Nil;

                const slots_offset = self.frame().slots_offset;
                self.closeUpvalues(@intFromPtr(&self.stack[slots_offset]));

                self.frame_count -= 1;
                if (self.frame_count == 0) {
                    return;
                }
                const caller_slots_offset = self.frames[self.frame_count].slots_offset;
                self.stack_top = caller_slots_offset - 1;
                try self.push(result);
                break;
            },
            .CloseUpvalue => {
                self.closeUpvalues(@intFromPtr(&self.stack[self.stack_top - 1]));
                _ = try self.pop();
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
        var globals_list = std.ArrayList(u8).empty;
        defer globals_list.deinit(self.allocator);

        var iterator = self.globals.iterator();
        while (iterator.next()) |e| {
            try globals_list.appendSlice(self.allocator, "\n - ");
            try globals_list.appendSlice(self.allocator, e.key_ptr.*);
        }

        std.log.err("Unknown global: {s}. Current globals are:{s}", .{ name, globals_list.items });
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

// ============================================
// Garbage Collection
// ============================================

fn markValue(self: *VM, value: LoxValue) void {
    switch (value) {
        .Closure => |c| {
            if (!c.marked) {
                c.marked = true;
                // Рекурсивно помечаем upvalues
                for (c.upvalues[0..c.upvalue_count]) |up| {
                    self.markUpvalue(up);
                }
            }
        },
        .Function => |f| {
            if (!f.marked) {
                f.marked = true;
                // Mark constants from chunk (may contain Function/Closure)
                for (f.chunk.constants.items) |const_val| {
                    self.markValue(const_val);
                }
            }
        },
        .String => {},
        else => {},
    }
}

fn markUpvalue(self: *VM, upvalue: *val.Upvalue) void {
    if (!upvalue.marked) {
        upvalue.marked = true;
        // If upvalue is closed, mark the value inside
        if (upvalue.isClosed()) {
            self.markValue(upvalue.closed);
        }
    }
}

fn markRoots(self: *VM) void {
    // 1. Stack
    for (self.stack[0..self.stack_top]) |slot| {
        self.markValue(slot);
    }

    // 2. Globals
    var it = self.globals.iterator();
    while (it.next()) |entry| {
        self.markValue(entry.value_ptr.*);
    }

    // 3. Call frames
    for (self.frames[0..self.frame_count]) |f| {
        self.markValue(.{ .Closure = f.closure });
    }

    // 4. Open upvalues
    var upvalue = self.open_upvalues;
    while (upvalue) |up| {
        self.markUpvalue(up);
        upvalue = up.next;
    }
}

pub fn collectGarbage(self: *VM) !void {
    // Mark phase
    self.markRoots();
    // Sweep phase
    try self.heap.collectGarbage();
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

test "divide by zero" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 5 / 0;", false);

    // Assert
    try std.testing.expectEqualStrings("NaN\n", writer.written());
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

test "function call no arguments" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun sayHi() { print \"hi\"; } sayHi();", false);

    // Assert
    try std.testing.expectEqualStrings("hi\n", writer.written());
}

test "function call with arguments" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun add(a, b) { return a + b; } print add(3, 4);", false);

    // Assert
    try std.testing.expectEqualStrings("7\n", writer.written());
}

test "function call with multiple arguments" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun sum(a, b, c) { return a + b + c; } print sum(1, 2, 3);", false);

    // Assert
    try std.testing.expectEqualStrings("6\n", writer.written());
}

test "function return value" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun double(x) { return x * 2; } print double(5);", false);

    // Assert
    try std.testing.expectEqualStrings("10\n", writer.written());
}

test "function nested calls" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun inner() { return 5; } fun outer() { return inner() * 2; } print outer();", false);

    // Assert
    try std.testing.expectEqualStrings("10\n", writer.written());
}

test "function with early return" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun check(x) { if (x > 0) return 1; return -1; } print check(5); print check(-5);", false);

    // Assert
    try std.testing.expectEqualStrings("1\n-1\n", writer.written());
}

test "function without return statement" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun noReturn() { var x = 5; } print noReturn();", false);

    // Assert
    try std.testing.expectEqualStrings("nil\n", writer.written());
}

test "function recursion factorial" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun fact(n) { if (n <= 1) return 1; return n * fact(n - 1); } print fact(5);", false);

    // Assert
    try std.testing.expectEqualStrings("120\n", writer.written());
}

test "function recursion fibonacci" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun fib(n) { if (n <= 1) return n; return fib(n - 1) + fib(n - 2); } print fib(6);", false);

    // Assert
    try std.testing.expectEqualStrings("8\n", writer.written());
}

test "native function clock" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print clock() > 0;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "native function sqrt" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print sqrt(16);", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "native function sqrt of two" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print sqrt(2);", false);

    // Assert
    try std.testing.expectEqualStrings("1.4142135623730951\n", writer.written());
}

test "native function min" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print min(5, 3);", false);

    // Assert
    try std.testing.expectEqualStrings("3\n", writer.written());
}

test "native function min reversed" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print min(3, 5);", false);

    // Assert
    try std.testing.expectEqualStrings("3\n", writer.written());
}

test "native function min equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print min(4, 4);", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "native function max" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print max(5, 3);", false);

    // Assert
    try std.testing.expectEqualStrings("5\n", writer.written());
}

test "native function max reversed" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print max(3, 5);", false);

    // Assert
    try std.testing.expectEqualStrings("5\n", writer.written());
}

test "native function max equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print max(4, 4);", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "native functions composition" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print sqrt(max(9, 4));", false);

    // Assert
    try std.testing.expectEqualStrings("3\n", writer.written());
}

test "native functions nested min max" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print min(max(3, 5), 4);", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "function as argument" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun apply(f, x) { return f(x); } fun negate(x) { return -x; } print apply(negate, 42);", false);

    // Assert
    try std.testing.expectEqualStrings("-42\n", writer.written());
}

test "closures capture outer variable" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    const code =
        \\var x = "global";
        \\fun outer() {
        \\  var x = "outer";
        \\  fun inner() {
        \\    print x;
        \\  }
        \\  inner();
        \\}
        \\outer();
        \\
    ;

    // Act
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("outer\n", writer.written());
}

test "closures multiple instances with different captured values" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    const code =
        \\fun makeClosure(value) {
        \\  fun closure() {
        \\    print value;
        \\  }
        \\  return closure;
        \\}
        \\
        \\var doughnut = makeClosure("doughnut");
        \\var bagel = makeClosure("bagel");
        \\doughnut();
        \\bagel();
        \\
    ;

    // Act
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("doughnut\nbagel\n", writer.written());
}

test "closures mutate captured variable" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    const code =
        \\fun makeCounter() {
        \\  var count = 0;
        \\  fun increment() {
        \\    count = count + 1;
        \\    return count;
        \\  }
        \\  return increment;
        \\}
        \\
        \\var counter = makeCounter();
        \\print counter();
        \\print counter();
        \\print counter();
        \\
    ;

    try virtualMachine.interpret(code, false);
    try std.testing.expectEqualStrings("1\n2\n3\n", writer.written());
}

test "closures survive after enclosing function returns" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    const code =
        \\fun makeAdder(n) {
        \\  fun adder(x) {
        \\    return x + n;
        \\  }
        \\  return adder;
        \\}
        \\
        \\var add5 = makeAdder(5);
        \\var add10 = makeAdder(10);
        \\print add5(3);
        \\print add10(3);
        \\
    ;

    try virtualMachine.interpret(code, false);
    try std.testing.expectEqualStrings("8\n13\n", writer.written());
}

test "nested closures share mutable outer variable" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    const code =
        \\fun outer() {
        \\  var x = 1;
        \\  fun middle() {
        \\    fun inner() {
        \\      x = x + 1;
        \\      print x;
        \\    }
        \\    inner();
        \\    inner();
        \\  }
        \\  middle();
        \\}
        \\outer();
        \\
    ;

    try virtualMachine.interpret(code, false);
    try std.testing.expectEqualStrings("2\n3\n", writer.written());
}
