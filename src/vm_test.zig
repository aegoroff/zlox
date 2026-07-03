const std = @import("std");
const vm = @import("vm.zig");
const init = vm.init;

test "Simple add expression" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1 + 2;", false);

    // Assert
    try std.testing.expectEqualStrings("3\n", writer.written());
}

test "String concatentation" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"a\" + \"b\") + \"c\";", false);

    // Assert
    try std.testing.expectEqualStrings("abc\n", writer.written());
}

test "string equal false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"a\" == \"b\");", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "string not equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"a\" != \"c\");", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "string equal true" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"ab\" == \"ab\");", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "string greater false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"aa\" > \"bb\");", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "string greater true" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"bb\" > \"aa\");", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "string greater or equal true" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"bba\" >= \"aaa\");", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "string less or equal false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (\"bba\" <= \"aaa\");", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "number equal false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1 == 2;", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "number equal true" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 2 == 2;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "number greater or equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 3 >= 3;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "number greater or equal two" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 3 >= 2;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "number less or equal false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 3 <= 1;", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "expression less or equal false" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (3 - 1) * 200 <= 1;", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "comparison with equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 3 > 1 == true;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "number less or equal equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 20 <= 20;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "number less or equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 40 <= 50;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "not nil" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print !nil;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "not number" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print !1;", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "not string" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print !\"s\";", false);

    // Assert
    try std.testing.expectEqualStrings("false\n", writer.written());
}

test "two ands + or" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 40 <= 50 and 1 > 2 or 2 < 3;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "three ands" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 40 <= 50 and 1 < 2 and 2 < 3;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "decrement prefix" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print --1;", false);

    // Assert
    try std.testing.expectEqualStrings("1\n", writer.written());
}

test "subtract same numbers" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1 - 1;", false);

    // Assert
    try std.testing.expectEqualStrings("0\n", writer.written());
}

test "subtract negative result" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1 - 2;", false);

    // Assert
    try std.testing.expectEqualStrings("-1\n", writer.written());
}

test "subtract positive result" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 2 - 1;", false);

    // Assert
    try std.testing.expectEqualStrings("1\n", writer.written());
}

test "add numbers" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 2 + 3;", false);

    // Assert
    try std.testing.expectEqualStrings("5\n", writer.written());
}

test "add and subtract" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 2 + 3 - 1;", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "add and divide" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 3 + 3 / 3;", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "parentheses add and divide" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (3 + 3) / 3;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "divide numbers" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 4 / 2;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "divide by one" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 4 / 1;", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "divide by negative" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 5 / -1;", false);

    // Assert
    try std.testing.expectEqualStrings("-5\n", writer.written());
}

test "divide by zero" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 5 / 0;", false);

    // Assert
    try std.testing.expectEqualStrings("NaN\n", writer.written());
}

test "nested expression one" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (5 - (3-1)) + -1;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "nested expression two" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print (5 - (3-1)) * -1;", false);

    // Assert
    try std.testing.expectEqualStrings("-3\n", writer.written());
}

test "nested expression three" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print ((5 - (3-1)) * -2) / 4;", false);

    // Assert
    try std.testing.expectEqualStrings("-1.5\n", writer.written());
}

test "nested expression four" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print ((5 - (3-1) + 3) * -2) / 4;", false);

    // Assert
    try std.testing.expectEqualStrings("-3\n", writer.written());
}

test "variables assignment and print" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = 1; var y = x + 1; print x; print y;", false);

    // Assert
    try std.testing.expectEqualStrings("1\n2\n", writer.written());
}

test "multiple prints" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1; print 2;", false);

    // Assert
    try std.testing.expectEqualStrings("1\n2\n", writer.written());
}

test "print with block" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print 1; { print 3; }", false);

    // Assert
    try std.testing.expectEqualStrings("1\n3\n", writer.written());
}

test "block scope variable" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var y = 1; { var x = 2; print x; } print y;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n1\n", writer.written());
}

