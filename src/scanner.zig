pub const Lexer = @This();

const std = @import("std");

pub const LexerError = error{
    UnexpectedCharacter,
    UnterminatedString,
};

pub const TokenType = enum {
    LeftParen,
    RightParen,
    LeftBrace,
    RightBrace,
    Comma,
    Dot,
    Minus,
    Plus,
    Semicolon,
    Slash,
    Star,
    Bang,
    BangEqual,
    Equal,
    EqualEqual,
    Greater,
    GreaterEqual,
    Less,
    LessEqual,
    Identifier,
    String,
    Number,
    And,
    Class,
    Else,
    False,
    Fun,
    For,
    If,
    Nil,
    Or,
    Print,
    Return,
    Super,
    This,
    True,
    Var,
    While,
    Eof,
};

/// Where the text scanned so far for the token in progress begins and ends.
/// A lexical error hands back no token, so this is the only description of
/// what went wrong that survives it.
pub const Span = struct {
    line: usize,
    col_start: usize,
    col_end: usize,
};

pub const Token = struct {
    type: TokenType,
    start: usize,
    length: usize,
    line: usize,
    col_start: usize,
    col_end: usize,
    text: ?[]const u8 = null, // only syntetic
};

source: []const u8,
start: usize,
current: usize,
line: usize,
col: usize,
start_col: usize,
/// Line the token in progress began on, which is not `line` once the token
/// has run over a newline - as an unterminated string literal does.
start_line: usize,

pub fn init(source: []const u8) Lexer {
    return Lexer{
        .source = source,
        .start = 0,
        .current = 0,
        .line = 1,
        .col = 1,
        .start_col = 1,
        .start_line = 1,
    };
}

pub fn span(self: *const Lexer) Span {
    // `col` sits one past the last character consumed, and is a column on
    // `line` - which is only the token's own line while the token has not run
    // over a newline. Once it has, all that can be pointed at is where it
    // started.
    const ends_where_it_began = self.line != self.start_line or self.col <= self.start_col;
    return .{
        .line = self.start_line,
        .col_start = self.start_col,
        .col_end = if (ends_where_it_began) self.start_col else self.col - 1,
    };
}

pub fn scanToken(self: *Lexer) LexerError!Token {
    self.skipWhitespace();
    self.start = self.current;
    self.start_col = self.col;
    self.start_line = self.line;
    if (self.isAtEnd()) {
        // For EOF token, use the position at the end of the file
        // col_start and col_end should point to the end of the last line
        const eof_col = if (self.col > 1) self.col - 1 else 1;
        return Token{
            .type = .Eof,
            .start = self.current,
            .length = 0,
            .line = self.line,
            .col_start = eof_col,
            .col_end = eof_col,
        };
    }
    const c = self.advance();
    return switch (c) {
        '(' => self.makeToken(.LeftParen),
        ')' => self.makeToken(.RightParen),
        '{' => self.makeToken(.LeftBrace),
        '}' => self.makeToken(.RightBrace),
        ',' => self.makeToken(.Comma),
        '.' => self.makeToken(.Dot),
        '-' => self.makeToken(.Minus),
        '+' => self.makeToken(.Plus),
        ';' => self.makeToken(.Semicolon),
        '*' => self.makeToken(.Star),
        '/' => self.makeToken(.Slash),
        '0'...'9' => self.number(),
        'A'...'Z', 'a'...'z', '_' => self.identifier(),
        '!' => {
            if (self.match('=')) {
                return self.makeToken(.BangEqual);
            } else {
                return self.makeToken(.Bang);
            }
        },
        '=' => {
            if (self.match('=')) {
                return self.makeToken(.EqualEqual);
            } else {
                return self.makeToken(.Equal);
            }
        },
        '<' => {
            if (self.match('=')) {
                return self.makeToken(.LessEqual);
            } else {
                return self.makeToken(.Less);
            }
        },
        '>' => {
            if (self.match('=')) {
                return self.makeToken(.GreaterEqual);
            } else {
                return self.makeToken(.Greater);
            }
        },
        '"' => self.string(),
        else => {
            std.log.debug("invalid char is: 0x{X}", .{c});
            return LexerError.UnexpectedCharacter;
        },
    };
}

