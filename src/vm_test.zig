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

    fn expectCompileError(self: *TestHarness, source: []const u8) !void {
        try std.testing.expectError(err.Error.CompileError, self.machine.interpret(source, false));
    }

    fn expectRuntimeError(self: *TestHarness, source: []const u8) !void {
        try std.testing.expectError(err.Error.RuntimeError, self.machine.interpret(source, false));
    }
};

test "Simple add expression" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1 + 2;");

    // Assert
    try t.expectOutput("3\n");
}

test "String concatentation" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"a\" + \"b\") + \"c\";");

    // Assert
    try t.expectOutput("abc\n");
}

test "string equal false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"a\" == \"b\");");

    // Assert
    try t.expectOutput("false\n");
}

test "string not equal" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"a\" != \"c\");");

    // Assert
    try t.expectOutput("true\n");
}

test "short string equal true" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"ab\" == \"ab\");");

    // Assert
    try t.expectOutput("true\n");
}

test "big string equal true" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"abcdefg\" == \"abcdefg\");");

    // Assert
    try t.expectOutput("true\n");
}

test "string greater false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"aa\" > \"bb\");");

    // Assert
    try t.expectOutput("false\n");
}

test "string greater true" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"bb\" > \"aa\");");

    // Assert
    try t.expectOutput("true\n");
}

test "string greater or equal true" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"bba\" >= \"aaa\");");

    // Assert
    try t.expectOutput("true\n");
}

test "short string less or equal false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"bba\" <= \"aaa\");");

    // Assert
    try t.expectOutput("false\n");
}

test "big string less or equal false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (\"bbaaaa\" <= \"aaaaaa\");");

    // Assert
    try t.expectOutput("false\n");
}

test "number equal false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1 == 2;");

    // Assert
    try t.expectOutput("false\n");
}

test "number equal true" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 2 == 2;");

    // Assert
    try t.expectOutput("true\n");
}

test "number greater or equal" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 3 >= 3;");

    // Assert
    try t.expectOutput("true\n");
}

test "number greater or equal two" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 3 >= 2;");

    // Assert
    try t.expectOutput("true\n");
}

test "number less or equal false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 3 <= 1;");

    // Assert
    try t.expectOutput("false\n");
}

test "expression less or equal false" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (3 - 1) * 200 <= 1;");

    // Assert
    try t.expectOutput("false\n");
}

test "comparison with equal" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 3 > 1 == true;");

    // Assert
    try t.expectOutput("true\n");
}

test "number less or equal equal" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 20 <= 20;");

    // Assert
    try t.expectOutput("true\n");
}

test "number less or equal" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 40 <= 50;");

    // Assert
    try t.expectOutput("true\n");
}

test "not nil" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print !nil;");

    // Assert
    try t.expectOutput("true\n");
}

test "not number" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print !1;");

    // Assert
    try t.expectOutput("false\n");
}

test "not string" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print !\"s\";");

    // Assert
    try t.expectOutput("false\n");
}

test "two ands + or" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 40 <= 50 and 1 > 2 or 2 < 3;");

    // Assert
    try t.expectOutput("true\n");
}

test "three ands" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 40 <= 50 and 1 < 2 and 2 < 3;");

    // Assert
    try t.expectOutput("true\n");
}

test "decrement prefix" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print --1;");

    // Assert
    try t.expectOutput("1\n");
}

test "subtract same numbers" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1 - 1;");

    // Assert
    try t.expectOutput("0\n");
}

test "subtract negative result" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1 - 2;");

    // Assert
    try t.expectOutput("-1\n");
}

test "subtract positive result" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 2 - 1;");

    // Assert
    try t.expectOutput("1\n");
}

test "add numbers" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 2 + 3;");

    // Assert
    try t.expectOutput("5\n");
}

test "add and subtract" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 2 + 3 - 1;");

    // Assert
    try t.expectOutput("4\n");
}

test "add and divide" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 3 + 3 / 3;");

    // Assert
    try t.expectOutput("4\n");
}

test "parentheses add and divide" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (3 + 3) / 3;");

    // Assert
    try t.expectOutput("2\n");
}

test "divide numbers" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 4 / 2;");

    // Assert
    try t.expectOutput("2\n");
}

