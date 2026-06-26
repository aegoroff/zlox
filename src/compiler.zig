pub const Compiler = @This();

const std = @import("std");
const scan = @import("scanner.zig");

allocator: std.mem.Allocator,
lexer: scan.Lexer,

pub fn init(gpa: std.mem.Allocator) Compiler {
    return Compiler{
        .allocator = gpa,
        .lexer = undefined,
    };
}

pub fn compile(self: *Compiler, source: []const u8) void {
    self.lexer = scan.Lexer.init(self.allocator, source);
}
