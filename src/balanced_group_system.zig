const std = @import("std");
const Allocator = std.mem.Allocator;
const gs_mod = @import("group_system.zig");
pub const GroupSystem = gs_mod.GroupSystem;
pub const Group = gs_mod.Group;
pub const Round = gs_mod.Round;

/// Tracks pairwise familiarity and creates balanced groups that minimize repeat meetings.
///
/// ## Familiarity matrix (flat lower-triangle)
///
/// Instead of Python's `dict[frozenset, int]` (O(n) hash per lookup) or the initial
/// nested `ArrayList(ArrayList(u32))` (two pointer chases per access), the matrix is
/// stored as a single flat `[]u32` in row-major lower-triangle order:
///
///   pair (lo, hi)  where lo < hi  →  matrix[ hi*(hi-1)/2 + lo ]
///
/// This is cache-friendly: all entries for member `hi` sit in one contiguous span.
/// Adding a member appends `n` zeros; removing compacts in O(n) time.
///
/// ## Greedy-assignment scoring
///
/// Python's `_calculate_balanced_groups` memoised intermediate group scores in a
/// `dict[frozenset[str], int]` — O(n) per frozenset hash, one allocation per group
/// state.  Here we maintain a plain `group_scores[group_count]` array of running
/// totals updated in O(1) per member assignment.  The algorithm is otherwise
/// identical: for each shuffled member find the group that minimises
///   `current_score + Σ familiarity(member, existing) + 2`
/// where +2 is a size penalty that keeps groups balanced when familiarity is zero.
pub const BalancedGroupSystem = struct {
    base: GroupSystem,
    /// Flat lower-triangle familiarity matrix, length = n*(n-1)/2.
    /// Entry for pair (lo, hi) (lo < hi) = fam_matrix[ hi*(hi-1)/2 + lo ].
    fam_matrix: std.ArrayList(u32),
    /// O(1) member-name → index lookup (indices match base.members order).
    name_to_idx: std.StringHashMap(usize),

    pub fn init(allocator: Allocator) BalancedGroupSystem {
        return .{
            .base = GroupSystem.init(allocator),
            .fam_matrix = .empty,
            .name_to_idx = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *BalancedGroupSystem) void {
        const alloc = self.base.allocator;
        self.fam_matrix.deinit(alloc);
        self.name_to_idx.deinit();
        self.base.deinit();
    }

    pub fn addMember(self: *BalancedGroupSystem, name: []const u8) !void {
        const alloc = self.base.allocator;
        const n = self.base.memberCount(); // current count before adding
        try self.base.addMember(name);
        // Append n zeros for the new member's row (pairs with all prior members)
        if (n > 0) try self.fam_matrix.appendNTimes(alloc, 0, n);
        // Map name → new index n (base.members now has n+1 entries)
        const owned_name = self.base.members.items[n]; // owned by base
        try self.name_to_idx.put(owned_name, n);
    }

    pub fn removeMember(self: *BalancedGroupSystem, name: []const u8) !void {
        const alloc = self.base.allocator;
        const k = self.name_to_idx.get(name) orelse return error.MemberNotFound;
        const n = self.base.memberCount(); // count before removal

        // Compact the lower-triangle array: remove row k and column k.
        // New size: (n-1)*(n-2)/2
        const new_len = if (n >= 2) (n - 1) * (n - 2) / 2 else 0;
        var new_mat = try std.ArrayList(u32).initCapacity(alloc, new_len);
        errdefer new_mat.deinit(alloc);

        for (0..n - 1) |new_j| {
            const old_j = if (new_j >= k) new_j + 1 else new_j;
            for (0..new_j) |new_i| {
                const old_i = if (new_i >= k) new_i + 1 else new_i;
                new_mat.appendAssumeCapacity(self.fam_matrix.items[old_j * (old_j - 1) / 2 + old_i]);
            }
        }
        self.fam_matrix.deinit(alloc);
        self.fam_matrix = new_mat;

        // Rebuild name_to_idx: all indices > k shift down by 1
        _ = self.name_to_idx.remove(name);
        try self.base.removeMember(name);
        for (self.base.members.items, 0..) |m, new_i| {
            // Indices that were > k have been decremented by orderedRemove
            if (new_i >= k) try self.name_to_idx.put(m, new_i);
        }
    }

    pub inline fn getFam(self: *const BalancedGroupSystem, i: usize, j: usize) u32 {
        if (i == j) return 0;
        const lo: usize = @min(i, j);
        const hi: usize = @max(i, j);
        return self.fam_matrix.items[hi * (hi - 1) / 2 + lo];
    }

    pub inline fn addFam(self: *BalancedGroupSystem, i: usize, j: usize, delta: u32) void {
        if (i == j) return;
        const lo: usize = @min(i, j);
        const hi: usize = @max(i, j);
        self.fam_matrix.items[hi * (hi - 1) / 2 + lo] += delta;
    }

    /// Reverse the most recent round: remove it from history and subtract the
    /// familiarity it added. Pairs involving members that have since been
    /// removed are skipped. Returns `error.NoRounds` if history is empty.
    pub fn undoLastRound(self: *BalancedGroupSystem) !void {
        const alloc = self.base.allocator;
        if (self.base.group_history.items.len == 0) return error.NoRounds;
        var round = self.base.group_history.pop().?;
        defer gs_mod.freeRound(alloc, &round);

        for (round.items) |group| {
            for (group.items, 0..) |name_i, a| {
                const i = self.name_to_idx.get(name_i) orelse continue;
                for (group.items[a + 1 ..]) |name_j| {
                    const j = self.name_to_idx.get(name_j) orelse continue;
                    if (i == j) continue;
                    const lo: usize = @min(i, j);
                    const hi: usize = @max(i, j);
                    const slot = &self.fam_matrix.items[hi * (hi - 1) / 2 + lo];
                    slot.* -|= 2;
                }
            }
        }
    }

    /// Record a round that was formed outside the solver (e.g. groups that met
    /// before this tool was adopted). Familiarity is updated exactly as if
    /// `createBalancedGroups` had produced it, and the round joins history so
    /// it can be undone. Every name must be a current member, no group may be
    /// empty, and no member may appear twice.
    pub fn recordManualRound(self: *BalancedGroupSystem, groups: []const []const []const u8) !void {
        const alloc = self.base.allocator;
        const n = self.base.memberCount();

        // Validate everything before touching any state.
        const seen = try alloc.alloc(bool, n);
        defer alloc.free(seen);
        @memset(seen, false);
        for (groups) |group| {
            if (group.len == 0) return error.EmptyGroup;
            for (group) |name| {
                const idx = self.name_to_idx.get(name) orelse return error.MemberNotFound;
                if (seen[idx]) return error.DuplicateMember;
                seen[idx] = true;
            }
        }

        var round: Round = .empty;
        errdefer gs_mod.freeRound(alloc, &round);
        for (groups) |group| {
            var named: Group = .empty;
            errdefer gs_mod.freeGroup(alloc, &named);
            for (group) |name| try named.append(alloc, try alloc.dupe(u8, name));
            try round.append(alloc, named);
        }
        try self.base.recordRound(round);

        // Only after history is committed (the one fallible step) do we touch
        // the matrix, so a failure above leaves familiarity untouched.
        for (groups) |group| {
            for (group, 0..) |name_i, a| {
                const i = self.name_to_idx.get(name_i).?;
                for (group[a + 1 ..]) |name_j| {
                    self.addFam(i, self.name_to_idx.get(name_j).?, 2);
                }
            }
        }
    }

    /// Sum familiarity over all ordered pairs (matches Python's evaluate_group).
    pub fn evaluateGroup(self: *const BalancedGroupSystem, indices: []const usize) u32 {
        var score: u32 = 0;
        for (indices) |i| {
            for (indices) |j| {
                if (i != j) score += self.getFam(i, j);
            }
        }
        return score;
    }

    pub fn printFamiliarity(self: *const BalancedGroupSystem) void {
        const members = self.base.members.items;
        for (members) |m| std.debug.print("{s} ", .{m});
        std.debug.print("\n", .{});
        for (members, 0..) |m, i| {
            std.debug.print("{s}:", .{m});
            for (members, 0..) |_, j| {
                if (i == j) std.debug.print(" -", .{}) else std.debug.print(" {d}", .{self.getFam(i, j)});
            }
            std.debug.print("\n", .{});
        }
    }

    /// Compute balanced groups, update familiarity, record in history.
    /// Returns a new Round (caller must free with `freeRound`).
    pub fn createBalancedGroups(
        self: *BalancedGroupSystem,
        group_count: usize,
        rand: std.Random,
    ) !Round {
        const alloc = self.base.allocator;
        const n = self.base.memberCount();
        if (group_count == 0 or n == 0) return Round.empty;

        // Shuffled member indices
        var indices = try alloc.alloc(usize, n);
        defer alloc.free(indices);
        for (0..n) |i| indices[i] = i;
        rand.shuffle(usize, indices);

        // Temporary index-based groups
        var idx_groups = try alloc.alloc(std.ArrayList(usize), group_count);
        defer {
            for (idx_groups) |*g| g.deinit(alloc);
            alloc.free(idx_groups);
        }
        for (idx_groups) |*g| g.* = .empty;

        // Running score per group — O(1) lookup, no HashMap needed
        var group_scores = try alloc.alloc(u32, group_count);
        defer alloc.free(group_scores);
        @memset(group_scores, 0);

        for (indices) |member| {
            var best_gi: usize = 0;
            var best_score: u32 = std.math.maxInt(u32);
            for (idx_groups, 0..) |group, gi| {
                var score = group_scores[gi];
                for (group.items) |existing| score += self.getFam(member, existing);
                score += 2; // size penalty: keeps groups balanced when fam == 0
                if (score < best_score) {
                    best_score = score;
                    best_gi = gi;
                }
            }
            try idx_groups[best_gi].append(alloc, member);
            group_scores[best_gi] = best_score;
        }

        // Update familiarity for every unique pair in each group
        for (idx_groups) |group| {
            for (group.items, 0..) |i, a| {
                for (group.items[a + 1 ..]) |j| {
                    self.addFam(i, j, 2); // +2: mirrors Python's double-ordered-pair increment
                }
            }
        }

        // Build the named Round to return
        var round: Round = .empty;
        errdefer gs_mod.freeRound(alloc, &round);
        for (idx_groups) |group| {
            var named: Group = .empty;
            errdefer gs_mod.freeGroup(alloc, &named);
            for (group.items) |idx| {
                try named.append(alloc, try alloc.dupe(u8, self.base.members.items[idx]));
            }
            try round.append(alloc, named);
        }

        // Clone into history
        var hist_round: Round = .empty;
        errdefer gs_mod.freeRound(alloc, &hist_round);
        for (round.items) |group| {
            var hist_group: Group = .empty;
            errdefer gs_mod.freeGroup(alloc, &hist_group);
            for (group.items) |name| {
                try hist_group.append(alloc, try alloc.dupe(u8, name));
            }
            try hist_round.append(alloc, hist_group);
        }
        try self.base.recordRound(hist_round);

        return round;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "BalancedGroupSystem init and add members" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    try bgs.addMember("Alice");
    try bgs.addMember("Bob");
    try bgs.addMember("Charlie");
    try bgs.addMember("David");
    try bgs.addMember("Eve");

    try std.testing.expectEqual(@as(usize, 5), bgs.base.memberCount());
    try std.testing.expectEqual(@as(u32, 0), bgs.getFam(0, 1));
    try std.testing.expectEqual(@as(u32, 0), bgs.getFam(2, 4));
    // flat matrix length: 5*4/2 = 10
    try std.testing.expectEqual(@as(usize, 10), bgs.fam_matrix.items.len);
}

test "BalancedGroupSystem name_to_idx O(1) lookup" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    try bgs.addMember("Alice");
    try bgs.addMember("Bob");
    try bgs.addMember("Charlie");

    try std.testing.expectEqual(@as(usize, 0), bgs.name_to_idx.get("Alice").?);
    try std.testing.expectEqual(@as(usize, 1), bgs.name_to_idx.get("Bob").?);
    try std.testing.expectEqual(@as(usize, 2), bgs.name_to_idx.get("Charlie").?);
}

test "BalancedGroupSystem familiarity after group" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    try bgs.addMember("Alice"); // 0
    try bgs.addMember("Bob"); // 1
    try bgs.addMember("Charlie"); // 2

    bgs.addFam(0, 1, 2);
    try std.testing.expectEqual(@as(u32, 2), bgs.getFam(0, 1));
    try std.testing.expectEqual(@as(u32, 2), bgs.getFam(1, 0)); // symmetric
    try std.testing.expectEqual(@as(u32, 0), bgs.getFam(0, 2));
}

