const std = @import("std");
const vm = @import("vm.zig");
const err = @import("error.zig");

const TestHarness = struct {
    writer: std.Io.Writer.Allocating,
    machine: vm.VM,

    fn setup(self: *TestHarness) !void {
        self.writer = std.Io.Writer.Allocating.init(std.testing.allocator);
        errdefer self.writer.deinit();
        self.machine = try vm.init(std.testing.allocator, &self.writer.writer, std.testing.io);
    }

    fn deinit(self: *TestHarness) void {
        self.machine.deinit();
        self.writer.deinit();
    }

    fn interpret(self: *TestHarness, source: []const u8) !void {
        try self.machine.interpret(source, false);
    }

    fn expectOutput(self: *TestHarness, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, self.writer.written());
    }

    fn expectFrameCount(self: *TestHarness, expected: usize) !void {
        try std.testing.expectEqual(expected, self.machine.frame_count);
    }

    fn expectCompileError(self: *TestHarness, source: []const u8) !void {
        try std.testing.expectError(err.Error.CompileError, self.machine.interpret(source, false));
        try self.expectFrameCount(0);
    }

    fn expectRuntimeError(self: *TestHarness, source: []const u8) !void {
        try std.testing.expectError(err.Error.RuntimeError, self.machine.interpret(source, false));
    }
};

test "expr: add" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1 + 2;");

    // Assert
    try t.expectOutput("3\n");
}

test "expr: string concat" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"a\" + \"b\") + \"c\";");

    // Assert
    try t.expectOutput("abc\n");
}

test "expr: string == false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"a\" == \"b\");");

    // Assert
    try t.expectOutput("false\n");
}

test "expr: string !=" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"a\" != \"c\");");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: short string ==" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"ab\" == \"ab\");");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: long string ==" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"abcdefg\" == \"abcdefg\");");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: string > false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"aa\" > \"bb\");");

    // Assert
    try t.expectOutput("false\n");
}

test "expr: string > true" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"bb\" > \"aa\");");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: string >=" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"bba\" >= \"aaa\");");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: short string <= false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"bba\" <= \"aaa\");");

    // Assert
    try t.expectOutput("false\n");
}

test "expr: long string <= false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"bbaaaa\" <= \"aaaaaa\");");

    // Assert
    try t.expectOutput("false\n");
}

test "expr: number == false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1 == 2;");

    // Assert
    try t.expectOutput("false\n");
}

test "expr: number ==" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 2 == 2;");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: number >= equal" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 3 >= 3;");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: number >=" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 3 >= 2;");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: number <= false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 3 <= 1;");

    // Assert
    try t.expectOutput("false\n");
}

test "expr: nested <= false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (3 - 1) * 200 <= 1;");

    // Assert
    try t.expectOutput("false\n");
}

test "expr: > then ==" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 3 > 1 == true;");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: number <= equal" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 20 <= 20;");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: number <=" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 40 <= 50;");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: !nil" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print !nil;");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: !number" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print !1;");

    // Assert
    try t.expectOutput("false\n");
}

test "expr: !string" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print !\"s\";");

    // Assert
    try t.expectOutput("false\n");
}

test "expr: and or" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 40 <= 50 and 1 > 2 or 2 < 3;");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: and chain" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 40 <= 50 and 1 < 2 and 2 < 3;");

    // Assert
    try t.expectOutput("true\n");
}

test "expr: unary minus" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print --1;");

    // Assert
    try t.expectOutput("1\n");
}

test "expr: subtract zero" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1 - 1;");

    // Assert
    try t.expectOutput("0\n");
}

test "expr: subtract negative" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1 - 2;");

    // Assert
    try t.expectOutput("-1\n");
}

test "expr: subtract" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 2 - 1;");

    // Assert
    try t.expectOutput("1\n");
}

test "expr: add numbers" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 2 + 3;");

    // Assert
    try t.expectOutput("5\n");
}

test "expr: add subtract" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 2 + 3 - 1;");

    // Assert
    try t.expectOutput("4\n");
}

test "expr: add divide" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 3 + 3 / 3;");

    // Assert
    try t.expectOutput("4\n");
}

