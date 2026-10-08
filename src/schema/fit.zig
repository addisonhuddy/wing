const std = @import("std");
const jv = @import("../jv.zig");
const compile = @import("compile.zig");
const validate = @import("validate.zig");
const number = @import("number.zig");

pub const Change = struct {
    rule: Rule,
    path: []const u8,
    before: ?[]const u8,
    after: ?[]const u8,
};

pub const Rule = enum { coerce, defaults, drop_extra, wrap };

pub const Result = struct {
    node: *jv.Node,
    changes: []const Change,
};

pub fn apply(
    alloc: std.mem.Allocator,
    plan: *const compile.Plan,
    instance: *jv.Node,
) !Result {
    if ((try validate.validate(alloc, plan, instance, .{})).len == 0)
        return .{ .node = instance, .changes = &.{} };
    var changes: std.ArrayListUnmanaged(Change) = .empty;
    try fitNode(alloc, plan, plan.root, instance, "", &changes);
    return .{ .node = instance, .changes = try changes.toOwnedSlice(alloc) };
}

fn fitNode(
    alloc: std.mem.Allocator,
    plan: *const compile.Plan,
    schema: *const compile.Node,
    instance: *jv.Node,
    path: []const u8,
    changes: *std.ArrayListUnmanaged(Change),
) anyerror!void {
    if ((try validate.validateSubschema(alloc, plan, schema, instance, .{})).len == 0) return;

    if (schema.keyword("allOf")) |all_of| {
        if (all_of.value == .array) {
            for (all_of.value.array, 0..) |_, index| {
                var selector: [20]u8 = undefined;
                const name = try std.fmt.bufPrint(&selector, "{d}", .{index});
                if (schema.child("allOf", name)) |child|
                    try fitNode(alloc, plan, child, instance, path, changes);
            }
        }
    }
    if ((try validate.validateSubschema(alloc, plan, schema, instance, .{})).len == 0) return;

    _ = try fitBranches(alloc, plan, schema, instance, path, changes, "anyOf", false);
    _ = try fitBranches(alloc, plan, schema, instance, path, changes, "oneOf", true);
    if ((try validate.validateSubschema(alloc, plan, schema, instance, .{})).len == 0) return;

    try coerce(alloc, schema, instance, path, changes);
    if ((try validate.validateSubschema(alloc, plan, schema, instance, .{})).len == 0) return;

    try wrap(alloc, schema, instance, path, changes);
    if ((try validate.validateSubschema(alloc, plan, schema, instance, .{})).len == 0) return;

    switch (instance.value) {
        .object => try fitObject(alloc, plan, schema, instance, path, changes),
        .array => try fitArray(alloc, plan, schema, instance, path, changes),
        else => {},
    }
}

fn coerce(
    alloc: std.mem.Allocator,
    schema: *const compile.Node,
    instance: *jv.Node,
    path: []const u8,
    changes: *std.ArrayListUnmanaged(Change),
) !void {
    const target = schema.keyword("type") orelse return;
    const before = try jv.stringify(alloc, instance);
    switch (instance.value) {
        .string => |text| {
            if (allowsType(target, "string")) return;
            if (allowsType(target, "integer") or allowsType(target, "number")) {
                const parsed = number.parse(alloc, text) catch return;
                if (allowsType(target, "integer") and !allowsType(target, "number") and
                    !parsed.isInteger(schema.draft == .draft04)) return;
                instance.value = .{ .number = text };
            } else if (allowsType(target, "boolean")) {
                if (std.mem.eql(u8, text, "true")) {
                    instance.value = .{ .boolean = true };
                } else if (std.mem.eql(u8, text, "false")) {
                    instance.value = .{ .boolean = false };
                } else return;
            } else return;
        },
        .number => |text| {
            if (allowsType(target, "number") or allowsType(target, "integer")) return;
            if (!allowsType(target, "string")) return;
            instance.value = .{ .string = text };
        },
        .boolean => |value| {
            if (allowsType(target, "boolean")) return;
            if (!allowsType(target, "string")) return;
            instance.value = .{ .string = if (value) "true" else "false" };
        },
        .null_value, .object, .array => return,
    }
    const after = try jv.stringify(alloc, instance);
    try changes.append(alloc, .{ .rule = .coerce, .path = path, .before = before, .after = after });
}

