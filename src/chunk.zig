pub const Chunk = @This();

const std = @import("std");
const value = @import("value.zig");

const LoxValue = value.LoxValue;

pub const OpCode = enum(u8) {
    Constant = 0,
    ConstantLong = 1,
    Nil = 2,
    True = 3,
    False = 4,
    Pop = 5,
    GetLocal = 6,
    SetLocal = 7,
    GetLocalLong = 8,
    SetLocalLong = 9,
    GetGlobal = 10,
    GetGlobalLong = 11,
    DefineGlobal = 12,
    DefineGlobalLong = 13,
    SetGlobal = 14,
    SetGlobalLong = 15,
    GetUpvalue = 16,
    SetUpvalue = 17,
    GetProperty = 18,
    SetProperty = 19,
    GetSuper = 20,
    Equal = 21,
    Greater = 22,
    Less = 23,
    Add = 24,
    Subtract = 25,
    Multiply = 26,
    Divide = 27,
    Not = 28,
    Negate = 29,
    Print = 30,
    Jump = 31,
    JumpIfFalse = 32,
    Loop = 33,
    Call = 34,
    Invoke = 35,
    SuperInvoke = 36,
    Closure = 37,
    CloseUpvalue = 38,
    Return = 39,
    Class = 40,
    Inherit = 41,
    Method = 42,
    ClosureLong = 43,
    ClassLong = 44,
    MethodLong = 45,
    GetPropertyLong = 46,
    SetPropertyLong = 47,
    GetSuperLong = 48,
    InvokeLong = 49,
    SuperInvokeLong = 50,
};

pub const MAX_SHORT_VALUE: usize = 255;
pub const OPERAND_SHORT: usize = 1;
pub const OPERAND_LONG: usize = 3;

const OperandWidth = enum {
    short,
    long,
};

allocator: std.mem.Allocator,
code: std.ArrayList(u8),
constants: std.ArrayList(LoxValue),
lines: std.ArrayList(usize),

pub fn init(gpa: std.mem.Allocator) Chunk {
    return .{
        .allocator = gpa,
        .code = .empty,
        .constants = .empty,
        .lines = .empty,
    };
}

pub fn deinit(self: *Chunk) void {
    self.code.deinit(self.allocator);
    // Function constants are now in heap and managed by GC, don't free them here
    self.constants.deinit(self.allocator);
    self.lines.deinit(self.allocator);
}

inline fn operandSize(width: OperandWidth) usize {
    return switch (width) {
        .short => OPERAND_SHORT,
        .long => OPERAND_LONG,
    };
}

pub fn codeSize(self: *Chunk) usize {
    return self.code.items.len;
}

pub fn writeCode(self: *Chunk, code: OpCode, line: usize) !void {
    try self.writeOperand(@intFromEnum(code), line);
}

pub fn writeIndexedOpcode(self: *Chunk, short: OpCode, ix: usize, line: usize) !void {
    const real_code = if (ix > MAX_SHORT_VALUE) longOpcode(short) else short;
    try self.writeCode(real_code, line);
    try self.writeOperand(ix, line);
}

inline fn longOpcode(short: OpCode) OpCode {
    return switch (short) {
        .Constant => .ConstantLong,
        .DefineGlobal => .DefineGlobalLong,
        .GetGlobal => .GetGlobalLong,
        .SetGlobal => .SetGlobalLong,
        .GetLocal => .GetLocalLong,
        .SetLocal => .SetLocalLong,
        .GetSuper => .GetSuperLong,
        .GetProperty => .GetPropertyLong,
        .SetProperty => .SetPropertyLong,
        .Invoke => .InvokeLong,
        .SuperInvoke => .SuperInvokeLong,
        .Closure => .ClosureLong,
        .Class => .ClassLong,
        .Method => .MethodLong,
        else => short,
    };
}

pub fn writeConstant(self: *Chunk, ix: usize, line: usize) !void {
    try self.writeIndexedOpcode(.Constant, ix, line);
}

pub fn addConstant(self: *Chunk, val: LoxValue) !usize {
    // Deduplicate by representation, not semantic equality: short and heap
    // strings with the same text serve different roles in bytecode.
    for (self.constants.items, 0..) |existing, ix| {
        if (existing.raw == val.raw) {
            return ix;
        }
    }
    try self.constants.append(self.allocator, val);
    return self.constants.items.len - 1;
}