test "expr: parens precedence" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (3 + 3) / 3;");

    // Assert
    try t.expectOutput("2\n");
}

test "expr: divide" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 4 / 2;");

    // Assert
    try t.expectOutput("2\n");
}

test "expr: divide by one" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 4 / 1;");

    // Assert
    try t.expectOutput("4\n");
}

test "expr: divide by negative" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 5 / -1;");

    // Assert
    try t.expectOutput("-5\n");
}

test "expr: divide by zero" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 5 / 0;");

    // Assert
    try t.expectOutput("NaN\n");
}

test "expr: nested 1" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (5 - (3-1)) + -1;");

    // Assert
    try t.expectOutput("2\n");
}

test "expr: nested 2" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (5 - (3-1)) * -1;");

    // Assert
    try t.expectOutput("-3\n");
}

test "expr: nested 3" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print ((5 - (3-1)) * -2) / 4;");

    // Assert
    try t.expectOutput("-1.5\n");
}

test "expr: nested 4" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print ((5 - (3-1) + 3) * -2) / 4;");

    // Assert
    try t.expectOutput("-3\n");
}

test "var: assign and print" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = 1; var y = x + 1; print x; print y;");

    // Assert
    try t.expectOutput("1\n2\n");
}

test "var: multiple prints" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1; print 2;");

    // Assert
    try t.expectOutput("1\n2\n");
}

test "block: print" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1; { print 3; }");

    // Assert
    try t.expectOutput("1\n3\n");
}

test "block: scope" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var y = 1; { var x = 2; print x; } print y;");

    // Assert
    try t.expectOutput("2\n1\n");
}

test "block: shadow" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = 1; { var x = 2; print x; }");

    // Assert
    try t.expectOutput("2\n");
}

test "block: nested" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = 1; { var x = 2; print x; { var x = 3; print x; } } print x;");

    // Assert
    try t.expectOutput("2\n3\n1\n");
}

test "ctrl: if true" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = 1; if (x > 0) { print x; }");

    // Assert
    try t.expectOutput("1\n");
}

test "ctrl: if false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = -1; if (x > 0) { print x; } print 2;");

    // Assert
    try t.expectOutput("2\n");
}

test "ctrl: if-else true" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = 1; if (x > 0) { print x; } else { print 2; }");

    // Assert
    try t.expectOutput("1\n");
}

test "ctrl: if-else false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = -1; if (x > 0) { print x; } else { print 2; }");

    // Assert
    try t.expectOutput("2\n");
}

test "ctrl: while" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var i = 0; while (i < 10) i = i + 1; print i;");

    // Assert
    try t.expectOutput("10\n");
}

test "ctrl: for" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("for(var i = 0; i < 3; i = i + 1) print i;");

    // Assert
    try t.expectOutput("0\n1\n2\n");
}

test "ctrl: for without init" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var i = 0; for(; i < 3; i = i + 1) print i;");

    // Assert
    try t.expectOutput("0\n1\n2\n");
}

test "fun: call no args" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun sayHi() { print \"hi\"; } sayHi();");

    // Assert
    try t.expectOutput("hi\n");
}

test "fun: call with arg" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun add(a, b) { return a + b; } print add(3, 4);");

    // Assert
    try t.expectOutput("7\n");
}

test "fun: call multi args" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun sum(a, b, c) { return a + b + c; } print sum(1, 2, 3);");

    // Assert
    try t.expectOutput("6\n");
}

test "fun: return value" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun double(x) { return x * 2; } print double(5);");

    // Assert
    try t.expectOutput("10\n");
}

test "fun: nested calls" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun inner() { return 5; } fun outer() { return inner() * 2; } print outer();");

    // Assert
    try t.expectOutput("10\n");
}

test "fun: early return" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun check(x) { if (x > 0) return 1; return -1; } print check(5); print check(-5);");

    // Assert
    try t.expectOutput("1\n-1\n");
}

test "fun: implicit nil return" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun noReturn() { var x = 5; } print noReturn();");

    // Assert
    try t.expectOutput("nil\n");
}

