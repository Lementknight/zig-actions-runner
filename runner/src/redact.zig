//! Secret redaction for anything written to logs or stderr (SPEC §9).
const std = @import("std");

pub const mask = "***";

/// Writes `text` to `w` with every occurrence of any secret replaced by `***`.
pub fn write(w: *std.Io.Writer, text: []const u8, secrets: []const []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    outer: while (i < text.len) {
        for (secrets) |s| {
            if (s.len > 0 and std.mem.startsWith(u8, text[i..], s)) {
                try w.writeAll(mask);
                i += s.len;
                continue :outer;
            }
        }
        try w.writeByte(text[i]);
        i += 1;
    }
}

test "redacts all occurrences" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, "tok=abc123 url=pg://abc123@h", &.{ "abc123", "" });
    try std.testing.expectEqualStrings("tok=*** url=pg://***@h", w.buffered());
}