test "block scope shadow" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = 1; { var x = 2; print x; }", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "nested blocks" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = 1; { var x = 2; print x; { var x = 3; print x; } } print x;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n3\n1\n", writer.written());
}

test "if positive" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = 1; if (x > 0) { print x; }", false);

    // Assert
    try std.testing.expectEqualStrings("1\n", writer.written());
}

test "if negative" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = -1; if (x > 0) { print x; } print 2;", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "if else positive" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = 1; if (x > 0) { print x; } else { print 2; }", false);

    // Assert
    try std.testing.expectEqualStrings("1\n", writer.written());
}

test "if else negative" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var x = -1; if (x > 0) { print x; } else { print 2; }", false);

    // Assert
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "while test" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var i = 0; while (i < 10) i = i + 1; print i;", false);

    // Assert
    try std.testing.expectEqualStrings("10\n", writer.written());
}

test "for test" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("for(var i = 0; i < 3; i = i + 1) print i;", false);

    // Assert
    try std.testing.expectEqualStrings("0\n1\n2\n", writer.written());
}

test "for test without initializer" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("var i = 0; for(; i < 3; i = i + 1) print i;", false);

    // Assert
    try std.testing.expectEqualStrings("0\n1\n2\n", writer.written());
}

test "function call no arguments" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun sayHi() { print \"hi\"; } sayHi();", false);

    // Assert
    try std.testing.expectEqualStrings("hi\n", writer.written());
}

test "function call with arguments" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun add(a, b) { return a + b; } print add(3, 4);", false);

    // Assert
    try std.testing.expectEqualStrings("7\n", writer.written());
}

test "function call with multiple arguments" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun sum(a, b, c) { return a + b + c; } print sum(1, 2, 3);", false);

    // Assert
    try std.testing.expectEqualStrings("6\n", writer.written());
}

test "function return value" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun double(x) { return x * 2; } print double(5);", false);

    // Assert
    try std.testing.expectEqualStrings("10\n", writer.written());
}

test "function nested calls" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun inner() { return 5; } fun outer() { return inner() * 2; } print outer();", false);

    // Assert
    try std.testing.expectEqualStrings("10\n", writer.written());
}

test "function with early return" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun check(x) { if (x > 0) return 1; return -1; } print check(5); print check(-5);", false);

    // Assert
    try std.testing.expectEqualStrings("1\n-1\n", writer.written());
}

test "function without return statement" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun noReturn() { var x = 5; } print noReturn();", false);

    // Assert
    try std.testing.expectEqualStrings("nil\n", writer.written());
}

test "function recursion factorial" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun fact(n) { if (n <= 1) return 1; return n * fact(n - 1); } print fact(5);", false);

    // Assert
    try std.testing.expectEqualStrings("120\n", writer.written());
}

test "function recursion fibonacci" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun fib(n) { if (n <= 1) return n; return fib(n - 1) + fib(n - 2); } print fib(6);", false);

    // Assert
    try std.testing.expectEqualStrings("8\n", writer.written());
}

test "native function clock" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print clock() > 0;", false);

    // Assert
    try std.testing.expectEqualStrings("true\n", writer.written());
}

test "native function sqrt" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print sqrt(16);", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "native function sqrt of two" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print sqrt(2);", false);

    // Assert
    try std.testing.expectEqualStrings("1.4142135623730951\n", writer.written());
}

test "native function min" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print min(5, 3);", false);

    // Assert
    try std.testing.expectEqualStrings("3\n", writer.written());
}

test "native function min reversed" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print min(3, 5);", false);

    // Assert
    try std.testing.expectEqualStrings("3\n", writer.written());
}

test "native function min equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print min(4, 4);", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "native function max" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print max(5, 3);", false);

    // Assert
    try std.testing.expectEqualStrings("5\n", writer.written());
}

