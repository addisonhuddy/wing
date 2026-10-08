const std = @import("std");
const cli = @import("cli.zig");
const app = @import("app.zig");
const registry_mod = @import("registry.zig");
const schema_compile = @import("schema/compile.zig");
const metaschemas = @import("schema/metaschemas.zig");
const validator = @import("schema/validate.zig");
const jv = @import("jv.zig");
const CompatibilityError = struct { type: []const u8, path: []const u8, description: []const u8 };

const Options = struct {
    topic: ?[]const u8 = null,
    check: bool = false,
    key: bool = false,
    meta: bool = false,
    fixtures: ?[]const u8 = null,
    compatibility: ?[]const u8 = null,
};

fn pushStderr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("wing push: " ++ fmt ++ "\n", args);
}

fn checkPassed(global: cli.Global) void {
    if (global.quiet) return;
    const diagnostics = app.Diagnostics.init("push", global);
    if (diagnostics.json) diagnostics.note("ok") else diagnostics.print("wing push: ok", .{});
}

pub fn run(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
    const alloc = init.arena.allocator();
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--check")) {
            options.check = true;
        } else if (std.mem.eql(u8, arg, "--key")) {
            options.key = true;
        } else if (std.mem.eql(u8, arg, "--meta")) {
            options.meta = true;
        } else if (std.mem.eql(u8, arg, "--fixtures") and index + 1 < args.len) {
            index += 1;
            options.fixtures = args[index];
        } else if (std.mem.eql(u8, arg, "--compat") and index + 1 < args.len) {
            index += 1;
            options.compatibility = args[index];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            app.fatal(app.optionError(arg, &.{ "--check", "--key", "--meta", "--fixtures", "--compat" }) orelse "unexpected argument", global.errors_json, "push");
        } else if (options.topic == null) {
            options.topic = arg;
        } else {
            app.fatal("unexpected argument", global.errors_json, "push");
        }
    }
    if (options.compatibility != null and options.check)
        app.fatal("--compat cannot be combined with --check", global.errors_json, "push");
    if (options.topic == null and !options.check) {
        if (global.errors_json)
            app.fatal("push needs a TOPIC (use 'wing push --check' to lint offline)", true, "push");
        std.debug.print("wing: push needs a TOPIC (use 'wing push --check' to lint offline)\nTry 'wing --help'\n", .{});
        std.process.exit(1);
    }

    var stdin_buffer: [8192]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const source = try stdin.interface.allocRemaining(alloc, .limited(16 * 1024 * 1024));
    if (source.len == 0) app.fatal("no schema on stdin", global.errors_json, "push");
    var envelope: ?std.json.Value = null;
    const schema_text = if (options.meta) blk: {
        envelope = std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{
            .allocate = .alloc_always,
            .parse_numbers = false,
        }) catch app.fatal("invalid --meta envelope JSON", global.errors_json, "push");
        const value = app.jsonField(envelope.?, "schema") orelse app.fatal("--meta envelope has no schema", global.errors_json, "push");
        if (value != .string) app.fatal("--meta envelope schema must be a string", global.errors_json, "push");
        break :blk value.string;
    } else source;
    const document = jv.parse(alloc, schema_text) catch app.fatal("schema is not valid JSON", global.errors_json, "push");
    const plan = schema_compile.compile(alloc, document, .{}) catch |err| {
        pushStderr("schema cannot be compiled: {s}", .{@errorName(err)});
        std.process.exit(2);
    };

    const allowed_refs = try referenceNames(alloc, envelope);
    var lint_failed = try lintSchema(alloc, &plan, document, allowed_refs, global);
    const settings = app.settingsForCache(init, global, "push");
    var reg = app.registryFor(init, settings);
    var reference_resources: []const schema_compile.ResourceSource = &.{};
    if (envelope) |meta_value| {
        if (app.jsonField(meta_value, "references")) |references| {
            if (references == .array and references.array.items.len > 0) {
                if (settings.urls.len == 0) {
                    pushStderr("missing referenced schemas; configure a registry before pushing --meta", .{});
                    std.process.exit(1);
                }
                for (references.array.items) |reference| {
                    const subject = app.textField(reference, "subject") orelse continue;
                    const version_value = app.jsonField(reference, "version") orelse continue;
                    const version = try registry_mod.valueText(alloc, version_value);
                    _ = reg.schema(subject, version) catch {
                        pushStderr("missing reference {s} version {s}", .{ subject, version });
                        std.process.exit(1);
                    };
                }
                reference_resources = reg.referenceResources(meta_value, settings.schema_dir) catch |err|
                    app.fatal(allocFmt(alloc, "cannot resolve --meta references: {s}", .{@errorName(err)}), global.errors_json, "push");
                const referenced_plan = schema_compile.compile(alloc, document, .{ .extra_resources = reference_resources }) catch |err| {
                    pushStderr("schema cannot be compiled with --meta references: {s}", .{@errorName(err)});
                    std.process.exit(2);
                };
                lint_failed = (try lintSchema(alloc, &referenced_plan, document, allowed_refs, global)) or lint_failed;
            }
        }
    }
    if (options.fixtures) |directory|
        lint_failed = (try checkFixtures(init, alloc, directory, &plan, global)) or lint_failed;
    if (lint_failed) std.process.exit(2);

    if (options.topic == null) return checkPassed(global);
    if (settings.urls.len == 0)
        app.fatal("no Schema Registry configured; pass --registry URL, set SCHEMA_REGISTRY_URL, or run wing registry init", global.errors_json, "push");
    const subject = try app.subjectForTopic(alloc, options.topic.?, options.key);
    const reference_payload = if (envelope) |value| value else std.json.Value.null;
    const registration = try requestValue(alloc, schema_text, reference_payload, options.meta);
    const payload = try stringify(alloc, registration);
    const escaped = try registry_mod.pathEscape(alloc, subject);
    const compat_override = if (options.compatibility) |level|
        try setCompatibility(alloc, &reg, escaped, level)
    else
        CompatState{};
    const compatibility_level = if (options.compatibility) |level| level else reg.compat(subject) catch "BACKWARD";
    if (!try compatibilityCheck(alloc, &reg, escaped, subject, payload, compatibility_level, global)) {
        if (options.compatibility != null) restoreCompatibility(&reg, escaped, compat_override);
        std.process.exit(2);
    }
    if (options.check) return checkPassed(global);

    if (reg.post(try std.fmt.allocPrint(alloc, "/subjects/{s}", .{escaped}), payload)) |existing_body| {
        const existing = std.json.parseFromSliceLeaky(std.json.Value, alloc, existing_body, .{
            .allocate = .alloc_always,
            .parse_numbers = false,
        }) catch .null;
        if (registry_mod.stringValue(registry_mod.objectValue(existing, "guid") orelse .null)) |guid| {
            const versions = reg.versions(subject) catch .null;
            if (versions == .array) {
                var latest_version: ?[]const u8 = null;
                for (versions.array.items) |version_value| {
                    const version = try registry_mod.valueText(alloc, version_value);
                    const found = reg.schema(subject, version) catch continue;
                    if (std.mem.eql(u8, registry_mod.stringValue(registry_mod.objectValue(found, "guid") orelse .null) orelse "", guid))
                        latest_version = version;
                }
                if (latest_version) |version| {
                    try writeGuid(init.io, guid);
                    pushStderr("{s} version {s} already has this schema", .{ subject, version });
                    return;
                }
            }
        }
    } else |_| {
        if (reg.last_status != 404) app.commandError(&reg, error.RegistryFailure, global, "push");
    }

    const registered_body = reg.post(try std.fmt.allocPrint(alloc, "/subjects/{s}/versions", .{escaped}), payload) catch |err| {
        if (options.compatibility != null) restoreCompatibility(&reg, escaped, compat_override);
        app.commandError(&reg, err, global, "push");
    };
    const response = std.json.parseFromSliceLeaky(std.json.Value, alloc, registered_body, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch app.fatal("invalid registration response", global.errors_json, "push");
    const guid = app.textField(response, "guid") orelse app.fatal("registry returned no schema GUID", global.errors_json, "push");
    try writeGuid(init.io, guid);
    const versions = reg.versions(subject) catch .null;
    const version = if (versions == .array) app.latestVersion(alloc, versions) else "latest";
    pushStderr("registered {s} version {s}", .{ subject, version });
}

