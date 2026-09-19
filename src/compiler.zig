pub const Compiler = @This();

const std = @import("std");
const scan = @import("scanner.zig");
const Chunk = @import("chunk.zig");
const val = @import("value.zig");
const LoxValue = val.LoxValue;
const e = @import("error.zig");
const mem = @import("memory.zig");
const ErrorReporter = @import("fehler").ErrorReporter;
const Diagnostic = @import("fehler").Diagnostic;
const Severity = @import("fehler").Severity;
const SourceRange = @import("fehler").SourceRange;

pub const Parser = struct {
    current: scan.Token,
    previous: scan.Token,
    had_error: bool,
    panic_mode: bool,
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
    allocator: std.mem.Allocator,
    enclosing: ?*Compile,
    locals: [LOCALS_MAX]Local,
    local_count: usize,
    scope_depth: i16,
    function: ?*val.Function,
    function_type: FunctionType,
    upvalues: [LOCALS_MAX]Upvalue,

    fn init(gpa: std.mem.Allocator, function_type: FunctionType) !Compile {
        const func = try gpa.create(val.Function);
        func.* = val.Function.init(gpa, null);
        var compiler = Compile{
            .allocator = gpa,
            .local_count = 1,
            .scope_depth = 0,
            .locals = undefined,
            .function = func,
            .function_type = function_type,
            .enclosing = null,
            .upvalues = undefined,
        };
        const receiver_name = if (function_type == .Method or function_type == .TypeInitializer) "this" else "";
        compiler.locals[0] = Local{ .name = receiver_name, .depth = 0, .is_captured = false };
        return compiler;
    }

    fn deinit(self: *Compile) void {
        if (self.function) |func| {
            freeOwnedFunction(self.allocator, func);
        }
    }
};

/// Frees a function together with the nested functions stored in its constant
/// pool. Only reached while the compiler still owns the tree: a successful
/// `endCompiler` nulls out `Compile.function`, after which the VM owns every
/// function through the heap.
fn freeOwnedFunction(gpa: std.mem.Allocator, func: *val.Function) void {
    for (func.chunk.constants.items) |constant| {
        if (constant.isFunction()) {
            freeOwnedFunction(gpa, constant.asFunction());
        }
    }
    func.deinit();
    gpa.destroy(func);
}

