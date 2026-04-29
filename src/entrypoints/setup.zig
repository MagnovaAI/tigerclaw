//! Entrypoint shim for `tigerclaw setup`.
const setup_cmd = @import("../cli/commands/setup.zig");
pub const run = setup_cmd.run;