test "BalancedGroupSystem removeMember updates matrix and index" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    try bgs.addMember("Alice"); // 0
    try bgs.addMember("Bob"); // 1
    try bgs.addMember("Charlie"); // 2
    bgs.addFam(0, 2, 4); // Alice-Charlie = 4

    try bgs.removeMember("Bob"); // removes index 1
    try std.testing.expectEqual(@as(usize, 2), bgs.base.memberCount());
    try std.testing.expect(bgs.name_to_idx.get("Bob") == null);
    try std.testing.expectEqual(@as(usize, 0), bgs.name_to_idx.get("Alice").?);
    try std.testing.expectEqual(@as(usize, 1), bgs.name_to_idx.get("Charlie").?);
    // Alice (now 0) – Charlie (now 1) familiarity should be preserved
    try std.testing.expectEqual(@as(u32, 4), bgs.getFam(0, 1));
}

test "BalancedGroupSystem createBalancedGroups" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "David", "Eve" };
    for (names) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    var round = try bgs.createBalancedGroups(2, rand);
    defer gs_mod.freeRound(allocator, &round);

    try std.testing.expectEqual(@as(usize, 2), round.items.len);
    var total: usize = 0;
    for (round.items) |group| {
        try std.testing.expect(group.items.len >= 2);
        total += group.items.len;
    }
    try std.testing.expectEqual(@as(usize, 5), total);
    try std.testing.expectEqual(@as(usize, 1), bgs.base.group_history.items.len);
}

