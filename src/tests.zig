//! Extended test suite for balanced_groups.
//! Covers edge cases, correctness properties, and stress scenarios
//! not already covered by the inline tests in each module file.

const std = @import("std");
const bg = @import("balanced_groups");

const alloc = std.testing.allocator;

// ── GroupSystem ───────────────────────────────────────────────────────────────

test "GroupSystem: duplicate member names allowed" {
    var gs = bg.GroupSystem.init(alloc);
    defer gs.deinit();
    try gs.addMember("Alice");
    try gs.addMember("Alice"); // same name twice
    try std.testing.expectEqual(@as(usize, 2), gs.memberCount());
}

test "GroupSystem: removeMember returns error for unknown name" {
    var gs = bg.GroupSystem.init(alloc);
    defer gs.deinit();
    try gs.addMember("Alice");
    try std.testing.expectError(error.MemberNotFound, gs.removeMember("Bob"));
}

test "GroupSystem: empty system is safe to deinit" {
    var gs = bg.GroupSystem.init(alloc);
    gs.deinit();
}

// ── BalancedGroupSystem: correctness ─────────────────────────────────────────

test "BGS: single member, single group" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();
    try bgs.addMember("Solo");

    var prng = std.Random.DefaultPrng.init(1);
    var round = try bgs.createBalancedGroups(1, prng.random());
    defer bg.freeRound(alloc, &round);

    try std.testing.expectEqual(@as(usize, 1), round.items.len);
    try std.testing.expectEqual(@as(usize, 1), round.items[0].items.len);
}

test "BGS: more groups than members — each member gets its own group" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();
    for ([_][]const u8{ "A", "B", "C" }) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(2);
    var round = try bgs.createBalancedGroups(5, prng.random()); // 5 groups, 3 members
    defer bg.freeRound(alloc, &round);

    // 5 groups but only 3 members — 3 groups get 1 member, 2 stay empty
    var total: usize = 0;
    for (round.items) |g| total += g.items.len;
    try std.testing.expectEqual(@as(usize, 3), total);
}

test "BGS: partition property — every member appears exactly once per round" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();
    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "David", "Eve", "Frank", "Grace" };
    for (names) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();

    var seen = std.StringHashMap(u32).init(alloc);
    defer seen.deinit();

    for (0..10) |_| {
        seen.clearRetainingCapacity();
        var round = try bgs.createBalancedGroups(3, rand);
        defer bg.freeRound(alloc, &round);

        for (round.items) |g| {
            for (g.items) |name| {
                const entry = try seen.getOrPut(name);
                if (entry.found_existing) {
                    try std.testing.expect(false); // duplicate member in round
                }
                entry.value_ptr.* = 1;
            }
        }
        try std.testing.expectEqual(names.len, seen.count());
    }
}

test "BGS: familiarity is symmetric" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();
    const names = [_][]const u8{ "A", "B", "C", "D", "E" };
    for (names) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();

    for (0..8) |_| {
        var round = try bgs.createBalancedGroups(2, rand);
        bg.freeRound(alloc, &round);
    }

    const n = bgs.base.memberCount();
    for (0..n) |i| {
        for (0..n) |j| {
            try std.testing.expectEqual(bgs.getFam(i, j), bgs.getFam(j, i));
        }
    }
}

test "BGS: familiarity only increments, never decrements" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();
    const names = [_][]const u8{ "A", "B", "C", "D" };
    for (names) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    const n = bgs.base.memberCount();

    var prev = try alloc.alloc(u32, n * n);
    defer alloc.free(prev);
    for (0..n) |i| {
        for (0..n) |j| prev[i * n + j] = bgs.getFam(i, j);
    }

    for (0..20) |_| {
        var round = try bgs.createBalancedGroups(2, rand);
        bg.freeRound(alloc, &round);

        for (0..n) |i| {
            for (0..n) |j| {
                const cur = bgs.getFam(i, j);
                try std.testing.expect(cur >= prev[i * n + j]);
                prev[i * n + j] = cur;
            }
        }
    }
}

test "BGS: group count matches after multiple rounds" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();
    for (0..12) |i| {
        var name_buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "m{d}", .{i});
        try bgs.addMember(name);
    }

    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();

    for (0..5) |_| {
        var round = try bgs.createBalancedGroups(4, rand);
        defer bg.freeRound(alloc, &round);
        try std.testing.expectEqual(@as(usize, 4), round.items.len);
    }
    try std.testing.expectEqual(@as(usize, 5), bgs.base.group_history.items.len);
}

