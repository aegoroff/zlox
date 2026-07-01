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
};

pub const MAX_SHORT_VALUE: usize = 255;

allocator: std.mem.Allocator,
code: std.ArrayList(u8),
constants: std.ArrayList(LoxValue),
lines: std.ArrayList(usize),

pub fn init(gpa: std.mem.Allocator) Chunk {
    return Chunk{
        .allocator = gpa,
        .code = .empty,
        .constants = .empty,
        .lines = .empty,
    };
}

pub fn deinit(self: *Chunk) void {
    self.code.deinit(self.allocator);
    // Free any Function constants before deinitializing the ArrayList
    for (self.constants.items) |constant| {
        if (constant == .Function) {
            var func = constant.Function;
            func.deinit();
        }
    }
    self.constants.deinit(self.allocator);
    self.lines.deinit(self.allocator);
}

pub fn codeSize(self: *Chunk) usize {
    return self.code.items.len;
}

pub fn writeCode(self: *Chunk, code: OpCode, line: usize) !void {
    try self.writeOperand(@intFromEnum(code), line);
}

pub fn writeConstant(self: *Chunk, ix: usize, line: usize) !void {
    if (ix > MAX_SHORT_VALUE) {
        try self.writeCode(.ConstantLong, line);
    } else {
        try self.writeCode(.Constant, line);
    }
    try self.writeOperand(ix, line);
}

pub fn addConstant(self: *Chunk, val: LoxValue) !usize {
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

pub fn readOpcode(self: *Chunk, offset: usize) OpCode {
    const byte = self.readByte(offset);
    return @enumFromInt(byte);
}

pub fn readByte(self: *Chunk, offset: usize) u8 {
    return self.code.items[offset];
}

pub fn readShort(self: *Chunk, offset: usize) usize {
    const op1: usize = @intCast(self.readByte(offset)); // first operand defines constant index in the constant's vector
    const op2: usize = @intCast(self.readByte(offset + 1)); // second operand defines constant index in the constant's vector
    return op2 << 8 | op1;
}

pub fn readConstant(self: *Chunk, offset: usize) LoxValue {
    const ix = self.getConstantIx(offset, 1);
    return self.constants.items[ix];
}

pub fn readConstantLong(self: *Chunk, offset: usize) LoxValue {
    const ix = self.getConstantIx(offset, 3);
    return self.constants.items[ix];
}

pub fn readThreeBytes(self: *Chunk, offset: usize) usize {
    const op1: usize = self.readByte(offset); // first operand defines constant index in the constant's vector
    const op2 = self.readByte(offset + 1); // second operand defines constant index in the constant's vector
    const op3 = self.readByte(offset + 2); // third operand defines constant index in the constant's vector

    return @as(usize, @intCast(op3)) << 16 | @as(usize, @intCast(op2)) << 8 | op1;
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
        .Constant => try self.disassemblyConstant(writer, offset, "OP_CONSTANT", 1),
        .DefineGlobal => try self.disassemblyConstant(writer, offset, "OP_DEFINE_GLOBAL", 1),
        .GetGlobal => try self.disassemblyConstant(writer, offset, "OP_GET_GLOBAL", 1),
        .SetGlobal => try self.disassemblyConstant(writer, offset, "OP_SET_GLOBAL", 1),
        .GetSuper => try self.disassemblyConstant(writer, offset, "OP_GET_SUPER", 1),
        .ConstantLong => try self.disassemblyConstant(writer, offset, "OP_CONSTANT_LONG", 3),
        .GetGlobalLong => try self.disassemblyConstant(writer, offset, "OP_GET_GLOBAL_LONG", 3),
        .SetGlobalLong => try self.disassemblyConstant(writer, offset, "OP_SET_GLOBAL_LONG", 3),
        .DefineGlobalLong => try self.disassemblyConstant(writer, offset, "OP_DEFINE_LONG", 3),
        .SetLocal => try self.disassemblyByteInstruction(writer, offset, "OP_SET_LOCAL"),
        .GetLocal => try self.disassemblyByteInstruction(writer, offset, "OP_GET_LOCAL"),
        .SetLocalLong => try self.disassemblyThreeBytesInstruction(writer, offset, "OP_SET_LOCAL_LONG"),
        .GetLocalLong => try self.disassemblyThreeBytesInstruction(writer, offset, "OP_GET_LOCAL_LONG"),
        .Call => try self.disassemblyByteInstruction(writer, offset, "OP_CALL"),
        .GetUpvalue => try self.disassemblyByteInstruction(writer, offset, "OP_GET_UPVALUE"),
        .Class => try self.disassemblyByteInstruction(writer, offset, "OP_CLASS"),
        .Method => try self.disassemblyByteInstruction(writer, offset, "OP_METHOD"),
        .GetProperty => try self.disassemblyByteInstruction(writer, offset, "OP_GET_PROPERTY"),
        .SetProperty => try self.disassemblyByteInstruction(writer, offset, "OP_SET_PROPERTY"),
        .SetUpvalue => try self.disassemblyByteInstruction(writer, offset, "OP_SET_UPVALUE"),
        .Closure => try self.disassemblyClosureInstruction(writer, offset, "OP_CLOSURE"),
        .JumpIfFalse => try self.disassemblyJumpInstruction(writer, offset, "OP_JUMP_IF_FALSE", 1),
        .Jump => try self.disassemblyJumpInstruction(writer, offset, "OP_JUMP", 1),
        .Loop => try self.disassemblyJumpInstruction(writer, offset, "OP_LOOP", -1),
        else => {
            try writer.print("Unknown opcode {d}\n", .{opcode});
            return offset + 1;
        },
    };
}

fn write(self: *Chunk, byte: u8) !void {
    try self.code.append(self.allocator, byte);
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

fn disassemblyClosureInstruction(self: *Chunk, writer: *std.Io.Writer, offset: usize, name: []const u8) !usize {
    const function_ix = self.readByte(offset + 1);
    var current_offset = offset + 2;

    const val = self.constants.items[function_ix];
    if (val == .Closure) {
        const closure = val.Closure;
        try writer.print("{s:<16} {d:4} {s}\n", .{ name, function_ix, closure.function.name orelse "script" });
        var i: usize = 0;
        while (i < closure.upvalue_count) : (i += 1) {
            const is_local = self.readByte(current_offset);
            const is_local_str = if (is_local == 1) "local" else "upvalue";
            const index = self.readByte(current_offset + 1);
            try writer.print("{d:04}    |                     {s} {d}\n", .{ current_offset, is_local_str, index });
            current_offset += 2;
        }
    } else if (val == .Function) {
        const func = val.Function;
        try writer.print("{s:<16} {d:4} {s}\n", .{ name, function_ix, func.name orelse "script" });
    } else {
        try writer.print("{s:<16} {d:4}\n", .{ name, function_ix });
    }
    return current_offset;
}

fn getConstantIx(self: *Chunk, offset: usize, constant_size: usize) usize {
    return switch (constant_size) {
        1 => self.readByte(offset),
        3 => self.readThreeBytes(offset),
        else => @panic("Invalid constant size"),
    };
}

fn intoThreeBytes(val: usize) [3]u8 {
    const op1: u8 = @truncate(val & 0xFF);
    const op2: u8 = @truncate((val & 0xFF00) >> 8);
    const op3: u8 = @truncate((val & 0x00FF_0000) >> 16);
    return [3]u8{ op1, op2, op3 };
}
