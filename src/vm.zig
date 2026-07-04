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
globals: val.StringKeyMap,
frames: []CallFrame,
frame_count: usize,
init_string: *val.HeapString,

heap: mem.Heap,
interned: std.StringHashMap(*val.HeapString),
open_upvalues: ?*val.Upvalue,

pub const CallFrame = struct {
    closure: *val.Closure,
    slots_offset: usize, // points to vm's value's stack first value it can use
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io) !VM {
    const stack = try gpa.alloc(LoxValue, STACK_MAX);
    @memset(stack, LoxValue.nil);

    const frames = try gpa.alloc(CallFrame, FRAMES_MAX);
    @memset(frames, CallFrame{ .closure = undefined, .slots_offset = 0 });

    var vm = VM{
        .allocator = gpa,
        .io = io,
        .writer = writer,
        .stack = stack,
        .frames = frames,
        .frame_count = 0,
        .globals = val.StringKeyMap.init(gpa),
        .stack_top = 0,
        .heap = mem.Heap.init(gpa),
        .interned = std.StringHashMap(*val.HeapString).init(gpa),
        .open_upvalues = null,
        .compiler = null,
        .init_string = undefined,
    };
    errdefer {
        gpa.free(stack);
        gpa.free(frames);
        vm.interned.deinit();
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
    self.interned.deinit();
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

    const closure_ptr = try self.allocator.create(val.Closure);
    closure_ptr.* = val.Closure.init(func);
    try self.push(LoxValue.closure(closure_ptr));
    try self.trackObject(.{ .closure = closure_ptr }, @sizeOf(val.Closure));
    _ = try self.call(1, closure_ptr, 0);
    _ = try self.pop();
}

fn trackObject(self: *VM, obj: mem.HeapObj, size: usize) !void {
    try self.heap.trackObject(obj, size);
    try self.maybeCollect();
}

fn adjustMapAllocation(self: *VM, old_capacity: usize, new_capacity: usize) !void {
    if (old_capacity == new_capacity) return;
    self.heap.adjustMapCapacity(old_capacity, new_capacity, @sizeOf(val.StringKeyMap.Entry));
    try self.maybeCollect();
}

fn maybeCollect(self: *VM) !void {
    if (self.heap.shouldCollect()) {
        try self.collectGarbage();
    }
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
    if (self.interned.get(bytes)) |existing| {
        return existing;
    }

    const owned = try self.allocator.dupe(u8, bytes);
    const heap_str = try val.HeapString.init(self.allocator, owned);
    try self.interned.put(heap_str.data, heap_str);
    try self.trackObject(.{ .string = heap_str }, @sizeOf(val.HeapString) + owned.len);
    return heap_str;
}

fn defineNative(self: *VM, name: []const u8, function: val.NativeFn) !void {
    const key = try self.internString(name);
    try self.globals.put(key, LoxValue.native(function));
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
    if (self.frame_count >= FRAMES_MAX) {
        try self.errorAt(ip, "Stack overflow.", .{});
        return err.Error.RuntimeError;
    }
    self.frames[self.frame_count] = CallFrame{
        .closure = closure,
        .slots_offset = self.stack_top - arg_count - 1,
    };
    self.frame_count += 1;
    try self.run();
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
    const receiver = try self.peek(arg_count);
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
        const instance_ptr = try self.allocator.create(val.Instance);
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
    std.log.err("Can only call functions and classes.", .{});
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

    const created = try self.allocator.create(val.Upvalue);
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
    const method = try self.pop();
    const klass = try (try self.peek(0)).tryClass();
    const old_capacity = klass.methods.capacity();
    try klass.methods.put(name, method);
    try self.adjustMapAllocation(old_capacity, klass.methods.capacity());
}

fn bindMethod(self: *VM, klass: *val.Class, name: *val.HeapString) !bool {
    const instance = try (try self.peek(0)).tryInstance();
    if (klass.methods.get(name)) |method| {
        _ = try self.pop(); // instance

        const bound_ptr = try self.allocator.create(val.BoundMethod);
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
                try self.defineGlobal(ip, CONST_SIZE);
                ip += CONST_SIZE;
            },
            .DefineGlobalLong => {
                try self.defineGlobal(ip, CONST_LONG_SIZE);
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
                try self.push(LoxValue.nil);
            },
            .True => {
                try self.push(LoxValue.boolean(true));
            },
            .False => {
                try self.push(LoxValue.boolean(false));
            },
            .Equal => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(LoxValue.boolean(a.equal(b)));
            },
            .Less => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(LoxValue.boolean(try a.less(b)));
            },
            .Greater => {
                const b = try self.pop();
                const a = try self.pop();
                const lt = try a.less(b);
                const eq = a.equal(b);
                try self.push(LoxValue.boolean(!lt and !eq));
            },
            .Negate => {
                const value = try self.pop();
                try self.push(LoxValue.number(-try value.tryNumber()));
            },
            .Not => {
                const value = try self.pop();
                try self.push(LoxValue.boolean(value.isFalsee()));
            },
            .Add => {
                const b = try self.pop();
                const a = try self.pop();

                if (a.isNumber() and b.isNumber()) {
                    try self.push(LoxValue.number(a.asNumber() + b.asNumber()));
                } else if (a.isString() and b.isString()) {
                    const as = a.asString();
                    const bs = b.asString();
                    const result = try std.mem.concat(self.allocator, u8, &[_][]const u8{ as.data, bs.data });
                    const heap_str = try mem.HeapString.init(self.allocator, result);
                    try self.push(LoxValue.string(heap_str));
                    try self.trackObject(.{ .string = heap_str }, @sizeOf(mem.HeapString) + result.len);
                } else {
                    return err.Error.RuntimeError;
                }
            },
            .Subtract => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(LoxValue.number(try a.tryNumber() - try b.tryNumber()));
            },
            .Multiply => {
                const b = try self.pop();
                const a = try self.pop();
                try self.push(LoxValue.number(try a.tryNumber() * try b.tryNumber()));
            },
            .Divide => {
                const b = try self.pop();
                const a = try self.pop();
                const bn = try b.tryNumber();
                if (bn == 0) {
                    try self.push(LoxValue.number(std.math.nan(f64)));
                } else {
                    const an = try a.tryNumber();
                    try self.push(LoxValue.number(an / bn));
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
                const function = self.chunk().readConstant(ip).asFunction();
                ip += CONST_SIZE;

                const closure_ptr = try self.allocator.create(val.Closure);
                closure_ptr.* = val.Closure.init(function);
                try self.push(LoxValue.closure(closure_ptr));
                try self.trackObject(.{ .closure = closure_ptr }, @sizeOf(val.Closure));

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
                const name = try self.readStringConstant(ip, CONST_SIZE);

                const class_ptr = try self.allocator.create(val.Class);
                class_ptr.* = val.Class.init(self.allocator, name);
                try self.push(LoxValue.class(class_ptr));
                try self.trackObject(.{ .class = class_ptr }, class_ptr.size());

                ip += CONST_SIZE;
            },
            .Inherit => {
                const sub_class = try (try self.peek(0)).tryClass();
                const super_class = (try self.peek(1)).tryClass() catch {
                    try self.errorAt(ip, "Superclass must be a class.", .{});
                    return err.Error.RuntimeError;
                };
                const old_capacity = sub_class.methods.capacity();
                var it = super_class.methods.iterator();
                while (it.next()) |entry| {
                    try sub_class.methods.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                try self.adjustMapAllocation(old_capacity, sub_class.methods.capacity());
                _ = try self.pop(); // subclass
            },
            .GetSuper => {
                const name = try self.readStringConstant(ip, CONST_SIZE);
                const super_class = try (try self.pop()).tryClass();
                if (!try self.bindMethod(super_class, name)) {
                    try self.errorAt(ip, "Undefined method or property '{s}'", .{name.data});
                    return err.Error.RuntimeError;
                }

                ip += CONST_SIZE;
            },
            .GetProperty => {
                const name = try self.readStringConstant(ip, CONST_SIZE);
                const instance = try (try self.peek(0)).tryInstance();
                if (instance.fields.get(name)) |field| {
                    _ = try self.pop(); // instance
                    try self.push(field);
                } else if (!try self.bindMethod(instance.klass, name)) {
                    try self.errorAt(ip, "Undefined property or method '{s}' of {s}", .{ name.data, instance.klass.name.data });
                    return err.Error.RuntimeError;
                }
                ip += CONST_SIZE;
            },
            .Invoke => {
                const name = try self.readStringConstant(ip, CONST_SIZE);
                const arg_count = self.chunk().readByte(ip + CONST_SIZE);
                if (!try self.invoke(ip, name, arg_count)) {
                    try self.errorAt(ip, "Invoke '{s}'' failed", .{name.data});
                    return err.Error.RuntimeError;
                }
                ip += CONST_SIZE + 1;
            },
            .SuperInvoke => {
                const name = try self.readStringConstant(ip, CONST_SIZE);
                const arg_count = self.chunk().readByte(ip + CONST_SIZE);
                const super_class = try (try self.pop()).tryClass();

                if (!try self.invokeFromClass(ip, super_class, name, arg_count)) {
                    try self.errorAt(ip, "Super invoke '{s}' failed", .{name.data});
                    return err.Error.RuntimeError;
                }
                ip += CONST_SIZE + 1;
            },
            .SetProperty => {
                const prop_name = try self.readStringConstant(ip, CONST_SIZE);
                const prop_value = try self.pop();
                const instance = try (try self.pop()).tryInstance();

                const old_capacity = instance.fields.capacity();
                try instance.fields.put(prop_name, prop_value);
                try self.adjustMapAllocation(old_capacity, instance.fields.capacity());
                try self.push(prop_value);
                ip += CONST_SIZE;
            },
            .Method => {
                const name = try self.readStringConstant(ip, CONST_SIZE);
                try self.defineMethod(name);
                ip += CONST_SIZE;
            },
            .Return => {
                const result = if (self.stack_top > 0) try self.pop() else LoxValue.nil;

                const slots_offset = self.frame().slots_offset;
                self.closeUpvalues(@intFromPtr(&self.stack[slots_offset]));

                self.frame_count -= 1;
                if (self.frame_count == 0) {
                    return;
                }
                self.stack_top = slots_offset;
                try self.push(result);
                return;
            },
            .CloseUpvalue => {
                self.closeUpvalues(@intFromPtr(&self.stack[self.stack_top - 1]));
                _ = try self.pop();
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
    const value = try self.peek(0);
    try self.globals.put(name, value);
    _ = try self.pop();
}

fn getGlobal(self: *VM, ip: usize, constant_size: usize) !void {
    const name = try self.readStringConstant(ip, constant_size);
    if (self.globals.get(name)) |constant_value| {
        try self.push(constant_value);
    } else {
        try self.errorAt(ip, "Unknown global to get: {s}.", .{name.data});
        return err.Error.RuntimeError;
    }
}

fn setGlobal(self: *VM, ip: usize, constant_size: usize) !void {
    const name = try self.readStringConstant(ip, constant_size);
    if (!self.globals.contains(name)) {
        try self.errorAt(ip, "Unknown global to set: {s}.", .{name.data});
        return err.Error.RuntimeError;
    }
    const new_value = try self.peek(0);
    try self.globals.put(name, new_value);
}

// ============================================
// Garbage Collection
// ============================================

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
            var it = c.methods.iterator();
            while (it.next()) |entry| {
                self.markValue(LoxValue.string(entry.key_ptr.*));
                self.markValue(entry.value_ptr.*);
            }
        }
        return;
    }
    if (value.isInstance()) {
        const inst = value.asInstance();
        if (!inst.marked) {
            inst.marked = true;
            self.markValue(LoxValue.class(inst.klass));
            var it = inst.fields.iterator();
            while (it.next()) |entry| {
                self.markValue(LoxValue.string(entry.key_ptr.*));
                self.markValue(entry.value_ptr.*);
            }
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
        self.markValue(LoxValue.string(entry.key_ptr.*));
        self.markValue(entry.value_ptr.*);
    }

    // 3. Interned strings
    var intern_it = self.interned.iterator();
    while (intern_it.next()) |entry| {
        self.markValue(LoxValue.string(entry.value_ptr.*));
    }

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
    // Mark phase
    self.markRoots();
    // Sweep phase
    try self.heap.collectGarbage();
}

test {
    _ = @import("vm_test.zig");
}