const CompatState = struct { had_override: bool = false, level: ?[]const u8 = null };

fn setCompatibility(alloc: std.mem.Allocator, reg: *registry_mod.Registry, subject: []const u8, level: []const u8) !CompatState {
    const path = try std.fmt.allocPrint(alloc, "/config/{s}", .{subject});
    var state: CompatState = .{};
    if (reg.get(path)) |body| {
        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{ .allocate = .alloc_always }) catch .null;
        state.had_override = true;
        state.level = app.textField(value, "compatibilityLevel");
    } else |_| {
        if (reg.last_status != 404) app.commandError(reg, error.RegistryFailure, .{}, "push");
    }
    const request = try stringify(alloc, .{ .compatibility = level });
    _ = reg.put(path, request) catch |err| app.commandError(reg, err, .{}, "push");
    return state;
}

fn restoreCompatibility(reg: *registry_mod.Registry, subject: []const u8, state: CompatState) void {
    const path = std.fmt.allocPrint(reg.alloc, "/config/{s}", .{subject}) catch return;
    if (state.had_override) {
        const level = state.level orelse return;
        const body = std.fmt.allocPrint(reg.alloc, "{{\"compatibility\":\"{s}\"}}", .{level}) catch return;
        _ = reg.put(path, body) catch pushStderr("could not restore compatibility for {s}", .{subject});
    } else {
        _ = reg.delete(path) catch pushStderr("could not remove temporary compatibility for {s}", .{subject});
    }
}

