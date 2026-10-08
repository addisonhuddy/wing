const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const registry_mod = @import("registry.zig");
const term = @import("term.zig");
const jv = @import("jv.zig");
const header = @import("header.zig");
const app = @import("app.zig");
const schema_cache = @import("schema_cache.zig");
const schema_compile = @import("schema/compile.zig");
const uri = @import("schema/uri.zig");
const fatal = app.fatal;
const writeStdout = app.writeStdout;
const has = app.has;
const isTty = app.isTty;
const emitJson = app.emitJson;
const jsonField = app.jsonField;
const textField = app.textField;
const subjectForTopic = app.subjectForTopic;
const validVersion = app.validVersion;
const optionError = app.optionError;
const registryDescription = app.registryDescription;
const noSchemaMessage = app.noSchemaMessage;
const topicFromSubject = app.topicFromSubject;
const hasVersion = app.hasVersion;
const latestVersion = app.latestVersion;
const unknownVersionMessage = app.unknownVersionMessage;
const registryFor = app.registryFor;
const commandError = app.commandError;
const headerParseableGuid = app.headerParseableGuid;
const allocPrint = app.allocPrint;

pub fn run(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    var ref: ?[]const u8 = null;
    const meta = has(args, "--meta");
    const key = has(args, "--key");
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--meta") or std.mem.eql(u8, arg, "--key")) continue;
        if (std.mem.startsWith(u8, arg, "-")) fatal(optionError(arg, &.{ "--meta", "--key" }).?, global.errors_json, "get");
        if (ref == null) ref = arg else fatal("unexpected argument", global.errors_json, "get");
    }
    const reference = ref orelse fatal("missing REF", global.errors_json, "get");
    const settings = app.settingsForCache(init, global, "get");
    var reg = registryFor(init, settings);
    var schema: std.json.Value = undefined;
    var subject: ?[]const u8 = null;
    var version_text: ?[]const u8 = null;
    const guid_reference = reference.len == 36 and headerParseableGuid(reference);
    var cached = false;
    if (guid_reference) {
        if (settings.schema_dir) |directory| {
            const cached_schema = schema_cache.read(io, alloc, directory, reference) catch |err|
                fatal(allocPrint(alloc, "invalid schema cache entry for GUID '{s}': {s}", .{ reference, @errorName(err) }), global.errors_json, "get");
            if (cached_schema) |value| {
                schema = value;
                cached = true;
                subject = textField(schema, "subject") orelse if (textField(schema, "topic")) |topic|
                    try subjectForTopic(alloc, topic, key)
                else
                    null;
                if (jsonField(schema, "version")) |resolved|
                    version_text = registry_mod.valueText(alloc, resolved) catch null;
            }
        }
    }
    if (cached) {
        if (version_text == null) version_text = "latest";
    } else if (guid_reference) {
        if (settings.urls.len == 0)
            fatal("no Schema Registry configured; pass --registry URL, set SCHEMA_REGISTRY_URL, or run wing registry init", global.errors_json, "get");
        schema = reg.schemaGuid(reference) catch |err| {
            if (reg.last_status == 404)
                fatal(try std.fmt.allocPrint(alloc, "schema GUID '{s}' not found in {s}", .{ reference, registryDescription(alloc, global, settings) }), global.errors_json, "get");
            commandError(&reg, err, global, "get");
        };
        const loc = reg.guidLocation(reference, key) catch |err| {
            if (reg.last_status == 404)
                fatal(try std.fmt.allocPrint(alloc, "schema GUID '{s}' not found in {s}", .{ reference, registryDescription(alloc, global, settings) }), global.errors_json, "get");
            commandError(&reg, err, global, "get");
        };
        subject = loc.subject;
        version_text = loc.version;
        if (subject == null or version_text == null)
            fatal("GUID is not registered under a default-context topic subject", global.errors_json, "get");
    } else {
        if (settings.urls.len == 0)
            fatal("no Schema Registry configured; pass --registry URL, set SCHEMA_REGISTRY_URL, or run wing registry init", global.errors_json, "get");
        const at = std.mem.lastIndexOfScalar(u8, reference, '@');
        const raw_subject = if (at) |idx| reference[0..idx] else reference;
        if (at) |idx| if (!validVersion(reference[idx + 1 ..], true))
            fatal("version must be 'latest' or a positive integer", global.errors_json, "get");
        subject = try subjectForTopic(alloc, raw_subject, key);
        const versions = reg.versions(subject.?) catch |err| {
            if (reg.last_status == 404)
                fatal(noSchemaMessage(alloc, topicFromSubject(raw_subject), subject.?, global, settings), global.errors_json, "get");
            commandError(&reg, err, global, "get");
        };
        if (versions != .array or versions.array.items.len == 0)
            fatal(noSchemaMessage(alloc, topicFromSubject(raw_subject), subject.?, global, settings), global.errors_json, "get");
        const requested_version = if (at) |idx| reference[idx + 1 ..] else "latest";
        if (!std.mem.eql(u8, requested_version, "latest") and !hasVersion(alloc, versions, requested_version))
            fatal(unknownVersionMessage(alloc, subject.?, requested_version, versions), global.errors_json, "get");
        version_text = if (std.mem.eql(u8, requested_version, "latest")) latestVersion(alloc, versions) else requested_version;
        schema = reg.schema(subject.?, version_text.?) catch |err| {
            if (reg.last_status == 404)
                fatal(unknownVersionMessage(alloc, subject.?, version_text.?, versions), global.errors_json, "get");
            commandError(&reg, err, global, "get");
        };
        if (jsonField(schema, "version")) |resolved|
            version_text = registry_mod.valueText(alloc, resolved) catch version_text;
    }

    const topic_name = if (cached)
        textField(schema, "topic")
    else if (subject) |s|
        if (std.mem.endsWith(u8, s, "-value"))
            s[0 .. s.len - "-value".len]
        else if (std.mem.endsWith(u8, s, "-key"))
            s[0 .. s.len - "-key".len]
        else
            s
    else
        null;
    const metadata = .{
        .topic = topic_name,
        .version = jsonField(schema, "version") orelse std.json.Value{ .number_string = version_text orelse "latest" },
        .id = jsonField(schema, "id"),
        .guid = jsonField(schema, "guid"),
        .compat = if (cached) textField(schema, "compat") orelse "BACKWARD" else if (subject) |s| reg.compat(s) catch "BACKWARD" else "BACKWARD",
        .schema = jsonField(schema, "schema"),
        .references = jsonField(schema, "references"),
        .metadata = jsonField(schema, "metadata"),
        .ruleSet = jsonField(schema, "ruleSet"),
    };
    if (!cached) {
        if (settings.schema_dir) |directory| {
            if (jsonField(schema, "references")) |references| {
                if (references == .array and references.array.items.len > 0) {
                    _ = reg.referenceResources(schema, directory) catch |err| commandError(&reg, err, global, "get");
                }
            }
            if (textField(schema, "guid")) |guid| {
                const cache_entry = .{
                    .topic = metadata.topic,
                    .version = metadata.version,
                    .id = metadata.id,
                    .guid = metadata.guid,
                    .compat = metadata.compat,
                    .schema = metadata.schema,
                    .references = metadata.references,
                    .metadata = metadata.metadata,
                    .ruleSet = metadata.ruleSet,
                    .subject = subject,
                };
                schema_cache.write(io, alloc, directory, guid, cache_entry) catch |err|
                    std.debug.print("wing get: could not write schema cache for GUID '{s}': {s}\n", .{ guid, @errorName(err) });
            }
        }
    }
    var bundled_schema: ?[]const u8 = null;
    if (!meta) {
        if (jsonField(schema, "references")) |references| {
            if (references == .array and references.array.items.len > 0) {
                const resources = if (cached)
                    try schema_cache.referenceResources(io, alloc, settings.schema_dir.?, schema)
                else
                    reg.referenceResources(schema, settings.schema_dir) catch |err| commandError(&reg, err, global, "get");
                bundled_schema = try bundleReferences(alloc, textField(schema, "schema") orelse fatal("registry response has no schema text", global.errors_json, "get"), resources);
                std.debug.print("wing get: bundled schema references; the bundled schema has a different GUID\n", .{});
            }
        }
    }
    if (meta) {
        try emitJson(alloc, io, metadata, global.errors_json, "get");
    } else {
        const schema_text = bundled_schema orelse textField(schema, "schema") orelse fatal("registry response has no schema text", global.errors_json, "get");
        const pretty = isTty(io, std.Io.File.stdout());
        if (pretty) {
            const parsed = jv.parse(alloc, schema_text) catch {
                writeStdout(io, schema_text, global.errors_json, "get");
                return;
            };
            const formatted = try jv.pretty(alloc, parsed.root, term.colorEnabled(io, init.environ_map));
            writeStdout(io, try std.fmt.allocPrint(alloc, "{s}\n", .{formatted}), global.errors_json, "get");
        } else {
            writeStdout(io, try std.fmt.allocPrint(alloc, "{s}\n", .{schema_text}), global.errors_json, "get");
        }
    }
}

