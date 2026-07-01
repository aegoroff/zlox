pub const Compiler = @This();

const std = @import("std");
const scan = @import("scanner.zig");
const Chunk = @import("chunk.zig");
const val = @import("value.zig");
const e = @import("error.zig");
const ErrorReporter = @import("fehler").ErrorReporter;
const Diagnostic = @import("fehler").Diagnostic;
const Severity = @import("fehler").Severity;
const SourceRange = @import("fehler").SourceRange;

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

const Upvalue = struct {
    index: usize,
    is_local: bool,
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
    enclosing: ?*Compile,
    locals: [LOCALS_MAX]Local,
    localCount: usize,
    scopeDepth: i16,
    function: val.Function,
    function_type: FunctionType,
    upvalues: [LOCALS_MAX]Upvalue,

    fn init(gpa: std.mem.Allocator, function_type: FunctionType) Compile {
        return Compile{
            .localCount = 0,
            .scopeDepth = 0,
            .locals = undefined,
            .function = val.Function.init(gpa, null),
            .function_type = function_type,
            .enclosing = null,
            .upvalues = undefined,
        };
    }

    fn deinit(self: *Compile) void {
        self.function.deinit();
    }
};

pub const FunctionType = enum {
    Function,
    Script,
    Method,
    TypeInitializer,
};

const LOCALS_MAX: usize = std.math.maxInt(u8) + 1;

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
lexer: scan.Lexer,
current: *Compile,
parser: Parser,
print_code: bool,
filename: []const u8,

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, print_code: bool, filename: []const u8) Compiler {
    return Compiler{
        .allocator = gpa,
        .writer = writer,
        .print_code = print_code,
        .filename = filename,
        .lexer = undefined,
        .current = undefined,
        .parser = .{
            .current = undefined,
            .previous = undefined,
            .hadError = false,
            .panicMode = false,
        },
    };
}

fn initCurrent(self: *Compiler, function_type: FunctionType) !void {
    const compile_ptr = try self.allocator.create(Compile);
    compile_ptr.* = Compile.init(self.allocator, function_type);
    self.current = compile_ptr;
}

pub fn deinit(self: *Compiler) void {
    var current = self.current;
    while (current.enclosing) |enclosing| {
        current.deinit();
        self.allocator.destroy(current);
        current = enclosing;
    }
    // Free the top-level compile struct and its function
    current.deinit();
    self.allocator.destroy(current);
}

pub fn compile(self: *Compiler, source: []const u8) !val.Function {
    try self.initCurrent(.Script);
    self.lexer = scan.Lexer.init(source);
    try self.advance();
    while (!self.check(.Eof)) {
        try self.declaration();
    }
    return try self.endCompiler();
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

    var reporter = ErrorReporter.init(self.allocator);
    defer reporter.deinit();

    try reporter.addSource(self.filename, self.lexer.source);

    // For single-character tokens, use the same start and end columns
    const col_start = token.col_start;
    const col_end = if (token.col_end > token.col_start) token.col_end else token.col_start;

    const diagnostic = Diagnostic.init(.err, message)
        .withRange(SourceRange.span(self.filename, token.line, col_start, token.line, col_end));

    reporter.report(diagnostic);
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

fn emitLoop(self: *Compiler, loopStart: usize) !void {
    try self.emitOpcode(.Loop);
    const offset = self.currentChunk().codeSize() - loopStart + 2;
    if (offset > std.math.maxInt(u16)) {
        try self.errorAtCurrent("Loop body too large.");
        return e.Error.CompileError;
    }

    try self.emitOperand(offset & 0xff);
    try self.emitOperand((offset >> 8) & 0xff);
}

fn emitJump(self: *Compiler, opcode: Chunk.OpCode) !usize {
    try self.emitOpcode(opcode);
    try self.emitOperand(0xFF);
    try self.emitOperand(0xFF);
    return self.currentChunk().codeSize() - 2;
}

fn patchJump(self: *Compiler, offset: usize) !void {
    // -2 to adjust for the bytecode for the jump offset itself.
    const jump = self.currentChunk().codeSize() - offset - 2;

    if (jump > std.math.maxInt(u16)) {
        try self.errorAtCurrent("Too much code to jump over.");
        return e.Error.CompileError;
    }

    self.currentChunk().code.items[offset] = @truncate(jump & 0xff);
    self.currentChunk().code.items[offset + 1] = @truncate((jump >> 8) & 0xff);
}

fn emitReturn(self: *Compiler) !void {
    try self.emitOpcode(.Nil);
    try self.emitOpcode(.Return);
}

fn emitConstant(self: *Compiler, value: val.LoxValue) !void {
    const ix = try self.currentChunk().addConstant(value);
    try self.currentChunk().writeConstant(ix, self.parser.previous.line);
}

fn makeConstant(self: *Compiler, value: val.LoxValue) !usize {
    return try self.currentChunk().addConstant(value);
}

fn endCompiler(self: *Compiler) !val.Function {
    try self.emitReturn();
    const fun = self.current.function;
    if (!self.parser.hadError and self.print_code) {
        try self.currentChunk().disassembly(self.writer, fun.name);
    }
    // Ownership transfers to caller (VM), nullify the function in compiler
    // to prevent double-free when compiler is deinitialized
    self.current.function.name = null;
    self.current.function.chunk = Chunk.init(self.allocator);
    self.current.function.arity = 0;
    return fun;
}

fn beginScope(self: *Compiler) void {
    self.current.scopeDepth += 1;
}

fn endScope(self: *Compiler) !void {
    self.current.scopeDepth -= 1;
    while (self.current.localCount > 0 and self.current.locals[self.current.localCount - 1].depth > self.current.scopeDepth) {
        if (self.current.locals[self.current.localCount - 1].is_captured) {
            try self.emitOpcode(.CloseUpvalue);
        } else {
            try self.emitOpcode(.Pop);
        }
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
    var arg: ?usize = null;
    if (try self.resolveLocal(self.current, token)) |local| {
        getOp = .GetLocal;
        setOp = .SetLocal;
        arg = local;
    } else if (try self.resolveUpvalue(self.current, token)) |upvalue| {
        getOp = .GetUpvalue;
        setOp = .SetUpvalue;
        arg = upvalue;
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
            } else if (setOp == .SetLocal) {
                try self.emitOpcode(.SetLocalLong);
            } else {
                try self.emitOpcode(setOp);
            }
        } else {
            try self.emitOpcode(setOp);
        }
    } else {
        if (arg.? > Chunk.MAX_SHORT_VALUE) {
            if (getOp == .GetGlobal) {
                try self.emitOpcode(.GetGlobalLong);
            } else if (getOp == .GetLocal) {
                try self.emitOpcode(.GetLocalLong);
            } else {
                try self.emitOpcode(getOp);
            }
        } else {
            try self.emitOpcode(getOp);
        }
    }

    try self.emitOperand(arg.?);
}

