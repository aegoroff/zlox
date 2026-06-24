pub const Chunk = @This();

pub const OpCode = enum(u8) {
    Return = 37,
};

code: OpCode,