fn wrap(
    alloc: std.mem.Allocator,
    schema: *const compile.Node,
    instance: *jv.Node,
    path: []const u8,
    changes: *std.ArrayListUnmanaged(Change),
) !void {
    const type_node = schema.keyword("type") orelse return;
    if (!allowsType(type_node, "array") or instanceTypeAllowed(type_node, instance)) return;
    switch (instance.value) {
        .null_value, .array => return,
        else => {},
    }
    const before = try jv.stringify(alloc, instance);
    const values = try alloc.alloc(*jv.Node, 1);
    values[0] = try alloc.create(jv.Node);
    values[0].* = instance.*;
    instance.value = .{ .array = values };
    const after = try jv.stringify(alloc, instance);
    try changes.append(alloc, .{ .rule = .wrap, .path = path, .before = before, .after = after });
}

fn fitObject(
    alloc: std.mem.Allocator,
    plan: *const compile.Plan,
    schema: *const compile.Node,
    instance: *jv.Node,
    path: []const u8,
    changes: *std.ArrayListUnmanaged(Change),
) anyerror!void {
    const members = instance.value.object;
    var fitted: std.ArrayListUnmanaged(jv.Member) = .empty;
    const additional = schema.keyword("additionalProperties");
    for (members) |member| {
        const property_path = try appendPath(alloc, path, member.key);
        var matched = false;
        if (schema.child("properties", member.key)) |child| {
            matched = true;
            try fitNode(alloc, plan, child, member.value, property_path, changes);
        }
        if (schema.keyword("patternProperties")) |patterns| {
            if (patterns.value == .object) {
                for (patterns.value.object) |pattern| {
                    const expression = schema.pattern(pattern.key) orelse continue;
                    if (!try expression.matches(alloc, member.key)) continue;
                    matched = true;
                    if (schema.child("patternProperties", pattern.key)) |child|
                        try fitNode(alloc, plan, child, member.value, property_path, changes);
                }
            }
        }
        if (!matched) {
            if (additional) |additional_schema| {
                if (additional_schema.value == .boolean and !additional_schema.value.boolean) {
                    const before = try jv.stringify(alloc, member.value);
                    try changes.append(alloc, .{
                        .rule = .drop_extra,
                        .path = property_path,
                        .before = before,
                        .after = null,
                    });
                    continue;
                }
                if (schema.child("additionalProperties", null)) |child|
                    try fitNode(alloc, plan, child, member.value, property_path, changes);
            }
        }
        try fitted.append(alloc, member);
    }

    if (schema.keyword("properties")) |properties| {
        if (properties.value == .object) {
            for (properties.value.object) |property| {
                if (containsMember(fitted.items, property.key)) continue;
                const child = schema.child("properties", property.key) orelse continue;
                const default = child.keyword("default") orelse continue;
                const cloned = try cloneNode(alloc, default);
                const property_path = try appendPath(alloc, path, property.key);
                try changes.append(alloc, .{
                    .rule = .defaults,
                    .path = property_path,
                    .before = null,
                    .after = try jv.stringify(alloc, cloned),
                });
                try fitted.append(alloc, .{ .key = property.key, .value = cloned });
            }
        }
    }
    instance.value = .{ .object = try fitted.toOwnedSlice(alloc) };
}

fn fitArray(
    alloc: std.mem.Allocator,
    plan: *const compile.Plan,
    schema: *const compile.Node,
    instance: *jv.Node,
    path: []const u8,
    changes: *std.ArrayListUnmanaged(Change),
) anyerror!void {
    const items = instance.value.array;
    const prefix = schema.keyword("prefixItems");
    const tuple = schema.draft != .draft2020_12 and
        schema.keyword("items") != null and schema.keyword("items").?.value == .array;
    const tuple_items = if (tuple) schema.keyword("items") else null;
    const item_schema = if (tuple) null else schema.child("items", null);
    for (items, 0..) |item, index| {
        var selector: [20]u8 = undefined;
        const name = try std.fmt.bufPrint(&selector, "{d}", .{index});
        var child: ?*compile.Node = null;
        if (prefix) |prefix_value| {
            if (prefix_value.value == .array and index < prefix_value.value.array.len)
                child = schema.child("prefixItems", name);
        }
        if (child == null and tuple) {
            if (tuple_items) |tuple_value| {
                if (index < tuple_value.value.array.len) {
                    child = schema.child("items", name);
                } else if (schema.keyword("additionalItems") != null) {
                    child = schema.child("additionalItems", null);
                }
            }
        } else if (child == null) {
            child = item_schema;
        }
        if (child) |subschema|
            try fitNode(alloc, plan, subschema, @constCast(item), try appendIndex(alloc, path, index), changes);
    }
}

