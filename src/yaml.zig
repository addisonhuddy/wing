//! Minimal YAML subset parser for kite.yaml: block mappings nested by
//! indentation, plain/single/double-quoted scalars, comments. Anything
//! outside that subset (lists, flow syntax, anchors, block scalars) is a
//! syntax error naming the offending line.

const std = @import("std");

pub const Node = union(enum) { scalar: []const u8, map: Map };
pub const Map = std.StringArrayHashMapUnmanaged(Node);
pub const Diag = struct { line: usize = 0, msg: []const u8 = "" };

const Error = error{ Syntax, OutOfMemory };

const Line = struct { indent: usize, text: []const u8, no: usize };

fn fail(diag: *Diag, no: usize, msg: []const u8) error{Syntax} {
    diag.* = .{ .line = no, .msg = msg };
    return error.Syntax;
}

/// Parse `text` into the root mapping. On error.Syntax `diag` holds the
/// 1-based line and a short message.
pub fn parse(alloc: std.mem.Allocator, text: []const u8, diag: *Diag) Error!Map {
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var no: usize = 0;
    while (it.next()) |raw| {
        no += 1;
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        var indent: usize = 0;
        while (indent < line.len) : (indent += 1) {
            if (line[indent] == '\t') return fail(diag, no, "tab in indentation");
            if (line[indent] != ' ') break;
        }
        const body = line[indent..];
        if (body.len == 0 or body[0] == '#') continue;
        if (lines.items.len == 0 and std.mem.eql(u8, body, "---")) continue;
        if (body[0] == '-') return fail(diag, no, "list items are not supported");
        try lines.append(alloc, .{ .indent = indent, .text = body, .no = no });
    }
    var pos: usize = 0;
    const map = try parseMap(alloc, lines.items, &pos, 0, diag);
    if (pos < lines.items.len) return fail(diag, lines.items[pos].no, "unexpected indentation");
    return map;
}

fn parseMap(
    alloc: std.mem.Allocator,
    lines: []const Line,
    pos: *usize,
    indent: usize,
    diag: *Diag,
) Error!Map {
    var map: Map = .empty;
    while (pos.* < lines.len) {
        const line = lines[pos.*];
        if (line.indent < indent) break;
        if (line.indent > indent) return fail(diag, line.no, "unexpected indentation");
        const kv = try splitKey(alloc, line, diag);
        pos.* += 1;
        var value: Node = undefined;
        if (kv.value) |v| {
            value = .{ .scalar = v };
            if (pos.* < lines.len and lines[pos.*].indent > indent)
                return fail(diag, lines[pos.*].no, "a scalar value cannot have children");
        } else if (pos.* < lines.len and lines[pos.*].indent > indent) {
            value = .{ .map = try parseMap(alloc, lines, pos, lines[pos.*].indent, diag) };
        } else {
            value = .{ .scalar = "" };
        }
        const gop = try map.getOrPut(alloc, kv.key);
        if (gop.found_existing) return fail(diag, line.no, "duplicate key");
        gop.value_ptr.* = value;
    }
    return map;
}

const KeyVal = struct { key: []const u8, value: ?[]const u8 };

fn splitKey(alloc: std.mem.Allocator, line: Line, diag: *Diag) Error!KeyVal {
    const s = line.text;
    var key: []const u8 = undefined;
    var i: usize = 0;
    if (s[0] == '"' or s[0] == '\'') {
        const q = try quoted(alloc, s, 0, line.no, diag);
        key = q.value;
        i = q.end;
        while (i < s.len and s[i] == ' ') i += 1;
        if (i >= s.len or s[i] != ':')
            return fail(diag, line.no, "expected ':' after key");
        i += 1;
    } else {
        const colon = findColon(s) orelse
            return fail(diag, line.no, "missing ':' after key");
        key = std.mem.trim(u8, s[0..colon], " ");
        if (key.len == 0) return fail(diag, line.no, "empty key");
        i = colon + 1;
    }
    const rest = std.mem.trim(u8, s[i..], " ");
    if (rest.len == 0) return .{ .key = key, .value = null };
    return .{ .key = key, .value = try scalarValue(alloc, rest, line.no, diag) };
}

/// First ':' that ends a key: at end of line or followed by a space.
fn findColon(s: []const u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == ':' and (i + 1 == s.len or s[i + 1] == ' ')) return i;
    }
    return null;
}

const Quoted = struct { value: []const u8, end: usize };

