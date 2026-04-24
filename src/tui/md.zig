//! Markdown rendering for the TUI chat.
//!
//! Parses incoming agent text with koino (a CommonMark parser
//! vendored at `packages/koino`) and walks the resulting AST to
//! produce flat text plus a parallel list of style spans. The
//! renderer in `src/tui/root.zig` walks the spans and emits one
//! vaxis cell per grapheme under the covering span's style.
//!
//! For v0.1.0 we only honour the inline flavours LLMs actually
//! produce (`**bold**`, `*italic*`, `` `code` ``, `[links](...)`,
//! fenced code blocks). Tables, footnotes, task lists, and similar
//! extensions are not enabled — the options are left at koino's
//! default strict CommonMark.

const std = @import("std");
const koino = @import("koino");

/// Style classes the walker emits. The renderer maps each to a
/// concrete vaxis `Cell.Style`, so keeping this enum purely
/// semantic keeps the walker free of vaxis types.
pub const StyleKind = enum {
    plain,
    bold,
    italic,
    code,
    link,
    heading,
    block_quote,
};

/// A byte range within the rendered output that should be painted
/// with `style`. Spans do not overlap and are emitted in order.
pub const Span = struct {
    start: u32,
    len: u32,
    style: StyleKind,
};

pub const Rendered = struct {
    text: []u8,
    spans: []Span,

    pub fn deinit(self: *Rendered, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.spans);
        self.* = undefined;
    }
};

/// Render `markdown` to flat text + style spans. Caller owns both
/// returned slices (see `Rendered.deinit`).
pub fn render(allocator: std.mem.Allocator, markdown: []const u8) !Rendered {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const doc = try koino.parse(arena.allocator(), markdown, .{});

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);

    try walk(allocator, doc, &text, &spans, .plain);

    return .{
        .text = try text.toOwnedSlice(allocator),
        .spans = try spans.toOwnedSlice(allocator),
    };
}

fn walk(
    allocator: std.mem.Allocator,
    node: *koino.nodes.AstNode,
    text: *std.ArrayList(u8),
    spans: *std.ArrayList(Span),
    parent_style: StyleKind,
) !void {
    // Emit whatever content this node contributes, then recurse.
    const start: u32 = @intCast(text.items.len);

    switch (node.data.value) {
        .Text => |s| try text.appendSlice(allocator, s),
        .Code => |s| try text.appendSlice(allocator, s),
        .SoftBreak, .LineBreak => try text.append(allocator, ' '),
        else => {},
    }

    // Recurse. The style we push for children depends on this node.
    const child_style: StyleKind = switch (node.data.value) {
        .Strong => .bold,
        .Emph => .italic,
        .Code => .code,
        .Link => .link,
        .Heading => .heading,
        .BlockQuote => .block_quote,
        else => parent_style,
    };

    var it = node.first_child;
    while (it) |child| : (it = child.next) {
        try walk(allocator, child, text, spans, child_style);
    }

    // Close the node: separate block-level children with blank lines.
    switch (node.data.value) {
        .Paragraph, .Heading, .BlockQuote, .List, .Item => {
            if (node.next != null) try text.appendSlice(allocator, "\n\n");
        },
        .CodeBlock => |blk| {
            // CodeBlock content lives on the node itself, not its
            // children — emit it now so the span covers the whole block.
            try text.appendSlice(allocator, blk.literal.items);
            if (node.next != null) try text.appendSlice(allocator, "\n\n");
        },
        else => {},
    }

    // Record a span if this node introduced a styled region with
    // any actual text.
    const end: u32 = @intCast(text.items.len);
    if (end > start and child_style != parent_style) {
        try spans.append(allocator, .{
            .start = start,
            .len = end - start,
            .style = child_style,
        });
    }
}

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

test "render: plain text passes through with no spans" {
    var out = try render(testing.allocator, "just words");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("just words", out.text);
    try testing.expectEqual(@as(usize, 0), out.spans.len);
}

test "render: **bold** produces a bold span over the inner text" {
    var out = try render(testing.allocator, "hello **world** now");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("hello world now", out.text);
    // Expect exactly one span covering "world".
    try testing.expectEqual(@as(usize, 1), out.spans.len);
    try testing.expectEqual(StyleKind.bold, out.spans[0].style);
    try testing.expectEqualStrings(
        "world",
        out.text[out.spans[0].start .. out.spans[0].start + out.spans[0].len],
    );
}

test "render: *italic* produces an italic span" {
    var out = try render(testing.allocator, "hello *world* now");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("hello world now", out.text);
    try testing.expectEqual(@as(usize, 1), out.spans.len);
    try testing.expectEqual(StyleKind.italic, out.spans[0].style);
}

test "render: `code` spans mark inline code" {
    var out = try render(testing.allocator, "run `foo()` now");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("run foo() now", out.text);
    try testing.expectEqual(@as(usize, 1), out.spans.len);
    try testing.expectEqual(StyleKind.code, out.spans[0].style);
    try testing.expectEqualStrings(
        "foo()",
        out.text[out.spans[0].start .. out.spans[0].start + out.spans[0].len],
    );
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