/// A token is placed on the line it starts on. Only a string literal can run
/// over a newline, and then its end column belongs to a later line, so its
/// span is cut down to the opening quote the way `span` does it.
fn makeToken(self: *Lexer, token_type: TokenType) Token {
    const scanned = self.span();
    return Token{
        .type = token_type,
        .start = self.start,
        .length = self.current - self.start,
        .line = scanned.line,
        .col_start = scanned.col_start,
        .col_end = scanned.col_end,
    };
}

/// The source is a slice with a length, not a C string, so its end is that
/// length and nothing else. Treating a NUL byte as the end too - which is what
/// clox does, because there it really is the terminator - silently dropped
/// everything after the first one in a file that happened to contain it.
/// A NUL now reaches `scanToken` like any other byte and is reported as an
/// unexpected character, unless it sits inside a string literal.
fn isAtEnd(self: *Lexer) bool {
    return self.current >= self.source.len;
}

fn isDigit(c: u8) bool {
    return std.ascii.isDigit(c);
}

fn isAlpha(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn number(self: *Lexer) Token {
    while (isDigit(self.peek())) {
        _ = self.advance();
    }

    // Look for a fractional part.
    if (self.peek() == '.' and isDigit(self.peekNext())) {
        // Consume the ".".
        _ = self.advance();

        // Read fractional
        while (isDigit(self.peek())) {
            _ = self.advance();
        }
    }

    return self.makeToken(.Number);
}

fn identifier(self: *Lexer) Token {
    while (isAlpha(self.peek()) or isDigit(self.peek())) {
        _ = self.advance();
    }

    return self.makeToken(self.identifierType());
}

fn identifierType(self: *Lexer) TokenType {
    const len = self.current - self.start;
    return switch (self.source[self.start]) {
        'a' => self.checkKeyword(1, 2, "nd", .And),
        'c' => self.checkKeyword(1, 4, "lass", .Class),
        'e' => self.checkKeyword(1, 3, "lse", .Else),
        'f' => if (len >= 2) switch (self.source[self.start + 1]) {
            'a' => self.checkKeyword(2, 3, "lse", .False),
            'o' => self.checkKeyword(2, 1, "r", .For),
            'u' => self.checkKeyword(2, 1, "n", .Fun),
            else => .Identifier,
        } else .Identifier,
        'i' => self.checkKeyword(1, 1, "f", .If),
        'n' => self.checkKeyword(1, 2, "il", .Nil),
        'o' => self.checkKeyword(1, 1, "r", .Or),
        'p' => self.checkKeyword(1, 4, "rint", .Print),
        'r' => self.checkKeyword(1, 5, "eturn", .Return),
        's' => self.checkKeyword(1, 4, "uper", .Super),
        't' => if (len >= 2) switch (self.source[self.start + 1]) {
            'r' => self.checkKeyword(2, 2, "ue", .True),
            'h' => self.checkKeyword(2, 2, "is", .This),
            else => .Identifier,
        } else .Identifier,
        'v' => self.checkKeyword(1, 2, "ar", .Var),
        'w' => self.checkKeyword(1, 4, "hile", .While),
        else => .Identifier,
    };
}

fn checkKeyword(self: *Lexer, start: usize, length: usize, rest: []const u8, token_type: TokenType) TokenType {
    const current_len = self.current - self.start;

    if (current_len == start + length) {
        const lexeme = self.source[self.start + start .. self.start + start + length];

        if (std.mem.eql(u8, lexeme, rest)) {
            return token_type;
        }
    }

    return .Identifier;
}

fn match(self: *Lexer, expected: u8) bool {
    if (self.isAtEnd()) {
        return false;
    }
    if (self.source[self.current] != expected) {
        return false;
    }
    _ = self.advance();
    return true;
}

fn advance(self: *Lexer) u8 {
    const c = self.source[self.current];
    self.current += 1;
    if (c == '\n') {
        self.line += 1;
        self.col = 1;
    } else if (!isUtf8Continuation(c)) {
        self.col += 1;
    }
    return c;
}

/// Columns count characters, not bytes: the reporter pads the caret line
/// with one space per column, so a multibyte character counted per byte
/// shifts every mark after it on the line. Only a character's first byte
/// moves the column.
fn isUtf8Continuation(c: u8) bool {
    return c & 0xC0 == 0x80;
}

fn peek(self: *Lexer) u8 {
    if (self.isAtEnd()) {
        return '\x00';
    }
    return self.source[self.current];
}

fn peekNext(self: *Lexer) u8 {
    if (self.current + 1 >= self.source.len) {
        return '\x00';
    }
    return self.source[self.current + 1];
}

fn skipWhitespace(self: *Lexer) void {
    while (!self.isAtEnd()) {
        const c = self.peek();
        switch (c) {
            ' ', '\r', '\t', '\n' => _ = self.advance(),
            '/' => {
                if (self.peekNext() == '/') {
                    while (!self.isAtEnd() and self.peek() != '\n') {
                        _ = self.advance();
                    }
                } else {
                    return;
                }
            },
            else => return,
        }
    }
}

fn string(self: *Lexer) !Token {
    while (self.peek() != '"' and !self.isAtEnd()) {
        _ = self.advance();
    }

    if (self.isAtEnd()) {
        return LexerError.UnterminatedString;
    }

    _ = self.advance();
    return self.makeToken(.String);
}

test "NUL byte does not end the source" {
    // Arrange: a file with an embedded NUL used to be truncated at it without
    // a word, so everything past it was never compiled.
    var lexer = Lexer.init("a\x00b");

    // Act
    const first = try lexer.scanToken();
    const second = lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Identifier, first.type);
    try std.testing.expectError(LexerError.UnexpectedCharacter, second);
}

