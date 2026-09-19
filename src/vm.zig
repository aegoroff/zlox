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

// Declaration order is layout order here. What the dispatch loop touches on
// every call, return and global access comes first so it shares a cache line,
// and the compiler — large, and cold once execution starts — goes last. Without
// this the struct's tail shifts whenever an embedded field changes size, which
// moves the hot fields across line boundaries and shows up as several percent.
frames: []CallFrame,
frame_count: usize,
globals: Table,
open_upvalues: ?*val.Upvalue,
stack: []LoxValue,
/// Points one past the last pushed value (clox `stackTop`).
stack_top: [*]LoxValue,

heap: mem.Heap,
strings: Table,
init_string: *val.HeapString,
allocator: std.mem.Allocator,
writer: *std.Io.Writer,
io: std.Io,
compiler: ?Compiler,

pub const CallFrame = struct {
    closure: *val.Closure,
    slots: [*]LoxValue,
    ip: [*]const u8,
    /// Constant pool of `closure.function`, resolved once per call so operand
    /// decoding does not walk `closure -> function -> chunk` every time.
    constants: [*]const LoxValue,
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io) !VM {
    const stack = try gpa.alloc(LoxValue, STACK_MAX);
    @memset(stack, LoxValue.nil);

    const frames = try gpa.alloc(CallFrame, FRAMES_MAX);
    @memset(frames, CallFrame{ .closure = undefined, .slots = undefined, .ip = undefined, .constants = undefined });

    var vm = VM{
        .allocator = gpa,
        .io = io,
        .writer = writer,
        .stack = stack,
        .frames = frames,
        .frame_count = 0,
        .globals = .{},
        .stack_top = stack.ptr,
        .heap = try mem.Heap.init(gpa),
        .strings = .{},
        .open_upvalues = null,
        .compiler = null,
        .init_string = undefined,
    };
    errdefer {
        gpa.free(stack);
        gpa.free(frames);
        vm.strings.deinit(gpa);
        vm.globals.deinit(gpa);
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
    self.globals.deinit(self.allocator);
    self.strings.deinit(self.allocator);
    self.heap.deinit();
    self.allocator.free(self.stack);
    self.allocator.free(self.frames);
}

pub fn interpret(self: *VM, source: []const u8, print_code: bool) !void {
    return self.interpretFrom(source, print_code, "<stdin>");
}

pub fn interpretFrom(self: *VM, source: []const u8, print_code: bool, from: []const u8) !void {
    self.compiler = try Compiler.init(
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

    if (self.compiler.?.parser.had_error) {
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
    const old_capacity = table.capacity();
    const is_new = try table.set(self.allocator, key, value);
    try self.adjustMapAllocation(old_capacity, table.capacity());
    return is_new;
}

/// Hands the compiled function tree over to the heap. Registration goes
/// straight to the heap instead of `trackObject`: the tree is not reachable
/// from any root until the script closure sits on the stack, so a collection
/// started here would sweep the functions it has just tracked. The closure
/// registration right after this walk is the next collection point.
fn trackConstantsRecursively(self: *VM, func: *val.Function) !void {
    try self.heap.trackObject(.{ .function = func }, func.size());
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
    _ = self.pushFrame(closure, arg_count);
    return true;
}

/// Hot path for calling a closure when arity/frames are already known to be OK.
inline fn pushFrame(self: *VM, closure: *val.Closure, arg_count: usize) *CallFrame {
    const chunk_ptr = &closure.function.chunk;
    const pushed = &self.frames[self.frame_count];
    pushed.* = CallFrame{
        .closure = closure,
        .slots = self.stack_top - arg_count - 1,
        .ip = chunk_ptr.code.items.ptr,
        .constants = chunk_ptr.constants.items.ptr,
    };
    self.frame_count += 1;
    return pushed;
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
        instance_ptr.* = val.Instance.init(k);
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
    const old_capacity = klass.methods.capacity();
    _ = try klass.methods.set(self.allocator, name, method);
    try self.adjustMapAllocation(old_capacity, klass.methods.capacity());
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
    const reached = chunk_ptr.offsetOf(ip);
    // The dispatch loop steps past the opcode before the handler runs, so `ip`
    // can already sit on the next instruction. Every byte of an instruction
    // carries the same position, so stepping back one byte lands inside the
    // instruction that actually failed.
    const offset = if (reached > 0) reached - 1 else 0;
    const position = chunk_ptr.positions.items[offset];
    const message = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(message);
    const col_end = position.col + @max(position.len, 1) - 1;
    try self.compiler.?.reportErrorAt(position.line, position.col, position.line, col_end, message);
}

fn println(self: *VM) !void {
    try self.writer.print("\n", .{});
}

const FrameCursor = struct {
    frame: *CallFrame,
    /// Constant pool of the running function, hoisted out of the
    /// `closure -> function -> chunk` chain so operand decoding costs one load.
    constants: [*]const LoxValue,

    inline fn fromVm(vm: *VM) FrameCursor {
        return enter(&vm.frames[vm.frame_count - 1]);
    }

    inline fn enter(current: *CallFrame) FrameCursor {
        return .{ .frame = current, .constants = current.constants };
    }

    inline fn reload(self: *FrameCursor, vm: *VM) void {
        self.* = fromVm(vm);
    }

    /// Frames live in one flat array, so the caller is the slot below.
    inline fn returnToCaller(self: *FrameCursor) void {
        const frames: [*]CallFrame = @ptrCast(self.frame);
        self.* = enter(@ptrCast(frames - 1));
    }

    inline fn constantAt(self: *const FrameCursor, ip: [*]const u8, constant_size: usize) LoxValue {
        return self.constants[Chunk.getConstantIxAt(ip, constant_size)];
    }

    inline fn stringConstantAt(self: *const FrameCursor, ip: [*]const u8, constant_size: usize) err.Error!*val.HeapString {
        const value = self.constantAt(ip, constant_size);
        if (!value.isHeapString()) return err.Error.RuntimeError;
        return value.asString();
    }
};

/// The upvalue array is filled before the closure is pushed or registered: it
/// comes back from the allocator uninitialized, and a collection that reached a
/// closure holding it would walk those bytes as pointers. Capturing can collect —
/// `captureUpvalue` registers what it creates — but nothing the loop needs can be
/// swept while it runs. The closure is not in the heap's object list yet, so
/// the sweep cannot see it; its function is a constant of the running one; every
/// upvalue captured here is already on the open list, which `markRoots` walks;
/// and every upvalue inherited from the enclosing closure is held by a frame.
fn opClosure(self: *VM, cursor: *FrameCursor, ip: [*]const u8, constant_size: usize) ![*]const u8 {
    const function = cursor.constantAt(ip, constant_size).asFunction();
    var next = ip + constant_size;

    const closure_ptr = try self.heap.allocClosure();
    closure_ptr.* = try val.Closure.init(self.allocator, function);
    errdefer closure_ptr.deinit(self.allocator);

    for (0..function.upvalue_count) |i| {
        const is_local = Chunk.readByteAt(next);
        const index = Chunk.readByteAt(next + 1);
        next += 2;
        closure_ptr.upvalues[i] = if (is_local == 1)
            try self.captureUpvalue(@ptrCast(cursor.frame.slots + index))
        else
            cursor.frame.closure.upvalues[index];
    }

    try self.push(LoxValue.closure(closure_ptr));
    try self.trackObject(.{ .closure = closure_ptr }, closure_ptr.size());
    return next;
}

fn opClass(self: *VM, cursor: *const FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);

    const class_ptr = try self.heap.allocClass();
    class_ptr.* = val.Class.init(name);
    try self.push(LoxValue.class(class_ptr));
    try self.trackObject(.{ .class = class_ptr }, class_ptr.size());
}

inline fn opGetSuper(self: *VM, cursor: *const FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);
    const super_class = try (self.pop()).tryClass();
    if (!try self.bindMethod(super_class, name)) {
        try self.errorAt(ip, "Undefined method or property '{s}'", .{name.data});
        return err.Error.RuntimeError;
    }
}

inline fn opGetProperty(self: *VM, cursor: *const FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);
    const receiver = self.peek(0);
    if (!receiver.isInstance()) {
        try self.errorAt(ip, "Only instances have properties.", .{});
        return err.Error.RuntimeError;
    }
    const instance = receiver.asInstance();
    if (instance.fields.get(name)) |field| {
        self.replaceTos(field);
    } else if (!try self.bindMethod(instance.klass, name)) {
        try self.errorAt(ip, "Undefined property or method '{s}' of {s}", .{ name.data, instance.klass.name.data });
        return err.Error.RuntimeError;
    }
}

