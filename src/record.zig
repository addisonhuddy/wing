const std = @import("std");
const jv = @import("jv.zig");

pub const Error = error{ InvalidRecord, InvalidJson, OutOfMemory };

pub const Header = struct {
    key: []const u8,
    value: ?[]const u8,
    node: *const jv.Node,
};

pub const Record = struct {
    document: jv.Document,
    members: []const jv.Member,
    key: ?*const jv.Node,
    value: *const jv.Node,
    key_b64_bytes: ?[]const u8,
    value_b64_bytes: ?[]const u8,
    headers: []const Header,
    headers_node: ?*const jv.Node,

    pub fn parse(alloc: std.mem.Allocator, source: []const u8) Error!Record {
        const document = jv.parse(alloc, source) catch return error.InvalidJson;
        if (document.root.value != .object) return error.InvalidRecord;
        const plain_value = field(document.root, "value");
        const b64_value = field(document.root, "value_b64");
        if (plain_value != null and b64_value != null) return error.InvalidRecord;
        const value = plain_value orelse b64_value orelse return error.InvalidRecord;
        const value_b64_bytes = if (b64_value) |node| try decodeBase64Node(alloc, node) else null;
        const plain_key = field(document.root, "key");
        const b64_key = field(document.root, "key_b64");
        if (plain_key != null and b64_key != null) return error.InvalidRecord;
        const key_b64_bytes = if (b64_key) |node| try decodeBase64Node(alloc, node) else null;
        const key = plain_key orelse b64_key;
        const headers_node = field(document.root, "headers");
        const headers = if (headers_node) |node| try parseHeaders(alloc, node) else &.{};
        return .{
            .document = document,
            .members = document.root.value.object,
            .key = key,
            .value = value,
            .key_b64_bytes = key_b64_bytes,
            .value_b64_bytes = value_b64_bytes,
            .headers = headers,
            .headers_node = headers_node,
        };
    }

    pub fn payloadBytes(self: Record, alloc: std.mem.Allocator, node: *const jv.Node) ![]const u8 {
        if (node == self.value) {
            if (self.value_b64_bytes) |decoded| return decoded;
        }
        if (self.key) |key_node| {
            if (node == key_node) {
                if (self.key_b64_bytes) |decoded| return decoded;
            }
        }
        return bytes(alloc, self.document, node);
    }
};

fn parseHeaders(alloc: std.mem.Allocator, node: *const jv.Node) Error![]const Header {
    if (node.value == .null_value) return &.{};
    var result: std.ArrayListUnmanaged(Header) = .empty;
    switch (node.value) {
        .array => |items| {
            for (items) |item| {
                if (item.value != .object) return error.InvalidRecord;
                const key_node = field(item, "key") orelse return error.InvalidRecord;
                if (key_node.value != .string) return error.InvalidRecord;
                const plain_value = field(item, "value");
                const b64_value = field(item, "value_b64");
                if (plain_value != null and b64_value != null) return error.InvalidRecord;
                const value = if (b64_value) |value_node|
                    try decodeBase64Node(alloc, value_node)
                else blk: {
                    const value_node = plain_value orelse return error.InvalidRecord;
                    break :blk switch (value_node.value) {
                        .string => |value_bytes| value_bytes,
                        .null_value => null,
                        else => return error.InvalidRecord,
                    };
                };
                try result.append(alloc, .{ .key = key_node.value.string, .value = value, .node = item });
            }
        },
        .object => |members| {
            for (members) |member| {
                const value: ?[]const u8 = switch (member.value.value) {
                    .string => |value_bytes| value_bytes,
                    .null_value => null,
                    else => return error.InvalidRecord,
                };
                try result.append(alloc, .{ .key = member.key, .value = value, .node = member.value });
            }
        },
        else => return error.InvalidRecord,
    }
    return result.toOwnedSlice(alloc);
}

fn decodeBase64Node(alloc: std.mem.Allocator, node: *const jv.Node) Error![]const u8 {
    const encoded = switch (node.value) {
        .string => |text| text,
        else => return error.InvalidRecord,
    };
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidRecord;
    const decoded = alloc.alloc(u8, size) catch return error.OutOfMemory;
    errdefer alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch return error.InvalidRecord;
    return decoded;
}

