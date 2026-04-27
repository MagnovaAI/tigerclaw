const std = @import("std");
const t = @import("ctx_types");
const wire_types = @import("types");
const engine_mod = @import("ctx_engine");
const assemble = @import("ctx_assemble");
const compact = @import("ctx_compact");
const context_mod = @import("context");
const PlugError = @import("errors").PlugError;
const Context = context_mod.Context;

const keep_recent_messages: usize = 2;
const max_summary_content_bytes: usize = 160;

/// A stored message entry. All string fields are owned (duped).
/// `blocks`, when non-null, owns its outer slice and every inner
/// allocation per the ContentBlock variant. `content` always
/// holds a flat-text view for legacy consumers.
const StoredMsg = struct {
    session_id: []const u8,
    message_id: []const u8,
    role: t.Role,
    content: []const u8,
    blocks: ?[]wire_types.ContentBlock = null,
    is_heartbeat: bool = false,
};

/// Free everything a `StoredMsg.blocks` owns. Mirrors
/// `wire_types.Message.freeOwned` but operates on the engine's
/// `[]ContentBlock` slice directly.
fn freeStoredBlocks(allocator: std.mem.Allocator, blocks: []wire_types.ContentBlock) void {
    for (blocks) |b| {
        switch (b) {
            .text => |s| allocator.free(s),
            .tool_use => |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                allocator.free(tu.input_json);
            },
            .tool_result => |tr| {
                allocator.free(tr.tool_use_id);
                allocator.free(tr.content);
            },
        }
    }
    allocator.free(blocks);
}

/// Deep-copy a slice of ContentBlocks into `allocator`. The returned
/// slice owns every inner allocation per variant.
fn dupeBlocks(
    allocator: std.mem.Allocator,
    src: []const wire_types.ContentBlock,
) ![]wire_types.ContentBlock {
    const out = try allocator.alloc(wire_types.ContentBlock, src.len);
    var written: usize = 0;
    errdefer freeStoredBlocks(allocator, out[0..written]);
    for (src) |b| {
        out[written] = switch (b) {
            .text => |s| .{ .text = try allocator.dupe(u8, s) },
            .tool_use => |tu| .{ .tool_use = .{
                .id = try allocator.dupe(u8, tu.id),
                .name = try allocator.dupe(u8, tu.name),
                .input_json = try allocator.dupe(u8, tu.input_json),
            } },
            .tool_result => |tr| .{ .tool_result = .{
                .tool_use_id = try allocator.dupe(u8, tr.tool_use_id),
                .content = try allocator.dupe(u8, tr.content),
                .is_error = tr.is_error,
            } },
        };
        written += 1;
    }
    return out;
}

