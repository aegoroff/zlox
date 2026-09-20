const std = @import("std");
const val = @import("value.zig");
const tbl = @import("table.zig");

const Upvalue = val.Upvalue;
const Closure = val.Closure;
const Function = val.Function;
const HeapString = val.HeapString;
const Class = val.Class;
const Instance = val.Instance;
const BoundMethod = val.BoundMethod;
const Obj = val.Obj;

const Table = tbl.Table;
const LoxValue = val.LoxValue;

const GC_HEAP_GROW_FACTOR: usize = 2;
const BLOCK_SIZE: usize = 64 * 1024;
const SIZE_GRANULARITY: usize = 8;
const MAX_POOLED_SIZE: usize = 64;
const SIZE_CLASS_COUNT: usize = MAX_POOLED_SIZE / SIZE_GRANULARITY;
const BLOCK_ALIGNMENT: std.mem.Alignment = .fromByteUnits(SIZE_GRANULARITY);
const INITIAL_GC_THRESHOLD: usize = 1024 * 1024;
const GRAY_STACK_INITIAL: usize = 1024;

/// Unified type for all heap objects
pub const HeapObj = union(enum) {
    string: *HeapString,
    upvalue: *Upvalue,
    closure: *Closure,
    class: *Class,
    instance: *Instance,
    bound_method: *BoundMethod,
    function: *Function,

    pub inline fn obj(self: HeapObj) *Obj {
        return switch (self) {
            .string => |s| &s.gc,
            .upvalue => |u| &u.gc,
            .closure => |c| &c.gc,
            .function => |f| &f.gc,
            .class => |c| &c.gc,
            .instance => |i| &i.gc,
            .bound_method => |b| &b.gc,
        };
    }

    pub inline fn isMarked(self: HeapObj) bool {
        return self.obj().marked;
    }

    pub inline fn setMarked(self: HeapObj, marked: bool) void {
        self.obj().marked = marked;
    }

    pub inline fn liveSize(self: HeapObj) usize {
        return switch (self) {
            .string => |s| s.size(),
            .class => |c| c.size(),
            .function => |f| f.size(),
            .instance => |i| i.size(),
            .upvalue => @sizeOf(Upvalue),
            .closure => |c| c.size(),
            .bound_method => @sizeOf(BoundMethod),
        };
    }

    /// Releases whatever the object owns on the general allocator, then returns
    /// its own storage to the pool. `Function` is not pooled: it is an order of
    /// magnitude larger than the rest and is created once per compiled body.
    pub fn free(self: HeapObj, allocator: std.mem.Allocator, pool: *Pool) void {
        switch (self) {
            .string => |s| {
                allocator.free(@constCast(s.data));
                pool.destroy(HeapString, s);
            },
            .class => |cl| {
                cl.deinit(allocator);
                pool.destroy(Class, cl);
            },
            .upvalue => |u| {
                pool.destroy(Upvalue, u);
            },
            .closure => |c| {
                c.deinit(allocator);
                pool.destroy(Closure, c);
            },
            .function => |f| {
                f.deinit();
                allocator.destroy(f);
            },
            .instance => |i| {
                i.deinit(allocator);
                pool.destroy(Instance, i);
            },
            .bound_method => |b| {
                pool.destroy(BoundMethod, b);
            },
        }
    }
};

inline fn heapObjFromObj(obj: *Obj) HeapObj {
    return switch (obj.kind) {
        .string => .{ .string = @fieldParentPtr("gc", obj) },
        .upvalue => .{ .upvalue = @fieldParentPtr("gc", obj) },
        .closure => .{ .closure = @fieldParentPtr("gc", obj) },
        .class => .{ .class = @fieldParentPtr("gc", obj) },
        .instance => .{ .instance = @fieldParentPtr("gc", obj) },
        .bound_method => .{ .bound_method = @fieldParentPtr("gc", obj) },
        .function => .{ .function = @fieldParentPtr("gc", obj) },
    };
}

