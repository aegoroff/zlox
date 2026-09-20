const std = @import("std");
const val = @import("value.zig");

const LoxValue = val.LoxValue;
const HeapString = val.HeapString;

const INITIAL_CAPACITY: u32 = 8;

/// Non-null stand-in for a table that has not allocated yet. Never read: every
/// probe and every walk is guarded by the capacity.
const no_entries: [*]Entry = @constCast(@as([]const Entry, &.{}).ptr);

pub const Entry = struct {
    key: ?*HeapString = null,
    value: LoxValue = LoxValue.nil,
};

const ProbeMatch = union(enum) {
    pointer: *HeapString,
    bytes: struct { chars: []const u8, hash: u32 },
};

/// Open-addressed map from interned string to value.
///
/// Every instance and every class embeds one of these, so the struct is kept to
/// three words: the allocator is passed in by the caller (as `std.ArrayList`
/// does), the load limit is derived, and the capacity is the entry slice's own
/// length rather than a second copy of it.
pub const Table = struct {
    /// Occupied slots: live entries and tombstones alike. Deletion leaves the
    /// slot occupied so that the load limit accounts for tombstones too — a
    /// table that only counted live entries would stop growing while its
    /// tombstones ate the last empty slot, and every probe would then run
    /// forever, since an empty slot is what ends one.
    count: u32 = 0,
    /// Stored narrow to keep the struct at two words plus a pointer; read
    /// through `capacity()`, which widens it. A Lox program cannot reach four
    /// billion entries in one map before it runs out of address space.
    cap: u32 = 0,
    entries: [*]Entry = no_entries,

    pub inline fn capacity(self: *const Table) usize {
        return self.cap;
    }

    /// The live entries. Empty while the table has not allocated.
    pub inline fn slice(self: *const Table) []Entry {
        return self.entries[0..self.cap];
    }

    inline fn maxLoad(self: *const Table) u32 {
        return self.cap / 4 * 3;
    }

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        if (self.cap > 0) {
            gpa.free(self.slice());
        }
        self.* = .{};
    }

    pub inline fn get(self: *const Table, key: *HeapString) ?LoxValue {
        if (self.count == 0) return null;
        const entry = findSlot(self.entries, self.cap, .{ .pointer = key }, false) orelse return null;
        return entry.value;
    }

    pub inline fn set(self: *Table, gpa: std.mem.Allocator, key: *HeapString, value: LoxValue) !bool {
        if (self.count + 1 > self.maxLoad()) {
            try self.adjustCapacity(gpa, growCapacity(self.cap));
        }

        const entry = findSlot(self.entries, self.cap, .{ .pointer = key }, true).?;
        const is_new_key = entry.key == null;
        if (is_new_key and entry.value.isNil()) {
            self.count += 1;
        }

        entry.key = key;
        entry.value = value;
        return is_new_key;
    }

    pub inline fn setExisting(self: *Table, key: *HeapString, value: LoxValue) bool {
        const entry = findSlot(self.entries, self.cap, .{ .pointer = key }, false) orelse return false;
        entry.value = value;
        return true;
    }

    pub inline fn findString(self: *const Table, chars: []const u8, hash: u32) ?*HeapString {
        if (self.count == 0) return null;
        const entry = findSlot(
            self.entries,
            self.cap,
            .{ .bytes = .{ .chars = chars, .hash = hash } },
            false,
        ) orelse return null;
        return entry.key;
    }

    pub inline fn delete(self: *Table, key: *HeapString) bool {
        if (self.count == 0) return false;
        const entry = findSlot(self.entries, self.cap, .{ .pointer = key }, false) orelse return false;
        entry.key = null;
        entry.value = LoxValue.boolean(true);
        return true;
    }

    pub fn removeWhite(self: *Table) void {
        for (self.slice()) |*entry| {
            if (entry.key) |key| {
                if (!key.gc.marked) {
                    _ = self.delete(key);
                }
            }
        }
    }

    pub fn addAll(self: *Table, gpa: std.mem.Allocator, from: *const Table) !void {
        if (from.count == 0) return;

        const needed = self.count + from.count;
        while (needed > self.maxLoad()) {
            try self.adjustCapacity(gpa, growCapacity(self.cap));
        }

        for (from.slice()) |entry| {
            if (entry.key) |key| {
                _ = try self.set(gpa, key, entry.value);
            }
        }
    }

    inline fn adjustCapacity(self: *Table, gpa: std.mem.Allocator, new_capacity: u32) !void {
        const entries = try gpa.alloc(Entry, new_capacity);
        @memset(entries, .{});

        const old_entries = self.slice();
        self.count = 0;
        for (old_entries) |entry| {
            if (entry.key) |key| {
                const dest = findSlot(entries.ptr, new_capacity, .{ .pointer = key }, true).?;
                dest.key = key;
                dest.value = entry.value;
                self.count += 1;
            }
        }
        if (old_entries.len > 0) gpa.free(old_entries);

        self.entries = entries.ptr;
        self.cap = new_capacity;
    }

    inline fn growCapacity(current: u32) u32 {
        if (current < INITIAL_CAPACITY) return INITIAL_CAPACITY;
        return current * 2;
    }
};

// The probe index is word-sized even though the capacity is not: a 32-bit
// index would have to be zero-extended before every `entries[index]`, while a
// usize folds straight into the addressing mode.
inline fn hashIndex(hash: u32, mask: usize) usize {
    return hash & mask;
}

