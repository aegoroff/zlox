//! Fuzz the compiler + VM pipeline via `VM.interpret`.
//!
//! Each iteration feeds mutated bytes to the scanner/compiler/VM exactly as
//! `main.run` would a script file, then discards the result. `zig build test`
//! (and `just test`) replay only the corpus below - deterministic, fast, no
//! `--fuzz` flag needed. `zig build fuzzing` (or `zig build fuzzing --fuzz`)
//! runs the coverage-guided mutation engine.
//!
//! Input is a Smith slice (u32 little-endian length + bytes); corpus entries
//! below are raw Lox source wrapped with that length prefix.
//!
//! Invariants:
//!   - panic / abort are not allowed
//!   - memory leak is not allowed (`std.testing.allocator`)
//!   - compile errors and runtime errors are expected, not a bug
//!
//! Diagnostics go quiet in a `--fuzz` build: `Compiler.reportErrorAt` and
//! `VM.printCallStack` return early on `builtin.fuzz`, because the runner keeps
//! every byte this binary writes to stderr for the whole session and almost
//! every input produces a diagnostic. Without that the `build` process grew by
//! tens of megabytes a second until the kernel killed it.
//!
//! Known limitation: Lox has no `break`/`continue`, so a genuine infinite
//! loop (`while (true) {}` with no side effect that fails the writer) is a
//! real, if unlikely, mutation - the fixed output buffer below turns any
//! print-heavy loop into a quick `error.WriteFailed`, but a silent spin has
//! nothing to bound it. Run unattended `--fuzz` sessions under an external
//! `timeout` for that reason; a hang there is the language's own halting
//! problem, not a VM bug.

const std = @import("std");
const vm = @import("vm.zig");

const MAX_SOURCE_LEN: u32 = 4 * 1024;

fn sliceCorpus(comptime source: []const u8) *const [4 + source.len]u8 {
    const Storage = struct {
        const bytes: [4 + source.len]u8 = blk: {
            var buf: [4 + source.len]u8 = undefined;
            std.mem.writeInt(u32, buf[0..4], @intCast(source.len), .little);
            @memcpy(buf[4..], source);
            break :blk buf;
        };
    };
    return &Storage.bytes;
}

fn nestedParens(comptime depth: usize) []const u8 {
    return "print " ++ "(" ** depth ++ "1" ++ ")" ** depth ++ ";";
}