/// Storage for the fixed-size heap objects, carved from large blocks instead of
/// taken from the general allocator one object at a time. A benchmark that
/// builds fifteen million instances otherwise pays for fifteen million
/// malloc/free pairs, and scatters the objects while doing it — which the
/// collector pays for a second time whenever it walks them.
///
/// Free lists are keyed by size rather than by type. `Instance`, `Class`,
/// `Upvalue` and `HeapString` all occupy 40 bytes, so storage released by one
/// can serve another, the way a general allocator's size bins already do; a
/// list per type would hold every type's peak at once. `Function` is far larger
/// and rare, so it stays on the general allocator.
const Pool = struct {
    /// A recycled slot, threaded through the object's own storage.
    const Slot = struct { next: ?*Slot };
    /// Block header, living in the first bytes of the block it describes. The
    /// length is implied by `BLOCK_SIZE`, so only the link is stored.
    const Block = struct { next: ?*Block };

    blocks: ?*Block = null,
    free_lists: [SIZE_CLASS_COUNT]?*Slot = @splat(null),
    /// Bump cursor into the newest block, and what is left of it.
    cursor: [*]u8 = undefined,
    left: usize = 0,

    inline fn sizeClass(comptime T: type) usize {
        comptime {
            std.debug.assert(@alignOf(T) <= SIZE_GRANULARITY);
            std.debug.assert(@sizeOf(T) >= @sizeOf(Slot));
            std.debug.assert(@sizeOf(T) <= MAX_POOLED_SIZE);
        }
        return (@sizeOf(T) + SIZE_GRANULARITY - 1) / SIZE_GRANULARITY - 1;
    }

    fn create(self: *Pool, gpa: std.mem.Allocator, comptime T: type) !*T {
        return @ptrCast(@alignCast(try self.carve(gpa, comptime sizeClass(T))));
    }

    /// One shared body, deliberately not inlined. Every object kind reaches
    /// this from inside the dispatch loop, and six inlined copies of it push
    /// the loop out of the instruction and uop caches — which costs more than
    /// the call, even at fifteen million allocations.
    noinline fn carve(self: *Pool, gpa: std.mem.Allocator, class: usize) ![*]u8 {
        if (self.free_lists[class]) |slot| {
            self.free_lists[class] = slot.next;
            return @ptrCast(slot);
        }

        const size = (class + 1) * SIZE_GRANULARITY;
        if (self.left < size) try self.addBlock(gpa);
        const storage = self.cursor;
        self.cursor += size;
        self.left -= size;
        return storage;
    }

    fn destroy(self: *Pool, comptime T: type, ptr: *T) void {
        const class = comptime sizeClass(T);
        const slot: *Slot = @ptrCast(@alignCast(ptr));
        slot.next = self.free_lists[class];
        self.free_lists[class] = slot;
    }

    fn addBlock(self: *Pool, gpa: std.mem.Allocator) !void {
        const bytes = try gpa.alignedAlloc(u8, BLOCK_ALIGNMENT, BLOCK_SIZE);
        const block: *Block = @ptrCast(@alignCast(bytes.ptr));
        block.* = .{ .next = self.blocks };
        self.blocks = block;
        // The tail of the previous block is abandoned. At one block in 64 KiB
        // and at most 64 bytes lost, that is under a tenth of a percent.
        self.cursor = bytes.ptr + @sizeOf(Block);
        self.left = BLOCK_SIZE - @sizeOf(Block);
    }

    fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
        var current = self.blocks;
        while (current) |block| {
            const next = block.next;
            const raw: [*]align(SIZE_GRANULARITY) u8 = @ptrCast(block);
            const bytes: []align(SIZE_GRANULARITY) u8 = raw[0..BLOCK_SIZE];
            gpa.free(bytes);
            current = next;
        }
        self.* = .{};
    }
};