fn compatibilityCheck(
    alloc: std.mem.Allocator,
    reg: *registry_mod.Registry,
    escaped_subject: []const u8,
    subject: []const u8,
    payload: []const u8,
    compatibility: []const u8,
    global: cli.Global,
) !bool {
    const path = try std.fmt.allocPrint(alloc, "/compatibility/subjects/{s}/versions/latest?verbose=true", .{escaped_subject});
    const body = reg.post(path, payload) catch |err| {
        if (reg.last_status == 404) return true;
        app.commandError(reg, err, .{}, "push");
    };
    const response = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{ .allocate = .alloc_always }) catch return error.InvalidResponse;
    const compatible = registry_mod.objectValue(response, "is_compatible");
    if (compatible == null or compatible.? != .bool or compatible.?.bool) return true;
    const messages = registry_mod.objectValue(response, "messages");
    const message_count = if (messages) |value| if (value == .array) value.array.items.len else 0 else 0;
    const count = if (message_count > 0) message_count else @intFromBool(registry_mod.objectValue(response, "message") != null);
    var errors = try alloc.alloc(CompatibilityError, count);
    var raw_messages = try alloc.alloc([]const u8, count);
    var error_count: usize = 0;
    var raw_count: usize = 0;
    if (message_count > 0) {
        for (messages.?.array.items) |message| {
            const raw = registry_mod.stringValue(message) orelse continue;
            if (parseCompatibilityMessage(raw)) |parsed| {
                errors[error_count] = parsed;
                error_count += 1;
            } else if (global.verbose or !isVerboseMetadata(raw)) {
                raw_messages[raw_count] = raw;
                raw_count += 1;
            }
        }
    } else if (registry_mod.objectValue(response, "message")) |message| {
        const raw = registry_mod.stringValue(message) orelse "incompatible schema";
        if (parseCompatibilityMessage(raw)) |parsed| {
            errors[error_count] = parsed;
            error_count += 1;
        } else {
            raw_messages[raw_count] = raw;
            raw_count += 1;
        }
    }
    const versions = reg.versions(subject) catch null;
    const version = if (versions) |value|
        if (value == .array and value.array.items.len > 0) app.latestVersion(alloc, value) else "latest"
    else
        "latest";
    if (global.errors_json) {
        var emitted = false;
        for (errors[0..error_count]) |item| {
            try pushFinding(alloc, global, item.path, "", "not compatible with {s} version {s} ({s}): {s}: {s}", .{
                subject, version, compatibility, item.type, item.description,
            });
            emitted = true;
        }
        for (raw_messages[0..raw_count]) |raw| {
            try pushFinding(alloc, global, "", "", "{s}", .{raw});
            emitted = true;
        }
        if (!emitted)
            try pushFinding(alloc, global, "", "", "not compatible with {s} version {s} ({s})", .{
                subject, version, compatibility,
            });
    } else {
        pushStderr("not compatible with {s} version {s} ({s}):", .{ subject, version, compatibility });
        for (errors[0..error_count]) |item|
            if (item.type.len > 0)
                pushStderr("  {s} at {s}: {s}", .{ item.type, item.path, item.description });
        for (raw_messages[0..raw_count]) |raw| pushStderr("{s}", .{raw});
    }
    return false;
}