inline fn opInvoke(self: *VM, cursor: *FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);
    const arg_count = Chunk.readByteAt(ip + constant_size);
    const next = ip + constant_size + 1;
    cursor.frame.ip = next;
    if (!try self.invoke(next, name, arg_count)) {
        try self.errorAt(next, "Invoke '{s}'' failed", .{name.data});
        return err.Error.RuntimeError;
    }
    cursor.reload(self);
}

inline fn opSuperInvoke(self: *VM, cursor: *FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);
    const arg_count = Chunk.readByteAt(ip + constant_size);
    const next = ip + constant_size + 1;
    cursor.frame.ip = next;
    const super_class = try (self.pop()).tryClass();

    if (!try self.invokeFromClass(next, super_class, name, arg_count)) {
        try self.errorAt(next, "Super invoke '{s}' failed", .{name.data});
        return err.Error.RuntimeError;
    }
    cursor.reload(self);
}

/// Receiver and value are left on the stack until the store is accounted for:
/// growing the field table is a collection point, and neither operand is held
/// anywhere else while it runs. The receiver can be a temporary that no root
/// owns (`makeBox().field = x`), and the value then lives only in that dying
/// instance, so popping first would hand the collector both of them.
inline fn opSetProperty(self: *VM, cursor: *const FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const prop_name = try cursor.stringConstantAt(ip, constant_size);
    const receiver = self.peek(1);
    if (!receiver.isInstance()) {
        try self.errorAt(ip, "Only instances have fields.", .{});
        return err.Error.RuntimeError;
    }
    const instance = receiver.asInstance();

    const old_capacity = instance.fields.capacity();
    _ = try instance.fields.set(self.allocator, prop_name, self.peek(0));
    try self.adjustMapAllocation(old_capacity, instance.fields.capacity());

    const prop_value = self.pop();
    self.replaceTos(prop_value);
}