test "divide by one" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 4 / 1;");

    // Assert
    try t.expectOutput("4\n");
}

test "divide by negative" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 5 / -1;");

    // Assert
    try t.expectOutput("-5\n");
}

test "divide by zero" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 5 / 0;");

    // Assert
    try t.expectOutput("NaN\n");
}

test "nested expression one" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (5 - (3-1)) + -1;");

    // Assert
    try t.expectOutput("2\n");
}

test "nested expression two" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print (5 - (3-1)) * -1;");

    // Assert
    try t.expectOutput("-3\n");
}

test "nested expression three" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print ((5 - (3-1)) * -2) / 4;");

    // Assert
    try t.expectOutput("-1.5\n");
}

test "nested expression four" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print ((5 - (3-1) + 3) * -2) / 4;");

    // Assert
    try t.expectOutput("-3\n");
}

test "variables assignment and print" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = 1; var y = x + 1; print x; print y;");

    // Assert
    try t.expectOutput("1\n2\n");
}

test "multiple prints" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1; print 2;");

    // Assert
    try t.expectOutput("1\n2\n");
}

test "print with block" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print 1; { print 3; }");

    // Assert
    try t.expectOutput("1\n3\n");
}

test "block scope variable" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var y = 1; { var x = 2; print x; } print y;");

    // Assert
    try t.expectOutput("2\n1\n");
}

test "block scope shadow" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = 1; { var x = 2; print x; }");

    // Assert
    try t.expectOutput("2\n");
}

test "nested blocks" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = 1; { var x = 2; print x; { var x = 3; print x; } } print x;");

    // Assert
    try t.expectOutput("2\n3\n1\n");
}

test "if positive" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = 1; if (x > 0) { print x; }");

    // Assert
    try t.expectOutput("1\n");
}

test "if negative" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = -1; if (x > 0) { print x; } print 2;");

    // Assert
    try t.expectOutput("2\n");
}

test "if else positive" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = 1; if (x > 0) { print x; } else { print 2; }");

    // Assert
    try t.expectOutput("1\n");
}

test "if else negative" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var x = -1; if (x > 0) { print x; } else { print 2; }");

    // Assert
    try t.expectOutput("2\n");
}

test "while test" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var i = 0; while (i < 10) i = i + 1; print i;");

    // Assert
    try t.expectOutput("10\n");
}

test "for test" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("for(var i = 0; i < 3; i = i + 1) print i;");

    // Assert
    try t.expectOutput("0\n1\n2\n");
}

test "for test without initializer" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("var i = 0; for(; i < 3; i = i + 1) print i;");

    // Assert
    try t.expectOutput("0\n1\n2\n");
}

test "function call no arguments" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun sayHi() { print \"hi\"; } sayHi();");

    // Assert
    try t.expectOutput("hi\n");
}

test "function call with arguments" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun add(a, b) { return a + b; } print add(3, 4);");

    // Assert
    try t.expectOutput("7\n");
}

test "function call with multiple arguments" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun sum(a, b, c) { return a + b + c; } print sum(1, 2, 3);");

    // Assert
    try t.expectOutput("6\n");
}

test "function return value" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun double(x) { return x * 2; } print double(5);");

    // Assert
    try t.expectOutput("10\n");
}

test "function nested calls" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun inner() { return 5; } fun outer() { return inner() * 2; } print outer();");

    // Assert
    try t.expectOutput("10\n");
}

test "function with early return" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun check(x) { if (x > 0) return 1; return -1; } print check(5); print check(-5);");

    // Assert
    try t.expectOutput("1\n-1\n");
}

test "function without return statement" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun noReturn() { var x = 5; } print noReturn();");

    // Assert
    try t.expectOutput("nil\n");
}

test "function recursion factorial" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun fact(n) { if (n <= 1) return 1; return n * fact(n - 1); } print fact(5);");

    // Assert
    try t.expectOutput("120\n");
}

test "function recursion fibonacci" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun fib(n) { if (n <= 1) return n; return fib(n - 1) + fib(n - 2); } print fib(6);");

    // Assert
    try t.expectOutput("8\n");
}