pub fn writeOperand(self: *Chunk, val: usize, line: usize) !void {
    if (val > MAX_SHORT_VALUE) {
        for (intoThreeBytes(val)) |b| {
            try self.write(b);
            try self.lines.append(self.allocator, line);
        }
    } else {
        try self.write(@truncate(val));
        try self.lines.append(self.allocator, line);
    }
}

pub fn disassembly(self: *Chunk, writer: *std.Io.Writer, name: ?[]const u8) !void {
    try writer.print("== {s} ==\n", .{name orelse "script"});
    var offset: usize = 0;
    while (offset < self.codeSize()) {
        offset = try self.disassemblyInstruction(writer, offset);
    }
}

pub inline fn offsetOf(self: *const Chunk, ip: [*]const u8) usize {
    return @intFromPtr(ip) - @intFromPtr(self.code.items.ptr);
}

pub inline fn readOpcodeAt(_: *const Chunk, ip: [*]const u8) OpCode {
    return @enumFromInt(ip[0]);
}

pub inline fn readByteAt(_: *const Chunk, ip: [*]const u8) u8 {
    return ip[0];
}

pub inline fn readShortAt(_: *const Chunk, ip: [*]const u8) usize {
    const op1: usize = ip[0];
    const op2: usize = ip[1];
    return op2 << 8 | op1;
}

pub inline fn readThreeBytesAt(_: *const Chunk, ip: [*]const u8) usize {
    return @as(usize, ip[2]) << 16 | @as(usize, ip[1]) << 8 | ip[0];
}

pub inline fn readSlotAt(self: *const Chunk, ip: [*]const u8, operand_size: usize) usize {
    return switch (operand_size) {
        OPERAND_SHORT => ip[0],
        OPERAND_LONG => self.readThreeBytesAt(ip),
        else => unreachable,
    };
}

pub inline fn getConstantIxAt(self: *const Chunk, ip: [*]const u8, constant_size: usize) usize {
    return switch (constant_size) {
        OPERAND_SHORT => ip[0],
        OPERAND_LONG => self.readThreeBytesAt(ip),
        else => @panic("Invalid constant size"),
    };
}

pub inline fn readConstantAt(self: *const Chunk, ip: [*]const u8, constant_size: usize) LoxValue {
    const ix = self.getConstantIxAt(ip, constant_size);
    return self.constants.items[ix];
}

inline fn ipAt(self: *const Chunk, offset: usize) [*]const u8 {
    return self.code.items.ptr + offset;
}

inline fn readOpcode(self: *const Chunk, offset: usize) OpCode {
    return self.readOpcodeAt(self.ipAt(offset));
}

inline fn readByte(self: *const Chunk, offset: usize) u8 {
    return self.readByteAt(self.ipAt(offset));
}

inline fn readShort(self: *const Chunk, offset: usize) usize {
    return self.readShortAt(self.ipAt(offset));
}

inline fn readThreeBytes(self: *const Chunk, offset: usize) usize {
    return self.readThreeBytesAt(self.ipAt(offset));
}

inline fn getConstantIx(self: *const Chunk, offset: usize, constant_size: usize) usize {
    return self.getConstantIxAt(self.ipAt(offset), constant_size);
}

