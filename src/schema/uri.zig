const std = @import("std");

const Parts = struct {
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

fn parse(text: []const u8) Parts {
    var parts: Parts = .{};
    var end = text.len;
    if (std.mem.indexOfScalar(u8, text, '#')) |at| {
        parts.fragment = text[at + 1 ..];
        end = at;
    }
    if (std.mem.indexOfScalar(u8, text[0..end], '?')) |at| {
        parts.query = text[at + 1 .. end];
        end = at;
    }
    var rest = text[0..end];
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (colon < slash and colon > 0 and validScheme(rest[0..colon])) {
            parts.scheme = rest[0..colon];
            rest = rest[colon + 1 ..];
        }
    }
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        parts.authority = rest[0..slash];
        rest = rest[slash..];
    }
    parts.path = rest;
    return parts;
}

fn validScheme(text: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

pub fn resolve(alloc: std.mem.Allocator, base_uri: []const u8, reference: []const u8) ![]const u8 {
    const base = parse(base_uri);
    const ref = parse(reference);
    if (ref.scheme != null) return compose(alloc, .{
        .scheme = ref.scheme,
        .authority = ref.authority,
        .path = try removeDotSegments(alloc, ref.path),
        .query = ref.query,
        .fragment = ref.fragment,
    });
    if (base.scheme == null) return error.InvalidBaseUri;

    var target: Parts = .{ .scheme = base.scheme, .fragment = ref.fragment };
    if (ref.authority) |authority| {
        target.authority = authority;
        target.path = try removeDotSegments(alloc, ref.path);
        target.query = ref.query;
    } else {
        target.authority = base.authority;
        if (ref.path.len == 0) {
            target.path = base.path;
            target.query = ref.query orelse base.query;
        } else {
            const merged = if (std.mem.startsWith(u8, ref.path, "/"))
                ref.path
            else
                try mergePaths(alloc, base.authority, base.path, ref.path);
            target.path = try removeDotSegments(alloc, merged);
            target.query = ref.query;
        }
    }
    return compose(alloc, target);
}

fn mergePaths(alloc: std.mem.Allocator, authority: ?[]const u8, base_path: []const u8, ref_path: []const u8) ![]const u8 {
    if (authority != null and base_path.len == 0)
        return std.fmt.allocPrint(alloc, "/{s}", .{ref_path});
    const slash = std.mem.lastIndexOfScalar(u8, base_path, '/') orelse return std.fmt.allocPrint(alloc, "{s}{s}", .{ base_path, ref_path });
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ base_path[0 .. slash + 1], ref_path });
}

fn removeLastSegment(out: *std.ArrayListUnmanaged(u8)) void {
    if (std.mem.lastIndexOfScalar(u8, out.items, '/')) |slash| {
        out.items.len = slash;
    } else {
        out.items.len = 0;
    }
}

fn removeDotSegments(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var input = path;
    var output = std.ArrayListUnmanaged(u8).empty;
    while (input.len > 0) {
        if (std.mem.startsWith(u8, input, "../")) {
            input = input[3..];
        } else if (std.mem.startsWith(u8, input, "./")) {
            input = input[2..];
        } else if (std.mem.startsWith(u8, input, "/./")) {
            input = input[2..];
        } else if (std.mem.eql(u8, input, "/.")) {
            input = "/";
        } else if (std.mem.startsWith(u8, input, "/../")) {
            input = input[3..];
            removeLastSegment(&output);
        } else if (std.mem.eql(u8, input, "/..")) {
            input = "/";
            removeLastSegment(&output);
        } else if (std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "..")) {
            input = input[input.len..];
        } else {
            const search_from: usize = if (input[0] == '/') 1 else 0;
            const next_slash = std.mem.indexOfScalarPos(u8, input, search_from, '/') orelse input.len;
            try output.appendSlice(alloc, input[0..next_slash]);
            input = input[next_slash..];
        }
    }
    return output.toOwnedSlice(alloc);
}

fn compose(alloc: std.mem.Allocator, parts: Parts) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    if (parts.scheme) |scheme| {
        try out.appendSlice(alloc, scheme);
        try out.append(alloc, ':');
    }
    if (parts.authority) |authority| {
        try out.appendSlice(alloc, "//");
        try out.appendSlice(alloc, authority);
    }
    try out.appendSlice(alloc, parts.path);
    if (parts.query) |query| {
        try out.append(alloc, '?');
        try out.appendSlice(alloc, query);
    }
    if (parts.fragment) |fragment| {
        try out.append(alloc, '#');
        try out.appendSlice(alloc, fragment);
    }
    return out.toOwnedSlice(alloc);
}

