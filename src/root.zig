//! zlox — bytecode compiler and virtual machine for the Lox programming language.

pub const chunk = @import("chunk.zig");
pub const Chunk = chunk.Chunk;
pub const OpCode = chunk.OpCode;

pub const value = @import("value.zig");
pub const LoxValue = value.LoxValue;

pub const vm = @import("vm.zig");
pub const VM = vm.VM;

pub const compiler = @import("compiler.zig");
pub const Compiler = compiler.Compiler;

pub const scanner = @import("scanner.zig");
pub const Lexer = scanner.Lexer;

pub const memory = @import("memory.zig");
pub const Heap = memory.Heap;

pub const table = @import("table.zig");
pub const Table = table.Table;

pub const errors = @import("error.zig");
pub const Error = errors.Error;
pub const exitCode = errors.exitCode;

pub const configuration = @import("configuration.zig");
pub const Config = configuration.Config;

pub const builtin = @import("builtin.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
