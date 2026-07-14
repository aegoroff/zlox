pub const VM = @This();

const std = @import("std");
const Chunk = @import("chunk.zig");
const err = @import("error.zig");
const val = @import("value.zig");
const mem = @import("memory.zig");
const builtin = @import("builtin.zig");
const Compiler = @import("compiler.zig");
const tbl = @import("table.zig");
const Table = tbl.Table;

const LoxValue = val.LoxValue;
const FRAMES_MAX: usize = 64;
const STACK_MAX: usize = 256 * FRAMES_MAX;

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
compiler: ?Compiler,
io: std.Io,
stack: []LoxValue,
/// Points one past the last pushed value (clox `stackTop`).
stack_top: [*]LoxValue,
globals: Table,
frames: []CallFrame,
frame_count: usize,
init_string: *val.HeapString,

heap: mem.Heap,
strings: Table,
open_upvalues: ?*val.Upvalue,

pub const CallFrame = struct {
    closure: *val.Closure,
    slots: [*]LoxValue,
    ip: [*]const u8,
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io) !VM {
    const stack = try gpa.alloc(LoxValue, STACK_MAX);
    @memset(stack, LoxValue.nil);

    const frames = try gpa.alloc(CallFrame, FRAMES_MAX);
    @memset(frames, CallFrame{ .closure = undefined, .slots = undefined, .ip = undefined });

    var vm = VM{
        .allocator = gpa,
        .io = io,
        .writer = writer,
        .stack = stack,
        .frames = frames,
        .frame_count = 0,
        .globals = Table.init(gpa),
        .stack_top = stack.ptr,
        .heap = try mem.Heap.init(gpa),
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
    return self.interpretFrom(source, print_code, "<stdin>");
}

pub fn interpretFrom(self: *VM, source: []const u8, print_code: bool, from: []const u8) !void {
    self.compiler = Compiler.init(
        self.allocator,
        self.writer,
        print_code,
        from,
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
    closure_ptr.* = try val.Closure.init(self.allocator, func);
    try self.push(LoxValue.closure(closure_ptr));
    try self.trackObject(.{ .closure = closure_ptr }, closure_ptr.size());
    const script_ip = closure_ptr.function.chunk.code.items.ptr;
    if (!try self.call(script_ip, closure_ptr, 0)) return err.Error.RuntimeError;
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
    self.heap.adjustMapCapacity(old_capacity, new_capacity, @sizeOf(tbl.Entry));
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
    const hash = tbl.hashString(bytes);
    if (self.strings.findString(bytes, hash)) |existing| {
        return existing;
    }

    const owned = try self.allocator.dupe(u8, bytes);
    return self.takeString(owned, hash);
}

fn takeString(self: *VM, owned: []u8, hash: u32) !*val.HeapString {
    const heap_str = try self.heap.allocStringHeader();
    heap_str.* = .{ .gc = .{ .kind = .string }, .hash = hash, .data = owned };
    try self.push(LoxValue.string(heap_str));
    errdefer _ = self.pop();
    _ = try self.setTrackedTable(&self.strings, heap_str, LoxValue.nil);
    try self.trackObject(.{ .string = heap_str }, @sizeOf(val.HeapString) + owned.len);
    _ = self.pop();
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

inline fn stackLimit(self: *const VM) [*]LoxValue {
    return self.stack.ptr + STACK_MAX;
}

inline fn stackCount(self: *const VM) usize {
    return (@intFromPtr(self.stack_top) - @intFromPtr(self.stack.ptr)) / @sizeOf(LoxValue);
}

inline fn push(self: *VM, value: LoxValue) !void {
    if (@intFromPtr(self.stack_top) >= @intFromPtr(self.stackLimit())) {
        @branchHint(.unlikely);
        return stackOverflowError(self);
    }
    self.stack_top[0] = value;
    self.stack_top += 1;
}

inline fn pop(self: *VM) LoxValue {
    self.stack_top -= 1;
    return self.stack_top[0];
}

inline fn peek(self: *VM, distance: usize) LoxValue {
    return (self.stack_top - 1 - distance)[0];
}

/// Slot `distance` from the top (0 = TOS).
inline fn peekSlot(self: *VM, distance: usize) *LoxValue {
    return @ptrCast(self.stack_top - 1 - distance);
}

/// Overwrite TOS without changing stack height (unary ops like `Negate`).
inline fn replaceTos(self: *VM, value: LoxValue) void {
    (self.stack_top - 1)[0] = value;
}

/// Binary-op result: discard the top operand, write `value` into the new TOS.
/// Same effect as `pop(); pop(); push(value)`, but skips the overflow check on push.
inline fn popAndReplace(self: *VM, value: LoxValue) void {
    self.stack_top -= 1;
    (self.stack_top - 1)[0] = value;
}

inline fn call(self: *VM, ip: [*]const u8, closure: *val.Closure, arg_count: usize) anyerror!bool {
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
    self.pushFrame(closure, arg_count);
    return true;
}

/// Hot path for calling a closure when arity/frames are already known to be OK.
inline fn pushFrame(self: *VM, closure: *val.Closure, arg_count: usize) void {
    self.frames[self.frame_count] = CallFrame{
        .closure = closure,
        .slots = self.stack_top - arg_count - 1,
        .ip = closure.function.chunk.code.items.ptr,
    };
    self.frame_count += 1;
}

inline fn invokeFromClass(self: *VM, ip: [*]const u8, klass: *val.Class, name: *val.HeapString, arg_count: usize) anyerror!bool {
    if (klass.methods.get(name)) |method| {
        return self.call(ip, method.asClosure(), arg_count);
    }
    try self.errorAt(ip, "Undefined property '{s}'.", .{name.data});
    return err.Error.RuntimeError;
}

inline fn invoke(self: *VM, ip: [*]const u8, name: *val.HeapString, arg_count: usize) anyerror!bool {
    const receiver = self.peek(arg_count);
    const instance = receiver.tryInstance() catch {
        try self.errorAt(ip, "Only instances have methods.", .{});
        return err.Error.RuntimeError;
    };

    if (instance.fields.get(name)) |field| {
        self.peekSlot(arg_count).* = field;
        return self.callValue(ip, field, arg_count);
    }

    return self.invokeFromClass(ip, instance.klass, name, arg_count);
}

inline fn callValue(self: *VM, ip: [*]const u8, value: LoxValue, arg_count: usize) anyerror!bool {
    if (value.isClosure()) {
        return try self.call(ip, value.asClosure(), arg_count);
    }
    if (value.isClass()) {
        const k = value.asClass();
        const instance_ptr = try self.heap.allocInstance();
        instance_ptr.* = val.Instance.init(self.allocator, k);
        self.peekSlot(arg_count).* = LoxValue.instance(instance_ptr);
        try self.trackObject(.{ .instance = instance_ptr }, instance_ptr.size());
        if (instance_ptr.klass.methods.get(self.init_string)) |in| {
            return try self.call(ip, in.asClosure(), arg_count);
        } else if (arg_count != 0) {
            try self.errorAt(ip, "Expected 0 arguments but got {d}.", .{arg_count});
            return err.Error.RuntimeError;
        }
        return true;
    }
    if (value.isBoundMethod()) {
        const b = value.asBoundMethod();
        self.peekSlot(arg_count).* = LoxValue.instance(b.receiver);
        return self.call(ip, b.method.asClosure(), arg_count);
    }
    if (value.isNative()) {
        const native_fn = value.asNative();
        const args_ptr = self.stack_top - arg_count;
        const args = args_ptr[0..arg_count];
        const result = try native_fn(self.io, args);
        self.stack_top -= arg_count + 1;
        try self.push(result);
        return true;
    }
    try self.errorAt(ip, "Can only call functions and classes.", .{});
    return err.Error.RuntimeError;
}

fn captureUpvalue(self: *VM, slot: *LoxValue) !*val.Upvalue {
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
        .gc = .{ .kind = .upvalue },
        .location = slot,
        .closed = LoxValue.nil,
        .next = null,
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

fn closeUpvalues(self: *VM, last: *LoxValue) void {
    var current = self.open_upvalues orelse return;
    while (true) {
        if (@intFromPtr(current.location) >= @intFromPtr(last)) {
            self.open_upvalues = current.next;
            current.close();
            current = self.open_upvalues orelse return;
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

inline fn bindMethod(self: *VM, klass: *val.Class, name: *val.HeapString) !bool {
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

inline fn frame(self: *VM) *CallFrame {
    return &self.frames[self.frame_count - 1];
}

inline fn chunk(self: *VM) *Chunk {
    return &self.frame().closure.function.chunk;
}

fn errorAt(self: *VM, ip: [*]const u8, comptime fmt: []const u8, args: anytype) !void {
    const chunk_ptr = self.chunk();
    const offset = chunk_ptr.offsetOf(ip);
    const line = chunk_ptr.lines.items[offset];
    const message = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(message);
    try self.compiler.?.reportErrorAt(line, 1, line, 1, message);
}

fn println(self: *VM) !void {
    try self.writer.print("\n", .{});
}

const FrameCursor = struct {
    frame: *CallFrame,

    inline fn fromVm(vm: *VM) FrameCursor {
        return .{ .frame = &vm.frames[vm.frame_count - 1] };
    }

    inline fn reload(self: *FrameCursor, vm: *VM) void {
        self.frame = &vm.frames[vm.frame_count - 1];
    }

    inline fn chunk(self: *const FrameCursor) *Chunk {
        return &self.frame.closure.function.chunk;
    }
};

fn opClosure(self: *VM, cursor: *FrameCursor, constant_size: usize) !void {
    const function = cursor.chunk().readConstantAt(cursor.frame.ip, constant_size).asFunction();
    cursor.frame.ip += constant_size;

    const closure_ptr = try self.heap.allocClosure();
    closure_ptr.* = try val.Closure.init(self.allocator, function);
    try self.push(LoxValue.closure(closure_ptr));
    try self.trackObject(.{ .closure = closure_ptr }, closure_ptr.size());

    for (0..function.upvalue_count) |i| {
        const is_local = Chunk.readByteAt(cursor.frame.ip);
        const index = Chunk.readByteAt(cursor.frame.ip + 1);
        cursor.frame.ip += 2;
        closure_ptr.upvalues[i] = if (is_local == 1)
            try self.captureUpvalue(@ptrCast(cursor.frame.slots + index))
        else
            cursor.frame.closure.upvalues[index];
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

inline fn opInvoke(self: *VM, cursor: *FrameCursor, constant_size: usize) !void {
    const name = try self.readStringConstant(cursor.frame.ip, constant_size);
    const arg_count = Chunk.readByteAt(cursor.frame.ip + constant_size);
    cursor.frame.ip += constant_size + 1;
    if (!try self.invoke(cursor.frame.ip, name, arg_count)) {
        try self.errorAt(cursor.frame.ip, "Invoke '{s}'' failed", .{name.data});
        return err.Error.RuntimeError;
    }
    cursor.reload(self);
}

inline fn opSuperInvoke(self: *VM, cursor: *FrameCursor, constant_size: usize) !void {
    const name = try self.readStringConstant(cursor.frame.ip, constant_size);
    const arg_count = Chunk.readByteAt(cursor.frame.ip + constant_size);
    cursor.frame.ip += constant_size + 1;
    const super_class = try (self.pop()).tryClass();

    if (!try self.invokeFromClass(cursor.frame.ip, super_class, name, arg_count)) {
        try self.errorAt(cursor.frame.ip, "Super invoke '{s}' failed", .{name.data});
        return err.Error.RuntimeError;
    }
    cursor.reload(self);
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
    @setEvalBranchQuota(10_000);
    var cursor = FrameCursor.fromVm(self);

    while (true) {
        const opcode = Chunk.readOpcodeAt(cursor.frame.ip);
        cursor.frame.ip += 1;
        switch (opcode) {
            .JumpIfFalse => {
                const offset = Chunk.readShortAt(cursor.frame.ip);
                cursor.frame.ip += 2;
                if (self.peek(0).isFalsee()) {
                    cursor.frame.ip += offset;
                }
            },
            .Jump => {
                const offset = Chunk.readShortAt(cursor.frame.ip);
                cursor.frame.ip += 2;
                cursor.frame.ip += offset;
            },
            .Loop => {
                const offset = Chunk.readShortAt(cursor.frame.ip);
                cursor.frame.ip += 2;
                cursor.frame.ip -= offset;
            },
            .Constant => {
                try self.push(cursor.chunk().readConstantAt(cursor.frame.ip, Chunk.OPERAND_SHORT));
                cursor.frame.ip += Chunk.OPERAND_SHORT;
            },
            .ConstantLong => {
                try self.push(cursor.chunk().readConstantAt(cursor.frame.ip, Chunk.OPERAND_LONG));
                cursor.frame.ip += Chunk.OPERAND_LONG;
            },
            .DefineGlobal => {
                try self.defineGlobal(cursor.frame.ip, Chunk.OPERAND_SHORT);
                cursor.frame.ip += Chunk.OPERAND_SHORT;
            },
            .DefineGlobalLong => {
                try self.defineGlobal(cursor.frame.ip, Chunk.OPERAND_LONG);
                cursor.frame.ip += Chunk.OPERAND_LONG;
            },
            .GetGlobal => {
                try self.getGlobal(cursor.frame.ip, Chunk.OPERAND_SHORT);
                cursor.frame.ip += Chunk.OPERAND_SHORT;
            },
            .GetGlobalLong => {
                try self.getGlobal(cursor.frame.ip, Chunk.OPERAND_LONG);
                cursor.frame.ip += Chunk.OPERAND_LONG;
            },
            .SetGlobal => {
                try self.setGlobal(cursor.frame.ip, Chunk.OPERAND_SHORT);
                cursor.frame.ip += Chunk.OPERAND_SHORT;
            },
            .SetGlobalLong => {
                try self.setGlobal(cursor.frame.ip, Chunk.OPERAND_LONG);
                cursor.frame.ip += Chunk.OPERAND_LONG;
            },
            .GetLocal => {
                const slot = Chunk.readByteAt(cursor.frame.ip);
                cursor.frame.ip += Chunk.OPERAND_SHORT;
                try self.push(cursor.frame.slots[slot]);
            },
            .GetLocalLong => {
                const slot = Chunk.readThreeBytesAt(cursor.frame.ip);
                cursor.frame.ip += Chunk.OPERAND_LONG;
                try self.push(cursor.frame.slots[slot]);
            },
            .SetLocal => {
                const slot = Chunk.readByteAt(cursor.frame.ip);
                cursor.frame.ip += Chunk.OPERAND_SHORT;
                cursor.frame.slots[slot] = self.peek(0);
            },
            .SetLocalLong => {
                const slot = Chunk.readThreeBytesAt(cursor.frame.ip);
                cursor.frame.ip += Chunk.OPERAND_LONG;
                cursor.frame.slots[slot] = self.peek(0);
            },
            .GetUpvalue => {
                const slot = Chunk.readByteAt(cursor.frame.ip);
                cursor.frame.ip += 1;
                try self.push(cursor.frame.closure.upvalues[slot].get());
            },
            .SetUpvalue => {
                const slot = Chunk.readByteAt(cursor.frame.ip);
                cursor.frame.ip += 1;
                cursor.frame.closure.upvalues[slot].set(self.peek(0));
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
                const b = self.peek(0);
                const a = self.peek(1);
                if (a.isNumber() and b.isNumber()) {
                    self.popAndReplace(LoxValue.boolean(a.asNumber() < b.asNumber()));
                } else {
                    const result = a.less(b) catch {
                        try self.errorAt(cursor.frame.ip, "Operands must be strings.", .{});
                        return err.Error.RuntimeError;
                    };
                    self.popAndReplace(LoxValue.boolean(result));
                }
            },
            .Greater => {
                const b = self.peek(0);
                const a = self.peek(1);
                if (a.isNumber() and b.isNumber()) {
                    self.popAndReplace(LoxValue.boolean(a.asNumber() > b.asNumber()));
                } else {
                    const result = a.greaterThan(b) catch {
                        try self.errorAt(cursor.frame.ip, "Operands must be strings.", .{});
                        return err.Error.RuntimeError;
                    };
                    self.popAndReplace(LoxValue.boolean(result));
                }
            },
            .Negate => {
                const value = self.peek(0);
                if (!value.isNumber()) {
                    try self.errorAt(cursor.frame.ip, "Operand must be a number.", .{});
                    return err.Error.RuntimeError;
                }
                self.replaceTos(LoxValue.number(-value.asNumber()));
            },
            .Not => {
                const value = self.pop();
                try self.push(LoxValue.boolean(value.isFalsee()));
            },
            .Add => {
                const b = self.peek(0);
                const a = self.peek(1);

                if (a.isNumber() and b.isNumber()) {
                    self.popAndReplace(LoxValue.number(a.asNumber() + b.asNumber()));
                } else if (a.isString() and b.isString()) {
                    var buf_a: [val.SHORT_STRING_MAX_LEN]u8 = undefined;
                    var buf_b: [val.SHORT_STRING_MAX_LEN]u8 = undefined;
                    const as = a.stringBytes(&buf_a);
                    const bs = b.stringBytes(&buf_b);
                    _ = self.pop();
                    _ = self.pop();
                    if (as.len + bs.len <= val.SHORT_STRING_MAX_LEN) {
                        var combined: [val.SHORT_STRING_MAX_LEN]u8 = undefined;
                        @memcpy(combined[0..as.len], as);
                        @memcpy(combined[as.len..][0..bs.len], bs);
                        try self.push(LoxValue.shortString(combined[0 .. as.len + bs.len]));
                    } else {
                        const result = try std.mem.concat(self.allocator, u8, &[_][]const u8{ as, bs });
                        const hash = tbl.hashString(result);
                        const heap_str = if (self.strings.findString(result, hash)) |existing| blk: {
                            self.allocator.free(result);
                            break :blk existing;
                        } else try self.takeString(result, hash);
                        try self.push(LoxValue.string(heap_str));
                    }
                } else {
                    try self.errorAt(cursor.frame.ip, "Operands must be two numbers or two strings.", .{});
                    return err.Error.RuntimeError;
                }
            },
            .Subtract => {
                const b = self.peek(0);
                const a = self.peek(1);
                if (!a.isNumber() or !b.isNumber()) {
                    try self.errorAt(cursor.frame.ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                }
                self.popAndReplace(LoxValue.number(a.asNumber() - b.asNumber()));
            },
            .Multiply => {
                const b = self.peek(0);
                const a = self.peek(1);
                if (!a.isNumber() or !b.isNumber()) {
                    try self.errorAt(cursor.frame.ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                }
                self.popAndReplace(LoxValue.number(a.asNumber() * b.asNumber()));
            },
            .Divide => {
                const b = self.peek(0);
                const a = self.peek(1);
                if (!a.isNumber() or !b.isNumber()) {
                    try self.errorAt(cursor.frame.ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                }
                const bn = b.asNumber();
                self.popAndReplace(LoxValue.number(if (bn == 0) std.math.nan(f64) else a.asNumber() / bn));
            },
            .Print => {
                const value = self.pop();
                try value.print(self.writer);
                try self.println();
            },
            .Pop => _ = self.pop(),
            .Closure => try self.opClosure(&cursor, Chunk.OPERAND_SHORT),
            .ClosureLong => try self.opClosure(&cursor, Chunk.OPERAND_LONG),
            .Call => {
                const arg_count = Chunk.readByteAt(cursor.frame.ip);
                cursor.frame.ip += 1;
                const value = self.peek(arg_count);
                // Fast path: monomorphic closure calls (fib, etc.) — no error-union dance.
                if (value.isClosure()) {
                    const closure = value.asClosure();
                    if (closure.function.arity == arg_count and self.frame_count < FRAMES_MAX) {
                        self.pushFrame(closure, arg_count);
                    } else if (!try self.call(cursor.frame.ip, closure, arg_count)) {
                        try self.errorAt(cursor.frame.ip, "Calling failed", .{});
                        return err.Error.RuntimeError;
                    }
                } else if (!try self.callValue(cursor.frame.ip, value, arg_count)) {
                    try self.errorAt(cursor.frame.ip, "Calling failed", .{});
                    return err.Error.RuntimeError;
                }
                cursor.reload(self);
            },
            .Class => try self.opClass(cursor.frame, Chunk.OPERAND_SHORT),
            .ClassLong => try self.opClass(cursor.frame, Chunk.OPERAND_LONG),
            .Inherit => {
                const sub_class = try (self.peek(0)).tryClass();
                const super_class = (self.peek(1)).tryClass() catch {
                    try self.errorAt(cursor.frame.ip, "Superclass must be a class.", .{});
                    return err.Error.RuntimeError;
                };
                const old_capacity = sub_class.methods.capacity;
                try sub_class.methods.addAll(&super_class.methods);
                try self.adjustMapAllocation(old_capacity, sub_class.methods.capacity);
                _ = self.pop();
            },
            .GetSuper => try self.opGetSuper(cursor.frame, Chunk.OPERAND_SHORT),
            .GetSuperLong => try self.opGetSuper(cursor.frame, Chunk.OPERAND_LONG),
            .GetProperty => try self.opGetProperty(cursor.frame, Chunk.OPERAND_SHORT),
            .GetPropertyLong => try self.opGetProperty(cursor.frame, Chunk.OPERAND_LONG),
            .Invoke => try self.opInvoke(&cursor, Chunk.OPERAND_SHORT),
            .InvokeLong => try self.opInvoke(&cursor, Chunk.OPERAND_LONG),
            .SuperInvoke => try self.opSuperInvoke(&cursor, Chunk.OPERAND_SHORT),
            .SuperInvokeLong => try self.opSuperInvoke(&cursor, Chunk.OPERAND_LONG),
            .SetProperty => try self.opSetProperty(cursor.frame, Chunk.OPERAND_SHORT),
            .SetPropertyLong => try self.opSetProperty(cursor.frame, Chunk.OPERAND_LONG),
            .Method => try self.opMethod(cursor.frame, Chunk.OPERAND_SHORT),
            .MethodLong => try self.opMethod(cursor.frame, Chunk.OPERAND_LONG),
            .Return => {
                const result = if (@intFromPtr(self.stack_top) > @intFromPtr(self.stack.ptr)) self.pop() else LoxValue.nil;

                if (self.open_upvalues != null) {
                    self.closeUpvalues(@ptrCast(cursor.frame.slots));
                }

                self.frame_count -= 1;
                if (self.frame_count == 0) {
                    return;
                }

                self.stack_top = cursor.frame.slots;
                self.stack_top[0] = result;
                self.stack_top += 1;
                cursor.reload(self);
            },
            .CloseUpvalue => {
                self.closeUpvalues(@ptrCast(self.stack_top - 1));
                _ = self.pop();
            },
        }
    }
}

inline fn readStringConstant(self: *VM, ip: [*]const u8, constant_size: usize) err.Error!*val.HeapString {
    const value = self.chunk().readConstantAt(ip, constant_size);
    if (!value.isHeapString()) return err.Error.RuntimeError;
    return value.asString();
}

inline fn defineGlobal(self: *VM, ip: [*]const u8, constant_size: usize) !void {
    const name = try self.readStringConstant(ip, constant_size);
    const value = self.peek(0);
    _ = try self.setTrackedTable(&self.globals, name, value);
    _ = self.pop();
}

inline fn getGlobal(self: *VM, ip: [*]const u8, constant_size: usize) !void {
    const name = try self.readStringConstant(ip, constant_size);
    if (self.globals.get(name)) |constant_value| {
        try self.push(constant_value);
    } else {
        try self.errorAt(ip, "Undefined variable '{s}'.", .{name.data});
        return err.Error.RuntimeError;
    }
}

inline fn setGlobal(self: *VM, ip: [*]const u8, constant_size: usize) !void {
    const name = try self.readStringConstant(ip, constant_size);
    if (!self.globals.setExisting(name, self.peek(0))) {
        try self.errorAt(ip, "Undefined variable '{s}'.", .{name.data});
        return err.Error.RuntimeError;
    }
}

// Garbage Collection

fn markRoots(self: *VM) !void {
    for (self.stack[0..self.stackCount()]) |slot| {
        try self.heap.markValue(slot);
    }

    try self.heap.markTable(&self.globals);

    for (self.frames[0..self.frame_count]) |call_frame| {
        try self.heap.markObject(.{ .closure = call_frame.closure });
    }

    var upvalue = self.open_upvalues;
    while (upvalue) |up| {
        try self.heap.markObject(.{ .upvalue = up });
        upvalue = up.next;
    }

    try self.heap.markObject(.{ .string = self.init_string });
}

pub fn collectGarbage(self: *VM) !void {
    try self.markRoots();
    try self.heap.traceReferences();
    self.strings.removeWhite();
    self.heap.sweep();
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

test "unreferenced interned strings are collected from string pool" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtual_machine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtual_machine.deinit();

    const ephemeral = "ephemeral";
    const hash = tbl.hashString(ephemeral);
    {
        const owned = try virtual_machine.allocator.dupe(u8, ephemeral);
        _ = try virtual_machine.takeString(owned, hash);
    }
    try std.testing.expect(virtual_machine.strings.findString(ephemeral, hash) != null);

    try virtual_machine.collectGarbage();

    try std.testing.expect(virtual_machine.strings.findString(ephemeral, hash) == null);
    try std.testing.expect(virtual_machine.strings.findString("init", virtual_machine.init_string.hash) != null);
}

test "value stack overflow is reported" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtual_machine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtual_machine.deinit();
    virtual_machine.stack_top = virtual_machine.stackLimit();
    try std.testing.expectError(err.Error.RuntimeError, virtual_machine.push(LoxValue.nil));
}

test {
    _ = @import("vm_test.zig");
}