/// Coverage-guided mutation needs a seed that already reaches each grammar
/// production. Byte flips almost never invent keywords (`class`, `super`,
/// `fun`, …), so unique-run growth stalls on a tiny, similar corpus.
const CORPUS = [_][]const u8{
    // empty / trivia
    sliceCorpus(""),
    sliceCorpus("// comment only"),
    sliceCorpus("\n\n\n"),
    sliceCorpus("// lead\nprint 1;"),

    // literals / expressions
    sliceCorpus("print nil;"),
    sliceCorpus("print true; print false;"),
    sliceCorpus("print 1;"),
    sliceCorpus("print 1.5;"),
    sliceCorpus("print -0;"),
    sliceCorpus("print \"abc\";"),
    sliceCorpus("print \"\";"),
    sliceCorpus("print \"a\" + \"b\";"),
    sliceCorpus("print 1 + 2 * 3 - 4 / 2;"),
    sliceCorpus("print (1 + 2) == 3;"),
    sliceCorpus("print !true;"),
    sliceCorpus("print -5;"),
    sliceCorpus("print 1 < 2 and 2 < 3;"),
    sliceCorpus("print true or false;"),
    sliceCorpus("print 1 / 0;"),
    sliceCorpus("print 0 / 0;"),
    sliceCorpus("print -1 / 0;"),

    // var / assignment / scope
    sliceCorpus("var a = 1; print a;"),
    sliceCorpus("var a; print a;"),
    sliceCorpus("var _leading = 1; print _leading;"),
    sliceCorpus("{ var a = 1; { var a = 2; print a; } print a; }"),
    sliceCorpus("var a = 1; { a = 2; } print a;"),

    // control flow (bounded loops only - see the module doc comment)
    sliceCorpus("if (true) print 1; else print 2;"),
    sliceCorpus("if (1 < 2) print 1;"),
    sliceCorpus("var i = 0; while (i < 3) { print i; i = i + 1; }"),
    sliceCorpus("for (var i = 0; i < 3; i = i + 1) print i;"),
    sliceCorpus("for (var i = 0; i < 3; i = i + 1) { if (i == 1) print i; }"),

    // functions
    sliceCorpus("fun f() {} print f();"),
    sliceCorpus("fun f(a, b) { return a + b; } print f(1, 2);"),
    sliceCorpus("fun fact(n) { if (n <= 1) return 1; return n * fact(n - 1); } print fact(5);"),
    sliceCorpus("fun foo() { foo(); } foo();"),

    // closures
    sliceCorpus(
        \\fun make() {
        \\  var x = 0;
        \\  fun inc() { x = x + 1; return x; }
        \\  return inc;
        \\}
        \\var c = make();
        \\print c();
        \\print c();
    ),

    // classes / constructors / inheritance / super
    sliceCorpus("class A {} print A;"),
    sliceCorpus("class A {} print A();"),
    sliceCorpus("class A { m() { return 1; } } print A().m();"),
    sliceCorpus("class A { init(x) { this.x = x; } } print A(3).x;"),
    sliceCorpus(
        \\class A { m() { return 1; } }
        \\class B < A { m() { return super.m() + 1; } }
        \\print B().m();
    ),
    sliceCorpus("class A {} var a = A(); a.f = 1; print a.f;"),

    // natives
    sliceCorpus("print clock() >= 0;"),
    sliceCorpus("print sqrt(4);"),
    sliceCorpus("print min(1, 2); print max(1, 2);"),
    sliceCorpus("sqrt(1, 2);"),
    sliceCorpus("sqrt(\"x\");"),

    // syntax / semantic errors (distinct scanner and parser recoveries)
    sliceCorpus("print 1 +;"),
    sliceCorpus("print (1;"),
    sliceCorpus("var 1a = 2;"),
    sliceCorpus("1 + \"a\";"),
    sliceCorpus("a.b;"),
    sliceCorpus("this;"),
    sliceCorpus("super.m();"),
    sliceCorpus("return 1;"),
    sliceCorpus("print \"unterminated;"),
    sliceCorpus("print;"),
    sliceCorpus("class A < A {}"),
    sliceCorpus("class A < 1 {}"),
    sliceCorpus("fun f(a, a) {}"),
    sliceCorpus("var a = 1; var a = 2;"),
    sliceCorpus(nestedParens(100)),
    sliceCorpus(nestedParens(300)),

    // raw / high-byte input (lexer 8-bit paths)
    sliceCorpus(&.{0x00}),
    sliceCorpus(&.{0x81}),
    sliceCorpus(&.{0xff}),
    sliceCorpus(&.{ 0x9f, 0x03, '#', ' ', 'c' }),
};

const SOURCE_LEN_WEIGHTS = [_]std.testing.Smith.Weight{
    .rangeAtMost(u32, 0, 64, 8),
    .rangeAtMost(u32, 0, 256, 4),
    .rangeAtMost(u32, 0, MAX_SOURCE_LEN, 1),
};

const SOURCE_BYTE_WEIGHTS = [_]std.testing.Smith.Weight{
    .rangeAtMost(u8, 1, 255, 1),
    .rangeAtMost(u8, ' ', '~', 16),
    .value(u8, '\n', 8),
    .value(u8, '\t', 4),
};

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var source_buf: [MAX_SOURCE_LEN]u8 = undefined;
    const source_len = smith.sliceWeighted(&source_buf, &SOURCE_LEN_WEIGHTS, &SOURCE_BYTE_WEIGHTS);
    const source = source_buf[0..source_len];

    // Fixed, small: caps a print-heavy mutant's output instead of growing
    // without bound. `VM.run` propagates the resulting `error.WriteFailed`
    // like any other runtime error.
    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);

    var machine = try vm.init(std.testing.allocator, &out, std.testing.io);
    defer machine.deinit();

    machine.interpret(source, false) catch {};
}

test "fuzz interpret" {
    try std.testing.fuzz({}, fuzzOne, .{
        .corpus = &CORPUS,
    });
}