fn bundleReferences(
    alloc: std.mem.Allocator,
    schema_text: []const u8,
    resources: []const schema_compile.ResourceSource,
) ![]const u8 {
    const parsed = try jv.parse(alloc, schema_text);
    const draft = try schema_compile.selectDraft(parsed.root, .{});
    const root_plan = try schema_compile.compile(alloc, parsed, .{});
    const root_base_uri = root_plan.root.base_uri;
    const defs_name: []const u8 = if (draft == .draft2019_09 or draft == .draft2020_12) "$defs" else "definitions";
    var bundled = try std.json.parseFromSliceLeaky(std.json.Value, alloc, schema_text, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    if (bundled != .object) return error.InvalidSchema;
    const defs = if (bundled.object.get(defs_name)) |existing| blk: {
        if (existing != .object) return error.InvalidSchema;
        break :blk existing;
    } else try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{}", .{ .allocate = .alloc_always });

    var mappings: std.StringHashMapUnmanaged([]const u8) = .empty;
    var anchors: std.StringHashMapUnmanaged([]const u8) = .empty;
    var def_object = defs.object;
    for (resources, 0..) |resource, index| {
        const key = try std.fmt.allocPrint(alloc, "wing_bundle_{d}", .{index});
        try mappings.put(alloc, resource.uri, key);
        try collectAnchors(alloc, resource.uri, resource.document.root, "", &anchors);
        const resolved_uri = try uri.resolve(alloc, root_base_uri, resource.uri);
        try mappings.put(alloc, resolved_uri, key);
        try collectAnchors(alloc, resolved_uri, resource.document.root, "", &anchors);
        const resource_plan = try schema_compile.compile(alloc, resource.document, .{ .base_uri = resolved_uri });
        const id_uri = resource_plan.root.base_uri;
        try mappings.put(alloc, id_uri, key);
        try collectAnchors(alloc, id_uri, resource.document.root, "", &anchors);
        if (std.mem.indexOfScalar(u8, id_uri, '#')) |fragment|
            try mappings.put(alloc, id_uri[0..fragment], key);
        const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, resource.document.source, .{
            .allocate = .alloc_always,
            .parse_numbers = false,
        });
        try def_object.put(alloc, key, value);
    }
    try bundled.object.put(alloc, defs_name, .{ .object = def_object });
    try rewriteBundledRefs(alloc, &bundled, defs_name, mappings, anchors);
    var output = std.Io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(bundled, .{}, &output.writer);
    return output.written();
}