fn parseCompatibilityMessage(message: []const u8) ?CompatibilityError {
    const kind = pseudoField(message, "errorType") orelse return null;
    var description = pseudoField(message, "description") orelse return null;
    if (description.len > 0 and description[description.len - 1] == '\'')
        description = description[0 .. description.len - 1];
    var path: []const u8 = "";
    if (std.mem.indexOf(u8, description, "path '")) |start| {
        const from = start + "path '".len;
        if (std.mem.indexOfScalarPos(u8, description, from, '\'')) |end|
            path = description[from..end];
    }
    if (std.mem.startsWith(u8, path, "#")) path = path[1..];
    return .{ .type = kind, .path = path, .description = description };
}

fn pseudoField(message: []const u8, name: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, message, name) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, message, at + name.len, ':') orelse return null;
    var start = colon + 1;
    while (start < message.len and std.ascii.isWhitespace(message[start])) start += 1;
    if (start == message.len) return null;
    const quote = if (message[start] == '"' or message[start] == '\'') message[start] else 0;
    if (quote != 0) {
        start += 1;
        var end = start;
        while (end < message.len) : (end += 1) {
            if (message[end] == '\\') {
                end += 1;
                continue;
            }
            if (message[end] == quote) return message[start..end];
            if (message[end] == '}') return std.mem.trimEnd(u8, message[start..end], " \t\r\n");
        }
        return null;
    }
    var end = start;
    while (end < message.len and message[end] != ',' and message[end] != '}') : (end += 1) {}
    return std.mem.trim(u8, message[start..end], " \t\r\n");
}

test "parses Schema Registry compatibility pseudo JSON with a trailing apostrophe" {
    const parsed = parseCompatibilityMessage(
        "{errorType:\"TYPE_CHANGED\", description:\"A type at path '#/properties/order_id' is different between the new schema and the old schema'}",
    ).?;
    try std.testing.expectEqualStrings("TYPE_CHANGED", parsed.type);
    try std.testing.expectEqualStrings("/properties/order_id", parsed.path);
    try std.testing.expectEqualStrings(
        "A type at path '#/properties/order_id' is different between the new schema and the old schema",
        parsed.description,
    );
}

fn isVerboseMetadata(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "oldSchema") != null or
        std.mem.indexOf(u8, message, "validateFields") != null or
        std.mem.indexOf(u8, message, "compatibility") != null;
}

fn requestValue(
    alloc: std.mem.Allocator,
    schema_text: []const u8,
    envelope: std.json.Value,
    meta: bool,
) !std.json.Value {
    var value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{}", .{ .allocate = .alloc_always });
    try value.object.put(alloc, "schemaType", .{ .string = "JSON" });
    try value.object.put(alloc, "schema", .{ .string = schema_text });
    if (meta) {
        for ([_][]const u8{ "references", "metadata", "ruleSet" }) |name| {
            if (app.jsonField(envelope, name)) |field| try value.object.put(alloc, name, field);
        }
    }
    return value;
}

fn stringify(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.written();
}

fn writeGuid(io: std.Io, guid: []const u8) !void {
    var output = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    try output.writer.writeAll(guid);
    try output.writer.writeByte('\n');
    app.writeStdout(io, output.written(), false, "push");
}

fn allocFmt(alloc: std.mem.Allocator, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, format, args) catch "push failed";
}

fn referenceNames(alloc: std.mem.Allocator, envelope: ?std.json.Value) ![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    if (envelope) |meta_value| {
        if (app.jsonField(meta_value, "references")) |references| {
            if (references == .array) for (references.array.items) |reference| {
                if (app.textField(reference, "name")) |name| try names.append(alloc, name);
            };
        }
    }
    return names.toOwnedSlice(alloc);
}

