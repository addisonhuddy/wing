const std = @import("std");
const cli = @import("cli.zig");
const app = @import("app.zig");
const config = @import("config.zig");
const registry_mod = @import("registry.zig");
const header = @import("header.zig");
const jv = @import("jv.zig");
const schema_compile = @import("schema/compile.zig");
const schema_validate = @import("schema/validate.zig");
const schema_cache = @import("schema_cache.zig");
const record = @import("record.zig");
const record_io = @import("record_io.zig");
const term = @import("term.zig");

const SchemaInfo = struct {
    schema_value: std.json.Value,
    guid: ?[]const u8,
    subject: ?[]const u8,
    topic: ?[]const u8,
    version: []const u8,
    plan: *schema_compile.Plan,
    rule_set: ?std.json.Value,
};

var active_stdout: ?*std.Io.File.Writer = null;
var interrupted = std.atomic.Value(bool).init(false);

const Resolver = struct {
    init: std.process.Init,
    global: cli.Global,
    settings: config.Settings,
    registry: registry_mod.Registry,
    alloc: std.mem.Allocator,
    schemas: std.StringHashMapUnmanaged(*SchemaInfo) = .empty,
    warned_rules: std.StringHashMapUnmanaged(void) = .empty,

    fn resolve(self: *Resolver, prefix: header.Prefix, key: bool, line_number: usize) !*SchemaInfo {
        const schema_key = try self.prefixKey(prefix);
        if (self.schemas.get(schema_key)) |found| return found;

        var schema_value: std.json.Value = undefined;
        var subject: ?[]const u8 = null;
        var version: ?[]const u8 = null;
        var guid: ?[]const u8 = null;
        var was_cached = false;
        switch (prefix) {
            .guid => |bytes| {
                var formatted: [36]u8 = undefined;
                const text = header.formatGuid(bytes, &formatted);
                guid = try self.alloc.dupe(u8, text);
                if (self.settings.schema_dir) |directory| {
                    const cached = schema_cache.read(self.init.io, self.alloc, directory, text) catch |err|
                        recordFatal(self.global, self.alloc, line_number, "invalid schema cache entry for GUID '{s}': {s}", .{ text, @errorName(err) });
                    if (cached) |value| {
                        schema_value = value;
                        was_cached = true;
                        subject = registry_mod.stringValue(registry_mod.objectValue(value, "subject") orelse .null);
                        if (subject == null) {
                            if (registry_mod.stringValue(registry_mod.objectValue(value, "topic") orelse .null)) |topic|
                                subject = try app.subjectForTopic(self.alloc, topic, key);
                        }
                        if (registry_mod.objectValue(value, "version")) |version_value|
                            version = try registry_mod.valueText(self.alloc, version_value);
                    }
                }
                if (!was_cached) {
                    if (self.settings.urls.len == 0)
                        recordFatal(self.global, self.alloc, line_number, "no Schema Registry configured; pass --registry URL, set SCHEMA_REGISTRY_URL, or run wing registry init", .{});
                    schema_value = self.registry.schemaGuid(text) catch |err| {
                        if (self.registry.last_status == 404)
                            recordFatal(self.global, self.alloc, line_number, "schema GUID {s} not found in {s}", .{
                                text,
                                app.registryDescription(self.alloc, self.global, self.settings),
                            });
                        recordFatal(self.global, self.alloc, line_number, "{s}", .{self.registry.last_error orelse @errorName(err)});
                    };
                    const location = self.registry.guidLocation(text, key) catch |err| {
                        if (self.registry.last_status == 404)
                            recordFatal(self.global, self.alloc, line_number, "schema GUID {s} not found in {s}", .{
                                text,
                                app.registryDescription(self.alloc, self.global, self.settings),
                            });
                        recordFatal(self.global, self.alloc, line_number, "{s}", .{self.registry.last_error orelse @errorName(err)});
                    };
                    subject = location.subject;
                    version = location.version;
                    if (subject == null or version == null) {
                        const schema_id = jsonUnsigned(self.alloc, registry_mod.objectValue(schema_value, "id") orelse .null) orelse
                            recordFatal(self.global, self.alloc, line_number, "schema GUID {s} has no registered subject in {s}", .{
                                text,
                                app.registryDescription(self.alloc, self.global, self.settings),
                            });
                        const fallback = self.registry.idAnyLocation(schema_id) catch |err|
                            recordFatal(self.global, self.alloc, line_number, "{s}", .{self.registry.last_error orelse @errorName(err)});
                        subject = fallback.subject;
                        version = fallback.version;
                    }
                }
            },
            .id => |id| {
                if (self.settings.urls.len == 0)
                    recordFatal(self.global, self.alloc, line_number, "numeric schema ID {d} requires a configured Schema Registry", .{id});
                schema_value = self.registry.schemaId(id) catch |err| {
                    if (self.registry.last_status == 404)
                        recordFatal(self.global, self.alloc, line_number, "schema ID {d} not found in {s}", .{
                            id,
                            app.registryDescription(self.alloc, self.global, self.settings),
                        });
                    recordFatal(self.global, self.alloc, line_number, "{s}", .{self.registry.last_error orelse @errorName(err)});
                };
                guid = registry_mod.stringValue(registry_mod.objectValue(schema_value, "guid") orelse .null);
                const location = self.registry.idLocation(id, key) catch |err|
                    recordFatal(self.global, self.alloc, line_number, "{s}", .{self.registry.last_error orelse @errorName(err)});
                subject = location.subject;
                version = location.version;
                if (subject == null or version == null) {
                    const fallback = self.registry.idAnyLocation(id) catch |err|
                        recordFatal(self.global, self.alloc, line_number, "{s}", .{self.registry.last_error orelse @errorName(err)});
                    subject = fallback.subject;
                    version = fallback.version;
                }
            },
        }

        if (subject == null or version == null)
            recordFatal(self.global, self.alloc, line_number, "schema has no registered version in the selected registry", .{});
        if (guid == null)
            guid = registry_mod.stringValue(registry_mod.objectValue(schema_value, "guid") orelse .null);
        const schema_text = registry_mod.stringValue(registry_mod.objectValue(schema_value, "schema") orelse .null) orelse
            recordFatal(self.global, self.alloc, line_number, "registry response did not contain schema text", .{});
        const document = jv.parse(self.alloc, schema_text) catch
            recordFatal(self.global, self.alloc, line_number, "registered schema is not valid JSON", .{});

        var resources: []const schema_compile.ResourceSource = &.{};
        const references = registry_mod.objectValue(schema_value, "references") orelse .null;
        if (references == .array and references.array.items.len > 0) {
            if (was_cached and self.settings.schema_dir != null) {
                resources = schema_cache.referenceResources(self.init.io, self.alloc, self.settings.schema_dir.?, schema_value) catch |cache_err| blk: {
                    if (self.settings.urls.len == 0)
                        recordFatal(self.global, self.alloc, line_number, "schema references are not available in the cache ({s})", .{@errorName(cache_err)});
                    break :blk self.registry.referenceResources(schema_value, self.settings.schema_dir) catch |err|
                        recordFatal(self.global, self.alloc, line_number, "{s}", .{self.registry.last_error orelse @errorName(err)});
                };
            } else if (self.settings.urls.len > 0) {
                resources = self.registry.referenceResources(schema_value, self.settings.schema_dir) catch |err|
                    recordFatal(self.global, self.alloc, line_number, "{s}", .{self.registry.last_error orelse @errorName(err)});
            } else if (self.settings.schema_dir) |directory| {
                resources = schema_cache.referenceResources(self.init.io, self.alloc, directory, schema_value) catch |err|
                    recordFatal(self.global, self.alloc, line_number, "schema references are not available in the cache ({s})", .{@errorName(err)});
            } else {
                recordFatal(self.global, self.alloc, line_number, "schema references require a registry or a populated schema cache", .{});
            }
        }
        const plan_value = schema_compile.compile(self.alloc, document, .{ .default_draft = .draft07, .extra_resources = resources }) catch |err|
            recordFatal(self.global, self.alloc, line_number, "cannot compile schema: {s}", .{@errorName(err)});
        const plan = try self.alloc.create(schema_compile.Plan);
        plan.* = plan_value;
        const info = try self.alloc.create(SchemaInfo);
        info.* = .{
            .schema_value = schema_value,
            .guid = guid,
            .subject = subject,
            .topic = topicForSubject(subject),
            .version = version.?,
            .plan = plan,
            .rule_set = registry_mod.objectValue(schema_value, "ruleSet"),
        };
        try self.schemas.put(self.alloc, schema_key, info);
        if (guid) |guid_text| {
            try self.schemas.put(self.alloc, try self.guidKey(guid_text), info);
            if (!was_cached and self.settings.schema_dir != null)
                self.writeCache(info) catch |err| {
                    if (!self.global.quiet) app.stderr("could not write schema cache for GUID '{s}': {s}", .{ guid_text, @errorName(err) });
                };
        }
        return info;
    }

    fn prefixKey(self: *Resolver, prefix: header.Prefix) ![]const u8 {
        return switch (prefix) {
            .guid => |bytes| blk: {
                var formatted: [36]u8 = undefined;
                break :blk try self.guidKey(header.formatGuid(bytes, &formatted));
            },
            .id => |id| try std.fmt.allocPrint(self.alloc, "id:{d}", .{id}),
        };
    }

    fn guidKey(self: *Resolver, guid: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.alloc, "guid:{s}", .{guid});
    }

    fn writeCache(self: *Resolver, info: *const SchemaInfo) !void {
        const guid = info.guid orelse return;
        const compat = if (info.subject) |subject| self.registry.compat(subject) catch "BACKWARD" else "BACKWARD";
        const cache_entry = .{
            .topic = info.topic,
            .version = info.version,
            .id = registry_mod.objectValue(info.schema_value, "id") orelse .null,
            .guid = guid,
            .compat = compat,
            .schema = registry_mod.objectValue(info.schema_value, "schema"),
            .references = registry_mod.objectValue(info.schema_value, "references"),
            .metadata = registry_mod.objectValue(info.schema_value, "metadata"),
            .ruleSet = registry_mod.objectValue(info.schema_value, "ruleSet"),
            .subject = info.subject,
        };
        try schema_cache.write(self.init.io, self.alloc, self.settings.schema_dir.?, guid, cache_entry);
    }

    fn warnRuleSet(self: *Resolver, info: *const SchemaInfo) !void {
        const rule_set = info.rule_set orelse return;
        if (rule_set != .object) return;
        var active = false;
        for ([_][]const u8{ "domainRules", "migrationRules" }) |name| {
            if (registry_mod.objectValue(rule_set, name)) |rules| {
                if (rules == .array and rules.array.items.len > 0) active = true;
            }
        }
        if (!active) return;
        const key = info.guid orelse info.subject orelse return;
        if (self.warned_rules.contains(key)) return;
        try self.warned_rules.put(self.alloc, key, {});
        std.debug.print("wing read: schema {s} has rules that wing does not run\n", .{key});
    }
};

