pub const Compiler = @This();

const std = @import("std");
const scan = @import("scanner.zig");
const Chunk = @import("chunk.zig");
const val = @import("value.zig");

pub const Parser = struct {
    current: scan.Token,
    previous: scan.Token,
    hadError: bool,
    panicMode: bool,
};

const Precedence = enum(u8) {
    None = 0,
    Assignment = 1,
    Or = 2,
    And = 3,
    Equality = 4,
    Comparison = 5,
    Term = 6,
    Factor = 7,
    Unary = 8,
    Call = 9,
    Primary = 10,
};

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
lexer: scan.Lexer,
compilingChunk: *Chunk,
parser: Parser,

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) Compiler {
    return Compiler{
        .allocator = gpa,
        .writer = writer,
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
    try self.expression();
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
        std.log.err(" at '{s}'", .{self.lexeme(token)});
    }

    std.log.err(": {s}\n", .{message});
    self.parser.hadError = true;
}

fn consume(self: *Compiler, token: scan.TokenType, message: []const u8) !void {
    if (self.parser.current.type == token) {
        try self.advance();
        return;
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

fn emitConstant(self: *Compiler, value: val.LoxValue) !void {
    try self.currentChunk().writeConstant(value, self.parser.previous.line);
}

fn endCompiler(self: *Compiler) !void {
    try self.emitReturn();
    if (!self.parser.hadError) {
        try self.currentChunk().disassembly(self.writer, "main");
    }
}

fn grouping(self: *Compiler) !void {
    try self.expression();
    try self.consume(.RightParen, "Expect ')' after expression.");
}

fn lexeme(self: *Compiler, token: *scan.Token) []const u8 {
    return self.lexer.source[token.start .. token.start + token.length];
}

fn number(self: *Compiler) !void {
    const s = self.lexeme(&self.parser.previous);
    const value = try std.fmt.parseFloat(f64, s);

    try self.emitConstant(.{ .Number = value });
}

fn unary(self: *Compiler) !void {
    const operatorType = self.parser.previous.type;
    try self.parsePrecedence(.Unary);
    switch (operatorType) {
        .Minus => try self.emitOpcode(.Negate),
        else => {
            return;
        },
    }
}

fn binary(self: *Compiler) !void {
    const operatorType = self.parser.previous.type;
    const precedence = getPrecedence(operatorType);
    try self.parsePrecedence(@enumFromInt(@intFromEnum(precedence) + 1));
    switch (operatorType) {
        .Plus => try self.emitOpcode(.Add),
        .Minus => try self.emitOpcode(.Subtract),
        .Star => try self.emitOpcode(.Multiply),
        .Slash => try self.emitOpcode(.Divide),
        else => {
            return;
        },
    }
}

fn getPrecedence(tokenType: scan.TokenType) Precedence {
    return switch (tokenType) {
        .Minus, .Plus => .Term,
        .Slash, .Star => .Factor,
        .BangEqual, .EqualEqual => .Equality,
        .Greater, .GreaterEqual, .Less, .LessEqual => .Comparison,
        .And => .And,
        .Or => .Or,
        .LeftParen, .Dot => .Call,

        else => .None,
    };
}

fn parsePrecedence(self: *Compiler, precedence: Precedence) anyerror!void {
    try self.advance();
    const can_assign = @intFromEnum(precedence) <= @intFromEnum(Precedence.Assignment);
    try self.callPrefix(self.parser.previous.type, can_assign);
    while (@intFromEnum(getPrecedence(self.parser.current.type)) >= @intFromEnum(precedence)) {
        try self.advance();
        try self.callInfix(self.parser.previous.type, can_assign);
    }
}

fn callPrefix(self: *Compiler, tokenType: scan.TokenType, _: bool) !void {
    switch (tokenType) {
        .Minus, .Bang => try self.unary(),
        .LeftParen => try self.grouping(),
        .Number => try self.number(),
        //.String => |_| try self.string(),

        //.Identifier => |_| try self.variable(can_assign),

        //.This => try self.this(),
        //.TokenSuper => try self.super_(),

        //.True, .False, .Nil => try self.literal(),

        else => {},
    }
}

fn callInfix(self: *Compiler, tokenType: scan.TokenType, _: bool) !void {
    switch (tokenType) {
        .Minus, .Plus, .Slash, .Star, .BangEqual, .EqualEqual, .Greater, .GreaterEqual, .Less, .LessEqual => try self.binary(),
        else => {},
    }
}

fn currentChunk(self: *Compiler) *Chunk {
    return self.compilingChunk;
}

fn expression(self: *Compiler) !void {
    try self.parsePrecedence(.Assignment);
}
