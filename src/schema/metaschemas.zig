pub const Draft = enum { draft04, draft06, draft07, draft2019_09, draft2020_12 };

pub const Entry = struct {
    uri: []const u8,
    draft: Draft,
    source: []const u8,
};

pub const entries = [_]Entry{
    .{ .uri = "http://json-schema.org/draft-04/schema", .draft = .draft04, .source = @embedFile("meta/draft-04.json") },
    .{ .uri = "https://json-schema.org/draft-06/schema", .draft = .draft06, .source = @embedFile("meta/draft-06.json") },
    .{ .uri = "https://json-schema.org/draft-07/schema", .draft = .draft07, .source = @embedFile("meta/draft-07.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/schema", .draft = .draft2019_09, .source = @embedFile("meta/draft-2019-09.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/core", .draft = .draft2019_09, .source = @embedFile("meta/2019-09-core.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/applicator", .draft = .draft2019_09, .source = @embedFile("meta/2019-09-applicator.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/validation", .draft = .draft2019_09, .source = @embedFile("meta/2019-09-validation.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/meta-data", .draft = .draft2019_09, .source = @embedFile("meta/2019-09-meta-data.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/format", .draft = .draft2019_09, .source = @embedFile("meta/2019-09-format.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/content", .draft = .draft2019_09, .source = @embedFile("meta/2019-09-content.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/schema", .draft = .draft2020_12, .source = @embedFile("meta/draft-2020-12.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/core", .draft = .draft2020_12, .source = @embedFile("meta/2020-12-core.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/applicator", .draft = .draft2020_12, .source = @embedFile("meta/2020-12-applicator.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/unevaluated", .draft = .draft2020_12, .source = @embedFile("meta/2020-12-unevaluated.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/validation", .draft = .draft2020_12, .source = @embedFile("meta/2020-12-validation.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/meta-data", .draft = .draft2020_12, .source = @embedFile("meta/2020-12-meta-data.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/format-annotation", .draft = .draft2020_12, .source = @embedFile("meta/2020-12-format-annotation.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/format-assertion", .draft = .draft2020_12, .source = @embedFile("meta/2020-12-format-assertion.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/content", .draft = .draft2020_12, .source = @embedFile("meta/2020-12-content.json") },
};

pub fn declaredDraft(uri: []const u8) ?Draft {
    const normalized = trimFragment(uri);
    for (entries) |entry| if (sameSchemaUri(normalized, entry.uri)) return entry.draft;
    return null;
}

fn sameSchemaUri(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (std.mem.startsWith(u8, a, "http://json-schema.org/") and std.mem.startsWith(u8, b, "https://json-schema.org/"))
        return std.mem.eql(u8, a["http://".len..], b["https://".len..]);
    if (std.mem.startsWith(u8, a, "https://json-schema.org/") and std.mem.startsWith(u8, b, "http://json-schema.org/"))
        return std.mem.eql(u8, a["https://".len..], b["http://".len..]);
    return false;
}

fn trimFragment(uri: []const u8) []const u8 {
    return std.mem.trimEnd(u8, uri, "#");
}

const std = @import("std");

test "all official draft and vocabulary metaschemas are embedded" {
    try std.testing.expect(entries.len >= 18);
    for (entries) |entry| {
        try std.testing.expect(entry.source.len > 0);
        try std.testing.expect(declaredDraft(entry.uri) != null);
    }
}