fn fitBranches(
    alloc: std.mem.Allocator,
    plan: *const compile.Plan,
    schema: *const compile.Node,
    instance: *jv.Node,
    path: []const u8,
    changes: *std.ArrayListUnmanaged(Change),
    keyword: []const u8,
    exactly_one: bool,
) anyerror!bool {
    const branches = schema.keyword(keyword) orelse return false;
    if (branches.value != .array) return false;
    var unchanged_count: usize = 0;
    for (branches.value.array, 0..) |_, index| {
        var selector: [20]u8 = undefined;
        const name = try std.fmt.bufPrint(&selector, "{d}", .{index});
        const child = schema.child(keyword, name) orelse continue;
        if ((try validate.validateSubschema(alloc, plan, child, instance, .{})).len == 0) {
            unchanged_count += 1;
        }
    }
    if ((!exactly_one and unchanged_count > 0) or (exactly_one and unchanged_count == 1))
        return true;
    if (exactly_one and unchanged_count > 1) return true;

    if (matchingDiscriminator(alloc, schema, branches.value.array, keyword, instance)) |index| {
        var selector: [20]u8 = undefined;
        const name = try std.fmt.bufPrint(&selector, "{d}", .{index});
        const child = schema.child(keyword, name) orelse return false;
        const candidate = try cloneNode(alloc, instance);
        var candidate_changes: std.ArrayListUnmanaged(Change) = .empty;
        try fitNode(alloc, plan, child, candidate, path, &candidate_changes);
        if ((try validate.validateSubschema(alloc, plan, child, candidate, .{})).len == 0) {
            instance.* = candidate.*;
            try changes.appendSlice(alloc, candidate_changes.items);
        }
        return true;
    }

    var winner: ?jv.Node = null;
    var winner_changes: []const Change = &.{};
    var fitted_count: usize = 0;
    for (branches.value.array, 0..) |_, index| {
        var selector: [20]u8 = undefined;
        const name = try std.fmt.bufPrint(&selector, "{d}", .{index});
        const child = schema.child(keyword, name) orelse continue;
        const branch = try cloneNode(alloc, instance);
        var candidate_changes: std.ArrayListUnmanaged(Change) = .empty;
        try fitNode(alloc, plan, child, branch, path, &candidate_changes);
        if ((try validate.validateSubschema(alloc, plan, child, branch, .{})).len == 0) {
            fitted_count += 1;
            if (winner == null) {
                winner = branch.*;
                winner_changes = try candidate_changes.toOwnedSlice(alloc);
            }
            if (!exactly_one) break;
        }
    }
    if (winner) |fitted| {
        if (!exactly_one or fitted_count == 1) {
            instance.* = fitted;
            try changes.appendSlice(alloc, winner_changes);
        }
    }
    return true;
}

fn matchingDiscriminator(
    alloc: std.mem.Allocator,
    schema: *const compile.Node,
    branches: []const *jv.Node,
    keyword: []const u8,
    instance: *const jv.Node,
) ?usize {
    for (branches, 0..) |_, index| {
        var selector: [20]u8 = undefined;
        const name = std.fmt.bufPrint(&selector, "{d}", .{index}) catch continue;
        const branch = schema.child(keyword, name) orelse continue;
        if (matchesConstOrEnum(alloc, branch, instance)) return index;
    }
    return null;
}

fn matchesConstOrEnum(alloc: std.mem.Allocator, schema: *const compile.Node, value: *const jv.Node) bool {
    if (schema.keyword("const")) |constant| if (jsonEqual(alloc, value, constant)) return true;
    if (schema.keyword("enum")) |enumeration| {
        if (enumeration.value == .array) for (enumeration.value.array) |item|
            if (jsonEqual(alloc, value, item)) return true;
    }
    if (value.value == .object) {
        if (schema.keyword("properties")) |properties| {
            if (properties.value == .object) for (properties.value.object) |property| {
                const actual = objectValue(value.value.object, property.key) orelse continue;
                const child = schema.child("properties", property.key) orelse continue;
                if (matchesConstOrEnum(alloc, child, actual)) return true;
            };
        }
    }
    return false;
}