const PartResult = struct {
    node: ?*const jv.Node,
    payload: []const u8,
    prefix: ?header.Prefix = null,
    info: ?*SchemaInfo = null,
    errors: []const schema_validate.Failure = &.{},
    inline_value: bool = false,
    stripped_prefix: bool = false,
    source_was_string: bool = false,
    had_schema_id: bool = false,
    empty: bool = false,
};

pub fn run(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) continue;
        app.fatal(app.optionError(arg, &.{"--check"}) orelse "unexpected argument", global.errors_json, "read");
    }
    const check = app.has(args, "--check");
    const alloc = init.arena.allocator();
    const settings = app.settingsForCache(init, global, "read");
    var resolver: Resolver = .{
        .init = init,
        .global = global,
        .settings = settings,
        .registry = app.registryFor(init, settings),
        .alloc = alloc,
    };

    if (std.Io.File.stdin().isTty(init.io) catch false) {
        if (!global.quiet) std.debug.print("wing read: reading kite consume --json lines from the terminal (Ctrl-D to finish)\n", .{});
    }

    var stdin_buffer: [8192]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var lines = record_io.LineReader.init(&input.interface, alloc);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    active_stdout = &output;
    installSignalHandlers();
    const color = !check and (std.Io.File.stdout().isTty(init.io) catch false) and term.colorEnabled(init.io, init.environ_map);
    var record_arena = std.heap.ArenaAllocator.init(alloc);
    defer record_arena.deinit();
    var line_number: usize = 0;
    var read_count: usize = 0;
    var passed: usize = 0;
    var failed: usize = 0;
    var empty: usize = 0;

    while (true) {
        if (interrupted.load(.acquire)) break;
        const maybe_line = lines.next() catch |err| {
            if (interrupted.load(.acquire)) break;
            return err;
        };
        const line = maybe_line orelse break;
        line_number += 1;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        _ = record_arena.reset(.retain_capacity);
        const record_alloc = record_arena.allocator();
        const input_record = record.Record.parse(record_alloc, line) catch
            recordFatal(global, alloc, line_number, "expected a JSON record; did you mean 'kite consume --json'?", .{});
        read_count += 1;

        const value_bytes = try record.bytes(record_alloc, input_record.document, input_record.value);
        const value_result = if (value_bytes.len == 0)
            PartResult{ .node = input_record.value, .payload = value_bytes, .source_was_string = input_record.value.value == .string, .empty = true }
        else
            try processPart(&resolver, record_alloc, input_record, input_record.value, "__value_schema_id", false, line_number);

        var key_result: ?PartResult = null;
        if (input_record.key) |key_node| {
            if (key_node.value != .null_value) {
                if (key_node.value != .string)
                    recordFatal(global, alloc, line_number, "key must be a string or null", .{});
                key_result = try processPart(&resolver, record_alloc, input_record, key_node, "__key_schema_id", true, line_number);
            } else if (lastHeader(input_record, "__key_schema_id") != null) {
                key_result = .{
                    .node = key_node,
                    .payload = "",
                    .had_schema_id = true,
                    .errors = try singleFailure(record_alloc, "key has a schema ID but is null"),
                };
            }
        }
        if (value_result.empty) empty += 1;
        const value_failed = value_result.errors.len > 0;
        const key_failed = if (key_result) |part| part.errors.len > 0 else false;
        const record_failed = value_failed or key_failed;
        if (record_failed) {
            failed += 1;
            if (global.errors_json) {
                try printJsonInvalid(record_alloc, line_number, input_record, value_result.errors, key_result);
            } else {
                printTextErrors(record_alloc, line_number, input_record, value_result.errors, key_result);
            }
        } else if (!value_result.empty) {
            passed += 1;
        }
        if (value_result.info) |info| try resolver.warnRuleSet(info);
        if (key_result) |part| if (part.info) |info| try resolver.warnRuleSet(info);

        if (check) {
            if (record_failed) try writeOutputLine(&output, record_alloc, line, false);
        } else if (value_result.empty and key_result == null) {
            try writeOutputLine(&output, record_alloc, line, color);
        } else {
            try writeOutputLine(&output, record_alloc, try renderRecord(record_alloc, input_record, value_result, key_result), color);
        }
        if (!lines.hasCompleteLineBuffered())
            output.interface.flush() catch |err| outputFailure(err, global.errors_json);
    }
    output.interface.flush() catch |err| outputFailure(err, global.errors_json);
    const stopped_by_signal = interrupted.load(.acquire);
    if (!global.quiet) {
        if (global.errors_json) {
            std.debug.print("{{\"command\":\"read\",\"kind\":\"summary\",\"read\":{d},\"passed\":{d},\"failed\":{d},\"empty\":{d}}}\n", .{
                read_count, passed, failed, empty,
            });
        } else {
            std.debug.print("wing read: {d} read, {d} passed, {d} failed{s}\n", .{
                read_count,
                passed,
                failed,
                if (empty > 0) try std.fmt.allocPrint(alloc, ", {d} empty", .{empty}) else "",
            });
        }
    }
    std.process.exit(if (stopped_by_signal) 130 else if (failed > 0) 2 else 0);
}