fn resolveUpvalue(self: *Compiler, compiler: *Compile, token: *scan.Token) !?usize {
    if (compiler.enclosing) |enclosing| {
        if (try self.resolveLocal(enclosing, token)) |local| {
            compiler.enclosing.?.locals[local].is_captured = true;
            return try self.addUpvalue(compiler, local, true);
        } else {
            if (try self.resolveUpvalue(compiler.enclosing.?, token)) |upvalue| {
                return try self.addUpvalue(compiler, upvalue, false);
            } else {
                return null;
            }
        }
    } else {
        return null;
    }
}

fn addUpvalue(self: *Compiler, compiler: *Compile, index: usize, is_local: bool) !usize {
    const upvalueCount = compiler.function.upvalue_count;
    for (0..upvalueCount) |ix| {
        if (compiler.upvalues[ix].index == index and compiler.upvalues[ix].is_local == is_local) {
            return ix;
        }
    }

    if (upvalueCount == LOCALS_MAX) {
        try self.errorAtPrev("Too many closure variables in function.");
        return 0;
    }

    compiler.upvalues[upvalueCount].is_local = is_local;
    compiler.upvalues[upvalueCount].index = index;
    compiler.function.upvalue_count += 1;
    return upvalueCount;
}

fn resolveLocal(self: *Compiler, compiler: *Compile, token: *scan.Token) !?usize {
    var i: usize = compiler.localCount;
    while (i > 0) : (i -= 1) {
        const local = compiler.locals[i - 1];

        if (std.mem.eql(u8, self.lexeme(token), local.name)) {
            if (local.depth == -1) {
                try self.errorAtCurrent("Can't read local variable in its own initializer.");
                return e.Error.CompileError;
            }
            return i - 1;
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

fn call(self: *Compiler, _: bool) !void {
    const args_count = try self.argumentList();
    try self.emitOpcode(.Call);
    try self.emitOperand(args_count);
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
    if (self.current.scopeDepth == 0) {
        return;
    }
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

fn argumentList(self: *Compiler) anyerror!usize {
    var arg_count: usize = 0;
    if (!self.check(.RightParen)) {
        while (true) {
            try self.expression();
            if (arg_count == 255) {
                try self.errorAtPrev("Can't have more than 255 arguments.");
                return e.Error.CompileError;
            }
            arg_count += 1;
            if (!try self.match(.Comma)) {
                break;
            }
        }
    }
    try self.consume(.RightParen, "Expect ')' after arguments.");
    return arg_count;
}

fn and_(self: *Compiler) !void {
    const endJump = try self.emitJump(.JumpIfFalse);
    try self.emitOpcode(.Pop);
    try self.parsePrecedence(.And);
    try self.patchJump(endJump);
}

fn or_(self: *Compiler) !void {
    const elseJump = try self.emitJump(.JumpIfFalse);
    const endJump = try self.emitJump(.Jump);
    try self.patchJump(elseJump);
    try self.emitOpcode(.Pop);
    try self.parsePrecedence(.Or);
    try self.patchJump(endJump);
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

fn callInfix(self: *Compiler, tokenType: scan.TokenType, can_assign: bool) !void {
    switch (tokenType) {
        .Minus, .Plus, .Slash, .Star, .BangEqual, .EqualEqual, .Greater, .GreaterEqual, .Less, .LessEqual => try self.binary(),
        .And => try self.and_(),
        .Or => try self.or_(),
        .LeftParen => try self.call(can_assign),
        else => {},
    }
}

fn currentChunk(self: *Compiler) *Chunk {
    return &self.current.function.chunk;
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

fn returnStatement(self: *Compiler) anyerror!void {
    if (try self.match(.Semicolon)) {
        try self.emitReturn();
    } else {
        try self.expression();
        try self.consume(.Semicolon, "Expect ';' after return value.");
        try self.emitOpcode(.Return);
    }
}

fn whileStatement(self: *Compiler) anyerror!void {
    const loopStart = self.currentChunk().codeSize();
    try self.consume(.LeftParen, "Expect '(' after 'while'.");
    try self.expression();
    try self.consume(.RightParen, "Expect ')' after condition.");

    const exitJump = try self.emitJump(.JumpIfFalse);
    try self.emitOpcode(.Pop);
    try self.statement();
    try self.emitLoop(loopStart);

    try self.patchJump(exitJump);
    try self.emitOpcode(.Pop);
}

fn forStatement(self: *Compiler) anyerror!void {
    self.beginScope();
    try self.consume(.LeftParen, "Expect '(' after 'for'.");

    if (try self.match(.Semicolon)) {
        // no initializer
    } else if (try self.match(.Var)) {
        try self.varDeclaration();
    } else {
        try self.expressionStatement();
    }

    var loopStart = self.currentChunk().codeSize();
    var exitJump: ?usize = null;
    if (!try self.match(.Semicolon)) {
        try self.expression();
        try self.consume(.Semicolon, "Expect ';' after loop condition.");

        // Jump out of the loop if the condition is false.
        exitJump = try self.emitJump(.JumpIfFalse);
        try self.emitOpcode(.Pop); // Condition.
    }

    if (!try self.match(.RightParen)) {
        const bodyJump = try self.emitJump(.Jump);
        const incrementStart = self.currentChunk().codeSize();
        try self.expression();
        try self.emitOpcode(.Pop);
        try self.consume(.RightParen, "Expect ')' after for clauses.");
        try self.emitLoop(loopStart);
        loopStart = incrementStart;
        try self.patchJump(bodyJump);
    }

    try self.statement();
    try self.emitLoop(loopStart);
    if (exitJump != null) {
        try self.patchJump(exitJump.?);
        try self.emitOpcode(.Pop); // Condition.
    }

    try self.endScope();
}

fn block(self: *Compiler) anyerror!void {
    while (!self.check(.Eof) and !self.check(.RightBrace)) {
        try self.declaration();
    }
    try self.consume(.RightBrace, "Expect '}' after block.");
}

fn function(self: *Compiler, function_type: FunctionType) !void {
    const old_compiler = self.current;
    var compiler = Compile.init(self.allocator, function_type);
    compiler.enclosing = old_compiler;
    compiler.function.name = self.lexeme(&self.parser.previous);
    const new_compile = try self.allocator.create(Compile);
    new_compile.* = compiler;
    self.current = new_compile;

    self.beginScope();
    try self.consume(.LeftParen, "Expect '(' after function name.");

    if (!self.check(.RightParen)) {
        while (true) {
            self.current.function.arity += 1;
            if (self.current.function.arity > 255) {
                try self.errorAtCurrent("Can't have more than 255 parameters.");
            }
            const constant = try self.parseVariable("Expect parameter name.");
            try self.defineVariable(constant);

            if (!try self.match(.Comma)) break;
        }
    }

    try self.consume(.RightParen, "Expect ')' after parameters.");
    try self.consume(.LeftBrace, "Expect '{' before function body.");
    try self.block();
    const func = try self.endCompiler();

    // Copy upvalues before destroying new_compile
    var upvalues: [LOCALS_MAX]Upvalue = undefined;
    const upvalue_count = new_compile.function.upvalue_count;
    for (0..upvalue_count) |i| {
        upvalues[i] = new_compile.upvalues[i];
    }

    // Restore current to the enclosing compiler so defineVariable works correctly.
    self.current = old_compiler;

    new_compile.deinit();
    self.allocator.destroy(new_compile);

    try self.emitOpcode(.Closure);
    const ix = try self.currentChunk().addConstant(.{ .Function = func });
    try self.emitOperand(ix);
    for (0..upvalue_count) |i| {
        const is_local: usize = if (upvalues[i].is_local) 1 else 0;
        try self.emitOperand(is_local);
        try self.emitOperand(upvalues[i].index);
    }
}

fn funDeclaration(self: *Compiler) !void {
    const global = try self.parseVariable("Expect function name.");
    self.markInitialized();
    try self.function(.Function);
    try self.defineVariable(global);
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
    if (try self.match(.Fun)) {
        try self.funDeclaration();
    } else if (try self.match(.Var)) {
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
    } else if (try self.match(.Return)) {
        try self.returnStatement();
    } else if (try self.match(.While)) {
        try self.whileStatement();
    } else if (try self.match(.For)) {
        try self.forStatement();
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
