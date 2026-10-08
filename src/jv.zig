const std = @import("std");

pub const Node = struct {
    value: union(enum) {
        null_value,
        boolean: bool,
        number: []const u8,
        string: []const u8,
        object: []const Member,
        array: []const *Node,
    },
    span: Span = .{ .start = 0, .end = 0 },
};
pub const Member = struct { key: []const u8, value: *Node };
pub const Span = struct { start: usize, end: usize };
pub const Document = struct { root: *Node, source: []const u8 };
pub const ParseError = error{ InvalidJson, OutOfMemory };

const Parser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,

    fn ws(p: *Parser) void {
        while (p.pos < p.src.len and (p.src[p.pos] == ' ' or p.src[p.pos] == '\t' or p.src[p.pos] == '\n' or p.src[p.pos] == '\r')) p.pos += 1;
    }
    fn node(p: *Parser, n: Node) ParseError!*Node {
        const ptr = p.alloc.create(Node) catch return error.OutOfMemory;
        ptr.* = n;
        return ptr;
    }
    fn parseValue(p: *Parser) ParseError!*Node {
        p.ws();
        const start = p.pos;
        if (p.pos >= p.src.len) return error.InvalidJson;
        switch (p.src[p.pos]) {
            'n' => {
                if (!p.take("null")) return error.InvalidJson;
                return p.node(.{ .value = .null_value, .span = .{ .start = start, .end = p.pos } });
            },
            't' => {
                if (!p.take("true")) return error.InvalidJson;
                return p.node(.{ .value = .{ .boolean = true }, .span = .{ .start = start, .end = p.pos } });
            },
            'f' => {
                if (!p.take("false")) return error.InvalidJson;
                return p.node(.{ .value = .{ .boolean = false }, .span = .{ .start = start, .end = p.pos } });
            },
            '"' => {
                const text = try p.parseString();
                return p.node(.{ .value = .{ .string = text }, .span = .{ .start = start, .end = p.pos } });
            },
            '{' => return p.parseObject(start),
            '[' => return p.parseArray(start),
            '-', '0'...'9' => {
                const s = p.number() catch return error.InvalidJson;
                return p.node(.{ .value = .{ .number = s }, .span = .{ .start = start, .end = p.pos } });
            },
            else => return error.InvalidJson,
        }
    }
    fn take(p: *Parser, text: []const u8) bool {
        if (p.pos + text.len > p.src.len or !std.mem.eql(u8, p.src[p.pos .. p.pos + text.len], text)) return false;
        p.pos += text.len;
        return true;
    }
    fn parseString(p: *Parser) ParseError![]const u8 {
        if (p.src[p.pos] != '"') return error.InvalidJson;
        p.pos += 1;
        const content_start = p.pos;
        var escaped = false;
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            if (c == '"') {
                const content_end = p.pos;
                p.pos += 1;
                if (!escaped) return p.src[content_start..content_end];
                return unescape(p.alloc, p.src[content_start..content_end]);
            }
            if (c < 0x20) return error.InvalidJson;
            if (c == '\\') {
                escaped = true;
                p.pos += 1;
                if (p.pos >= p.src.len) return error.InvalidJson;
                if (p.src[p.pos] == 'u') {
                    if (p.pos + 4 >= p.src.len) return error.InvalidJson;
                    for (p.src[p.pos + 1 .. p.pos + 5]) |h| if (!std.ascii.isHex(h)) return error.InvalidJson;
                    p.pos += 5;
                } else {
                    if (std.mem.indexOfScalar(u8, "\"\\/bfnrt", p.src[p.pos]) == null) return error.InvalidJson;
                    p.pos += 1;
                }
            } else {
                p.pos += 1;
            }
        }
        return error.InvalidJson;
    }
    fn number(p: *Parser) ParseError![]const u8 {
        const start = p.pos;
        if (p.src[p.pos] == '-') p.pos += 1;
        if (p.pos >= p.src.len) return error.InvalidJson;
        if (p.src[p.pos] == '0') {
            p.pos += 1;
            if (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) return error.InvalidJson;
        } else {
            if (p.src[p.pos] < '1' or p.src[p.pos] > '9') return error.InvalidJson;
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
        }
        if (p.pos < p.src.len and p.src[p.pos] == '.') {
            p.pos += 1;
            const digits = p.pos;
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
            if (digits == p.pos) return error.InvalidJson;
        }
        if (p.pos < p.src.len and (p.src[p.pos] == 'e' or p.src[p.pos] == 'E')) {
            p.pos += 1;
            if (p.pos < p.src.len and (p.src[p.pos] == '+' or p.src[p.pos] == '-')) p.pos += 1;
            const digits = p.pos;
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
            if (digits == p.pos) return error.InvalidJson;
        }
        return p.src[start..p.pos];
    }
    fn parseObject(p: *Parser, start: usize) ParseError!*Node {
        p.pos += 1;
        p.ws();
        var members: std.ArrayListUnmanaged(Member) = .empty;
        if (p.pos < p.src.len and p.src[p.pos] == '}') p.pos += 1 else while (true) {
            p.ws();
            if (p.pos >= p.src.len or p.src[p.pos] != '"') return error.InvalidJson;
            const key = try p.parseString();
            p.ws();
            if (p.pos >= p.src.len or p.src[p.pos] != ':') return error.InvalidJson;
            p.pos += 1;
            const value = try p.parseValue();
            members.append(p.alloc, .{ .key = key, .value = value }) catch return error.OutOfMemory;
            p.ws();
            if (p.pos >= p.src.len) return error.InvalidJson;
            if (p.src[p.pos] == '}') {
                p.pos += 1;
                break;
            }
            if (p.src[p.pos] != ',') return error.InvalidJson;
            p.pos += 1;
        }
        const result = try p.node(.{
            .value = .{ .object = try members.toOwnedSlice(p.alloc) },
            .span = .{ .start = start, .end = p.pos },
        });
        return result;
    }
    fn parseArray(p: *Parser, start: usize) ParseError!*Node {
        p.pos += 1;
        p.ws();
        var values: std.ArrayListUnmanaged(*Node) = .empty;
        if (p.pos < p.src.len and p.src[p.pos] == ']') p.pos += 1 else while (true) {
            try values.append(p.alloc, try p.parseValue());
            p.ws();
            if (p.pos >= p.src.len) return error.InvalidJson;
            if (p.src[p.pos] == ']') {
                p.pos += 1;
                break;
            }
            if (p.src[p.pos] != ',') return error.InvalidJson;
            p.pos += 1;
        }
        const result = try p.node(.{
            .value = .{ .array = try values.toOwnedSlice(p.alloc) },
            .span = .{ .start = start, .end = p.pos },
        });
        return result;
    }
};