fn jsonEqual(alloc: std.mem.Allocator, left: *const jv.Node, right: *const jv.Node) bool {
    switch (left.value) {
        .null_value => return right.value == .null_value,
        .boolean => |value| return right.value == .boolean and value == right.value.boolean,
        .number => |text| {
            if (right.value != .number) return false;
            const a = number.parse(alloc, text) catch return false;
            const b = number.parse(alloc, right.value.number) catch return false;
            return number.equal(a, b);
        },
        .string => |value| return right.value == .string and std.mem.eql(u8, value, right.value.string),
        .array => |items| {
            if (right.value != .array or items.len != right.value.array.len) return false;
            for (items, right.value.array) |a, b| if (!jsonEqual(alloc, a, b)) return false;
            return true;
        },
        .object => |members| {
            if (right.value != .object or members.len != right.value.object.len) return false;
            for (members) |member| {
                const other = objectValue(right.value.object, member.key) orelse return false;
                if (!jsonEqual(alloc, member.value, other)) return false;
            }
            return true;
        },
    }
}

fn cloneNode(alloc: std.mem.Allocator, source: *const jv.Node) !*jv.Node {
    const copy = try alloc.create(jv.Node);
    copy.* = source.*;
    switch (source.value) {
        .object => |members| {
            const cloned = try alloc.alloc(jv.Member, members.len);
            for (members, 0..) |member, index| cloned[index] = .{
                .key = member.key,
                .value = try cloneNode(alloc, member.value),
            };
            copy.value = .{ .object = cloned };
        },
        .array => |items| {
            const cloned = try alloc.alloc(*jv.Node, items.len);
            for (items, 0..) |item, index| cloned[index] = try cloneNode(alloc, item);
            copy.value = .{ .array = cloned };
        },
        else => {},
    }
    return copy;
}

fn allowsType(type_node: *const jv.Node, name: []const u8) bool {
    return switch (type_node.value) {
        .string => |value| std.mem.eql(u8, value, name),
        .array => |values| blk: {
            for (values) |value| if (value.value == .string and std.mem.eql(u8, value.value.string, name)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn instanceTypeAllowed(type_node: *const jv.Node, instance: *const jv.Node) bool {
    const name = switch (instance.value) {
        .null_value => "null",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .object => "object",
        .array => "array",
    };
    if (std.mem.eql(u8, name, "number") and allowsType(type_node, "integer")) return true;
    return allowsType(type_node, name);
}

fn containsMember(members: []const jv.Member, key: []const u8) bool {
    for (members) |member| if (std.mem.eql(u8, member.key, key)) return true;
    return false;
}

fn objectValue(members: []const jv.Member, key: []const u8) ?*jv.Node {
    for (members) |member| if (std.mem.eql(u8, member.key, key)) return member.value;
    return null;
}

fn appendPath(alloc: std.mem.Allocator, path: []const u8, token: []const u8) ![]const u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    try output.appendSlice(alloc, path);
    try output.append(alloc, '/');
    for (token) |byte| switch (byte) {
        '~' => try output.appendSlice(alloc, "~0"),
        '/' => try output.appendSlice(alloc, "~1"),
        else => try output.append(alloc, byte),
    };
    return output.toOwnedSlice(alloc);
}

fn appendIndex(alloc: std.mem.Allocator, path: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/{d}", .{ path, index });
}

test "fit coerces exact values and leaves valid values alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema_doc = try jv.parse(alloc, "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\"},\"s\":{\"type\":\"string\"}}}");
    const schema_plan = try compile.compile(alloc, schema_doc, .{});
    const invalid = try jv.parse(alloc, "{\"n\":\"12.50\",\"s\":\"same\"}");
    const result = try apply(alloc, &schema_plan, invalid.root);
    try std.testing.expectEqualStrings("{\"n\":12.50,\"s\":\"same\"}", try jv.stringify(alloc, result.node));
    try std.testing.expectEqual(@as(usize, 1), result.changes.len);
    const valid = try jv.parse(alloc, "{\"n\":12.50,\"s\":\"same\"}");
    const unchanged = try apply(alloc, &schema_plan, valid.root);
    try std.testing.expectEqual(@as(usize, 0), unchanged.changes.len);
}

test "fit defaults, drops extras, and wraps array items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema_doc = try jv.parse(alloc, "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\",\"default\":7},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}},\"additionalProperties\":false}");
    const schema_plan = try compile.compile(alloc, schema_doc, .{});
    const input = try jv.parse(alloc, "{\"tags\":\"3\",\"extra\":true}");
    const result = try apply(alloc, &schema_plan, input.root);
    const output = try jv.stringify(alloc, result.node);
    try std.testing.expectEqualStrings("{\"tags\":[3],\"n\":7}", output);
    try std.testing.expectEqual(@as(usize, 3), result.changes.len);
}

