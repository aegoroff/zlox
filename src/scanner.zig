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

pub const Token = struct {
    type: TokenType,
    start: usize,
    length: usize,
    line: usize,
};

source: []const u8,
start: usize,
current: usize,
line: usize,

pub fn init(source: []const u8) Lexer {
    return Lexer{
        .source = source,
        .start = 0,
        .current = 0,
        .line = 1,
    };
}

pub fn scanToken(self: *Lexer) LexerError!Token {
    self.skipWhitespace();
    self.start = self.current;
    if (self.isAtEnd()) {
        return self.makeToken(.Eof);
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
        'A'...'Z', 'a'...'z' => self.identifier(),
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
            std.log.err("invalid char is: 0x{X}", .{c});
            return LexerError.UnexpectedCharacter;
        },
    };
}

fn makeToken(self: *Lexer, tokenType: TokenType) Token {
    return Token{
        .start = self.start,
        .type = tokenType,
        .length = self.current - self.start,
        .line = self.line,
    };
}

fn isAtEnd(self: *Lexer) bool {
    return self.current == self.source.len or self.source[self.current] == '\x00';
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

fn checkKeyword(self: *Lexer, start: usize, length: usize, rest: []const u8, tokenType: TokenType) TokenType {
    const current_len = self.current - self.start;

    if (current_len == start + length) {
        const lexeme = self.source[self.start + start .. self.start + start + length];

        if (std.mem.eql(u8, lexeme, rest)) {
            return tokenType;
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
    self.current += 1;
    return true;
}

fn advance(self: *Lexer) u8 {
    self.current += 1;
    return self.source[self.current - 1];
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
            ' ', '\r', '\t' => _ = self.advance(),
            '\n' => {
                self.line += 1;
                _ = self.advance();
            },
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
    while (self.peek() != '"') {
        if (self.peek() == '\n') {
            self.line += 1;
        }
        _ = self.advance();
    }

    if (self.isAtEnd()) {
        return LexerError.UnterminatedString;
    }

    _ = self.advance();
    return self.makeToken(.String);
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
