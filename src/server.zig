//! HTTP API server for balanced_groups.
//!
//! Keeps several independent `BalancedGroupSystem`s ("group systems", each
//! with its own members, familiarity and history) in memory, persists them as
//! one JSON file on every mutation, and exposes them over a small JSON API
//! consumed by joshsi.com.
//!
//! Configuration (environment variables):
//!
//!   BG_HOST             bind address            (default 127.0.0.1)
//!   BG_PORT             bind port               (default 8090)
//!   BG_STATE_PATH       JSON state file         (default ./state.json)
//!   BG_API_KEY          the admin key: edits every system, lists them all,
//!                       and is the only way to edit systems without a passcode
//!   BG_ALLOWED_ORIGINS  comma-separated CORS allow-list
//!                       (default https://joshsi.com,https://www.joshsi.com,
//!                                https://joshsi.github.io)
//!
//! Anyone can create a group system and gets a passcode for it; that passcode
//! (or the admin key) is the bearer token for every change to that system.
//! Ids carry a random suffix so a system is reachable only by its link.
//!
//! Endpoints:
//!
//!   GET  /healthz                        -> "ok"
//!   POST /api/systems  {name, passcode?} -> create a system; returns its id and passcode (open, rate-limited)
//!   GET  /api/systems                    -> { systems: [{id, name, members, rounds, locked}] }  (admin)
//!   POST /api/systems/rename   {id, name}            (owner or admin)
//!   POST /api/systems/delete   {id}                  (owner or admin; not the last one)
//!   POST /api/systems/passcode {id, passcode?}       -> set or regenerate the passcode (owner or admin)
//!   GET  /api/state                      -> { system, members, familiarity, history, rounds, can_edit }
//!   POST /api/members        {name}      -> add a member
//!   POST /api/members/remove {name}      -> remove a member
//!   POST /api/rounds   {group_count}     -> create a round, returns {round, state}
//!   POST /api/rounds/manual {groups, add_missing?}
//!                                        -> record groups formed elsewhere
//!   POST /api/rounds/undo                -> revert the most recent round
//!
//! `/api/state`, `/api/members*` and `/api/rounds*` act on the system named by
//! the `?system=<id>` query parameter, or on the first system when it is
//! omitted (so clients written before multiple systems keep working).
//!
//! Credentials go in `Authorization: Bearer <passcode or admin key>` (or
//! `X-Api-Key`). `GET /api/state` is public; with a credential it also says
//! whether that credential may edit (`can_edit`). Every mutating response
//! includes the full updated state so the client can re-render without a
//! second request.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const Allocator = std.mem.Allocator;
const bg = @import("balanced_groups");
const persist = bg.persist;

const log = std.log.scoped(.server);

const default_origins = "https://joshsi.com,https://www.joshsi.com,https://joshsi.github.io";
const max_body_len = 64 * 1024;
const max_state_file_len = 64 * 1024 * 1024;
const max_member_name_len = 64;
const max_members = 1000;
const max_systems = 500;
const max_system_id_len = 40;
const min_passcode_len = 8;
const max_passcode_len = 128;
/// Open creation is rate-limited: at most this many new systems per hour.
const max_creations_per_hour = 30;
const passcode_alphabet = "abcdefghjkmnpqrstuvwxyz23456789"; // no 0/o/1/l/i
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Who is asking, for one system.
const Role = enum { none, owner, admin };

