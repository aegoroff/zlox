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
compiler: ?Compiler,
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
        .compiler = null,
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
    if (self.compiler) |_| {
        self.compiler.?.deinit();
    }
    self.globals.deinit();
    self.heap.deinit();
    self.allocator.free(self.stack);
    self.allocator.free(self.frames);
}

pub fn interpret(self: *VM, source: []const u8, print_code: bool) !void {
    return self.interpretWithFilename(source, print_code, "<stdin>");
}

pub fn interpretWithFilename(self: *VM, source: []const u8, print_code: bool, filename: []const u8) !void {
    self.compiler = Compiler.init(self.allocator, self.writer, print_code, filename);

    const func = self.compiler.?.compile(source) catch |compile_err| {
        return compile_err;
    };

    if (self.compiler.?.parser.hadError) {
        return err.Error.CompileError;
    }

    try self.trackConstantsRecursively(func);
    self.compiler.?.current.function = null;

    const closure_ptr = try self.allocator.create(val.Closure);
    closure_ptr.* = val.Closure.init(func);
    try self.heap.trackObject(.{ .closure = closure_ptr }, @sizeOf(val.Closure));

    try self.push(.{ .Closure = closure_ptr });
    _ = try self.call(1, closure_ptr, 0);
    _ = try self.pop();
}

fn trackConstantsRecursively(self: *VM, func: *val.Function) !void {
    try self.heap.trackObject(.{ .function = func }, @sizeOf(val.Function));
    for (func.chunk.constants.items) |c| {
        switch (c) {
            .Function => |nested| try self.trackConstantsRecursively(nested),
            .String => |s| try self.heap.trackObject(.{ .string = s }, @sizeOf(mem.HeapString) + s.data.len),
            else => {},
        }
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

fn call(self: *VM, ip: usize, closure: *val.Closure, arg_count: usize) anyerror!bool {
    if (closure.function.arity != arg_count) {
        try self.errorAt(ip, "Expected {d} arguments but got {d}.", .{
            closure.function.arity,
            arg_count,
        });
        return err.Error.RuntimeError;
    }
    self.frames[self.frame_count] = CallFrame{
        .closure = closure,
        .slots_offset = self.stack_top - arg_count,
    };
    self.frame_count += 1;
    try self.run();
    return true;
}

fn callValue(self: *VM, ip: usize, value: LoxValue, arg_count: usize) anyerror!bool {
    return switch (value) {
        .Closure => |f| try self.call(ip, f, arg_count),
        .Class => |k| {
            const instance_ptr = try self.allocator.create(val.Instance);
            instance_ptr.* = val.Instance.init(self.allocator, k);
            try self.heap.trackObject(.{ .instance = instance_ptr }, instance_ptr.size());
            self.stack[self.stack_top - arg_count - 1] = .{ .Instance = instance_ptr };
            return true;
        },
        .BoundMethod => |b| self.call(ip, try b.method.tryClosure(), arg_count),
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

fn defineMethod(self: *VM, name: []const u8) !void {
    const method = try self.pop(); // Closure
    const klass = try (try self.peek(0)).tryClass(); // Class stays on stack
    try klass.methods.put(name, method);
}

fn frame(self: *VM) *CallFrame {
    return &self.frames[self.frame_count - 1];
}

fn chunk(self: *VM) *Chunk {
    return &self.frame().closure.function.chunk;
}

fn errorAt(self: *VM, ip: usize, comptime fmt: []const u8, args: anytype) !void {
    const line = self.chunk().lines.items[ip];
    const message = try std.fmt.allocPrint(self.allocator, fmt, args);
    try self.compiler.?.reportErrorAt(line, 1, line, 1, message);
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
                            const result = try std.mem.concat(self.allocator, u8, &[_][]const u8{ as.data, bs.data });
                            const heap_str = try mem.HeapString.init(self.allocator, result);
                            try self.heap.trackObject(.{ .string = heap_str }, @sizeOf(mem.HeapString) + result.len);
                            try self.push(.{ .String = heap_str });

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
                closure_ptr.* = val.Closure.init(function);
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
                const value = try self.peek(arg_count);
                if (!try self.callValue(ip, value, arg_count)) {
                    try self.errorAt(ip, "Calling failed", .{});
                    return err.Error.RuntimeError;
                }
                ip += 1;
                // After call returns, frame_count is already decremented by Return
                // Continue with next instruction
            },
            .Class => {
                const name = try self.chunk().readConstant(ip).tryString();

                const class_ptr = try self.allocator.create(val.Class);
                class_ptr.* = val.Class.init(self.allocator, name);
                try self.heap.trackObject(
                    .{ .class = class_ptr },
                    @sizeOf(val.Class) + @sizeOf(std.StringHashMap(val.LoxValue)),
                );
                try self.push(.{ .Class = class_ptr });

                ip += CONST_SIZE;
            },
            .GetProperty => {
                const name = try self.chunk().readConstant(ip).tryString();
                const instance = try (try self.peek(0)).tryInstance();
                if (instance.fields.get(name)) |field| {
                    _ = try self.pop(); // instance
                    try self.push(field);
                } else if (instance.klass.methods.get(name)) |method| {
                    _ = try self.pop(); // instance

                    const bound_ptr = try self.allocator.create(val.BoundMethod);
                    bound_ptr.* = val.BoundMethod.init(instance, method);
                    try self.heap.trackObject(.{ .bound_method = bound_ptr }, @sizeOf(val.BoundMethod));

                    try self.push(.{ .BoundMethod = bound_ptr });
                } else {
                    try self.errorAt(ip, "Undefined property or method '{s}' of {s}", .{ name, instance.klass.name });
                    return err.Error.RuntimeError;
                }
                ip += CONST_SIZE;
            },
            .SetProperty => {
                const prop_name = try self.chunk().readConstant(ip).tryString();
                const prop_value = try self.pop();
                const instance = try (try self.pop()).tryInstance();

                try instance.fields.put(prop_name, prop_value);
                try self.push(prop_value);
                ip += CONST_SIZE;
            },
            .Method => {
                const name = try self.chunk().readConstant(ip).tryString();
                try self.defineMethod(name);
                ip += CONST_SIZE;
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
        try self.errorAt(ip, "Unknown global to get: {s}.", .{name});
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
        try self.errorAt(ip, "Unknown global to set: {s}.", .{name});
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
                self.markValue(.{ .Function = c.function });
                for (c.upvalues[0..c.upvalue_count]) |up| {
                    self.markUpvalue(up);
                }
            }
        },
        .Class => |c| {
            if (!c.marked) {
                c.marked = true;
            }
        },
        .Instance => |inst| {
            if (!inst.marked) {
                inst.marked = true;
            }
        },
        .BoundMethod => |b| {
            if (!b.marked) {
                b.marked = true;
            }
        },
        .Function => |f| {
            if (!f.marked) {
                f.marked = true;
                for (f.chunk.constants.items) |const_val| {
                    self.markValue(const_val);
                }
            }
        },
        .String => |s| {
            s.marked = true;
        },
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


test {
    _ = @import("vm_test.zig");
}
