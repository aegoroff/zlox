pub const VM = @This();

const std = @import("std");
const Chunk = @import("chunk.zig");
const err = @import("error.zig");
const val = @import("value.zig");
const mem = @import("memory.zig");
const builtin = @import("builtin.zig");
const Compiler = @import("compiler.zig");
const Table = @import("table.zig").Table;

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
globals: Table,
frames: []CallFrame,
frame_count: usize,
init_string: *val.HeapString,

heap: mem.Heap,
strings: Table,
open_upvalues: ?*val.Upvalue,

pub const CallFrame = struct {
    closure: *val.Closure,
    slots_offset: usize,
    slots: [*]LoxValue,
    ip: usize = 0,
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io) !VM {
    const stack = try gpa.alloc(LoxValue, STACK_MAX);
    @memset(stack, LoxValue.nil);

    const frames = try gpa.alloc(CallFrame, FRAMES_MAX);
    @memset(frames, CallFrame{ .closure = undefined, .slots_offset = 0, .slots = undefined, .ip = 0 });

    var vm = VM{
        .allocator = gpa,
        .io = io,
        .writer = writer,
        .stack = stack,
        .frames = frames,
        .frame_count = 0,
        .globals = Table.init(gpa),
        .stack_top = 0,
        .heap = mem.Heap.init(gpa),
        .strings = Table.init(gpa),
        .open_upvalues = null,
        .compiler = null,
        .init_string = undefined,
    };
    errdefer {
        gpa.free(stack);
        gpa.free(frames);
        vm.strings.deinit();
        vm.globals.deinit();
        vm.heap.deinit();
    }
    vm.init_string = try vm.internString("init");
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
    self.strings.deinit();
    self.heap.deinit();
    self.allocator.free(self.stack);
    self.allocator.free(self.frames);
}

pub fn interpret(self: *VM, source: []const u8, print_code: bool) !void {
    return self.interpretWithFilename(source, print_code, "<stdin>");
}

pub fn interpretWithFilename(self: *VM, source: []const u8, print_code: bool, filename: []const u8) !void {
    self.compiler = Compiler.init(
        self.allocator,
        self.writer,
        print_code,
        filename,
        self,
        compilerInternString,
    );

    const func = self.compiler.?.compile(source) catch |compile_err| {
        return compile_err;
    };

    if (self.compiler.?.parser.hadError) {
        return err.Error.CompileError;
    }

    try self.trackConstantsRecursively(func);
    self.compiler.?.current.function = null;

    const closure_ptr = try self.heap.allocClosure();
    closure_ptr.* = val.Closure.init(func);
    try self.push(LoxValue.closure(closure_ptr));
    try self.trackObject(.{ .closure = closure_ptr }, @sizeOf(val.Closure));
    if (!try self.call(1, closure_ptr, 0)) return err.Error.RuntimeError;
    try self.run();
    _ = self.pop();
}

fn trackObject(self: *VM, obj: mem.HeapObj, size: usize) !void {
    try self.heap.trackObject(obj, size);
    if (self.heap.shouldCollect()) {
        try self.collectGarbage();
    }
}

fn adjustMapAllocation(self: *VM, old_capacity: usize, new_capacity: usize) !void {
    if (old_capacity == new_capacity) return;
    self.heap.adjustMapCapacity(old_capacity, new_capacity, @sizeOf(@import("table.zig").Entry));
    if (self.heap.shouldCollect()) {
        try self.collectGarbage();
    }
}

fn setTrackedTable(self: *VM, table: *Table, key: *val.HeapString, value: LoxValue) !bool {
    const old_capacity = table.capacity;
    const is_new = try table.set(key, value);
    try self.adjustMapAllocation(old_capacity, table.capacity);
    return is_new;
}

fn trackConstantsRecursively(self: *VM, func: *val.Function) !void {
    try self.trackObject(.{ .function = func }, func.size());
    for (func.chunk.constants.items) |c| {
        if (c.isFunction()) {
            try self.trackConstantsRecursively(c.asFunction());
        }
    }
}