fn unescape(alloc: std.mem.Allocator, source: []const u8) ParseError![]const u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    var index: usize = 0;
    while (index < source.len) {
        const byte = source[index];
        if (byte != '\\') {
            output.append(alloc, byte) catch return error.OutOfMemory;
            index += 1;
            continue;
        }
        index += 1;
        if (index >= source.len) return error.InvalidJson;
        switch (source[index]) {
            '"', '\\', '/' => output.append(alloc, source[index]) catch return error.OutOfMemory,
            'b' => output.append(alloc, 0x08) catch return error.OutOfMemory,
            'f' => output.append(alloc, 0x0c) catch return error.OutOfMemory,
            'n' => output.append(alloc, '\n') catch return error.OutOfMemory,
            'r' => output.append(alloc, '\r') catch return error.OutOfMemory,
            't' => output.append(alloc, '\t') catch return error.OutOfMemory,
            'u' => {
                if (index + 4 >= source.len) return error.InvalidJson;
                var codepoint: u32 = std.fmt.parseInt(u16, source[index + 1 .. index + 5], 16) catch return error.InvalidJson;
                index += 4;
                if (codepoint >= 0xd800 and codepoint <= 0xdbff) {
                    if (index + 6 >= source.len or source[index + 1] != '\\' or source[index + 2] != 'u')
                        return error.InvalidJson;
                    const low = std.fmt.parseInt(u16, source[index + 3 .. index + 7], 16) catch return error.InvalidJson;
                    if (low < 0xdc00 or low > 0xdfff) return error.InvalidJson;
                    codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + @as(u32, low - 0xdc00);
                    index += 6;
                } else if (codepoint >= 0xdc00 and codepoint <= 0xdfff) {
                    return error.InvalidJson;
                }
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch return error.InvalidJson;
                output.appendSlice(alloc, encoded[0..length]) catch return error.OutOfMemory;
            },
            else => return error.InvalidJson,
        }
        index += 1;
    }
    return output.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

pub fn parse(alloc: std.mem.Allocator, src: []const u8) ParseError!Document {
    var p = Parser{ .alloc = alloc, .src = src };
    const root = try p.parseValue();
    p.ws();
    if (p.pos != src.len) return error.InvalidJson;
    return .{ .root = root, .source = src };
}

pub fn sourceSlice(document: Document, node: *const Node) []const u8 {
    return document.source[node.span.start..node.span.end];
}

pub fn stringify(alloc: std.mem.Allocator, node: *const Node) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try write(&out, alloc, node);
    return out.toOwnedSlice(alloc);
}