const ClassCompiler = struct {
    enclosing: ?*ClassCompiler,
    has_superclass: bool,
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
current_class: ?*ClassCompiler,
parser: Parser,
print_code: bool,
filename: []const u8,
intern_ctx: *anyopaque,
intern_string_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!*val.HeapString,
reporter: ErrorReporter,

pub fn init(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    print_code: bool,
    filename: []const u8,
    intern_ctx: *anyopaque,
    intern_string_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!*val.HeapString,
) !Compiler {
    const script = try gpa.create(Compile);
    errdefer gpa.destroy(script);
    script.* = try Compile.init(gpa, .Script);
    return .{
        .allocator = gpa,
        .writer = writer,
        .print_code = print_code,
        .filename = filename,
        .intern_ctx = intern_ctx,
        .intern_string_fn = intern_string_fn,
        .reporter = ErrorReporter.init(gpa),
        .lexer = undefined,
        .current = script,
        .current_class = null,
        .parser = .{
            .current = undefined,
            .previous = undefined,
            .had_error = false,
            .panic_mode = false,
        },
    };
}

fn internCompileString(self: *Compiler, bytes: []const u8) !*val.HeapString {
    return self.intern_string_fn(self.intern_ctx, bytes);
}

pub fn deinit(self: *Compiler) void {
    self.reporter.deinit();
    var current = self.current;
    while (current.enclosing) |enclosing| {
        current.deinit();
        self.allocator.destroy(current);
        current = enclosing;
    }
    // Free the top-level compile struct and its function
    // Function already freed in endCompiler or will be freed by VM
    current.deinit();
    self.allocator.destroy(current);
}

/// Marks everything reachable from the functions still being compiled. Those
/// functions are owned by the compiler and absent from the heap object list, so
/// the collector cannot reach the constants they already hold - without this the
/// interned strings baked into a half-built chunk look unreachable and are swept.
pub fn markRoots(self: *Compiler, heap: *mem.Heap) !void {
    var scope: ?*Compile = self.current;
    while (scope) |current| {
        if (current.function) |func| {
            try markOwnedConstants(heap, func);
        }
        scope = current.enclosing;
    }
}

/// Marks a function's constants but not the function itself: a compiler owned
/// function is never swept, so setting its mark bit would leave it permanently
/// black and make later collections skip blackening its constants.
fn markOwnedConstants(heap: *mem.Heap, func: *val.Function) !void {
    for (func.chunk.constants.items) |constant| {
        if (constant.isFunction()) {
            try markOwnedConstants(heap, constant.asFunction());
        } else {
            try heap.markValue(constant);
        }
    }
}

pub fn compile(self: *Compiler, source: []const u8) !*val.Function {
    self.lexer = scan.Lexer.init(source);
    try self.reporter.addSource(self.filename, source);
    try self.advance();
    while (!self.check(.Eof)) {
        try self.declaration();
    }
    if (self.parser.had_error) {
        return e.Error.CompileError;
    }
    return try self.endCompiler();
}

pub fn reportErrorAt(
    self: *Compiler,
    start_line: usize,
    start_col: usize,
    end_line: usize,
    end_col: usize,
    message: []const u8,
) !void {
    // For single-character tokens, use the same start and end columns
    const col_end = if (end_col > start_col) end_col else start_col;

    const range = SourceRange.span(
        self.filename,
        start_line,
        start_col,
        end_line,
        col_end,
    );
    const diagnostic = Diagnostic.init(.err, message)
        .withRange(range);

    self.reporter.report(diagnostic);
}

fn advance(self: *Compiler) !void {
    self.parser.previous = self.parser.current;
    self.parser.current = self.lexer.scanToken() catch |lex_err| {
        switch (lex_err) {
            error.UnexpectedCharacter => try self.errorAtCurrent("Unexpected character found in source code."),
            error.UnterminatedString => try self.errorAtLexerScan("Unterminated string literal."),
        }
        // A lexical error is a compile error. Letting the scanner's own error
        // set escape sends `exitCode` down its `else` branch, which exits 1
        // instead of the 65 the language contract promises for a failed
        // compilation.
        return e.Error.CompileError;
    };
}

fn errorAtCurrent(self: *Compiler, message: []const u8) !void {
    try self.errorAt(&self.parser.current, message);
}

fn errorAtPrev(self: *Compiler, message: []const u8) !void {
    try self.errorAt(&self.parser.previous, message);
}

fn errorAtLexerScan(self: *Compiler, message: []const u8) !void {
    if (self.parser.panic_mode) {
        return;
    }
    self.parser.panic_mode = true;
    const col_end = if (self.lexer.col > self.lexer.start_col) self.lexer.col - 1 else self.lexer.start_col;
    try self.reportErrorAt(
        self.lexer.line,
        self.lexer.start_col,
        self.lexer.line,
        col_end,
        message,
    );
    self.parser.had_error = true;
}

fn errorAt(self: *Compiler, token: *scan.Token, message: []const u8) !void {
    if (self.parser.panic_mode) {
        return;
    }
    self.parser.panic_mode = true;

    try self.reportErrorAt(
        token.line,
        token.col_start,
        token.line,
        token.col_end,
        message,
    );
    self.parser.had_error = true;
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

/// Span of the token the current instruction is attributed to, used by both the
/// disassembler and the runtime error reporter.
fn previousPosition(self: *Compiler) Chunk.Position {
    return tokenPosition(&self.parser.previous);
}

fn tokenPosition(token: *const scan.Token) Chunk.Position {
    const span = if (token.col_end >= token.col_start) token.col_end - token.col_start + 1 else 1;
    return .{
        .line = std.math.cast(u32, token.line) orelse std.math.maxInt(u32),
        .col = std.math.cast(u16, token.col_start) orelse std.math.maxInt(u16),
        .len = std.math.cast(u16, span) orelse std.math.maxInt(u16),
    };
}

fn emitOpcode(self: *Compiler, opcode: Chunk.OpCode) !void {
    try self.currentChunk().writeCode(opcode, self.previousPosition());
}

fn emitOperand(self: *Compiler, value: usize) !void {
    try self.currentChunk().writeOperand(value, self.previousPosition());
}

fn emitConstantOpcode(self: *Compiler, short_op: Chunk.OpCode, ix: usize) !void {
    try self.currentChunk().writeIndexedOpcode(short_op, ix, self.previousPosition());
}

fn emitLoop(self: *Compiler, loop_start: usize) !void {
    try self.emitOpcode(.Loop);
    const offset = self.currentChunk().codeSize() - loop_start + 2;
    if (offset > std.math.maxInt(u16)) {
        try self.errorAtPrev("Loop body too large.");
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
        try self.errorAtPrev("Too much code to jump over.");
    }

    self.currentChunk().code.items[offset] = @truncate(jump & 0xff);
    self.currentChunk().code.items[offset + 1] = @truncate((jump >> 8) & 0xff);
}

fn emitReturn(self: *Compiler) !void {
    if (self.current.function_type == .TypeInitializer) {
        try self.emitOpcode(.GetLocal);
        try self.emitOperand(0);
    } else {
        try self.emitOpcode(.Nil);
    }
    try self.emitOpcode(.Return);
}

fn emitConstant(self: *Compiler, value: val.LoxValue) !void {
    const ix = try self.currentChunk().addConstant(value);
    try self.currentChunk().writeConstant(ix, self.previousPosition());
}

fn makeConstant(self: *Compiler, value: val.LoxValue) !usize {
    return try self.currentChunk().addConstant(value);
}

fn endCompiler(self: *Compiler) !*val.Function {
    try self.emitReturn();
    const fun_ptr = self.current.function.?;
    if (!self.parser.had_error and self.print_code) {
        try self.currentChunk().disassembly(self.writer, fun_ptr.name);
    }
    // Ownership transfers to caller (VM), nullify the function in compiler
    // to prevent double-free when compiler is deinitialized
    self.current.function = null;
    return fun_ptr;
}

fn beginScope(self: *Compiler) void {
    self.current.scope_depth += 1;
}

fn endScope(self: *Compiler) !void {
    self.current.scope_depth -= 1;
    while (self.current.local_count > 0 and self.current.locals[self.current.local_count - 1].depth > self.current.scope_depth) {
        if (self.current.locals[self.current.local_count - 1].is_captured) {
            try self.emitOpcode(.CloseUpvalue);
        } else {
            try self.emitOpcode(.Pop);
        }
        self.current.local_count -= 1;
    }
}

fn grouping(self: *Compiler) !void {
    try self.expression();
    try self.consume(.RightParen, "Expect ')' after expression.");
}

fn lexeme(self: *Compiler, token: *const scan.Token) []const u8 {
    if (token.text) |t| return t;
    return self.lexer.source[token.start .. token.start + token.length];
}

fn number(self: *Compiler) !void {
    const s = self.lexeme(&self.parser.previous);
    const value = try std.fmt.parseFloat(f64, s);

    _ = try self.emitConstant(LoxValue.number(value));
}

fn string(self: *Compiler) !void {
    const s = self.lexeme(&self.parser.previous);
    const content = s[1 .. s.len - 1];
    if (content.len <= val.SHORT_STRING_MAX_LEN) {
        _ = try self.emitConstant(LoxValue.shortString(content));
    } else {
        const interned = try self.internCompileString(content);
        _ = try self.emitConstant(LoxValue.string(interned));
    }
}

fn variable(self: *Compiler, can_assign: bool) !void {
    try self.namedVariable(&self.parser.previous, can_assign);
}

fn syntheticToken(comptime name: []const u8) scan.Token {
    return .{
        .type = .Identifier,
        .start = 0,
        .length = name.len,
        .line = 0,
        .col_start = 0,
        .col_end = 0,
        .text = name,
    };
}

fn super_(self: *Compiler) !void {
    if (self.current_class == null) {
        try self.errorAtPrev("Can't use 'super' outside of a class.");
    } else if (!self.current_class.?.has_superclass) {
        try self.errorAtPrev("Can't use 'super' in a class with no superclass.");
    }
    try self.consume(.Dot, "Expect '.' after 'super'.");
    try self.consume(.Identifier, "Expect superclass method name.");
    const name = try self.identifierConstant(&self.parser.previous);
    try self.namedVariable(&syntheticToken("this"), false);

    if (try self.match(.LeftParen)) {
        const arg_count = try self.argumentList();
        try self.namedVariable(&syntheticToken("super"), false);
        try self.emitConstantOpcode(.SuperInvoke, name);
        try self.emitOperand(arg_count);
    } else {
        try self.namedVariable(&syntheticToken("super"), false);
        try self.emitConstantOpcode(.GetSuper, name);
    }
}

fn this_(self: *Compiler) !void {
    if (self.current_class == null) {
        try self.errorAtPrev("Can't use 'this' outside of a class.");
        return;
    }
    try self.variable(false);
}

fn namedVariable(self: *Compiler, token: *const scan.Token, can_assign: bool) !void {
    var get_op: Chunk.OpCode = undefined;
    var set_op: Chunk.OpCode = undefined;
    var arg: ?usize = null;
    if (try self.resolveLocal(self.current, token)) |local| {
        get_op = .GetLocal;
        set_op = .SetLocal;
        arg = local;
    } else if (try self.resolveUpvalue(self.current, token)) |upvalue| {
        get_op = .GetUpvalue;
        set_op = .SetUpvalue;
        arg = upvalue;
    } else {
        arg = try self.identifierConstant(token);
        get_op = .GetGlobal;
        set_op = .SetGlobal;
    }

    if (can_assign and try self.match(.Equal)) {
        try self.expression();
        try self.currentChunk().writeIndexedOpcode(set_op, arg.?, self.previousPosition());
    } else {
        try self.currentChunk().writeIndexedOpcode(get_op, arg.?, self.previousPosition());
    }
}

fn resolveUpvalue(self: *Compiler, compiler: *Compile, token: *const scan.Token) !?usize {
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
    const upvalue_count = compiler.function.?.upvalue_count;
    for (0..upvalue_count) |ix| {
        if (compiler.upvalues[ix].index == index and compiler.upvalues[ix].is_local == is_local) {
            return ix;
        }
    }

    if (upvalue_count == LOCALS_MAX) {
        try self.errorAtPrev("Too many closure variables in function.");
        return 0;
    }

    compiler.upvalues[upvalue_count].is_local = is_local;
    compiler.upvalues[upvalue_count].index = index;
    compiler.function.?.upvalue_count += 1;
    return upvalue_count;
}

fn resolveLocal(self: *Compiler, compiler: *Compile, token: *const scan.Token) !?usize {
    var i: usize = compiler.local_count;
    while (i > 0) : (i -= 1) {
        const local = compiler.locals[i - 1];

        if (std.mem.eql(u8, self.lexeme(token), local.name)) {
            if (local.depth == -1) {
                try self.errorAtPrev("Can't read local variable in its own initializer.");
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
    const operator_type = self.parser.previous.type;
    try self.parsePrecedence(.Unary);
    switch (operator_type) {
        .Minus => try self.emitOpcode(.Negate),
        .Bang => try self.emitOpcode(.Not),
        else => {
            return;
        },
    }
}

fn binary(self: *Compiler) !void {
    const operator_type = self.parser.previous.type;
    const precedence = getPrecedence(operator_type);
    try self.parsePrecedence(@enumFromInt(@intFromEnum(precedence) + 1));
    switch (operator_type) {
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

fn dot(self: *Compiler, can_assign: bool) !void {
    try self.consume(.Identifier, "Expect property name after '.'.");
    const name = try self.identifierConstant(&self.parser.previous);
    if (can_assign and try self.match(.Equal)) {
        try self.expression();
        try self.emitConstantOpcode(.SetProperty, name);
    } else if (try self.match(.LeftParen)) {
        const arg_count = try self.argumentList();
        try self.emitConstantOpcode(.Invoke, name);
        try self.emitOperand(arg_count);
    } else {
        try self.emitConstantOpcode(.GetProperty, name);
    }
}

fn getPrecedence(token_type: scan.TokenType) Precedence {
    return switch (token_type) {
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
    if (!try self.callPrefix(self.parser.previous.type, can_assign)) {
        return;
    }
    while (@intFromEnum(getPrecedence(self.parser.current.type)) >= @intFromEnum(precedence)) {
        try self.advance();
        try self.callInfix(self.parser.previous.type, can_assign);
    }
    if (can_assign and try self.match(.Equal)) {
        try self.errorAtPrev("Invalid assignment target.");
    }
}

fn markInitialized(self: *Compiler) void {
    if (self.current.scope_depth == 0) {
        return;
    }
    self.current.locals[self.current.local_count - 1].depth = self.current.scope_depth;
}

fn parseVariable(self: *Compiler, message: []const u8) anyerror!usize {
    try self.consume(.Identifier, message);
    try self.declareVariable();
    if (self.current.scope_depth > 0) {
        return 0;
    }
    return try self.identifierConstant(&self.parser.previous);
}

fn defineVariable(self: *Compiler, global: usize) anyerror!void {
    if (self.current.scope_depth > 0) {
        self.markInitialized();
        return;
    }
    try self.currentChunk().writeIndexedOpcode(.DefineGlobal, global, self.previousPosition());
}

fn argumentList(self: *Compiler) anyerror!usize {
    var arg_count: usize = 0;
    if (!self.check(.RightParen)) {
        while (true) {
            try self.expression();
            if (arg_count == 255) {
                try self.errorAtPrev("Can't have more than 255 arguments.");
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
    const end_jump = try self.emitJump(.JumpIfFalse);
    try self.emitOpcode(.Pop);
    try self.parsePrecedence(.And);
    try self.patchJump(end_jump);
}

fn or_(self: *Compiler) !void {
    const else_jump = try self.emitJump(.JumpIfFalse);
    const end_jump = try self.emitJump(.Jump);
    try self.patchJump(else_jump);
    try self.emitOpcode(.Pop);
    try self.parsePrecedence(.Or);
    try self.patchJump(end_jump);
}

fn identifierConstant(self: *Compiler, token: *const scan.Token) anyerror!usize {
    const interned = try self.internCompileString(self.lexeme(token));
    return try self.makeConstant(LoxValue.string(interned));
}

fn addLocal(self: *Compiler, token: *const scan.Token) !void {
    if (self.current.local_count == LOCALS_MAX) {
        try self.errorAtPrev("Too many local variables in function.");
        return;
    }
    var local = &self.current.locals[self.current.local_count];
    self.current.local_count += 1;
    local.name = self.lexeme(token);
    local.depth = -1; // Uninitialized
    local.is_captured = false;
}

fn declareVariable(self: *Compiler) !void {
    if (self.current.scope_depth == 0) {
        return;
    }
    var i: usize = self.current.local_count;
    while (i > 0) {
        i -= 1;
        const local = &self.current.locals[i];

        if (local.depth != -1 and local.depth < self.current.scope_depth) {
            break;
        }

        const name = self.lexeme(&self.parser.previous);
        if (std.mem.eql(u8, name, local.name)) {
            try self.errorAtPrev("Already a variable with this name in this scope.");
        }
    }

    try self.addLocal(&self.parser.previous);
}

/// Returns false when the token has no prefix rule, so the caller can stop
/// instead of building an expression around a value that was never pushed.
fn callPrefix(self: *Compiler, token_type: scan.TokenType, can_assign: bool) !bool {
    switch (token_type) {
        .Minus, .Bang => try self.unary(),
        .LeftParen => try self.grouping(),
        .Number => try self.number(),
        .String => try self.string(),
        .Identifier => try self.variable(can_assign),
        .This => try self.this_(),
        .Super => try self.super_(),
        .True, .False, .Nil => try self.literal(),

        else => {
            try self.errorAtPrev("Expect expression.");
            return false;
        },
    }
    return true;
}

fn callInfix(self: *Compiler, token_type: scan.TokenType, can_assign: bool) !void {
    switch (token_type) {
        .Minus, .Plus, .Slash, .Star, .BangEqual, .EqualEqual, .Greater, .GreaterEqual, .Less, .LessEqual => try self.binary(),
        .And => try self.and_(),
        .Or => try self.or_(),
        .LeftParen => try self.call(can_assign),
        .Dot => try self.dot(can_assign),
        else => {},
    }
}

fn currentChunk(self: *Compiler) *Chunk {
    return &self.current.function.?.chunk;
}

fn expression(self: *Compiler) !void {
    try self.parsePrecedence(.Assignment);
}

fn ifStatement(self: *Compiler) anyerror!void {
    try self.consume(.LeftParen, "Expect '(' after 'if'.");
    try self.expression();
    try self.consume(.RightParen, "Expect ')' after condition.");
    const then_jump = try self.emitJump(.JumpIfFalse);
    try self.emitOpcode(.Pop);
    try self.statement();
    const else_jump = try self.emitJump(.Jump);
    try self.patchJump(then_jump);
    try self.emitOpcode(.Pop);
    if (try self.match(.Else)) {
        try self.statement();
    }
    try self.patchJump(else_jump);
}

fn returnStatement(self: *Compiler) anyerror!void {
    if (self.current.function_type == .Script) {
        try self.errorAtPrev("Can't return from top-level code.");
    }
    if (try self.match(.Semicolon)) {
        try self.emitReturn();
    } else {
        if (self.current.function_type == .TypeInitializer) {
            try self.errorAtCurrent("Can't return a value from an initializer.");
        }
        try self.expression();
        try self.consume(.Semicolon, "Expect ';' after return value.");
        try self.emitOpcode(.Return);
    }
}

fn whileStatement(self: *Compiler) anyerror!void {
    const loop_start = self.currentChunk().codeSize();
    try self.consume(.LeftParen, "Expect '(' after 'while'.");
    try self.expression();
    try self.consume(.RightParen, "Expect ')' after condition.");

    const exit_jump = try self.emitJump(.JumpIfFalse);
    try self.emitOpcode(.Pop);
    try self.statement();
    try self.emitLoop(loop_start);

    try self.patchJump(exit_jump);
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

    var loop_start = self.currentChunk().codeSize();
    var exit_jump: ?usize = null;
    if (!try self.match(.Semicolon)) {
        try self.expression();
        try self.consume(.Semicolon, "Expect ';' after loop condition.");

        // Jump out of the loop if the condition is false.
        exit_jump = try self.emitJump(.JumpIfFalse);
        try self.emitOpcode(.Pop); // Condition.
    }

    if (!try self.match(.RightParen)) {
        const body_jump = try self.emitJump(.Jump);
        const increment_start = self.currentChunk().codeSize();
        try self.expression();
        try self.emitOpcode(.Pop);
        try self.consume(.RightParen, "Expect ')' after for clauses.");
        try self.emitLoop(loop_start);
        loop_start = increment_start;
        try self.patchJump(body_jump);
    }

    try self.statement();
    try self.emitLoop(loop_start);
    if (exit_jump != null) {
        try self.patchJump(exit_jump.?);
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
    var compiler = try Compile.init(self.allocator, function_type);
    compiler.enclosing = old_compiler;
    compiler.function.?.name = self.lexeme(&self.parser.previous);
    const new_compile = try self.allocator.create(Compile);
    new_compile.* = compiler;
    self.current = new_compile;

    self.beginScope();
    try self.consume(.LeftParen, "Expect '(' after function name.");

    if (!self.check(.RightParen)) {
        while (true) {
            self.current.function.?.arity += 1;
            if (self.current.function.?.arity > 255) {
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

    // Save upvalue_count before calling endCompiler (which nullifies function)
    const upvalue_count = new_compile.function.?.upvalue_count;
    var upvalues: [LOCALS_MAX]Upvalue = undefined;
    for (0..upvalue_count) |i| {
        upvalues[i] = new_compile.upvalues[i];
    }

    const func = try self.endCompiler();

    // Restore current to the enclosing compiler so defineVariable works correctly.
    self.current = old_compiler;

    new_compile.deinit();
    self.allocator.destroy(new_compile);

    const ix = try self.currentChunk().addConstant(LoxValue.function(func));
    try self.emitConstantOpcode(.Closure, ix);
    for (0..upvalue_count) |i| {
        const is_local: usize = if (upvalues[i].is_local) 1 else 0;
        try self.emitOperand(is_local);
        try self.emitOperand(upvalues[i].index);
    }
}

fn method(self: *Compiler) !void {
    try self.consume(.Identifier, "Expect method name.");
    const method_constant = try self.identifierConstant(&self.parser.previous);
    const function_type: FunctionType = if (self.lexeme(&self.parser.previous).len == 4 and
        std.mem.eql(u8, self.lexeme(&self.parser.previous), "init"))
        .TypeInitializer
    else
        .Method;
    try self.function(function_type);
    try self.emitConstantOpcode(.Method, method_constant);
}

fn classDeclaration(self: *Compiler) !void {
    try self.consume(.Identifier, "Expect class name.");
    var class_name = self.parser.previous;
    const name_constant = try self.identifierConstant(&class_name);
    try self.declareVariable();
    try self.emitConstantOpcode(.Class, name_constant);
    try self.defineVariable(name_constant);

    var class_compiler = ClassCompiler{
        .enclosing = self.current_class,
        .has_superclass = false,
    };
    self.current_class = &class_compiler;
    defer self.current_class = class_compiler.enclosing;

    if (try self.match(.Less)) {
        try self.consume(.Identifier, "Expect superclass name.");
        try self.variable(false);

        if (std.mem.eql(u8, self.lexeme(&class_name), self.lexeme(&self.parser.previous))) {
            try self.errorAtPrev("A class can't inherit from itself.");
        }
        self.beginScope();
        try self.addLocal(&syntheticToken("super"));
        try self.defineVariable(0);

        try self.namedVariable(&class_name, false);
        try self.emitOpcode(.Inherit);
        class_compiler.has_superclass = true;
    }

    try self.namedVariable(&class_name, false);
    try self.consume(.LeftBrace, "Expect '{' before class body.");
    while (!self.check(.RightBrace) and !self.check(.Eof)) {
        try self.method();
    }
    try self.consume(.RightBrace, "Expect '}' after class body.");
    try self.emitOpcode(.Pop);
    if (class_compiler.has_superclass) {
        try self.endScope();
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
    if (try self.match(.Class)) {
        try self.classDeclaration();
    } else if (try self.match(.Fun)) {
        try self.funDeclaration();
    } else if (try self.match(.Var)) {
        try self.varDeclaration();
    } else {
        try self.statement();
    }
    if (self.parser.panic_mode) {
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
    self.parser.panic_mode = false;
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
