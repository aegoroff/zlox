const std = @import("std");
const configuration = @import("configuration.zig");
const yazap = @import("yazap");
const vm = @import("vm.zig");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const gpa = init.arena.allocator();

    // In order to do I/O operations need an `Io` instance.
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

    const args = try init.minimal.args.toSlice(gpa);
    try run(gpa, stdout_writer, io, args[1..]); // skip exe itself

}

pub fn run(gpa: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io, argv: []const [:0]const u8) !void {
    var config = try configuration.Config.init(gpa, io, argv);
    defer config.deinit();
    if (configuration.getPathArgValue(config.matches)) |path| {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);
        const stat = try file.stat(io);
        var file_buffer: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &file_buffer);
        const reader = &file_reader.interface;
        const source = try reader.readAlloc(gpa, stat.size);
        var virtualMachine = vm.init(gpa, writer);
        defer virtualMachine.deinit();
        try virtualMachine.interpret(source);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