test "fit respects draft integer coercion and branch copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema_doc = try jv.parse(alloc, "{\"$schema\":\"http://json-schema.org/draft-04/schema#\",\"type\":\"integer\"}");
    const schema_plan = try compile.compile(alloc, schema_doc, .{});
    const input = try jv.parse(alloc, "\"12.0\"");
    const result = try apply(alloc, &schema_plan, input.root);
    try std.testing.expectEqualStrings("\"12.0\"", try jv.stringify(alloc, result.node));
    try std.testing.expectEqual(@as(usize, 0), result.changes.len);
}

test "fit applies matching branch on a copy and prefers unchanged anyOf branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema_doc = try jv.parse(alloc,
        \\{"anyOf":[
        \\ {"type":"object","properties":{"kind":{"const":"a"},"n":{"type":"integer"}},"required":["kind","n"],"additionalProperties":false},
        \\ {"type":"object","properties":{"kind":{"const":"b"},"n":{"type":"string"}},"required":["kind","n"],"additionalProperties":false}
        \\]}
    );
    const plan = try compile.compile(alloc, schema_doc, .{});
    const input = try jv.parse(alloc, "{\"kind\":\"a\",\"n\":\"9007199254740993\"}");
    const result = try apply(alloc, &plan, input.root);
    try std.testing.expectEqualStrings("{\"kind\":\"a\",\"n\":9007199254740993}", try jv.stringify(alloc, result.node));
    try std.testing.expect((try validate.validate(alloc, &plan, result.node, .{})).len == 0);

    const unchanged_input = try jv.parse(alloc, "{\"kind\":\"b\",\"n\":\"x\"}");
    const unchanged = try apply(alloc, &plan, unchanged_input.root);
    try std.testing.expectEqual(@as(usize, 0), unchanged.changes.len);
}

test "fit rejects coercions that lose information and oneOf ambiguity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema_doc = try jv.parse(alloc,
        \\{"oneOf":[{"type":"number"},{"type":"integer"}]}
    );
    const plan = try compile.compile(alloc, schema_doc, .{});
    const input = try jv.parse(alloc, "\"2\"");
    const result = try apply(alloc, &plan, input.root);
    try std.testing.expectEqualStrings("\"2\"", try jv.stringify(alloc, result.node));
    try std.testing.expect((try validate.validate(alloc, &plan, result.node, .{})).len != 0);

    const integer_doc = try jv.parse(alloc, "{\"type\":\"integer\"}");
    const integer_plan = try compile.compile(alloc, integer_doc, .{});
    const lossy = try jv.parse(alloc, "\"12.5\"");
    const unchanged = try apply(alloc, &integer_plan, lossy.root);
    try std.testing.expectEqualStrings("\"12.5\"", try jv.stringify(alloc, unchanged.node));
    try std.testing.expectEqual(@as(usize, 0), unchanged.changes.len);
}

test "fit output validates and a second fit is idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema_doc = try jv.parse(alloc,
        \\{"type":"object","properties":{"amount":{"type":"number","default":1.5},"enabled":{"type":"boolean"}},"required":["amount","enabled"],"additionalProperties":false}
    );
    const plan = try compile.compile(alloc, schema_doc, .{});
    const cases = [_][]const u8{
        "{\"amount\":\"12.50\",\"enabled\":\"true\"}",
        "{\"amount\":9007199254740993,\"enabled\":false}",
        "{\"amount\":null,\"enabled\":\"false\"}",
    };
    for (cases) |source| {
        const doc = try jv.parse(alloc, source);
        const fitted = try apply(alloc, &plan, doc.root);
        const remaining = try validate.validate(alloc, &plan, fitted.node, .{});
        if (std.mem.eql(u8, source, cases[2])) {
            try std.testing.expect(remaining.len != 0);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 0), remaining.len);
        const second = try apply(alloc, &plan, fitted.node);
        try std.testing.expectEqual(@as(usize, 0), second.changes.len);
    }
}

