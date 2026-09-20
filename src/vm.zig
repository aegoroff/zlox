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
/// An `OP_CLOSURE` operand pair: where the upvalue comes from, and its index.
const UPVALUE_OPERAND_SIZE: usize = 2;

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
/// Null only during `init`, before the "init" string is interned. A GC
/// triggered by that first intern must not mark a still-undefined pointer,
/// so this stays optional rather than `undefined` even though every other
/// caller sees it always set.
init_string: ?*val.HeapString,
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
        .init_string = null,
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
    // A runtime error stops without unwinding, so a failed call can leave
    // frame_count and stack_top past where it broke off - callers rely on
    // that to still be there right after the failing call (see the
    // frame-count assertions in vm_test.zig), so the cleanup happens here,
    // before the next script starts, rather than where the error occurred.
    // A no-op after a successful run, which already leaves both at their
    // initial values.
    self.resetStack();

    // A prior call's compiler stays alive through `run()` so `errorAt` can
    // still reach it, but nothing keeps it around after that: overwriting
    // `self.compiler` below without freeing it first leaks its reporter and
    // script `Compile` struct on every call after the first.
    if (self.compiler) |*previous| {
        previous.deinit();
    }
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

    const closure_ptr = try self.heap.alloc(val.Closure);
    closure_ptr.* = try val.Closure.init(self.allocator, func);
    try self.push(LoxValue.closure(closure_ptr));
    try self.trackObject(.{ .closure = closure_ptr }, closure_ptr.size());
    const script_ip = closure_ptr.function.chunk.code.items.ptr;
    try self.call(script_ip, closure_ptr, 0);
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

/// Wraps `owned` in a heap string and hands both to the heap. The buffer is
/// the caller's until the registration goes through, so a failure on the way
/// there releases it: nothing else knows about it yet. Its own scope ends at
/// the registration, which is what keeps the release from running once the
/// heap owns the bytes and would free them a second time at `deinit`.
fn allocString(self: *VM, owned: []u8, hash: u32) !*val.HeapString {
    errdefer self.allocator.free(owned);
    const heap_str = try self.heap.alloc(val.HeapString);
    heap_str.* = .{ .gc = .{ .kind = .string }, .hash = hash, .data = owned };
    try self.heap.trackObject(.{ .string = heap_str }, @sizeOf(val.HeapString) + owned.len);
    return heap_str;
}

fn takeString(self: *VM, owned: []u8, hash: u32) !*val.HeapString {
    // Registration goes in before the push and before the intern-table insert,
    // which grows the table and is therefore a collection point. A collection
    // reached with the string on the stack but missing from the heap's object
    // list marks it and then cannot unmark it - only listed objects are swept -
    // so it would join the list already black. `markObject` skips an object
    // that is already marked, so from then on nothing it points at would be
    // blackened again. Registering first costs nothing: it is a plain list
    // insert that never collects, and the collection it makes due is taken
    // once the insert is accounted for.
    const heap_str = try self.allocString(owned, hash);
    try self.push(LoxValue.string(heap_str));
    errdefer _ = self.pop();
    _ = try self.setTrackedTable(&self.strings, heap_str, LoxValue.nil);
    if (self.heap.shouldCollect()) {
        try self.collectGarbage();
    }
    _ = self.pop();
    return heap_str;
}

fn defineNative(self: *VM, name: []const u8, function: val.NativeFn) !void {
    const key = try self.internString(name);
    _ = try self.setTrackedTable(&self.globals, key, LoxValue.native(function));
}

/// Reports a stack overflow at `ip` and fails. The instruction has to be
/// handed in: the dispatch loop keeps the live one in a register and writes it
/// back to the frame only at a call, so the frame's own copy names whatever was
/// called last rather than the push that ran out of room. A null `ip` belongs
/// to the pushes that happen with no frame running - interning during a
/// compile, and the script closure - which have no instruction to point at.
fn stackOverflowError(self: *VM, ip: ?[*]const u8) !void {
    if (ip) |at| {
        try self.errorAt(at, "Stack overflow.", .{});
    }
    return err.Error.RuntimeError;
}

