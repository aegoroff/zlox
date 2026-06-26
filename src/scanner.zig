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

allocator: std.mem.Allocator,
source: []const u8,
start: usize,
current: usize,
line: usize,

pub fn init(gpa: std.mem.Allocator, source: []const u8) Lexer {
    return Lexer{
        .allocator = gpa,
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
        return self.makeToken(TokenType.Eof);
    }
    const c = self.advance();
    if (isDigit(c)) {
        return self.number();
    }
    return switch (c) {
        '(' => self.makeToken(TokenType.LeftParen),
        ')' => self.makeToken(TokenType.RightParen),
        '{' => self.makeToken(TokenType.LeftBrace),
        '}' => self.makeToken(TokenType.RightBrace),
        ',' => self.makeToken(TokenType.Comma),
        '.' => self.makeToken(TokenType.Dot),
        '-' => self.makeToken(TokenType.Minus),
        '+' => self.makeToken(TokenType.Plus),
        ';' => self.makeToken(TokenType.Semicolon),
        '*' => self.makeToken(TokenType.Star),
        '/' => self.makeToken(TokenType.Slash),
        '!' => {
            if (self.match('=')) {
                return self.makeToken(TokenType.BangEqual);
            } else {
                return self.makeToken(TokenType.Bang);
            }
        },
        '=' => {
            if (self.match('=')) {
                return self.makeToken(TokenType.EqualEqual);
            } else {
                return self.makeToken(TokenType.Equal);
            }
        },
        '<' => {
            if (self.match('=')) {
                return self.makeToken(TokenType.LessEqual);
            } else {
                return self.makeToken(TokenType.Less);
            }
        },
        '>' => {
            if (self.match('=')) {
                return self.makeToken(TokenType.GreaterEqual);
            } else {
                return self.makeToken(TokenType.Greater);
            }
        },
        '"' => self.string(),
        else => return LexerError.UnexpectedCharacter,
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

    return self.makeToken(TokenType.Number);
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
    if (self.isAtEnd()) {
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
    return self.makeToken(TokenType.String);
}

test "Left paren" {
    // Arrange
    var lexer = Lexer.init(std.testing.allocator, "(");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(TokenType.LeftParen, token.type);
}

test "Bang tests" {
    // Arrange
    var lexer = Lexer.init(std.testing.allocator, "!!=");

    // Act
    const token1 = try lexer.scanToken();
    const token2 = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(TokenType.Bang, token1.type);
    try std.testing.expectEqual(TokenType.BangEqual, token2.type);
}

test "Only comment test" {
    // Arrange
    var lexer = Lexer.init(std.testing.allocator, "// Comment");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(TokenType.Eof, token.type);
}

test "Not comment and comment test" {
    // Arrange
    var lexer = Lexer.init(std.testing.allocator, "! // Comment");

    // Act
    const token1 = try lexer.scanToken();
    const token2 = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(TokenType.Bang, token1.type);
    try std.testing.expectEqual(TokenType.Eof, token2.type);
}

test "String test" {
    // Arrange
    var lexer = Lexer.init(std.testing.allocator, "\"test\"");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(TokenType.String, token.type);
}

test "Number test" {
    // Arrange
    var lexer = Lexer.init(std.testing.allocator, "123.0");

    // Act
    const token = try lexer.scanToken();

    // Assert
    try std.testing.expectEqual(TokenType.Number, token.type);
}
