const std = @import("std");
const val = @import("value.zig");

const LoxValue = val.LoxValue;
const HeapString = val.HeapString;

const TABLE_MAX_LOAD: f64 = 0.75;
const INITIAL_CAPACITY: usize = 8;

pub const Entry = struct {
    key: ?*HeapString = null,
    value: LoxValue = LoxValue.nil,
};

pub const Table = struct {
    count: usize = 0,
    capacity: usize = 0,
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

    pub fn get(self: *const Table, key: *HeapString) ?LoxValue {
        if (self.count == 0) return null;
        const entry = findEntry(self.entries, self.capacity, key) orelse return null;
        if (entry.key == null) return null;
        return entry.value;
    }

    pub fn contains(self: *const Table, key: *HeapString) bool {
        return self.get(key) != null;
    }

    pub fn set(self: *Table, key: *HeapString, value: LoxValue) !bool {
        if (self.count + 1 > loadThreshold(self.capacity)) {
            try self.adjustCapacity(growCapacity(self.capacity));
        }

        const entry = findEntry(self.entries, self.capacity, key).?;
        const is_new_key = entry.key == null;
        if (is_new_key and entry.value.isNil()) {
            self.count += 1;
        }

        entry.key = key;
        entry.value = value;
        return is_new_key;
    }

    pub fn findString(self: *const Table, chars: []const u8, hash: u32) ?*HeapString {
        if (self.count == 0) return null;

        var index: usize = @intCast(hash & @as(u32, @intCast(self.capacity - 1)));
        while (true) {
            const entry = &self.entries[index];
            if (entry.key == null) {
                if (entry.value.isNil()) return null;
            } else {
                const key = entry.key.?;
                if (key.hash == hash and key.data.len == chars.len and
                    std.mem.eql(u8, key.data, chars))
                {
                    return key;
                }
            }

            index = (index + 1) & (self.capacity - 1);
        }
    }

    pub fn addAll(self: *Table, from: *const Table) !void {
        if (from.capacity == 0) return;
        for (from.entries) |entry| {
            if (entry.key) |key| {
                _ = try self.set(key, entry.value);
            }
        }
    }

    pub fn forEach(
        self: *const Table,
        ctx: anytype,
        callback: *const fn (ctx: @TypeOf(ctx), key: *HeapString, value: LoxValue) void,
    ) void {
        if (self.capacity == 0) return;
        for (self.entries) |entry| {
            if (entry.key) |key| {
                callback(ctx, key, entry.value);
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
                    const dest = findEntry(entries, new_capacity, key).?;
                    dest.key = key;
                    dest.value = entry.value;
                    self.count += 1;
                }
            }
            self.allocator.free(self.entries);
        }

        self.entries = entries;
        self.capacity = new_capacity;
    }

    fn growCapacity(capacity: usize) usize {
        if (capacity < INITIAL_CAPACITY) return INITIAL_CAPACITY;
        return capacity * 2;
    }

    fn loadThreshold(capacity: usize) usize {
        if (capacity == 0) return 0;
        return @intFromFloat(@as(f64, @floatFromInt(capacity)) * TABLE_MAX_LOAD);
    }

    inline fn findEntry(entries: []Entry, capacity: usize, key: *HeapString) ?*Entry {
        if (capacity == 0) return null;

        var index: usize = @intCast(key.hash & @as(u32, @intCast(capacity - 1)));
        var tombstone: ?*Entry = null;

        while (true) {
            const entry = &entries[index];
            if (entry.key == null) {
                if (entry.value.isNil()) {
                    return tombstone orelse entry;
                }
                if (tombstone == null) tombstone = entry;
            } else if (entry.key.? == key) {
                return entry;
            }

            index = (index + 1) & (capacity - 1);
        }
    }
};

pub fn hashString(bytes: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return hash;
}

test "table set and get" {
    const bytes = "foo";
    var str = val.HeapString{ .hash = hashString(bytes), .data = bytes };

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

test "table findString" {
    const bytes = "hello";
    var str = val.HeapString{ .hash = hashString(bytes), .data = bytes };

    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.set(&str, LoxValue.nil);

    try std.testing.expect(table.findString(bytes, str.hash) == &str);
    try std.testing.expect(table.findString("world", hashString("world")) == null);
}

test "table addAll copies entries" {
    const a_bytes = "a";
    const b_bytes = "b";
    var a = val.HeapString{ .hash = hashString(a_bytes), .data = a_bytes };
    var b = val.HeapString{ .hash = hashString(b_bytes), .data = b_bytes };

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