fn processPart(
    resolver: *Resolver,
    alloc: std.mem.Allocator,
    input: record.Record,
    node: *const jv.Node,
    header_name: []const u8,
    key: bool,
    line_number: usize,
) !PartResult {
    const payload_all = try record.bytes(alloc, input.document, node);
    var result: PartResult = .{
        .node = node,
        .payload = payload_all,
        .source_was_string = node.value == .string,
    };
    if (payload_all.len == 0) {
        result.empty = true;
        return result;
    }
    const header_value = lastHeader(input, header_name);
    if (header_value) |value| {
        result.had_schema_id = true;
        const bytes = value orelse "";
        if (bytes.len == 17 and bytes[0] == 1) {
            var guid: header.Guid = undefined;
            @memcpy(&guid, bytes[1..]);
            result.prefix = .{ .guid = guid };
        } else if (bytes.len == 5 and bytes[0] == 0) {
            result.prefix = .{ .id = std.mem.readInt(u32, bytes[1..5], .big) };
        } else {
            result.errors = try singleFailure(alloc, try std.fmt.allocPrint(alloc, "corrupt {s} header ({d} bytes; was the line re-encoded by jq?)", .{ header_name, bytes.len }));
            return result;
        }
        if (header.detectPrefix(payload_all) != null) {
            result.errors = try singleFailure(alloc, "payload still has a schema-id prefix after header");
            return result;
        }
    } else if (header.detectPrefix(payload_all)) |prefix| {
        result.prefix = prefix.prefix;
        result.had_schema_id = true;
        result.payload = prefix.payload;
        result.stripped_prefix = true;
    } else {
        result.errors = try singleFailure(alloc, try std.fmt.allocPrint(alloc, "no {s} header or schema-id prefix", .{header_name}));
        result.inline_value = !key and inlineCandidate(alloc, result.payload);
        return result;
    }

    const prefix = result.prefix orelse return result;
    result.info = try resolver.resolve(prefix, key, line_number);
    const instance = jv.parse(alloc, result.payload) catch {
        result.errors = try singleFailure(alloc, "invalid JSON instance");
        return result;
    };
    result.errors = try schema_validate.validate(alloc, result.info.?.plan, instance.root, .{ .verbose = resolver.global.verbose });
    result.inline_value = !key and inlineCandidate(alloc, result.payload);
    return result;
}

