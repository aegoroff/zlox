pub const VM = @This();

const std = @import("std");
const chk = @import("chunk.zig");
const err = @import("error.zig");

allocator: std.mem.Allocator,
chunk: *chk.Chunk,
writer: *std.Io.Writer,

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) VM {
    return VM{
        .allocator = gpa,
        .chunk = undefined,
        .writer = writer,
    };
}

pub fn deinit(_: *VM) void {}

pub fn interpret(self: *VM, chunk: *chk.Chunk) !void {
    self.chunk = chunk;
    try self.run();
}

pub fn run(self: *VM) !void {
    var ip: usize = 0;
    while (ip < self.chunk.code.items.len) {
        const opcode = self.chunk.readOpcode(ip);
        ip += 1;
        switch (opcode) {
            chk.OpCode.Constant => {
                const val = self.chunk.readConstant(ip);
                ip += 1;
                try val.format(self.writer);
                try self.writer.print("\n", .{});
            },
            chk.OpCode.ConstantLong => {
                const val = self.chunk.readConstantLong(ip);
                ip += 3;
                try val.format(self.writer);
                try self.writer.print("\n", .{});
            },
            chk.OpCode.Return => return,
            else => {},
        }
    }
}