test "fit covers Appendix A exactness and scalar coercions" {
    try expectFit("{\"type\":\"string\"}", "true", "\"true\"");
    try expectFit("{\"type\":\"boolean\"}", "\"false\"", "false");
    try expectFit("{\"type\":\"string\"}", "1e+08", "\"1e+08\"");
    try expectFit("{\"type\":\"number\"}", "\"12.50\"", "12.50");
    try expectFit("{\"type\":\"integer\"}", "\"9007199254740993\"", "9007199254740993");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const draft6_schema = try jv.parse(alloc,
        \\{"$schema":"http://json-schema.org/draft-06/schema#","type":"integer"}
    );
    const draft6_plan = try compile.compile(alloc, draft6_schema, .{});
    const decimal_integer = try jv.parse(alloc, "\"12.0\"");
    const fitted = try apply(alloc, &draft6_plan, decimal_integer.root);
    try std.testing.expectEqualStrings("12.0", try jv.stringify(alloc, fitted.node));
    try std.testing.expectEqual(@as(usize, 1), fitted.changes.len);

    const null_schema = try jv.parse(alloc, "{\"type\":\"number\"}");
    const null_plan = try compile.compile(alloc, null_schema, .{});
    const null_value = try jv.parse(alloc, "null");
    const null_result = try apply(alloc, &null_plan, null_value.root);
    try std.testing.expectEqualStrings("null", try jv.stringify(alloc, null_result.node));
    try std.testing.expectEqual(@as(usize, 0), null_result.changes.len);
    const null_string = try jv.parse(alloc, "{\"type\":\"string\"}");
    const null_string_plan = try compile.compile(alloc, null_string, .{});
    const null_for_string = try jv.parse(alloc, "null");
    try std.testing.expectEqual(
        @as(usize, 0),
        (try apply(alloc, &null_string_plan, null_for_string.root)).changes.len,
    );
    const null_boolean = try jv.parse(alloc, "{\"type\":\"boolean\"}");
    const null_boolean_plan = try compile.compile(alloc, null_boolean, .{});
    const null_for_boolean = try jv.parse(alloc, "null");
    try std.testing.expectEqual(
        @as(usize, 0),
        (try apply(alloc, &null_boolean_plan, null_for_boolean.root)).changes.len,
    );

    const bool_number_schema = try jv.parse(alloc, "{\"type\":\"number\"}");
    const bool_number_plan = try compile.compile(alloc, bool_number_schema, .{});
    const boolean = try jv.parse(alloc, "true");
    const boolean_result = try apply(alloc, &bool_number_plan, boolean.root);
    try std.testing.expectEqualStrings("true", try jv.stringify(alloc, boolean_result.node));
    try std.testing.expectEqual(@as(usize, 0), boolean_result.changes.len);
}

test "fit uses unchanged anyOf branches and applies defaults only in the winning oneOf branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const any_schema = try jv.parse(alloc,
        \\{"anyOf":[
        \\ {"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":false},
        \\ {"type":"object","properties":{"b":{"type":"string"}},"additionalProperties":false}
        \\]}
    );
    const any_plan = try compile.compile(alloc, any_schema, .{});
    const value = try jv.parse(alloc, "{\"b\":\"x\"}");
    const any_result = try apply(alloc, &any_plan, value.root);
    try std.testing.expectEqualStrings("{\"b\":\"x\"}", try jv.stringify(alloc, any_result.node));
    try std.testing.expectEqual(@as(usize, 0), any_result.changes.len);

    const one_schema = try jv.parse(alloc,
        \\{"oneOf":[
        \\ {"type":"object","properties":{"kind":{"const":"a"},"extra":{"type":"integer","default":7}},"required":["kind","extra"]},
        \\ {"type":"object","properties":{"kind":{"const":"b"}},"required":["kind"]}
        \\]}
    );
    const one_plan = try compile.compile(alloc, one_schema, .{});
    const input = try jv.parse(alloc, "{\"kind\":\"a\"}");
    const one_result = try apply(alloc, &one_plan, input.root);
    try std.testing.expectEqualStrings("{\"kind\":\"a\",\"extra\":7}", try jv.stringify(alloc, one_result.node));
    try std.testing.expectEqual(@as(usize, 0), (try validate.validate(alloc, &one_plan, one_result.node, .{})).len);
}

fn expectFit(schema_source: []const u8, input_source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema_doc = try jv.parse(alloc, schema_source);
    const plan = try compile.compile(alloc, schema_doc, .{});
    const input = try jv.parse(alloc, input_source);
    const result = try apply(alloc, &plan, input.root);
    try std.testing.expectEqualStrings(expected, try jv.stringify(alloc, result.node));
    try std.testing.expectEqual(@as(usize, 0), (try validate.validate(alloc, &plan, result.node, .{})).len);
}