fn lastHeader(input: record.Record, name: []const u8) ??[]const u8 {
    var found: ?[]const u8 = null;
    var present = false;
    for (input.headers) |item| {
        if (!std.mem.eql(u8, item.key, name)) continue;
        found = item.value;
        present = true;
    }
    return if (present) found else null;
}

fn inlineCandidate(alloc: std.mem.Allocator, bytes: []const u8) bool {
    const document = jv.parse(alloc, bytes) catch return false;
    return (document.root.value == .object or document.root.value == .array) and
        document.root.span.start == 0 and document.root.span.end == bytes.len;
}

fn singleFailure(alloc: std.mem.Allocator, message: []const u8) ![]const schema_validate.Failure {
    const failures = try alloc.alloc(schema_validate.Failure, 1);
    failures[0] = .{ .instanceLocation = "", .keywordLocation = "", .@"error" = message };
    return failures;
}

fn renderRecord(
    alloc: std.mem.Allocator,
    input: record.Record,
    value: PartResult,
    key: ?PartResult,
) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(alloc);
    var first = true;
    var wrote_value = false;
    var wrote_key = false;
    var wrote_headers = false;
    try output.writer.writeByte('{');
    for (input.members) |member| {
        const name = member.key;
        if (std.mem.eql(u8, name, "schema")) continue;
        if (std.mem.eql(u8, name, "value")) {
            if (member.value != input.value or wrote_value) continue;
            try writeFieldPrefix(&output.writer, alloc, &first, name);
            try writePartValue(&output.writer, input.document, value);
            wrote_value = true;
        } else if (std.mem.eql(u8, name, "key")) {
            if (input.key == null or member.value != input.key.? or wrote_key) continue;
            try writeFieldPrefix(&output.writer, alloc, &first, name);
            if (key) |part| {
                try writePartValue(&output.writer, input.document, part);
            } else {
                try output.writer.writeAll(record.raw(input.document, member.value));
            }
            wrote_key = true;
        } else if (std.mem.eql(u8, name, "headers")) {
            if (input.headers_node == null or member.value != input.headers_node.? or wrote_headers) continue;
            try writeFieldPrefix(&output.writer, alloc, &first, name);
            try writeFilteredHeaders(&output.writer, input);
            wrote_headers = true;
        } else {
            try writeFieldPrefix(&output.writer, alloc, &first, name);
            try output.writer.writeAll(record.raw(input.document, member.value));
        }
    }
    if (!wrote_value) {
        try writeFieldPrefix(&output.writer, alloc, &first, "value");
        try writePartValue(&output.writer, input.document, value);
    }
    if (input.headers_node != null and !wrote_headers) {
        try writeFieldPrefix(&output.writer, alloc, &first, "headers");
        try writeFilteredHeaders(&output.writer, input);
    }
    try writeFieldPrefix(&output.writer, alloc, &first, "schema");
    try writeSchemaField(&output.writer, value, key);
    try output.writer.writeByte('}');
    return output.written();
}

