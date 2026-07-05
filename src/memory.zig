const std = @import("std");
const val = @import("value.zig");
const tbl = @import("table.zig");

pub const Upvalue = val.Upvalue;
pub const Closure = val.Closure;
pub const Function = val.Function;
pub const HeapString = val.HeapString;
pub const Class = val.Class;
pub const Instance = val.Instance;
pub const BoundMethod = val.BoundMethod;
pub const Obj = val.Obj;

const Table = tbl.Table;
const LoxValue = val.LoxValue;

const GC_HEAP_GROW_FACTOR: usize = 2;
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
                c.deinit(allocator);
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

/// Heap manager with intrusive linked-list object tracking
pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: ?*Obj = null,
    bytes_allocated: usize = 0,
    next_gc: usize = INITIAL_GC_THRESHOLD,
    gray_stack: []HeapObj = &.{},
    gray_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Heap {
        return .{
            .allocator = allocator,
            .gray_stack = try allocator.alloc(HeapObj, GRAY_STACK_INITIAL),
        };
    }

    pub fn deinit(self: *Heap) void {
        var current = self.objects;
        while (current) |obj| {
            const next = obj.next;
            heapObjFromObj(obj).free(self.allocator);
            current = next;
        }
        if (self.gray_stack.len > 0) {
            self.allocator.free(self.gray_stack);
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
        if (value.isString()) {
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
        if (table.capacity == 0) return;
        for (table.entries) |entry| {
            if (entry.key) |key| {
                try self.markObject(.{ .string = key });
                try self.markValue(entry.value);
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
                heap_obj.free(self.allocator);
                current = next;
            }
        }

        self.next_gc = self.bytes_allocated * GC_HEAP_GROW_FACTOR;
    }
};
