//! Polymorphic message content. Today it is only text; image/tool blocks
//! land with the multimodal subsystem.

const std = @import("std");

pub const Content = union(enum) {
    text: []const u8,

    pub fn jsonStringify(self: Content, w: *std.json.Stringify) !void {
        try w.beginObject();
        switch (self) {
            .text => |t| {
                try w.objectField("type");
                try w.write("text");
                try w.objectField("value");
                try w.write(t);
            },
        }
        try w.endObject();
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Content.text: stringifies as tagged object" {
    const c = Content{ .text = "hi" };
    const s = try std.json.Stringify.valueAlloc(testing.allocator, c, .{});
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\"type\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"value\":\"hi\"") != null);
}