fn write(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, node: *const Node) !void {
    switch (node.value) {
        .null_value => try out.appendSlice(alloc, "null"),
        .boolean => |v| try out.appendSlice(alloc, if (v) "true" else "false"),
        .number => |v| try out.appendSlice(alloc, v),
        .string => |v| {
            var w = std.Io.Writer.Allocating.init(alloc);
            try std.json.Stringify.value(v, .{}, &w.writer);
            try out.appendSlice(alloc, w.written());
        },
        .object => |members| {
            try out.append(alloc, '{');
            for (members, 0..) |m, i| {
                if (i != 0) try out.append(alloc, ',');
                var w = std.Io.Writer.Allocating.init(alloc);
                try std.json.Stringify.value(m.key, .{}, &w.writer);
                try out.appendSlice(alloc, w.written());
                try out.append(alloc, ':');
                try write(out, alloc, m.value);
            }
            try out.append(alloc, '}');
        },
        .array => |values| {
            try out.append(alloc, '[');
            for (values, 0..) |v, i| {
                if (i != 0) try out.append(alloc, ',');
                try write(out, alloc, v);
            }
            try out.append(alloc, ']');
        },
    }
}

pub fn pretty(alloc: std.mem.Allocator, node: *const Node, colored: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try writePretty(&out, alloc, node, 0, colored);
    return out.toOwnedSlice(alloc);
}

fn quoted(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    var writer = std.Io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(text, .{}, &writer.writer);
    try out.appendSlice(alloc, writer.written());
}

fn indent(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, depth: usize) !void {
    for (0..depth * 2) |_| try out.append(alloc, ' ');
}

fn writePretty(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    node: *const Node,
    depth: usize,
    colored: bool,
) anyerror!void {
    switch (node.value) {
        .null_value => try out.appendSlice(alloc, "null"),
        .boolean => |v| try out.appendSlice(alloc, if (v) "true" else "false"),
        .number => |v| {
            if (colored) try out.appendSlice(alloc, "\x1b[33m");
            try out.appendSlice(alloc, v);
            if (colored) try out.appendSlice(alloc, "\x1b[0m");
        },
        .string => |v| {
            if (colored) try out.appendSlice(alloc, "\x1b[32m");
            try quoted(out, alloc, v);
            if (colored) try out.appendSlice(alloc, "\x1b[0m");
        },
        .object => |members| {
            if (members.len == 0) return out.appendSlice(alloc, "{}");
            try out.appendSlice(alloc, "{\n");
            for (members, 0..) |member, i| {
                try indent(out, alloc, depth + 1);
                if (colored) try out.appendSlice(alloc, "\x1b[36m");
                try quoted(out, alloc, member.key);
                if (colored) try out.appendSlice(alloc, "\x1b[0m");
                try out.appendSlice(alloc, ": ");
                try writePretty(out, alloc, member.value, depth + 1, colored);
                try out.appendSlice(alloc, if (i + 1 == members.len) "\n" else ",\n");
            }
            try indent(out, alloc, depth);
            try out.append(alloc, '}');
        },
        .array => |values| {
            if (values.len == 0) return out.appendSlice(alloc, "[]");
            try out.appendSlice(alloc, "[\n");
            for (values, 0..) |value, i| {
                try indent(out, alloc, depth + 1);
                try writePretty(out, alloc, value, depth + 1, colored);
                try out.appendSlice(alloc, if (i + 1 == values.len) "\n" else ",\n");
            }
            try indent(out, alloc, depth);
            try out.append(alloc, ']');
        },
    }
}

test "JSON retains large integer spelling and source offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), "{\"n\":9007199254740993,\"s\":\"v\"}");
    const out = try stringify(arena.allocator(), doc.root);
    try std.testing.expectEqualStrings("{\"n\":9007199254740993,\"s\":\"v\"}", out);
    try std.testing.expect(doc.root.span.end > doc.root.span.start);
}

test "JSON number source slice and escaped strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "{\"n\":1.00e+9,\"s\":\"line\\nquote\\\"\"}";
    const doc = try parse(arena.allocator(), source);
    const members = doc.root.value.object;
    try std.testing.expectEqualStrings("1.00e+9", sourceSlice(doc, members[0].value));
    try std.testing.expectEqualStrings("line\nquote\"", members[1].value.value.string);
    try std.testing.expectEqualStrings(source, try stringify(arena.allocator(), doc.root));
}

test "escaped strings decode Unicode while raw high bytes remain unchanged" {
    const alloc = std.testing.allocator;
    const escaped = try parse(alloc, "\"\\u00ff\"");
    try std.testing.expectEqualSlices(u8, &.{ 0xc3, 0xbf }, escaped.root.value.string);
    const raw = [_]u8{ '"', 0xff, '"' };
    const unescaped = try parse(alloc, &raw);
    try std.testing.expectEqualSlices(u8, &.{0xff}, unescaped.root.value.string);
}

test "JSON parser rejects invalid numbers and trailing data" {
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "[01]"));
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "{\"x\":1,}"));
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "true false"));
}
