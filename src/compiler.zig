pub const Compiler = @This();

const std = @import("std");
const scan = @import("scanner.zig");
const Chunk = @import("chunk.zig");

pub const Parser = struct {
    current: scan.Token,
    previous: scan.Token,
    hadError: bool,
    panicMode: bool,
};

allocator: std.mem.Allocator,
lexer: scan.Lexer,
compilingChunk: *Chunk,
parser: Parser,

pub fn init(gpa: std.mem.Allocator) Compiler {
    return Compiler{
        .allocator = gpa,
        .lexer = undefined,
        .compilingChunk = undefined,
        .parser = .{
            .current = undefined,
            .previous = undefined,
            .hadError = false,
            .panicMode = false,
        },
    };
}

pub fn compile(self: *Compiler, source: []const u8, chunk: *Chunk) !void {
    self.compilingChunk = chunk;
    self.lexer = scan.Lexer.init(source);
    try self.advance();
    self.expression();
    try self.consume(.Eof, "Expect end of expression.");
    try self.endCompiler();
}

fn advance(self: *Compiler) !void {
    self.parser.previous = self.parser.current;
    self.parser.current = self.lexer.scanToken() catch |err| {
        switch (err) {
            error.UnexpectedCharacter => self.errorAtCurrent("Unexpected character found in source code."),
            error.UnterminatedString => self.errorAtCurrent("Unterminated string literal."),
        }
        return err;
    };
}

fn errorAtCurrent(self: *Compiler, message: []const u8) void {
    self.errorAt(&self.parser.current, message);
}

fn errorAtPrev(self: *Compiler, message: []const u8) void {
    self.errorAt(&self.parser.previous, message);
}

fn errorAt(self: *Compiler, token: *scan.Token, message: []const u8) void {
    if (self.parser.panicMode) {
        return;
    }
    self.parser.panicMode = true;
    std.log.err("[line {d}] Error", .{token.line});

    if (token.type == .Eof) {
        std.log.err(" at end", .{});
    } else {
        std.log.err(" at '{s}'", .{self.lexer.source[token.start .. token.start + token.length]});
    }

    std.log.err(": {s}\n", .{message});
    self.parser.hadError = true;
}

fn consume(self: *Compiler, token: scan.TokenType, message: []const u8) !void {
    if (self.parser.current.type == token) {
        try self.advance();
    }
    self.errorAtCurrent(message);
}

fn emitOpcode(self: *Compiler, opcode: Chunk.OpCode) !void {
    try self.currentChunk().writeCode(opcode, self.parser.previous.line);
}

fn emitOperand(self: *Compiler, value: usize) !void {
    try self.currentChunk().writeOperand(value, self.parser.previous.line);
}

fn emitReturn(self: *Compiler) !void {
    try self.emitOpcode(.Return);
}

fn endCompiler(self: *Compiler) !void {
    try self.emitReturn();
}

fn currentChunk(self: *Compiler) *Chunk {
    return self.compilingChunk;
}

fn expression(_: *Compiler) void {}