test "NUL byte inside a string literal is part of it" {
    // Arrange
    var lexer = Lexer.init("\"a\x00b\"");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.String, token.type);
    try std.testing.expectEqual(@as(usize, 5), token.length);
}

test "a string literal over a newline is placed where it opens" {
    // Arrange
    var lexer = Lexer.init("print \"a\nbc\";");
    _ = try lexer.scanToken();

    // Act
    const token = try lexer.scanToken();

    // Assert: the end column belongs to line 2, so only the quote is kept.
    try std.testing.expectEqual(.String, token.type);
    try std.testing.expectEqual(@as(usize, 1), token.line);
    try std.testing.expectEqual(@as(usize, 7), token.col_start);
    try std.testing.expectEqual(@as(usize, 7), token.col_end);
}

test "columns after a multibyte character count characters" {
    // Arrange: two-byte Cyrillic and Latin letters inside a literal, then a
    // token after it on the same line.
    var lexer = Lexer.init("var s = \"ыé\"; x");
    for (0..3) |_| _ = try lexer.scanToken();

    // Act
    const literal = try lexer.scanToken();
    _ = try lexer.scanToken();
    const after = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(@as(usize, 9), literal.col_start);
    try std.testing.expectEqual(@as(usize, 12), literal.col_end);
    try std.testing.expectEqual(@as(usize, 15), after.col_start);
    try std.testing.expectEqual(@as(usize, 15), after.col_end);
}

test "decimal after a multibyte string keeps its fraction" {
    // Arrange
    const source = "\"é\" 1.5";
    var lexer = Lexer.init(source);
    _ = try lexer.scanToken();

    // Act
    const number_token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Number, number_token.type);
    try std.testing.expectEqualStrings("1.5", source[number_token.start..][0..number_token.length]);
}

test "decimal after a multibyte comment keeps its fraction" {
    // Arrange
    const source = "// é\n1.5";
    var lexer = Lexer.init(source);

    // Act
    const number_token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Number, number_token.type);
    try std.testing.expectEqualStrings("1.5", source[number_token.start..][0..number_token.length]);
}