test "BalancedGroupSystem familiarity accumulates across rounds" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "David", "Eve" };
    for (names) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();

    for (0..5) |_| {
        var round = try bgs.createBalancedGroups(2, rand);
        gs_mod.freeRound(allocator, &round);
    }

    var any_nonzero = false;
    const n = bgs.base.memberCount();
    for (0..n) |i| {
        for (i + 1..n) |j| {
            if (bgs.getFam(i, j) > 0) any_nonzero = true;
        }
    }
    try std.testing.expect(any_nonzero);
}

test "BalancedGroupSystem undoLastRound restores familiarity" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "David", "Eve", "Frank" };
    for (names) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(3);
    var r1 = try bgs.createBalancedGroups(2, prng.random());
    gs_mod.freeRound(allocator, &r1);

    const before = try allocator.dupe(u32, bgs.fam_matrix.items);
    defer allocator.free(before);

    var r2 = try bgs.createBalancedGroups(2, prng.random());
    gs_mod.freeRound(allocator, &r2);
    try std.testing.expectEqual(@as(usize, 2), bgs.base.group_history.items.len);

    try bgs.undoLastRound();
    try std.testing.expectEqual(@as(usize, 1), bgs.base.group_history.items.len);
    try std.testing.expectEqualSlices(u32, before, bgs.fam_matrix.items);

    try bgs.undoLastRound();
    try std.testing.expectError(error.NoRounds, bgs.undoLastRound());
    for (bgs.fam_matrix.items) |v| try std.testing.expectEqual(@as(u32, 0), v);
}