fn compilerInternString(ctx: *anyopaque, bytes: []const u8) !*val.HeapString {
    const vm: *VM = @ptrCast(@alignCast(ctx));
    return vm.internString(bytes);
}

fn internString(self: *VM, bytes: []const u8) !*val.HeapString {
    const hash = @import("table.zig").hashString(bytes);
    if (self.strings.findString(bytes, hash)) |existing| {
        return existing;
    }

    const owned = try self.allocator.dupe(u8, bytes);
    return self.takeString(owned, hash);
}

fn takeString(self: *VM, owned: []u8, hash: u32) !*val.HeapString {
    const heap_str = try self.heap.allocStringHeader();
    heap_str.* = .{ .marked = false, .hash = hash, .data = owned };
    _ = try self.setTrackedTable(&self.strings, heap_str, LoxValue.nil);
    try self.trackObject(.{ .string = heap_str }, @sizeOf(val.HeapString) + owned.len);
    return heap_str;
}

fn defineNative(self: *VM, name: []const u8, function: val.NativeFn) !void {
    const key = try self.internString(name);
    _ = try self.setTrackedTable(&self.globals, key, LoxValue.native(function));
}

fn stackOverflowError(self: *VM) !void {
    if (self.frame_count > 0) {
        try self.errorAt(self.frames[self.frame_count - 1].ip, "Stack overflow.", .{});
    }
    return err.Error.RuntimeError;
}

inline fn push(self: *VM, value: LoxValue) !void {
    if (self.stack_top >= STACK_MAX) {
        @branchHint(.unlikely);
        return stackOverflowError(self);
    }
    self.stack[self.stack_top] = value;
    self.stack_top += 1;
}

inline fn pop(self: *VM) LoxValue {
    self.stack_top -= 1;
    return self.stack[self.stack_top];
}

inline fn peek(self: *VM, distance: usize) LoxValue {
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
    if (self.frame_count >= FRAMES_MAX) {
        try self.errorAt(ip, "Stack overflow.", .{});
        return err.Error.RuntimeError;
    }
    const slots_offset = self.stack_top - arg_count - 1;
    self.frames[self.frame_count] = CallFrame{
        .closure = closure,
        .slots_offset = slots_offset,
        .slots = @ptrCast(&self.stack[slots_offset]),
        .ip = 0,
    };
    self.frame_count += 1;
    return true;
}

fn invokeFromClass(self: *VM, ip: usize, klass: *val.Class, name: *val.HeapString, arg_count: usize) anyerror!bool {
    if (klass.methods.get(name)) |method| {
        return self.call(ip, try method.tryClosure(), arg_count);
    }
    try self.errorAt(ip, "Undefined property '{s}'.", .{name.data});
    return err.Error.RuntimeError;
}

fn invoke(self: *VM, ip: usize, name: *val.HeapString, arg_count: usize) anyerror!bool {
    const receiver = self.peek(arg_count);
    const instance = receiver.tryInstance() catch {
        try self.errorAt(ip, "Only instances have methods.", .{});
        return err.Error.RuntimeError;
    };

    if (instance.fields.get(name)) |field| {
        self.stack[self.stack_top - arg_count - 1] = field;
        return self.callValue(ip, field, arg_count);
    }

    return self.invokeFromClass(ip, instance.klass, name, arg_count);
}