fn lintSchema(
    alloc: std.mem.Allocator,
    plan: *const schema_compile.Plan,
    document: jv.Document,
    allowed_refs: []const []const u8,
    global: cli.Global,
) !bool {
    var failed = false;
    var meta_source: ?[]const u8 = null;
    for (metaschemas.entries) |entry| {
        if (entry.draft == plan.draft and std.mem.endsWith(u8, entry.uri, "/schema")) {
            meta_source = entry.source;
            break;
        }
    }
    if (meta_source) |source| {
        const meta_document = try jv.parse(alloc, source);
        var resources: std.ArrayListUnmanaged(schema_compile.ResourceSource) = .empty;
        for (metaschemas.entries) |entry| {
            const resource_document = try jv.parse(alloc, entry.source);
            try resources.append(alloc, .{ .uri = entry.uri, .document = resource_document });
        }
        const meta_plan = try schema_compile.compile(alloc, meta_document, .{
            .default_draft = plan.draft,
            .extra_resources = resources.items,
        });
        const failures = try validator.validate(alloc, &meta_plan, document.root, .{});
        for (failures) |failure| {
            try pushFinding(alloc, global, failure.instanceLocation, failure.keywordLocation, "schema metaschema error at {s}: {s}", .{
                lintLocation(failure.keywordLocation), failure.@"error",
            });
            failed = true;
        }
    }
    try lintNode(alloc, plan, plan.root, allowed_refs, &failed, global);
    return failed;
}

fn lintNode(
    alloc: std.mem.Allocator,
    plan: *const schema_compile.Plan,
    schema: *const schema_compile.Node,
    allowed_refs: []const []const u8,
    failed: *bool,
    global: cli.Global,
) !void {
    if (schema.keyword("default")) |default_value| {
        const failures = try validator.validateSubschema(alloc, plan, schema, default_value, .{});
        for (failures) |failure| {
            try pushFinding(alloc, global, schema.location, failure.keywordLocation, "default at {s} is invalid: {s}", .{
                lintLocation(schema.location), failure.@"error",
            });
            failed.* = true;
        }
    }
    if (hasUnsatisfiableTypeEnum(schema.schema)) {
        try pushFinding(alloc, global, schema.location, "", "unsatisfiable type and enum at {s}", .{lintLocation(schema.location)});
        failed.* = true;
    }
    if (hasCombinatorAdditionalProperties(schema.schema, schema.draft)) {
        const suggestion = if (schema.draft == .draft2019_09 or schema.draft == .draft2020_12)
            "use unevaluatedProperties or declare the properties at the top level"
        else
            "declare the properties at the top level";
        try pushFinding(alloc, global, schema.location, "", "additionalProperties:false with properties only inside a combinator at {s}; {s}", .{
            lintLocation(schema.location), suggestion,
        });
        failed.* = true;
    }
    if (schema.schema.value == .object) {
        for (schema.schema.value.object) |member| {
            const name = member.key;
            if (std.mem.eql(u8, name, "$ref") and member.value.value == .string) {
                const reference = member.value.value.string;
                if (isLocalFileRef(reference) and !allowedReference(reference, allowed_refs)) {
                    try pushFinding(alloc, global, schema.location, "", "local-file $ref '{s}' at {s} does not resolve inside the schema; declare references via --meta", .{
                        reference, lintLocation(schema.location),
                    });
                    failed.* = true;
                }
            }
            if (knownKeyword(name) or annotationKeyword(name)) continue;
            if (nearestKeyword(name)) |candidate| {
                try pushFinding(alloc, global, schema.location, "", "unknown keyword '{s}' at {s} (did you mean '{s}'?)", .{
                    name, lintLocation(schema.location), candidate,
                });
                failed.* = true;
            } else {
                try pushNote(alloc, global, schema.location, "warning: unknown keyword '{s}' at {s}", .{
                    name, lintLocation(schema.location),
                });
            }
        }
    }
    for (schema.children) |child| try lintNode(alloc, plan, child.node, allowed_refs, failed, global);
}