test "BGS: groups are balanced (size differs by at most 1)" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();
    const names = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" };
    for (names) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(123);
    const rand = prng.random();

    for (0..20) |_| {
        var round = try bgs.createBalancedGroups(3, rand);
        defer bg.freeRound(alloc, &round);

        var min_sz: usize = std.math.maxInt(usize);
        var max_sz: usize = 0;
        for (round.items) |g| {
            if (g.items.len == 0) continue;
            min_sz = @min(min_sz, g.items.len);
            max_sz = @max(max_sz, g.items.len);
        }
        try std.testing.expect(max_sz - min_sz <= 1);
    }
}

test "BGS: addMember after rounds preserves familiarity" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();
    for ([_][]const u8{ "A", "B", "C" }) |n| try bgs.addMember(n);

    var prng = std.Random.DefaultPrng.init(5);
    const rand = prng.random();

    var round = try bgs.createBalancedGroups(2, rand);
    bg.freeRound(alloc, &round);

    const fam_ab = bgs.getFam(0, 1);

    try bgs.addMember("D"); // should not disturb existing familiarity
    try std.testing.expectEqual(fam_ab, bgs.getFam(0, 1));
    try std.testing.expectEqual(@as(u32, 0), bgs.getFam(0, 3)); // new member starts at 0
}

test "BGS: removeMember preserves unrelated familiarity" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();
    for ([_][]const u8{ "A", "B", "C", "D" }) |n| try bgs.addMember(n);

    // Manually set familiarity: A-C = 6, B-D = 4
    bgs.addFam(0, 2, 6);
    bgs.addFam(1, 3, 4);

    try bgs.removeMember("B"); // was index 1; C→1, D→2
    // A(0) – C(1): familiarity should still be 6
    try std.testing.expectEqual(@as(u32, 6), bgs.getFam(0, 1));
    // A(0) – D(2): was 0, should remain 0
    try std.testing.expectEqual(@as(u32, 0), bgs.getFam(0, 2));
}

test "BGS: zero groups returns empty round" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();
    try bgs.addMember("A");

    var prng = std.Random.DefaultPrng.init(0);
    var round = try bgs.createBalancedGroups(0, prng.random());
    defer bg.freeRound(alloc, &round);
    try std.testing.expectEqual(@as(usize, 0), round.items.len);
}

test "BGS: no members returns empty round" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    var round = try bgs.createBalancedGroups(3, prng.random());
    defer bg.freeRound(alloc, &round);
    try std.testing.expectEqual(@as(usize, 0), round.items.len);
}

// ── AvailableGroupScheduler ───────────────────────────────────────────────────

test "AGS: all-false schedule produces empty group" {
    var sched = bg.AvailableGroupScheduler.init(alloc);
    defer sched.deinit();
    for ([_][]const u8{ "A", "B", "C" }) |n| try sched.addMember(n);
    try sched.addSchedule(&[_]bool{ false, false, false });

    const groups = try sched.createBalancedSchedules(2);
    defer sched.freeSchedule(groups);

    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 0), groups[0].len);
}

test "AGS: participation is tracked across windows" {
    var sched = bg.AvailableGroupScheduler.init(alloc);
    defer sched.deinit();
    for ([_][]const u8{ "A", "B", "C", "D" }) |n| try sched.addMember(n);

    // Same availability for 4 windows; each window picks 2 from 4
    for (0..4) |_| {
        try sched.addSchedule(&[_]bool{ true, true, true, true });
    }

    const groups = try sched.createBalancedSchedules(2);
    defer sched.freeSchedule(groups);

    // After 4 windows with group_size=2, each member should have participated ~2 times
    var total_participations: u32 = 0;
    for (sched.participation.items) |p| total_participations += p;
    try std.testing.expectEqual(@as(u32, 4 * 2), total_participations); // 4 windows × 2 per group
}

// ── Stress test ───────────────────────────────────────────────────────────────

test "BGS: stress — 200 members × 30 rounds, no memory leaks" {
    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();

    var name_buf: [16]u8 = undefined;
    for (0..200) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "member{d}", .{i});
        try bgs.addMember(name);
    }

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    for (0..30) |_| {
        var round = try bgs.createBalancedGroups(20, rand);
        bg.freeRound(alloc, &round);
    }

    try std.testing.expectEqual(@as(usize, 30), bgs.base.group_history.items.len);
}
