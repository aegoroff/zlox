pub const Compiler = @This();

const std = @import("std");
const scan = @import("scanner.zig");
const Chunk = @import("chunk.zig");

pub const Parser = struct {
    current: scan.Token,
    previous: scan.Token,
    hadError: bool,
};

allocator: std.mem.Allocator,
lexer: scan.Lexer,
chunk: *Chunk,
parser: Parser,

pub fn init(gpa: std.mem.Allocator) Compiler {
    return Compiler{
        .allocator = gpa,
        .lexer = undefined,
        .chunk = undefined,
        .parser = .{
            .current = undefined,
            .previous = undefined,
            .hadError = false,
        },
    };
}

pub fn compile(self: *Compiler, source: []const u8, chunk: *Chunk) !void {
    self.chunk = chunk;
    self.lexer = scan.Lexer.init(source);
    try self.advance();
    self.expression();
    self.consume(.Eof, "Expect end of expression.");
}

fn advance(self: *Compiler) !void {
    self.parser.previous = self.parser.current;
    self.parser.current = self.lexer.scanToken() catch |err| {
        self.errorAt(&self.parser.current, "");
        return err;
    };
}

fn errorAt(self: *Compiler, token: *scan.Token, message: []const u8) void {
    std.log.err("[line {d}] Error", .{token.line});

    if (token.type == .Eof) {
        std.log.err(" at end", .{});
    } else {
        std.log.err(" at '{s}'", .{self.lexer.source[token.start .. token.start + token.length]});
    }

    std.log.err(": {s}\n", .{message});
    self.parser.hadError = true;
}

fn expression(_: *Compiler) void {}

fn consume(_: *Compiler, _: scan.TokenType, _: []const u8) void {}