test "span of an unexpected character covers just that character" {
    // Arrange
    var lexer = Lexer.init("@");

    // Act
    const result = lexer.scanToken();

    // Assert
    try std.testing.expectError(LexerError.UnexpectedCharacter, result);
    try std.testing.expectEqual(Span{ .line = 1, .col_start = 1, .col_end = 1 }, lexer.span());
}

test "span of an unexpected character stays on its own line" {
    // Arrange
    var lexer = Lexer.init("print 1;\n@");
    _ = try lexer.scanToken();
    _ = try lexer.scanToken();
    _ = try lexer.scanToken();

    // Act
    const result = lexer.scanToken();

    // Assert
    try std.testing.expectError(LexerError.UnexpectedCharacter, result);
    try std.testing.expectEqual(Span{ .line = 2, .col_start = 1, .col_end = 1 }, lexer.span());
}

test "span of an unterminated string that ran over a newline points at its start" {
    // Arrange
    var lexer = Lexer.init("var s = \"no close\nand more text here");
    _ = try lexer.scanToken();
    _ = try lexer.scanToken();
    _ = try lexer.scanToken();

    // Act
    const result = lexer.scanToken();

    // Assert: the scan stopped two lines down, but the literal opened here.
    try std.testing.expectError(LexerError.UnterminatedString, result);
    try std.testing.expectEqual(Span{ .line = 1, .col_start = 9, .col_end = 9 }, lexer.span());
}

test "span of an unterminated string covers the literal" {
    // Arrange
    var lexer = Lexer.init("var s = \"no close");

    // Act
    _ = try lexer.scanToken();
    _ = try lexer.scanToken();
    _ = try lexer.scanToken();
    const result = lexer.scanToken();

    // Assert
    try std.testing.expectError(LexerError.UnterminatedString, result);
    try std.testing.expectEqual(Span{ .line = 1, .col_start = 9, .col_end = 17 }, lexer.span());
}

test "Left paren" {
    // Arrange
    var lexer = Lexer.init("(");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.LeftParen, token.type);
}

test "Bang tests" {
    // Arrange
    var lexer = Lexer.init("!!=");

    // Act
    const token1 = try lexer.scanToken();
    const token2 = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Bang, token1.type);
    try std.testing.expectEqual(.BangEqual, token2.type);
}

test "Token columns restart on the next line" {
    // Arrange
    var lexer = Lexer.init("var a;\nvar bb;");

    // Act
    _ = try lexer.scanToken();
    _ = try lexer.scanToken();
    _ = try lexer.scanToken();
    const keyword = try lexer.scanToken();
    const name = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(@as(usize, 2), keyword.line);
    try std.testing.expectEqual(@as(usize, 1), keyword.col_start);
    try std.testing.expectEqual(@as(usize, 3), keyword.col_end);
    try std.testing.expectEqual(@as(usize, 5), name.col_start);
    try std.testing.expectEqual(@as(usize, 6), name.col_end);
}

test "Two character operator spans both columns" {
    // Arrange
    var lexer = Lexer.init("a != b");

    // Act
    _ = try lexer.scanToken();
    const operator = try lexer.scanToken();
    const operand = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.BangEqual, operator.type);
    try std.testing.expectEqual(@as(usize, 3), operator.col_start);
    try std.testing.expectEqual(@as(usize, 4), operator.col_end);
    try std.testing.expectEqual(@as(usize, 6), operand.col_start);
    try std.testing.expectEqual(@as(usize, 6), operand.col_end);
}

test "Line counted after multiline string" {
    // Arrange
    var lexer = Lexer.init("\"one\ntwo\";\nvar a;");

    // Act
    _ = try lexer.scanToken();
    _ = try lexer.scanToken();
    const keyword = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Var, keyword.type);
    try std.testing.expectEqual(@as(usize, 3), keyword.line);
    try std.testing.expectEqual(@as(usize, 1), keyword.col_start);
    try std.testing.expectEqual(@as(usize, 3), keyword.col_end);
}

