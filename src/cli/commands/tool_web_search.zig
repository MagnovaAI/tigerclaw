//! DuckDuckGo HTML search (no API key required).
//!
//! Hits https://html.duckduckgo.com/html/?q=<query>, parses the
//! result HTML for the top N entries, returns title/url/snippet.
//! DDG's class names drift roughly every 6-12 months; the parser is
//! pinned to current selectors and the fixture-based tests will go
//! red when the page format changes.

const std = @import("std");

pub const SearchError = error{
    QueryTooShort,
    HttpFailed,
    ParseFailed,
} || std.mem.Allocator.Error;

pub const SearchOptions = struct {
    query: []const u8,
    /// Optional list of substrings; only URLs containing one of these
    /// pass the filter (e.g. ["github.com", "ziglang.org"]).
    domain_filter: ?[]const []const u8 = null,
    /// Number of results to return; clamped [1, 20].
    count: u32 = 10,
};

pub const SearchResult = struct {
    title: []u8,
    url: []u8,
    snippet: []u8,

    pub fn deinit(self: SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.snippet);
    }
};

pub const SearchResponse = struct {
    results: []SearchResult,

    pub fn deinit(self: SearchResponse, allocator: std.mem.Allocator) void {
        for (self.results) |r| r.deinit(allocator);
        allocator.free(self.results);
    }
};

/// Cap on the response body size; DDG's HTML page is ~50 KB.
const MAX_BODY: usize = 256 * 1024;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: SearchOptions,
) SearchError!SearchResponse {
    if (opts.query.len < 2) return error.QueryTooShort;
    const count = std.math.clamp(opts.count, 1, 20);

    const html = fetchDdg(allocator, io, opts.query) catch return error.HttpFailed;
    defer allocator.free(html);

    const all_results = try parseDdgHtml(allocator, html);
    errdefer {
        for (all_results) |r| r.deinit(allocator);
        allocator.free(all_results);
    }

    const filtered = try filterByDomain(allocator, all_results, opts.domain_filter, count);
    return .{ .results = filtered };
}

// ---------------------------------------------------------------------------
// HTTP

fn fetchDdg(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
) ![]u8 {
    var url_buf: std.ArrayList(u8) = .empty;
    defer url_buf.deinit(allocator);
    try url_buf.appendSlice(allocator, "https://html.duckduckgo.com/html/?q=");
    try urlEncode(&url_buf, allocator, query);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const ua_header = std.http.Header{
        .name = "user-agent",
        .value = "Mozilla/5.0 (compatible; tigerclaw/0.1; +https://github.com/tigerclaw)",
    };

    const result = try client.fetch(.{
        .location = .{ .url = url_buf.items },
        .method = .GET,
        .response_writer = &body.writer,
        .extra_headers = &.{ua_header},
    });

    if (@intFromEnum(result.status) >= 400) return error.HttpFailed;

    const taken = body.toOwnedSlice() catch return error.OutOfMemory;
    if (taken.len > MAX_BODY) {
        // Trim. Keeping the parse cheap.
        const out = try allocator.alloc(u8, MAX_BODY);
        @memcpy(out, taken[0..MAX_BODY]);
        allocator.free(taken);
        return out;
    }
    return taken;
}

pub fn urlEncode(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (safe) {
            try out.append(allocator, c);
        } else {
            const hex = try std.fmt.allocPrint(allocator, "%{X:0>2}", .{c});
            defer allocator.free(hex);
            try out.appendSlice(allocator, hex);
        }
    }
}

// ---------------------------------------------------------------------------
// HTML parsing
//
// DDG's html.duckduckgo.com page format (as of 2026-04-25):
//   <a class="result__a" href="<URL>">title text</a>
//   ...
//   <a class="result__snippet">snippet text</a>

pub fn parseDdgHtml(allocator: std.mem.Allocator, html: []const u8) ![]SearchResult {
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(allocator);
        results.deinit(allocator);
    }

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, html, pos, "class=\"result__a\"")) |a_marker| {
        // Find the `href="..."` of this anchor — could be before or after the class attribute.
        const tag_start_search = std.mem.lastIndexOfScalar(u8, html[0..a_marker], '<') orelse {
            pos = a_marker + 1;
            continue;
        };
        const tag_end = std.mem.indexOfScalarPos(u8, html, a_marker, '>') orelse break;
        const tag_text = html[tag_start_search..tag_end];

        const href_marker = std.mem.indexOf(u8, tag_text, "href=\"") orelse {
            pos = tag_end + 1;
            continue;
        };
        const href_start = tag_start_search + href_marker + "href=\"".len;
        const href_end_rel = std.mem.indexOfScalarPos(u8, html, href_start, '"') orelse break;
        const url = html[href_start..href_end_rel];

        const title_text_end = std.mem.indexOfPos(u8, html, tag_end + 1, "</a>") orelse break;
        const title = html[tag_end + 1 .. title_text_end];

        // Snippet — search forward.
        var snippet: []const u8 = "";
        if (std.mem.indexOfPos(u8, html, title_text_end, "class=\"result__snippet\"")) |snippet_marker| {
            const snip_tag_end = std.mem.indexOfScalarPos(u8, html, snippet_marker, '>') orelse break;
            const snip_text_end = std.mem.indexOfPos(u8, html, snip_tag_end + 1, "</a>") orelse break;
            snippet = std.mem.trim(u8, html[snip_tag_end + 1 .. snip_text_end], " \t\n\r");
        }

        const title_text = stripTags(allocator, title) catch return error.OutOfMemory;
        errdefer allocator.free(title_text);
        const title_clean = htmlUnescape(allocator, title_text) catch return error.OutOfMemory;
        allocator.free(title_text);
        errdefer allocator.free(title_clean);

        const real_url = unwrapDdgRedirect(allocator, url) catch return error.OutOfMemory;
        errdefer allocator.free(real_url);

        const snippet_text = stripTags(allocator, snippet) catch return error.OutOfMemory;
        errdefer allocator.free(snippet_text);
        const snippet_clean = htmlUnescape(allocator, snippet_text) catch return error.OutOfMemory;
        allocator.free(snippet_text);

        try results.append(allocator, .{
            .title = title_clean,
            .url = real_url,
            .snippet = snippet_clean,
        });

        pos = title_text_end;
    }

    if (results.items.len == 0) return error.ParseFailed;
    return results.toOwnedSlice(allocator);
}

