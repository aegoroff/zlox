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
    GetGlobal = 8,
    GetGlobalLong = 9,
    DefineGlobal = 10,
    DefineGlobalLong = 11,
    SetGlobal = 12,
    SetGlobalLong = 13,
    GetUpvalue = 14,
    SetUpvalue = 15,
    GetProperty = 16,
    SetProperty = 17,
    GetSuper = 18,
    Equal = 19,
    Greater = 20,
    Less = 21,
    Add = 22,
    Subtract = 23,
    Multiply = 24,
    Divide = 25,
    Not = 26,
    Negate = 27,
    Print = 28,
    Jump = 29,
    JumpIfFalse = 30,
    Loop = 31,
    Call = 32,
    Invoke = 33,
    SuperInvoke = 34,
    Closure = 35,
    CloseUpvalue = 36,
    Return = 37,
    Class = 38,
    Inherit = 39,
    Method = 40,
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
    self.constants.deinit(self.allocator);
    self.lines.deinit(self.allocator);
}

pub fn writeCode(self: *Chunk, code: OpCode, line: usize) !void {
    try self.writeOperand(@intFromEnum(code), line);
}

pub fn writeConstant(self: *Chunk, val: LoxValue, line: usize) !void {
    try self.constants.append(self.allocator, val);
    const ix = self.constants.items.len - 1;
    if (ix > MAX_SHORT_VALUE) {
        try self.writeCode(OpCode.ConstantLong, line);
    } else {
        try self.writeCode(OpCode.Constant, line);
    }
    try self.writeOperand(ix, line);
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

pub fn disassembly(self: *Chunk, writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("== {s} ==\n", .{name});
    var offset: usize = 0;
    while (offset < self.code.items.len) {
        offset = try self.disassemblyInstruction(writer, offset);
    }
}

pub fn disassemblyInstruction(self: *Chunk, writer: *std.Io.Writer, offset: usize) !usize {
    try writer.print("{d:0>4} ", .{offset});

    if (offset > 0 and self.lines.items[offset] == self.lines.items[offset - 1]) {
        try writer.print("   | ", .{});
    } else {
        try writer.print("{d:4} ", .{self.lines.items[offset]});
    }

    const byte = self.readByte(offset);
    const opcode: OpCode = @enumFromInt(byte);
    return switch (opcode) {
        OpCode.Return => try disassemblySimpleInstruction(writer, offset, "OP_RETURN"),
        OpCode.Nil => try disassemblySimpleInstruction(writer, offset, "OP_NIL"),
        OpCode.True => try disassemblySimpleInstruction(writer, offset, "OP_TRUE"),
        OpCode.False => try disassemblySimpleInstruction(writer, offset, "OP_FALSE"),
        OpCode.Negate => try disassemblySimpleInstruction(writer, offset, "OP_NEGATE"),
        OpCode.Add => try disassemblySimpleInstruction(writer, offset, "OP_ADD"),
        OpCode.Subtract => try disassemblySimpleInstruction(writer, offset, "OP_SUBTRACT"),
        OpCode.Multiply => try disassemblySimpleInstruction(writer, offset, "OP_MULTIPLY"),
        OpCode.Divide => try disassemblySimpleInstruction(writer, offset, "OP_DIVIDE"),
        OpCode.Not => try disassemblySimpleInstruction(writer, offset, "OP_NOT"),
        OpCode.Equal => try disassemblySimpleInstruction(writer, offset, "OP_EQUAL"),
        OpCode.Greater => try disassemblySimpleInstruction(writer, offset, "OP_GREATER"),
        OpCode.Less => try disassemblySimpleInstruction(writer, offset, "OP_LESS"),
        OpCode.Print => try disassemblySimpleInstruction(writer, offset, "OP_PRINT"),
        OpCode.Pop => try disassemblySimpleInstruction(writer, offset, "OP_POP"),
        OpCode.CloseUpvalue => try disassemblySimpleInstruction(writer, offset, "OP_CLOSE_UPVALUE"),
        OpCode.Inherit => try disassemblySimpleInstruction(writer, offset, "OP_INHERIT"),
        OpCode.Constant => try disassemblyConstant(self, writer, offset, "OP_CONSTANT", 1),
        OpCode.ConstantLong => try disassemblyConstant(self, writer, offset, "OP_CONSTANT_LONG", 3),
        else => {
            try writer.print("Unknown opcode {d}\n", .{byte});
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

fn disassemblyConstant(self: *Chunk, writer: *std.Io.Writer, offset: usize, name: []const u8, constant_size: usize) !usize {
    const ix = self.getConstantIx(offset + 1, constant_size);
    const val = self.constants.items[ix];
    try writer.print("{s:<16} {d:4} '", .{ name, ix });
    try val.format(writer);
    try writer.print("'\n", .{});
    return offset + constant_size + 1; // + 1 for opcode itself
}

fn getConstantIx(self: *Chunk, offset: usize, constant_size: usize) usize {
    return switch (constant_size) {
        1 => self.readByte(offset),
        3 => self.readThreeBytes(offset),
        else => @panic("Invalid constant size"),
    };
}

fn readByte(self: *Chunk, offset: usize) u8 {
    return self.code.items[offset];
}

fn readThreeBytes(self: *Chunk, offset: usize) usize {
    const op1: usize = self.readByte(offset); // first operand defines constant index in the constant's vector
    const op2 = self.readByte(offset + 1); // second operand defines constant index in the constant's vector
    const op3 = self.readByte(offset + 2); // third operand defines constant index in the constant's vector

    return @as(usize, @intCast(op3)) << 16 | @as(usize, @intCast(op2)) << 8 | op1;
}

fn intoThreeBytes(val: usize) [3]u8 {
    const op1: u8 = @truncate(val & 0xFF);
    const op2: u8 = @truncate((val & 0xFF00) >> 8);
    const op3: u8 = @truncate((val & 0x00FF_0000) >> 16);
    return [3]u8{ op1, op2, op3 };
}

fn intoTwoBytes(val: usize) [2]u8 {
    const op1: u8 = @truncate(val & 0xFF);
    const op2: u8 = @truncate((val & 0xFF00) >> 8);
    return [2]u8{ op1, op2 };
}
