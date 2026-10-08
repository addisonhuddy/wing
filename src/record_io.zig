const std = @import("std");

pub const LineReader = struct {
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    overflow: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(reader: *std.Io.Reader, allocator: std.mem.Allocator) LineReader {
        return .{ .reader = reader, .allocator = allocator };
    }

    pub fn next(self: *LineReader) error{ ReadFailed, StreamTooLong, OutOfMemory }!?[]const u8 {
        self.overflow.clearRetainingCapacity();
        while (true) {
            const part = self.reader.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.StreamTooLong => {
                    const buffered = self.reader.buffered();
                    if (buffered.len == 0) return error.StreamTooLong;
                    try self.overflow.appendSlice(self.allocator, buffered);
                    self.reader.toss(buffered.len);
                    continue;
                },
            };
            if (part) |line| {
                if (self.overflow.items.len == 0) return line;
                try self.overflow.appendSlice(self.allocator, line);
                return self.overflow.items;
            }
            if (self.overflow.items.len == 0) return null;
            return self.overflow.items;
        }
    }

    pub fn hasCompleteLineBuffered(self: *const LineReader) bool {
        return std.mem.indexOfScalar(u8, self.reader.buffered(), '\n') != null;
    }
};

pub fn writeLine(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(bytes);
    try writer.writeByte('\n');
}

test "line reader preserves empty lines and final unterminated line" {
    var source = std.Io.Reader.fixed("first\n\nlast");
    var lines = LineReader.init(&source, std.testing.allocator);

    try std.testing.expectEqualStrings("first", (try lines.next()).?);
    try std.testing.expectEqualStrings("", (try lines.next()).?);
    try std.testing.expectEqualStrings("last", (try lines.next()).?);
    try std.testing.expectEqual(null, try lines.next());
}

test "line writer preserves raw bytes" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try writeLine(&output.writer, &.{ 0x7b, 0xff, 0x7d });
    try std.testing.expectEqualSlices(u8, &.{ 0x7b, 0xff, 0x7d, '\n' }, output.written());
}