/// DDG wraps real URLs as `//duckduckgo.com/l/?uddg=<encoded-url>&...`
fn unwrapDdgRedirect(allocator: std.mem.Allocator, wrapped: []const u8) ![]u8 {
    const tag = "//duckduckgo.com/l/?uddg=";
    if (std.mem.startsWith(u8, wrapped, tag)) {
        const start = tag.len;
        const end = std.mem.indexOfScalarPos(u8, wrapped, start, '&') orelse wrapped.len;
        return urlDecode(allocator, wrapped[start..end]);
    }
    // Some links are also relative to https://...
    return allocator.dupe(u8, wrapped);
}

fn urlDecode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const byte = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, s[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, byte);
            i += 3;
        } else if (s[i] == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Drop `<...>` tags from a snippet/title. DDG sometimes wraps the
/// matched query terms in `<b>` highlights.
fn stripTags(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_tag = false;
    for (s) |c| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (!in_tag) try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

pub fn htmlUnescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "&#39;")) {
                try out.append(allocator, '\'');
                i += 5;
                continue;
            }
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn filterByDomain(
    allocator: std.mem.Allocator,
    results: []SearchResult,
    filters: ?[]const []const u8,
    count: u32,
) ![]SearchResult {
    var kept: std.ArrayList(SearchResult) = .empty;
    errdefer {
        for (kept.items) |r| r.deinit(allocator);
        kept.deinit(allocator);
    }
    for (results) |r| {
        if (kept.items.len >= count) {
            r.deinit(allocator);
            continue;
        }
        if (filters) |list| {
            var matches = false;
            for (list) |dom| {
                if (std.mem.indexOf(u8, r.url, dom) != null) {
                    matches = true;
                    break;
                }
            }
            if (!matches) {
                r.deinit(allocator);
                continue;
            }
        }
        try kept.append(allocator, r);
    }
    allocator.free(results);
    return kept.toOwnedSlice(allocator);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "urlEncode: spaces become %20" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try urlEncode(&buf, testing.allocator, "zig 0.16");
    try testing.expectEqualStrings("zig%200.16", buf.items);
}

test "urlEncode: special chars escaped" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try urlEncode(&buf, testing.allocator, "a&b=c");
    try testing.expectEqualStrings("a%26b%3Dc", buf.items);
}

test "htmlUnescape: common entities" {
    const out = try htmlUnescape(testing.allocator, "a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#39;");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a & b <c> \"d\" 'e'", out);
}

test "stripTags: removes <b>highlights</b>" {
    const out = try stripTags(testing.allocator, "match <b>zig</b> here");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("match zig here", out);
}

test "unwrapDdgRedirect: extracts real URL from /l/?uddg=" {
    const out = try unwrapDdgRedirect(testing.allocator, "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com&rut=...");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("https://example.com", out);
}

test "unwrapDdgRedirect: passthrough for direct URLs" {
    const out = try unwrapDdgRedirect(testing.allocator, "https://example.com");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("https://example.com", out);
}

test "parseDdgHtml: minimal fixture" {
    const html =
        "<div>" ++
        "<a class=\"result__a\" href=\"//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org&rut=x\">Zig <b>Programming</b> Language</a>" ++
        "<a class=\"result__snippet\" href=\"#\">A general-purpose language.</a>" ++
        "</div>";
    const results = try parseDdgHtml(testing.allocator, html);
    defer {
        for (results) |r| r.deinit(testing.allocator);
        testing.allocator.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("Zig Programming Language", results[0].title);
    try testing.expectEqualStrings("https://ziglang.org", results[0].url);
    try testing.expectEqualStrings("A general-purpose language.", results[0].snippet);
}

test "filterByDomain: only github.com kept" {
    const a = SearchResult{
        .title = try testing.allocator.dupe(u8, "x"),
        .url = try testing.allocator.dupe(u8, "https://example.com/page"),
        .snippet = try testing.allocator.dupe(u8, "y"),
    };
    const b = SearchResult{
        .title = try testing.allocator.dupe(u8, "x"),
        .url = try testing.allocator.dupe(u8, "https://github.com/foo"),
        .snippet = try testing.allocator.dupe(u8, "y"),
    };
    const slice = try testing.allocator.alloc(SearchResult, 2);
    slice[0] = a;
    slice[1] = b;
    const filters = [_][]const u8{"github.com"};
    const kept = try filterByDomain(testing.allocator, slice, &filters, 10);
    defer {
        for (kept) |r| r.deinit(testing.allocator);
        testing.allocator.free(kept);
    }
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expect(std.mem.indexOf(u8, kept[0].url, "github.com") != null);
}
