//! JSON (de)serialisation of a `BalancedGroupSystem` so the familiarity
//! matrix and round history survive process restarts.
//!
//! On-disk format (version 1):
//!
//! ```json
//! {
//!   "version": 1,
//!   "members": ["Alice", "Bob", "Charlie"],
//!   "fam": [2, 0, 2],                       // flat lower-triangle, n*(n-1)/2
//!   "history": [[["Alice", "Bob"], ["Charlie"]]]
//! }
//! ```
//!
//! `fam` uses exactly the same layout as `BalancedGroupSystem.fam_matrix`:
//! pair (lo, hi) with lo < hi lives at `hi*(hi-1)/2 + lo`.
//!
//! A *store* (version 3) holds several independent named systems, each with
//! its own members, matrix, history and, optionally, the SHA-256 of the
//! passcode that lets its organiser edit it:
//!
//! ```json
//! {
//!   "version": 3,
//!   "systems": [
//!     { "id": "main", "name": "Main", "key_hash": null, "created": 0,
//!       "members": [...], "fam": [...], "history": [...] }
//!   ]
//! }
//! ```
//!
//! `storeFromJson` also accepts version 2 (no `key_hash`/`created`) and
//! version 1 (a single system at the top level, loaded with id
//! `legacy_system_id`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const bg = @import("balanced_group_system.zig");
const gs_mod = @import("group_system.zig");
const BalancedGroupSystem = bg.BalancedGroupSystem;

pub const format_version: u32 = 1;

/// Plain-data mirror of a `BalancedGroupSystem`, suitable for `std.json`.
pub const Snapshot = struct {
    version: u32 = format_version,
    members: []const []const u8,
    fam: []const u32,
    history: []const []const []const []const u8,
};

pub const LoadError = error{
    UnsupportedVersion,
    MatrixSizeMismatch,
    DuplicateMember,
    UnknownMemberInHistory,
} || Allocator.Error || std.json.ParseError(std.json.Scanner);

/// Serialise `bgs` to a JSON string. Caller owns the result.
pub fn toJson(gpa: Allocator, bgs: *const BalancedGroupSystem) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, snapshotForJson(bgs), .{});
}

// `std.ArrayList(Group)` is not a plain slice-of-slices, so build a view that
// `std.json` knows how to serialise. Pointers alias `bgs`.
const JsonHistory = struct {
    rounds: []const gs_mod.Round,

    pub fn jsonStringify(self: @This(), jws: *std.json.Stringify) !void {
        try jws.beginArray();
        for (self.rounds) |round| {
            try jws.beginArray();
            for (round.items) |group| {
                try jws.beginArray();
                for (group.items) |name| try jws.write(name);
                try jws.endArray();
            }
            try jws.endArray();
        }
        try jws.endArray();
    }
};

const JsonSnapshot = struct {
    version: u32,
    members: []const []const u8,
    fam: []const u32,
    history: JsonHistory,
};

fn snapshotForJson(bgs: *const BalancedGroupSystem) JsonSnapshot {
    return .{
        .version = format_version,
        .members = @ptrCast(bgs.base.members.items),
        .fam = bgs.fam_matrix.items,
        .history = .{ .rounds = bgs.base.group_history.items },
    };
}