fn rewriteBundledRefs(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
    defs_name: []const u8,
    mappings: std.StringHashMapUnmanaged([]const u8),
    anchors: std.StringHashMapUnmanaged([]const u8),
) anyerror!void {
    switch (value.*) {
        .object => {
            if (value.object.getPtr("$ref")) |reference| {
                if (reference.* == .string) {
                    if (rewriteReference(alloc, reference.string, defs_name, mappings, anchors)) |rewritten|
                        reference.* = .{ .string = rewritten };
                }
            }
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| try rewriteBundledRefs(alloc, entry.value_ptr, defs_name, mappings, anchors);
        },
        .array => {
            for (value.array.items) |*entry| try rewriteBundledRefs(alloc, entry, defs_name, mappings, anchors);
        },
        else => {},
    }
}

fn rewriteReference(
    alloc: std.mem.Allocator,
    reference: []const u8,
    defs_name: []const u8,
    mappings: std.StringHashMapUnmanaged([]const u8),
    anchors: std.StringHashMapUnmanaged([]const u8),
) ?[]const u8 {
    const hash = std.mem.indexOfScalar(u8, reference, '#');
    const name = if (hash) |at| reference[0..at] else reference;
    const definition = mappings.get(name) orelse return null;
    const fragment = if (hash) |at| reference[at..] else "";
    const suffix = if (fragment.len == 0)
        ""
    else if (std.mem.startsWith(u8, fragment, "#/"))
        fragment[1..]
    else blk: {
        const anchor_name = std.fmt.allocPrint(alloc, "{s}{s}", .{ name, fragment }) catch return null;
        break :blk anchors.get(anchor_name) orelse return null;
    };
    return std.fmt.allocPrint(alloc, "#/{s}/{s}{s}", .{ defs_name, definition, suffix }) catch null;
}

