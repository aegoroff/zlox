pub const Compiler = @This();

const std = @import("std");
const scan = @import("scanner.zig");
const Chunk = @import("chunk.zig");
const val = @import("value.zig");
const e = @import("error.zig");

pub const Parser = struct {
    current: scan.Token,
    previous: scan.Token,
    hadError: bool,
    panicMode: bool,
};

pub const Local = struct {
    name: []const u8,
    depth: i16,
    is_captured: bool,
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

const Compile = struct {
    locals: [LOCALS_MAX]Local,
    localCount: usize,
    scopeDepth: i16,

    fn init() Compile {
        return Compile{
            .localCount = 0,
            .scopeDepth = 0,
            .locals = undefined,
        };
    }
};

const LOCALS_MAX: usize = std.math.maxInt(u8) + 1;

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
lexer: scan.Lexer,
compilingChunk: *Chunk,
current: Compile,
parser: Parser,
print_code: bool,

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, print_code: bool) Compiler {
    return Compiler{
        .allocator = gpa,
        .writer = writer,
        .print_code = print_code,
        .lexer = undefined,
        .compilingChunk = undefined,
        .current = undefined,
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
    self.current = Compile.init();
    self.lexer = scan.Lexer.init(source);
    try self.advance();
    while (!self.check(.Eof)) {
        try self.declaration();
    }
    try self.endCompiler();
}

fn advance(self: *Compiler) !void {
    self.parser.previous = self.parser.current;
    self.parser.current = self.lexer.scanToken() catch |err| {
        switch (err) {
            error.UnexpectedCharacter => try self.errorAtCurrent("Unexpected character found in source code."),
            error.UnterminatedString => try self.errorAtCurrent("Unterminated string literal."),
        }
        return err;
    };
}

fn errorAtCurrent(self: *Compiler, message: []const u8) !void {
    try self.errorAt(&self.parser.current, message);
}

fn errorAtPrev(self: *Compiler, message: []const u8) !void {
    try self.errorAt(&self.parser.previous, message);
}

fn errorAt(self: *Compiler, token: *scan.Token, message: []const u8) !void {
    if (self.parser.panicMode) {
        return;
    }
    self.parser.panicMode = true;

    const location = if (token.type == .Eof)
        try self.allocator.dupe(u8, " at end")
    else
        try std.fmt.allocPrint(self.allocator, " at '{s}'", .{self.lexeme(token)});

    defer self.allocator.free(location);

    std.log.err("[line {d}] Error{s}: {s}", .{ token.line, location, message });

    self.parser.hadError = true;
}

fn consume(self: *Compiler, token: scan.TokenType, message: []const u8) !void {
    if (self.check(token)) {
        try self.advance();
        return;
    }
    try self.errorAtCurrent(message);
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

fn emitJump(self: *Compiler, opcode: Chunk.OpCode) !usize {
    try self.currentChunk().writeCode(opcode, self.parser.previous.line);
    try self.currentChunk().writeOperand(0xFF, self.parser.previous.line);
    try self.currentChunk().writeOperand(0xFF, self.parser.previous.line);
    return self.currentChunk().code.items.len - 2;
}

fn patchJump(self: *Compiler, offset: usize) !void {
    // -2 to adjust for the bytecode for the jump offset itself.
    const jump = self.currentChunk().code.items.len - offset - 2;

    if (jump > std.math.maxInt(u16)) {
        try self.errorAtCurrent("Too much code to jump over.");
    }

    self.currentChunk().code.items[offset] = @truncate(jump & 0xff);
    self.currentChunk().code.items[offset + 1] = @truncate((jump >> 8) & 0xff);
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

fn beginScope(self: *Compiler) void {
    self.current.scopeDepth += 1;
}

fn endScope(self: *Compiler) !void {
    self.current.scopeDepth -= 1;
    while (self.current.localCount > 0 and self.current.locals[self.current.localCount - 1].depth > self.current.scopeDepth) {
        try self.emitOpcode(.Pop);
        self.current.localCount -= 1;
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
    _ = try self.emitConstant(.{ .String = s[1 .. s.len - 1] }); // trimming quotes
}

fn variable(self: *Compiler, can_assign: bool) !void {
    try self.namedVariable(&self.parser.previous, can_assign);
}

fn namedVariable(self: *Compiler, token: *scan.Token, can_assign: bool) !void {
    var getOp: Chunk.OpCode = undefined;
    var setOp: Chunk.OpCode = undefined;
    var arg = try self.resolveLocal(&self.current, token);
    if (arg != null) {
        getOp = .GetLocal;
        setOp = .SetLocal;
    } else {
        arg = try self.identifierConstant(token);
        getOp = .GetGlobal;
        setOp = .SetGlobal;
    }

    if (can_assign and try self.match(.Equal)) {
        try self.expression();
        if (arg.? > Chunk.MAX_SHORT_VALUE) {
            if (setOp == .SetGlobal) {
                try self.emitOpcode(.SetGlobalLong);
            } else {
                try self.emitOpcode(setOp);
            }
        } else {
            try self.emitOpcode(setOp);
        }
    } else {
        if (arg.? > Chunk.MAX_SHORT_VALUE) {
            if (setOp == .GetGlobal) {
                try self.emitOpcode(.GetGlobalLong);
            } else {
                try self.emitOpcode(getOp);
            }
        } else {
            try self.emitOpcode(getOp);
        }
    }

    try self.emitOperand(arg.?);
}

fn resolveLocal(self: *Compiler, compiler: *Compile, token: *scan.Token) !?usize {
    var i: usize = compiler.localCount;
    while (i > 0) {
        i -= 1;
        const local = compiler.locals[i];

        if (std.mem.eql(u8, self.lexeme(token), local.name)) {
            if (local.depth == -1) {
                try self.errorAtCurrent("Can't read local variable in its own initializer.");
                return e.Error.RuntimeError;
            }
            return i;
        }
    }
    return null;
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
    if (can_assign and try self.match(.Equal)) {
        try self.errorAtCurrent("Invalid assignment target.");
    }
}

fn markInitialized(self: *Compiler) void {
    self.current.locals[self.current.localCount - 1].depth = self.current.scopeDepth;
}

fn parseVariable(self: *Compiler, message: []const u8) anyerror!usize {
    try self.consume(.Identifier, message);
    try self.declareVariable();
    if (self.current.scopeDepth > 0) {
        self.markInitialized();
        return 0;
    }
    return try self.identifierConstant(&self.parser.previous);
}

fn defineVariable(self: *Compiler, global: usize) anyerror!void {
    if (self.current.scopeDepth > 0) {
        return;
    }
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

fn addLocal(self: *Compiler, token: *scan.Token) !void {
    if (self.current.localCount == LOCALS_MAX) {
        try self.errorAtPrev("Too many local variables in function.");
        return e.Error.CompileError;
    }
    var local = &self.current.locals[self.current.localCount];
    self.current.localCount += 1;
    local.name = self.lexeme(token);
    local.depth = -1; // Uninitialized
}

fn declareVariable(self: *Compiler) !void {
    if (self.current.scopeDepth == 0) {
        return;
    }
    var i: usize = self.current.localCount;
    while (i > 0) {
        i -= 1;
        const local = &self.current.locals[i];

        if (local.depth != -1 and local.depth < self.current.scopeDepth) {
            break;
        }

        const name = self.lexeme(&self.parser.previous);
        if (std.mem.eql(u8, name, local.name)) {
            try self.errorAtPrev("Already a variable with this name in this scope.");
        }
    }

    try self.addLocal(&self.parser.previous);
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

fn ifStatement(self: *Compiler) anyerror!void {
    try self.consume(.LeftParen, "Expect '(' after 'if'.");
    try self.expression();
    try self.consume(.RightParen, "Expect ')' after condition.");
    const thenJump = try self.emitJump(.JumpIfFalse);
    try self.emitOpcode(.Pop);
    try self.statement();
    const elseJump = try self.emitJump(.Jump);
    try self.patchJump(thenJump);
    try self.emitOpcode(.Pop);
    if (try self.match(.Else)) {
        try self.statement();
    }
    try self.patchJump(elseJump);
}

fn block(self: *Compiler) anyerror!void {
    while (!self.check(.Eof) and !self.check(.RightBrace)) {
        try self.declaration();
    }
    try self.consume(.RightBrace, "Expect '}' after block.");
}

fn varDeclaration(self: *Compiler) !void {
    const global = try self.parseVariable("Expect variable name.");

    if (try self.match(.Equal)) {
        try self.expression();
    } else {
        try self.emitOpcode(.Nil);
    }
    try self.consume(.Semicolon, "Expect ';' after variable declaration.");
    try self.defineVariable(global);
}

fn declaration(self: *Compiler) !void {
    if (try self.match(.Var)) {
        try self.varDeclaration();
    } else {
        try self.statement();
    }
    if (self.parser.panicMode) {
        try self.synchronize();
    }
}

fn statement(self: *Compiler) !void {
    if (try self.match(.Print)) {
        try self.printStatement();
    } else if (try self.match(.If)) {
        try self.ifStatement();
    } else if (try self.match(.LeftBrace)) {
        self.beginScope();
        try self.block();
        try self.endScope();
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
