pub const Chunk = @This();

const std = @import("std");

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

allocator: std.mem.Allocator,
code: std.ArrayList(OpCode),

pub fn init(gpa: std.mem.Allocator) Chunk {
    return Chunk{
        .allocator = gpa,
        .code = .empty,
    };
}

pub fn deinit(self: *Chunk) void {
    self.code.deinit(self.allocator);
}

pub fn writeCode(self: *Chunk, code: OpCode) !void {
    try self.code.append(self.allocator, code);
}