/// Rebuild a `BalancedGroupSystem` from JSON produced by `toJson`.
/// The returned system owns all its memory; caller must `deinit`.
pub fn fromJson(gpa: Allocator, json: []const u8) LoadError!BalancedGroupSystem {
    var parsed = try std.json.parseFromSlice(Snapshot, gpa, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return fromSnapshot(gpa, parsed.value);
}

pub fn fromSnapshot(gpa: Allocator, snap: Snapshot) LoadError!BalancedGroupSystem {
    if (snap.version != format_version) return error.UnsupportedVersion;

    const n = snap.members.len;
    const expected_len = if (n >= 2) n * (n - 1) / 2 else 0;
    if (snap.fam.len != expected_len) return error.MatrixSizeMismatch;

    var bgs = BalancedGroupSystem.init(gpa);
    errdefer bgs.deinit();

    for (snap.members) |name| {
        if (bgs.name_to_idx.contains(name)) return error.DuplicateMember;
        try bgs.addMember(name);
    }
    @memcpy(bgs.fam_matrix.items, snap.fam);

    for (snap.history) |round_src| {
        var round: gs_mod.Round = .empty;
        errdefer gs_mod.freeRound(gpa, &round);
        for (round_src) |group_src| {
            var group: gs_mod.Group = .empty;
            errdefer gs_mod.freeGroup(gpa, &group);
            for (group_src) |name| {
                // History may legitimately reference members that were later
                // removed, so we only copy the string rather than validating.
                try group.append(gpa, try gpa.dupe(u8, name));
            }
            try round.append(gpa, group);
        }
        try bgs.base.recordRound(round);
    }

    return bgs;
}

// ── Multi-system store (version 2) ───────────────────────────────────────────

pub const store_version: u32 = 3;
pub const store_version_2: u32 = 2;
pub const legacy_system_id = "main";
pub const legacy_system_name = "Main";

/// One independent group system inside a store. Owns `id`, `name`,
/// `key_hash` and `bgs`.
pub const NamedSystem = struct {
    id: []u8,
    name: []u8,
    /// Lowercase hex SHA-256 of the organiser passcode; null when only the
    /// server-wide admin key may edit this system.
    key_hash: ?[]u8,
    /// Unix seconds when the system was created (0 when unknown).
    created: i64,
    bgs: BalancedGroupSystem,

    pub fn deinit(self: *NamedSystem, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        if (self.key_hash) |h| gpa.free(h);
        self.bgs.deinit();
    }

    /// Replace the passcode hash (null clears it). Takes a copy.
    pub fn setKeyHash(self: *NamedSystem, gpa: Allocator, hash: ?[]const u8) Allocator.Error!void {
        const copy: ?[]u8 = if (hash) |h| try gpa.dupe(u8, h) else null;
        if (self.key_hash) |old| gpa.free(old);
        self.key_hash = copy;
    }
};

pub const Store = std.ArrayList(NamedSystem);

pub fn deinitStore(gpa: Allocator, store: *Store) void {
    for (store.items) |*sys| sys.deinit(gpa);
    store.deinit(gpa);
}

pub const StoreLoadError = LoadError || error{ DuplicateSystemId, MissingField };

const SystemSnapshot = struct {
    id: []const u8,
    name: []const u8,
    key_hash: ?[]const u8 = null,
    created: i64 = 0,
    members: []const []const u8,
    fam: []const u32,
    history: []const []const []const []const u8,
};

/// Either file version; fields absent in the other version are null.
const AnySnapshot = struct {
    version: u32,
    systems: ?[]const SystemSnapshot = null,
    members: ?[]const []const u8 = null,
    fam: ?[]const u32 = null,
    history: ?[]const []const []const []const u8 = null,
};

/// Load a store from a version 1 or version 2 file. Caller owns the result
/// and frees it with `deinitStore`.
pub fn storeFromJson(gpa: Allocator, json: []const u8) StoreLoadError!Store {
    var parsed = try std.json.parseFromSlice(AnySnapshot, gpa, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const snap = parsed.value;

    var store: Store = .empty;
    errdefer deinitStore(gpa, &store);

    switch (snap.version) {
        format_version => {
            const bgs = try fromSnapshot(gpa, .{
                .members = snap.members orelse return error.MissingField,
                .fam = snap.fam orelse return error.MissingField,
                .history = snap.history orelse &.{},
            });
            try appendSystem(gpa, &store, legacy_system_id, legacy_system_name, null, 0, bgs);
        },
        store_version_2, store_version => {
            for (snap.systems orelse return error.MissingField) |s| {
                for (store.items) |existing| {
                    if (std.mem.eql(u8, existing.id, s.id)) return error.DuplicateSystemId;
                }
                const bgs = try fromSnapshot(gpa, .{ .members = s.members, .fam = s.fam, .history = s.history });
                try appendSystem(gpa, &store, s.id, s.name, s.key_hash, s.created, bgs);
            }
        },
        else => return error.UnsupportedVersion,
    }
    return store;
}

/// Append a system to `store`, taking ownership of `bgs` (freed on error).
pub fn appendSystem(gpa: Allocator, store: *Store, id: []const u8, name: []const u8, key_hash: ?[]const u8, created: i64, bgs: BalancedGroupSystem) Allocator.Error!void {
    var owned = bgs;
    errdefer owned.deinit();
    const id_copy = try gpa.dupe(u8, id);
    errdefer gpa.free(id_copy);
    const name_copy = try gpa.dupe(u8, name);
    errdefer gpa.free(name_copy);
    const hash_copy: ?[]u8 = if (key_hash) |h| try gpa.dupe(u8, h) else null;
    errdefer if (hash_copy) |h| gpa.free(h);
    try store.append(gpa, .{ .id = id_copy, .name = name_copy, .key_hash = hash_copy, .created = created, .bgs = owned });
}

const JsonSystem = struct {
    id: []const u8,
    name: []const u8,
    key_hash: ?[]const u8,
    created: i64,
    members: []const []const u8,
    fam: []const u32,
    history: JsonHistory,
};

/// Serialise a store as version 2 JSON. Caller owns the result.
pub fn storeToJson(gpa: Allocator, systems: []const NamedSystem) Allocator.Error![]u8 {
    const views = try gpa.alloc(JsonSystem, systems.len);
    defer gpa.free(views);
    for (systems, views) |*sys, *v| {
        v.* = .{
            .id = sys.id,
            .name = sys.name,
            .key_hash = sys.key_hash,
            .created = sys.created,
            .members = @ptrCast(sys.bgs.base.members.items),
            .fam = sys.bgs.fam_matrix.items,
            .history = .{ .rounds = sys.bgs.base.group_history.items },
        };
    }
    return std.json.Stringify.valueAlloc(gpa, .{ .version = store_version, .systems = views }, .{});
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "persist: round-trip preserves members, matrix and history" {
    const alloc = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(alloc);
    defer bgs.deinit();

    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "David", "Eve", "Frank" };
    for (names) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(7);
    for (0..4) |_| {
        var round = try bgs.createBalancedGroups(2, prng.random());
        gs_mod.freeRound(alloc, &round);
    }

    const json = try toJson(alloc, &bgs);
    defer alloc.free(json);

    var restored = try fromJson(alloc, json);
    defer restored.deinit();

    try std.testing.expectEqual(bgs.base.memberCount(), restored.base.memberCount());
    for (bgs.base.members.items, restored.base.members.items) |a, b| {
        try std.testing.expectEqualStrings(a, b);
    }
    try std.testing.expectEqualSlices(u32, bgs.fam_matrix.items, restored.fam_matrix.items);
    try std.testing.expectEqual(bgs.base.group_history.items.len, restored.base.group_history.items.len);
    for (bgs.base.group_history.items, restored.base.group_history.items) |ra, rb| {
        try std.testing.expectEqual(ra.items.len, rb.items.len);
        for (ra.items, rb.items) |ga, gb| {
            try std.testing.expectEqual(ga.items.len, gb.items.len);
            for (ga.items, gb.items) |na, nb| try std.testing.expectEqualStrings(na, nb);
        }
    }
    // name_to_idx must be rebuilt too
    try std.testing.expectEqual(@as(usize, 3), restored.name_to_idx.get("David").?);
}

test "persist: empty system round-trips" {
    const alloc = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(alloc);
    defer bgs.deinit();

    const json = try toJson(alloc, &bgs);
    defer alloc.free(json);
    var restored = try fromJson(alloc, json);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 0), restored.base.memberCount());
}