pub const DefaultEngine = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayListUnmanaged(StoredMsg),
    markers: compact.MarkerLog,

    /// File-scope vtable; taking `&vtable_const` is safe for the lifetime
    /// of the process because the value is stored in read-only memory.
    const vtable_const: engine_mod.ContextEngineVTable = .{
        .bootstrap = bootstrap,
        .ingest = ingest,
        .assemble = assemble_fn,
        .after_turn = afterTurn,
        .maintain = maintain,
        .compact = compactFn,
        .recall = recall,
        .dispose = dispose,
    };

    pub fn init(allocator: std.mem.Allocator) !*DefaultEngine {
        const self = try allocator.create(DefaultEngine);
        self.* = .{
            .allocator = allocator,
            .messages = .{ .items = &.{}, .capacity = 0 },
            .markers = compact.MarkerLog.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *DefaultEngine) void {
        for (self.messages.items) |m| {
            self.allocator.free(m.session_id);
            self.allocator.free(m.message_id);
            self.allocator.free(m.content);
            if (m.blocks) |bs| freeStoredBlocks(self.allocator, bs);
        }
        self.messages.deinit(self.allocator);
        self.markers.deinit();
        self.allocator.destroy(self);
    }

    pub fn engine(self: *DefaultEngine) engine_mod.ContextEngine {
        return .{ .ptr = self, .vtable = &vtable_const };
    }

    /// Free the slices that `assemble` returned. Must be called after every
    /// successful `assemble` call.
    pub fn freeAssembleResult(self: *DefaultEngine, r: t.AssembleResult) void {
        self.allocator.free(r.sections);
        self.allocator.free(r.dropped);
    }

    fn castSelf(p: *anyopaque) *DefaultEngine {
        return @ptrCast(@alignCast(p));
    }

    fn bootstrap(_: *const Context, _: *anyopaque, _: t.BootstrapParams) PlugError!t.BootstrapResult {
        return .{ .bootstrapped = true };
    }

    fn ingest(_: *const Context, p: *anyopaque, params: t.IngestParams) PlugError!t.IngestResult {
        const self = castSelf(p);
        // Idempotent: skip if (session_id, message_id) already stored.
        for (self.messages.items) |m| {
            if (std.mem.eql(u8, m.session_id, params.session_id) and
                std.mem.eql(u8, m.message_id, params.message_id))
            {
                return .{ .ingested = false };
            }
        }
        const sid = self.allocator.dupe(u8, params.session_id) catch return error.Internal;
        errdefer self.allocator.free(sid);
        const mid = self.allocator.dupe(u8, params.message_id) catch return error.Internal;
        errdefer self.allocator.free(mid);
        const cnt = self.allocator.dupe(u8, params.content) catch return error.Internal;
        errdefer self.allocator.free(cnt);
        // Deep-copy structured blocks if the caller provided any —
        // the engine owns them through `dispose`.
        const owned_blocks: ?[]wire_types.ContentBlock = if (params.blocks) |bs|
            dupeBlocks(self.allocator, bs) catch return error.Internal
        else
            null;
        errdefer if (owned_blocks) |bs| freeStoredBlocks(self.allocator, bs);
        self.messages.append(self.allocator, .{
            .session_id = sid,
            .message_id = mid,
            .role = params.role,
            .content = cnt,
            .blocks = owned_blocks,
            .is_heartbeat = params.is_heartbeat,
        }) catch return error.Internal;
        return .{ .ingested = true };
    }

    fn assemble_fn(_: *const Context, p: *anyopaque, params: t.AssembleParams) PlugError!t.AssembleResult {
        const self = castSelf(p);
        var sections: std.ArrayListUnmanaged(t.Section) = .{ .items = &.{}, .capacity = 0 };
        defer sections.deinit(self.allocator);

        // Emit one history_turn section per stored message for this session,
        // skipping any message_id that falls inside a compaction marker range.
        // Pass `m.blocks` through verbatim — the runner reads it on
        // replay to reconstruct structured assistant tool_use /
        // user tool_result wire shapes. The slice is borrowed from
        // the stored message; the runner must finish consuming
        // the assemble result before the engine deallocates.
        for (self.messages.items) |m| {
            if (!std.mem.eql(u8, m.session_id, params.session_id)) continue;
            if (self.markers.coversSession(params.session_id, m.message_id)) continue;
            sections.append(self.allocator, .{
                .kind = .history_turn,
                .role = m.role,
                .content = m.content,
                .blocks = m.blocks,
                .priority = 50,
                .token_estimate = estimateTokens(m.content),
                .tags = &.{},
                .pinned = false,
                .origin = "default-engine/history",
            }) catch return error.Internal;
        }

        // Emit one compaction_summary section per marker.
        for (self.markers.all()) |mk| {
            if (!std.mem.eql(u8, mk.session_id, params.session_id)) continue;
            sections.append(self.allocator, .{
                .kind = .compaction_summary,
                .role = .system,
                .content = mk.summary_text,
                .priority = 40,
                .token_estimate = estimateTokens(mk.summary_text),
                .tags = &.{},
                .pinned = false,
                .origin = "default-engine/summary",
            }) catch return error.Internal;
        }

        // Emit the current prompt last (priority 0 so fit sees it first).
        sections.append(self.allocator, .{
            .kind = .current_prompt,
            .role = .user,
            .content = params.prompt,
            .priority = 0,
            .token_estimate = estimateTokens(params.prompt),
            .tags = &.{},
            .pinned = false,
            .origin = "default-engine/prompt",
        }) catch return error.Internal;

        const fit = assemble.fit(self.allocator, sections.items, params.token_budget) catch return error.Internal;
        return .{
            .sections = fit.sections,
            .estimated_tokens = fit.estimated_tokens,
            .dropped = fit.dropped,
            .system_prompt_addition = null,
        };
    }

    fn afterTurn(_: *const Context, _: *anyopaque, _: t.AfterTurnParams) PlugError!void {
        return;
    }

    fn maintain(_: *const Context, _: *anyopaque, _: t.MaintainParams) PlugError!t.MaintainResult {
        return .{};
    }

    fn compactFn(ctx: *const Context, p: *anyopaque, params: t.CompactParams) PlugError!t.CompactResult {
        const self = castSelf(p);
        const tokens_before = params.current_token_count orelse visibleTokenCount(self, params.session_id);
        if (!params.force and tokens_before <= params.token_budget) {
            return .{
                .compacted = false,
                .tokens_before = tokens_before,
                .reason = "within token budget",
            };
        }

        const range = compactableRange(self, params.session_id) orelse return .{
            .compacted = false,
            .tokens_before = tokens_before,
            .reason = "not enough compactable history",
        };

        const summary_text = buildSummary(self, params.session_id, range.start, range.end) catch return error.Internal;
        defer self.allocator.free(summary_text);
        const summary_entry_id = std.fmt.allocPrint(
            self.allocator,
            "summary:{s}:{s}",
            .{ self.messages.items[range.start].message_id, self.messages.items[range.end].message_id },
        ) catch return error.Internal;
        defer self.allocator.free(summary_entry_id);

        self.markers.append(.{
            .session_id = params.session_id,
            .range_start_id = self.messages.items[range.start].message_id,
            .range_end_id = self.messages.items[range.end].message_id,
            .summary_text = summary_text,
            .summary_entry_id = summary_entry_id,
            .created_at_ms = @intCast(@divTrunc(ctx.clock.nowNs(), std.time.ns_per_ms)),
        }) catch return error.Internal;

        const owned_summary_id = self.allocator.dupe(u8, summary_entry_id) catch return error.Internal;
        return .{
            .compacted = true,
            .summary_entry_id = owned_summary_id,
            .tokens_before = tokens_before,
            .tokens_after = visibleTokenCount(self, params.session_id),
        };
    }

    fn recall(_: *const Context, p: *anyopaque, params: t.RecallParams) PlugError!t.RecallResult {
        const self = castSelf(p);
        if (params.k == 0 or params.query.len == 0) return .{ .hits = &.{} };

        var hits: std.ArrayList(t.RecallHit) = .empty;
        errdefer {
            for (hits.items) |h| {
                self.allocator.free(h.entry_id);
                self.allocator.free(h.snippet);
            }
            hits.deinit(self.allocator);
        }

        for (self.messages.items) |m| {
            if (hits.items.len >= params.k) break;
            if (!std.mem.eql(u8, m.session_id, params.session_id)) continue;
            if (self.markers.coversSession(params.session_id, m.message_id)) continue;
            if (!containsIgnoreCase(m.content, params.query)) continue;

            const entry_id = self.allocator.dupe(u8, m.message_id) catch return error.Internal;
            errdefer self.allocator.free(entry_id);
            const snippet = self.allocator.dupe(u8, snippetFor(m.content)) catch return error.Internal;
            errdefer self.allocator.free(snippet);
            hits.append(self.allocator, .{
                .entry_id = entry_id,
                .score = scoreFor(m.content, params.query),
                .snippet = snippet,
            }) catch return error.Internal;
        }

        return .{ .hits = hits.toOwnedSlice(self.allocator) catch return error.Internal };
    }

    fn dispose(_: *const Context, p: *anyopaque) void {
        const self = castSelf(p);
        self.deinit();
    }
};