fn writePartValue(writer: *std.Io.Writer, document: jv.Document, part: PartResult) !void {
    if (part.inline_value) {
        try writer.writeAll(part.payload);
    } else if (part.source_was_string and !part.stripped_prefix and part.node != null) {
        try writer.writeAll(record.raw(document, part.node.?));
    } else {
        try record.writeString(writer, part.payload);
    }
}

fn writeFilteredHeaders(writer: *std.Io.Writer, input: record.Record) !void {
    try writer.writeByte('[');
    var first = true;
    for (input.headers) |item| {
        if (std.mem.eql(u8, item.key, "__value_schema_id") or std.mem.eql(u8, item.key, "__key_schema_id")) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        if (input.headers_node.?.value == .array) {
            try writer.writeAll(record.raw(input.document, item.node));
        } else {
            try writer.writeAll("{\"key\":");
            try record.writeString(writer, item.key);
            try writer.writeAll(",\"value\":");
            if (item.value) |bytes| try record.writeString(writer, bytes) else try writer.writeAll("null");
            try writer.writeByte('}');
        }
    }
    try writer.writeByte(']');
}

fn writeFieldPrefix(writer: *std.Io.Writer, alloc: std.mem.Allocator, first: *bool, name: []const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try record.writeString(writer, name);
    try writer.writeByte(':');
    _ = alloc;
}

