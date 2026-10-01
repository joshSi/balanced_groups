//! HTTP API server for balanced_groups.
//!
//! Keeps one `BalancedGroupSystem` in memory, persists it as JSON on every
//! mutation, and exposes it over a small JSON API consumed by joshsi.com.
//!
//! Configuration (environment variables):
//!
//!   BG_HOST             bind address            (default 127.0.0.1)
//!   BG_PORT             bind port               (default 8090)
//!   BG_STATE_PATH       JSON state file         (default ./state.json)
//!   BG_API_KEY          required for all POST requests; if unset, writes are
//!                       rejected with 503 so the service is read-only
//!   BG_ALLOWED_ORIGINS  comma-separated CORS allow-list
//!                       (default https://joshsi.com,https://www.joshsi.com,
//!                                https://joshsi.github.io)
//!
//! Endpoints:
//!
//!   GET  /healthz                      -> "ok"
//!   GET  /api/state                    -> { members, familiarity, history }
//!   POST /api/members        {name}    -> add a member
//!   POST /api/members/remove {name}    -> remove a member
//!   POST /api/rounds   {group_count}   -> create a round, returns {round, state}
//!   POST /api/rounds/manual {groups, add_missing?}
//!                                      -> record groups formed elsewhere
//!   POST /api/rounds/undo              -> revert the most recent round
//!
//! Every POST requires `Authorization: Bearer <BG_API_KEY>` (or `X-Api-Key`).
//! Every mutating response includes the full updated state so the client can
//! re-render without a second request.

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