inline fn nextIndex(index: usize, mask: usize) usize {
    return (index + 1) & mask;
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
    entries: [*]Entry,
    capacity: u32,
    match: ProbeMatch,
    comptime for_insert: bool,
) ?*Entry {
    if (capacity == 0) return null;

    const hash = switch (match) {
        .pointer => |ptr| ptr.hash,
        .bytes => |b| b.hash,
    };

    const mask: usize = @as(usize, capacity) - 1;
    var index = hashIndex(hash, mask);
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

        index = nextIndex(index, mask);
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

    var table: Table = .{};
    defer table.deinit(std.testing.allocator);

    const is_new = try table.set(std.testing.allocator, &str, LoxValue.number(42));
    try std.testing.expect(is_new);

    const value = table.get(&str).?;
    try std.testing.expectEqual(@as(f64, 42), value.asNumber());

    const is_new_again = try table.set(std.testing.allocator, &str, LoxValue.number(7));
    try std.testing.expect(!is_new_again);
    try std.testing.expectEqual(@as(f64, 7), table.get(&str).?.asNumber());
}

test "table setExisting" {
    const bytes = "foo";
    var str = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(bytes), .data = bytes };

    var table: Table = .{};
    defer table.deinit(std.testing.allocator);

    try std.testing.expect(!table.setExisting(&str, LoxValue.number(1)));

    _ = try table.set(std.testing.allocator, &str, LoxValue.number(42));
    try std.testing.expect(table.setExisting(&str, LoxValue.number(7)));
    try std.testing.expectEqual(@as(f64, 7), table.get(&str).?.asNumber());
}

test "table findString" {
    const bytes = "hello";
    var str = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(bytes), .data = bytes };

    var table: Table = .{};
    defer table.deinit(std.testing.allocator);

    _ = try table.set(std.testing.allocator, &str, LoxValue.nil);

    try std.testing.expect(table.findString(bytes, str.hash) == &str);
    try std.testing.expect(table.findString("world", hashString("world")) == null);
}

test "table delete leaves tombstone" {
    const bytes = "hello";
    var str = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(bytes), .data = bytes };

    var table: Table = .{};
    defer table.deinit(std.testing.allocator);

    _ = try table.set(std.testing.allocator, &str, LoxValue.nil);
    try std.testing.expect(table.delete(&str));
    try std.testing.expect(table.get(&str) == null);
    // The tombstone still occupies its slot, so it still counts against the load.
    try std.testing.expectEqual(@as(usize, 1), table.count);
}

test "table removeWhite deletes unmarked strings" {
    const live_bytes = "live";
    const dead_bytes = "dead";
    var live = val.HeapString{ .gc = .{ .kind = .string, .marked = true }, .hash = hashString(live_bytes), .data = live_bytes };
    var dead = val.HeapString{ .gc = .{ .kind = .string, .marked = false }, .hash = hashString(dead_bytes), .data = dead_bytes };

    var table: Table = .{};
    defer table.deinit(std.testing.allocator);

    _ = try table.set(std.testing.allocator, &live, LoxValue.nil);
    _ = try table.set(std.testing.allocator, &dead, LoxValue.nil);

    table.removeWhite();

    try std.testing.expect(table.findString(live_bytes, live.hash) == &live);
    try std.testing.expect(table.findString(dead_bytes, dead.hash) == null);
    try std.testing.expectEqual(@as(usize, 2), table.count);
}

fn countEmptySlots(table: *const Table) usize {
    var empty: usize = 0;
    for (table.slice()) |entry| {
        if (entry.key == null and entry.value.isNil()) empty += 1;
    }
    return empty;
}

test "table keeps an empty slot through delete and reinsert cycles" {
    // Arrange
    const allocator = std.testing.allocator;
    var names: [32][8]u8 = undefined;
    var keys: [32]val.HeapString = undefined;
    for (&names, &keys, 0..) |*name, *key, i| {
        const bytes = try std.fmt.bufPrint(name, "k{d}", .{i});
        key.* = .{ .gc = .{ .kind = .string }, .hash = hashString(bytes), .data = bytes };
    }

    var table: Table = .{};
    defer table.deinit(allocator);
    for (keys[0..6]) |*key| {
        _ = try table.set(allocator, key, LoxValue.number(1));
    }
    // A collection sweeping every interned string leaves nothing but tombstones.
    for (keys[0..6]) |*key| {
        try std.testing.expect(table.delete(key));
    }

    // Act + Assert: refilling the table must never consume the last empty slot,
    // which is what ends a probe sequence that finds no match.
    for (keys[6..]) |*key| {
        try std.testing.expect(countEmptySlots(&table) > 0);
        _ = try table.set(allocator, key, LoxValue.number(1));
    }
    try std.testing.expect(countEmptySlots(&table) > 0);
    try std.testing.expect(table.findString("absent", hashString("absent")) == null);
}

test "table addAll copies entries" {
    const a_bytes = "a";
    const b_bytes = "b";
    var a = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(a_bytes), .data = a_bytes };
    var b = val.HeapString{ .gc = .{ .kind = .string }, .hash = hashString(b_bytes), .data = b_bytes };

    var from: Table = .{};
    defer from.deinit(std.testing.allocator);
    _ = try from.set(std.testing.allocator, &a, LoxValue.number(1));
    _ = try from.set(std.testing.allocator, &b, LoxValue.number(2));

    var to: Table = .{};
    defer to.deinit(std.testing.allocator);
    try to.addAll(std.testing.allocator, &from);

    try std.testing.expectEqual(@as(f64, 1), to.get(&a).?.asNumber());
    try std.testing.expectEqual(@as(f64, 2), to.get(&b).?.asNumber());
}