test "Only comment test" {
    // Arrange
    var lexer = Lexer.init("// Comment");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Eof, token.type);
}

test "Not comment and comment test" {
    // Arrange
    var lexer = Lexer.init("! // Comment");

    // Act
    const token1 = try lexer.scanToken();
    const token2 = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Bang, token1.type);
    try std.testing.expectEqual(.Eof, token2.type);
}

test "String test" {
    // Arrange
    var lexer = Lexer.init("\"test\"");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.String, token.type);
}

test "unterminated string" {
    // Arrange
    var lexer = Lexer.init("\"no close");

    // Act + Assert
    try std.testing.expectError(LexerError.UnterminatedString, lexer.scanToken());
}

test "Number test" {
    // Arrange
    var lexer = Lexer.init("123.0");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Number, token.type);
}

test "Identifier test" {
    // Arrange
    var lexer = Lexer.init("test");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Identifier, token.type);
}

test "Keyword print" {
    // Arrange
    var lexer = Lexer.init("print");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Print, token.type);
}

test "Keyword and" {
    // Arrange
    var lexer = Lexer.init("and");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.And, token.type);
}

test "Keyword class" {
    // Arrange
    var lexer = Lexer.init("class");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Class, token.type);
}

test "Keyword else" {
    // Arrange
    var lexer = Lexer.init("else");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Else, token.type);
}

test "Keyword false" {
    // Arrange
    var lexer = Lexer.init("false");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.False, token.type);
}

test "Keyword fun" {
    // Arrange
    var lexer = Lexer.init("fun");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Fun, token.type);
}

test "Keyword for" {
    // Arrange
    var lexer = Lexer.init("for");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.For, token.type);
}

test "Keyword if" {
    // Arrange
    var lexer = Lexer.init("if");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.If, token.type);
}

test "Keyword nil" {
    // Arrange
    var lexer = Lexer.init("nil");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Nil, token.type);
}

test "Keyword or" {
    // Arrange
    var lexer = Lexer.init("or");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Or, token.type);
}

test "Keyword return" {
    // Arrange
    var lexer = Lexer.init("return");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Return, token.type);
}

test "Keyword super" {
    // Arrange
    var lexer = Lexer.init("super");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Super, token.type);
}

test "Keyword this" {
    // Arrange
    var lexer = Lexer.init("this");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.This, token.type);
}

test "Keyword true" {
    // Arrange
    var lexer = Lexer.init("true");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.True, token.type);
}

test "Keyword var" {
    // Arrange
    var lexer = Lexer.init("var");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Var, token.type);
}

test "Keyword while" {
    // Arrange
    var lexer = Lexer.init("while");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.While, token.type);
}

test "Single letter t identifier" {
    // Arrange
    var lexer = Lexer.init("t");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Identifier, token.type);
}

test "Single letter f identifier" {
    // Arrange
    var lexer = Lexer.init("f");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Identifier, token.type);
}

test "Leading underscore identifier" {
    // Arrange
    var lexer = Lexer.init("_name");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Identifier, token.type);
    try std.testing.expectEqual(5, token.length);
}

test "Lone underscore identifier" {
    // Arrange
    var lexer = Lexer.init("_");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Identifier, token.type);
    try std.testing.expectEqual(1, token.length);
}

test "Underscore before a keyword is an identifier" {
    // Arrange
    var lexer = Lexer.init("_class");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(.Identifier, token.type);
    try std.testing.expectEqual(6, token.length);
}