fn hashPasscode(passcode: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(passcode, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn validatePasscode(raw: []const u8) ![]const u8 {
    const p = std.mem.trim(u8, raw, " \t\r\n");
    if (p.len < min_passcode_len) return error.PasscodeTooShort;
    if (p.len > max_passcode_len) return error.PasscodeTooLong;
    for (p) |c| if (std.ascii.isControl(c)) return error.InvalidPasscode;
    return p;
}

const App = struct {
    gpa: Allocator,
    io: Io,
    store: persist.Store,
    state_path: []const u8,
    tmp_path: []const u8,
    api_key: ?[]const u8,
    allowed_origins: []const []const u8,
    prng: std.Random.DefaultPrng,
    /// Unix seconds of recent system creations, for the rate limit.
    creations: [max_creations_per_hour]i64 = [_]i64{0} ** max_creations_per_hour,

    fn now(self: *const App) i64 {
        return Io.Clock.Timestamp.now(self.io, .real).raw.toSeconds();
    }

    /// Record a creation if the hourly budget allows it.
    fn allowCreation(self: *App) bool {
        const t = self.now();
        var oldest: usize = 0;
        for (self.creations, 0..) |c, i| if (c < self.creations[oldest]) {
            oldest = i;
        };
        if (t - self.creations[oldest] < 3600) return false;
        self.creations[oldest] = t;
        return true;
    }

    /// A fresh passcode like "k7mq-4x2p-9hd3" (about 59 bits), from OS randomness.
    fn newPasscode(self: *const App, arena: Allocator) ![]const u8 {
        var raw: [12]u8 = undefined;
        self.io.random(&raw);
        var out = try arena.alloc(u8, 14);
        var j: usize = 0;
        for (raw, 0..) |b, i| {
            if (i == 4 or i == 8) {
                out[j] = '-';
                j += 1;
            }
            out[j] = passcode_alphabet[b % passcode_alphabet.len];
            j += 1;
        }
        return out;
    }

    fn roleFor(self: *const App, sys: ?*const persist.NamedSystem, presented: ?[]const u8) Role {
        const p = presented orelse return .none;
        if (self.authorized(p)) return .admin;
        const s = sys orelse return .none;
        const h = s.key_hash orelse return .none;
        const hex = hashPasscode(p);
        if (h.len != hex.len) return .none;
        var diff: u8 = 0;
        for (h, hex) |a, b| diff |= a ^ b;
        return if (diff == 0) .owner else .none;
    }

    fn load(self: *App) !void {
        const cwd = Io.Dir.cwd();
        const bytes = cwd.readFileAlloc(self.io, self.state_path, self.gpa, .limited(max_state_file_len)) catch |err| switch (err) {
            error.FileNotFound => {
                log.info("no state file at {s}; starting empty", .{self.state_path});
                return;
            },
            else => return err,
        };
        defer self.gpa.free(bytes);
        var loaded = persist.storeFromJson(self.gpa, bytes) catch |err| {
            log.err("state file {s} could not be loaded ({t}); refusing to start so it is not overwritten", .{ self.state_path, err });
            return error.CorruptStateFile;
        };
        if (loaded.items.len == 0) {
            loaded.deinit(self.gpa);
            return;
        }
        persist.deinitStore(self.gpa, &self.store);
        self.store = loaded;
        for (self.store.items) |*sys| {
            log.info("loaded system {s}: {d} members, {d} rounds", .{
                sys.id, sys.bgs.base.memberCount(), sys.bgs.base.group_history.items.len,
            });
        }
    }

    fn find(self: *App, id: []const u8) ?*persist.NamedSystem {
        for (self.store.items) |*sys| {
            if (std.mem.eql(u8, sys.id, id)) return sys;
        }
        return null;
    }

    /// Turn a display name into a unique URL-safe id with a random suffix, so a
    /// system is reachable by its link but not by guessing: "Chess Club!" ->
    /// "chess-club-7f3k".
    fn uniqueId(self: *App, arena: Allocator, name: []const u8) ![]const u8 {
        var base: std.ArrayList(u8) = .empty;
        for (name) |c| {
            if (base.items.len >= max_system_id_len) break;
            if (std.ascii.isAlphanumeric(c)) {
                try base.append(arena, std.ascii.toLower(c));
            } else if (base.items.len > 0 and base.items[base.items.len - 1] != '-') {
                try base.append(arena, '-');
            }
        }
        while (base.items.len > 0 and base.items[base.items.len - 1] == '-') base.items.len -= 1;
        if (base.items.len == 0) try base.appendSlice(arena, "group");

        while (true) {
            var raw: [4]u8 = undefined;
            self.io.random(&raw);
            var suffix: [4]u8 = undefined;
            for (raw, 0..) |b, i| suffix[i] = passcode_alphabet[b % passcode_alphabet.len];
            const candidate = try std.fmt.allocPrint(arena, "{s}-{s}", .{ base.items, suffix });
            if (self.find(candidate) == null) return candidate;
        }
    }

    /// Atomically persist: write to a temp file, fsync, rename over the target.
    fn save(self: *App) !void {
        const json = try persist.storeToJson(self.gpa, self.store.items);
        defer self.gpa.free(json);

        const cwd = Io.Dir.cwd();
        {
            var file = try cwd.createFile(self.io, self.tmp_path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, json);
            try file.sync(self.io);
        }
        try Io.Dir.rename(cwd, self.tmp_path, cwd, self.state_path, self.io);
    }

    fn originAllowed(self: *const App, origin: []const u8) bool {
        for (self.allowed_origins) |o| {
            if (std.mem.eql(u8, o, origin)) return true;
        }
        return false;
    }

    fn authorized(self: *const App, presented: ?[]const u8) bool {
        const key = self.api_key orelse return false;
        const p = presented orelse return false;
        if (p.len != key.len) return false;
        var diff: u8 = 0;
        for (p, key) |a, b| diff |= a ^ b;
        return diff == 0;
    }
};

// ── Request handling ──────────────────────────────────────────────────────────

const RequestInfo = struct {
    method: http.Method,
    path: []const u8,
    /// Value of the `system` query parameter, if present.
    system: ?[]const u8,
    origin: ?[]const u8,
    api_key: ?[]const u8,
};

const Ctx = struct {
    app: *App,
    arena: Allocator,
    req: *http.Server.Request,
    info: RequestInfo,
    cors: std.ArrayList(http.Header),

    fn headers(self: *Ctx, extra: []const http.Header) ![]const http.Header {
        var list = try std.ArrayList(http.Header).initCapacity(self.arena, self.cors.items.len + extra.len + 1);
        // This is a JSON API, never a page: keep it out of search indexes.
        list.appendAssumeCapacity(.{ .name = "x-robots-tag", .value = "noindex, nofollow" });
        list.appendSliceAssumeCapacity(self.cors.items);
        list.appendSliceAssumeCapacity(extra);
        return list.items;
    }

    fn respondJson(self: *Ctx, status: http.Status, value: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(self.arena, value, .{});
        try self.req.respond(body, .{
            .status = status,
            .extra_headers = try self.headers(&.{
                .{ .name = "content-type", .value = "application/json; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
            }),
        });
    }

    fn respondError(self: *Ctx, status: http.Status, message: []const u8) !void {
        try self.respondJson(status, .{ .@"error" = message });
    }

    fn respondText(self: *Ctx, status: http.Status, text: []const u8) !void {
        try self.req.respond(text, .{
            .status = status,
            .extra_headers = try self.headers(&.{
                .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
            }),
        });
    }
};

/// Wire shape of GET /api/state. Slices alias the live system; serialise
/// before mutating again.
const StateView = struct {
    system: SystemRef,
    members: []const []const u8,
    familiarity: []const []const u32,
    history: HistoryView,
    rounds: usize,
    /// May the credential sent with this request change the system?
    can_edit: bool,
    /// Does the system have its own passcode (false: admin key only)?
    locked: bool,

    const HistoryView = struct {
        rounds: []const bg.Round,
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
};

const SystemRef = struct { id: []const u8, name: []const u8 };

const SystemSummary = struct {
    id: []const u8,
    name: []const u8,
    members: usize,
    rounds: usize,
    locked: bool,
};

fn systemsView(arena: Allocator, app: *const App) ![]const SystemSummary {
    const out = try arena.alloc(SystemSummary, app.store.items.len);
    for (app.store.items, out) |*sys, *o| o.* = .{
        .id = sys.id,
        .name = sys.name,
        .members = sys.bgs.base.memberCount(),
        .rounds = sys.bgs.base.group_history.items.len,
        .locked = sys.key_hash != null,
    };
    return out;
}

fn stateView(arena: Allocator, sys: *const persist.NamedSystem, role: Role) !StateView {
    const bgs = &sys.bgs;
    const n = bgs.base.memberCount();
    const rows = try arena.alloc([]const u32, n);
    for (rows, 0..) |*row, i| {
        const r = try arena.alloc(u32, n);
        for (r, 0..) |*cell, j| cell.* = bgs.getFam(i, j);
        row.* = r;
    }
    return .{
        .system = .{ .id = sys.id, .name = sys.name },
        .members = @ptrCast(bgs.base.members.items),
        .familiarity = rows,
        .history = .{ .rounds = bgs.base.group_history.items },
        .rounds = bgs.base.group_history.items.len,
        .can_edit = role != .none,
        .locked = sys.key_hash != null,
    };
}

const RoundView = struct {
    groups: []const bg.Group,
    pub fn jsonStringify(self: @This(), jws: *std.json.Stringify) !void {
        try jws.beginArray();
        for (self.groups) |group| {
            try jws.beginArray();
            for (group.items) |name| try jws.write(name);
            try jws.endArray();
        }
        try jws.endArray();
    }
};

fn readHeaders(req: *const http.Server.Request, arena: Allocator) !RequestInfo {
    var info: RequestInfo = .{
        .method = req.head.method,
        .path = req.head.target,
        .system = null,
        .origin = null,
        .api_key = null,
    };
    // Split off the query string; the only parameter we read is `system`.
    if (std.mem.indexOfScalar(u8, info.path, '?')) |q| {
        var params = std.mem.splitScalar(u8, info.path[q + 1 ..], '&');
        while (params.next()) |param| {
            const prefix = "system=";
            if (std.mem.startsWith(u8, param, prefix)) {
                // Ids are [a-z0-9-], so no percent-decoding is needed.
                info.system = try arena.dupe(u8, param[prefix.len..]);
            }
        }
        info.path = info.path[0..q];
    }
    info.path = try arena.dupe(u8, info.path);

    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) {
            info.origin = try arena.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            const prefix = "Bearer ";
            if (h.value.len > prefix.len and std.ascii.eqlIgnoreCase(h.value[0..prefix.len], prefix)) {
                info.api_key = try arena.dupe(u8, std.mem.trim(u8, h.value[prefix.len..], " "));
            }
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-api-key")) {
            info.api_key = try arena.dupe(u8, std.mem.trim(u8, h.value, " "));
        }
    }
    return info;
}

fn readBody(ctx: *Ctx) ![]u8 {
    if (bodyLengthUnknown(ctx.req)) return &.{};
    var buf: [4096]u8 = undefined;
    const reader = try ctx.req.readerExpectContinue(&buf);
    return reader.allocRemaining(ctx.arena, .limited(max_body_len)) catch |err| switch (err) {
        error.StreamTooLong => return error.BodyTooLarge,
        else => return err,
    };
}

fn parseBody(comptime T: type, ctx: *Ctx) !T {
    const body = try readBody(ctx);
    if (body.len == 0) return error.EmptyBody;
    return std.json.parseFromSliceLeaky(T, ctx.arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
}

fn validateName(raw: []const u8) ![]const u8 {
    const name = std.mem.trim(u8, raw, " \t\r\n");
    if (name.len == 0) return error.EmptyName;
    if (name.len > max_member_name_len) return error.NameTooLong;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
    for (name) |c| if (std.ascii.isControl(c)) return error.InvalidName;
    return name;
}

/// True when the request method permits a body but the client sent neither
/// Content-Length nor Transfer-Encoding (e.g. `curl -X POST` with no data).
fn bodyLengthUnknown(req: *const http.Server.Request) bool {
    return req.head.method.requestHasBody() and
        req.head.content_length == null and
        req.head.transfer_encoding == .none;
}

fn handle(app: *App, req: *http.Server.Request, arena: Allocator) !void {
    // std.http.Server asserts a body-capable request declares its length when
    // it tries to discard the body on a keep-alive connection. Treat such a
    // request as body-less and close the connection after responding.
    if (bodyLengthUnknown(req)) req.head.keep_alive = false;
    // One connection is served at a time, so an idle keep-alive connection
    // would stall every other client until it closes. Answer and hang up.
    req.head.keep_alive = false;

    const info = try readHeaders(req, arena);
    var ctx: Ctx = .{
        .app = app,
        .arena = arena,
        .req = req,
        .info = info,
        .cors = .empty,
    };

    if (info.origin) |origin| {
        if (app.originAllowed(origin)) {
            try ctx.cors.appendSlice(arena, &.{
                .{ .name = "access-control-allow-origin", .value = origin },
                .{ .name = "vary", .value = "Origin" },
                .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
                .{ .name = "access-control-allow-headers", .value = "Content-Type, Authorization, X-Api-Key" },
                .{ .name = "access-control-max-age", .value = "86400" },
            });
        }
    }

    if (info.method == .OPTIONS) {
        // Preflight. Always answer 204; the CORS headers above decide whether
        // the browser lets the real request through.
        try req.respond("", .{ .status = .no_content, .extra_headers = ctx.cors.items });
        return;
    }

    const path = info.path;
    const is_get = info.method == .GET or info.method == .HEAD;

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/healthz")) {
        if (!is_get) return ctx.respondError(.method_not_allowed, "method not allowed");
        return ctx.respondText(.ok, "ok\n");
    }

    if (std.mem.eql(u8, path, "/api/state")) {
        if (!is_get) return ctx.respondError(.method_not_allowed, "method not allowed");
        const sys = selectSystem(app, info) orelse return ctx.respondError(.not_found, "no such group system");
        return ctx.respondJson(.ok, try stateView(arena, sys, app.roleFor(sys, info.api_key)));
    }

    // ── open: create a system ────────────────────────────────────────────
    if (std.mem.eql(u8, path, "/api/systems") and info.method == .POST) {
        const Body = struct { name: []const u8, passcode: ?[]const u8 = null };
        const body = parseBody(Body, &ctx) catch |err| return badRequest(&ctx, err);
        const name = validateName(body.name) catch |err| return badRequest(&ctx, err);
        var passcode: []const u8 = undefined;
        if (body.passcode) |p| {
            passcode = validatePasscode(p) catch |err| return badRequest(&ctx, err);
        } else passcode = try app.newPasscode(arena);
        if (app.store.items.len >= max_systems) return ctx.respondError(.unprocessable_entity, "too many group systems");
        const is_admin = app.authorized(info.api_key);
        if (!is_admin and !app.allowCreation()) return ctx.respondError(.too_many_requests, "too many new group systems right now; try again later");
        const id = try app.uniqueId(arena, name);
        const hash = hashPasscode(passcode);
        try persist.appendSystem(app.gpa, &app.store, id, name, &hash, app.now(), bg.BalancedGroupSystem.init(app.gpa));
        try app.save();
        log.info("created system {s} ({s}){s}", .{ id, name, if (is_admin) " [admin]" else "" });
        return ctx.respondJson(.created, .{
            .system = SystemRef{ .id = id, .name = name },
            .passcode = passcode,
            .systems = if (is_admin) try systemsView(arena, app) else null,
        });
    }

    // ── admin: list everything ───────────────────────────────────────────
    if (std.mem.eql(u8, path, "/api/systems")) {
        if (!is_get) return ctx.respondError(.method_not_allowed, "method not allowed");
        if (app.api_key == null) return ctx.respondError(.service_unavailable, "BG_API_KEY not configured");
        if (!app.authorized(info.api_key)) return ctx.respondError(.unauthorized, "invalid or missing API key");
        return ctx.respondJson(.ok, .{ .systems = try systemsView(arena, app) });
    }

    // ── everything else mutates one system: owner passcode or admin key ──
    const is_system_op = std.mem.eql(u8, path, "/api/systems/rename") or
        std.mem.eql(u8, path, "/api/systems/delete") or
        std.mem.eql(u8, path, "/api/systems/passcode");
    const is_mutation = is_system_op or
        std.mem.eql(u8, path, "/api/members") or
        std.mem.eql(u8, path, "/api/members/remove") or
        std.mem.eql(u8, path, "/api/rounds") or
        std.mem.eql(u8, path, "/api/rounds/manual") or
        std.mem.eql(u8, path, "/api/rounds/undo");
    if (!is_mutation) return ctx.respondError(.not_found, "not found");
    if (info.method != .POST) return ctx.respondError(.method_not_allowed, "method not allowed");

    if (is_system_op) {
        const Body = struct { id: []const u8, name: ?[]const u8 = null, passcode: ?[]const u8 = null };
        const body = parseBody(Body, &ctx) catch |err| return badRequest(&ctx, err);
        const sys = app.find(body.id) orelse return ctx.respondError(.not_found, "no such group system");
        const role = app.roleFor(sys, info.api_key);
        if (role == .none) return ctx.respondError(.unauthorized, if (sys.key_hash == null) "this group system can only be edited with the admin key" else "invalid or missing passcode");

        if (std.mem.eql(u8, path, "/api/systems/rename")) {
            const name = validateName(body.name orelse "") catch |err| return badRequest(&ctx, err);
            const new_name = try app.gpa.dupe(u8, name);
            app.gpa.free(sys.name);
            sys.name = new_name;
            try app.save();
            log.info("renamed system {s} to {s}", .{ sys.id, name });
            return ctx.respondJson(.ok, .{
                .system = SystemRef{ .id = sys.id, .name = sys.name },
                .systems = if (role == .admin) try systemsView(arena, app) else null,
            });
        }
        if (std.mem.eql(u8, path, "/api/systems/passcode")) {
            var passcode: []const u8 = undefined;
            if (body.passcode) |p| {
                passcode = validatePasscode(p) catch |err| return badRequest(&ctx, err);
            } else passcode = try app.newPasscode(arena);
            const hash = hashPasscode(passcode);
            try sys.setKeyHash(app.gpa, &hash);
            try app.save();
            log.info("new passcode for system {s}", .{sys.id});
            return ctx.respondJson(.ok, .{ .system = SystemRef{ .id = sys.id, .name = sys.name }, .passcode = passcode });
        }
        // delete
        if (app.store.items.len == 1) return ctx.respondError(.conflict, "cannot delete the only group system");
        const idx = (@intFromPtr(sys) - @intFromPtr(app.store.items.ptr)) / @sizeOf(persist.NamedSystem);
        var removed = app.store.orderedRemove(idx);
        log.info("deleted system {s} ({d} members, {d} rounds)", .{
            removed.id, removed.bgs.base.memberCount(), removed.bgs.base.group_history.items.len,
        });
        removed.deinit(app.gpa);
        try app.save();
        return ctx.respondJson(.ok, .{ .systems = if (role == .admin) try systemsView(arena, app) else null });
    }

    const sys = selectSystem(app, info) orelse return ctx.respondError(.not_found, "no such group system");
    const role = app.roleFor(sys, info.api_key);
    if (role == .none) return ctx.respondError(.unauthorized, if (sys.key_hash == null) "this group system can only be edited with the admin key" else "invalid or missing passcode");

    if (std.mem.eql(u8, path, "/api/members")) {
        const Body = struct { name: []const u8 };
        const body = parseBody(Body, &ctx) catch |err| return badRequest(&ctx, err);
        const name = validateName(body.name) catch |err| return badRequest(&ctx, err);
        if (sys.bgs.name_to_idx.contains(name)) return ctx.respondError(.conflict, "member already exists");
        if (sys.bgs.base.memberCount() >= max_members) return ctx.respondError(.unprocessable_entity, "too many members");
        try sys.bgs.addMember(name);
        try app.save();
        log.info("added member {s}", .{name});
        return ctx.respondJson(.created, .{ .state = try stateView(arena, sys, role) });
    }

    if (std.mem.eql(u8, path, "/api/members/remove")) {
        const Body = struct { name: []const u8 };
        const body = parseBody(Body, &ctx) catch |err| return badRequest(&ctx, err);
        const name = validateName(body.name) catch |err| return badRequest(&ctx, err);
        sys.bgs.removeMember(name) catch |err| switch (err) {
            error.MemberNotFound => return ctx.respondError(.not_found, "member not found"),
            else => return err,
        };
        try app.save();
        log.info("removed member {s}", .{name});
        return ctx.respondJson(.ok, .{ .state = try stateView(arena, sys, role) });
    }

    if (std.mem.eql(u8, path, "/api/rounds")) {
        const Body = struct { group_count: usize };
        const body = parseBody(Body, &ctx) catch |err| return badRequest(&ctx, err);
        const n = sys.bgs.base.memberCount();
        if (n == 0) return ctx.respondError(.unprocessable_entity, "add some members first");
        if (body.group_count == 0 or body.group_count > n) {
            return ctx.respondError(.unprocessable_entity, "group_count must be between 1 and the number of members");
        }
        var round = try sys.bgs.createBalancedGroups(body.group_count, app.prng.random());
        defer bg.freeRound(app.gpa, &round);
        try app.save();
        log.info("created round {d}: {d} groups of {d} members", .{ sys.bgs.base.group_history.items.len, body.group_count, n });
        return ctx.respondJson(.created, .{
            .round = RoundView{ .groups = round.items },
            .state = try stateView(arena, sys, role),
        });
    }

    if (std.mem.eql(u8, path, "/api/rounds/manual")) {
        const Body = struct { groups: []const []const []const u8, add_missing: bool = false };
        const body = parseBody(Body, &ctx) catch |err| return badRequest(&ctx, err);
        if (body.groups.len == 0) return ctx.respondError(.unprocessable_entity, "provide at least one group");

        // Normalise names, and check for empties/duplicates before mutating.
        var total: usize = 0;
        for (body.groups) |g| total += g.len;
        const clean = try arena.alloc([]const []const u8, body.groups.len);
        var seen = std.StringHashMap(void).init(arena);
        var unknown: std.ArrayList([]const u8) = .empty;
        for (body.groups, 0..) |g, gi| {
            if (g.len == 0) return ctx.respondError(.unprocessable_entity, "every group needs at least one name");
            const names = try arena.alloc([]const u8, g.len);
            for (g, 0..) |raw, ni| {
                const name = validateName(raw) catch |err| return badRequest(&ctx, err);
                if (seen.contains(name)) {
                    const msg = try std.fmt.allocPrint(arena, "{s} appears more than once", .{name});
                    return ctx.respondError(.unprocessable_entity, msg);
                }
                try seen.put(name, {});
                if (!sys.bgs.name_to_idx.contains(name)) try unknown.append(arena, name);
                names[ni] = name;
            }
            clean[gi] = names;
        }
        if (unknown.items.len > 0 and !body.add_missing) {
            return ctx.respondJson(.unprocessable_entity, .{
                .@"error" = "some names are not members yet",
                .unknown = unknown.items,
            });
        }
        if (sys.bgs.base.memberCount() + unknown.items.len > max_members) {
            return ctx.respondError(.unprocessable_entity, "too many members");
        }
        for (unknown.items) |name| try sys.bgs.addMember(name);
        sys.bgs.recordManualRound(clean) catch |err| switch (err) {
            // All three were ruled out above; anything else is a real failure.
            error.MemberNotFound, error.DuplicateMember, error.EmptyGroup => unreachable,
            else => return err,
        };
        try app.save();
        log.info("recorded manual round {d}: {d} groups, {d} members ({d} newly added)", .{
            sys.bgs.base.group_history.items.len, clean.len, total, unknown.items.len,
        });
        return ctx.respondJson(.created, .{
            .round = clean,
            .added = unknown.items,
            .state = try stateView(arena, sys, role),
        });
    }

    if (std.mem.eql(u8, path, "/api/rounds/undo")) {
        // Consume (and ignore) any body so the connection stays in sync.
        _ = readBody(&ctx) catch {};
        sys.bgs.undoLastRound() catch |err| switch (err) {
            error.NoRounds => return ctx.respondError(.conflict, "no rounds to undo"),
        };
        try app.save();
        log.info("undid last round; {d} rounds remain", .{sys.bgs.base.group_history.items.len});
        return ctx.respondJson(.ok, .{ .state = try stateView(arena, sys, role) });
    }

    unreachable;
}

/// The system named by `?system=`, or the first one when it is omitted.
fn selectSystem(app: *App, info: RequestInfo) ?*persist.NamedSystem {
    if (info.system) |id| return app.find(id);
    if (app.store.items.len == 0) return null;
    return &app.store.items[0];
}

fn badRequest(ctx: *Ctx, err: anyerror) !void {
    const msg: []const u8 = switch (err) {
        error.EmptyBody => "request body is required",
        error.InvalidJson => "request body is not valid JSON for this endpoint",
        error.BodyTooLarge => "request body too large",
        error.EmptyName => "name must not be empty",
        error.NameTooLong => "name is too long (max 64 bytes)",
        error.InvalidName => "name contains invalid characters",
        error.PasscodeTooShort => "passcode must be at least 8 characters",
        error.PasscodeTooLong => "passcode is too long (max 128 bytes)",
        error.InvalidPasscode => "passcode contains invalid characters",
        else => return err,
    };
    try ctx.respondError(.bad_request, msg);
}

fn serveConnection(app: *App, stream: Io.net.Stream) void {
    const io = app.io;
    defer stream.close(io);

    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var server = http.Server.init(&reader.interface, &writer.interface);

    while (server.reader.state == .ready) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                log.debug("receiveHead: {t}", .{err});
                return;
            },
        };

        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();

        handle(app, &req, arena_state.allocator()) catch |err| {
            log.err("{t} {s}: {t}", .{ req.head.method, req.head.target, err });
            // Best-effort error response; the connection is dropped afterwards.
            req.respond("{\"error\":\"internal server error\"}", .{
                .status = .internal_server_error,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch {};
            return;
        };
    }
}

// ── Configuration & entry point ───────────────────────────────────────────────

fn splitOrigins(gpa: Allocator, csv: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const o = std.mem.trim(u8, raw, " ");
        if (o.len > 0) try list.append(gpa, o);
    }
    return list.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const env = init.environ_map;

    const host = env.get("BG_HOST") orelse "127.0.0.1";
    const port_str = env.get("BG_PORT") orelse "8090";
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        log.err("BG_PORT must be a number between 1 and 65535, got {s}", .{port_str});
        return error.InvalidConfig;
    };
    const state_path = env.get("BG_STATE_PATH") orelse "state.json";
    const api_key_raw = env.get("BG_API_KEY");
    const api_key: ?[]const u8 = if (api_key_raw) |k| (if (k.len >= 16) k else null) else null;
    if (api_key_raw != null and api_key == null) {
        log.err("BG_API_KEY must be at least 16 characters; refusing to start", .{});
        return error.InvalidConfig;
    }
    if (api_key == null) log.warn("BG_API_KEY is not set: systems without a passcode cannot be edited and /api/systems is unavailable", .{});

    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .store = .empty,
        .state_path = state_path,
        .tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{state_path}),
        .api_key = api_key,
        .allowed_origins = try splitOrigins(gpa, env.get("BG_ALLOWED_ORIGINS") orelse default_origins),
        .prng = std.Random.DefaultPrng.init(seed),
    };
    defer persist.deinitStore(gpa, &app.store);
    defer gpa.free(app.tmp_path);
    defer gpa.free(app.allowed_origins);

    try app.load();
    if (app.store.items.len == 0) {
        try persist.appendSystem(gpa, &app.store, persist.legacy_system_id, persist.legacy_system_name, null, 0, bg.BalancedGroupSystem.init(gpa));
    }

    const addr = Io.net.IpAddress.parse(host, port) catch {
        log.err("BG_HOST is not a valid IP address: {s}", .{host});
        return error.InvalidConfig;
    };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    log.info("listening on {s}:{d}, state file {s}, origins: {s}", .{
        host, port, state_path, env.get("BG_ALLOWED_ORIGINS") orelse default_origins,
    });

    while (true) {
        const stream = server.accept(io) catch |err| {
            log.err("accept failed: {t}", .{err});
            continue;
        };
        serveConnection(&app, stream);
    }
}
