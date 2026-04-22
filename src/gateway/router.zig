//! HTTP router — pure pattern matching, no IO.
//!
//! A `Route` names an HTTP method, a path pattern, and a tag the caller
//! uses to dispatch. Patterns support three element kinds:
//!
//!   - literal segments (e.g. `/sessions`)
//!   - typed parameters (e.g. `/sessions/:id`) that match one segment
//!     and are returned in `Match.params`
//!   - a trailing wildcard (`/sessions/:id/*`) that captures the rest
//!     of the path into `Match.tail`
//!
//! The router is deliberately allocation-free on the hot path: matching
//! walks the incoming target segment-by-segment and stores up to
//! `max_params` name/value pairs in a caller-provided buffer. The
//! `resolve` helper accepts a route table and returns the first match
//! or an explicit `NoMatch`/`MethodNotAllowed` result so the caller
//! can emit the right status code.

const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,

    pub fn parse(text: []const u8) ?Method {
        return std.meta.stringToEnum(Method, text);
    }
};

pub const max_params = 8;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const Route = struct {
    method: Method,
    pattern: []const u8,
    /// Caller-chosen tag. Using a string keeps the router generic; the
    /// dispatch layer maps this to a typed handler via a switch.
    tag: []const u8,
};

pub const Match = struct {
    route: *const Route,
    params: []const Param,
    tail: ?[]const u8,
};

pub const Resolved = union(enum) {
    match: Match,
    method_not_allowed: struct {
        /// Methods that *are* defined for the matched path. Useful
        /// when the caller wants to emit an `Allow:` response header.
        allowed: [5]?Method,
        allowed_count: u3,
    },
    no_match,
};

pub const MatchError = error{TooManyParams};

/// Try to match a single route against `target`. Fills `params_buffer`
/// up to `max_params` entries. Returns an empty slice when the pattern
/// has no parameters.
pub fn matchRoute(
    route: Route,
    target: []const u8,
    params_buffer: []Param,
) MatchError!?Match {
    // Strip an optional query string.
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..path_end];

    if (path.len == 0 or path[0] != '/') return null;
    if (route.pattern.len == 0 or route.pattern[0] != '/') return null;

    var target_it = std.mem.splitScalar(u8, path[1..], '/');
    var pattern_it = std.mem.splitScalar(u8, route.pattern[1..], '/');

    var param_count: usize = 0;
    var tail: ?[]const u8 = null;

    while (true) {
        const maybe_pattern = pattern_it.next();
        const maybe_target = target_it.next();

        if (maybe_pattern == null and maybe_target == null) break;

        // Pattern exhausted but target has more → not a match (unless
        // the last pattern element was a wildcard, which is handled
        // below before we loop).
        if (maybe_pattern == null) return null;
        const p = maybe_pattern.?;

        // Wildcard absorbs the remainder of the target.
        if (std.mem.eql(u8, p, "*")) {
            if (pattern_it.next() != null) return null; // `*` must be last
            const rem = target_it.rest();
            if (maybe_target) |first_seg| {
                tail = if (rem.len == 0)
                    first_seg
                else
                    // splitScalar left us positioned at the end of
                    // `first_seg`; we want `first_seg/rem` joined with
                    // a single `/`, which is what lives at
                    // `path[match_offset..]`. The simplest correct
                    // recovery is to walk the original `path` backwards
                    // to the start of `first_seg` so we capture the
                    // full remainder verbatim.
                    path[indexOfSegStart(path, first_seg)..];
            } else {
                tail = "";
            }
            break;
        }

        if (maybe_target == null) {
            // Trailing empty segment ("/foo/") — treat as no match
            // unless pattern also ended with an empty segment.
            return null;
        }
        const t = maybe_target.?;

        if (p.len > 1 and p[0] == ':') {
            if (param_count >= params_buffer.len) return error.TooManyParams;
            params_buffer[param_count] = .{ .name = p[1..], .value = t };
            param_count += 1;
            continue;
        }

        if (!std.mem.eql(u8, p, t)) return null;
    }

    return .{
        .route = undefined, // overwritten by `resolve` below
        .params = params_buffer[0..param_count],
        .tail = tail,
    };
}

// Given a path like "/a/b/c" and the substring "b" (known to live at
// some segment boundary), return the offset of the leading '/' before
// it. Caller guarantees `seg` is a byte-slice within `path` produced
// by `splitScalar`.
fn indexOfSegStart(path: []const u8, seg: []const u8) usize {
    const seg_ptr = @intFromPtr(seg.ptr);
    const path_ptr = @intFromPtr(path.ptr);
    std.debug.assert(seg_ptr >= path_ptr);
    const offset = seg_ptr - path_ptr;
    std.debug.assert(offset > 0 and path[offset - 1] == '/');
    return offset - 1;
}