pub fn disassemblyInstruction(self: *Chunk, writer: *std.Io.Writer, offset: usize) !usize {
    try writer.print("{d:0>4} ", .{offset});

    if (offset > 0 and self.lines.items[offset] == self.lines.items[offset - 1]) {
        try writer.print("   | ", .{});
    } else {
        try writer.print("{d:4} ", .{self.lines.items[offset]});
    }

    const opcode = self.readOpcode(offset);
    return switch (opcode) {
        .Return => try disassemblySimpleInstruction(writer, offset, "OP_RETURN"),
        .Nil => try disassemblySimpleInstruction(writer, offset, "OP_NIL"),
        .True => try disassemblySimpleInstruction(writer, offset, "OP_TRUE"),
        .False => try disassemblySimpleInstruction(writer, offset, "OP_FALSE"),
        .Negate => try disassemblySimpleInstruction(writer, offset, "OP_NEGATE"),
        .Add => try disassemblySimpleInstruction(writer, offset, "OP_ADD"),
        .Subtract => try disassemblySimpleInstruction(writer, offset, "OP_SUBTRACT"),
        .Multiply => try disassemblySimpleInstruction(writer, offset, "OP_MULTIPLY"),
        .Divide => try disassemblySimpleInstruction(writer, offset, "OP_DIVIDE"),
        .Not => try disassemblySimpleInstruction(writer, offset, "OP_NOT"),
        .Equal => try disassemblySimpleInstruction(writer, offset, "OP_EQUAL"),
        .Greater => try disassemblySimpleInstruction(writer, offset, "OP_GREATER"),
        .Less => try disassemblySimpleInstruction(writer, offset, "OP_LESS"),
        .Print => try disassemblySimpleInstruction(writer, offset, "OP_PRINT"),
        .Pop => try disassemblySimpleInstruction(writer, offset, "OP_POP"),
        .CloseUpvalue => try disassemblySimpleInstruction(writer, offset, "OP_CLOSE_UPVALUE"),
        .Inherit => try disassemblySimpleInstruction(writer, offset, "OP_INHERIT"),
        .Constant, .ConstantLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_CONSTANT", "OP_CONSTANT_LONG", .constant),
        .DefineGlobal, .DefineGlobalLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_DEFINE_GLOBAL", "OP_DEFINE_LONG", .constant),
        .GetGlobal, .GetGlobalLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_GET_GLOBAL", "OP_GET_GLOBAL_LONG", .constant),
        .SetGlobal, .SetGlobalLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_SET_GLOBAL", "OP_SET_GLOBAL_LONG", .constant),
        .GetSuper, .GetSuperLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_GET_SUPER", "OP_GET_SUPER_LONG", .constant),
        .GetLocal, .GetLocalLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_GET_LOCAL", "OP_GET_LOCAL_LONG", .local),
        .SetLocal, .SetLocalLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_SET_LOCAL", "OP_SET_LOCAL_LONG", .local),
        .Call => try self.disassemblyByteInstruction(writer, offset, "OP_CALL"),
        .GetUpvalue => try self.disassemblyByteInstruction(writer, offset, "OP_GET_UPVALUE"),
        .Class, .ClassLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_CLASS", "OP_CLASS_LONG", .constant),
        .Method, .MethodLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_METHOD", "OP_METHOD_LONG", .constant),
        .GetProperty, .GetPropertyLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_GET_PROPERTY", "OP_GET_PROPERTY_LONG", .constant),
        .Invoke, .InvokeLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_INVOKE", "OP_INVOKE_LONG", .invoke),
        .SuperInvoke, .SuperInvokeLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_SUPER_INVOKE", "OP_SUPER_INVOKE_LONG", .invoke),
        .SetProperty, .SetPropertyLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_SET_PROPERTY", "OP_SET_PROPERTY_LONG", .constant),
        .SetUpvalue => try self.disassemblyByteInstruction(writer, offset, "OP_SET_UPVALUE"),
        .Closure, .ClosureLong => try self.disassemblyOperandPair(writer, offset, opcode, "OP_CLOSURE", "OP_CLOSURE_LONG", .closure),
        .JumpIfFalse => try self.disassemblyJumpInstruction(writer, offset, "OP_JUMP_IF_FALSE", 1),
        .Jump => try self.disassemblyJumpInstruction(writer, offset, "OP_JUMP", 1),
        .Loop => try self.disassemblyJumpInstruction(writer, offset, "OP_LOOP", -1),
    };
}

inline fn operandWidth(opcode: OpCode) ?OperandWidth {
    return switch (opcode) {
        .Constant, .DefineGlobal, .GetGlobal, .SetGlobal, .GetSuper, .GetLocal, .SetLocal, .Class, .Method, .GetProperty, .SetProperty, .Invoke, .SuperInvoke, .Closure => .short,
        .ConstantLong, .DefineGlobalLong, .GetGlobalLong, .SetGlobalLong, .GetSuperLong, .GetLocalLong, .SetLocalLong, .ClassLong, .MethodLong, .GetPropertyLong, .SetPropertyLong, .InvokeLong, .SuperInvokeLong, .ClosureLong => .long,
        else => null,
    };
}

fn write(self: *Chunk, byte: u8) !void {
    try self.code.append(self.allocator, byte);
}

const DisasmOperandKind = enum {
    constant,
    local,
    closure,
    invoke,
};