inline fn opMethod(self: *VM, cursor: *const FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);
    try self.defineMethod(name);
}

/// Value-stack top cached in a local so the dispatch loop keeps it in a
/// register instead of reloading `VM.stack_top` around every stack store. It is
/// handed back to the VM with `sync` before anything that touches the stack
/// itself or can trigger a collection, and picked up again with `reload`.
const StackCursor = struct {
    top: [*]LoxValue,
    limit: [*]LoxValue,

    inline fn fromVm(vm: *const VM) StackCursor {
        return .{ .top = vm.stack_top, .limit = vm.stack.ptr + STACK_MAX };
    }

    inline fn sync(self: StackCursor, vm: *VM) void {
        vm.stack_top = self.top;
    }

    inline fn reload(self: *StackCursor, vm: *const VM) void {
        self.top = vm.stack_top;
    }

    inline fn base(self: StackCursor) [*]LoxValue {
        return self.limit - STACK_MAX;
    }

    inline fn push(self: *StackCursor, vm: *VM, value: LoxValue) !void {
        if (@intFromPtr(self.top) >= @intFromPtr(self.limit)) {
            @branchHint(.unlikely);
            self.sync(vm);
            return vm.stackOverflowError();
        }
        self.pushUnchecked(value);
    }

    /// For pushes that cannot grow the stack past a height it already had.
    inline fn pushUnchecked(self: *StackCursor, value: LoxValue) void {
        self.top[0] = value;
        self.top += 1;
    }

    inline fn pop(self: *StackCursor) LoxValue {
        self.top -= 1;
        return self.top[0];
    }

    inline fn peek(self: StackCursor, distance: usize) LoxValue {
        return (self.top - 1 - distance)[0];
    }

    /// Overwrite TOS without changing stack height (unary ops like `Negate`).
    inline fn replaceTos(self: StackCursor, value: LoxValue) void {
        (self.top - 1)[0] = value;
    }

    /// Binary-op result: discard the top operand, write `value` into the new TOS.
    inline fn popAndReplace(self: *StackCursor, value: LoxValue) void {
        self.top -= 1;
        (self.top - 1)[0] = value;
    }
};