test "fun: recurse factorial" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun fact(n) { if (n <= 1) return 1; return n * fact(n - 1); } print fact(5);");

    // Assert
    try t.expectOutput("120\n");
}

test "fun: recurse fibonacci" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun fib(n) { if (n <= 1) return n; return fib(n - 1) + fib(n - 2); } print fib(6);");

    // Assert
    try t.expectOutput("8\n");
}

test "native: clock" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print clock() > 0;");

    // Assert
    try t.expectOutput("true\n");
}

test "native: sqrt" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print sqrt(16);");

    // Assert
    try t.expectOutput("4\n");
}

test "native: sqrt of two" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print sqrt(2);");

    // Assert
    try t.expectOutput("1.4142135623730951\n");
}

test "native: min and max" {
    // Arrange
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "print min(5, 3);", .expected = "3\n" },
        .{ .source = "print min(3, 5);", .expected = "3\n" },
        .{ .source = "print min(4, 4);", .expected = "4\n" },
        .{ .source = "print max(5, 3);", .expected = "5\n" },
        .{ .source = "print max(3, 5);", .expected = "5\n" },
        .{ .source = "print max(4, 4);", .expected = "4\n" },
    };

    for (cases) |c| {
        var t: TestHarness = undefined;
        try t.setup();
        defer t.deinit();

        // Act
        try t.interpret(c.source);

        // Assert
        try t.expectOutput(c.expected);
    }
}

test "native: sqrt max composition" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print sqrt(max(9, 4));");

    // Assert
    try t.expectOutput("3\n");
}

test "native: nested min max" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print min(max(3, 5), 4);");

    // Assert
    try t.expectOutput("4\n");
}

test "fun: as argument" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun apply(f, x) { return f(x); } fun negate(x) { return -x; } print apply(negate, 42);");

    // Assert
    try t.expectOutput("-42\n");
}

test "closure: capture outer" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\var x = "global";
        \\fun outer() {
        \\  var x = "outer";
        \\  fun inner() {
        \\    print x;
        \\  }
        \\  inner();
        \\}
        \\outer();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("outer\n");
}

test "closure: multiple instances" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\fun makeClosure(value) {
        \\  fun closure() {
        \\    print value;
        \\  }
        \\  return closure;
        \\}
        \\
        \\var doughnut = makeClosure("doughnut");
        \\var bagel = makeClosure("bagel");
        \\doughnut();
        \\bagel();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("doughnut\nbagel\n");
}

test "closure: mutate capture" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\fun makeCounter() {
        \\  var count = 0;
        \\  fun increment() {
        \\    count = count + 1;
        \\    return count;
        \\  }
        \\  return increment;
        \\}
        \\
        \\var counter = makeCounter();
        \\print counter();
        \\print counter();
        \\print counter();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("1\n2\n3\n");
}

test "closure: survive enclosing return" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\fun makeAdder(n) {
        \\  fun adder(x) {
        \\    return x + n;
        \\  }
        \\  return adder;
        \\}
        \\
        \\var add5 = makeAdder(5);
        \\var add10 = makeAdder(10);
        \\print add5(3);
        \\print add10(3);
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("8\n13\n");
}

test "closure: nested share mutable" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\fun outer() {
        \\  var x = 1;
        \\  fun middle() {
        \\    fun inner() {
        \\      x = x + 1;
        \\      print x;
        \\    }
        \\    inner();
        \\    inner();
        \\  }
        \\  middle();
        \\}
        \\outer();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("2\n3\n");
}

test "class: declare and print" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {}
        \\print Foo;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("Foo\n");
}

test "class: declare and call" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {}
        \\print Foo();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("Foo instance\n");
}

test "class: block scope return" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\{
        \\  class Foo {
        \\    returnSelf() {
        \\      return Foo;
        \\    }
        \\  }
        \\  print Foo().returnSelf();
        \\}
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("Foo\n");
}

test "class: field set get" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {}
        \\var foo = Foo();
        \\foo.bar = "baz";
        \\print foo.bar;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("baz\n");
}