const App = struct {
    gpa: Allocator,
    io: Io,
    bgs: bg.BalancedGroupSystem,
    state_path: []const u8,
    tmp_path: []const u8,
    api_key: ?[]const u8,
    allowed_origins: []const []const u8,
    prng: std.Random.DefaultPrng,

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
        var loaded = persist.fromJson(self.gpa, bytes) catch |err| {
            log.err("state file {s} could not be loaded ({t}); refusing to start so it is not overwritten", .{ self.state_path, err });
            return error.CorruptStateFile;
        };
        self.bgs.deinit();
        self.bgs = loaded;
        loaded = undefined;
        log.info("loaded {d} members, {d} rounds from {s}", .{
            self.bgs.base.memberCount(),
            self.bgs.base.group_history.items.len,
            self.state_path,
        });
    }

    /// Atomically persist: write to a temp file, fsync, rename over the target.
    fn save(self: *App) !void {
        const json = try persist.toJson(self.gpa, &self.bgs);
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
    members: []const []const u8,
    familiarity: []const []const u32,
    history: HistoryView,
    rounds: usize,

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

fn stateView(arena: Allocator, bgs: *const bg.BalancedGroupSystem) !StateView {
    const n = bgs.base.memberCount();
    const rows = try arena.alloc([]const u32, n);
    for (rows, 0..) |*row, i| {
        const r = try arena.alloc(u32, n);
        for (r, 0..) |*cell, j| cell.* = bgs.getFam(i, j);
        row.* = r;
    }
    return .{
        .members = @ptrCast(bgs.base.members.items),
        .familiarity = rows,
        .history = .{ .rounds = bgs.base.group_history.items },
        .rounds = bgs.base.group_history.items.len,
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
        .origin = null,
        .api_key = null,
    };
    // Drop query string.
    if (std.mem.indexOfScalar(u8, info.path, '?')) |q| info.path = info.path[0..q];
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
        return ctx.respondJson(.ok, try stateView(arena, &app.bgs));
    }

    // Everything below mutates state.
    const is_mutation = std.mem.eql(u8, path, "/api/members") or
        std.mem.eql(u8, path, "/api/members/remove") or
        std.mem.eql(u8, path, "/api/rounds") or
        std.mem.eql(u8, path, "/api/rounds/manual") or
        std.mem.eql(u8, path, "/api/rounds/undo");
    if (!is_mutation) return ctx.respondError(.not_found, "not found");
    if (info.method != .POST) return ctx.respondError(.method_not_allowed, "method not allowed");
    if (app.api_key == null) return ctx.respondError(.service_unavailable, "server is read-only: BG_API_KEY not configured");
    if (!app.authorized(info.api_key)) return ctx.respondError(.unauthorized, "invalid or missing API key");

    if (std.mem.eql(u8, path, "/api/members")) {
        const Body = struct { name: []const u8 };
        const body = parseBody(Body, &ctx) catch |err| return badRequest(&ctx, err);
        const name = validateName(body.name) catch |err| return badRequest(&ctx, err);
        if (app.bgs.name_to_idx.contains(name)) return ctx.respondError(.conflict, "member already exists");
        if (app.bgs.base.memberCount() >= max_members) return ctx.respondError(.unprocessable_entity, "too many members");
        try app.bgs.addMember(name);
        try app.save();
        log.info("added member {s}", .{name});
        return ctx.respondJson(.created, .{ .state = try stateView(arena, &app.bgs) });
    }

    if (std.mem.eql(u8, path, "/api/members/remove")) {
        const Body = struct { name: []const u8 };
        const body = parseBody(Body, &ctx) catch |err| return badRequest(&ctx, err);
        const name = validateName(body.name) catch |err| return badRequest(&ctx, err);
        app.bgs.removeMember(name) catch |err| switch (err) {
            error.MemberNotFound => return ctx.respondError(.not_found, "member not found"),
            else => return err,
        };
        try app.save();
        log.info("removed member {s}", .{name});
        return ctx.respondJson(.ok, .{ .state = try stateView(arena, &app.bgs) });
    }

    if (std.mem.eql(u8, path, "/api/rounds")) {
        const Body = struct { group_count: usize };
        const body = parseBody(Body, &ctx) catch |err| return badRequest(&ctx, err);
        const n = app.bgs.base.memberCount();
        if (n == 0) return ctx.respondError(.unprocessable_entity, "add some members first");
        if (body.group_count == 0 or body.group_count > n) {
            return ctx.respondError(.unprocessable_entity, "group_count must be between 1 and the number of members");
        }
        var round = try app.bgs.createBalancedGroups(body.group_count, app.prng.random());
        defer bg.freeRound(app.gpa, &round);
        try app.save();
        log.info("created round {d}: {d} groups of {d} members", .{ app.bgs.base.group_history.items.len, body.group_count, n });
        return ctx.respondJson(.created, .{
            .round = RoundView{ .groups = round.items },
            .state = try stateView(arena, &app.bgs),
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
                if (!app.bgs.name_to_idx.contains(name)) try unknown.append(arena, name);
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
        if (app.bgs.base.memberCount() + unknown.items.len > max_members) {
            return ctx.respondError(.unprocessable_entity, "too many members");
        }
        for (unknown.items) |name| try app.bgs.addMember(name);
        app.bgs.recordManualRound(clean) catch |err| switch (err) {
            // All three were ruled out above; anything else is a real failure.
            error.MemberNotFound, error.DuplicateMember, error.EmptyGroup => unreachable,
            else => return err,
        };
        try app.save();
        log.info("recorded manual round {d}: {d} groups, {d} members ({d} newly added)", .{
            app.bgs.base.group_history.items.len, clean.len, total, unknown.items.len,
        });
        return ctx.respondJson(.created, .{
            .round = clean,
            .added = unknown.items,
            .state = try stateView(arena, &app.bgs),
        });
    }

    if (std.mem.eql(u8, path, "/api/rounds/undo")) {
        // Consume (and ignore) any body so the connection stays in sync.
        _ = readBody(&ctx) catch {};
        app.bgs.undoLastRound() catch |err| switch (err) {
            error.NoRounds => return ctx.respondError(.conflict, "no rounds to undo"),
        };
        try app.save();
        log.info("undid last round; {d} rounds remain", .{app.bgs.base.group_history.items.len});
        return ctx.respondJson(.ok, .{ .state = try stateView(arena, &app.bgs) });
    }

    unreachable;
}

fn badRequest(ctx: *Ctx, err: anyerror) !void {
    const msg: []const u8 = switch (err) {
        error.EmptyBody => "request body is required",
        error.InvalidJson => "request body is not valid JSON for this endpoint",
        error.BodyTooLarge => "request body too large",
        error.EmptyName => "name must not be empty",
        error.NameTooLong => "name is too long (max 64 bytes)",
        error.InvalidName => "name contains invalid characters",
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
    if (api_key == null) log.warn("BG_API_KEY is not set: the API is read-only", .{});

    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .bgs = bg.BalancedGroupSystem.init(gpa),
        .state_path = state_path,
        .tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{state_path}),
        .api_key = api_key,
        .allowed_origins = try splitOrigins(gpa, env.get("BG_ALLOWED_ORIGINS") orelse default_origins),
        .prng = std.Random.DefaultPrng.init(seed),
    };
    defer app.bgs.deinit();
    defer gpa.free(app.tmp_path);
    defer gpa.free(app.allowed_origins);

    try app.load();

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
