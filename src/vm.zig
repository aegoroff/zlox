pub const VM = @This();

const std = @import("std");
const chk = @import("chunk.zig");
const err = @import("error.zig");

allocator: std.mem.Allocator,
chunk: *chk.Chunk,
ip: *std.ArrayList(u8),

pub fn init(gpa: std.mem.Allocator) VM {
    return VM{
        .allocator = gpa,
        .chunk = undefined,
        .ip = undefined,
    };
}

pub fn deinit(_: *VM) void {}

pub fn interpret(self: *VM, chunk: *chk.Chunk) err.Error!void {
    self.chunk = chunk;
    self.ip = &chunk.code;
    try self.run();
}

pub fn run(self: *VM) err.Error!void {
    for (0..self.ip.items.len) |offset| {
        const opcode = self.chunk.readOpcode(offset);
        switch (opcode) {
            chk.OpCode.Return => return,
            else => {},
        }
    }
}
