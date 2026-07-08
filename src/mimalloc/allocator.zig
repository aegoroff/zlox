const std = @import("std");
const Allocator = std.mem.Allocator;

const mi = @import("mi");

var state: i32 = 0;

const vtable = Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

pub const allocator = Allocator{
    .ptr = &state,
    .vtable = &vtable,
};

fn alloc(_: *anyopaque, len: usize, log2_align: std.mem.Alignment, _: usize) ?[*]u8 {
    std.debug.assert(len > 0);
    const ptr = mi.mi_malloc_aligned(len, log2_align.toByteUnits()) orelse return null;
    return @ptrCast(ptr);
}

fn resize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    std.debug.assert(new_len > 0);
    std.debug.assert(buf.len > 0);
    return mi.mi_expand(buf.ptr, new_len) != null;
}

fn remap(_: *anyopaque, buf: []u8, log2_align: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    std.debug.assert(new_len > 0);
    std.debug.assert(buf.len > 0);
    const ptr = mi.mi_realloc_aligned(buf.ptr, new_len, log2_align.toByteUnits()) orelse return null;
    return @ptrCast(ptr);
}

fn free(_: *anyopaque, buf: []u8, log2_align: std.mem.Alignment, _: usize) void {
    mi.mi_free_aligned(buf.ptr, log2_align.toByteUnits());
}
