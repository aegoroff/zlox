const std = @import("std");
const err = @import("error.zig");
const Chunk = @import("chunk.zig");
const tbl = @import("table.zig");
const Table = tbl.Table;
const TableEntry = tbl.Entry;

const SIGN_BIT: u64 = 0x8000000000000000;
const QNAN: u64 = 0x7ffc000000000000;
const TAG_NIL: u64 = 1;
const TAG_FALSE: u64 = 2;
const TAG_TRUE: u64 = 3;
const BOXED_MASK: u64 = SIGN_BIT | QNAN;
const PTR_TYPE_MASK: u64 = 0x7;
const PTR_MASK: u64 = 0x0000_ffff_ffff_fff8;

pub const SHORT_STRING_MAX_LEN: usize = 5;

const ObjTag = enum(u4) {
    string = 0,
    function = 1,
    closure = 2,
    class = 3,
    instance = 4,
    bound_method = 5,
    native = 6,
    short_string = 7,
};

pub const NativeFn = *const fn (io: std.Io, args: []const LoxValue) err.Error!LoxValue;

pub const LoxValue = struct {
    raw: u64,

    pub const nil: LoxValue = .{ .raw = QNAN | TAG_NIL };

    pub inline fn boolean(b: bool) LoxValue {
        return .{ .raw = if (b) QNAN | TAG_TRUE else QNAN | TAG_FALSE };
    }

    pub inline fn number(n: f64) LoxValue {
        return .{ .raw = @as(u64, @bitCast(n)) };
    }

    pub inline fn shortString(bytes: []const u8) LoxValue {
        std.debug.assert(bytes.len <= SHORT_STRING_MAX_LEN);
        var payload: u64 = @intFromEnum(ObjTag.short_string);
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            payload |= @as(u64, bytes[i]) << @intCast(7 + i * 8);
        }
        payload |= @as(u64, bytes.len) << 3;
        return .{ .raw = BOXED_MASK | payload };
    }

    pub inline fn string(s: *HeapString) LoxValue {
        return fromTaggedPtr(.string, s);
    }

    pub inline fn function(f: *Function) LoxValue {
        return fromTaggedPtr(.function, f);
    }

    pub inline fn closure(c: *Closure) LoxValue {
        return fromTaggedPtr(.closure, c);
    }

    pub inline fn class(c: *Class) LoxValue {
        return fromTaggedPtr(.class, c);
    }

    pub inline fn instance(i: *Instance) LoxValue {
        return fromTaggedPtr(.instance, i);
    }

    pub inline fn boundMethod(b: *BoundMethod) LoxValue {
        return fromTaggedPtr(.bound_method, b);
    }

    pub inline fn native(n: NativeFn) LoxValue {
        return fromTaggedPtr(.native, @constCast(n));
    }

    pub inline fn isNil(self: LoxValue) bool {
        return self.raw == QNAN | TAG_NIL;
    }

    pub inline fn isBool(self: LoxValue) bool {
        if (self.isNil()) return false;
        return (self.raw | 1) == QNAN | TAG_TRUE;
    }

    pub inline fn isNumber(self: LoxValue) bool {
        return (self.raw & QNAN) != QNAN;
    }

    pub inline fn isBoxed(self: LoxValue) bool {
        if (self.isNumber()) return false;
        return (self.raw & BOXED_MASK) == BOXED_MASK;
    }

    pub inline fn isHeapString(self: LoxValue) bool {
        return isBoxed(self) and objTag(self) == .string;
    }

    pub inline fn isShortString(self: LoxValue) bool {
        return isBoxed(self) and objTag(self) == .short_string;
    }

    pub inline fn isString(self: LoxValue) bool {
        return self.isHeapString() or self.isShortString();
    }

    pub inline fn isFunction(self: LoxValue) bool {
        return isBoxed(self) and objTag(self) == .function;
    }

    pub inline fn isClosure(self: LoxValue) bool {
        return isBoxed(self) and objTag(self) == .closure;
    }

    pub inline fn isClass(self: LoxValue) bool {
        return isBoxed(self) and objTag(self) == .class;
    }

    pub inline fn isInstance(self: LoxValue) bool {
        return isBoxed(self) and objTag(self) == .instance;
    }

    pub inline fn isBoundMethod(self: LoxValue) bool {
        return isBoxed(self) and objTag(self) == .bound_method;
    }

    pub inline fn isNative(self: LoxValue) bool {
        return isBoxed(self) and objTag(self) == .native;
    }

    pub inline fn asBool(self: LoxValue) bool {
        return self.raw == QNAN | TAG_TRUE;
    }

    pub inline fn asNumber(self: LoxValue) f64 {
        return @bitCast(self.raw);
    }

    pub inline fn asString(self: LoxValue) *HeapString {
        return @ptrCast(@alignCast(decodePtr(.string, self)));
    }

    pub inline fn shortStringLen(self: LoxValue) usize {
        std.debug.assert(self.isShortString());
        return @intCast((self.raw >> 3) & 0xF);
    }

    pub fn shortStringChars(self: LoxValue, buf: *[SHORT_STRING_MAX_LEN]u8) []const u8 {
        const len = self.shortStringLen();
        var i: usize = 0;
        while (i < len) : (i += 1) {
            buf[i] = @intCast((self.raw >> @intCast(7 + i * 8)) & 0xFF);
        }
        return buf[0..len];
    }

    pub fn stringBytes(self: LoxValue, storage: *[SHORT_STRING_MAX_LEN]u8) []const u8 {
        if (self.isShortString()) return self.shortStringChars(storage);
        return self.asString().data;
    }

    pub fn stringLen(self: LoxValue) usize {
        if (self.isShortString()) return self.shortStringLen();
        return self.asString().data.len;
    }

    pub fn stringsEqual(a: LoxValue, b: LoxValue) bool {
        var buf_a: [SHORT_STRING_MAX_LEN]u8 = undefined;
        var buf_b: [SHORT_STRING_MAX_LEN]u8 = undefined;
        const as = a.stringBytes(&buf_a);
        const bs = b.stringBytes(&buf_b);
        return std.mem.eql(u8, as, bs);
    }

    pub fn stringsLess(a: LoxValue, b: LoxValue) bool {
        var buf_a: [SHORT_STRING_MAX_LEN]u8 = undefined;
        var buf_b: [SHORT_STRING_MAX_LEN]u8 = undefined;
        const as = a.stringBytes(&buf_a);
        const bs = b.stringBytes(&buf_b);
        return std.mem.lessThan(u8, as, bs);
    }

    pub inline fn asFunction(self: LoxValue) *Function {
        return @ptrCast(@alignCast(decodePtr(.function, self)));
    }

    pub inline fn asClosure(self: LoxValue) *Closure {
        return @ptrCast(@alignCast(decodePtr(.closure, self)));
    }

    pub inline fn asClass(self: LoxValue) *Class {
        return @ptrCast(@alignCast(decodePtr(.class, self)));
    }

    pub inline fn asInstance(self: LoxValue) *Instance {
        return @ptrCast(@alignCast(decodePtr(.instance, self)));
    }

    pub inline fn asBoundMethod(self: LoxValue) *BoundMethod {
        return @ptrCast(@alignCast(decodePtr(.bound_method, self)));
    }

    pub inline fn asNative(self: LoxValue) NativeFn {
        return @ptrCast(@alignCast(decodePtr(.native, self)));
    }

    pub fn print(self: LoxValue, writer: *std.Io.Writer) !void {
        if (self.isNil()) {
            try writer.print("nil", .{});
        } else if (self.isBool()) {
            try writer.print("{}", .{self.asBool()});
        } else if (self.isNumber()) {
            const n = self.asNumber();
            if (std.math.isNan(n)) {
                try writer.print("NaN", .{});
            } else {
                try writer.print("{d}", .{n});
            }
        } else if (self.isString()) {
            var buf: [SHORT_STRING_MAX_LEN]u8 = undefined;
            try writer.print("{s}", .{self.stringBytes(&buf)});
        } else if (self.isFunction()) {
            const f = self.asFunction();
            try writer.print("<{s}>", .{f.name orelse "script"});
        } else if (self.isClass()) {
            try writer.print("{s}", .{self.asClass().name.data});
        } else if (self.isInstance()) {
            const inst = self.asInstance();
            try writer.print("{s} instance", .{inst.klass.name.data});
        } else if (self.isBoundMethod()) {
            const b = self.asBoundMethod();
            try writer.print("<fn {s}>", .{b.method.asClosure().function.name orelse "script"});
        } else if (self.isClosure()) {
            const cl = self.asClosure();
            try writer.print("<fn {s}>", .{cl.function.name orelse "script"});
        } else if (self.isNative()) {
            try writer.print("<native fn>", .{});
        }
    }

    pub fn tryNumber(self: LoxValue) err.Error!f64 {
        if (!self.isNumber()) return err.Error.RuntimeError;
        return self.asNumber();
    }

    pub fn tryString(self: LoxValue, storage: *[SHORT_STRING_MAX_LEN]u8) err.Error![]const u8 {
        if (!self.isString()) return err.Error.RuntimeError;
        return self.stringBytes(storage);
    }

    pub fn tryInstance(self: LoxValue) err.Error!*Instance {
        if (!self.isInstance()) return err.Error.RuntimeError;
        return self.asInstance();
    }

    pub fn tryClass(self: LoxValue) err.Error!*Class {
        if (!self.isClass()) return err.Error.RuntimeError;
        return self.asClass();
    }

    pub fn tryClosure(self: LoxValue) err.Error!*Closure {
        if (!self.isClosure()) return err.Error.RuntimeError;
        return self.asClosure();
    }

    pub inline fn isFalsee(self: LoxValue) bool {
        if (self.isNil()) return true;
        if (self.isBool()) return !self.asBool();
        return false;
    }

    pub inline fn equal(self: LoxValue, other: LoxValue) bool {
        // Match clox (NAN_BOXING): IEEE equality for numbers (NaN != NaN, +0 == -0).
        if (self.isNumber() and other.isNumber()) {
            return self.asNumber() == other.asNumber();
        }
        // Same bit pattern ⇒ equal (nil/bool/short string/interned heap ptr).
        if (self.raw == other.raw) return true;
        // Short ↔ heap string with the same characters.
        if (self.isString() and other.isString()) {
            return stringsEqual(self, other);
        }
        return false;
    }

    pub fn less(self: LoxValue, other: LoxValue) err.Error!bool {
        if (self.isNumber() and other.isNumber()) {
            const l = self.asNumber();
            const r = other.asNumber();
            if (std.math.isNan(l) or std.math.isNan(r)) return false;
            return l < r;
        }
        if (self.isString() and other.isString()) {
            return stringsLess(self, other);
        }
        if (self.isBool() and other.isBool()) {
            return !self.asBool() and other.asBool();
        }
        return err.Error.RuntimeError;
    }

    pub inline fn greaterThan(self: LoxValue, other: LoxValue) err.Error!bool {
        const lt = try self.less(other);
        return !lt and !self.equal(other);
    }

    inline fn fromTaggedPtr(comptime tag: ObjTag, ptr: anytype) LoxValue {
        const addr: u64 = @intFromPtr(ptr) & PTR_MASK;
        return .{ .raw = BOXED_MASK | (@as(u64, @intFromEnum(tag))) | addr };
    }

    inline fn objTag(self: LoxValue) ObjTag {
        return @enumFromInt(self.raw & PTR_TYPE_MASK);
    }

    inline fn decodePtr(comptime tag: ObjTag, self: LoxValue) *anyopaque {
        std.debug.assert(isBoxed(self) and objTag(self) == tag);
        return @ptrFromInt(self.raw & PTR_MASK);
    }
};

