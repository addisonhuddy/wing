const std = @import("std");

pub const Guid = [16]u8;
pub const Error = error{InvalidGuid};

pub fn parseGuid(text: []const u8) Error!Guid {
    if (text.len != 36 or text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-')
        return error.InvalidGuid;
    var guid: Guid = undefined;
    var out: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '-') continue;
        if (i + 1 >= text.len) return error.InvalidGuid;
        guid[out] = std.fmt.parseInt(u8, text[i .. i + 2], 16) catch return error.InvalidGuid;
        out += 1;
        i += 1;
    }
    if (out != 16) return error.InvalidGuid;
    return guid;
}

pub fn formatGuid(guid: Guid, out: *[36]u8) []const u8 {
    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (guid, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[pos] = '-';
            pos += 1;
        }
        out[pos] = hex[byte >> 4];
        out[pos + 1] = hex[byte & 0x0f];
        pos += 2;
    }
    return out;
}

pub fn encodeGuid(guid: Guid, out: *[17]u8) []const u8 {
    out[0] = 1;
    @memcpy(out[1..], &guid);
    return out;
}

pub fn encodeId(id: u32, out: *[5]u8) []const u8 {
    out[0] = 0;
    std.mem.writeInt(u32, out[1..5], id, .big);
    return out;
}

pub const Prefix = union(enum) { guid: Guid, id: u32 };

pub fn detectPrefix(bytes: []const u8) ?struct { prefix: Prefix, payload: []const u8 } {
    if (bytes.len >= 17 and bytes[0] == 1) {
        var guid: Guid = undefined;
        @memcpy(&guid, bytes[1..17]);
        return .{ .prefix = .{ .guid = guid }, .payload = bytes[17..] };
    }
    if (bytes.len >= 5 and bytes[0] == 0)
        return .{ .prefix = .{ .id = std.mem.readInt(u32, bytes[1..5], .big) }, .payload = bytes[5..] };
    return null;
}

test "guid and header codecs" {
    const g = try parseGuid("6da336d8-f1d3-0f98-4c47-d03ee8a14a12");
    var formatted: [36]u8 = undefined;
    try std.testing.expectEqualStrings("6da336d8-f1d3-0f98-4c47-d03ee8a14a12", formatGuid(g, &formatted));
    var enc: [17]u8 = undefined;
    _ = encodeGuid(g, &enc);
    var payload: [20]u8 = undefined;
    @memcpy(payload[0..17], &enc);
    @memcpy(payload[17..], "abc");
    const got = detectPrefix(&payload);
    try std.testing.expect(got != null and got.?.prefix == .guid);
    try std.testing.expectEqualStrings("abc", got.?.payload);
}

test "numeric id prefix" {
    var b: [5]u8 = undefined;
    _ = encodeId(0x01020304, &b);
    const p = detectPrefix(&b).?;
    try std.testing.expectEqual(@as(u32, 0x01020304), p.prefix.id);
    try std.testing.expectEqual(@as(usize, 0), p.payload.len);
    try std.testing.expect(detectPrefix(&.{ 1, 2, 3 }) == null);
}
