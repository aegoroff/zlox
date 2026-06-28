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
print_code: bool,

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, print_code: bool) Compiler {
    return Compiler{
        .allocator = gpa,
        .writer = writer,
        .print_code = print_code,
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
    if (self.check(token)) {
        try self.advance();
        return;
    }
    self.errorAtCurrent(message);
}

fn match(self: *Compiler, token: scan.TokenType) !bool {
    if (!self.check(token)) {
        return false;
    }
    try self.advance();
    return true;
}

fn check(self: *Compiler, token: scan.TokenType) bool {
    return self.parser.current.type == token;
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
    const ix = try self.currentChunk().addConstant(value);
    try self.currentChunk().writeConstant(ix, self.parser.previous.line);
}

fn makeConstant(self: *Compiler, value: val.LoxValue) !usize {
    return try self.currentChunk().addConstant(value);
}

fn endCompiler(self: *Compiler) !void {
    try self.emitReturn();
    if (!self.parser.hadError and self.print_code) {
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

    _ = try self.emitConstant(.{ .Number = value });
}

fn string(self: *Compiler) !void {
    const s = self.lexeme(&self.parser.previous);
    _ = try self.emitConstant(.{ .String = s });
}

fn variable(self: *Compiler, _: bool) !void {
    try self.namedVariable(&self.parser.previous);
}

fn namedVariable(self: *Compiler, token: *scan.Token) !void {
    const arg = try self.identifierConstant(token);
    if (arg > Chunk.MAX_SHORT_VALUE) {
        try self.emitOpcode(.GetGlobalLong);
    } else {
        try self.emitOpcode(.GetGlobal);
    }
    try self.emitOperand(arg);
}

fn literal(self: *Compiler) !void {
    switch (self.parser.previous.type) {
        .False => try self.emitOpcode(.False),
        .Nil => try self.emitOpcode(.Nil),
        .True => try self.emitOpcode(.True),
        else => {
            return;
        },
    }
}

fn unary(self: *Compiler) !void {
    const operatorType = self.parser.previous.type;
    try self.parsePrecedence(.Unary);
    switch (operatorType) {
        .Minus => try self.emitOpcode(.Negate),
        .Bang => try self.emitOpcode(.Not),
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
        .BangEqual => {
            try self.emitOpcode(.Equal);
            try self.emitOpcode(.Not);
        },
        .EqualEqual => try self.emitOpcode(.Equal),
        .Greater => try self.emitOpcode(.Greater),
        .GreaterEqual => {
            try self.emitOpcode(.Less);
            try self.emitOpcode(.Not);
        },
        .Less => try self.emitOpcode(.Less),
        .LessEqual => {
            try self.emitOpcode(.Greater);
            try self.emitOpcode(.Not);
        },
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

fn parseVariable(self: *Compiler, message: []const u8) anyerror!usize {
    try self.consume(.Identifier, message);
    return try self.identifierConstant(&self.parser.previous);
}

fn defintVariable(self: *Compiler, global: usize) anyerror!usize {
    if (global > Chunk.MAX_SHORT_VALUE) {
        try self.emitOpcode(.DefineGlobalLong);
    } else {
        try self.emitOpcode(.DefineGlobal);
    }
    try self.emitOperand(global);
}

fn identifierConstant(self: *Compiler, token: *scan.Token) anyerror!usize {
    return try self.makeConstant(.{ .String = self.lexeme(token) });
}

fn callPrefix(self: *Compiler, tokenType: scan.TokenType, can_assign: bool) !void {
    switch (tokenType) {
        .Minus, .Bang => try self.unary(),
        .LeftParen => try self.grouping(),
        .Number => try self.number(),
        .String => try self.string(),
        .Identifier => try self.variable(can_assign),

        //.This => try self.this(),
        //.Super => try self.super_(),

        .True, .False, .Nil => try self.literal(),

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

fn varDeclaration(self: *Compiler) !void {
    const global = try self.parseVariable("Expect variable name.");

    if (self.match(.Equal)) {
        try self.expression();
    } else {
        try self.emitOpcode(.Nil);
    }
    try self.consume(.Semicolon, "Expect ';' after variable declaration.");
    try self.defintVariable(global);
}

fn declaration(self: *Compiler) !void {
    if (self.match(.Var)) {
        try self.varDeclaration();
    } else {
        try self.statement();
    }
    if (self.parser.panicMode) {
        try self.synchronize();
    }
}

fn statement(self: *Compiler) !void {
    if (self.match(.Print)) {
        try self.printStatement();
    } else {
        try self.expressionStatement();
    }
}

fn printStatement(self: *Compiler) !void {
    try self.expression();
    try self.consume(.Semicolon, "Expect ';' after value.");
    try self.emitOpcode(.Print);
}

fn expressionStatement(self: *Compiler) !void {
    try self.expression();
    try self.consume(.Semicolon, "Expect ';' after expression.");
    try self.emitOpcode(.Pop);
}

fn synchronize(self: *Compiler) !void {
    self.parser.panicMode = false;
    while (self.parser.current.type != .Eof) {
        if (self.parser.previous.type == .Semicolon) {
            return;
        }
        switch (self.parser.current.type) {
            .Class, .Fun, .Var, .For, .If, .While, .Print, .Return => return,
            else => {},
        }
        try self.advance();
    }
}
