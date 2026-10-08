const std = @import("std");

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const green = "\x1b[32m";
pub const bold_blue = "\x1b[1;34m";
pub const cyan = "\x1b[36m";
pub const red = "\x1b[31m";

pub fn writeJsonColored(writer: *std.Io.Writer, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] == '"') {
            var end = index + 1;
            while (end < bytes.len) {
                if (bytes[end] == '\\') {
                    end += 2;
                    continue;
                }
                if (bytes[end] == '"') break;
                end += 1;
            }
            end = @min(end + 1, bytes.len);
            var next = end;
            while (next < bytes.len and (bytes[next] == ' ' or bytes[next] == '\t')) next += 1;
            try writer.writeAll(if (next < bytes.len and bytes[next] == ':') bold_blue else green);
            try writer.writeAll(bytes[index..end]);
            try writer.writeAll(reset);
            index = end;
        } else if (index + 4 <= bytes.len and std.mem.eql(u8, bytes[index .. index + 4], "null") and
            (index + 4 == bytes.len or !std.ascii.isAlphanumeric(bytes[index + 4])))
        {
            try writer.writeAll(dim);
            try writer.writeAll("null");
            try writer.writeAll(reset);
            index += 4;
        } else {
            try writer.writeByte(bytes[index]);
            index += 1;
        }
    }
}

pub fn writeTableCell(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) {
        for (0..width - text.len) |_| try writer.writeByte(' ');
    }
}

pub fn colorEnabled(io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("WING_COLOR")) |v| {
        if (std.mem.eql(u8, v, "always")) return true;
        if (std.mem.eql(u8, v, "never")) return false;
    }
    if (env.get("NO_COLOR")) |v| if (v.len > 0) return false;
    return std.Io.File.stderr().isTty(io) catch false;
}

pub fn confirm(io: std.Io, prompt: []const u8) ?bool {
    if (!(std.Io.File.stderr().isTty(io) catch false)) return null;
    const tty = std.Io.Dir.cwd().openFile(io, "/dev/tty", .{}) catch return null;
    defer tty.close(io);
    std.debug.print("wing: {s}", .{prompt});
    var buf: [128]u8 = undefined;
    var reader = tty.reader(io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch return false;
    const answer = std.mem.trim(u8, line orelse return false, " \t\r");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

test "writeJsonColored preserves compact bytes and colors JSON tokens" {
    const alloc = std.testing.allocator;
    const input = "{\"value\":\"raw \x80 bytes\",\"headers\":[{\"key\":\"x\",\"value\":null}]}";
    var output = std.Io.Writer.Allocating.init(alloc);
    defer output.deinit();
    try writeJsonColored(&output.writer, input);

    var plain = std.ArrayListUnmanaged(u8).empty;
    var index: usize = 0;
    const bytes = output.written();
    while (index < bytes.len) {
        if (bytes[index] == 0x1b) {
            while (index < bytes.len and bytes[index] != 'm') index += 1;
            index += 1;
        } else {
            try plain.append(alloc, bytes[index]);
            index += 1;
        }
    }
    try std.testing.expectEqualSlices(u8, input, plain.items);
    try std.testing.expect(std.mem.indexOf(u8, bytes, bold_blue ++ "\"value\"" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, green ++ "\"raw \x80 bytes\"" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, dim ++ "null" ++ reset) != null);
}