test "native function clock" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print clock() > 0;");

    // Assert
    try t.expectOutput("true\n");
}

test "native function sqrt" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print sqrt(16);");

    // Assert
    try t.expectOutput("4\n");
}

test "native function sqrt of two" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print sqrt(2);");

    // Assert
    try t.expectOutput("1.4142135623730951\n");
}

test "native function min" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print min(5, 3);");

    // Assert
    try t.expectOutput("3\n");
}

test "native function min reversed" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print min(3, 5);");

    // Assert
    try t.expectOutput("3\n");
}

test "native function min equal" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print min(4, 4);");

    // Assert
    try t.expectOutput("4\n");
}

test "native function max" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print max(5, 3);");

    // Assert
    try t.expectOutput("5\n");
}

test "native function max reversed" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print max(3, 5);");

    // Assert
    try t.expectOutput("5\n");
}

test "native function max equal" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print max(4, 4);");

    // Assert
    try t.expectOutput("4\n");
}

test "native functions composition" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print sqrt(max(9, 4));");

    // Assert
    try t.expectOutput("3\n");
}

test "native functions nested min max" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("print min(max(3, 5), 4);");

    // Assert
    try t.expectOutput("4\n");
}

test "function as argument" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act
    try t.interpret("fun apply(f, x) { return f(x); } fun negate(x) { return -x; } print apply(negate, 42);");

    // Assert
    try t.expectOutput("-42\n");
}

test "closures capture outer variable" {
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

test "closures multiple instances with different captured values" {
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

test "closures mutate captured variable" {
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

test "closures survive after enclosing function returns" {
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

test "nested closures share mutable outer variable" {
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

test "class declaration and print" {
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

test "class declaration and call" {
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

test "class in block scope returns class from method" {
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

test "class instance property set and get" {
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

test "class method call no arguments" {
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

test "class method call with arguments" {
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

test "class method uses this to access instance field" {
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

test "class method uses this as receiver" {
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

test "class method call multiple methods" {
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

test "constructor with arguments sets instance fields" {
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

test "constructor without init creates instance" {
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

test "constructor early return still returns instance" {
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

test "constructor explicit init call does not create new instance" {
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

test "constructor nested function named init is not initializer" {
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

test "nested return preserves frame count" {
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
}

test "gc instance field survives collection" {
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

test "gc class method closure survives collection" {
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

test "gc closure in global survives collection" {
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

test "gc global variable survives collection" {
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

test "gc deep linked instance chain survives collection" {
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

test "gc bound methods are collected during method calls" {
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

test "class and bound method identity equality" {
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

test "inheritance inherits methods from superclass" {
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

test "inheritance subclass method overrides superclass" {
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

test "inheritance base initializer sets fields on subclass instance" {
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

test "super calls superclass method" {
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

test "super init calls superclass constructor" {
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

test "super init sets superclass fields accessed on subclass instance" {
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

test "super resolves through multiple inheritance levels" {
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

test "super method binds to superclass implementation" {
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

test "recursive calls report stack overflow" {
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
}

test "native sqrt wrong arity reports runtime error" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectRuntimeError("sqrt();");
}

test "native min wrong arity reports runtime error" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectRuntimeError("min(1);");
}

test "long closure opcode with large constant pool" {
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

test "long invoke opcode with large constant pool" {
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

test "compile error on duplicate local variable" {
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

test "compile error on invalid assignment target" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError("1 = 2;");
}

test "compile error on top-level return" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError("return;");
}

test "compile error on initializer return value" {
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

test "compile error on too many function parameters" {
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

test "runtime error on undefined variable" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectRuntimeError("print not_defined;");
}

test "compile error on this outside class" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError("print this;");
}

test "compile error on class inheriting from itself" {
    // Arrange
    var t: TestHarness = undefined;
    try t.setup();
    defer t.deinit();

    // Act + Assert
    try t.expectCompileError("class A < A {};");
}

test "temporary bound method is collected" {
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

test "instance field keeps nested instance alive" {
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

test "stored bound method keeps receiver alive" {
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

test "field bound method call uses receiver" {
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

test "free list reuse after temporary instances" {
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

test "get super bound method then call" {
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
