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
    headers: []const Header,
    headers_node: ?*const jv.Node,

    pub fn parse(alloc: std.mem.Allocator, source: []const u8) Error!Record {
        const document = jv.parse(alloc, source) catch return error.InvalidJson;
        if (document.root.value != .object) return error.InvalidRecord;
        const value = field(document.root, "value") orelse return error.InvalidRecord;
        const headers_node = field(document.root, "headers");
        const headers = if (headers_node) |node| try parseHeaders(alloc, node) else &.{};
        return .{
            .document = document,
            .members = document.root.value.object,
            .key = field(document.root, "key"),
            .value = value,
            .headers = headers,
            .headers_node = headers_node,
        };
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
                const value_node = field(item, "value") orelse return error.InvalidRecord;
                const value: ?[]const u8 = switch (value_node.value) {
                    .string => |value_bytes| value_bytes,
                    .null_value => null,
                    else => return error.InvalidRecord,
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

test "record string writer preserves high bytes and escapes controls" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeString(&output.writer, &.{ 0xff, 1, '"' });
    try std.testing.expectEqualSlices(u8, &.{ '"', 0xff, '\\', 'u', '0', '0', '0', '1', '\\', '"', '"' }, output.written());
}