test "native function max reversed" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print max(3, 5);", false);

    // Assert
    try std.testing.expectEqualStrings("5\n", writer.written());
}

test "native function max equal" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print max(4, 4);", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "native functions composition" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print sqrt(max(9, 4));", false);

    // Assert
    try std.testing.expectEqualStrings("3\n", writer.written());
}

test "native functions nested min max" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("print min(max(3, 5), 4);", false);

    // Assert
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "function as argument" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret("fun apply(f, x) { return f(x); } fun negate(x) { return -x; } print apply(negate, 42);", false);

    // Assert
    try std.testing.expectEqualStrings("-42\n", writer.written());
}

test "closures capture outer variable" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("outer\n", writer.written());
}

test "closures multiple instances with different captured values" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("doughnut\nbagel\n", writer.written());
}

test "closures mutate captured variable" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("1\n2\n3\n", writer.written());
}

test "closures survive after enclosing function returns" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("8\n13\n", writer.written());
}

test "nested closures share mutable outer variable" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("2\n3\n", writer.written());
}

test "class declaration and print" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    const code =
        \\class Foo {}
        \\print Foo;
        \\
    ;

    // Act
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("Foo\n", writer.written());
}

test "class declaration and call" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    const code =
        \\class Foo {}
        \\print Foo();
        \\
    ;

    // Act
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("Foo instance\n", writer.written());
}

test "class instance property set and get" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    const code =
        \\class Foo {}
        \\var foo = Foo();
        \\foo.bar = "baz";
        \\print foo.bar;
        \\
    ;

    // Act
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("baz\n", writer.written());
}

test "class method call no arguments" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("hi\n", writer.written());
}

test "class method call with arguments" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("7\n", writer.written());
}

test "class method uses this to access instance field" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("42\n", writer.written());
}

test "class method uses this as receiver" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("Foo instance\n", writer.written());
}

test "class method call multiple methods" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("10\n15\n", writer.written());
}

test "constructor with arguments sets instance fields" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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

    try virtualMachine.interpret(code, false);

    try std.testing.expectEqualStrings("init\n1\n2\n", writer.written());
}

test "constructor without init creates instance" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    const code =
        \\class Foo {}
        \\var foo = Foo();
        \\print foo;
        \\
    ;

    try virtualMachine.interpret(code, false);

    try std.testing.expectEqualStrings("Foo instance\n", writer.written());
}

test "constructor early return still returns instance" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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

    try virtualMachine.interpret(code, false);

    try std.testing.expectEqualStrings("init\nFoo instance\n", writer.written());
}

test "constructor explicit init call does not create new instance" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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

    try virtualMachine.interpret(code, false);

    try std.testing.expectEqualStrings(
        "Foo.init(one)\nFoo.init(two)\nFoo instance\ninit\n",
        writer.written(),
    );
}

test "constructor nested function named init is not initializer" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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

    try virtualMachine.interpret(code, false);

    try std.testing.expectEqualStrings("bar\nFoo instance\n", writer.written());
}

test "nested return preserves frame count" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

    // Act
    try virtualMachine.interpret(
        \\fun a() { return 1; }
        \\fun b() { return a() + 1; }
        \\fun c() { return b() + 1; }
        \\print c();
    , false);

    // Assert
    try std.testing.expectEqualStrings("3\n", writer.written());
}

test "gc instance field survives collection" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("survive\n", writer.written());
}

test "gc class method closure survives collection" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("hello\n", writer.written());
}

test "gc closure in global survives collection" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("42\n", writer.written());
}

test "gc global variable survives collection" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("ok\n", writer.written());
}

test "gc bound methods are collected during method calls" {
    // Arrange
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    var virtualMachine = try init(std.testing.allocator, &writer.writer, std.testing.io);
    defer virtualMachine.deinit();

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
    try virtualMachine.interpret(code, false);

    // Assert
    try std.testing.expectEqualStrings("1\n", writer.written());
}