test "class: method no args" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  sayHi() {
        \\    print "hi";
        \\  }
        \\}
        \\var foo = Foo();
        \\foo.sayHi();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("hi\n");
}

test "class: method with args" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Calculator {
        \\  add(a, b) {
        \\    return a + b;
        \\  }
        \\}
        \\var calc = Calculator();
        \\print calc.add(3, 4);
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("7\n");
}

test "class: this field" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  setValue(v) {
        \\    this.value = v;
        \\  }
        \\  getValue() {
        \\    return this.value;
        \\  }
        \\}
        \\var foo = Foo();
        \\foo.setValue(42);
        \\print foo.getValue();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("42\n");
}

test "class: this receiver" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  greet() {
        \\    print this;
        \\  }
        \\}
        \\Foo().greet();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("Foo instance\n");
}

test "class: multiple methods" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Math {
        \\  double(x) {
        \\    return x * 2;
        \\  }
        \\  triple(x) {
        \\    return x * 3;
        \\  }
        \\}
        \\var math = Math();
        \\print math.double(5);
        \\print math.triple(5);
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("10\n15\n");
}

test "ctor: init sets fields" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  init(a, b) {
        \\    print "init";
        \\    this.a = a;
        \\    this.b = b;
        \\  }
        \\}
        \\var foo = Foo(1, 2);
        \\print foo.a;
        \\print foo.b;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("init\n1\n2\n");
}

test "ctor: default creates instance" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {}
        \\var foo = Foo();
        \\print foo;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("Foo instance\n");
}

test "ctor: early return instance" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  init() {
        \\    print "init";
        \\    return;
        \\    print "nope";
        \\  }
        \\}
        \\var foo = Foo();
        \\print foo;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("init\nFoo instance\n");
}

test "ctor: explicit init same instance" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  init(arg) {
        \\    print "Foo.init(" + arg + ")";
        \\    this.field = "init";
        \\  }
        \\}
        \\var foo = Foo("one");
        \\foo.field = "field";
        \\var foo2 = foo.init("two");
        \\print foo2;
        \\print foo.field;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("Foo.init(one)\nFoo.init(two)\nFoo instance\ninit\n");
}

test "ctor: nested init not initializer" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  init() {
        \\    fun init() {
        \\      return "bar";
        \\    }
        \\    print init();
        \\  }
        \\}
        \\print Foo();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("bar\nFoo instance\n");
}

test "fun: nested return clears frames" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret(
        \\fun a() { return 1; }
        \\fun b() { return a() + 1; }
        \\fun c() { return b() + 1; }
        \\print c();
    );

    // Assert
    try t.expectOutput("3\n");
    try t.expectFrameCount(0);
}

test "gc: instance field survives" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Box {}
        \\var box = Box();
        \\box.value = "survive";
        \\var i = 0;
        \\while (i < 5000) {
        \\  var s = "aaaa" + "bbbb";
        \\  i = i + 1;
        \\}
        \\print box.value;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("survive\n");
}

test "gc: method closure survives" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Greeter {
        \\  greet() {
        \\    return "hello";
        \\  }
        \\}
        \\var g = Greeter();
        \\var i = 0;
        \\while (i < 5000) {
        \\  var s = "aaaa" + "bbbb";
        \\  i = i + 1;
        \\}
        \\print g.greet();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("hello\n");
}

test "gc: global closure survives" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\fun make() {
        \\  fun inner() { return 42; }
        \\  return inner;
        \\}
        \\var f = make();
        \\var i = 0;
        \\while (i < 5000) {
        \\  var s = "aaaa" + "bbbb";
        \\  i = i + 1;
        \\}
        \\print f();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("42\n");
}

test "gc: global var survives" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\var survive = "ok";
        \\var i = 0;
        \\while (i < 5000) {
        \\  var s = "aaaa" + "bbbb";
        \\  i = i + 1;
        \\}
        \\print survive;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("ok\n");
}