fn disassemblyOperandPair(
    self: *Chunk,
    writer: *std.Io.Writer,
    offset: usize,
    opcode: OpCode,
    disasm_short: []const u8,
    disasm_long: []const u8,
    kind: DisasmOperandKind,
) !usize {
    const width = operandWidth(opcode) orelse unreachable;
    const size = operandSize(width);
    const name = if (width == .long) disasm_long else disasm_short;
    return switch (kind) {
        .constant => try self.disassemblyConstant(writer, offset, name, size),
        .local => if (width == .short)
            try self.disassemblyByteInstruction(writer, offset, name)
        else
            try self.disassemblyThreeBytesInstruction(writer, offset, name),
        .closure => try self.disassemblyClosureInstruction(writer, offset, name, size),
        .invoke => try self.disassemblyInvokeInstruction(writer, offset, name, size),
    };
}

fn disassemblySimpleInstruction(writer: *std.Io.Writer, offset: usize, name: []const u8) !usize {
    try writer.print("{s}\n", .{name});
    return offset + 1;
}

fn disassemblyByteInstruction(self: *Chunk, writer: *std.Io.Writer, offset: usize, name: []const u8) !usize {
    const ix = self.readByte(offset + 1);
    try writer.print("{s:<16} {d:4}\n", .{ name, ix });
    return offset + 2;
}

fn disassemblyInvokeInstruction(self: *Chunk, writer: *std.Io.Writer, offset: usize, name: []const u8, constant_size: usize) !usize {
    const ix = self.getConstantIx(offset + 1, constant_size);
    const val = self.constants.items[ix];
    const arg_count = self.readByte(offset + 1 + constant_size);
    try writer.print("{s:<16} {d:4} '", .{ name, ix });
    try val.print(writer);
    try writer.print("' ({d} args)\n", .{arg_count});
    return offset + 1 + constant_size + 1;
}

fn disassemblyThreeBytesInstruction(self: *Chunk, writer: *std.Io.Writer, offset: usize, name: []const u8) !usize {
    const ix = self.readThreeBytes(offset + 1);
    try writer.print("{s:<16} {d:4}\n", .{ name, ix });
    return offset + 4;
}

fn disassemblyConstant(self: *Chunk, writer: *std.Io.Writer, offset: usize, name: []const u8, constant_size: usize) !usize {
    const ix = self.getConstantIx(offset + 1, constant_size);
    const val = self.constants.items[ix];
    try writer.print("{s:<16} {d:4} '", .{ name, ix });
    try val.print(writer);
    try writer.print("'\n", .{});
    return offset + constant_size + 1; // + 1 for opcode itself
}

fn disassemblyJumpInstruction(self: *Chunk, writer: *std.Io.Writer, offset: usize, name: []const u8, sign: i32) !usize {
    const jump = self.readShort(offset + 1);
    const target_address = @as(i32, @intCast(offset)) + 3 + sign * @as(i32, @intCast(jump));
    try writer.print("{s:<16} {d:>4} -> {d}\n", .{ name, offset, target_address });
    return offset + 3;
}

fn disassemblyClosureInstruction(self: *Chunk, writer: *std.Io.Writer, offset: usize, name: []const u8, constant_size: usize) !usize {
    const function_ix = self.getConstantIx(offset + 1, constant_size);
    var current_offset = offset + 1 + constant_size;

    const val = self.constants.items[function_ix];
    const func = if (val.isFunction())
        val.asFunction().*
    else if (val.isClosure())
        val.asClosure().function.*
    else
        null;
    const func_name = func.?.name orelse "script";
    const upvalue_count = if (func) |f| f.upvalue_count else 0;

    try writer.print("{s:<16} {d:4} {s}\n", .{ name, function_ix, func_name });

    var i: usize = 0;
    while (i < upvalue_count) : (i += 1) {
        const is_local = self.readByte(current_offset);
        const is_local_str = if (is_local == 1) "local" else "upvalue";
        const index = self.readByte(current_offset + 1);
        try writer.print("{d:04}    |                     {s} {d}\n", .{ current_offset, is_local_str, index });
        current_offset += 2;
    }
    return current_offset;
}

fn intoThreeBytes(val: usize) [3]u8 {
    const op1: u8 = @truncate(val & 0xFF);
    const op2: u8 = @truncate((val & 0xFF00) >> 8);
    const op3: u8 = @truncate((val & 0x00FF_0000) >> 16);
    return [3]u8{ op1, op2, op3 };
}