pub fn run(self: *VM) !void {
    @setEvalBranchQuota(10_000);
    var cursor = FrameCursor.fromVm(self);
    // The instruction pointer and the stack top live in locals so the dispatch
    // loop keeps them in registers; they are written back to the VM only when
    // control leaves the loop (calls, invokes, allocations, errors).
    var ip = cursor.frame.ip;
    var stack = StackCursor.fromVm(self);

    while (true) {
        const opcode = Chunk.readOpcodeAt(ip);
        ip += 1;
        switch (opcode) {
            .JumpIfFalse => {
                const offset = Chunk.readShortAt(ip);
                ip += 2;
                if (stack.peek(0).isFalsee()) {
                    ip += offset;
                }
            },
            .Jump => {
                const offset = Chunk.readShortAt(ip);
                ip += 2 + offset;
            },
            .Loop => {
                const offset = Chunk.readShortAt(ip);
                ip += 2;
                ip -= offset;
            },
            .Constant => {
                try stack.push(self, cursor.constantAt(ip, Chunk.OPERAND_SHORT));
                ip += Chunk.OPERAND_SHORT;
            },
            .ConstantLong => {
                try stack.push(self, cursor.constantAt(ip, Chunk.OPERAND_LONG));
                ip += Chunk.OPERAND_LONG;
            },
            .DefineGlobal => {
                stack.sync(self);
                try self.defineGlobal(&cursor, ip, Chunk.OPERAND_SHORT);
                stack.reload(self);
                ip += Chunk.OPERAND_SHORT;
            },
            .DefineGlobalLong => {
                stack.sync(self);
                try self.defineGlobal(&cursor, ip, Chunk.OPERAND_LONG);
                stack.reload(self);
                ip += Chunk.OPERAND_LONG;
            },
            .GetGlobal => {
                try self.getGlobal(&stack, &cursor, ip, Chunk.OPERAND_SHORT);
                ip += Chunk.OPERAND_SHORT;
            },
            .GetGlobalLong => {
                try self.getGlobal(&stack, &cursor, ip, Chunk.OPERAND_LONG);
                ip += Chunk.OPERAND_LONG;
            },
            .SetGlobal => {
                try self.setGlobal(&stack, &cursor, ip, Chunk.OPERAND_SHORT);
                ip += Chunk.OPERAND_SHORT;
            },
            .SetGlobalLong => {
                try self.setGlobal(&stack, &cursor, ip, Chunk.OPERAND_LONG);
                ip += Chunk.OPERAND_LONG;
            },
            .GetLocal => {
                const slot = Chunk.readByteAt(ip);
                ip += Chunk.OPERAND_SHORT;
                try stack.push(self, cursor.frame.slots[slot]);
            },
            .GetLocalLong => {
                const slot = Chunk.readThreeBytesAt(ip);
                ip += Chunk.OPERAND_LONG;
                try stack.push(self, cursor.frame.slots[slot]);
            },
            .SetLocal => {
                const slot = Chunk.readByteAt(ip);
                ip += Chunk.OPERAND_SHORT;
                cursor.frame.slots[slot] = stack.peek(0);
            },
            .SetLocalLong => {
                const slot = Chunk.readThreeBytesAt(ip);
                ip += Chunk.OPERAND_LONG;
                cursor.frame.slots[slot] = stack.peek(0);
            },
            .GetUpvalue => {
                const slot = Chunk.readByteAt(ip);
                ip += 1;
                try stack.push(self, cursor.frame.closure.upvalues[slot].get());
            },
            .SetUpvalue => {
                const slot = Chunk.readByteAt(ip);
                ip += 1;
                cursor.frame.closure.upvalues[slot].set(stack.peek(0));
            },
            .Nil => try stack.push(self, LoxValue.nil),
            .True => try stack.push(self, LoxValue.boolean(true)),
            .False => try stack.push(self, LoxValue.boolean(false)),
            .Equal => {
                const b = stack.peek(0);
                const a = stack.peek(1);
                stack.popAndReplace(LoxValue.boolean(a.equal(b)));
            },
            .Less => {
                const b = stack.peek(0);
                const a = stack.peek(1);
                if (a.isNumber() and b.isNumber()) {
                    stack.popAndReplace(LoxValue.boolean(a.asNumber() < b.asNumber()));
                } else {
                    const result = a.less(b) catch {
                        stack.sync(self);
                        try self.errorAt(ip, "Operands must be two numbers or two strings.", .{});
                        return err.Error.RuntimeError;
                    };
                    stack.popAndReplace(LoxValue.boolean(result));
                }
            },
            .Greater => {
                const b = stack.peek(0);
                const a = stack.peek(1);
                if (a.isNumber() and b.isNumber()) {
                    stack.popAndReplace(LoxValue.boolean(a.asNumber() > b.asNumber()));
                } else {
                    const result = a.greaterThan(b) catch {
                        stack.sync(self);
                        try self.errorAt(ip, "Operands must be two numbers or two strings.", .{});
                        return err.Error.RuntimeError;
                    };
                    stack.popAndReplace(LoxValue.boolean(result));
                }
            },
            .Negate => {
                const value = stack.peek(0);
                if (!value.isNumber()) {
                    stack.sync(self);
                    try self.errorAt(ip, "Operand must be a number.", .{});
                    return err.Error.RuntimeError;
                }
                stack.replaceTos(LoxValue.number(-value.asNumber()));
            },
            .Not => {
                stack.replaceTos(LoxValue.boolean(stack.peek(0).isFalsee()));
            },
            .Add => {
                const b = stack.peek(0);
                const a = stack.peek(1);

                if (a.isNumber() and b.isNumber()) {
                    stack.popAndReplace(LoxValue.number(a.asNumber() + b.asNumber()));
                } else if (a.isString() and b.isString()) {
                    stack.sync(self);
                    try self.concatenate(a, b);
                    stack.reload(self);
                } else {
                    stack.sync(self);
                    try self.errorAt(ip, "Operands must be two numbers or two strings.", .{});
                    return err.Error.RuntimeError;
                }
            },
            .Subtract => {
                const b = stack.peek(0);
                const a = stack.peek(1);
                if (!a.isNumber() or !b.isNumber()) {
                    stack.sync(self);
                    try self.errorAt(ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                }
                stack.popAndReplace(LoxValue.number(a.asNumber() - b.asNumber()));
            },
            .Multiply => {
                const b = stack.peek(0);
                const a = stack.peek(1);
                if (!a.isNumber() or !b.isNumber()) {
                    stack.sync(self);
                    try self.errorAt(ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                }
                stack.popAndReplace(LoxValue.number(a.asNumber() * b.asNumber()));
            },
            .Divide => {
                const b = stack.peek(0);
                const a = stack.peek(1);
                if (!a.isNumber() or !b.isNumber()) {
                    stack.sync(self);
                    try self.errorAt(ip, "Operands must be numbers.", .{});
                    return err.Error.RuntimeError;
                }
                const bn = b.asNumber();
                stack.popAndReplace(LoxValue.number(if (bn == 0) std.math.nan(f64) else a.asNumber() / bn));
            },
            .Print => {
                const value = stack.pop();
                try value.print(self.writer);
                try self.println();
            },
            .Pop => _ = stack.pop(),
            .Closure => {
                stack.sync(self);
                ip = try self.opClosure(&cursor, ip, Chunk.OPERAND_SHORT);
                stack.reload(self);
            },
            .ClosureLong => {
                stack.sync(self);
                ip = try self.opClosure(&cursor, ip, Chunk.OPERAND_LONG);
                stack.reload(self);
            },
            .Call => {
                const arg_count = Chunk.readByteAt(ip);
                ip += 1;
                cursor.frame.ip = ip;
                stack.sync(self);
                const value = stack.peek(arg_count);
                // Fast path: monomorphic closure calls (fib, etc.) — no error-union dance.
                if (value.isClosure()) {
                    const closure = value.asClosure();
                    if (closure.function.arity == arg_count and self.frame_count < FRAMES_MAX) {
                        _ = self.pushFrame(closure, arg_count);
                    } else if (!try self.call(ip, closure, arg_count)) {
                        try self.errorAt(ip, "Calling failed", .{});
                        return err.Error.RuntimeError;
                    }
                } else if (!try self.callValue(ip, value, arg_count)) {
                    try self.errorAt(ip, "Calling failed", .{});
                    return err.Error.RuntimeError;
                }
                stack.reload(self);
                cursor.reload(self);
                ip = cursor.frame.ip;
            },
            .Class => {
                stack.sync(self);
                try self.opClass(&cursor, ip, Chunk.OPERAND_SHORT);
                stack.reload(self);
                ip += Chunk.OPERAND_SHORT;
            },
            .ClassLong => {
                stack.sync(self);
                try self.opClass(&cursor, ip, Chunk.OPERAND_LONG);
                stack.reload(self);
                ip += Chunk.OPERAND_LONG;
            },
            .Inherit => {
                stack.sync(self);
                const sub_class = try (stack.peek(0)).tryClass();
                const super_class = (stack.peek(1)).tryClass() catch {
                    try self.errorAt(ip, "Superclass must be a class.", .{});
                    return err.Error.RuntimeError;
                };
                const old_capacity = sub_class.methods.capacity();
                try sub_class.methods.addAll(self.allocator, &super_class.methods);
                try self.adjustMapAllocation(old_capacity, sub_class.methods.capacity());
                stack.reload(self);
                _ = stack.pop();
            },
            .GetSuper => {
                stack.sync(self);
                try self.opGetSuper(&cursor, ip, Chunk.OPERAND_SHORT);
                stack.reload(self);
                ip += Chunk.OPERAND_SHORT;
            },
            .GetSuperLong => {
                stack.sync(self);
                try self.opGetSuper(&cursor, ip, Chunk.OPERAND_LONG);
                stack.reload(self);
                ip += Chunk.OPERAND_LONG;
            },
            .GetProperty => {
                stack.sync(self);
                try self.opGetProperty(&cursor, ip, Chunk.OPERAND_SHORT);
                stack.reload(self);
                ip += Chunk.OPERAND_SHORT;
            },
            .GetPropertyLong => {
                stack.sync(self);
                try self.opGetProperty(&cursor, ip, Chunk.OPERAND_LONG);
                stack.reload(self);
                ip += Chunk.OPERAND_LONG;
            },
            .Invoke => {
                stack.sync(self);
                try self.opInvoke(&cursor, ip, Chunk.OPERAND_SHORT);
                stack.reload(self);
                ip = cursor.frame.ip;
            },
            .InvokeLong => {
                stack.sync(self);
                try self.opInvoke(&cursor, ip, Chunk.OPERAND_LONG);
                stack.reload(self);
                ip = cursor.frame.ip;
            },
            .SuperInvoke => {
                stack.sync(self);
                try self.opSuperInvoke(&cursor, ip, Chunk.OPERAND_SHORT);
                stack.reload(self);
                ip = cursor.frame.ip;
            },
            .SuperInvokeLong => {
                stack.sync(self);
                try self.opSuperInvoke(&cursor, ip, Chunk.OPERAND_LONG);
                stack.reload(self);
                ip = cursor.frame.ip;
            },
            .SetProperty => {
                stack.sync(self);
                try self.opSetProperty(&cursor, ip, Chunk.OPERAND_SHORT);
                stack.reload(self);
                ip += Chunk.OPERAND_SHORT;
            },
            .SetPropertyLong => {
                stack.sync(self);
                try self.opSetProperty(&cursor, ip, Chunk.OPERAND_LONG);
                stack.reload(self);
                ip += Chunk.OPERAND_LONG;
            },
            .Method => {
                stack.sync(self);
                try self.opMethod(&cursor, ip, Chunk.OPERAND_SHORT);
                stack.reload(self);
                ip += Chunk.OPERAND_SHORT;
            },
            .MethodLong => {
                stack.sync(self);
                try self.opMethod(&cursor, ip, Chunk.OPERAND_LONG);
                stack.reload(self);
                ip += Chunk.OPERAND_LONG;
            },
            .Return => {
                const result = if (@intFromPtr(stack.top) > @intFromPtr(stack.base())) stack.pop() else LoxValue.nil;

                if (self.open_upvalues != null) {
                    self.closeUpvalues(@ptrCast(cursor.frame.slots));
                }

                self.frame_count -= 1;
                if (self.frame_count == 0) {
                    stack.sync(self);
                    return;
                }

                stack.top = cursor.frame.slots;
                stack.pushUnchecked(result);
                cursor.returnToCaller();
                ip = cursor.frame.ip;
            },
            .CloseUpvalue => {
                self.closeUpvalues(@ptrCast(stack.top - 1));
                _ = stack.pop();
            },
        }
    }
}

/// `a` and `b` are the two strings on top of the stack; replaces them with
/// their concatenation. The stack must be synced: interning can collect.
fn concatenate(self: *VM, a: LoxValue, b: LoxValue) !void {
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
        return;
    }
    const result = try std.mem.concat(self.allocator, u8, &[_][]const u8{ as, bs });
    const hash = tbl.hashString(result);
    const heap_str = if (self.strings.findString(result, hash)) |existing| blk: {
        self.allocator.free(result);
        break :blk existing;
    } else try self.takeString(result, hash);
    try self.push(LoxValue.string(heap_str));
}

inline fn defineGlobal(self: *VM, cursor: *const FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);
    const value = self.peek(0);
    _ = try self.setTrackedTable(&self.globals, name, value);
    _ = self.pop();
}

inline fn getGlobal(self: *VM, stack: *StackCursor, cursor: *const FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);
    const constant_value = self.globals.get(name) orelse {
        stack.sync(self);
        try self.errorAt(ip, "Undefined variable '{s}'.", .{name.data});
        return err.Error.RuntimeError;
    };
    try stack.push(self, constant_value);
}

inline fn setGlobal(self: *VM, stack: *StackCursor, cursor: *const FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);
    if (!self.globals.setExisting(name, stack.peek(0))) {
        stack.sync(self);
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

    if (self.compiler) |*compiler| {
        try compiler.markRoots(&self.heap);
    }
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

    try std.testing.expect(virtual_machine.globals.capacity() > 0);
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
