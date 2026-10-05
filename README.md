# balanced_groups

A Zig 0.16 library for organizing members into balanced groups across multiple
rounds, maximising new interactions and minimising repeat meetings. Addresses
the [Social Golfer Problem](https://en.wikipedia.org/wiki/Social_golfer_problem).

This is a Zig rewrite of
[joshSi/balanced_group_system](https://github.com/joshSi/balanced_group_system)
(originally Python), with explicit allocator control and optimised data
structures.

---

## Requirements

- [Zig 0.16](https://ziglang.org/download/)

---

## Build

```sh
zig build          # compile the example binary and the API server to zig-out/bin/
zig build run      # compile and run the example
zig build serve    # compile and run the HTTP API server (see below)
zig build test     # run the full test suite
zig build bench    # run performance benchmarks (always ReleaseFast)
```

---

## How it works

### `BalancedGroupSystem`

Tracks a **pairwise familiarity matrix** across rounds and greedily assigns
members to groups to minimise repeat meetings.

```zig
const std = @import("std");
const bg = @import("balanced_groups");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    var bgs = bg.BalancedGroupSystem.init(alloc);
    defer bgs.deinit();

    const members = [_][]const u8{
        "Alice", "Bob", "Charlie", "David", "Eve", "Frank",
    };
    for (members) |m| try bgs.addMember(m);

    var seed: u64 = undefined;
    init.io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);

    for (0..5) |_| {
        var round = try bgs.createBalancedGroups(3, prng.random());
        defer bg.freeRound(alloc, @constCast(&round));
        // round.items is a []Group where Group = ArrayList([]u8) of names
    }

    bgs.base.printHistory(); // prints all recorded rounds to stderr
}
```

### `AvailableGroupScheduler`

Like `BalancedGroupSystem` but accepts per-window **availability schedules**,
building one group per window while prioritising under-participated members.

---

## Algorithm

Each round, members are shuffled randomly and placed one-by-one into the group
that minimises a running score:

```
score(group after adding member m)
    = score(group before) + Σ familiarity(m, existing) + 2
```

The `+2` is a **size penalty** that keeps groups balanced when familiarity is
zero: a group of size k has a base score of `2k`, so the greedy pass
distributes members evenly before favouring new pairings.

After placement, every pair in each group has its familiarity incremented by 2
(matching the original Python convention of iterating over all ordered pairs
`(i, j)` and `(j, i)` for each pair).

---

## Performance

All numbers measured on a headless Linux VPS (2 vCPU Intel Xeon Skylake,
3.7 GB RAM), compiled with `-Doptimize=ReleaseFast`.

### Benchmark results

| members | groups | rounds | total (ms) | per-round (µs) | rounds/sec |
|--------:|-------:|-------:|-----------:|---------------:|-----------:|
|      20 |      4 |    100 |         <1 |              7 |    ~130 K  |
|      50 |      5 |    100 |          2 |             22 |     ~44 K  |
|     100 |     10 |     50 |          3 |             60 |     ~17 K  |
|     200 |     20 |     20 |          3 |            164 |      ~6 K  |
|     500 |     25 |     10 |          6 |            600 |     ~1.7 K |

Scaling is close to O(n²) per round as expected (2× members ≈ 2.7× time),
with minor cache-pressure growth at larger n.

### Optimisations over the Python original

| Concern | Python | Zig |
|---------|--------|-----|
| Familiarity matrix | `dict[frozenset[str], int]` — O(n) hash per pair lookup | Flat `[]u32` lower-triangle — O(1) index arithmetic, cache-friendly |
| Group-score memo | `dict[frozenset[str], int]` — one HashMap entry (+ frozenset alloc) per group state | `[group_count]u32` running array — zero allocations in the inner loop |
| Member index lookup | `list.index(name)` — O(n) linear scan | `StringHashMap(usize)` — O(1) amortised |
| Memory model | GC / reference counting | Explicit; single allocator per struct, no hidden allocs in hot path |

#### Flat lower-triangle matrix

For `n` members the familiarity of pair `(lo, hi)` (lo < hi) sits at:

```
matrix[ hi*(hi-1)/2 + lo ]
```

All `hi-1` entries for member `hi` are contiguous in memory. The inner loop
of `createBalancedGroups` scans each group's members sequentially, so
familiarity lookups hit the L1 cache rather than chasing pointers through a
hash table.

Adding a member appends `n` zeros (O(n), amortised O(1) with ArrayList
doubling). Removing member `k` compacts in O(n) time.

#### Running group-score array

Python's `_calculate_balanced_groups` memoised intermediate scores in a
`dict[frozenset[str], int]`: each group state needed a frozenset allocation
(O(k) for size-k group) plus a hash-map insertion. The Zig version maintains
a plain `group_scores[group_count]` array:

```zig
// Before placing member m into group gi:
var score = group_scores[gi];               // O(1) array read
for (group.items) |existing| score += getFam(m, existing); // O(k)
score += 2;                                 // size penalty
// After choosing best group:
group_scores[best_gi] = best_score;         // O(1) array write
```

No allocations occur inside the placement loop.

---

## Test suite

Tests covering:

- **GroupSystem**: member add/remove, history recording, error handling
- **BalancedGroupSystem**: partition property (every member appears exactly once
  per round), balance property (group sizes differ by at most 1), familiarity
  symmetry, familiarity monotonicity (never decrements), edge cases (zero members,
  zero groups, more groups than members), member add/remove preserving unrelated
  familiarity
- **AvailableGroupScheduler**: all-false schedule, participation tracking across
  windows, fallback when candidates < group_size
- **Stress**: 200 members × 30 rounds, checked for memory leaks via
  `std.testing.allocator`

```
zig build test
# Build Summary: 5/5 steps succeeded; 38/38 tests passed
```

---

## API

### `BalancedGroupSystem`

| Method | Description |
|--------|-------------|
| `init(allocator)` | Create a new system |
| `deinit()` | Free all memory |
| `addMember(name)` | Add a member; grows matrix by O(n) |
| `removeMember(name)` | Remove a member; compacts matrix in O(n) |
| `createBalancedGroups(count, rand)` | Return a new `Round`; also records in history |
| `recordManualRound(groups)` | Record externally formed groups (names); updates familiarity and history |
| `undoLastRound()` | Pop the latest round from history and subtract its familiarity |
| `getFam(i, j)` | Raw familiarity score between members at indices i and j |
| `evaluateGroup(indices)` | Sum familiarity over all ordered pairs (Python-compatible) |
| `printFamiliarity()` | Print the matrix to stderr |
| `base.printHistory()` | Print all recorded rounds to stderr |

`Round = ArrayList(Group)`, `Group = ArrayList([]u8)`.
Free caller-owned rounds with `freeRound(allocator, &round)`.

### `AvailableGroupScheduler`

| Method | Description |
|--------|-------------|
| `init(allocator)` | Create a new scheduler |
| `addMember(name)` | Add a member |
| `addSchedule([]bool)` | Add one availability window |
| `createBalancedSchedules(group_size)` | Return `[][]usize` (member indices, one group per window) |
| `freeSchedule(schedule)` | Free the returned schedule |

---

## HTTP API server

`src/server.zig` wraps several independent `BalancedGroupSystem`s ("group
systems", each with its own members, familiarity and history) in a small JSON
API so they can live on a server and be driven from a web page
([joshsi.com/groups.html](https://joshsi.com/groups.html), which picks a system
with `?g=<id>`). It uses only
`std.http.Server`, has no dependencies, and idles at ~2 MB RSS.

### Persistence

Every mutation serialises all systems (`src/persist.zig`) and atomically
replaces the state file (write `state.json.tmp`, fsync, rename). Each system
uses the same flat lower-triangle layout as the in-memory matrix:

```json
{
  "version": 3,
  "systems": [
    {
      "id": "main",
      "name": "Main",
      "key_hash": null,
      "created": 0,
      "members": ["Alice", "Bob", "Charlie"],
      "fam": [2, 0, 2],
      "history": [[["Alice", "Bob"], ["Charlie"]]]
    }
  ]
}
```

`key_hash` is the SHA-256 (lowercase hex) of the system's passcode, or null
when only the admin key may edit it. Version 2 files (no `key_hash`,
`created`) and version 1 files (a single system at the top level, loaded as
`main`) are still accepted and rewritten as version 3 on the next change, so
keep a copy if you may roll back to an older binary. With no state file the
server starts with one empty `main` system.

On start-up the file is loaded back; if it exists but cannot be parsed the
server refuses to start rather than overwrite it.

### Endpoints

| Method | Path                   | Body                | Description |
|--------|------------------------|---------------------|-------------|
| GET    | `/healthz`             |                     | Liveness check |
| GET    | `/api/systems`          |                     | `{ systems: [{ id, name, members, rounds, locked }] }` (admin key) |
| POST   | `/api/systems`          | `{ "name": "Chess club", "passcode": "optional" }` | **Open to anyone** (30/hour). Creates an empty system and returns `{ system: {id, name}, passcode }`; the id is the slugged name plus a random suffix (`chess-club-7f3k`) so systems are reachable by link, not by guessing |
| POST   | `/api/systems/rename`  | `{ "id": "chess-club", "name": "Chess" }` | Rename; the id (and links using it) stay the same |
| POST   | `/api/systems/delete`  | `{ "id": "chess-club" }` | Delete a system and everything in it (409 for the last one) |
| POST   | `/api/systems/passcode` | `{ "id": "…", "passcode": "optional" }` | Set a new passcode (generated when omitted); returns it once. Owner or admin |
| GET    | `/api/state`           |                     | `{ system: {id, name}, members, familiarity (n×n), history, rounds, can_edit, locked }` |
| POST   | `/api/members`         | `{ "name": "Eve" }` | Add a member (409 if it exists) |
| POST   | `/api/members/remove`  | `{ "name": "Eve" }` | Remove a member and their matrix row/column |
| POST   | `/api/rounds`          | `{ "group_count": 3 }` | Create a round; returns `{ round, state }` |
| POST   | `/api/rounds/manual`   | `{ "groups": [["Al","Bo"],["Cy"]], "add_missing": false }` | Record a round formed elsewhere (e.g. before the tool); 422 with `unknown` if names aren't members unless `add_missing` |
| POST   | `/api/rounds/undo`     |                     | Revert the latest round (familiarity is subtracted) |

`/api/state`, `/api/members*` and `/api/rounds*` act on the system given by
`?system=<id>` (404 if unknown), or on the first system when it is omitted.

Credentials travel as `Authorization: Bearer <token>` (or `X-Api-Key`). A
system's own passcode edits that system; `BG_API_KEY` is the admin key that
edits every system, lists them, and is the only way to edit a system without
a passcode (such as a `main` migrated from an older file; give it one with
`POST /api/systems/passcode`). Passcodes are stored hashed. `GET /api/state`
is public and, when a credential is sent, reports in `can_edit` whether it
may change that system. Member and round endpoints return the full updated
`state`. CORS is enabled for the origins in `BG_ALLOWED_ORIGINS`, including
pre-flight.

### Configuration

| Variable             | Default                              | Purpose |
|----------------------|--------------------------------------|---------|
| `BG_HOST`            | `127.0.0.1`                          | Bind address |
| `BG_PORT`            | `8090`                               | Bind port |
| `BG_STATE_PATH`      | `state.json`                         | Where the matrix is persisted |
| `BG_API_KEY`         | *(unset → passcode-only)*            | Admin key (≥16 chars): edits every system, lists them |
| `BG_ALLOWED_ORIGINS` | `https://joshsi.com,https://www.joshsi.com,https://joshsi.github.io` | CORS allow-list |

### Deployment

`scripts/deploy.sh` builds in `ReleaseSafe`, installs the binary to
`/opt/balanced-groups/`, generates `/etc/balanced-groups.env` with a random
API key on first run, and installs/restarts the hardened systemd unit in
`deploy/balanced-groups.service` (`DynamicUser`, state in
`/var/lib/balanced-groups/`). Re-run it after every change.

```sh
sudo ./scripts/deploy.sh
journalctl -u balanced-groups -f --no-pager
grep BG_API_KEY /etc/balanced-groups.env   # the admin key; it unlocks every system in the web page
```

The service listens on loopback only; a Cloudflare Tunnel public hostname
(`groups.joshsi.com → http://localhost:8090`) exposes it to the website.

---

## License

MIT
