pub const Chunk = @This();

const std = @import("std");

pub const OpCode = enum(u8) {
    Return = 37,
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
