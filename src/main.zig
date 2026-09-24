const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const zlox = @import("zlox");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
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

    const gpa: std.mem.Allocator = if (build_options.use_mimalloc)
        @import("mimalloc").allocator
    else
        std.heap.c_allocator;

    const args = try init.minimal.args.toSlice(gpa);
    run(gpa, stdout_writer, io, args[1..]) catch |e| { // skip exe itself
        stdout_writer.flush() catch {};
        // A debug build lets the error escape so the panic handler prints a
        // stack trace, which is the reason to run one. A script that could not
        // be read is the exception: the trace describes std's call chain down
        // to open(2) and adds nothing to what `run` has already reported, while
        // the caller only mistyped a path.
        if (builtin.mode == .Debug and e != zlox.Error.IoError) return e;
        std.process.exit(zlox.exitCode(e));
    };
}

pub fn run(gpa: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io, argv: []const [:0]const u8) !void {
    var config = try zlox.Config.init(gpa, io, argv);
    defer config.deinit();
    var memory = std.Io.Writer.Allocating.init(gpa);
    defer memory.deinit();

    var filename: []const u8 = "";
    if (config.getPathArgValue()) |path| {
        filename = path;
        var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |open_err| {
            std.debug.print("Could not open file \"{s}\": {s}.\n", .{ path, @errorName(open_err) });
            return zlox.Error.IoError;
        };
        defer file.close(io);
        var file_buffer: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &file_buffer);
        _ = file_reader.interface.streamRemaining(&memory.writer) catch |read_err| {
            std.debug.print("Could not read file \"{s}\": {s}.\n", .{ path, @errorName(read_err) });
            return zlox.Error.IoError;
        };
    } else {
        var stdin_buffer: [1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
        _ = stdin_reader.interface.streamRemaining(&memory.writer) catch |read_err| {
            std.debug.print("Could not read standard input: {s}.\n", .{@errorName(read_err)});
            return zlox.Error.IoError;
        };
    }

    var virtual_machine = try zlox.VM.init(gpa, writer, io);
    defer virtual_machine.deinit();
    virtual_machine.line_buffered = std.Io.File.stdout().isTty(io) catch false;
    const from = if (filename.len == 0) "<stdin>" else filename;
    try virtual_machine.interpretFrom(memory.written(), config.printCode(), from);
}

test {
    @import("std").testing.refAllDecls(@This());
}
