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
        return self.recordManual(groups, false);
    }

    /// `recordManualRound` for group-id mode, where groups are positional: an
    /// id nobody used that round is an empty group. The round may not be empty.
    pub fn recordManualSlottedRound(self: *BalancedGroupSystem, groups: []const []const []const u8) !void {
        return self.recordManual(groups, true);
    }

    fn recordManual(self: *BalancedGroupSystem, groups: []const []const []const u8, allow_empty: bool) !void {
        const alloc = self.base.allocator;
        const n = self.base.memberCount();

        // Validate everything before touching any state.
        const seen = try alloc.alloc(bool, n);
        defer alloc.free(seen);
        @memset(seen, false);
        var total: usize = 0;
        for (groups) |group| {
            total += group.len;
            if (group.len == 0 and !allow_empty) return error.EmptyGroup;
            for (group) |name| {
                const idx = self.name_to_idx.get(name) orelse return error.MemberNotFound;
                if (seen[idx]) return error.DuplicateMember;
                seen[idx] = true;
            }
        }
        if (total == 0) return error.EmptyGroup;

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

    /// How many past rounds each member spent in each group id (row-major,
    /// `counts[member * group_count + gi]`), and what one more visit costs.
    /// One repeat visit costs `weight`; one repeat meeting costs 2.
    const SlotCost = struct {
        counts: []const u32,
        group_count: usize,
        weight: u32,

        inline fn at(self: SlotCost, member: usize, gi: usize) u32 {
            return self.weight * self.counts[member * self.group_count + gi];
        }
    };

    /// Count, from history, how often each current member sat in group ids
    /// 0..group_count. Rounds with fewer groups count for the ids they had;
    /// extra ids in rounds with more groups are ignored. Caller frees.
    pub fn slotCounts(self: *const BalancedGroupSystem, alloc: Allocator, group_count: usize) ![]u32 {
        const counts = try alloc.alloc(u32, self.base.memberCount() * group_count);
        @memset(counts, 0);
        for (self.base.group_history.items) |round| {
            for (round.items[0..@min(round.items.len, group_count)], 0..) |group, gi| {
                for (group.items) |name| {
                    const m = self.name_to_idx.get(name) orelse continue;
                    counts[m * group_count + gi] += 1;
                }
            }
        }
        return counts;
    }

    /// Place members one by one into the group where they add the least familiarity
    /// (plus, when `slots` is given, the least repeat time in that group id).
    fn greedyFill(self: *const BalancedGroupSystem, alloc: Allocator, groups: []std.ArrayList(usize), order: []const usize, slots: ?SlotCost) !void {
        // Sizes are fixed up front (the first n % g groups get one extra) so that
        // avoiding repeat meetings can never leave a group of 3 beside a group of 1.
        const base_size = order.len / groups.len;
        const extra = order.len % groups.len;
        for (order) |member| {
            var best_gi: usize = 0;
            var best_score: u32 = std.math.maxInt(u32);
            for (groups, 0..) |group, gi| {
                if (group.items.len >= base_size + @intFromBool(gi < extra)) continue;
                var score: u32 = if (slots) |sc| sc.at(member, gi) else 0;
                for (group.items) |existing| score += self.getFam(member, existing);
                if (score < best_score) {
                    best_score = score;
                    best_gi = gi;
                }
            }
            try groups[best_gi].append(alloc, member);
        }
    }

    /// Hill-climb: swap two members of different groups whenever that lowers the
    /// total within-group familiarity (plus slot cost, if given). Group sizes
    /// never change. Returns the cost.
    fn improveBySwaps(self: *const BalancedGroupSystem, groups: []std.ArrayList(usize), slots: ?SlotCost) u32 {
        var improved = true;
        while (improved) {
            improved = false;
            for (groups, 0..) |*ga, gi| {
                for (groups[gi + 1 ..], gi + 1..) |*gb, gj| {
                    for (ga.items, 0..) |a, ai| {
                        for (gb.items, 0..) |b, bi| {
                            var now: u32 = 0;
                            var swapped: u32 = 0;
                            if (slots) |sc| {
                                now += sc.at(a, gi) + sc.at(b, gj);
                                swapped += sc.at(b, gi) + sc.at(a, gj);
                            }
                            for (ga.items) |x| {
                                if (x == a) continue;
                                now += self.getFam(a, x);
                                swapped += self.getFam(b, x);
                            }
                            for (gb.items) |y| {
                                if (y == b) continue;
                                now += self.getFam(b, y);
                                swapped += self.getFam(a, y);
                            }
                            if (swapped < now) {
                                ga.items[ai] = b;
                                gb.items[bi] = a;
                                improved = true;
                                break;
                            }
                        }
                    }
                }
            }
        }
        var cost: u32 = 0;
        for (groups, 0..) |g, gi| {
            for (g.items, 0..) |i, a| {
                if (slots) |sc| cost += sc.at(i, gi);
                for (g.items[a + 1 ..]) |j| cost += self.getFam(i, j);
            }
        }
        return cost;
    }

    /// Renumber the groups (who is together stays fixed) so the total slot cost
    /// is minimal: an assignment problem between groups and group ids, solved
    /// exactly with the Hungarian method in O(g³). A group may only take an id
    /// of the same size, keeping the "first n % g groups are larger" rule.
    fn relabelGroups(alloc: Allocator, groups: []std.ArrayList(usize), sc: SlotCost) !void {
        const g = groups.len;
        if (g < 2) return;
        const forbidden: i64 = 1 << 40;
        // cost[r][c]: group r placed at id c. 1-based arrays for the classic form.
        const cost = try alloc.alloc(i64, g * g);
        defer alloc.free(cost);
        for (groups, 0..) |grp, r| {
            for (0..g) |c| {
                if (grp.items.len != groups[c].items.len) {
                    cost[r * g + c] = forbidden;
                    continue;
                }
                var sum: i64 = 0;
                for (grp.items) |m| sum += sc.at(m, c);
                cost[r * g + c] = sum;
            }
        }

        const u = try alloc.alloc(i64, g + 1);
        defer alloc.free(u);
        const v = try alloc.alloc(i64, g + 1);
        defer alloc.free(v);
        const p = try alloc.alloc(usize, g + 1); // p[c] = row assigned to column c
        defer alloc.free(p);
        const way = try alloc.alloc(usize, g + 1);
        defer alloc.free(way);
        const minv = try alloc.alloc(i64, g + 1);
        defer alloc.free(minv);
        const used = try alloc.alloc(bool, g + 1);
        defer alloc.free(used);
        @memset(u, 0);
        @memset(v, 0);
        @memset(p, 0);

        for (1..g + 1) |row| {
            p[0] = row;
            var c0: usize = 0;
            @memset(minv, std.math.maxInt(i64));
            @memset(used, false);
            while (true) {
                used[c0] = true;
                const r0 = p[c0];
                var delta: i64 = std.math.maxInt(i64);
                var c1: usize = 0;
                for (1..g + 1) |c| {
                    if (used[c]) continue;
                    const cur = cost[(r0 - 1) * g + (c - 1)] - u[r0] - v[c];
                    if (cur < minv[c]) {
                        minv[c] = cur;
                        way[c] = c0;
                    }
                    if (minv[c] < delta) {
                        delta = minv[c];
                        c1 = c;
                    }
                }
                for (0..g + 1) |c| {
                    if (used[c]) {
                        u[p[c]] += delta;
                        v[c] -= delta;
                    } else minv[c] -= delta;
                }
                c0 = c1;
                if (p[c0] == 0) break;
            }
            while (c0 != 0) {
                const c1 = way[c0];
                p[c0] = p[c1];
                c0 = c1;
            }
        }

        const old = try alloc.dupe(std.ArrayList(usize), groups);
        defer alloc.free(old);
        for (1..g + 1) |c| groups[c - 1] = old[p[c] - 1];
    }

    /// Round-robin for pairs. When the pairs that have never met form a regular
    /// graph, pick a perfect matching of it whose leftovers can still be split
    /// into perfect matchings, so everyone has met everyone after n-1 rounds.
    /// Plain "fewest repeats" choices can dead-end (e.g. 8 people ending with
    /// two people who never meet), so this looks ahead with a bounded search.
    /// Returns false when it does not apply or finds nothing in budget; the
    /// caller then falls back to the heuristic. With `slots`, several valid
    /// matchings are tried and the one that numbers best is kept.
    fn roundRobinPairs(self: *const BalancedGroupSystem, alloc: Allocator, groups: []std.ArrayList(usize), rand: std.Random, slots: ?SlotCost) !bool {
        const n = self.base.memberCount();
        if (n < 2 or n > 64 or n % 2 != 0 or groups.len != n / 2) return false;
        var adj: [64]u64 = @splat(0);
        for (0..n) |j| for (0..j) |i| {
            if (self.getFam(i, j) == 0) {
                adj[i] |= @as(u64, 1) << @intCast(j);
                adj[j] |= @as(u64, 1) << @intCast(i);
            }
        };
        const d = @popCount(adj[0]);
        if (d == 0) return false;
        for (adj[0..n]) |row| if (@popCount(row) != d) return false;

        const all: u64 = if (n == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
        for (groups) |*g| try g.ensureTotalCapacity(alloc, 2);
        var partner: [64]u8 = undefined;
        var budget: usize = 200_000;
        if (!matchAndExtend(adj, all, all, &partner, rand, &budget)) return false;
        pairsFromPartners(groups, partner[0..n]);
        const sc = slots orelse return true;

        try relabelGroups(alloc, groups, sc);
        var best_cost = slotCostOf(groups, sc);
        var best: [32][2]usize = undefined;
        for (groups, 0..) |g, gi| best[gi] = g.items[0..2].*;
        for (0..32) |_| {
            if (best_cost == 0) break;
            budget = 200_000;
            if (!matchAndExtend(adj, all, all, &partner, rand, &budget)) break;
            pairsFromPartners(groups, partner[0..n]);
            try relabelGroups(alloc, groups, sc);
            const cost = slotCostOf(groups, sc);
            if (cost < best_cost) {
                best_cost = cost;
                for (groups, 0..) |g, gi| best[gi] = g.items[0..2].*;
            }
        }
        for (groups, 0..) |*g, gi| @memcpy(g.items, &best[gi]);
        return true;
    }

    /// Fill `groups` (capacity ≥ 2 each) with the pairs in `partner`.
    fn pairsFromPartners(groups: []std.ArrayList(usize), partner: []const u8) void {
        var gi: usize = 0;
        for (partner, 0..) |u, v| {
            if (u > v) {
                groups[gi].items.len = 2;
                groups[gi].items[0] = v;
                groups[gi].items[1] = u;
                gi += 1;
            }
        }
    }

    fn slotCostOf(groups: []const std.ArrayList(usize), sc: SlotCost) u32 {
        var cost: u32 = 0;
        for (groups, 0..) |g, gi| for (g.items) |m| {
            cost += sc.at(m, gi);
        };
        return cost;
    }

    /// Pair up every vertex in `unmatched` along edges of `adj`, then require the
    /// edges left over to be fully splittable the same way. `full` is every vertex.
    fn matchAndExtend(adj: [64]u64, full: u64, unmatched: u64, partner: *[64]u8, rand: std.Random, budget: *usize) bool {
        if (unmatched == 0) {
            var rest = adj;
            var any = false;
            var m = full;
            while (m != 0) : (m &= m - 1) {
                const v: usize = @ctz(m);
                rest[v] &= ~(@as(u64, 1) << @intCast(partner[v]));
                if (rest[v] != 0) any = true;
            }
            if (!any) return true;
            var inner: [64]u8 = undefined;
            return matchAndExtend(rest, full, full, &inner, rand, budget);
        }
        if (budget.* == 0) return false;
        budget.* -= 1;
        const v: usize = @ctz(unmatched);
        var cand: [64]u8 = undefined;
        var nc: usize = 0;
        var c = adj[v] & unmatched;
        while (c != 0) : (c &= c - 1) {
            cand[nc] = @intCast(@ctz(c));
            nc += 1;
        }
        rand.shuffle(u8, cand[0..nc]);
        for (cand[0..nc]) |u| {
            partner[v] = u;
            partner[u] = @intCast(v);
            const next = unmatched & ~(@as(u64, 1) << @intCast(v)) & ~(@as(u64, 1) << @intCast(u));
            if (matchAndExtend(adj, full, next, partner, rand, budget)) return true;
        }
        return false;
    }

    /// Compute balanced groups, update familiarity, record in history.
    /// Returns a new Round (caller must free with `freeRound`).
    pub fn createBalancedGroups(
        self: *BalancedGroupSystem,
        group_count: usize,
        rand: std.Random,
    ) !Round {
        return self.createGroups(group_count, rand, null);
    }

    /// Like `createBalancedGroups`, but group ids matter (group 0 is "table 1"
    /// every round) and members should rotate through them. Minimises
    ///
    ///   Σ familiarity within groups  +  slot_weight · Σ past visits to own id
    ///
    /// where one repeat meeting adds 2, so `slot_weight = 1` makes a repeat
    /// meeting count twice as much as one person returning to a table, and a
    /// large weight makes rotation dominate. History is the source of truth for
    /// visits, so undo, manual rounds and member removal need no extra state.
    /// A sensible `slot_weight`: rotation wins over a repeat meeting, but only
    /// just (with 12 people at 3 tables, nobody revisits a table in 3 rounds).
    pub const default_slot_weight: u32 = 3;

    pub fn createSlottedGroups(
        self: *BalancedGroupSystem,
        group_count: usize,
        rand: std.Random,
        slot_weight: u32,
    ) !Round {
        return self.createGroups(group_count, rand, slot_weight);
    }

    fn createGroups(
        self: *BalancedGroupSystem,
        group_count: usize,
        rand: std.Random,
        slot_weight: ?u32,
    ) !Round {
        const alloc = self.base.allocator;
        const n = self.base.memberCount();
        if (group_count == 0 or n == 0) return Round.empty;

        const counts: []u32 = if (slot_weight != null) try self.slotCounts(alloc, group_count) else &.{};
        defer if (slot_weight != null) alloc.free(counts);
        const slots: ?SlotCost = if (slot_weight) |w| .{ .counts = counts, .group_count = group_count, .weight = w } else null;

        const idx_groups = try alloc.alloc(std.ArrayList(usize), group_count);
        defer {
            for (idx_groups) |*g| g.deinit(alloc);
            alloc.free(idx_groups);
        }
        for (idx_groups) |*g| g.* = .empty;

        // Candidate arrangement under construction; the best one found goes in idx_groups.
        const trial = try alloc.alloc(std.ArrayList(usize), group_count);
        defer {
            for (trial) |*g| g.deinit(alloc);
            alloc.free(trial);
        }
        for (trial) |*g| g.* = .empty;

        var indices = try alloc.alloc(usize, n);
        defer alloc.free(indices);

        // Greedy placement alone can paint itself into a corner (e.g. 8 people in
        // pairs never finishing the round-robin), so improve each attempt by
        // swapping members between groups and keep the best of a few restarts.
        const pairs_done = try self.roundRobinPairs(alloc, idx_groups, rand, slots);
        const restarts: usize = if (pairs_done) 0 else if (n <= 64) 24 else 4;
        var best_cost: u32 = std.math.maxInt(u32);
        for (0..restarts) |_| {
            for (0..n) |i| indices[i] = i;
            rand.shuffle(usize, indices);
            for (trial) |*g| g.clearRetainingCapacity();
            try self.greedyFill(alloc, trial, indices, slots);
            var cost = self.improveBySwaps(trial, slots);
            // Swaps only move one pair at a time; renumbering whole groups can
            // still lower slot cost, and may open up new improving swaps.
            if (slots) |sc| while (true) {
                try relabelGroups(alloc, trial, sc);
                const after = self.improveBySwaps(trial, slots);
                if (after >= cost) break;
                cost = after;
            };
            if (cost < best_cost) {
                best_cost = cost;
                for (trial, idx_groups) |t, *dst| {
                    dst.clearRetainingCapacity();
                    try dst.appendSlice(alloc, t.items);
                }
            }
            if (best_cost == 0) break;
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

test "BalancedGroupSystem relabelGroups finds the cheapest numbering" {
    const allocator = std.testing.allocator;
    // 3 members, 3 single-member groups. Member m has sat at id m twice.
    const counts = [_]u32{ 2, 0, 0, 0, 2, 0, 0, 0, 2 };
    const sc: BalancedGroupSystem.SlotCost = .{ .counts = &counts, .group_count = 3, .weight = 1 };
    var groups: [3]std.ArrayList(usize) = .{ .empty, .empty, .empty };
    defer for (&groups) |*g| g.deinit(allocator);
    for (&groups, 0..) |*g, i| try g.append(allocator, i);

    try BalancedGroupSystem.relabelGroups(allocator, &groups, sc);
    for (groups, 0..) |g, gi| try std.testing.expect(g.items[0] != gi);
}

test "BalancedGroupSystem relabelGroups keeps larger groups at the low ids" {
    const allocator = std.testing.allocator;
    // Members 0,1 (a pair) have always been at id 0; member 2 never.
    const counts = [_]u32{ 5, 0, 5, 0, 0, 0 };
    const sc: BalancedGroupSystem.SlotCost = .{ .counts = &counts, .group_count = 2, .weight = 1 };
    var groups: [2]std.ArrayList(usize) = .{ .empty, .empty };
    defer for (&groups) |*g| g.deinit(allocator);
    try groups[0].appendSlice(allocator, &.{ 0, 1 });
    try groups[1].append(allocator, 2);

    try BalancedGroupSystem.relabelGroups(allocator, &groups, sc);
    try std.testing.expectEqual(@as(usize, 2), groups[0].items.len);
}

test "BalancedGroupSystem createSlottedGroups rotates everyone through every id" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();
    for (0..12) |i| {
        var buf: [8]u8 = undefined;
        try bgs.addMember(try std.fmt.bufPrint(&buf, "m{d}", .{i}));
    }

    var prng = std.Random.DefaultPrng.init(7);
    for (0..3) |_| {
        var round = try bgs.createSlottedGroups(3, prng.random(), 100);
        gs_mod.freeRound(allocator, &round);
    }
    const counts = try bgs.slotCounts(allocator, 3);
    defer allocator.free(counts);
    for (counts) |c| try std.testing.expectEqual(@as(u32, 1), c);
}

test "BalancedGroupSystem createSlottedGroups still finishes the pair round-robin" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();
    for (0..8) |i| {
        var buf: [8]u8 = undefined;
        try bgs.addMember(try std.fmt.bufPrint(&buf, "m{d}", .{i}));
    }

    var prng = std.Random.DefaultPrng.init(11);
    for (0..7) |_| {
        var round = try bgs.createSlottedGroups(4, prng.random(), 1);
        gs_mod.freeRound(allocator, &round);
    }
    for (bgs.fam_matrix.items) |v| try std.testing.expectEqual(@as(u32, 2), v);
    // 7 rounds over 4 ids: 2 is ideal, but ids are chosen one round at a time
    // after the round-robin's constraints, so allow one extra visit.
    const counts = try bgs.slotCounts(allocator, 4);
    defer allocator.free(counts);
    for (counts) |c| try std.testing.expect(c <= 3);
}

test "BalancedGroupSystem slotCounts follows undo and removed members" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();
    for ([_][]const u8{ "A", "B", "C", "D" }) |n| try bgs.addMember(n);

    const g1 = [_][]const u8{ "A", "B" };
    const g2 = [_][]const u8{ "C", "D" };
    try bgs.recordManualRound(&[_][]const []const u8{ &g1, &g2 });
    try bgs.removeMember("B");

    const counts = try bgs.slotCounts(allocator, 2);
    defer allocator.free(counts);
    // A, C, D → indices 0, 1, 2
    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 0, 1, 0, 1 }, counts);

    try bgs.undoLastRound();
    const after = try bgs.slotCounts(allocator, 2);
    defer allocator.free(after);
    for (after) |c| try std.testing.expectEqual(@as(u32, 0), c);
}

test "BalancedGroupSystem recordManualSlottedRound keeps empty ids in place" {
    const allocator = std.testing.allocator;
    var bgs = BalancedGroupSystem.init(allocator);
    defer bgs.deinit();
    for ([_][]const u8{ "A", "B", "C" }) |n| try bgs.addMember(n);

    const empty = [_][]const u8{};
    try std.testing.expectError(error.EmptyGroup, bgs.recordManualSlottedRound(&.{ &empty, &empty }));
    try bgs.recordManualSlottedRound(&.{ &.{ "A", "B" }, &empty, &.{"C"} });

    const counts = try bgs.slotCounts(allocator, 3);
    defer allocator.free(counts);
    // C sat at id 2, not id 1.
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1 }, counts[2 * 3 ..][0..3]);
    try bgs.undoLastRound();
}