fn callValue(self: *VM, ip: usize, value: LoxValue, arg_count: usize) anyerror!bool {
    if (value.isClosure()) {
        return try self.call(ip, value.asClosure(), arg_count);
    }
    if (value.isClass()) {
        const k = value.asClass();
        const instance_ptr = try self.heap.allocInstance();
        instance_ptr.* = val.Instance.init(self.allocator, k);
        self.stack[self.stack_top - arg_count - 1] = LoxValue.instance(instance_ptr);
        try self.trackObject(.{ .instance = instance_ptr }, instance_ptr.size());
        if (instance_ptr.klass.methods.get(self.init_string)) |in| {
            return try self.call(ip, try in.tryClosure(), arg_count);
        } else if (arg_count != 0) {
            try self.errorAt(ip, "Expected 0 arguments but got {d}.", .{arg_count});
            return err.Error.RuntimeError;
        }
        return true;
    }
    if (value.isBoundMethod()) {
        const b = value.asBoundMethod();
        self.stack[self.stack_top - arg_count - 1] = LoxValue.instance(b.receiver);
        return self.call(ip, try b.method.tryClosure(), arg_count);
    }
    if (value.isNative()) {
        const native_fn = value.asNative();
        const args_start = self.stack_top - arg_count;
        const result = try native_fn(self.io, self.stack[args_start..self.stack_top]);
        self.stack_top -= arg_count + 1;
        try self.push(result);
        return true;
    }
    try self.errorAt(ip, "Can only call functions and classes.", .{});
    return err.Error.RuntimeError;
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

    const created = try self.heap.allocUpvalue();
    created.* = .{
        .location = slot,
        .closed = LoxValue.nil,
        .next = null,
        .marked = false,
    };

    if (prev) |p| {
        created.next = p.next;
        p.next = created;
    } else {
        created.next = self.open_upvalues;
        self.open_upvalues = created;
    }

    try self.trackObject(.{ .upvalue = created }, @sizeOf(val.Upvalue));

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

fn defineMethod(self: *VM, name: *val.HeapString) !void {
    const method = self.pop();
    const klass = try (self.peek(0)).tryClass();
    const old_capacity = klass.methods.capacity;
    _ = try klass.methods.set(name, method);
    try self.adjustMapAllocation(old_capacity, klass.methods.capacity);
}

fn bindMethod(self: *VM, klass: *val.Class, name: *val.HeapString) !bool {
    const instance = try (self.peek(0)).tryInstance();
    if (klass.methods.get(name)) |method| {
        _ = self.pop(); // instance

        const bound_ptr = try self.heap.allocBoundMethod();
        bound_ptr.* = val.BoundMethod.init(instance, method);
        try self.push(LoxValue.boundMethod(bound_ptr));
        try self.trackObject(.{ .bound_method = bound_ptr }, @sizeOf(val.BoundMethod));
        return true;
    }
    return false;
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
    defer self.allocator.free(message);
    try self.compiler.?.reportErrorAt(line, 1, line, 1, message);
}

fn println(self: *VM) !void {
    try self.writer.print("\n", .{});
}

// After CALL, RETURN, or INVOKE the active call frame changes. Refresh the
// cached frame pointer and its derived closure, chunk, and slots base.
inline fn syncFrame(
    self: *VM,
    frame_out: **CallFrame,
    closure_out: **val.Closure,
    chunk_out: **Chunk,
    slots_out: *[*]LoxValue,
) void {
    frame_out.* = &self.frames[self.frame_count - 1];
    closure_out.* = frame_out.*.closure;
    chunk_out.* = &closure_out.*.function.chunk;
    slots_out.* = frame_out.*.slots;
}

inline fn numberLess(a: LoxValue, b: LoxValue) bool {
    const l = a.asNumber();
    const r = b.asNumber();
    if (std.math.isNan(l) or std.math.isNan(r)) return false;
    return l < r;
}

inline fn readFunctionConstant(code: *Chunk, ip: usize, constant_size: usize) *val.Function {
    const value = switch (constant_size) {
        CONST_SIZE => code.readConstant(ip),
        CONST_LONG_SIZE => code.readConstantLong(ip),
        else => unreachable,
    };
    return value.asFunction();
}

inline fn opClosure(
    self: *VM,
    current_frame: *CallFrame,
    current_chunk: *Chunk,
    closure: **val.Closure,
    constant_size: usize,
) !void {
    const function = readFunctionConstant(current_chunk, current_frame.ip, constant_size);
    current_frame.ip += constant_size;

    const closure_ptr = try self.heap.allocClosure();
    closure_ptr.* = val.Closure.init(function);
    try self.push(LoxValue.closure(closure_ptr));
    try self.trackObject(.{ .closure = closure_ptr }, @sizeOf(val.Closure));

    for (0..function.upvalue_count) |_| {
        const is_local = current_chunk.readByte(current_frame.ip);
        const index = current_chunk.readByte(current_frame.ip + 1);
        current_frame.ip += 2;
        const upvalue: *val.Upvalue = if (is_local == 1)
            try self.captureUpvalue(current_frame.slots_offset + index)
        else
            closure.*.upvalues[index];
        closure_ptr.upvalues[closure_ptr.upvalue_count] = upvalue;
        closure_ptr.upvalue_count += 1;
    }
}

fn opClass(self: *VM, current_frame: *CallFrame, constant_size: usize) !void {
    const name = try self.readStringConstant(current_frame.ip, constant_size);

    const class_ptr = try self.heap.allocClass();
    class_ptr.* = val.Class.init(self.allocator, name);
    try self.push(LoxValue.class(class_ptr));
    try self.trackObject(.{ .class = class_ptr }, class_ptr.size());

    current_frame.ip += constant_size;
}

inline fn opGetSuper(self: *VM, current_frame: *CallFrame, constant_size: usize) !void {
    const name = try self.readStringConstant(current_frame.ip, constant_size);
    const super_class = try (self.pop()).tryClass();
    if (!try self.bindMethod(super_class, name)) {
        try self.errorAt(current_frame.ip, "Undefined method or property '{s}'", .{name.data});
        return err.Error.RuntimeError;
    }

    current_frame.ip += constant_size;
}

inline fn opGetProperty(self: *VM, current_frame: *CallFrame, constant_size: usize) !void {
    const name = try self.readStringConstant(current_frame.ip, constant_size);
    const receiver = self.peek(0);
    if (!receiver.isInstance()) {
        try self.errorAt(current_frame.ip, "Only instances have properties.", .{});
        return err.Error.RuntimeError;
    }
    const instance = receiver.asInstance();
    if (instance.fields.get(name)) |field| {
        _ = self.pop();
        try self.push(field);
    } else if (!try self.bindMethod(instance.klass, name)) {
        try self.errorAt(current_frame.ip, "Undefined property or method '{s}' of {s}", .{ name.data, instance.klass.name.data });
        return err.Error.RuntimeError;
    }
    current_frame.ip += constant_size;
}

inline fn opInvoke(
    self: *VM,
    current_frame: **CallFrame,
    current_chunk: *Chunk,
    closure: **val.Closure,
    current_chunk_ptr: **Chunk,
    slots: *[*]LoxValue,
    constant_size: usize,
) !void {
    const name = try self.readStringConstant(current_frame.*.ip, constant_size);
    const arg_count = current_chunk.readByte(current_frame.*.ip + constant_size);
    current_frame.*.ip += constant_size + 1;
    if (!try self.invoke(current_frame.*.ip, name, arg_count)) {
        try self.errorAt(current_frame.*.ip, "Invoke '{s}'' failed", .{name.data});
        return err.Error.RuntimeError;
    }
    syncFrame(self, current_frame, closure, current_chunk_ptr, slots);
}

inline fn opSuperInvoke(
    self: *VM,
    current_frame: **CallFrame,
    current_chunk: *Chunk,
    closure: **val.Closure,
    current_chunk_ptr: **Chunk,
    slots: *[*]LoxValue,
    constant_size: usize,
) !void {
    const name = try self.readStringConstant(current_frame.*.ip, constant_size);
    const arg_count = current_chunk.readByte(current_frame.*.ip + constant_size);
    current_frame.*.ip += constant_size + 1;
    const super_class = try (self.pop()).tryClass();

    if (!try self.invokeFromClass(current_frame.*.ip, super_class, name, arg_count)) {
        try self.errorAt(current_frame.*.ip, "Super invoke '{s}' failed", .{name.data});
        return err.Error.RuntimeError;
    }
    syncFrame(self, current_frame, closure, current_chunk_ptr, slots);
}

inline fn opSetProperty(self: *VM, current_frame: *CallFrame, constant_size: usize) !void {
    const prop_name = try self.readStringConstant(current_frame.ip, constant_size);
    const prop_value = self.pop();
    const receiver = self.pop();
    if (!receiver.isInstance()) {
        try self.errorAt(current_frame.ip, "Only instances have fields.", .{});
        return err.Error.RuntimeError;
    }
    const instance = receiver.asInstance();

    const old_capacity = instance.fields.capacity;
    _ = try instance.fields.set(prop_name, prop_value);
    try self.adjustMapAllocation(old_capacity, instance.fields.capacity);
    try self.push(prop_value);
    current_frame.ip += constant_size;
}

inline fn opMethod(self: *VM, current_frame: *CallFrame, constant_size: usize) !void {
    const name = try self.readStringConstant(current_frame.ip, constant_size);
    try self.defineMethod(name);
    current_frame.ip += constant_size;
}

pub fn run(self: *VM) !void {
    var current_frame = &self.frames[self.frame_count - 1];
    var closure = current_frame.closure;
    var current_chunk = &closure.function.chunk;
    var slots = current_frame.slots;

    while (true) {
        const opcode = current_chunk.readOpcode(current_frame.ip);
        current_frame.ip += 1;
        switch (opcode) {
            .JumpIfFalse => {
                const offset = current_chunk.readShort(current_frame.ip);
                current_frame.ip += 2;
                if (self.peek(0).isFalsee()) {
                    current_frame.ip += offset;
                }
            },
            .Jump => {
                const offset = current_chunk.readShort(current_frame.ip);
                current_frame.ip += 2;
                current_frame.ip += offset;
            },
            .Loop => {
                const offset = current_chunk.readShort(current_frame.ip);
                current_frame.ip += 2;
                current_frame.ip -= offset;
            },
            .Constant => {
                try self.push(current_chunk.readConstant(current_frame.ip));
                current_frame.ip += CONST_SIZE;
            },
            .ConstantLong => {
                try self.push(current_chunk.readConstantLong(current_frame.ip));
                current_frame.ip += CONST_LONG_SIZE;
            },
            .DefineGlobal => {
                try self.defineGlobal(current_frame.ip, CONST_SIZE);
                current_frame.ip += CONST_SIZE;
            },
            .DefineGlobalLong => {
                try self.defineGlobal(current_frame.ip, CONST_LONG_SIZE);
                current_frame.ip += CONST_LONG_SIZE;
            },
            .GetGlobal => {
                try self.getGlobal(current_frame.ip, CONST_SIZE);
                current_frame.ip += CONST_SIZE;
            },
            .GetGlobalLong => {
                try self.getGlobal(current_frame.ip, CONST_LONG_SIZE);
                current_frame.ip += CONST_LONG_SIZE;
            },
            .SetGlobal => {
                try self.setGlobal(current_frame.ip, CONST_SIZE);
                current_frame.ip += CONST_SIZE;
            },
            .SetGlobalLong => {
                try self.setGlobal(current_frame.ip, CONST_LONG_SIZE);
                current_frame.ip += CONST_LONG_SIZE;
            },
            .GetLocal => {
                const slot = current_chunk.readByte(current_frame.ip);
                current_frame.ip += 1;
                try self.push(slots[slot]);
            },
            .GetLocalLong => {
                const slot = current_chunk.readThreeBytes(current_frame.ip);
                current_frame.ip += CONST_LONG_SIZE;
                try self.push(slots[slot]);
            },
            .SetLocal => {
                const slot = current_chunk.readByte(current_frame.ip);
                current_frame.ip += 1;
                slots[slot] = self.peek(0);
            },
            .SetLocalLong => {
                const slot = current_chunk.readThreeBytes(current_frame.ip);
                current_frame.ip += CONST_LONG_SIZE;
                slots[slot] = self.peek(0);
            },
            .GetUpvalue => {
                const slot = current_chunk.readByte(current_frame.ip);
                current_frame.ip += 1;
                try self.push(closure.upvalues[slot].get());
            },
            .SetUpvalue => {
                const slot = current_chunk.readByte(current_frame.ip);
                current_frame.ip += 1;
                closure.upvalues[slot].set(self.peek(0));
            },
            .Nil => try self.push(LoxValue.nil),
            .True => try self.push(LoxValue.boolean(true)),
            .False => try self.push(LoxValue.boolean(false)),
            .Equal => {
                const b = self.pop();
                const a = self.pop();
                try self.push(LoxValue.boolean(a.equal(b)));
            },
            .Less => {
                const b = self.pop();
                const a = self.pop();
                if (a.isNumber() and b.isNumber()) {
                    try self.push(LoxValue.boolean(numberLess(a, b)));
                } else if (a.isString() and b.isString()) {
                    try self.push(LoxValue.boolean(std.mem.lessThan(u8, a.asString().data, b.asString().data)));
                } else if (a.isBool() and b.isBool()) {
                    try self.push(LoxValue.boolean(!a.asBool() and b.asBool()));
                } else {
                    try self.errorAt(current_frame.ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                }
            },
            .Greater => {
                const b = self.pop();
                const a = self.pop();
                const lt = if (a.isNumber() and b.isNumber())
                    numberLess(a, b)
                else if (a.isString() and b.isString())
                    std.mem.lessThan(u8, a.asString().data, b.asString().data)
                else if (a.isBool() and b.isBool())
                    !a.asBool() and b.asBool()
                else {
                    try self.errorAt(current_frame.ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                };
                try self.push(LoxValue.boolean(!lt and !a.equal(b)));
            },
            .Negate => {
                const value = self.pop();
                if (!value.isNumber()) {
                    try self.errorAt(current_frame.ip, "Operand must be a number.", .{});
                    return err.Error.RuntimeError;
                }
                try self.push(LoxValue.number(-value.asNumber()));
            },
            .Not => {
                const value = self.pop();
                try self.push(LoxValue.boolean(value.isFalsee()));
            },
            .Add => {
                const b = self.pop();
                const a = self.pop();

                if (a.isNumber() and b.isNumber()) {
                    try self.push(LoxValue.number(a.asNumber() + b.asNumber()));
                } else if (a.isString() and b.isString()) {
                    const as = a.asString();
                    const bs = b.asString();
                    const result = try std.mem.concat(self.allocator, u8, &[_][]const u8{ as.data, bs.data });
                    const hash = @import("table.zig").hashString(result);
                    const heap_str = if (self.strings.findString(result, hash)) |existing| blk: {
                        self.allocator.free(result);
                        break :blk existing;
                    } else try self.takeString(result, hash);
                    try self.push(LoxValue.string(heap_str));
                } else {
                    try self.errorAt(current_frame.ip, "Operands must be two numbers or two strings.", .{});
                    return err.Error.RuntimeError;
                }
            },
            .Subtract => {
                const b = self.pop();
                const a = self.pop();
                if (!a.isNumber() or !b.isNumber()) {
                    try self.errorAt(current_frame.ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                }
                try self.push(LoxValue.number(a.asNumber() - b.asNumber()));
            },
            .Multiply => {
                const b = self.pop();
                const a = self.pop();
                if (!a.isNumber() or !b.isNumber()) {
                    try self.errorAt(current_frame.ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                }
                try self.push(LoxValue.number(a.asNumber() * b.asNumber()));
            },
            .Divide => {
                const b = self.pop();
                const a = self.pop();
                if (!a.isNumber() or !b.isNumber()) {
                    try self.errorAt(current_frame.ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                }
                const bn = b.asNumber();
                if (bn == 0) {
                    try self.push(LoxValue.number(std.math.nan(f64)));
                } else {
                    try self.push(LoxValue.number(a.asNumber() / bn));
                }
            },
            .Print => {
                const value = self.pop();
                try value.print(self.writer);
                try self.println();
            },
            .Pop => _ = self.pop(),
            .Closure => try self.opClosure(current_frame, current_chunk, &closure, CONST_SIZE),
            .ClosureLong => try self.opClosure(current_frame, current_chunk, &closure, CONST_LONG_SIZE),
            .Call => {
                const arg_count = current_chunk.readByte(current_frame.ip);
                current_frame.ip += 1;
                const value = self.peek(arg_count);
                if (!try self.callValue(current_frame.ip, value, arg_count)) {
                    try self.errorAt(current_frame.ip, "Calling failed", .{});
                    return err.Error.RuntimeError;
                }
                syncFrame(self, &current_frame, &closure, &current_chunk, &slots);
            },
            .Class => try self.opClass(current_frame, CONST_SIZE),
            .ClassLong => try self.opClass(current_frame, CONST_LONG_SIZE),
            .Inherit => {
                const sub_class = try (self.peek(0)).tryClass();
                const super_class = (self.peek(1)).tryClass() catch {
                    try self.errorAt(current_frame.ip, "Superclass must be a class.", .{});
                    return err.Error.RuntimeError;
                };
                const old_capacity = sub_class.methods.capacity;
                try sub_class.methods.addAll(&super_class.methods);
                try self.adjustMapAllocation(old_capacity, sub_class.methods.capacity);
                _ = self.pop();
            },
            .GetSuper => try self.opGetSuper(current_frame, CONST_SIZE),
            .GetSuperLong => try self.opGetSuper(current_frame, CONST_LONG_SIZE),
            .GetProperty => try self.opGetProperty(current_frame, CONST_SIZE),
            .GetPropertyLong => try self.opGetProperty(current_frame, CONST_LONG_SIZE),
            .Invoke => try self.opInvoke(&current_frame, current_chunk, &closure, &current_chunk, &slots, CONST_SIZE),
            .InvokeLong => try self.opInvoke(&current_frame, current_chunk, &closure, &current_chunk, &slots, CONST_LONG_SIZE),
            .SuperInvoke => try self.opSuperInvoke(&current_frame, current_chunk, &closure, &current_chunk, &slots, CONST_SIZE),
            .SuperInvokeLong => try self.opSuperInvoke(&current_frame, current_chunk, &closure, &current_chunk, &slots, CONST_LONG_SIZE),
            .SetProperty => try self.opSetProperty(current_frame, CONST_SIZE),
            .SetPropertyLong => try self.opSetProperty(current_frame, CONST_LONG_SIZE),
            .Method => try self.opMethod(current_frame, CONST_SIZE),
            .MethodLong => try self.opMethod(current_frame, CONST_LONG_SIZE),
            .Return => {
                const result = if (self.stack_top > 0) self.pop() else LoxValue.nil;

                self.closeUpvalues(@intFromPtr(current_frame.slots));

                self.frame_count -= 1;
                if (self.frame_count == 0) {
                    return;
                }

                self.stack_top = current_frame.slots_offset;
                try self.push(result);
                syncFrame(self, &current_frame, &closure, &current_chunk, &slots);
            },
            .CloseUpvalue => {
                self.closeUpvalues(@intFromPtr(&self.stack[self.stack_top - 1]));
                _ = self.pop();
            },
        }
    }
}

fn readStringConstant(self: *VM, ip: usize, constant_size: usize) err.Error!*val.HeapString {
    const value = switch (constant_size) {
        CONST_SIZE => self.chunk().readConstant(ip),
        CONST_LONG_SIZE => self.chunk().readConstantLong(ip),
        else => return err.Error.CompileError,
    };
    if (!value.isString()) return err.Error.RuntimeError;
    return value.asString();
}

fn defineGlobal(self: *VM, ip: usize, constant_size: usize) !void {
    const name = try self.readStringConstant(ip, constant_size);
    const value = self.peek(0);
    _ = try self.setTrackedTable(&self.globals, name, value);
    _ = self.pop();
}

inline fn getGlobal(self: *VM, ip: usize, constant_size: usize) !void {
    const name = try self.readStringConstant(ip, constant_size);
    if (self.globals.get(name)) |constant_value| {
        try self.push(constant_value);
    } else {
        try self.errorAt(ip, "Undefined variable '{s}'.", .{name.data});
        return err.Error.RuntimeError;
    }
}

inline fn setGlobal(self: *VM, ip: usize, constant_size: usize) !void {
    const name = try self.readStringConstant(ip, constant_size);
    if (!self.globals.contains(name)) {
        try self.errorAt(ip, "Undefined variable '{s}'.", .{name.data});
        return err.Error.RuntimeError;
    }
    const new_value = self.peek(0);
    _ = try self.setTrackedTable(&self.globals, name, new_value);
}

// ============================================
// Garbage Collection
// ============================================

fn markTable(self: *VM, table: *const Table) void {
    const Ctx = struct {
        vm: *VM,
        fn callback(ctx: @This(), key: *val.HeapString, value: LoxValue) void {
            ctx.vm.markValue(LoxValue.string(key));
            ctx.vm.markValue(value);
        }
    };
    const ctx: Ctx = .{ .vm = self };
    table.forEach(ctx, Ctx.callback);
}

fn markValue(self: *VM, value: LoxValue) void {
    if (value.isClosure()) {
        const c = value.asClosure();
        if (!c.marked) {
            c.marked = true;
            self.markValue(LoxValue.function(c.function));
            for (c.upvalues[0..c.upvalue_count]) |up| {
                self.markUpvalue(up);
            }
        }
        return;
    }
    if (value.isClass()) {
        const c = value.asClass();
        if (!c.marked) {
            c.marked = true;
            self.markValue(LoxValue.string(c.name));
            self.markTable(&c.methods);
        }
        return;
    }
    if (value.isInstance()) {
        const inst = value.asInstance();
        if (!inst.marked) {
            inst.marked = true;
            self.markValue(LoxValue.class(inst.klass));
            self.markTable(&inst.fields);
        }
        return;
    }
    if (value.isBoundMethod()) {
        const b = value.asBoundMethod();
        if (!b.marked) {
            b.marked = true;
            self.markValue(LoxValue.instance(b.receiver));
            self.markValue(b.method);
        }
        return;
    }
    if (value.isFunction()) {
        const f = value.asFunction();
        if (!f.marked) {
            f.marked = true;
            for (f.chunk.constants.items) |const_val| {
                self.markValue(const_val);
            }
        }
        return;
    }
    if (value.isString()) {
        value.asString().marked = true;
    }
}

fn markUpvalue(self: *VM, upvalue: *val.Upvalue) void {
    if (!upvalue.marked) {
        upvalue.marked = true;
        if (upvalue.isClosed()) {
            self.markValue(upvalue.closed);
        } else {
            self.markValue(upvalue.location.*);
        }
    }
}

fn markRoots(self: *VM) void {
    // 1. Stack
    for (self.stack[0..self.stack_top]) |slot| {
        self.markValue(slot);
    }

    // 2. Globals
    self.markTable(&self.globals);

    // 3. Interned strings
    const StringCtx = struct {
        vm: *VM,
        fn callback(ctx: @This(), key: *val.HeapString, _: LoxValue) void {
            ctx.vm.markValue(LoxValue.string(key));
        }
    };
    const string_ctx: StringCtx = .{ .vm = self };
    self.strings.forEach(string_ctx, StringCtx.callback);

    // 4. Call frames
    for (self.frames[0..self.frame_count]) |f| {
        self.markValue(LoxValue.closure(f.closure));
    }

    // 5. Open upvalues
    var upvalue = self.open_upvalues;
    while (upvalue) |up| {
        self.markUpvalue(up);
        upvalue = up.next;
    }
}

pub fn collectGarbage(self: *VM) !void {
    self.markRoots();
    self.heap.collectGarbage();
}

test "tracked table growth updates gc heap bytes" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtual_machine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtual_machine.deinit();

    const before = virtual_machine.heap.bytes_allocated;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "g{d}", .{i});
        const key = try virtual_machine.internString(name);
        _ = try virtual_machine.setTrackedTable(&virtual_machine.globals, key, LoxValue.number(1));
    }

    try std.testing.expect(virtual_machine.globals.capacity > 0);
    try std.testing.expect(virtual_machine.heap.bytes_allocated > before);
}

test "value stack overflow is reported" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtual_machine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtual_machine.deinit();
    virtual_machine.stack_top = STACK_MAX;
    try std.testing.expectError(err.Error.RuntimeError, virtual_machine.push(LoxValue.nil));
}

test {
    _ = @import("vm_test.zig");
}