pub const ObjKind = enum {
    string,
    upvalue,
    closure,
    class,
    instance,
    bound_method,
    function,
};

pub const Obj = struct {
    next: ?*Obj = null,
    marked: bool = false,
    kind: ObjKind,
};

pub const HeapString = struct {
    gc: Obj,
    hash: u32 = 0,
    data: []const u8,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !*HeapString {
        const self = try allocator.create(HeapString);
        self.* = .{ .gc = .{ .kind = .string }, .data = bytes };
        return self;
    }

    pub fn size(self: *const HeapString) usize {
        return @sizeOf(HeapString) + self.data.len;
    }
};

pub const Upvalue = struct {
    gc: Obj,
    location: *LoxValue,
    closed: LoxValue = LoxValue.nil,
    next: ?*Upvalue = null,

    pub inline fn get(self: *const Upvalue) LoxValue {
        return self.location.*;
    }

    pub inline fn set(self: *Upvalue, val: LoxValue) void {
        self.location.* = val;
    }

    pub inline fn close(self: *Upvalue) void {
        self.closed = self.location.*;
        self.location = &self.closed;
    }

    pub inline fn isClosed(self: *const Upvalue) bool {
        return self.location == &self.closed;
    }
};

pub const Function = struct {
    gc: Obj,
    arity: usize,
    chunk: Chunk,
    name: ?[]const u8,
    upvalue_count: usize,

    pub fn init(gpa: std.mem.Allocator, name: ?[]const u8) Function {
        return .{
            .gc = .{ .kind = .function },
            .arity = 0,
            .chunk = Chunk.init(gpa),
            .name = name,
            .upvalue_count = 0,
        };
    }

    pub fn deinit(self: *Function) void {
        self.chunk.deinit();
    }

    pub fn size(self: *const Function) usize {
        return @sizeOf(Function) +
            self.chunk.code.items.len +
            self.chunk.constants.items.len * @sizeOf(LoxValue) +
            self.chunk.lines.items.len * @sizeOf(usize);
    }
};