pub fn field(node: *const jv.Node, name: []const u8) ?*const jv.Node {
    if (node.value != .object) return null;
    var found: ?*const jv.Node = null;
    for (node.value.object) |member| {
        if (std.mem.eql(u8, member.key, name)) found = member.value;
    }
    return found;
}

pub fn bytes(alloc: std.mem.Allocator, document: jv.Document, node: *const jv.Node) ![]const u8 {
    return switch (node.value) {
        .string => |text| text,
        .null_value => "",
        else => try alloc.dupe(u8, jv.sourceSlice(document, node)),
    };
}

pub fn writeBase64String(writer: *std.Io.Writer, input_bytes: []const u8) !void {
    try writer.writeByte('"');
    try std.base64.standard.Encoder.encodeWriter(writer, input_bytes);
    try writer.writeByte('"');
}

pub fn raw(document: jv.Document, node: *const jv.Node) []const u8 {
    return jv.sourceSlice(document, node);
}

pub fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

test "record reader decodes header strings and keeps raw value spans" {
    const alloc = std.testing.allocator;
    const input = "{\"headers\":[{\"key\":\"__value_schema_id\",\"value\":\"\\\\u0001\"}],\"value\":\"{\\\\\\\"x\\\\\\\":1}\"}";
    const parsed = try Record.parse(alloc, input);
    try std.testing.expectEqual(@as(usize, 1), parsed.headers.len);
    try std.testing.expectEqualStrings("__value_schema_id", parsed.headers[0].key);
    try std.testing.expectEqualStrings("\\u0001", parsed.headers[0].value.?);
    try std.testing.expectEqualStrings("{\\\"x\\\":1}", try bytes(alloc, parsed.document, parsed.value));
}

test "record reader decodes top-level base64 byte fields" {
    const alloc = std.testing.allocator;
    const parsed = try Record.parse(alloc, "{\"key_b64\":\"AQID\",\"value_b64\":\"eyJ4IjoxfQ==\"}");
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, try parsed.payloadBytes(alloc, parsed.key.?));
    try std.testing.expectEqualStrings("{\"x\":1}", try parsed.payloadBytes(alloc, parsed.value));
}

test "record reader rejects conflicting or invalid top-level base64 fields" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidRecord,
        Record.parse(alloc, "{\"value\":\"{}\",\"value_b64\":\"e30=\"}"),
    );
    try std.testing.expectError(
        error.InvalidRecord,
        Record.parse(alloc, "{\"value_b64\":\"not base64\"}"),
    );
}

test "record reader decodes base64 header values and rejects conflicting values" {
    const alloc = std.testing.allocator;
    const parsed = try Record.parse(alloc, "{\"value\":\"{}\",\"headers\":[{\"key\":\"h\",\"value_b64\":\"AW2jNtjx0w+YTEfQPuihShI=\"}]}");
    const expected = [_]u8{ 1, 0x6d, 0xa3, 0x36, 0xd8, 0xf1, 0xd3, 0x0f, 0x98, 0x4c, 0x47, 0xd0, 0x3e, 0xe8, 0xa1, 0x4a, 0x12 };
    try std.testing.expectEqualSlices(u8, &expected, parsed.headers[0].value.?);
    try std.testing.expectError(
        error.InvalidRecord,
        Record.parse(alloc, "{\"value\":\"{}\",\"headers\":[{\"key\":\"h\",\"value\":\"x\",\"value_b64\":\"eA==\"}]}"),
    );
}

test "base64 JSON strings use standard padded encoding" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const header_bytes = [_]u8{ 1, 0x6d, 0xa3, 0x36, 0xd8, 0xf1, 0xd3, 0x0f, 0x98, 0x4c, 0x47, 0xd0, 0x3e, 0xe8, 0xa1, 0x4a, 0x12 };
    try writeBase64String(&output.writer, &header_bytes);
    try std.testing.expectEqualStrings("\"AW2jNtjx0w+YTEfQPuihShI=\"", output.written());
}

test "record string writer preserves high bytes and escapes controls" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeString(&output.writer, &.{ 0xff, 1, '"' });
    try std.testing.expectEqualSlices(u8, &.{ '"', 0xff, '\\', 'u', '0', '0', '0', '1', '\\', '"', '"' }, output.written());
}