test "Tree benchmark lexer test" {
    const code =
        \\class Tree {
        \\  init(item, depth) {
        \\    this.item = item;
        \\    this.depth = depth;
        \\    if (depth > 0) {
        \\      var item2 = item + item;
        \\      depth = depth - 1;
        \\      this.left = Tree(item2 - 1, depth);
        \\      this.right = Tree(item2, depth);
        \\    } else {
        \\      this.left = nil;
        \\      this.right = nil;
        \\    }
        \\  }
        \\
        \\  check() {
        \\    if (this.left == nil) {
        \\      return this.item;
        \\    }
        \\
        \\    return this.item + this.left.check() - this.right.check();
        \\  }
        \\}
        \\
        \\var minDepth = 4;
        \\var maxDepth = 14;
        \\var stretchDepth = maxDepth + 1;
        \\
        \\var start = clock();
        \\
        \\print "stretch tree of depth:";
        \\print stretchDepth;
        \\print "check:";
        \\print Tree(0, stretchDepth).check();
        \\
        \\var longLivedTree = Tree(0, maxDepth);
        \\
        \\// iterations = 2 ** maxDepth
        \\var iterations = 1;
        \\var d = 0;
        \\while (d < maxDepth) {
        \\  iterations = iterations * 2;
        \\  d = d + 1;
        \\}
        \\
        \\var depth = minDepth;
        \\while (depth < stretchDepth) {
        \\  var check = 0;
        \\  var i = 1;
        \\  while (i <= iterations) {
        \\    check = check + Tree(i, depth).check() + Tree(-i, depth).check();
        \\    i = i + 1;
        \\  }
        \\
        \\  print "num trees:";
        \\  print iterations * 2;
        \\  print "depth:";
        \\  print depth;
        \\  print "check:";
        \\  print check;
        \\
        \\  iterations = iterations / 4;
        \\  depth = depth + 2;
        \\}
        \\
        \\print "long lived tree of depth:";
        \\print maxDepth;
        \\print "check:";
        \\print longLivedTree.check();
        \\print "elapsed:";
        \\print clock() - start;
        \\
    ;

    const expected_tokens = [_]TokenType{
        .Class, .Identifier, .LeftBrace, // class Tree {
        .Identifier, .LeftParen, .Identifier, .Comma, .Identifier, .RightParen, .LeftBrace, // init(item, depth) {
        .This, .Dot, .Identifier, .Equal, .Identifier, .Semicolon, // this.item = item;
        .This, .Dot, .Identifier, .Equal, .Identifier, .Semicolon, // this.depth = depth;
        .If, .LeftParen, .Identifier, .Greater, .Number, .RightParen, .LeftBrace, // if (depth > 0) {
        .Var, .Identifier, .Equal, .Identifier, .Plus, .Identifier, .Semicolon, // var item2 = item + item;
        .Identifier, .Equal, .Identifier, .Minus, .Number, .Semicolon, // depth = depth - 1;
        .This, .Dot, .Identifier, .Equal, .Identifier, .LeftParen, .Identifier, .Minus, .Number, .Comma, .Identifier, .RightParen, .Semicolon, // this.left = Tree(item2 - 1, depth);
        .This, .Dot, .Identifier, .Equal, .Identifier, .LeftParen, .Identifier, .Comma, .Identifier, .RightParen, .Semicolon, // this.right = Tree(item2, depth);
        .RightBrace, .Else, .LeftBrace, // } else {
        .This, .Dot, .Identifier, .Equal, .Nil, .Semicolon, // this.left = nil;
        .This, .Dot, .Identifier, .Equal, .Nil, .Semicolon, // this.right = nil;
        .RightBrace, .RightBrace, // } }
        .Identifier, .LeftParen, .RightParen, .LeftBrace, // check() {
        .If, .LeftParen, .This, .Dot, .Identifier, .EqualEqual, .Nil, .RightParen, .LeftBrace, // if (this.left == nil) {
        .Return, .This, .Dot, .Identifier, .Semicolon, // return this.item;
        .RightBrace, // }
        .Return, .This, .Dot, .Identifier, .Plus, .This, .Dot, .Identifier, .Dot, .Identifier, .LeftParen, .RightParen, .Minus, .This, .Dot, .Identifier, .Dot, .Identifier, .LeftParen, .RightParen, .Semicolon, // return this.item + this.left.check() - this.right.check();
        .RightBrace, .RightBrace, // } }
        .Var, .Identifier, .Equal, .Number, .Semicolon, // var minDepth = 4;
        .Var, .Identifier, .Equal, .Number, .Semicolon, // var maxDepth = 14;
        .Var, .Identifier, .Equal, .Identifier, .Plus, .Number, .Semicolon, // var stretchDepth = maxDepth + 1;
        .Var, .Identifier, .Equal, .Identifier, .LeftParen, .RightParen, .Semicolon, // var start = clock();
        .Print, .String, .Semicolon, // print "stretch tree of depth:";
        .Print, .Identifier, .Semicolon, // print stretchDepth;
        .Print, .String, .Semicolon, // print "check:";
        .Print, .Identifier, .LeftParen, .Number, .Comma, .Identifier, .RightParen, .Dot, .Identifier, .LeftParen, .RightParen, .Semicolon, // print Tree(0, stretchDepth).check();
        .Var, .Identifier, .Equal, .Identifier, .LeftParen, .Number, .Comma, .Identifier, .RightParen, .Semicolon, // var longLivedTree = Tree(0, maxDepth);
        .Var, .Identifier, .Equal, .Number, .Semicolon, // var iterations = 1;
        .Var, .Identifier, .Equal, .Number, .Semicolon, // var d = 0;
        .While, .LeftParen, .Identifier, .Less, .Identifier, .RightParen, .LeftBrace, // while (d < maxDepth) {
        .Identifier, .Equal, .Identifier, .Star, .Number, .Semicolon, // iterations = iterations * 2;
        .Identifier, .Equal, .Identifier, .Plus, .Number, .Semicolon, // d = d + 1;
        .RightBrace, // }
        .Var, .Identifier, .Equal, .Identifier, .Semicolon, // var depth = minDepth;
        .While, .LeftParen, .Identifier, .Less, .Identifier, .RightParen, .LeftBrace, // while (depth < stretchDepth) {
        .Var, .Identifier, .Equal, .Number, .Semicolon, // var check = 0;
        .Var, .Identifier, .Equal, .Number, .Semicolon, // var i = 1;
        .While, .LeftParen, .Identifier, .LessEqual, .Identifier, .RightParen, .LeftBrace, // while (i <= iterations) {
        .Identifier, .Equal, .Identifier, .Plus, .Identifier, .LeftParen, .Identifier, .Comma, .Identifier, .RightParen, .Dot, .Identifier, .LeftParen, .RightParen, .Plus, .Identifier, .LeftParen, .Minus, .Identifier, .Comma, .Identifier, .RightParen, .Dot, .Identifier, .LeftParen, .RightParen, .Semicolon, // check = check + Tree(i, depth).check() + Tree(-i, depth).check();
        .Identifier, .Equal, .Identifier, .Plus, .Number, .Semicolon, // i = i + 1;
        .RightBrace, // }
        .Print, .String, .Semicolon, // print "num trees:";
        .Print, .Identifier, .Star, .Number, .Semicolon, // print iterations * 2;
        .Print, .String, .Semicolon, // print "depth:";
        .Print, .Identifier, .Semicolon, // print depth;
        .Print, .String, .Semicolon, // print "check:";
        .Print, .Identifier, .Semicolon, // print check;
        .Identifier, .Equal, .Identifier, .Slash, .Number, .Semicolon, // iterations = iterations / 4;
        .Identifier, .Equal, .Identifier, .Plus, .Number, .Semicolon, // depth = depth + 2;
        .RightBrace, // }
        .Print, .String, .Semicolon, // print "long lived tree of depth:";
        .Print, .Identifier, .Semicolon, // print maxDepth;
        .Print, .String, .Semicolon, // print "check:";
        .Print, .Identifier, .Dot, .Identifier, .LeftParen, .RightParen, .Semicolon, // print longLivedTree.check();
        .Print, .String, .Semicolon, // print "elapsed:";
        .Print, .Identifier, .LeftParen, .RightParen, .Minus, .Identifier, .Semicolon, // print clock() - start;
        .Eof, // EOF
    };

    var lexer = Lexer.init(code);

    // Scan all tokens and verify each one
    for (expected_tokens) |expected_type| {
        const token = try lexer.scanToken();
        try std.testing.expectEqual(expected_type, token.type);
    }
}
