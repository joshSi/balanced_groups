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
