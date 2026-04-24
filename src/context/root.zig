//! Context engine subsystem.
//!
//! Plugger-based context assembly: a `context_engine` capability owns
//! the lifecycle (ingest, assemble, compact, recall) and delegates
//! content gathering to `context_contributor` providers. The default
//! engine stores messages in-process, honors append-only compaction
//! markers, and routes recall through an optional `MemoryIndex`.

pub const types = @import("ctx_types");
pub const engine = @import("ctx_engine");
pub const assemble = @import("ctx_assemble");
pub const registry = @import("ctx_registry");
pub const compact = @import("ctx_compact");
pub const recall = @import("ctx_recall");
pub const default_engine = @import("ctx_default_engine");
