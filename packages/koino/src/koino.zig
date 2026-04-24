//! Trimmed koino — CommonMark parser only.
//!
//! Vendored from https://github.com/kivikakk/koino and upgraded to
//! Zig 0.16. The HTML renderer (`html.zig`) and CLI (`main.zig`)
//! were dropped: tigerclaw walks the AST itself to emit vaxis
//! segments, so the dependencies those files pulled in
//! (`htmlentities_zig`, `clap`) are not needed.

const std = @import("std");

pub const parser = @import("parser.zig");
pub const Options = @import("options.zig").Options;
pub const nodes = @import("nodes.zig");

/// Parses Markdown into an AST.  Use `deinit()' on the returned document to free memory.
pub fn parse(internalAllocator: std.mem.Allocator, markdown: []const u8, options: Options) !*nodes.AstNode {
    var p = try parser.Parser.init(internalAllocator, options);
    defer p.deinit();
    try p.feed(markdown);
    return try p.finish();
}
