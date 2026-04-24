const std = @import("std");
const t = @import("ctx_types");
const wire_types = @import("types");
const engine_mod = @import("ctx_engine");
const assemble = @import("ctx_assemble");
const compact = @import("ctx_compact");
const context_mod = @import("context");
const Context = context_mod.Context;

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

    fn bootstrap(_: *const Context, _: *anyopaque, _: t.BootstrapParams) anyerror!t.BootstrapResult {
        return .{ .bootstrapped = true };
    }

    fn ingest(_: *const Context, p: *anyopaque, params: t.IngestParams) anyerror!t.IngestResult {
        const self = castSelf(p);
        // Idempotent: skip if (session_id, message_id) already stored.
        for (self.messages.items) |m| {
            if (std.mem.eql(u8, m.session_id, params.session_id) and
                std.mem.eql(u8, m.message_id, params.message_id))
            {
                return .{ .ingested = false };
            }
        }
        const sid = try self.allocator.dupe(u8, params.session_id);
        errdefer self.allocator.free(sid);
        const mid = try self.allocator.dupe(u8, params.message_id);
        errdefer self.allocator.free(mid);
        const cnt = try self.allocator.dupe(u8, params.content);
        errdefer self.allocator.free(cnt);
        // Deep-copy structured blocks if the caller provided any —
        // the engine owns them through `dispose`.
        const owned_blocks: ?[]wire_types.ContentBlock = if (params.blocks) |bs|
            try dupeBlocks(self.allocator, bs)
        else
            null;
        errdefer if (owned_blocks) |bs| freeStoredBlocks(self.allocator, bs);
        try self.messages.append(self.allocator, .{
            .session_id = sid,
            .message_id = mid,
            .role = params.role,
            .content = cnt,
            .blocks = owned_blocks,
        });
        return .{ .ingested = true };
    }

    fn assemble_fn(_: *const Context, p: *anyopaque, params: t.AssembleParams) anyerror!t.AssembleResult {
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
            if (self.markers.covers(m.message_id)) continue;
            try sections.append(self.allocator, .{
                .kind = .history_turn,
                .role = m.role,
                .content = m.content,
                .blocks = m.blocks,
                .priority = 50,
                .token_estimate = estimateTokens(m.content),
                .tags = &.{},
                .pinned = false,
                .origin = "default-engine/history",
            });
        }

        // Emit one compaction_summary section per marker.
        for (self.markers.all()) |mk| {
            try sections.append(self.allocator, .{
                .kind = .compaction_summary,
                .role = .system,
                .content = mk.summary_text,
                .priority = 40,
                .token_estimate = estimateTokens(mk.summary_text),
                .tags = &.{},
                .pinned = false,
                .origin = "default-engine/summary",
            });
        }

        // Emit the current prompt last (priority 0 so fit sees it first).
        try sections.append(self.allocator, .{
            .kind = .current_prompt,
            .role = .user,
            .content = params.prompt,
            .priority = 0,
            .token_estimate = estimateTokens(params.prompt),
            .tags = &.{},
            .pinned = false,
            .origin = "default-engine/prompt",
        });

        const fit = try assemble.fit(self.allocator, sections.items, params.token_budget);
        return .{
            .sections = fit.sections,
            .estimated_tokens = fit.estimated_tokens,
            .dropped = fit.dropped,
            .system_prompt_addition = null,
        };
    }

    fn afterTurn(_: *const Context, _: *anyopaque, _: t.AfterTurnParams) anyerror!void {
        return;
    }

    fn maintain(_: *const Context, _: *anyopaque, _: t.MaintainParams) anyerror!t.MaintainResult {
        return .{};
    }

    fn compactFn(_: *const Context, _: *anyopaque, params: t.CompactParams) anyerror!t.CompactResult {
        return .{
            .compacted = false,
            .tokens_before = params.current_token_count orelse 0,
            .reason = "default engine: compact not wired yet",
        };
    }

    fn recall(_: *const Context, _: *anyopaque, _: t.RecallParams) anyerror!t.RecallResult {
        return .{ .hits = &.{} };
    }

    fn dispose(_: *const Context, p: *anyopaque) void {
        const self = castSelf(p);
        self.deinit();
    }
};

/// Rough token estimate: one token per four bytes, minimum 1.
fn estimateTokens(s: []const u8) u32 {
    const est: u32 = @intCast((s.len + 3) / 4);
    return if (est == 0) 1 else est;
}
