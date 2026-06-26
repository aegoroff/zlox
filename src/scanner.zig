pub const Lexer = @This();

const std = @import("std");

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

allocator: std.mem.Allocator,
source: []const u8,

pub fn init(gpa: std.mem.Allocator, source: []const u8) Lexer {
    return Lexer{
        .allocator = gpa,
        .source = source,
    };
}
