//! Telegram channel — front door.
//!
//! Re-exports the Bot API client surface. Kept as a thin shim so the
//! public entry point mirrors the other extensions in this tree.

pub const api = @import("api.zig");

pub const Bot = api.Bot;
pub const Update = api.Update;
pub const Message = api.Message;
pub const Chat = api.Chat;
pub const User = api.User;
pub const Command = api.Command;
pub const Updates = api.Updates;
pub const SendError = api.SendError;