fn writeSchemaField(writer: *std.Io.Writer, value: PartResult, key: ?PartResult) !void {
    try writer.writeByte('{');
    var first = true;
    if (value.had_schema_id or value.errors.len > 0) {
        try writePartMetadata(writer, &first, "value", value);
    }
    if (key) |part| {
        if (part.had_schema_id or part.errors.len > 0)
            try writePartMetadata(writer, &first, "key", part);
    }
    try writer.writeByte('}');
}

fn writePartMetadata(writer: *std.Io.Writer, first: *bool, name: []const u8, part: PartResult) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try record.writeString(writer, name);
    try writer.writeAll(":{");
    var field_first = true;
    if (part.info) |info| {
        if (info.guid) |guid| try writeStringField(writer, &field_first, "guid", guid);
        if (info.topic) |topic| try writeStringField(writer, &field_first, "topic", topic);
        try writeRawField(writer, &field_first, "version", info.version);
        if (part.prefix) |prefix| switch (prefix) {
            .id => |id| {
                if (!field_first) try writer.writeByte(',');
                field_first = false;
                try record.writeString(writer, "id");
                try writer.print(":{d}", .{id});
            },
            .guid => {},
        };
    }
    if (part.errors.len > 0) {
        if (!field_first) try writer.writeByte(',');
        try record.writeString(writer, "errors");
        try writer.writeAll(":[");
        for (part.errors, 0..) |failure, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"instanceLocation\":");
            try record.writeString(writer, stripFragment(failure.instanceLocation));
            try writer.writeAll(",\"keywordLocation\":");
            try record.writeString(writer, stripFragment(failure.keywordLocation));
            try writer.writeAll(",\"error\":");
            try record.writeString(writer, failure.@"error");
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