test "persist: rejects matrix of the wrong size" {
    const alloc = std.testing.allocator;
    const bad =
        \\{"version":1,"members":["A","B","C"],"fam":[1,2],"history":[]}
    ;
    try std.testing.expectError(error.MatrixSizeMismatch, fromJson(alloc, bad));
}

test "persist: rejects unsupported version" {
    const alloc = std.testing.allocator;
    const bad =
        \\{"version":99,"members":[],"fam":[],"history":[]}
    ;
    try std.testing.expectError(error.UnsupportedVersion, fromJson(alloc, bad));
}

test "persist: rejects duplicate member names" {
    const alloc = std.testing.allocator;
    const bad =
        \\{"version":1,"members":["A","A"],"fam":[0],"history":[]}
    ;
    try std.testing.expectError(error.DuplicateMember, fromJson(alloc, bad));
}

test "persist: version 1 file loads as a single legacy system" {
    const alloc = std.testing.allocator;
    const v1 =
        \\{"version":1,"members":["A","B"],"fam":[2],"history":[[["A","B"]]]}
    ;
    var store = try storeFromJson(alloc, v1);
    defer deinitStore(alloc, &store);
    try std.testing.expectEqual(@as(usize, 1), store.items.len);
    try std.testing.expectEqualStrings(legacy_system_id, store.items[0].id);
    try std.testing.expectEqual(@as(u32, 2), store.items[0].bgs.getFam(0, 1));
    try std.testing.expectEqual(@as(usize, 1), store.items[0].bgs.base.group_history.items.len);
}