pub const Closure = struct {
    gc: Obj,
    function: *Function,
    upvalues: []*Upvalue,
    upvalue_count: usize,

    pub fn init(allocator: std.mem.Allocator, function: *Function) !Closure {
        const upvalues = try allocator.alloc(*Upvalue, function.upvalue_count);
        return .{
            .gc = .{ .kind = .closure },
            .function = function,
            .upvalues = upvalues,
            .upvalue_count = function.upvalue_count,
        };
    }

    pub fn deinit(self: *Closure, allocator: std.mem.Allocator) void {
        if (self.upvalues.len > 0) {
            allocator.free(self.upvalues);
            self.upvalues = &.{};
        }
    }

    pub fn size(self: *const Closure) usize {
        return @sizeOf(Closure) + self.upvalue_count * @sizeOf(*Upvalue);
    }
};

pub const Class = struct {
    gc: Obj,
    name: *HeapString,
    methods: Table,

    pub fn init(gpa: std.mem.Allocator, name: *HeapString) Class {
        return .{
            .gc = .{ .kind = .class },
            .name = name,
            .methods = Table.init(gpa),
        };
    }

    pub fn deinit(self: *Class) void {
        self.methods.deinit();
    }

    pub fn size(self: *const Class) usize {
        return @sizeOf(Class) + self.methods.capacity * @sizeOf(TableEntry);
    }
};

