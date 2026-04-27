const t = @import("types.zig");
const Context = @import("context").Context;
const PlugError = @import("errors").PlugError;

/// Vtable for a full context engine implementation.
///
/// Every method receives `*const Context` as its first argument —
/// a repo-wide convention so implementations can reach the I/O
/// abstraction, allocator, clock, and deadline without globals.
/// `self` is the opaque implementation pointer stored in `ContextEngine`.
pub const ContextEngineVTable = struct {
    /// Called once per session start; implementations set up persistent
    /// state (e.g. load memory index, warm caches).
    bootstrap: *const fn (ctx: *const Context, self: *anyopaque, p: t.BootstrapParams) PlugError!t.BootstrapResult,

    /// Called for each incoming message or tool result; implementations
    /// decide what to store and how to index it.
    ingest: *const fn (ctx: *const Context, self: *anyopaque, p: t.IngestParams) PlugError!t.IngestResult,

    /// Called before each LLM call; implementations build the context
    /// window from stored state and active contributors.
    assemble: *const fn (ctx: *const Context, self: *anyopaque, p: t.AssembleParams) PlugError!t.AssembleResult,

    /// Called after a full turn completes; implementations persist state,
    /// update indices, and release per-turn scratch allocations.
    after_turn: *const fn (ctx: *const Context, self: *anyopaque, p: t.AfterTurnParams) PlugError!void,

    /// Called on an idle heartbeat; implementations run background
    /// housekeeping (eviction, re-ranking, flush to durable store).
    maintain: *const fn (ctx: *const Context, self: *anyopaque, p: t.MaintainParams) PlugError!t.MaintainResult,

    /// Called when the context window is approaching its token budget;
    /// implementations summarise or drop low-priority segments.
    compact: *const fn (ctx: *const Context, self: *anyopaque, p: t.CompactParams) PlugError!t.CompactResult,

    /// Called for explicit memory-recall queries (e.g. "what did we
    /// decide last week?"); implementations search their indices.
    recall: *const fn (ctx: *const Context, self: *anyopaque, p: t.RecallParams) PlugError!t.RecallResult,

    /// Release all resources owned by the implementation.
    dispose: *const fn (ctx: *const Context, self: *anyopaque) void,
};

/// Opaque handle to a context engine instance.
pub const ContextEngine = struct {
    ptr: *anyopaque,
    vtable: *const ContextEngineVTable,
};

/// Vtable for a context contributor — a lightweight plug that injects
/// a band of content into the assembled context window.
pub const ContextContributorVTable = struct {
    /// Return the content this contributor wants to place in the
    /// context window for the current turn.
    contribute: *const fn (ctx: *const Context, self: *anyopaque, p: t.ContributeParams) PlugError!t.ContributeResult,

    /// Release all resources owned by the contributor implementation.
    dispose: *const fn (ctx: *const Context, self: *anyopaque) void,
};

/// Opaque handle to a context contributor instance.
///
/// `band` lives on the handle, not the vtable: it is per-instance
/// configuration, not a shared method. Lower band = higher priority
/// when the engine allocates token budget across contributors.
pub const ContextContributor = struct {
    /// Stable identifier used to deduplicate contributors and route
    /// recall queries to the right source.
    id: []const u8,
    /// Priority band. 0 = highest priority.
    band: u8,
    ptr: *anyopaque,
    vtable: *const ContextContributorVTable,
};
