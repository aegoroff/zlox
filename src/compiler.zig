pub const Compiler = @This();

const std = @import("std");
const scan = @import("scanner.zig");
const Chunk = @import("chunk.zig");

pub const Parser = struct {
    current: scan.Token,
    previous: scan.Token,
};

allocator: std.mem.Allocator,
lexer: scan.Lexer,
chunk: *Chunk,

pub fn init(gpa: std.mem.Allocator) Compiler {
    return Compiler{
        .allocator = gpa,
        .lexer = undefined,
        .chunk = undefined,
    };
}

pub fn compile(self: *Compiler, source: []const u8, chunk: *Chunk) !void {
    self.chunk = chunk;
    self.lexer = scan.Lexer.init(source);
    self.advance();
    self.expression();
    self.consume(.Eof, "Expect end of expression.");
}

fn advance(_: *Compiler) void {}
fn expression(_: *Compiler) void {}
fn consume(_: *Compiler, _: scan.TokenType, _: []const u8) void {}