pub const Instance = struct {
    gc: Obj,
    klass: *Class,
    fields: Table,

    pub fn init(gpa: std.mem.Allocator, klass: *Class) Instance {
        return .{
            .gc = .{ .kind = .instance },
            .klass = klass,
            .fields = Table.init(gpa),
        };
    }

    pub fn deinit(self: *Instance) void {
        self.fields.deinit();
    }

    pub fn size(self: *const Instance) usize {
        return @sizeOf(Instance) + self.fields.capacity * @sizeOf(TableEntry);
    }
};

pub const BoundMethod = struct {
    gc: Obj,
    receiver: *Instance,
    method: LoxValue,

    pub fn init(receiver: *Instance, method: LoxValue) BoundMethod {
        return .{
            .gc = .{ .kind = .bound_method },
            .receiver = receiver,
            .method = method,
        };
    }
};

test "short string round trip" {
    const bytes = "hi";
    const value = LoxValue.shortString(bytes);
    try std.testing.expect(value.isShortString());
    try std.testing.expect(value.isString());
    try std.testing.expect(!value.isHeapString());

    var buf: [SHORT_STRING_MAX_LEN]u8 = undefined;
    try std.testing.expectEqualStrings(bytes, value.stringBytes(&buf));
    try std.testing.expect(LoxValue.stringsEqual(value, LoxValue.shortString("hi")));
    try std.testing.expect(LoxValue.stringsEqual(value, value));
}

test "short string compares with heap string" {
    const heap = try HeapString.init(std.testing.allocator, "ab");
    defer std.testing.allocator.destroy(heap);
    heap.data = "ab";

    const short = LoxValue.shortString("ab");
    const long = LoxValue.string(heap);
    try std.testing.expect(LoxValue.stringsEqual(short, long));
}

test "LoxValue is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(LoxValue));
}

test "Closure size scales with upvalue count" {
    var func = Function.init(std.testing.allocator, "fn");
    func.upvalue_count = 3;
    var closure = try Closure.init(std.testing.allocator, &func);
    defer closure.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), closure.upvalues.len);
    try std.testing.expectEqual(
        @sizeOf(Closure) + 3 * @sizeOf(*Upvalue),
        closure.size(),
    );
}