test "gc: deep instance chain survives" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Node {}
        \\var head = Node();
        \\var cur = head;
        \\var depth = 0;
        \\while (depth < 50000) {
        \\  var next = Node();
        \\  cur.next = next;
        \\  cur = next;
        \\  depth = depth + 1;
        \\}
        \\var i = 0;
        \\while (i < 5000) {
        \\  var s = "aaaaaaa" + "bbbbbbb";
        \\  i = i + 1;
        \\}
        \\var node = head;
        \\var count = 0;
        \\while (count < depth) {
        \\  node = node.next;
        \\  count = count + 1;
        \\}
        \\print count;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("50000\n");
}

test "gc: bound methods collected" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  method() { return 1; }
        \\}
        \\var foo = Foo();
        \\var i = 0;
        \\while (i < 5000) {
        \\  foo.method();
        \\  i = i + 1;
        \\}
        \\print foo.method();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("1\n");
}

test "class: bound method identity" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  init() {}
        \\}
        \\class Bar {}
        \\var foo = Foo();
        \\var fooMethod = foo.init;
        \\print Foo == Foo;
        \\print Foo == Bar;
        \\print fooMethod == fooMethod;
        \\print foo.init == foo.init;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("true\nfalse\ntrue\nfalse\n");
}

test "inherit: methods" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  methodOnFoo() { print "foo"; }
        \\}
        \\class Bar < Foo {
        \\  methodOnBar() { print "bar"; }
        \\}
        \\var bar = Bar();
        \\bar.methodOnFoo();
        \\bar.methodOnBar();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("foo\nbar\n");
}

test "inherit: override" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  override() { print "foo"; }
        \\}
        \\class Bar < Foo {
        \\  override() { print "bar"; }
        \\}
        \\Bar().override();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("bar\n");
}

test "inherit: base init fields" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Foo {
        \\  setFields(a, b) {
        \\    this.field1 = a;
        \\    this.field2 = b;
        \\  }
        \\  printFields() {
        \\    print this.field1;
        \\    print this.field2;
        \\  }
        \\}
        \\class Bar < Foo {}
        \\var bar = Bar();
        \\bar.setFields("foo 1", "foo 2");
        \\bar.printFields();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("foo 1\nfoo 2\n");
}

test "super: call method" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Base {
        \\  foo() { print "Base.foo()"; }
        \\}
        \\class Derived < Base {
        \\  foo() {
        \\    print "Derived.foo()";
        \\    super.foo();
        \\  }
        \\}
        \\Derived().foo();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("Derived.foo()\nBase.foo()\n");
}

test "super: init constructor" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Base {
        \\  init(a, b) {
        \\    print "Base.init(" + a + ", " + b + ")";
        \\  }
        \\}
        \\class Derived < Base {
        \\  init() {
        \\    print "Derived.init()";
        \\    super.init("a", "b");
        \\  }
        \\}
        \\Derived();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("Derived.init()\nBase.init(a, b)\n");
}

test "super: init fields on subclass" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Base {
        \\  init(a) {
        \\    this.a = a;
        \\  }
        \\}
        \\class Derived < Base {
        \\  init(a, b) {
        \\    super.init(a);
        \\    this.b = b;
        \\  }
        \\}
        \\var derived = Derived("a", "b");
        \\print derived.a;
        \\print derived.b;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("a\nb\n");
}

test "super: multi level" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class A {
        \\  foo() { print "A.foo()"; }
        \\}
        \\class B < A {}
        \\class C < B {
        \\  foo() {
        \\    print "C.foo()";
        \\    super.foo();
        \\  }
        \\}
        \\C().foo();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("C.foo()\nA.foo()\n");
}

test "super: bind superclass method" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class A {
        \\  method(arg) {
        \\    print "A.method(" + arg + ")";
        \\  }
        \\}
        \\class B < A {
        \\  getClosure() {
        \\    return super.method;
        \\  }
        \\  method(arg) {
        \\    print "B.method(" + arg + ")";
        \\  }
        \\}
        \\var closure = B().getClosure();
        \\closure("arg");
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("A.method(arg)\n");
}

