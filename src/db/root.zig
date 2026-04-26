//! Database subsystem — single SQLite handle, schema migrations,
//! and the typed repositories that sit on top.
//!
//! Lifetime: open the `Db` once at gateway boot, run migrations,
//! hand pointers to the repositories that need it. Close on
//! shutdown, after every subsystem that holds a repo has torn down.

const std = @import("std");

pub const sqlite = @import("sqlite.zig");
pub const migrations = @import("migrations.zig");
pub const instances_repo = @import("instances_repo.zig");

pub const Db = sqlite.Db;
pub const InstanceRepo = instances_repo.Repo;
pub const InstanceRecord = instances_repo.Record;
pub const InstanceKind = instances_repo.Kind;

test {
    std.testing.refAllDecls(@This());
}
