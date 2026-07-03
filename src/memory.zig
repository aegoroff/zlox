const std = @import("std");
const val = @import("value.zig");

pub const Upvalue = val.Upvalue;
pub const Closure = val.Closure;
pub const Function = val.Function;
pub const HeapString = val.HeapString;
pub const Class = val.Class;
pub const Instance = val.Instance;

/// Unified type for all heap objects
pub const HeapObj = union(enum) {
    string: *HeapString,
    upvalue: *Upvalue,
    closure: *Closure,
    class: *Class,
    instance: *Instance,
    function: *Function,

    pub fn isMarked(self: HeapObj) bool {
        return switch (self) {
            .string => |s| s.marked,
            .upvalue => |u| u.marked,
            .closure => |c| c.marked,
            .function => |f| f.marked,
            .class => |f| f.marked,
            .instance => |i| i.marked,
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
        }
    }

    pub fn free(self: HeapObj, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |s| {
                allocator.free(s.data);
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
        }
    }
};

/// Heap manager with tracking of all objects
pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(HeapObj),
    bytes_allocated: usize = 0,
    next_gc: usize = 1024 * 1024, // 1MB initial limit

    pub fn init(allocator: std.mem.Allocator) Heap {
        var objects = std.ArrayList(HeapObj).empty;
        objects.ensureTotalCapacity(allocator, 64) catch {};
        return .{
            .allocator = allocator,
            .objects = objects,
        };
    }

    pub fn deinit(self: *Heap) void {
        // Free all objects
        for (self.objects.items) |*obj| {
            obj.free(self.allocator);
        }
        self.objects.deinit(self.allocator);
    }

    pub fn trackObject(self: *Heap, obj: HeapObj, size: usize) !void {
        try self.objects.append(self.allocator, obj);
        self.bytes_allocated += size;
    }

    pub fn shouldCollect(self: *Heap) bool {
        return self.bytes_allocated >= self.next_gc;
    }

    pub fn collectGarbage(self: *Heap) !void {
        // Mark phase already done in VM.markRoots()

        // Sweep phase
        var i: usize = 0;
        while (i < self.objects.items.len) {
            const obj = &self.objects.items[i];
            if (obj.isMarked()) {
                // Reset mark for next cycle
                obj.setMarked(false);
                i += 1;
            } else {
                // Object unreachable - free it
                const size = switch (obj.*) {
                    .string => |s| s.size(),
                    .class => |cl| cl.size(),
                    .upvalue => @sizeOf(Upvalue),
                    .closure => @sizeOf(Closure),
                    .function => |f| f.size(),
                    .instance => |inst| inst.size(),
                };
                self.bytes_allocated -= size;
                obj.free(self.allocator);
                _ = self.objects.orderedRemove(i);
            }
        }

        // Increase limit for next collection
        self.next_gc = self.bytes_allocated * 2;
        if (self.next_gc < 1024 * 1024) {
            self.next_gc = 1024 * 1024;
        }
    }
};