test "persist: store round-trips several independent systems" {
    const alloc = std.testing.allocator;
    var store: Store = .empty;
    defer deinitStore(alloc, &store);

    try appendSystem(alloc, &store, "main", "Main", null, 0, BalancedGroupSystem.init(alloc));
    try appendSystem(alloc, &store, "chess-club", "Chess club", "ab" ** 32, 1_700_000_000, BalancedGroupSystem.init(alloc));
    for ([_][]const u8{ "Al", "Bo", "Cy" }) |n| try store.items[0].bgs.addMember(n);
    for ([_][]const u8{ "Xi", "Yu" }) |n| try store.items[1].bgs.addMember(n);
    try store.items[1].bgs.recordManualRound(&.{&.{ "Xi", "Yu" }});

    const json = try storeToJson(alloc, store.items);
    defer alloc.free(json);
    var restored = try storeFromJson(alloc, json);
    defer deinitStore(alloc, &restored);

    try std.testing.expectEqual(@as(usize, 2), restored.items.len);
    try std.testing.expectEqualStrings("Chess club", restored.items[1].name);
    try std.testing.expectEqual(@as(usize, 3), restored.items[0].bgs.base.memberCount());
    try std.testing.expectEqual(@as(usize, 0), restored.items[0].bgs.base.group_history.items.len);
    try std.testing.expectEqual(@as(u32, 2), restored.items[1].bgs.getFam(0, 1));
    try std.testing.expect(restored.items[0].key_hash == null);
    try std.testing.expectEqualStrings("ab" ** 32, restored.items[1].key_hash.?);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), restored.items[1].created);
}

test "persist: version 2 file loads with no passcodes" {
    const alloc = std.testing.allocator;
    const v2 =
        \\{"version":2,"systems":[{"id":"a","name":"A","members":["X"],"fam":[],"history":[]}]}
    ;
    var store = try storeFromJson(alloc, v2);
    defer deinitStore(alloc, &store);
    try std.testing.expectEqual(@as(usize, 1), store.items.len);
    try std.testing.expect(store.items[0].key_hash == null);
    try store.items[0].setKeyHash(alloc, "cd" ** 32);
    try std.testing.expectEqualStrings("cd" ** 32, store.items[0].key_hash.?);
    try store.items[0].setKeyHash(alloc, null);
    try std.testing.expect(store.items[0].key_hash == null);
}

test "persist: store rejects duplicate system ids" {
    const alloc = std.testing.allocator;
    const bad =
        \\{"version":2,"systems":[
        \\ {"id":"a","name":"A","members":[],"fam":[],"history":[]},
        \\ {"id":"a","name":"B","members":[],"fam":[],"history":[]}]}
    ;
    try std.testing.expectError(error.DuplicateSystemId, storeFromJson(alloc, bad));
}
