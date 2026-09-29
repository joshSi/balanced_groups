//! Benchmarks for BalancedGroupSystem.
//!
//! Run with: zig build bench

const std = @import("std");
const Io = std.Io;
const bg = @import("balanced_groups");

const Config = struct {
    members: usize,
    groups: usize,
    rounds: usize,
};

const CONFIGS = [_]Config{
    .{ .members = 20, .groups = 4, .rounds = 100 },
    .{ .members = 50, .groups = 5, .rounds = 100 },
    .{ .members = 100, .groups = 10, .rounds = 50 },
    .{ .members = 200, .groups = 20, .rounds = 20 },
    .{ .members = 500, .groups = 25, .rounds = 10 },
};

fn runConfig(io: Io, allocator: std.mem.Allocator, cfg: Config, rand: std.Random) !u64 {
    var bgs = bg.BalancedGroupSystem.init(allocator);
    defer bgs.deinit();

    var name_buf: [16]u8 = undefined;
    for (0..cfg.members) |i| {
        const name = std.fmt.bufPrint(&name_buf, "m{d}", .{i}) catch unreachable;
        try bgs.addMember(name);
    }

    const t0 = Io.Timestamp.now(io, .awake);
    for (0..cfg.rounds) |_| {
        var round = try bgs.createBalancedGroups(cfg.groups, rand);
        bg.freeRound(allocator, &round);
    }
    const t1 = Io.Timestamp.now(io, .awake);
    return @intCast(t0.durationTo(t1).nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var out_buf: [8192]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    try out.print(
        "\n{s:<12} {s:<8} {s:<8} {s:>12} {s:>14} {s:>12}\n",
        .{ "members", "groups", "rounds", "total (ms)", "per-round (µs)", "rounds/sec" },
    );
    try out.print("{s}\n", .{"─" ** 68});

    for (CONFIGS) |cfg| {
        // Warm-up (not measured)
        _ = try runConfig(io, allocator, cfg, rand);

        const elapsed_ns = try runConfig(io, allocator, cfg, rand);
        const total_ms = elapsed_ns / std.time.ns_per_ms;
        const per_round_us = elapsed_ns / std.time.ns_per_us / cfg.rounds;
        const rounds_per_sec = if (elapsed_ns > 0)
            cfg.rounds * std.time.ns_per_s / elapsed_ns
        else
            0;

        try out.print(
            "{d:<12} {d:<8} {d:<8} {d:>12} {d:>14} {d:>12}\n",
            .{ cfg.members, cfg.groups, cfg.rounds, total_ms, per_round_us, rounds_per_sec },
        );
    }
    try out.print("\n", .{});
    try out_fw.flush();
}
