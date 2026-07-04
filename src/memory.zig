const std = @import("std");
const val = @import("value.zig");

pub const Upvalue = val.Upvalue;
pub const Closure = val.Closure;
pub const Function = val.Function;
pub const HeapString = val.HeapString;
pub const Class = val.Class;
pub const Instance = val.Instance;
pub const BoundMethod = val.BoundMethod;

const GC_HEAP_GROW_FACTOR: usize = 2;
const INITIAL_GC_THRESHOLD: usize = 1024 * 1024;

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

    pub fn liveSize(self: HeapObj) usize {
        return switch (self) {
            .string => |s| s.size(),
            .class => |c| c.size(),
            .function => |f| f.size(),
            .instance => |i| i.size(),
            .upvalue => @sizeOf(Upvalue),
            .closure => @sizeOf(Closure),
            .bound_method => @sizeOf(BoundMethod),
        };
    }

    pub fn free(self: HeapObj, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |s| {
                allocator.free(@constCast(s.data));
                allocator.destroy(s);
            },
            .class => |cl| {
                cl.deinit();
                allocator.destroy(cl);
            },
            .upvalue => |u| {
                allocator.destroy(u);
            },
            .closure => |c| {
                allocator.destroy(c);
            },
            .function => |f| {
                f.deinit();
                allocator.destroy(f);
            },
            .instance => |i| {
                i.deinit();
                allocator.destroy(i);
            },
            .bound_method => |b| {
                allocator.destroy(b);
            },
        }
    }
};

pub const ObjectNode = struct {
    obj: HeapObj,
    next: ?*ObjectNode,
};

/// Heap manager with linked-list object tracking
pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: ?*ObjectNode = null,
    bytes_allocated: usize = 0,
    next_gc: usize = INITIAL_GC_THRESHOLD,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Heap) void {
        var current = self.objects;
        while (current) |node| {
            node.obj.free(self.allocator);
            const next = node.next;
            self.allocator.destroy(node);
            current = next;
        }
    }

    pub fn allocInstance(self: *Heap) !*Instance {
        return self.allocator.create(Instance);
    }

    pub fn allocClosure(self: *Heap) !*Closure {
        return self.allocator.create(Closure);
    }

    pub fn allocUpvalue(self: *Heap) !*Upvalue {
        return self.allocator.create(Upvalue);
    }

    pub fn allocBoundMethod(self: *Heap) !*BoundMethod {
        return self.allocator.create(BoundMethod);
    }

    pub fn allocClass(self: *Heap) !*Class {
        return self.allocator.create(Class);
    }

    pub fn allocStringHeader(self: *Heap) !*HeapString {
        return self.allocator.create(HeapString);
    }

    pub fn trackObject(self: *Heap, obj: HeapObj, size: usize) !void {
        const node = try self.allocator.create(ObjectNode);
        node.* = .{
            .obj = obj,
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
                self.bytes_allocated -= node.obj.liveSize();
                node.obj.free(self.allocator);

                const unreached = node;
                const next = node.next;
                if (previous) |prev| {
                    prev.next = next;
                } else {
                    self.objects = next;
                }
                current = next;
                self.allocator.destroy(unreached);
            }
        }

        self.next_gc = self.bytes_allocated * GC_HEAP_GROW_FACTOR;
    }
};
