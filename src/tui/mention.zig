//! `@mention` parser for the chat input.
//!
//! Recognises a single leading `@<name>` at the start of a typed
//! message and returns the matched name plus the body with the
//! mention stripped. Whitespace between the mention and the body
//! is consumed.
//!
//! Examples:
//!   "@sage hi"        → { target = "sage", body = "hi" }
//!   "  @bolt fix it"  → { target = "bolt", body = "fix it" }
//!   "@tiger"          → { target = "tiger", body = "" }
//!   "no mention here" → { target = null, body = "no mention here" }
//!   "email@x.com"     → { target = null, body = "email@x.com" } (mid-message)
//!
//! Multi-mention is intentionally not parsed at this layer — Part 2
//! of the routing plan defers that. We surface the *first* mention
//! only; additional `@names` fall through into the body verbatim.
//!
//! Names follow the Unix-shell-friendly subset already used by
//! `~/.tigerclaw/agents/<name>/`: ASCII letters, digits, `-`, `_`.
//! Anything else terminates the name. A bare `@` with no name is
//! treated as no mention.

const std = @import("std");

pub const Parsed = struct {
    /// Slice into `input` covering the mention name (without the
    /// leading `@`). Null when the input has no leading mention.
    target: ?[]const u8,
    /// The remainder of `input` after stripping the mention and
    /// any whitespace separating it from the body. Always non-null;
    /// equals `input` (verbatim) when there's no mention.
    body: []const u8,
};

/// One `@<name>` occurrence inside arbitrary text. Used by the
/// auto-dispatch path that scans an agent's full reply for
/// cross-agent invocations after the turn completes.
pub const Match = struct {
    /// Name (without the leading `@`), borrowed from `text`.
    name: []const u8,
};

pub fn parse(input: []const u8) Parsed {
    // Skip leading whitespace so `"  @sage hi"` parses the same
    // as `"@sage hi"`. People paste with leading spaces.
    var i: usize = 0;
    while (i < input.len and isSpace(input[i])) i += 1;

    if (i >= input.len or input[i] != '@') {
        return .{ .target = null, .body = input };
    }

    const name_start = i + 1; // skip the `@`
    var j = name_start;
    while (j < input.len and isNameChar(input[j])) j += 1;

    // Bare `@` (no name char after) is not a mention.
    if (j == name_start) return .{ .target = null, .body = input };

    const name = input[name_start..j];

    // Advance past whitespace between the name and the body. If
    // the next char is non-space and non-end, the `@name` was
    // actually inline (e.g. `@sage,hello` has no separator); we
    // still treat the name as the target and the rest as body
    // — feels nicer than refusing to route.
    var body_start = j;
    while (body_start < input.len and isSpace(input[body_start])) body_start += 1;

    return .{ .target = name, .body = input[body_start..] };
}

/// Scan `text` for every `@<name>` occurrence whose name appears in
/// `known` (case-insensitive). De-duplicated: each known name shows
/// up at most once in the result, in the order of first occurrence.
/// Self-mentions (where `name == invoker`) are skipped — an agent
/// referring to itself shouldn't trigger a sub-turn.
///
/// Two structural exclusions prevent the auto-dispatch loop from
/// re-triggering on its own output:
///
///   - Content inside fenced code blocks (``` ... ```) is skipped.
///     Models routinely paste shell snippets and config that contain
///     `@email`-style strings; those are not dispatch requests.
///   - Lines whose first non-whitespace token is `@<known>` followed
///     by `:` (the synthetic resume-header format used by the
///     auto-dispatch state machine) are skipped entirely. Without
///     this, an agent quoting back its sub-turn replies — verbatim
///     or with light editorializing — would re-trigger fan-out and
///     burn the dispatch budget on a feedback loop.
///
/// Caller owns the returned slice (allocated from `gpa`); free with
/// `gpa.free(result)`. Each `Match.name` is borrowed from `text`
/// and lives as long as `text` does.
pub fn findAll(
    gpa: std.mem.Allocator,
    text: []const u8,
    known: []const []const u8,
    invoker: []const u8,
) std.mem.Allocator.Error![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(gpa);

    var in_fence = false;
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |line| {
        if (isFenceLine(line)) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        if (isSyntheticHeaderLine(line, known)) continue;

        try scanLine(gpa, &out, line, known, invoker);
    }

    return out.toOwnedSlice(gpa);
}

