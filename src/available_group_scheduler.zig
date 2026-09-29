const std = @import("std");
const Allocator = std.mem.Allocator;
const gs_mod = @import("group_system.zig");
pub const GroupSystem = gs_mod.GroupSystem;
pub const Group = gs_mod.Group;
pub const Round = gs_mod.Round;

/// Creates groups for multiple availability windows in one pass, maximising
/// new interactions by tracking both participation counts and pairwise familiarity.
///
/// Uses the same flat lower-triangle matrix optimisation as BalancedGroupSystem.
pub const AvailableGroupScheduler = struct {
    base: GroupSystem,
    /// Flat lower-triangle familiarity matrix, length = n*(n-1)/2.
    fam_matrix: std.ArrayList(u32),
    /// Participation count per member (index-aligned with base.members).
    participation: std.ArrayList(u32),
    /// availability[window][member_index]: true if member is available.
    schedules: std.ArrayList(std.ArrayList(bool)),

    pub fn init(allocator: Allocator) AvailableGroupScheduler {
        return .{
            .base = GroupSystem.init(allocator),
            .fam_matrix = .empty,
            .participation = .empty,
            .schedules = .empty,
        };
    }

    pub fn deinit(self: *AvailableGroupScheduler) void {
        const alloc = self.base.allocator;
        self.fam_matrix.deinit(alloc);
        self.participation.deinit(alloc);
        for (self.schedules.items) |*s| s.deinit(alloc);
        self.schedules.deinit(alloc);
        self.base.deinit();
    }

    pub fn addMember(self: *AvailableGroupScheduler, name: []const u8) !void {
        const alloc = self.base.allocator;
        const n = self.base.memberCount();
        try self.base.addMember(name);
        if (n > 0) try self.fam_matrix.appendNTimes(alloc, 0, n);
        try self.participation.append(alloc, 0);
    }

    pub fn addSchedule(self: *AvailableGroupScheduler, availability: []const bool) !void {
        const alloc = self.base.allocator;
        var sched: std.ArrayList(bool) = .empty;
        errdefer sched.deinit(alloc);
        try sched.appendSlice(alloc, availability);
        try self.schedules.append(alloc, sched);
    }

    inline fn getFam(self: *const AvailableGroupScheduler, i: usize, j: usize) u32 {
        if (i == j) return 0;
        const lo: usize = @min(i, j);
        const hi: usize = @max(i, j);
        return self.fam_matrix.items[hi * (hi - 1) / 2 + lo];
    }

    inline fn addFam(self: *AvailableGroupScheduler, i: usize, j: usize, delta: u32) void {
        if (i == j) return;
        const lo: usize = @min(i, j);
        const hi: usize = @max(i, j);
        self.fam_matrix.items[hi * (hi - 1) / 2 + lo] += delta;
    }

    fn updateParticipation(self: *AvailableGroupScheduler, group: []const usize) void {
        for (group) |i| {
            self.participation.items[i] += 1;
            for (group) |j| {
                if (i != j) self.addFam(i, j, 1);
            }
        }
    }

    /// Pick `group_size` members from `candidates`, starting from `existing`,
    /// greedily minimising accumulated familiarity. Uses a running-score array.
    fn pickBalancedGroup(
        self: *AvailableGroupScheduler,
        candidates: []const usize,
        existing: []const usize,
        group_size: usize,
        alloc: Allocator,
    ) ![]usize {
        var group = try std.ArrayList(usize).initCapacity(alloc, group_size);
        errdefer group.deinit(alloc);
        try group.appendSlice(alloc, existing);

        var avail = try alloc.alloc(bool, candidates.len);
        defer alloc.free(avail);
        @memset(avail, true);

        var running_score: u32 = 0;

        while (group.items.len < group_size) {
            var best_ci: usize = 0;
            var best_score: u32 = std.math.maxInt(u32);
            for (candidates, 0..) |c, ci| {
                if (!avail[ci]) continue;
                var score = running_score;
                for (group.items) |m| score += self.getFam(c, m);
                score += 1;
                if (score < best_score) {
                    best_score = score;
                    best_ci = ci;
                }
            }
            avail[best_ci] = false;
            try group.append(alloc, candidates[best_ci]);
            running_score = best_score;
        }

        return group.toOwnedSlice(alloc);
    }

    /// Run a scheduling pass over all windows. Resets familiarity and participation
    /// before starting so each call produces a fresh independent schedule.
    /// Returns a slice of index-groups (one per window); caller frees with `freeSchedule`.
    pub fn createBalancedSchedules(
        self: *AvailableGroupScheduler,
        group_size: usize,
    ) ![][]usize {
        const alloc = self.base.allocator;
        const n = self.base.memberCount();

        @memset(self.participation.items, 0);
        @memset(self.fam_matrix.items, 0);

        var result: std.ArrayList([]usize) = .empty;
        errdefer {
            for (result.items) |g| alloc.free(g);
            result.deinit(alloc);
        }

        for (self.schedules.items) |sched| {
            var candidates: std.ArrayList(usize) = .empty;
            defer candidates.deinit(alloc);
            const limit = @min(sched.items.len, n);
            for (0..limit) |i| {
                if (sched.items[i]) try candidates.append(alloc, i);
            }

            if (candidates.items.len <= group_size) {
                const group = try alloc.dupe(usize, candidates.items);
                self.updateParticipation(group);
                try result.append(alloc, group);
                continue;
            }

            // Find minimum participation among candidates
            var min_part: u32 = std.math.maxInt(u32);
            for (candidates.items) |c| min_part = @min(min_part, self.participation.items[c]);

            // Split: those at min_part vs those above
            var min_cands: std.ArrayList(usize) = .empty;
            defer min_cands.deinit(alloc);
            var extra_cands: std.ArrayList(usize) = .empty;
            defer extra_cands.deinit(alloc);
            for (candidates.items) |c| {
                if (self.participation.items[c] == min_part) {
                    try min_cands.append(alloc, c);
                } else {
                    try extra_cands.append(alloc, c);
                }
            }

            if (min_cands.items.len >= group_size) {
                const group = try self.pickBalancedGroup(min_cands.items, &.{}, group_size, alloc);
                self.updateParticipation(group);
                try result.append(alloc, group);
            } else {
                // Fill from extra_cands sorted by participation ascending
                std.mem.sort(usize, extra_cands.items, self.participation.items, struct {
                    fn lt(part: []const u32, a: usize, b: usize) bool {
                        return part[a] < part[b];
                    }
                }.lt);

                const still_needed = group_size - min_cands.items.len;
                const top_extra = extra_cands.items[0..@min(extra_cands.items.len, still_needed)];

                const group = try self.pickBalancedGroup(
                    top_extra,
                    min_cands.items,
                    group_size,
                    alloc,
                );
                self.updateParticipation(group);
                try result.append(alloc, group);
            }
        }

        return result.toOwnedSlice(alloc);
    }

    pub fn freeSchedule(self: *const AvailableGroupScheduler, schedule: [][]usize) void {
        for (schedule) |g| self.base.allocator.free(g);
        self.base.allocator.free(schedule);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "AvailableGroupScheduler basic scheduling" {
    const allocator = std.testing.allocator;
    var sched = AvailableGroupScheduler.init(allocator);
    defer sched.deinit();

    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "David", "Eve" };
    for (names) |n| try sched.addMember(n);

    try sched.addSchedule(&[_]bool{ true, true, true, true, true });
    try sched.addSchedule(&[_]bool{ true, true, true, true, false });

    const groups = try sched.createBalancedSchedules(3);
    defer sched.freeSchedule(groups);

    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqual(@as(usize, 3), groups[0].len);
}

test "AvailableGroupScheduler falls back to all candidates when below group_size" {
    const allocator = std.testing.allocator;
    var sched = AvailableGroupScheduler.init(allocator);
    defer sched.deinit();

    const names = [_][]const u8{ "Alice", "Bob" };
    for (names) |n| try sched.addMember(n);

    // Only 2 available, group_size = 3 → take both
    try sched.addSchedule(&[_]bool{ true, true });

    const groups = try sched.createBalancedSchedules(3);
    defer sched.freeSchedule(groups);

    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 2), groups[0].len);
}