/// Walk `routes` and return the first match. If one or more routes
/// match the path but none match the method, returns `method_not_allowed`
/// with the list of methods that *would* match. Otherwise `no_match`.
pub fn resolve(
    routes: []const Route,
    method: Method,
    target: []const u8,
    params_buffer: []Param,
) MatchError!Resolved {
    var allowed: [5]?Method = [_]?Method{null} ** 5;
    var allowed_count: u3 = 0;
    var saw_path_match_wrong_method = false;

    for (routes) |*route| {
        // Param buffer is reused across routes; a non-matching route
        // leaves no observable state behind.
        const maybe_match = try matchRoute(route.*, target, params_buffer);
        const m = maybe_match orelse continue;

        if (route.method == method) {
            return .{ .match = .{
                .route = route,
                .params = m.params,
                .tail = m.tail,
            } };
        }

        saw_path_match_wrong_method = true;
        if (allowed_count < allowed.len) {
            // Avoid listing a method twice.
            var already = false;
            for (allowed[0..allowed_count]) |existing| {
                if (existing == route.method) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                allowed[allowed_count] = route.method;
                allowed_count += 1;
            }
        }
    }

    if (saw_path_match_wrong_method) {
        return .{ .method_not_allowed = .{
            .allowed = allowed,
            .allowed_count = allowed_count,
        } };
    }
    return .no_match;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const routes_fixture = [_]Route{
    .{ .method = .GET, .pattern = "/health", .tag = "health" },
    .{ .method = .GET, .pattern = "/sessions", .tag = "sessions.list" },
    .{ .method = .POST, .pattern = "/sessions", .tag = "sessions.create" },
    .{ .method = .GET, .pattern = "/sessions/:id", .tag = "sessions.get" },
    .{ .method = .DELETE, .pattern = "/sessions/:id", .tag = "sessions.delete" },
    .{ .method = .POST, .pattern = "/sessions/:id/messages", .tag = "sessions.message" },
    .{ .method = .POST, .pattern = "/sessions/:id/turns", .tag = "sessions.turn" },
    .{ .method = .GET, .pattern = "/static/*", .tag = "static" },
};

test "resolve: literal route matches" {
    var params: [max_params]Param = undefined;
    const r = try resolve(&routes_fixture, .GET, "/health", &params);
    try testing.expect(r == .match);
    try testing.expectEqualStrings("health", r.match.route.tag);
    try testing.expectEqual(@as(usize, 0), r.match.params.len);
}

test "resolve: same path, method overload (GET vs POST /sessions)" {
    var params: [max_params]Param = undefined;
    const r1 = try resolve(&routes_fixture, .GET, "/sessions", &params);
    try testing.expectEqualStrings("sessions.list", r1.match.route.tag);

    const r2 = try resolve(&routes_fixture, .POST, "/sessions", &params);
    try testing.expectEqualStrings("sessions.create", r2.match.route.tag);
}

test "resolve: typed param is captured by name" {
    var params: [max_params]Param = undefined;
    const r = try resolve(&routes_fixture, .GET, "/sessions/abc-123", &params);
    try testing.expectEqualStrings("sessions.get", r.match.route.tag);
    try testing.expectEqual(@as(usize, 1), r.match.params.len);
    try testing.expectEqualStrings("id", r.match.params[0].name);
    try testing.expectEqualStrings("abc-123", r.match.params[0].value);
}

test "resolve: nested path with typed param" {
    var params: [max_params]Param = undefined;
    const r = try resolve(&routes_fixture, .POST, "/sessions/xyz/messages", &params);
    try testing.expectEqualStrings("sessions.message", r.match.route.tag);
    try testing.expectEqualStrings("xyz", r.match.params[0].value);
}

test "resolve: wildcard captures the remainder into tail" {
    var params: [max_params]Param = undefined;
    const r = try resolve(&routes_fixture, .GET, "/static/css/main.css", &params);
    try testing.expectEqualStrings("static", r.match.route.tag);
    try testing.expect(r.match.tail != null);
    try testing.expectEqualStrings("/css/main.css", r.match.tail.?);
}

test "resolve: unknown path → no_match" {
    var params: [max_params]Param = undefined;
    const r = try resolve(&routes_fixture, .GET, "/missing", &params);
    try testing.expect(r == .no_match);
}

test "resolve: wrong method on known path → method_not_allowed with Allow list" {
    var params: [max_params]Param = undefined;
    const r = try resolve(&routes_fixture, .DELETE, "/sessions", &params);
    try testing.expect(r == .method_not_allowed);
    try testing.expectEqual(@as(u3, 2), r.method_not_allowed.allowed_count);
    // Order follows the table: GET appears before POST.
    try testing.expectEqual(Method.GET, r.method_not_allowed.allowed[0].?);
    try testing.expectEqual(Method.POST, r.method_not_allowed.allowed[1].?);
}

test "resolve: query string is ignored for matching" {
    var params: [max_params]Param = undefined;
    const r = try resolve(&routes_fixture, .GET, "/sessions/abc?follow=true", &params);
    try testing.expectEqualStrings("sessions.get", r.match.route.tag);
    try testing.expectEqualStrings("abc", r.match.params[0].value);
}

test "resolve: trailing slash mismatch does not match a literal route" {
    var params: [max_params]Param = undefined;
    const r = try resolve(&routes_fixture, .GET, "/health/", &params);
    try testing.expect(r == .no_match);
}

test "Method.parse: canonical names" {
    try testing.expectEqual(Method.GET, Method.parse("GET").?);
    try testing.expectEqual(Method.POST, Method.parse("POST").?);
    try testing.expectEqual(Method.DELETE, Method.parse("DELETE").?);
    try testing.expect(Method.parse("GARBAGE") == null);
}

test "matchRoute: too many params returns TooManyParams" {
    // Build a synthetic many-param route.
    const long_route: Route = .{
        .method = .GET,
        .pattern = "/:a/:b/:c",
        .tag = "many",
    };
    var small: [2]Param = undefined;
    try testing.expectError(
        error.TooManyParams,
        matchRoute(long_route, "/1/2/3", &small),
    );
}