/// True when `line` (after stripping leading whitespace) starts with
/// three or more backticks. Matches the CommonMark fenced-code-block
/// rule loosely enough for our needs: we don't care about info
/// strings or the closing fence's length matching.
fn isFenceLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and isSpace(line[i])) i += 1;
    if (i + 2 >= line.len) return false;
    return line[i] == '`' and line[i + 1] == '`' and line[i + 2] == '`';
}

/// True when `line` looks like a synthetic resume header — `@<known>`
/// followed by `:` as the first non-whitespace token. The colon is
/// what distinguishes a header (`@sage replied:`) from a normal
/// inline mention (`I'll defer to @sage on this`).
fn isSyntheticHeaderLine(line: []const u8, known: []const []const u8) bool {
    var i: usize = 0;
    while (i < line.len and isSpace(line[i])) i += 1;
    if (i >= line.len or line[i] != '@') return false;
    const name_start = i + 1;
    var j = name_start;
    while (j < line.len and isNameChar(line[j])) j += 1;
    if (j == name_start) return false;
    const name = line[name_start..j];

    // Must match a known agent — otherwise an unrelated `@foo:`
    // shouldn't suppress an actual mention later in the line.
    var matched = false;
    for (known) |k| {
        if (std.ascii.eqlIgnoreCase(k, name)) {
            matched = true;
            break;
        }
    }
    if (!matched) return false;

    // Header marker: optionally a single token like `replied`, then
    // `:`. We accept both `@sage:` and `@sage replied:` since the
    // resume body uses the latter; either shape signals a quote
    // rather than a dispatch.
    while (j < line.len and isSpace(line[j])) j += 1;
    if (j < line.len and line[j] == ':') return true;
    // Allow one bare alphabetic word (e.g. `replied`) before the colon.
    var k2 = j;
    while (k2 < line.len and isAlpha(line[k2])) k2 += 1;
    if (k2 == j) return false;
    while (k2 < line.len and isSpace(line[k2])) k2 += 1;
    return k2 < line.len and line[k2] == ':';
}

