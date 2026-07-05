const std = @import("std");
const val = @import("value.zig");

const LoxValue = val.LoxValue;
const HeapString = val.HeapString;

const INITIAL_CAPACITY: usize = 8;

pub const Entry = struct {
    key: ?*HeapString = null,
    value: LoxValue = LoxValue.nil,
};

const ProbeMatch = union(enum) {
    pointer: *HeapString,
    bytes: struct { chars: []const u8, hash: u32 },
};

pub const Table = struct {
    count: usize = 0,
    capacity: usize = 0,
    max_load: usize = 0,
    entries: []Entry = &.{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Table) void {
        if (self.capacity > 0) {
            self.allocator.free(self.entries);
        }
        self.* = .init(self.allocator);
    }

    pub inline fn get(self: *const Table, key: *HeapString) ?LoxValue {
        if (self.count == 0) return null;
        const entry = findSlot(self.entries, self.capacity, .{ .pointer = key }, false) orelse return null;
        return entry.value;
    }

    pub inline fn contains(self: *const Table, key: *HeapString) bool {
        if (self.count == 0) return false;
        return findSlot(self.entries, self.capacity, .{ .pointer = key }, false) != null;
    }

    pub inline fn set(self: *Table, key: *HeapString, value: LoxValue) !bool {
        if (self.count + 1 > self.max_load) {
            try self.adjustCapacity(growCapacity(self.capacity));
        }

        const entry = findSlot(self.entries, self.capacity, .{ .pointer = key }, true).?;
        const is_new_key = entry.key == null;
        if (is_new_key and entry.value.isNil()) {
            self.count += 1;
        }

        entry.key = key;
        entry.value = value;
        return is_new_key;
    }

    pub inline fn setExisting(self: *Table, key: *HeapString, value: LoxValue) bool {
        const entry = findSlot(self.entries, self.capacity, .{ .pointer = key }, false) orelse return false;
        entry.value = value;
        return true;
    }

    pub inline fn findString(self: *const Table, chars: []const u8, hash: u32) ?*HeapString {
        if (self.count == 0) return null;
        const entry = findSlot(
            self.entries,
            self.capacity,
            .{ .bytes = .{ .chars = chars, .hash = hash } },
            false,
        ) orelse return null;
        return entry.key;
    }

    pub inline fn delete(self: *Table, key: *HeapString) bool {
        if (self.count == 0) return false;
        const entry = findSlot(self.entries, self.capacity, .{ .pointer = key }, false) orelse return false;
        self.count -= 1;
        entry.key = null;
        entry.value = LoxValue.boolean(true);
        return true;
    }

    pub fn removeWhite(self: *Table) void {
        if (self.capacity == 0) return;
        for (self.entries) |*entry| {
            if (entry.key) |key| {
                if (!key.gc.marked) {
                    _ = self.delete(key);
                }
            }
        }
    }

    pub fn addAll(self: *Table, from: *const Table) !void {
        if (from.count == 0) return;

        const needed = self.count + from.count;
        while (needed > self.max_load) {
            try self.adjustCapacity(growCapacity(self.capacity));
        }

        for (from.entries) |entry| {
            if (entry.key) |key| {
                _ = try self.set(key, entry.value);
            }
        }
    }

    inline fn adjustCapacity(self: *Table, new_capacity: usize) !void {
        const entries = try self.allocator.alloc(Entry, new_capacity);
        for (entries) |*entry| {
            entry.* = .{};
        }

        self.count = 0;
        if (self.capacity > 0) {
            for (self.entries) |entry| {
                if (entry.key) |key| {
                    const dest = findSlot(entries, new_capacity, .{ .pointer = key }, true).?;
                    dest.key = key;
                    dest.value = entry.value;
                    self.count += 1;
                }
            }
            self.allocator.free(self.entries);
        }

        self.entries = entries;
        self.capacity = new_capacity;
        self.max_load = maxLoad(new_capacity);
    }

    inline fn growCapacity(capacity: usize) usize {
        if (capacity < INITIAL_CAPACITY) return INITIAL_CAPACITY;
        return capacity * 2;
    }

    inline fn maxLoad(capacity: usize) usize {
        if (capacity == 0) return 0;
        return (capacity * 3) / 4;
    }
};

inline fn hashIndex(hash: u32, capacity: usize) usize {
    return @intCast(hash & @as(u32, @intCast(capacity - 1)));
}

