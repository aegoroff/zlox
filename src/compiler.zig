pub const Compiler = @This();

const std = @import("std");
const scan = @import("scanner.zig");

allocator: std.mem.Allocator,
lexer: scan.Lexer,

pub fn init(gpa: std.mem.Allocator) Compiler {
    return Compiler{
        .allocator = gpa,
        .lexer = undefined,
    };
}

pub fn compile(self: *Compiler, source: []const u8) !void {
    self.lexer = scan.Lexer.init(source);
    var line: usize = 0;
    while (true) {
        const token = try self.lexer.scanToken();
        if (token.line != line) {
            std.debug.print("{d: >4} ", .{token.line});
            line = token.line;
        } else {
            std.debug.print("   | ", .{});
        }

        std.debug.print("{t: >2} '{s}'\n", .{ token.type, source[token.start .. token.start + token.length] });

        if (token.type == scan.TokenType.Eof) break;
    }
}
