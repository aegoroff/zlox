const std = @import("std");
const val = @import("value.zig");

pub const Upvalue = val.Upvalue;
pub const Closure = val.Closure;
pub const Function = val.Function;
pub const HeapString = val.HeapString;
pub const Class = val.Class;
pub const Instance = val.Instance;
pub const BoundMethod = val.BoundMethod;

const CHUNK_SIZE: usize = 256 * 1024;
const GC_HEAP_GROW_FACTOR: usize = 2;
const INITIAL_GC_THRESHOLD: usize = 1024 * 1024;
const CHUNK_ALIGNMENT: std.mem.Alignment = .@"16";

const FreeList = struct {
    next: ?*FreeList = null,
};

const BumpRegion = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList([]u8) = .empty,
    current: ?[]u8 = null,
    offset: usize = 0,

    fn deinit(self: *BumpRegion) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk);
        }
        self.chunks.deinit(self.allocator);
    }

    fn allocBytes(self: *BumpRegion, size: usize, alignment: usize) ![*]u8 {
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment);
        if (self.current) |chunk| {
            if (aligned_offset + size <= chunk.len) {
                self.offset = aligned_offset + size;
                return chunk[aligned_offset..].ptr;
            }
        }

        const chunk_size = @max(CHUNK_SIZE, std.mem.alignForward(usize, size, alignment));
        const chunk = try self.allocator.alignedAlloc(u8, CHUNK_ALIGNMENT, chunk_size);
        try self.chunks.append(self.allocator, chunk);
        self.current = chunk;
        self.offset = std.mem.alignForward(usize, size, alignment);
        return chunk[0..size].ptr;
    }

    fn alloc(self: *BumpRegion, comptime T: type) !*T {
        const ptr = try self.allocBytes(@sizeOf(T), @alignOf(T));
        return @ptrCast(@alignCast(ptr));
    }
};

fn Pool(comptime T: type) type {
    return struct {
        free: ?*T = null,

        fn alloc(self: *@This(), bump: *BumpRegion) !*T {
            if (self.free) |ptr| {
                const node: *FreeList = @ptrCast(@alignCast(ptr));
                self.free = @ptrCast(@alignCast(node.next));
                return ptr;
            }
            return bump.alloc(T);
        }

        fn release(self: *@This(), ptr: *T) void {
            const node: *FreeList = @ptrCast(@alignCast(ptr));
            node.next = @ptrCast(@alignCast(self.free));
            self.free = ptr;
        }
    };
}

/// Unified type for all heap objects
pub const HeapObj = union(enum) {
    string: *HeapString,
    upvalue: *Upvalue,
    closure: *Closure,
    class: *Class,
    instance: *Instance,
    bound_method: *BoundMethod,
    function: *Function,

    pub fn isMarked(self: HeapObj) bool {
        return switch (self) {
            .string => |s| s.marked,
            .upvalue => |u| u.marked,
            .closure => |c| c.marked,
            .function => |f| f.marked,
            .class => |c| c.marked,
            .instance => |i| i.marked,
            .bound_method => |b| b.marked,
        };
    }

    pub fn setMarked(self: HeapObj, marked: bool) void {
        switch (self) {
            .string => |s| s.marked = marked,
            .upvalue => |u| u.marked = marked,
            .closure => |c| c.marked = marked,
            .function => |f| f.marked = marked,
            .class => |c| c.marked = marked,
            .instance => |i| i.marked = marked,
            .bound_method => |b| b.marked = marked,
        }
    }
};

pub const ObjectNode = struct {
    obj: HeapObj,
    size: usize,
    next: ?*ObjectNode,
};

/// Heap manager with bump allocation and object tracking
pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: ?*ObjectNode = null,
    bytes_allocated: usize = 0,
    next_gc: usize = INITIAL_GC_THRESHOLD,

    bump: BumpRegion,
    object_node_pool: Pool(ObjectNode) = .{},
    instance_pool: Pool(Instance) = .{},
    closure_pool: Pool(Closure) = .{},
    upvalue_pool: Pool(Upvalue) = .{},
    bound_method_pool: Pool(BoundMethod) = .{},
    class_pool: Pool(Class) = .{},
    string_pool: Pool(HeapString) = .{},

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{
            .allocator = allocator,
            .bump = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Heap) void {
        var current = self.objects;
        while (current) |node| {
            self.releaseObject(node.obj);
            current = node.next;
        }
        self.bump.deinit();
    }

    pub fn allocInstance(self: *Heap) !*Instance {
        return self.instance_pool.alloc(&self.bump);
    }

    pub fn allocClosure(self: *Heap) !*Closure {
        return self.closure_pool.alloc(&self.bump);
    }

    pub fn allocUpvalue(self: *Heap) !*Upvalue {
        return self.upvalue_pool.alloc(&self.bump);
    }

    pub fn allocBoundMethod(self: *Heap) !*BoundMethod {
        return self.bound_method_pool.alloc(&self.bump);
    }

    pub fn allocClass(self: *Heap) !*Class {
        return self.class_pool.alloc(&self.bump);
    }

    pub fn allocStringHeader(self: *Heap) !*HeapString {
        return self.string_pool.alloc(&self.bump);
    }

    pub fn trackObject(self: *Heap, obj: HeapObj, size: usize) !void {
        const node = try self.object_node_pool.alloc(&self.bump);
        node.* = .{
            .obj = obj,
            .size = size,
            .next = self.objects,
        };
        self.objects = node;
        self.bytes_allocated += size;
    }

    pub fn adjustMapCapacity(self: *Heap, old_capacity: usize, new_capacity: usize, entry_size: usize) void {
        const old_bytes = old_capacity * entry_size;
        const new_bytes = new_capacity * entry_size;
        if (new_bytes >= old_bytes) {
            self.bytes_allocated += new_bytes - old_bytes;
        } else {
            self.bytes_allocated -= old_bytes - new_bytes;
        }
    }

    pub fn shouldCollect(self: *const Heap) bool {
        return self.bytes_allocated > self.next_gc;
    }

    pub fn collectGarbage(self: *Heap) void {
        var previous: ?*ObjectNode = null;
        var current = self.objects;
        while (current) |node| {
            if (node.obj.isMarked()) {
                node.obj.setMarked(false);
                previous = node;
                current = node.next;
            } else {
                self.bytes_allocated -= node.size;
                self.releaseObject(node.obj);

                const unreached = node;
                const next = node.next;
                if (previous) |prev| {
                    prev.next = next;
                } else {
                    self.objects = next;
                }
                current = next;
                self.object_node_pool.release(unreached);
            }
        }

        self.next_gc = self.bytes_allocated * GC_HEAP_GROW_FACTOR;
    }

    fn releaseObject(self: *Heap, obj: HeapObj) void {
        switch (obj) {
            .string => |s| {
                self.allocator.free(@constCast(s.data));
                self.string_pool.release(s);
            },
            .class => |cl| {
                cl.deinit();
                self.class_pool.release(cl);
            },
            .upvalue => |u| {
                self.upvalue_pool.release(u);
            },
            .closure => |c| {
                self.closure_pool.release(c);
            },
            .function => |f| {
                f.deinit();
                self.allocator.destroy(f);
            },
            .instance => |i| {
                i.deinit();
                self.instance_pool.release(i);
            },
            .bound_method => |b| {
                self.bound_method_pool.release(b);
            },
        }
    }
};
