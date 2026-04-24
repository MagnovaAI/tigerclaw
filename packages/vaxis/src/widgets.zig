//! Specialized TUI Widgets

pub const alignment = @import("widgets/alignment.zig");
pub const Scrollbar = @import("widgets/Scrollbar.zig");
pub const Table = @import("widgets/Table.zig");
pub const ScrollView = @import("widgets/ScrollView.zig");
pub const LineNumbers = @import("widgets/LineNumbers.zig");
pub const TextView = @import("widgets/TextView.zig");
pub const CodeView = @import("widgets/CodeView.zig");
// Terminal widget (vt emulator) disabled in this fork — it uses
// std.fs.File which moved to std.Io.File in Zig 0.16, and we don't
// need an embedded vt for the chat TUI. Restore the import once
// Terminal.zig and Pty.zig are ported.
// pub const Terminal = @import("widgets/terminal/Terminal.zig");
pub const TextInput = @import("widgets/TextInput.zig");
pub const View = @import("widgets/View.zig");