fn writeStringField(writer: *std.Io.Writer, first: *bool, name: []const u8, value: []const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try record.writeString(writer, name);
    try writer.writeByte(':');
    try record.writeString(writer, value);
}

fn writeRawField(writer: *std.Io.Writer, first: *bool, name: []const u8, value: []const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try record.writeString(writer, name);
    try writer.writeByte(':');
    try writer.writeAll(value);
}

fn printTextErrors(
    alloc: std.mem.Allocator,
    line_number: usize,
    input: record.Record,
    value_errors: []const schema_validate.Failure,
    key: ?PartResult,
) void {
    const position = recordPosition(alloc, input);
    for (value_errors) |failure| {
        printOneTextError(line_number, position, "", failure, null);
    }
    if (key) |part| {
        for (part.errors) |failure| {
            const subject = if (part.info) |info| info.subject orelse "key schema" else "key schema";
            const context = std.fmt.allocPrint(alloc, " (keys are validated because {s} exists)", .{subject}) catch "";
            printOneTextError(line_number, position, "key ", failure, context);
        }
    }
}

fn printOneTextError(line_number: usize, position: []const u8, prefix: []const u8, failure: schema_validate.Failure, context: ?[]const u8) void {
    const instance = displayPath(failure.instanceLocation);
    const keyword = displayPath(failure.keywordLocation);
    std.debug.print("wing read: line {d}{s}: {s}{s}{s}{s}", .{
        line_number, position, prefix, if (instance.len > 0) instance else "", if (instance.len > 0) ": " else "", failure.@"error",
    });
    if (keyword.len > 0) std.debug.print(" [{s}]", .{keyword});
    if (context) |suffix| std.debug.print("{s}", .{suffix});
    std.debug.print("\n", .{});
}

fn printJsonInvalid(
    alloc: std.mem.Allocator,
    line_number: usize,
    input: record.Record,
    value_errors: []const schema_validate.Failure,
    key: ?PartResult,
) !void {
    var output = std.Io.Writer.Allocating.init(alloc);
    try output.writer.print("{{\"command\":\"read\",\"kind\":\"invalid\",\"line\":{d}", .{line_number});
    if (record.field(input.document.root, "topic")) |topic| if (topic.value == .string) {
        try output.writer.writeAll(",\"topic\":");
        try record.writeString(&output.writer, topic.value.string);
    };
    for ([_][]const u8{ "partition", "offset" }) |name| {
        if (record.field(input.document.root, name)) |node| {
            try output.writer.writeByte(',');
            try record.writeString(&output.writer, name);
            try output.writer.writeByte(':');
            try output.writer.writeAll(record.raw(input.document, node));
        }
    }
    try output.writer.writeAll(",\"output\":{\"valid\":false,\"errors\":[");
    var first = true;
    for (value_errors) |failure| {
        try writeJsonFailure(&output.writer, &first, failure);
    }
    if (key) |part| for (part.errors) |failure| {
        try writeJsonFailure(&output.writer, &first, failure);
    };
    try output.writer.writeAll("]}}\n");
    std.debug.print("{s}", .{output.written()});
}