test "error: stack overflow" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\fun foo() {
        \\  foo();
        \\}
        \\foo();
        \\
    ;

    // Act + Assert
    try t.expectRuntimeError(code);
    try t.expectFrameCount(t.machine.frames.len);
}

test "error: native sqrt arity" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectRuntimeError("sqrt();");
    try t.expectFrameCount(1);
}

test "error: native min arity" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectRuntimeError("min(1);");
    try t.expectFrameCount(1);
}

test "opcode: long closure" {
    // Arrange
    var code = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer code.deinit();
    var i: usize = 0;
    while (i < 257) : (i += 1) {
        try code.writer.print("fun f{d}() {{ print {d}; }}\n", .{ i, i });
    }
    try code.writer.writeAll("f256();\n");

    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret(code.written());

    // Assert
    try t.expectOutput("256\n");
}

test "opcode: long invoke" {
    // Arrange
    var code = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer code.deinit();
    try code.writer.writeAll("class C {\n");
    var i: usize = 0;
    while (i < 257) : (i += 1) {
        try code.writer.print("  m{d}() {{ return {d}; }}\n", .{ i, i });
    }
    try code.writer.writeAll("}\nprint C().m256();\n");

    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret(code.written());

    // Assert
    try t.expectOutput("256\n");
}

test "error: duplicate local" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError(
        \\{
        \\  var x = 1;
        \\  var x = 2;
        \\}
    );
}

test "error: invalid assignment" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError("1 = 2;");
}

test "error: top-level return" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError("return;");
}

test "error: init return value" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError(
        \\class C {
        \\  init() {
        \\    return 1;
        \\  }
        \\}
    );
}

test "error: too many params" {
    // Arrange
    var code = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer code.deinit();
    try code.writer.writeAll("fun f(");
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        if (i > 0) try code.writer.writeAll(", ");
        try code.writer.print("a{d}", .{i});
    }
    try code.writer.writeAll(") {}\n");

    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError(code.written());
}

test "error: undefined variable" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectRuntimeError("print not_defined;");
    try t.expectFrameCount(1);
}

test "error: this outside class" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError("print this;");
}

test "error: inherit self" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError("class A < A {};");
}

test "gc: temporary bound method" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class A {
        \\  init() { this.x = 1; }
        \\  m() { return this.x; }
        \\}
        \\for (var i = 0; i < 50; i = i + 1) {
        \\  A().m;
        \\  print A().m();
        \\}
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer expected.deinit();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try expected.writer.writeAll("1\n");
    }
    try t.expectOutput(expected.written());
}

test "gc: field keeps nested instance" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Box { init(n) { this.n = n; } }
        \\class Holder {}
        \\var h = Holder();
        \\{
        \\  var b = Box(7);
        \\  h.f = b;
        \\}
        \\print h.f.n;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("7\n");
}

test "gc: stored bound method receiver" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class A {
        \\  init(n) { this.n = n; }
        \\  m() { print this.n; }
        \\}
        \\var method;
        \\{
        \\  var a = A(99);
        \\  method = a.m;
        \\}
        \\method();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("99\n");
}

test "class: field bound method call" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class A {
        \\  init(n) { this.n = n; }
        \\  m() { print this.n; }
        \\}
        \\var a = A(42);
        \\a.f = a.m;
        \\a.f();
        \\var b = a.f;
        \\b();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("42\n42\n");
}

test "gc: free list reuse" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class Box { init(n) { this.n = n; } }
        \\class Holder {}
        \\var h = Holder();
        \\for (var i = 0; i < 100; i = i + 1) {
        \\  {
        \\    var b = Box(i);
        \\    h.f = b;
        \\  }
        \\}
        \\print h.f.n;
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("99\n");
}

test "super: get bound method then call" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    const code =
        \\class A {
        \\  method() { print this.value; }
        \\}
        \\class B < A {
        \\  method() {
        \\    var m = super.method;
        \\    m();
        \\  }
        \\}
        \\var b = B();
        \\b.value = 3;
        \\b.method();
        \\
    ;

    // Act
    try t.interpret(code);

    // Assert
    try t.expectOutput("3\n");
}
