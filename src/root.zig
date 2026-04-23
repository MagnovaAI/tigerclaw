//! tigerclaw — library root.
//!
//! Re-exports the public surface of the runtime. Subsystems are added here
//! as they land. Dependency direction flows inward toward primitives
//! (log, clock, determinism, errors); subsystems must not import across
//! each other.

pub const agent = @import("agent/root.zig");
pub const bench = @import("bench/root.zig");
pub const capabilities = @import("capabilities.zig");
pub const context = @import("context.zig");
pub const registry = @import("registry.zig");
pub const manifest = @import("manifest.zig");
pub const dep_graph = @import("dep_graph.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const hook_bus = @import("hook_bus.zig");
pub const envelope = @import("envelope.zig");
pub const envelope_codec = @import("envelope_codec.zig");
pub const peer_id = @import("peer_id.zig");
pub const channel_id = @import("channel_id.zig");
pub const envelope_sig = @import("envelope_sig.zig");
pub const contract_runner = @import("contract_runner.zig");
pub const channels = @import("channels/root.zig");
pub const cli = @import("cli/root.zig");
pub const clock = @import("clock.zig");
pub const constants = @import("constants/root.zig");
pub const cost = @import("cost/root.zig");
pub const daemon = @import("daemon/root.zig");
pub const determinism = @import("determinism.zig");
pub const entrypoints = @import("entrypoints/root.zig");
pub const errors = @import("errors.zig");
pub const eval = @import("eval/root.zig");
pub const gateway = @import("gateway/root.zig");
pub const globals = @import("globals.zig");
pub const harness = @import("harness/root.zig");
pub const llm = @import("llm/root.zig");
pub const log = @import("log.zig");
pub const permissions = @import("permissions/root.zig");
pub const sandbox = @import("sandbox/root.zig");
pub const scenario = @import("scenario/root.zig");
pub const settings = @import("settings/root.zig");
pub const tools = @import("tools/root.zig");
pub const trace = @import("trace/root.zig");
pub const types = @import("types");
pub const util = @import("util/root.zig");
pub const vcr = @import("vcr/root.zig");
pub const version = @import("version.zig");
