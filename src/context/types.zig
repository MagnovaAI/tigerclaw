pub const Role = enum { system, user, assistant, tool };

pub const SectionKind = enum {
    system_preamble,
    channel_state,
    memory_hit,
    tool_manifest,
    history_turn,
    compaction_summary,
    current_prompt,
};

pub const Section = struct {
    kind: SectionKind,
    role: Role,
    content: []const u8,
    priority: u8,
    token_estimate: u32,
    tags: []const []const u8,
    pinned: bool,
    origin: []const u8,
};

pub const DroppedSection = struct {
    section: Section,
    reason: DropReason,
};

pub const DropReason = enum { over_budget, kind_excluded, contributor_disabled };

pub const AssembleResult = struct {
    sections: []const Section,
    estimated_tokens: u32,
    dropped: []const DroppedSection,
    system_prompt_addition: ?[]const u8,
};

pub const ContributeParams = struct {
    session_id: []const u8,
    prompt: []const u8,
    model: []const u8,
    available_tools: []const []const u8,
    remaining_budget_tokens: u32,
};

pub const ContributeResult = struct {
    sections: []const Section,
};

pub const AssembleParams = struct {
    session_id: []const u8,
    prompt: []const u8,
    model: []const u8,
    available_tools: []const []const u8,
    token_budget: u32,
};

pub const IngestParams = struct {
    session_id: []const u8,
    message_id: []const u8,
    role: Role,
    content: []const u8,
    is_heartbeat: bool = false,
};

pub const IngestResult = struct { ingested: bool };

pub const BootstrapParams = struct {
    session_id: []const u8,
    session_file: []const u8,
};

pub const BootstrapResult = struct {
    bootstrapped: bool,
    imported_messages: u32 = 0,
    reason: ?[]const u8 = null,
};

pub const AfterTurnParams = struct {
    session_id: []const u8,
    pre_prompt_message_count: u32,
    token_budget: u32,
    is_heartbeat: bool = false,
};

pub const MaintainParams = struct { session_id: []const u8 };
pub const MaintainResult = struct {
    rewritten_entries: u32 = 0,
    bytes_freed: u64 = 0,
};

pub const CompactParams = struct {
    session_id: []const u8,
    token_budget: u32,
    force: bool = false,
    current_token_count: ?u32 = null,
};

pub const CompactResult = struct {
    compacted: bool,
    summary_entry_id: ?[]const u8 = null,
    tokens_before: u32,
    tokens_after: ?u32 = null,
    reason: ?[]const u8 = null,
};

pub const RecallParams = struct {
    session_id: []const u8,
    query: []const u8,
    k: u8,
};

pub const RecallHit = struct {
    entry_id: []const u8,
    score: f32,
    snippet: []const u8,
};

pub const RecallResult = struct {
    hits: []const RecallHit,
};
