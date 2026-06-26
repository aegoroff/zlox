pub const VM = @This();

const std = @import("std");
const chk = @import("chunk.zig");
const err = @import("error.zig");

allocator: std.mem.Allocator,
chunk: *chk.Chunk,

pub fn init(gpa: std.mem.Allocator) VM {
    return VM{
        .allocator = gpa,
        .chunk = undefined,
    };
}

pub fn deinit(_: *VM) void {}

pub fn interpret(self: *VM, chunk: *chk.Chunk) err.Error!void {
    self.chunk = chunk;
    try self.run();
}

pub fn run(self: *VM) err.Error!void {
    var ip: usize = 0;
    while (ip < self.chunk.code.items.len) {
        const opcode = self.chunk.readOpcode(ip);
        ip += 1;
        switch (opcode) {
            chk.OpCode.Return => return,
            else => {},
        }
    }
}