fn knownKeyword(name: []const u8) bool {
    const names = [_][]const u8{
        "$schema",           "$id",              "id",                    "$ref",            "$anchor",          "$dynamicAnchor", "$dynamicRef",       "$recursiveRef",        "$recursiveAnchor",
        "$defs",             "definitions",      "type",                  "enum",            "const",            "title",          "description",       "default",              "examples",
        "$comment",          "deprecated",       "readOnly",              "writeOnly",       "multipleOf",       "maximum",        "exclusiveMaximum",  "minimum",              "exclusiveMinimum",
        "maxLength",         "minLength",        "pattern",               "additionalItems", "items",            "maxItems",       "minItems",          "uniqueItems",          "contains",
        "maxContains",       "minContains",      "maxProperties",         "minProperties",   "required",         "properties",     "patternProperties", "additionalProperties", "dependencies",
        "dependentRequired", "dependentSchemas", "propertyNames",         "if",              "then",             "else",           "allOf",             "anyOf",                "oneOf",
        "not",               "unevaluatedItems", "unevaluatedProperties", "contentEncoding", "contentMediaType", "contentSchema",  "format",            "$vocabulary",
    };
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn annotationKeyword(name: []const u8) bool {
    return std.mem.eql(u8, name, "title") or std.mem.eql(u8, name, "description") or
        std.mem.eql(u8, name, "examples") or std.mem.eql(u8, name, "$comment") or
        std.mem.eql(u8, name, "deprecated") or std.mem.eql(u8, name, "readOnly") or
        std.mem.eql(u8, name, "writeOnly") or std.mem.startsWith(u8, name, "connect.") or
        std.mem.startsWith(u8, name, "confluent:") or std.mem.startsWith(u8, name, "x-");
}

fn nearestKeyword(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var distance: usize = 3;
    const names = [_][]const u8{
        "type",    "enum",    "const",            "required",         "properties", "additionalProperties", "items",     "allOf",     "anyOf", "oneOf",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "pattern",              "minLength", "maxLength",
    };
    for (names) |candidate| {
        const current = editDistance(name, candidate);
        if (current <= 2 and current < distance) {
            distance = current;
            best = candidate;
        }
    }
    return best;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return 65;
    var rows: [2][66]usize = undefined;
    for (0..b.len + 1) |index| rows[0][index] = index;
    for (1..a.len + 1) |i| {
        rows[1][0] = i;
        for (1..b.len + 1) |j| {
            rows[1][j] = @min(@min(rows[0][j] + 1, rows[1][j - 1] + 1), rows[0][j - 1] + @intFromBool(a[i - 1] != b[j - 1]));
        }
        rows[0] = rows[1];
    }
    return rows[0][b.len];
}

fn isLocalFileRef(reference: []const u8) bool {
    return !std.mem.startsWith(u8, reference, "#") and std.mem.indexOf(u8, reference, "://") == null and
        (std.mem.endsWith(u8, reference, ".json") or std.mem.indexOf(u8, reference, ".json#") != null);
}

fn allowedReference(reference: []const u8, allowed: []const []const u8) bool {
    for (allowed) |name| {
        if (std.mem.startsWith(u8, reference, name) and
            (reference.len == name.len or reference[name.len] == '#')) return true;
    }
    return false;
}

fn hasUnsatisfiableTypeEnum(schema: *const jv.Node) bool {
    const type_node = jvObjectField(schema, "type") orelse return false;
    const enum_node = jvObjectField(schema, "enum") orelse return false;
    if (enum_node.value != .array or enum_node.value.array.len == 0) return true;
    for (enum_node.value.array) |value| {
        if (type_node.value == .string and typeMatches(type_node.value.string, value)) return false;
        if (type_node.value == .array) {
            for (type_node.value.array) |candidate|
                if (candidate.value == .string and typeMatches(candidate.value.string, value)) return false;
        }
    }
    return true;
}

fn typeMatches(name: []const u8, value: *const jv.Node) bool {
    return if (std.mem.eql(u8, name, "null")) value.value == .null_value else if (std.mem.eql(u8, name, "boolean")) value.value == .boolean else if (std.mem.eql(u8, name, "object")) value.value == .object else if (std.mem.eql(u8, name, "array")) value.value == .array else if (std.mem.eql(u8, name, "string")) value.value == .string else if (std.mem.eql(u8, name, "number")) value.value == .number else if (std.mem.eql(u8, name, "integer")) value.value == .number and std.mem.indexOfAny(u8, value.value.number, ".eE") == null else false;
}

fn hasCombinatorAdditionalProperties(schema: *const jv.Node, draft: schema_compile.Draft) bool {
    const additional = jvObjectField(schema, "additionalProperties") orelse return false;
    if (additional.value != .boolean or additional.value.boolean) return false;
    for ([_][]const u8{ "allOf", "anyOf", "oneOf" }) |name| {
        const branches = jvObjectField(schema, name) orelse continue;
        if (branches.value != .array) continue;
        for (branches.value.array) |branch| {
            if (jvObjectField(branch, "properties") != null) {
                _ = draft;
                return true;
            }
        }
    }
    return false;
}

fn jvObjectField(node: *const jv.Node, name: []const u8) ?*const jv.Node {
    if (node.value != .object) return null;
    for (node.value.object) |member| if (std.mem.eql(u8, member.key, name)) return member.value;
    return null;
}

fn checkFixtures(init: std.process.Init, alloc: std.mem.Allocator, directory: []const u8, plan: *const schema_compile.Plan, global: cli.Global) !bool {
    var failed = false;
    for ([_][]const u8{ "valid", "invalid" }) |category| {
        const path = try std.fs.path.join(alloc, &.{ directory, category });
        var dir = std.Io.Dir.cwd().openDir(init.io, path, .{ .iterate = true }) catch {
            try pushFinding(alloc, global, "", "", "fixture directory '{s}' is missing", .{path});
            failed = true;
            continue;
        };
        defer dir.close(init.io);
        var iterator = dir.iterate();
        while (try iterator.next(init.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            const source = try dir.readFileAlloc(init.io, entry.name, alloc, .limited(16 * 1024 * 1024));
            const document = jv.parse(alloc, source) catch {
                try pushFinding(alloc, global, "", "", "fixture {s}/{s} is not valid JSON", .{ category, entry.name });
                failed = true;
                continue;
            };
            const errors = try validator.validate(alloc, plan, document.root, .{});
            const expected_valid = std.mem.eql(u8, category, "valid");
            if (expected_valid and errors.len > 0) {
                const first = errors[0];
                try pushFinding(alloc, global, first.instanceLocation, first.keywordLocation, "fixture {s}/{s} did not pass: {s}: {s}", .{
                    category, entry.name, if (first.instanceLocation.len == 0) "/" else first.instanceLocation, first.@"error",
                });
                failed = true;
            } else if (!expected_valid and errors.len == 0) {
                try pushFinding(alloc, global, "", "", "fixture {s}/{s} did not fail", .{ category, entry.name });
                failed = true;
            }
        }
    }
    return failed;
}

fn pushFinding(
    alloc: std.mem.Allocator,
    global: cli.Global,
    instance_location: []const u8,
    keyword_location: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(alloc, fmt, args);
    if (global.errors_json) {
        const failure: validator.Failure = .{
            .instanceLocation = jsonPointer(instance_location),
            .keywordLocation = jsonPointer(keyword_location),
            .@"error" = message,
        };
        app.Diagnostics.init("push", global).invalid(null, null, &.{&.{failure}});
    } else {
        pushStderr("{s}", .{message});
    }
}

fn pushNote(
    alloc: std.mem.Allocator,
    global: cli.Global,
    location: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(alloc, fmt, args);
    if (global.errors_json) {
        var output = std.Io.Writer.Allocating.init(alloc);
        try std.json.Stringify.value(.{
            .command = "push",
            .kind = "note",
            .location = jsonPointer(location),
            .message = message,
        }, .{}, &output.writer);
        std.debug.print("{s}\n", .{output.written()});
    } else {
        pushStderr("{s}", .{message});
    }
}

fn jsonPointer(location: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, location, "#")) location[1..] else location;
}

fn lintLocation(location: []const u8) []const u8 {
    const pointer = jsonPointer(location);
    return if (pointer.len == 0) "the root" else pointer;
}