test "BalancedGroupSystem undoLastRound tolerates removed members" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "David" };
    for (names) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(5);
    var r1 = try bgs.createBalancedGroups(2, prng.random());
    gs_mod.freeRound(allocator, &r1);

    try bgs.removeMember("Bob");
    try bgs.undoLastRound(); // must not crash or underflow
    for (bgs.fam_matrix.items) |v| try std.testing.expectEqual(@as(u32, 0), v);
}

test "BalancedGroupSystem recordManualRound updates familiarity and history" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "David", "Eve" };
    for (names) |n| try bgs.addMember(n);

    const g1 = [_][]const u8{ "Alice", "Bob", "Charlie" };
    const g2 = [_][]const u8{"David"}; // Eve absent this round
    const groups = [_][]const []const u8{ &g1, &g2 };
    try bgs.recordManualRound(&groups);

    try std.testing.expectEqual(@as(usize, 1), bgs.base.group_history.items.len);
    try std.testing.expectEqual(@as(u32, 2), bgs.getFam(0, 1));
    try std.testing.expectEqual(@as(u32, 2), bgs.getFam(0, 2));
    try std.testing.expectEqual(@as(u32, 2), bgs.getFam(1, 2));
    try std.testing.expectEqual(@as(u32, 0), bgs.getFam(0, 3));
    try std.testing.expectEqual(@as(u32, 0), bgs.getFam(3, 4));

    // Undo reverses it completely
    try bgs.undoLastRound();
    for (bgs.fam_matrix.items) |v| try std.testing.expectEqual(@as(u32, 0), v);
    try std.testing.expectEqual(@as(usize, 0), bgs.base.group_history.items.len);
}

test "BalancedGroupSystem recordManualRound rejects bad input without mutating" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();
    try bgs.addMember("Alice");
    try bgs.addMember("Bob");

    const unknown = [_][]const u8{ "Alice", "Zed" };
    const dup_a = [_][]const u8{"Alice"};
    const dup_b = [_][]const u8{ "Bob", "Alice" };
    const empty = [_][]const u8{};

    try std.testing.expectError(error.MemberNotFound, bgs.recordManualRound(&[_][]const []const u8{&unknown}));
    try std.testing.expectError(error.DuplicateMember, bgs.recordManualRound(&[_][]const []const u8{ &dup_a, &dup_b }));
    try std.testing.expectError(error.EmptyGroup, bgs.recordManualRound(&[_][]const []const u8{ &dup_a, &empty }));

    try std.testing.expectEqual(@as(usize, 0), bgs.base.group_history.items.len);
    try std.testing.expectEqual(@as(u32, 0), bgs.getFam(0, 1));
}
