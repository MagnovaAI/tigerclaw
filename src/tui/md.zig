//! Markdown rendering for the TUI chat.
//!
//! Parses incoming agent text with koino (a CommonMark parser
//! vendored at `packages/koino`) and walks the resulting AST to
//! produce vaxis `Segment` runs. That way we reuse a battle-tested
//! parser instead of hand-rolling a lookalike that misses the edge
//! cases every LLM manages to hit.
//!
//! For v0.1.0 we only honour the inline flavours LLMs actually
//! produce (`**bold**`, `*italic*`, `` `code` ``, `[links](...)`,
//! fenced code blocks). Tables, footnotes, task lists, and similar
//! extensions are not enabled — the options are left at koino's
//! default strict CommonMark.

const std = @import("std");
const koino = @import("koino");

// Inline tests are placed here so extracting the walker later is a
// straight move.

const testing = std.testing;

test "koino: parse a single paragraph into an AST" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try koino.parse(arena.allocator(), "Hello **bold** world.", .{});
    // Root node kind is `.document`. If this passes we know koino
    // compiled with its PCRE dependency and linked into the test
    // binary correctly; deeper walker coverage arrives with the
    // renderer in the next commit.
    const Tag = std.meta.Tag(koino.nodes.NodeValue);
    try testing.expectEqual(Tag.Document, std.meta.activeTag(doc.data.value));
}

test "koino: bold span appears in the parsed AST" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try koino.parse(arena.allocator(), "Hello **bold** world.", .{});

    // Walk the AST looking for a Strong node — koino's AST for
    // `**bold**` always produces one.
    var found_strong = false;
    var it = doc.first_child;
    while (it) |node| : (it = node.next) {
        var inner = node.first_child;
        while (inner) |inl| : (inner = inl.next) {
            if (std.meta.activeTag(inl.data.value) == .Strong) {
                found_strong = true;
                break;
            }
        }
        if (found_strong) break;
    }
    try testing.expect(found_strong);
}