inline fn nextIndex(index: usize, capacity: usize) usize {
    return (index + 1) & (capacity - 1);
}

inline fn keysEqual(entry_key: *HeapString, match: ProbeMatch) bool {
    return switch (match) {
        .pointer => |ptr| entry_key == ptr,
        .bytes => |b| entry_key.hash == b.hash and
            entry_key.data.len == b.chars.len and
            std.mem.eql(u8, entry_key.data, b.chars),
    };
}

inline fn findSlot(
    entries: []Entry,
    capacity: usize,
    match: ProbeMatch,
    comptime for_insert: bool,
) ?*Entry {
    if (capacity == 0) return null;

    const hash = switch (match) {
        .pointer => |ptr| ptr.hash,
        .bytes => |b| b.hash,
    };

    var index = hashIndex(hash, capacity);
    var tombstone: ?*Entry = null;

    while (true) {
        const entry = &entries[index];
        if (entry.key) |entry_key| {
            if (keysEqual(entry_key, match)) return entry;
        } else {
            if (entry.value.isNil()) {
                if (for_insert) return tombstone orelse entry;
                return null;
            }
            if (for_insert and tombstone == null) tombstone = entry;
        }

        index = nextIndex(index, capacity);
    }
}

pub inline fn hashString(bytes: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return hash;
}

test "table set and get" {
    const bytes = "foo";
    var str = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(bytes), .data = bytes };

    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    const is_new = try table.set(&str, LoxValue.number(42));
    try std.testing.expect(is_new);

    const value = table.get(&str).?;
    try std.testing.expectEqual(@as(f64, 42), value.asNumber());

    const is_new_again = try table.set(&str, LoxValue.number(7));
    try std.testing.expect(!is_new_again);
    try std.testing.expectEqual(@as(f64, 7), table.get(&str).?.asNumber());
}

test "table setExisting" {
    const bytes = "foo";
    var str = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(bytes), .data = bytes };

    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expect(!table.setExisting(&str, LoxValue.number(1)));

    _ = try table.set(&str, LoxValue.number(42));
    try std.testing.expect(table.setExisting(&str, LoxValue.number(7)));
    try std.testing.expectEqual(@as(f64, 7), table.get(&str).?.asNumber());
}

test "table findString" {
    const bytes = "hello";
    var str = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(bytes), .data = bytes };

    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.set(&str, LoxValue.nil);

    try std.testing.expect(table.findString(bytes, str.hash) == &str);
    try std.testing.expect(table.findString("world", hashString("world")) == null);
}

test "table delete leaves tombstone" {
    const bytes = "hello";
    var str = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(bytes), .data = bytes };

    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.set(&str, LoxValue.nil);
    try std.testing.expect(table.delete(&str));
    try std.testing.expect(table.get(&str) == null);
    try std.testing.expectEqual(@as(usize, 0), table.count);
}

test "table removeWhite deletes unmarked strings" {
    const live_bytes = "live";
    const dead_bytes = "dead";
    var live = val.HeapString{ .gc = .{ .kind = .string, .marked = true }, .hash = hashString(live_bytes), .data = live_bytes };
    var dead = val.HeapString{ .gc = .{ .kind = .string, .marked = false }, .hash = hashString(dead_bytes), .data = dead_bytes };

    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.set(&live, LoxValue.nil);
    _ = try table.set(&dead, LoxValue.nil);

    table.removeWhite();

    try std.testing.expect(table.findString(live_bytes, live.hash) == &live);
    try std.testing.expect(table.findString(dead_bytes, dead.hash) == null);
    try std.testing.expectEqual(@as(usize, 1), table.count);
}

test "table addAll copies entries" {
    const a_bytes = "a";
    const b_bytes = "b";
    var a = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(a_bytes), .data = a_bytes };
    var b = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(b_bytes), .data = b_bytes };

    var from = Table.init(std.testing.allocator);
    defer from.deinit();
    _ = try from.set(&a, LoxValue.number(1));
    _ = try from.set(&b, LoxValue.number(2));

    var to = Table.init(std.testing.allocator);
    defer to.deinit();
    try to.addAll(&from);

    try std.testing.expectEqual(@as(f64, 1), to.get(&a).?.asNumber());
    try std.testing.expectEqual(@as(f64, 2), to.get(&b).?.asNumber());
}
