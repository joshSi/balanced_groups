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

    // Group ids matter: "Table 1" is the same table every round, so members
    // should also rotate tables. Compare plain groups with slotted ones.
    const people = [_][]const u8{
        "Ann", "Ben", "Cat", "Dan", "Eli", "Fay", "Gus", "Hal", "Ivy", "Jo", "Kai", "Lee",
    };
    const tables = 3;
    const rounds = 3;
    for ([_]?u32{ null, 4 }) |weight| {
        var sys = bg.BalancedGroupSystem.init(allocator);
        defer sys.deinit();
        for (people) |p| try sys.addMember(p);

        if (weight) |w|
            try out.print("\nSlotted (weight {d}):\n", .{w})
        else
            try out.print("\nPlain (group ids ignored):\n", .{});
        for (0..rounds) |r| {
            const round = if (weight) |w|
                try sys.createSlottedGroups(tables, rand, w)
            else
                try sys.createBalancedGroups(tables, rand);
            defer bg.freeRound(allocator, @constCast(&round));
            try out.print("  Round {d}:", .{r + 1});
            for (round.items, 0..) |group, gi| {
                try out.print("  T{d}[", .{gi + 1});
                for (group.items, 0..) |name, ni| {
                    if (ni > 0) try out.print(" ", .{});
                    try out.print("{s}", .{name});
                }
                try out.print("]", .{});
            }
            try out.print("\n", .{});
        }

        const visits = try sys.slotCounts(allocator, tables);
        var repeats: u32 = 0;
        for (visits) |v| repeats += v -| 1;
        var met_twice: u32 = 0;
        for (sys.fam_matrix.items) |f| met_twice += (f / 2) -| 1;
        try out.print("  repeat table visits: {d}, repeat meetings: {d}\n", .{ repeats, met_twice });
    }
    try out_fw.flush();
}
