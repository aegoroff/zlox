pub const Lexer = @This();

const std = @import("std");

pub const LexerError = error{
    UnexpectedCharacter,
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
    return self.source[self.current];
}

fn skipWhitespace(self: *Lexer) void {
    while (true) {
        const c = self.peek();
        switch (c) {
            ' ', '\r', '\t' => _ = self.advance(),
            '\n' => {
                self.line += 1;
                _ = self.advance();
            },
            else => return,
        }
    }
}