pub fn percentDecode(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '%') {
            try out.append(alloc, text[index]);
            continue;
        }
        if (index + 2 >= text.len) return error.InvalidPercentEncoding;
        const high = std.fmt.charToDigit(text[index + 1], 16) catch return error.InvalidPercentEncoding;
        const low = std.fmt.charToDigit(text[index + 2], 16) catch return error.InvalidPercentEncoding;
        try out.append(alloc, @as(u8, @intCast(high * 16 + low)));
        index += 2;
    }
    return out.toOwnedSlice(alloc);
}

pub fn pointerTokens(alloc: std.mem.Allocator, fragment: []const u8) ![][]const u8 {
    const raw = if (std.mem.startsWith(u8, fragment, "#")) fragment[1..] else fragment;
    const decoded = try percentDecode(alloc, raw);
    if (decoded.len == 0) return try alloc.alloc([]const u8, 0);
    if (decoded[0] != '/') return error.NotJsonPointer;
    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, decoded[1..], '/');
    while (parts.next()) |part| {
        var token = std.ArrayListUnmanaged(u8).empty;
        var i: usize = 0;
        while (i < part.len) : (i += 1) {
            if (part[i] != '~') {
                try token.append(alloc, part[i]);
                continue;
            }
            if (i + 1 >= part.len) return error.InvalidJsonPointerEscape;
            i += 1;
            switch (part[i]) {
                '0' => try token.append(alloc, '~'),
                '1' => try token.append(alloc, '/'),
                else => return error.InvalidJsonPointerEscape,
            }
        }
        try tokens.append(alloc, try token.toOwnedSlice(alloc));
    }
    return tokens.toOwnedSlice(alloc);
}

test "RFC 3986 relative reference resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("http://a/b/c/g", try resolve(alloc, "http://a/b/c/d;p?q", "g"));
    try std.testing.expectEqualStrings("http://a/b/g", try resolve(alloc, "http://a/b/c/d", "../g"));
    try std.testing.expectEqualStrings("https://example.test/a#x", try resolve(alloc, "https://example.test/a", "#x"));
}

test "RFC 3986 normal and abnormal reference examples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = "http://a/b/c/d;p?q";
    const examples = [_]struct { reference: []const u8, expected: []const u8 }{
        .{ .reference = "g", .expected = "http://a/b/c/g" },
        .{ .reference = "./g", .expected = "http://a/b/c/g" },
        .{ .reference = "g/", .expected = "http://a/b/c/g/" },
        .{ .reference = "/g", .expected = "http://a/g" },
        .{ .reference = "//g", .expected = "http://g" },
        .{ .reference = "?y", .expected = "http://a/b/c/d;p?y" },
        .{ .reference = "g?y", .expected = "http://a/b/c/g?y" },
        .{ .reference = "#s", .expected = "http://a/b/c/d;p?q#s" },
        .{ .reference = "g#s", .expected = "http://a/b/c/g#s" },
        .{ .reference = "g?y#s", .expected = "http://a/b/c/g?y#s" },
        .{ .reference = ";x", .expected = "http://a/b/c/;x" },
        .{ .reference = "g;x", .expected = "http://a/b/c/g;x" },
        .{ .reference = "", .expected = "http://a/b/c/d;p?q" },
        .{ .reference = ".", .expected = "http://a/b/c/" },
        .{ .reference = "..", .expected = "http://a/b/" },
        .{ .reference = "../g", .expected = "http://a/b/g" },
        .{ .reference = "../../g", .expected = "http://a/g" },
    };
    for (examples) |example| {
        try std.testing.expectEqualStrings(example.expected, try resolve(alloc, base, example.reference));
    }
}

test "JSON Pointer fragment decoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try pointerTokens(arena.allocator(), "/a~1b/%7E0");
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("a/b", tokens[0]);
    try std.testing.expectEqualStrings("~", tokens[1]);
    const encoded = try pointerTokens(arena.allocator(), "%2Fa~1b");
    try std.testing.expectEqual(@as(usize, 1), encoded.len);
    try std.testing.expectEqualStrings("a/b", encoded[0]);
}