fn writeJsonFailure(writer: *std.Io.Writer, first: *bool, failure: schema_validate.Failure) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writer.writeAll("{\"keywordLocation\":");
    try record.writeString(writer, displayPath(failure.keywordLocation));
    try writer.writeAll(",\"instanceLocation\":");
    try record.writeString(writer, displayPath(failure.instanceLocation));
    try writer.writeAll(",\"error\":");
    try record.writeString(writer, failure.@"error");
    try writer.writeByte('}');
}

fn recordPosition(alloc: std.mem.Allocator, input: record.Record) []const u8 {
    const topic_node = record.field(input.document.root, "topic") orelse return "";
    if (topic_node.value != .string) return "";
    const partition = record.field(input.document.root, "partition");
    const offset = record.field(input.document.root, "offset");
    if (partition) |p| {
        if (offset) |o| return std.fmt.allocPrint(alloc, " ({s}/{s}@{s})", .{
            topic_node.value.string,
            record.raw(input.document, p),
            record.raw(input.document, o),
        }) catch "";
    }
    return std.fmt.allocPrint(alloc, " ({s})", .{topic_node.value.string}) catch "";
}

fn displayPath(location: []const u8) []const u8 {
    return stripFragment(location);
}

fn stripFragment(location: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, location, "#")) location[1..] else location;
}

fn writeOutputLine(output: *std.Io.File.Writer, alloc: std.mem.Allocator, bytes: []const u8, color: bool) !void {
    var rendered = bytes;
    if (color) {
        if (jv.parse(alloc, bytes)) |document| {
            rendered = jv.pretty(alloc, document.root, true) catch bytes;
        } else |_| {}
    }
    record_io.writeLine(&output.interface, rendered) catch |err| {
        const cause = output.err orelse err;
        if (cause == error.BrokenPipe or stdoutClosed()) std.process.exit(0);
        return err;
    };
}

fn outputFailure(err: anyerror, errors_json: bool) noreturn {
    const cause = if (active_stdout) |output| output.err orelse err else err;
    if (cause == error.BrokenPipe or stdoutClosed()) std.process.exit(0);
    app.fatal("failed writing stdout", errors_json, "read");
}

fn topicForSubject(subject: ?[]const u8) ?[]const u8 {
    const name = subject orelse return null;
    if (std.mem.endsWith(u8, name, "-value")) return name[0 .. name.len - "-value".len];
    if (std.mem.endsWith(u8, name, "-key")) return name[0 .. name.len - "-key".len];
    return null;
}

fn jsonUnsigned(alloc: std.mem.Allocator, value: std.json.Value) ?u32 {
    const text = registry_mod.valueText(alloc, value) catch return null;
    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn recordFatal(global: cli.Global, alloc: std.mem.Allocator, line_number: usize, comptime fmt: []const u8, args: anytype) noreturn {
    if (active_stdout) |output| output.interface.flush() catch {};
    const message = std.fmt.allocPrint(alloc, fmt, args) catch "record processing failed";
    if (global.errors_json) {
        const full = std.fmt.allocPrint(alloc, "line {d}: {s}", .{ line_number, message }) catch message;
        app.fatal(full, true, "read");
    }
    std.debug.print("wing read: line {d}: {s}\n", .{ line_number, message });
    std.process.exit(1);
}

fn stdoutClosed() bool {
    var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDOUT_FILENO, .events = 0, .revents = 0 }};
    const count = std.posix.poll(&fds, 0) catch return false;
    return count > 0 and (fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0;
}

fn onInterrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

fn installSignalHandlers() void {
    const stop: std.posix.Sigaction = .{
        .handler = .{ .handler = onInterrupt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &stop, null);
    std.posix.sigaction(.TERM, &stop, null);
    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &ignore, null);
}