/// Heap manager with intrusive linked-list object tracking
pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: ?*Obj = null,
    bytes_allocated: usize = 0,
    next_gc: usize = INITIAL_GC_THRESHOLD,
    gray_stack: []HeapObj = &.{},
    gray_count: usize = 0,
    pool: Pool = .{},

    pub fn init(allocator: std.mem.Allocator) !Heap {
        return .{
            .allocator = allocator,
            .gray_stack = try allocator.alloc(HeapObj, GRAY_STACK_INITIAL),
        };
    }

    pub fn deinit(self: *Heap) void {
        // Only the memory each object owns is released here; the objects
        // themselves live in the pool's blocks, which go last and wholesale.
        var current = self.objects;
        while (current) |obj| {
            const next = obj.next;
            heapObjFromObj(obj).free(self.allocator, &self.pool);
            current = next;
        }
        self.pool.deinit(self.allocator);
        if (self.gray_stack.len > 0) {
            self.allocator.free(self.gray_stack);
        }
    }

    pub fn alloc(self: *Heap, comptime T: type) !*T {
        return self.pool.create(self.allocator, T);
    }

    pub fn trackObject(self: *Heap, obj: HeapObj, size: usize) !void {
        const header = obj.obj();
        header.next = self.objects;
        self.objects = header;
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

    inline fn growGrayStack(self: *Heap) !void {
        const new_capacity = if (self.gray_stack.len == 0) GRAY_STACK_INITIAL else self.gray_stack.len * 2;
        self.gray_stack = try self.allocator.realloc(self.gray_stack, new_capacity);
    }

    pub inline fn markObject(self: *Heap, obj: HeapObj) !void {
        if (obj.isMarked()) return;
        obj.setMarked(true);
        if (self.gray_count >= self.gray_stack.len) {
            try self.growGrayStack();
        }
        self.gray_stack[self.gray_count] = obj;
        self.gray_count += 1;
    }

    pub fn markValue(self: *Heap, value: LoxValue) !void {
        if (value.isHeapString()) {
            try self.markObject(.{ .string = value.asString() });
        } else if (value.isFunction()) {
            try self.markObject(.{ .function = value.asFunction() });
        } else if (value.isClosure()) {
            try self.markObject(.{ .closure = value.asClosure() });
        } else if (value.isClass()) {
            try self.markObject(.{ .class = value.asClass() });
        } else if (value.isInstance()) {
            try self.markObject(.{ .instance = value.asInstance() });
        } else if (value.isBoundMethod()) {
            try self.markObject(.{ .bound_method = value.asBoundMethod() });
        }
    }

    pub fn markTable(self: *Heap, table: *const Table) !void {
        if (table.count == 0) return;
        var found: usize = 0;
        for (table.slice()) |entry| {
            if (entry.key) |key| {
                try self.markObject(.{ .string = key });
                try self.markValue(entry.value);
                found += 1;
                if (found == table.count) return;
            }
        }
    }

    fn blackenObject(self: *Heap, obj: HeapObj) !void {
        switch (obj) {
            .bound_method => |bound| {
                try self.markValue(LoxValue.instance(bound.receiver));
                try self.markValue(bound.method);
            },
            .class => |klass| {
                try self.markObject(.{ .string = klass.name });
                try self.markTable(&klass.methods);
            },
            .closure => |closure| {
                try self.markObject(.{ .function = closure.function });
                for (closure.upvalues) |upvalue| {
                    try self.markObject(.{ .upvalue = upvalue });
                }
            },
            .function => |function| {
                for (function.chunk.constants.items) |constant| {
                    try self.markValue(constant);
                }
            },
            .instance => |instance| {
                try self.markObject(.{ .class = instance.klass });
                try self.markTable(&instance.fields);
            },
            .upvalue => |upvalue| {
                if (upvalue.isClosed()) {
                    try self.markValue(upvalue.closed);
                }
            },
            .string => {},
        }
    }

    pub fn traceReferences(self: *Heap) !void {
        while (self.gray_count > 0) {
            self.gray_count -= 1;
            const obj = self.gray_stack[self.gray_count];
            try self.blackenObject(obj);
        }
    }

    pub fn sweep(self: *Heap) void {
        var previous: ?*Obj = null;
        var current = self.objects;
        while (current) |obj| {
            if (obj.marked) {
                obj.marked = false;
                previous = obj;
                current = obj.next;
            } else {
                const heap_obj = heapObjFromObj(obj);
                self.bytes_allocated -= heap_obj.liveSize();
                const next = obj.next;
                if (previous) |prev| {
                    prev.next = next;
                } else {
                    self.objects = next;
                }
                heap_obj.free(self.allocator, &self.pool);
                current = next;
            }
        }

        self.next_gc = self.bytes_allocated * GC_HEAP_GROW_FACTOR;
    }
};
