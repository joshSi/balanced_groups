const std = @import("std");
const Io = std.Io;
const bg = @import("balanced_groups");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    const members = [_][]const u8{
        "Alice", "Bob", "Charlie", "David", "Eve", "Frank", "Grace", "Harry",
    };

    var bgs = bg.BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    for (members) |m| try bgs.addMember(m);

    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    for (0..3) |i| {
        const round = try bgs.createBalancedGroups(3, rand);
        defer bg.freeRound(allocator, @constCast(&round));
        try out.print("Round {d}:\n", .{i + 1});
        for (round.items, 0..) |group, gi| {
            try out.print("  Group {d}: ", .{gi + 1});
            for (group.items, 0..) |name, ni| {
                if (ni > 0) try out.print(", ", .{});
                try out.print("{s}", .{name});
            }
            try out.print("\n", .{});
        }
    }

    try out.print("\nFamiliarity matrix:\n", .{});
    try out_fw.flush();
    bgs.printFamiliarity();
}
