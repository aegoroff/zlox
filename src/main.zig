const std = @import("std");
const configuration = @import("configuration.zig");
const yazap = @import("yazap");
const vm = @import("vm.zig");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    defer {
        stdout_writer.flush() catch {};
    }

    const args = try init.minimal.args.toSlice(allocator);
    try run(allocator, stdout_writer, io, args[1..]); // skip exe itself

}

pub fn run(gpa: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io, argv: []const [:0]const u8) !void {
    var config = try configuration.Config.init(gpa, io, argv);
    defer config.deinit();
    var memory = std.Io.Writer.Allocating.init(gpa);
    defer memory.deinit();

    var filename: []const u8 = "";
    if (config.getPathArgValue()) |path| {
        filename = path;
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);
        var file_buffer: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &file_buffer);
        _ = try file_reader.interface.streamRemaining(&memory.writer);
    } else {
        var stdin_buffer: [1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
        _ = try stdin_reader.interface.streamRemaining(&memory.writer);
    }

    var virtualMachine = try vm.init(gpa, writer, io);
    defer virtualMachine.deinit();
    const fname = if (filename.len == 0) "<stdin>" else filename;
    try virtualMachine.interpretWithFilename(memory.written(), config.printCode(), fname);
}

test {
    @import("std").testing.refAllDecls(@This());
}