fn collectAnchors(
    alloc: std.mem.Allocator,
    resource_uri: []const u8,
    node: *const jv.Node,
    path: []const u8,
    anchors: *std.StringHashMapUnmanaged([]const u8),
) !void {
    if (node.value != .object) return;
    for ([_][]const u8{ "$anchor", "$dynamicAnchor" }) |key| {
        if (nodeField(node, key)) |anchor| {
            if (anchor.value == .string) try anchors.put(
                alloc,
                try std.fmt.allocPrint(alloc, "{s}#{s}", .{ resource_uri, anchor.value.string }),
                path,
            );
        }
    }
    for (node.value.object) |member| {
        if (std.mem.eql(u8, member.key, "properties") or std.mem.eql(u8, member.key, "patternProperties") or
            std.mem.eql(u8, member.key, "$defs") or std.mem.eql(u8, member.key, "definitions") or
            std.mem.eql(u8, member.key, "dependentSchemas") or std.mem.eql(u8, member.key, "dependencies"))
        {
            if (member.value.value != .object) continue;
            for (member.value.value.object) |entry| {
                const child_path = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{
                    path,
                    member.key,
                    try pointerEscape(alloc, entry.key),
                });
                try collectAnchors(alloc, resource_uri, entry.value, child_path, anchors);
            }
        } else if (member.value.value == .array and schemaContainer(member.key)) {
            for (member.value.value.array, 0..) |child, index| {
                const child_path = try std.fmt.allocPrint(alloc, "{s}/{s}/{d}", .{ path, member.key, index });
                try collectAnchors(alloc, resource_uri, child, child_path, anchors);
            }
        } else if (schemaContainer(member.key)) {
            const child_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, member.key });
            try collectAnchors(alloc, resource_uri, member.value, child_path, anchors);
        }
    }
}

fn schemaContainer(name: []const u8) bool {
    const names = [_][]const u8{ "properties", "patternProperties", "$defs", "definitions", "items", "prefixItems", "allOf", "anyOf", "oneOf", "not", "if", "then", "else", "additionalProperties", "contains" };
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn nodeField(node: *const jv.Node, name: []const u8) ?*const jv.Node {
    if (node.value != .object) return null;
    for (node.value.object) |member| if (std.mem.eql(u8, member.key, name)) return member.value;
    return null;
}

fn pointerEscape(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    for (text) |byte| switch (byte) {
        '~' => try output.appendSlice(alloc, "~0"),
        '/' => try output.appendSlice(alloc, "~1"),
        else => try output.append(alloc, byte),
    };
    return output.toOwnedSlice(alloc);
}

test "get bundles named registry references under draft-specific definitions" {
    const alloc = std.testing.allocator;
    const referenced = try jv.parse(alloc, "{\"type\":\"string\"}");
    const resources = [_]schema_compile.ResourceSource{.{
        .uri = "common.json",
        .document = referenced,
    }};
    const output = try bundleReferences(alloc, "{\"$ref\":\"common.json\"}", &resources);
    try std.testing.expect(output.len > 0 and output[0] == '{');
    try std.testing.expect(std.mem.indexOf(u8, output, "\"$ref\":\"#/definitions/wing_bundle_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"string\"") != null);

    const modern = try bundleReferences(alloc, "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"$ref\":\"common.json#/properties/name\"}", &resources);
    try std.testing.expect(std.mem.indexOf(u8, modern, "\"$ref\":\"#/$defs/wing_bundle_0/properties/name\"") != null);
}

test "get rewrites named reference anchors to bundled pointers" {
    const alloc = std.testing.allocator;
    const referenced = try jv.parse(alloc, "{\"properties\":{\"name\":{\"$anchor\":\"name\",\"type\":\"string\"}}}");
    const resources = [_]schema_compile.ResourceSource{.{ .uri = "common.json", .document = referenced }};
    const output = try bundleReferences(alloc, "{\"$ref\":\"common.json#name\"}", &resources);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"$ref\":\"#/definitions/wing_bundle_0/properties/name\"") != null);
}

test "get emits valid JSON when bundling an absolute registry reference" {
    const alloc = std.testing.allocator;
    const referenced = try jv.parse(alloc, "{\"$id\":\"https://example.test/common.json\",\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"string\"}},\"required\":[\"code\"]}");
    const resources = [_]schema_compile.ResourceSource{.{ .uri = "https://example.test/common.json", .document = referenced }};
    const output = try bundleReferences(
        alloc,
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"$ref\":\"https://example.test/common.json\"}",
        &resources,
    );
    try std.testing.expect(output.len > 0 and output[0] == '{');
    _ = try jv.parse(alloc, output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"$ref\":\"#/$defs/wing_bundle_0\"") != null);
}