/// Parse a quoted scalar starting at `s[start]` (the quote char).
/// Returns the unescaped value and the index just past the closing quote.
fn quoted(alloc: std.mem.Allocator, s: []const u8, start: usize, no: usize, diag: *Diag) Error!Quoted {
    const q = s[start];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i = start + 1;
    while (i < s.len) {
        const c = s[i];
        if (q == '\'' and c == '\'' and i + 1 < s.len and s[i + 1] == '\'') {
            try out.append(alloc, '\'');
            i += 2;
            continue;
        }
        if (c == q) return .{ .value = out.items, .end = i + 1 };
        if (q == '"' and c == '\\' and i + 1 < s.len) {
            const esc: u8 = switch (s[i + 1]) {
                'n' => '\n',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                else => |e| e,
            };
            try out.append(alloc, esc);
            i += 2;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }
    return fail(diag, no, "unterminated quoted scalar");
}

fn scalarValue(alloc: std.mem.Allocator, s: []const u8, no: usize, diag: *Diag) Error![]const u8 {
    switch (s[0]) {
        '[', '{' => return fail(diag, no, "flow syntax is not supported"),
        '&', '*' => return fail(diag, no, "anchors and aliases are not supported"),
        '|', '>' => return fail(diag, no, "block scalars are not supported"),
        '\'', '"' => {
            const q = try quoted(alloc, s, 0, no, diag);
            const rest = std.mem.trim(u8, s[q.end..], " ");
            if (rest.len == 0 or rest[0] == '#') return q.value;
            return fail(diag, no, "unexpected characters after quoted scalar");
        },
        else => {
            // Plain scalar: a '#' starts a comment only after whitespace.
            var end = s.len;
            for (s, 0..) |c, i| {
                if (c == '#' and i > 0 and s[i - 1] == ' ') {
                    end = i - 1;
                    break;
                }
            }
            return std.mem.trim(u8, s[0..end], " ");
        },
    }
}

fn scalar(node: Node) ?[]const u8 {
    return switch (node) {
        .scalar => |v| v,
        .map => null,
    };
}

test "nested block mappings with comments and ---" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const gpa = arena.allocator();
    var diag: Diag = .{};
    var m = try parse(gpa, "# comment\n" ++
        "---\n" ++
        "default: dev  # trailing\n" ++
        "clusters:\n" ++
        "  dev:\n" ++
        "    bootstrap.servers: localhost:9092\n" ++
        "  prod:\n" ++
        "    security.protocol: SASL_SSL\n" ++
        "    sasl.password: 'it''s'\n" ++
        "    linger.ms: \"20\\tms\"\n" ++
        "empty:\n" ++
        "\n", &diag);
    try std.testing.expectEqualStrings("dev", scalar(m.get("default").?).?);
    const clusters = m.get("clusters").?.map;
    try std.testing.expectEqualStrings("localhost:9092", scalar(clusters.get("dev").?.map.get("bootstrap.servers").?).?);
    try std.testing.expectEqualStrings("it's", scalar(clusters.get("prod").?.map.get("sasl.password").?).?);
    try std.testing.expectEqualStrings("20\tms", scalar(clusters.get("prod").?.map.get("linger.ms").?).?);
    try std.testing.expectEqualStrings("", scalar(m.get("empty").?).?);
    _ = &m;
}

test "quoted keys and crlf" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const gpa = arena.allocator();
    var diag: Diag = .{};
    const m = try parse(gpa, "\"bootstrap.servers\": h:1\r\n'sasl.mechanism': PLAIN\r\n", &diag);
    try std.testing.expectEqualStrings("h:1", scalar(m.get("bootstrap.servers").?).?);
    try std.testing.expectEqualStrings("PLAIN", scalar(m.get("sasl.mechanism").?).?);
}

test "rejected forms report the line" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cases = [_]struct { text: []const u8, line: usize, msg: []const u8 }{
        .{ .text = "a:\n\tb: 1\n", .line = 2, .msg = "tab in indentation" },
        .{ .text = "- item\n", .line = 1, .msg = "list items are not supported" },
        .{ .text = "a: [1, 2]\n", .line = 1, .msg = "flow syntax is not supported" },
        .{ .text = "a: &anchor v\n", .line = 1, .msg = "anchors and aliases are not supported" },
        .{ .text = "a: *alias\n", .line = 1, .msg = "anchors and aliases are not supported" },
        .{ .text = "a: |\n  x\n", .line = 1, .msg = "block scalars are not supported" },
        .{ .text = "a: >\n  x\n", .line = 1, .msg = "block scalars are not supported" },
        .{ .text = "a: v\n  b: 1\n", .line = 2, .msg = "a scalar value cannot have children" },
        .{ .text = "justakey\n", .line = 1, .msg = "missing ':' after key" },
        .{ .text = "a: 1\na: 2\n", .line = 2, .msg = "duplicate key" },
        .{ .text = "a: 'unclosed\n", .line = 1, .msg = "unterminated quoted scalar" },
        .{ .text = "a: 'q' junk\n", .line = 1, .msg = "unexpected characters after quoted scalar" },
        .{ .text = "a:\n  b: 1\n c: 2\n", .line = 3, .msg = "unexpected indentation" },
        .{ .text = "a: x\n   b: y\n", .line = 2, .msg = "a scalar value cannot have children" },
    };
    for (cases) |case| {
        var diag: Diag = .{};
        try std.testing.expectError(error.Syntax, parse(gpa, case.text, &diag));
        try std.testing.expectEqual(case.line, diag.line);
        try std.testing.expectEqualStrings(case.msg, diag.msg);
    }
}

test "hash inside a value without preceding space is kept" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const gpa = arena.allocator();
    var diag: Diag = .{};
    const m = try parse(gpa, "a: x#y\nb: v # gone # too\n", &diag);
    try std.testing.expectEqualStrings("x#y", scalar(m.get("a").?).?);
    try std.testing.expectEqualStrings("v", scalar(m.get("b").?).?);
}