inline fn stackLimit(self: *const VM) [*]LoxValue {
    return self.stack.ptr + STACK_MAX;
}

inline fn stackCount(self: *const VM) usize {
    return (@intFromPtr(self.stack_top) - @intFromPtr(self.stack.ptr)) / @sizeOf(LoxValue);
}

/// For pushes with no instruction to blame: every caller either runs with no
/// frame yet or pushes into a slot it has just freed, so the overflow branch
/// reports without a location. Handlers inside the dispatch loop use `pushAt`.
inline fn push(self: *VM, value: LoxValue) !void {
    return self.pushAt(null, value);
}

inline fn pushAt(self: *VM, ip: ?[*]const u8, value: LoxValue) !void {
    if (@intFromPtr(self.stack_top) >= @intFromPtr(self.stackLimit())) {
        @branchHint(.unlikely);
        return self.stackOverflowError(ip);
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

/// Pushes a frame for `closure`, or reports why it cannot and fails. There is
/// no third outcome: a call either happens or raises, never comes back to be
/// asked what went wrong.
inline fn call(self: *VM, ip: [*]const u8, closure: *val.Closure, arg_count: usize) anyerror!void {
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

inline fn invokeFromClass(self: *VM, ip: [*]const u8, klass: *val.Class, name: *val.HeapString, arg_count: usize) anyerror!void {
    if (klass.methods.get(name)) |method| {
        return self.call(ip, method.asClosure(), arg_count);
    }
    try self.errorAt(ip, "Undefined property '{s}'.", .{name.data});
    return err.Error.RuntimeError;
}

inline fn invoke(self: *VM, ip: [*]const u8, name: *val.HeapString, arg_count: usize) anyerror!void {
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

inline fn callValue(self: *VM, ip: [*]const u8, value: LoxValue, arg_count: usize) anyerror!void {
    if (value.isClosure()) {
        return self.call(ip, value.asClosure(), arg_count);
    }
    if (value.isClass()) {
        const k = value.asClass();
        const instance_ptr = try self.heap.alloc(val.Instance);
        instance_ptr.* = val.Instance.init(k);
        self.peekSlot(arg_count).* = LoxValue.instance(instance_ptr);
        try self.trackObject(.{ .instance = instance_ptr }, instance_ptr.size());
        if (instance_ptr.klass.methods.get(self.init_string.?)) |in| {
            return self.call(ip, in.asClosure(), arg_count);
        } else if (arg_count != 0) {
            try self.errorAt(ip, "Expected 0 arguments but got {d}.", .{arg_count});
            return err.Error.RuntimeError;
        }
        return;
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
        switch (native_fn(self.io, args)) {
            .value => |result| {
                self.stack_top -= arg_count + 1;
                return self.push(result);
            },
            .failure => |message| {
                try self.errorAt(ip, "{s}", .{message});
                return err.Error.RuntimeError;
            },
        }
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

    const created = try self.heap.alloc(val.Upvalue);
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

/// Restores the stack and call frames to the state a fresh VM starts in.
/// Any upvalue still open into the stack is closed first, copying its value
/// out, so a closure that outlived the discarded run keeps that value
/// instead of a pointer into stack slots the next run is about to reuse.
fn resetStack(self: *VM) void {
    self.closeUpvalues(@ptrCast(self.stack.ptr));
    self.stack_top = self.stack.ptr;
    self.frame_count = 0;
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

        const bound_ptr = try self.heap.alloc(val.BoundMethod);
        bound_ptr.* = val.BoundMethod.init(instance, method);
        try self.push(LoxValue.boundMethod(bound_ptr));
        try self.trackObject(.{ .bound_method = bound_ptr }, @sizeOf(val.BoundMethod));
        return true;
    }
    return false;
}

/// Source span of the instruction `ip` points into. The dispatch loop steps
/// past the opcode before the handler runs, and a frame that is waiting on a
/// call has its `ip` just past that call, so one byte back lands inside the
/// instruction in either case. Every byte of an instruction carries the same
/// position, so which byte it lands on does not matter.
fn positionAt(chunk_ptr: *const Chunk, ip: [*]const u8) Chunk.Position {
    const reached = chunk_ptr.offsetOf(ip);
    const offset = if (reached > 0) reached - 1 else 0;
    return chunk_ptr.positions.items[offset];
}

/// One frame of the Lox call stack: where it stopped, and whose frame it is.
pub const TraceFrame = struct {
    position: Chunk.Position,
    /// The compiled function's name, or null for the top-level script.
    name: ?[]const u8,
};

/// Writes the Lox call stack into `buf`, innermost frame first, and returns
/// the part of it that was filled. Meaningful while the VM is stopped on a
/// runtime error: `errorAt` puts the running frame's instruction pointer back
/// before anything reads the frames, and a runtime error stops without
/// unwinding, so the frames stay until the next `interpret` resets the stack.
pub fn callStack(self: *const VM, buf: []TraceFrame) []TraceFrame {
    var count: usize = 0;
    var i = self.frame_count;
    while (i > 0 and count < buf.len) {
        i -= 1;
        const function = self.frames[i].closure.function;
        buf[count] = .{
            .position = positionAt(&function.chunk, self.frames[i].ip),
            .name = function.name,
        };
        count += 1;
    }
    return buf[0..count];
}

// The reporter dims the source lines around a diagnostic; the trace under it
// is subordinate to the same diagnostic, so it is dimmed to match.
const dim = "\x1b[2m";
const reset_color = "\x1b[0m";

/// Prints the Lox call stack under the diagnostic, innermost frame first. It
/// goes to stderr through `std.debug.print`, which is where the reporter puts
/// the diagnostic it follows. A single frame gets none: with the script alone
/// the snippet above already says everything one more line could.
fn printCallStack(self: *const VM, trace: []const TraceFrame) void {
    // Skipped while fuzzing for the reason `reportErrorAt` gives: the runner
    // keeps every stderr byte, and a runaway recursion prints a line per frame.
    if (@import("builtin").fuzz) return;
    if (trace.len < 2) return;
    const filename = self.compiler.?.filename;
    std.debug.print("  {s}stack:{s}\n", .{ dim, reset_color });
    for (trace) |entry| {
        std.debug.print("  {s}  {s}:{d}:{d} in ", .{ dim, filename, entry.position.line, entry.position.col });
        if (entry.name) |name| {
            std.debug.print("{s}(){s}\n", .{ name, reset_color });
        } else {
            std.debug.print("script{s}\n", .{reset_color});
        }
    }
}

fn errorAt(self: *VM, ip: [*]const u8, comptime fmt: []const u8, args: anytype) !void {
    if (self.frame_count == 0) return;
    // The dispatch loop keeps the live instruction pointer in a register and
    // writes it back only at a call, so the running frame's copy is stale.
    // Putting it back first means every frame describes where it stopped, for
    // the trace below and for anything that inspects the stopped VM.
    self.frames[self.frame_count - 1].ip = ip;

    var buf: [FRAMES_MAX]TraceFrame = undefined;
    const trace = self.callStack(&buf);
    const position = trace[0].position;
    const message = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(message);
    // Widened before the arithmetic: `Position` stores the column and the
    // length in sixteen bits and saturates both, so a token whose span reaches
    // past column 65535 - a long string literal, or anything on a generated
    // line that long - overflows the sum in sixteen-bit arithmetic.
    const span = @max(@as(usize, position.len), 1);
    const col_end = @as(usize, position.col) + span - 1;
    try self.compiler.?.reportErrorAt(position.line, position.col, position.line, col_end, message);
    self.printCallStack(trace);
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

fn opClosure(self: *VM, cursor: *FrameCursor, ip: [*]const u8, constant_size: usize) ![*]const u8 {
    const function = cursor.constantAt(ip, constant_size).asFunction();
    const operands = ip + constant_size;
    const closure_ptr = try self.makeClosure(cursor, ip, operands, function);
    try self.trackObject(.{ .closure = closure_ptr }, closure_ptr.size());
    return operands + UPVALUE_OPERAND_SIZE * function.upvalue_count;
}

/// Builds the closure and leaves it on the stack for the caller to register.
///
/// The upvalue array is filled before the closure is pushed or registered: it
/// comes back from the allocator uninitialized, and a collection that reached a
/// closure holding it would walk those bytes as pointers. Capturing can collect —
/// `captureUpvalue` registers what it creates — but nothing the loop needs can be
/// swept while it runs. The closure is not in the heap's object list yet, so
/// the sweep cannot see it; its function is a constant of the running one; every
/// upvalue captured here is already on the open list, which `markRoots` walks;
/// and every upvalue inherited from the enclosing closure is held by a frame.
///
/// The array is the closure's own memory, and until the registration nothing
/// else knows about it, so a failure before then - a capture, or a stack with
/// no room for the push - releases it here. The scope ends at the return,
/// which keeps the release off a closure the heap already owns: registering is
/// a collection point, and a collection that fails there would otherwise leave
/// a listed closure whose upvalues have been freed under it.
fn makeClosure(self: *VM, cursor: *const FrameCursor, ip: [*]const u8, operands: [*]const u8, function: *val.Function) !*val.Closure {
    const closure_ptr = try self.heap.alloc(val.Closure);
    closure_ptr.* = try val.Closure.init(self.allocator, function);
    errdefer closure_ptr.deinit(self.allocator);

    var next = operands;
    for (0..function.upvalue_count) |i| {
        const is_local = Chunk.readByteAt(next);
        const index = Chunk.readByteAt(next + 1);
        next += UPVALUE_OPERAND_SIZE;
        closure_ptr.upvalues[i] = if (is_local == 1)
            try self.captureUpvalue(@ptrCast(cursor.frame.slots + index))
        else
            cursor.frame.closure.upvalues[index];
    }

    try self.pushAt(ip, LoxValue.closure(closure_ptr));
    return closure_ptr;
}

fn opClass(self: *VM, cursor: *const FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);

    const class_ptr = try self.heap.alloc(val.Class);
    class_ptr.* = val.Class.init(name);
    try self.pushAt(ip, LoxValue.class(class_ptr));
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
    try self.invoke(next, name, arg_count);
    cursor.reload(self);
}

inline fn opSuperInvoke(self: *VM, cursor: *FrameCursor, ip: [*]const u8, constant_size: usize) !void {
    const name = try cursor.stringConstantAt(ip, constant_size);
    const arg_count = Chunk.readByteAt(ip + constant_size);
    const next = ip + constant_size + 1;
    cursor.frame.ip = next;
    const super_class = try (self.pop()).tryClass();

    try self.invokeFromClass(next, super_class, name, arg_count);
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

    inline fn push(self: *StackCursor, vm: *VM, ip: [*]const u8, value: LoxValue) !void {
        if (@intFromPtr(self.top) >= @intFromPtr(self.limit)) {
            @branchHint(.unlikely);
            self.sync(vm);
            return vm.stackOverflowError(ip);
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
                try stack.push(self, ip, cursor.constantAt(ip, Chunk.OPERAND_SHORT));
                ip += Chunk.OPERAND_SHORT;
            },
            .ConstantLong => {
                try stack.push(self, ip, cursor.constantAt(ip, Chunk.OPERAND_LONG));
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
                try stack.push(self, ip, cursor.frame.slots[slot]);
            },
            .GetLocalLong => {
                const slot = Chunk.readThreeBytesAt(ip);
                ip += Chunk.OPERAND_LONG;
                try stack.push(self, ip, cursor.frame.slots[slot]);
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
                try stack.push(self, ip, cursor.frame.closure.upvalues[slot].get());
            },
            .SetUpvalue => {
                const slot = Chunk.readByteAt(ip);
                ip += 1;
                cursor.frame.closure.upvalues[slot].set(stack.peek(0));
            },
            .Nil => try stack.push(self, ip, LoxValue.nil),
            .True => try stack.push(self, ip, LoxValue.boolean(true)),
            .False => try stack.push(self, ip, LoxValue.boolean(false)),
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
                stack.popAndReplace(LoxValue.number(a.asNumber() / b.asNumber()));
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
                    } else {
                        try self.call(ip, closure, arg_count);
                    }
                } else {
                    try self.callValue(ip, value, arg_count);
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
    try stack.push(self, ip, constant_value);
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

    if (self.init_string) |s| {
        try self.heap.markObject(.{ .string = s });
    }

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

test "compiled functions carry no constant lookup into execution" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtual_machine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtual_machine.deinit();

    // Act: a script, a nested function and a method, each with constants of
    // its own.
    const code =
        \\fun outer() { var a = "first value"; fun inner() { return a; } return inner; }
        \\class Greeter { greet() { return "third value"; } }
        \\print outer()();
    ;
    try virtual_machine.interpret(code, false);

    // Assert: nothing reaches execution still holding the map `addConstant`
    // dedupes through - the indexes it produced are in the bytecode by then.
    var seen: usize = 0;
    var current = virtual_machine.heap.objects;
    while (current) |obj| : (current = obj.next) {
        if (obj.kind != .function) continue;
        const func: *val.Function = @fieldParentPtr("gc", obj);
        try std.testing.expectEqual(@as(usize, 0), func.chunk.constant_lookup.capacity());
        seen += 1;
    }
    // script, outer, inner and greet at the least.
    try std.testing.expect(seen >= 4);
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
    try std.testing.expect(virtual_machine.strings.findString("init", virtual_machine.init_string.?.hash) != null);
}

test "a failed heap allocation drops the interned string's bytes" {
    // Arrange: a VM whose next allocation but one fails, with the pool left
    // without room so that the string header has to carve a fresh block - the
    // copy of the name goes through, the allocation right after it does not.
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var virtual_machine = try init(failing.allocator(), &writer.writer, std.testing.io);
    defer virtual_machine.deinit();
    virtual_machine.heap.pool.left = 0;
    failing.fail_index = failing.alloc_index + 1;

    // Act
    const interned = virtual_machine.internString("never interned before");

    // Assert: the failure surfaces, and the copy the VM made of the name is
    // released - the testing allocator reports it as a leak otherwise.
    try std.testing.expectError(error.OutOfMemory, interned);
}

test "interning a string across a collection leaves it white" {
    // Arrange: collect at every tracked allocation, so the growth of the
    // string pool inside `takeString` is itself a collection point.
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtual_machine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtual_machine.deinit();
    virtual_machine.heap.next_gc = 0;

    // Act: enough strings to grow the pool several times.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "interned_string_{d}", .{i});
        _ = try virtual_machine.internString(name);
    }

    // Assert: no object stays black between collections. One that does is
    // skipped by `markObject` forever after, and nothing it points at would
    // ever be blackened again.
    var current = virtual_machine.heap.objects;
    while (current) |obj| : (current = obj.next) {
        try std.testing.expect(!obj.marked);
    }
}

test "collecting garbage before init_string is set does not mark a garbage pointer" {
    // Arrange: reproduces the state `init` is in while interning "init" itself,
    // before `vm.init_string` has been assigned.
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtual_machine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtual_machine.deinit();
    virtual_machine.init_string = null;

    // Act & Assert: markRoots must skip the unset field instead of marking
    // whatever it would otherwise point at.
    try virtual_machine.collectGarbage();
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
