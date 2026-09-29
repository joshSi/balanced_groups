const std = @import("std");
const Allocator = std.mem.Allocator;

/// A single group: a list of member name strings (owned by the caller).
pub const Group = std.ArrayList([]u8);
/// One round of grouping: a list of Groups.
pub const Round = std.ArrayList(Group);

/// Free a Round and all strings it contains.
pub fn freeRound(allocator: Allocator, round: *Round) void {
    for (round.items) |*g| freeGroup(allocator, g);
    round.deinit(allocator);
}

/// Free a Group and all strings it contains.
pub fn freeGroup(allocator: Allocator, group: *Group) void {
    for (group.items) |name| allocator.free(name);
    group.deinit(allocator);
}

/// Manages a list of members and records group history across rounds.
pub const GroupSystem = struct {
    allocator: Allocator,
    members: std.ArrayList([]u8),
    group_history: std.ArrayList(Round),

    pub fn init(allocator: Allocator) GroupSystem {
        return .{
            .allocator = allocator,
            .members = .empty,
            .group_history = .empty,
        };
    }

    pub fn deinit(self: *GroupSystem) void {
        for (self.members.items) |m| self.allocator.free(m);
        self.members.deinit(self.allocator);
        for (self.group_history.items) |*round| freeRound(self.allocator, round);
        self.group_history.deinit(self.allocator);
    }

    pub fn addMember(self: *GroupSystem, name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.members.append(self.allocator, owned);
    }

    pub fn removeMember(self: *GroupSystem, name: []const u8) !void {
        for (self.members.items, 0..) |m, i| {
            if (std.mem.eql(u8, m, name)) {
                const removed = self.members.orderedRemove(i);
                self.allocator.free(removed);
                return;
            }
        }
        return error.MemberNotFound;
    }

    pub fn memberCount(self: *const GroupSystem) usize {
        return self.members.items.len;
    }

    pub fn findMemberIndex(self: *const GroupSystem, name: []const u8) ?usize {
        for (self.members.items, 0..) |m, i| {
            if (std.mem.eql(u8, m, name)) return i;
        }
        return null;
    }

    /// Appends a round to history. Takes ownership of `round`.
    pub fn recordRound(self: *GroupSystem, round: Round) !void {
        try self.group_history.append(self.allocator, round);
    }

    pub fn printHistory(self: *const GroupSystem) void {
        for (self.group_history.items, 0..) |round, ri| {
            std.debug.print("{d}: [", .{ri});
            for (round.items, 0..) |group, gi| {
                std.debug.print("{{", .{});
                for (group.items, 0..) |name, ni| {
                    if (ni > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{name});
                }
                std.debug.print("}}", .{});
                if (gi + 1 < round.items.len) std.debug.print(", ", .{});
            }
            std.debug.print("]\n", .{});
        }
    }
};

test "GroupSystem add and remove members" {
    const allocator = std.testing.allocator;
    var gs = GroupSystem.init(allocator);
    defer gs.deinit();

    try gs.addMember("Alice");
    try gs.addMember("Bob");
    try gs.addMember("Charlie");
    try std.testing.expectEqual(@as(usize, 3), gs.memberCount());

    try gs.removeMember("Bob");
    try std.testing.expectEqual(@as(usize, 2), gs.memberCount());
    try std.testing.expect(gs.findMemberIndex("Alice") != null);
    try std.testing.expect(gs.findMemberIndex("Bob") == null);
    try std.testing.expect(gs.findMemberIndex("Charlie") != null);
}

test "GroupSystem recordRound and history" {
    const allocator = std.testing.allocator;
    var gs = GroupSystem.init(allocator);
    defer gs.deinit();

    try gs.addMember("Alice");
    try gs.addMember("Bob");
    try gs.addMember("Charlie");

    var round: Round = .empty;
    var g1: Group = .empty;
    try g1.append(allocator, try allocator.dupe(u8, "Alice"));
    try g1.append(allocator, try allocator.dupe(u8, "Bob"));
    try round.append(allocator, g1);
    var g2: Group = .empty;
    try g2.append(allocator, try allocator.dupe(u8, "Charlie"));
    try round.append(allocator, g2);

    try gs.recordRound(round);
    try std.testing.expectEqual(@as(usize, 1), gs.group_history.items.len);
    try std.testing.expectEqual(@as(usize, 2), gs.group_history.items[0].items.len);
}