const MessageRange = struct { start: usize, end: usize };

fn roleName(role: t.Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn snippetFor(content: []const u8) []const u8 {
    return content[0..@min(content.len, max_summary_content_bytes)];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn scoreFor(content: []const u8, query: []const u8) f32 {
    if (std.ascii.eqlIgnoreCase(content, query)) return 1.0;
    if (std.mem.startsWith(u8, content, query)) return 0.9;
    return 0.75;
}

fn visibleTokenCount(self: *DefaultEngine, session_id: []const u8) u32 {
    var total: u32 = 0;
    for (self.messages.items) |m| {
        if (!std.mem.eql(u8, m.session_id, session_id)) continue;
        if (self.markers.coversSession(session_id, m.message_id)) continue;
        total +|= estimateTokens(m.content);
    }
    for (self.markers.all()) |mk| {
        if (!std.mem.eql(u8, mk.session_id, session_id)) continue;
        total +|= estimateTokens(mk.summary_text);
    }
    return total;
}

fn compactableRange(self: *DefaultEngine, session_id: []const u8) ?MessageRange {
    var first: ?usize = null;
    var eligible: usize = 0;
    for (self.messages.items, 0..) |m, i| {
        if (!std.mem.eql(u8, m.session_id, session_id)) continue;
        if (m.is_heartbeat or self.markers.coversSession(session_id, m.message_id)) continue;
        if (first == null) first = i;
        eligible += 1;
    }
    if (eligible <= keep_recent_messages) return null;

    const compact_count = eligible - keep_recent_messages;
    var seen: usize = 0;
    for (self.messages.items, 0..) |m, i| {
        if (!std.mem.eql(u8, m.session_id, session_id)) continue;
        if (m.is_heartbeat or self.markers.coversSession(session_id, m.message_id)) continue;
        if (seen == compact_count) return .{ .start = first.?, .end = i };
        seen += 1;
    }
    return null;
}

fn buildSummary(self: *DefaultEngine, session_id: []const u8, start: usize, end: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);
    try out.appendSlice(self.allocator, "Compacted earlier turns:\n");
    for (self.messages.items[start..end]) |m| {
        if (!std.mem.eql(u8, m.session_id, session_id)) continue;
        if (m.is_heartbeat or self.markers.coversSession(session_id, m.message_id)) continue;
        try out.appendSlice(self.allocator, "- ");
        try out.appendSlice(self.allocator, roleName(m.role));
        try out.appendSlice(self.allocator, ": ");
        try out.appendSlice(self.allocator, snippetFor(m.content));
        try out.appendSlice(self.allocator, "\n");
    }
    return out.toOwnedSlice(self.allocator);
}

/// Rough token estimate: one token per four bytes, minimum 1.
fn estimateTokens(s: []const u8) u32 {
    const est: u32 = @intCast((s.len + 3) / 4);
    return if (est == 0) 1 else est;
}