fn scanLine(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Match),
    line: []const u8,
    known: []const []const u8,
    invoker: []const u8,
) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < line.len) {
        const at_pos = std.mem.indexOfScalarPos(u8, line, i, '@') orelse break;

        // Reject mid-token `@`. The character before must be
        // whitespace, punctuation, or start-of-line — otherwise
        // it's an email/handle inside other text and we ignore.
        const at_is_word_start = at_pos == 0 or !isNameChar(line[at_pos - 1]);
        if (!at_is_word_start) {
            i = at_pos + 1;
            continue;
        }

        var j = at_pos + 1;
        while (j < line.len and isNameChar(line[j])) j += 1;
        if (j == at_pos + 1) {
            i = at_pos + 1;
            continue;
        }

        const name = line[at_pos + 1 .. j];
        i = j;

        if (std.ascii.eqlIgnoreCase(name, invoker)) continue;

        var resolved: ?[]const u8 = null;
        for (known) |k| {
            if (std.ascii.eqlIgnoreCase(k, name)) {
                resolved = k;
                break;
            }
        }
        const r = resolved orelse continue;

        var seen = false;
        for (out.items) |m| {
            if (std.ascii.eqlIgnoreCase(m.name, r)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        try out.append(gpa, .{ .name = r });
    }
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_';
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: leading mention with body" {
    const r = parse("@sage hi");
    try testing.expectEqualStrings("sage", r.target.?);
    try testing.expectEqualStrings("hi", r.body);
}

test "parse: no mention" {
    const r = parse("hi there");
    try testing.expect(r.target == null);
    try testing.expectEqualStrings("hi there", r.body);
}

test "parse: leading whitespace tolerated" {
    const r = parse("  \t@bolt fix it");
    try testing.expectEqualStrings("bolt", r.target.?);
    try testing.expectEqualStrings("fix it", r.body);
}

test "parse: mid-message @ ignored" {
    const r = parse("ping email@x.com please");
    try testing.expect(r.target == null);
    try testing.expectEqualStrings("ping email@x.com please", r.body);
}

test "parse: bare mention without body" {
    const r = parse("@tiger");
    try testing.expectEqualStrings("tiger", r.target.?);
    try testing.expectEqualStrings("", r.body);
}

test "parse: bare @ with no name" {
    const r = parse("@ hi");
    try testing.expect(r.target == null);
    try testing.expectEqualStrings("@ hi", r.body);
}

test "parse: name with hyphen and underscore" {
    const r = parse("@my_agent-2 do x");
    try testing.expectEqualStrings("my_agent-2", r.target.?);
    try testing.expectEqualStrings("do x", r.body);
}

test "parse: punctuation right after name treats name as target" {
    const r = parse("@sage,hello");
    try testing.expectEqualStrings("sage", r.target.?);
    try testing.expectEqualStrings(",hello", r.body);
}

test "parse: empty input" {
    const r = parse("");
    try testing.expect(r.target == null);
    try testing.expectEqualStrings("", r.body);
}

const known_set = [_][]const u8{ "tiger", "sage", "bolt" };

test "findAll: one mention" {
    const ms = try findAll(testing.allocator, "let's ask @sage what they think", &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expectEqualStrings("sage", ms[0].name);
}

test "findAll: two mentions in one reply" {
    const ms = try findAll(testing.allocator, "let me check with @sage and @bolt about this", &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 2), ms.len);
    try testing.expectEqualStrings("sage", ms[0].name);
    try testing.expectEqualStrings("bolt", ms[1].name);
}

test "findAll: skips self-mention" {
    const ms = try findAll(testing.allocator, "@tiger here ignoring @sage and @tiger again", &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expectEqualStrings("sage", ms[0].name);
}

test "findAll: skips unknown names" {
    const ms = try findAll(testing.allocator, "ping @nobody and @sage", &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expectEqualStrings("sage", ms[0].name);
}

test "findAll: skips mid-token @" {
    const ms = try findAll(testing.allocator, "email user@sage.example", &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 0), ms.len);
}

test "findAll: dedupes repeated mentions" {
    const ms = try findAll(testing.allocator, "@sage said X and @sage also said Y", &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expectEqualStrings("sage", ms[0].name);
}

test "findAll: empty text" {
    const ms = try findAll(testing.allocator, "", &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 0), ms.len);
}

test "findAll: case-insensitive match resolves to known canonical" {
    const ms = try findAll(testing.allocator, "ping @SAGE", &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expectEqualStrings("sage", ms[0].name);
}

test "findAll: mentions inside fenced code blocks are skipped" {
    const text =
        "see this snippet:\n" ++
        "```\n" ++
        "echo @sage > log\n" ++
        "```\n" ++
        "real ping: @bolt";
    const ms = try findAll(testing.allocator, text, &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expectEqualStrings("bolt", ms[0].name);
}

test "findAll: closing fence resumes scanning" {
    const text =
        "```\n@sage in fence\n```\n@bolt outside";
    const ms = try findAll(testing.allocator, text, &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expectEqualStrings("bolt", ms[0].name);
}

test "findAll: synthetic resume header is skipped entirely" {
    const text =
        "@sage replied:\nI think we should ask @bolt about this.\n" ++
        "Here's my take.";
    // The header line names sage and bolt; neither should re-trigger,
    // because the line is identified as a synthetic header.
    const ms = try findAll(testing.allocator, text, &known_set, "tiger");
    defer testing.allocator.free(ms);
    // The body line contains a fresh mention of @bolt — that should
    // still match. We're skipping only the header line itself.
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expectEqualStrings("bolt", ms[0].name);
}

test "findAll: bare @name colon is also treated as header" {
    const text = "@sage:\nfollow-up below\n@bolt now please";
    const ms = try findAll(testing.allocator, text, &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expectEqualStrings("bolt", ms[0].name);
}

test "findAll: unknown @foo: does not suppress a real mention on the line" {
    // `@stranger:` is not a known agent, so it must NOT count as a
    // synthetic header — otherwise an attacker could mask any line.
    const text = "@stranger: please notify @sage";
    const ms = try findAll(testing.allocator, text, &known_set, "tiger");
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expectEqualStrings("sage", ms[0].name);
}
