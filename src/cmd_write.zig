const std = @import("std");
const cli = @import("cli.zig");
const app = @import("app.zig");
const config = @import("config.zig");
const registry_mod = @import("registry.zig");
const header = @import("header.zig");
const jv = @import("jv.zig");
const compile = @import("schema/compile.zig");
const validate = @import("schema/validate.zig");
const fit = @import("schema/fit.zig");
const schema_cache = @import("schema_cache.zig");
const record = @import("record.zig");
const record_io = @import("record_io.zig");
const term = @import("term.zig");

const Info = struct {
    value: std.json.Value,
    guid: []const u8,
    subject: []const u8,
    topic: ?[]const u8,
    version: []const u8,
    plan: *compile.Plan,
};

const Part = struct {
    node: ?*jv.Node = null,
    payload: []const u8 = "",
    failures: []const validate.Failure = &.{},
    changes: []const fit.Change = &.{},
    inline_value: bool = false,
    source_string: bool = false,
    changed: bool = false,
};

const Resolver = struct {
    init: std.process.Init,
    global: cli.Global,
    settings: config.Settings,
    registry: registry_mod.Registry,
    alloc: std.mem.Allocator,
    schemas: std.StringHashMapUnmanaged(*Info) = .empty,
    lookups: std.StringHashMapUnmanaged(?*Info) = .empty,

    fn resolve(self: *Resolver, reference: []const u8, key: bool, line: usize) !*Info {
        if (app.headerParseableGuid(reference)) return self.resolveGuid(reference, key, null, line);
        const parsed = app.parseReference(reference, true) catch |err| switch (err) {
            error.LegacyAtSyntax => fatal(self.global, "write", app.legacyReferenceMessage(self.alloc, reference)),
            error.InvalidVersion => fatal(self.global, "write", "version must be 'latest' or a positive integer"),
        };
        const topic = parsed.subject;
        const version_request = parsed.version orelse "latest";
        if (self.settings.urls.len == 0)
            fatalLine(self.global, line, "no Schema Registry configured; pass --registry URL, set SCHEMA_REGISTRY_URL, or run wing registry init");
        var probe_memory = std.heap.stackFallback(512, self.alloc);
        const probe = probe_memory.get();
        const probe_subject = try app.subjectForTopic(probe, topic, key);
        const probe_key = try std.fmt.allocPrint(probe, "{s}:{s}@{s}", .{
            if (key) "key" else "value", probe_subject, version_request,
        });
        if (self.lookups.get(probe_key)) |found| return found.?;
        const subject = try self.alloc.dupe(u8, probe_subject);
        const lookup_key = try self.alloc.dupe(u8, probe_key);
        const versions = self.registry.versions(subject) catch |err| {
            if (self.registry.last_status == 404)
                fatalFmt(self, "no schema for topic '{s}' (subject {s} not found in {s})", .{
                    topic, subject, app.registryDescription(self.alloc, self.global, self.settings),
                });
            fatalLine(self.global, line, self.registry.last_error orelse @errorName(err));
        };
        if (versions != .array or versions.array.items.len == 0)
            fatalFmt(self, "no schema for topic '{s}' (subject {s} not found in {s})", .{
                topic, subject, app.registryDescription(self.alloc, self.global, self.settings),
            });
        const version = if (std.mem.eql(u8, version_request, "latest"))
            app.latestVersion(self.alloc, versions)
        else blk: {
            if (!app.hasVersion(self.alloc, versions, version_request))
                fatalFmt(self, "{s} has no version {s} (versions: {s})", .{
                    subject, version_request, app.versionList(self.alloc, versions),
                });
            break :blk version_request;
        };
        const key_text = try std.fmt.allocPrint(self.alloc, "{s}@{s}", .{ subject, version });
        if (self.schemas.get(key_text)) |found| return found;
        const schema_value = self.registry.schema(subject, version) catch |err|
            fatalLine(self.global, line, self.registry.last_error orelse @errorName(err));
        const info = try self.makeInfo(schema_value, subject, topic, version, false, line);
        try self.lookups.put(self.alloc, lookup_key, info);
        return info;
    }

    fn latestKey(self: *Resolver, topic: []const u8, line: usize) !?*Info {
        if (self.settings.urls.len == 0)
            fatalLine(self.global, line, "a REF requires a configured Schema Registry to select its key schema");
        var probe_memory = std.heap.stackFallback(512, self.alloc);
        const probe = probe_memory.get();
        const probe_subject = try app.subjectForTopic(probe, topic, true);
        const probe_key = try std.fmt.allocPrint(probe, "key:{s}@latest", .{probe_subject});
        if (self.lookups.get(probe_key)) |found| return found;
        const subject = try self.alloc.dupe(u8, probe_subject);
        const lookup_key = try self.alloc.dupe(u8, probe_key);
        const versions = self.registry.versions(subject) catch |err| {
            if (self.registry.last_status == 404) {
                try self.lookups.put(self.alloc, lookup_key, null);
                return null;
            }
            fatalLine(self.global, line, self.registry.last_error orelse @errorName(err));
        };
        if (versions != .array or versions.array.items.len == 0) {
            try self.lookups.put(self.alloc, lookup_key, null);
            return null;
        }
        const version = app.latestVersion(self.alloc, versions);
        const key = try std.fmt.allocPrint(self.alloc, "{s}@{s}", .{ subject, version });
        if (self.schemas.get(key)) |found| {
            try self.lookups.put(self.alloc, lookup_key, found);
            return found;
        }
        const value = self.registry.schema(subject, version) catch |err|
            fatalLine(self.global, line, self.registry.last_error orelse @errorName(err));
        const info = try self.makeInfo(value, subject, topic, version, false, line);
        try self.lookups.put(self.alloc, lookup_key, info);
        return info;
    }

    fn resolveGuid(self: *Resolver, record_guid: []const u8, key: bool, record_topic: ?[]const u8, line: usize) !*Info {
        const role = if (key) "key" else "value";
        const topic_name: []const u8 = record_topic orelse "";
        var probe_memory = std.heap.stackFallback(512, self.alloc);
        const probe_key = try std.fmt.allocPrint(probe_memory.get(), "guid:{s}:{s}:{d}:{s}", .{
            record_guid, role, topic_name.len, topic_name,
        });
        if (self.schemas.get(probe_key)) |found| return found;
        // Record text lives in the per-record arena; keep owned copies in the cache.
        const cache_key = try self.alloc.dupe(u8, probe_key);
        const guid = try self.alloc.dupe(u8, record_guid);
        const requested_topic = if (record_topic) |topic| try self.alloc.dupe(u8, topic) else null;
        var value: std.json.Value = undefined;
        var subject: ?[]const u8 = null;
        var version: ?[]const u8 = null;
        var cached = false;
        if (self.settings.schema_dir) |directory| {
            const entry = schema_cache.read(self.init.io, self.alloc, directory, guid) catch |err|
                fatalFmt(self, "invalid schema cache entry for GUID '{s}': {s}", .{ guid, @errorName(err) });
            if (entry) |item| {
                value = item;
                cached = true;
                subject = registry_mod.stringValue(registry_mod.objectValue(item, "subject") orelse .null);
                if (registry_mod.objectValue(item, "version")) |resolved|
                    version = registry_mod.valueText(self.alloc, resolved) catch null;
                if (subject == null) {
                    if (registry_mod.stringValue(registry_mod.objectValue(item, "topic") orelse .null)) |topic|
                        subject = try app.subjectForTopic(self.alloc, topic, key);
                }
            }
        }
        if (!cached) {
            if (self.settings.urls.len == 0)
                fatalLine(self.global, line, "no Schema Registry configured; pass --registry URL, set SCHEMA_REGISTRY_URL, or run wing registry init");
            value = self.registry.schemaGuid(guid) catch |err| {
                if (self.registry.last_status == 404)
                    fatalFmt(self, "schema GUID '{s}' not found in {s}", .{ guid, app.registryDescription(self.alloc, self.global, self.settings) });
                fatalLine(self.global, line, self.registry.last_error orelse @errorName(err));
            };
            const location = self.registry.guidLocation(guid, key, requested_topic) catch |err| {
                if (self.registry.last_status == 404)
                    fatalFmt(self, "schema GUID '{s}' not found in {s}", .{ guid, app.registryDescription(self.alloc, self.global, self.settings) });
                fatalLine(self.global, line, self.registry.last_error orelse @errorName(err));
            };
            subject = location.subject;
            version = location.version;
        }
        if (cached and self.settings.urls.len > 0) {
            const location = self.registry.guidLocation(guid, key, requested_topic) catch |err| {
                if (self.registry.last_status == 404)
                    fatalFmt(self, "schema GUID '{s}' not found in {s}", .{ guid, app.registryDescription(self.alloc, self.global, self.settings) });
                fatalLine(self.global, line, self.registry.last_error orelse @errorName(err));
            };
            if (location.subject) |selected_subject| subject = selected_subject;
            if (location.version) |selected_version| version = selected_version;
        }
        const resolved_subject = subject orelse fatalFmt(self, "schema GUID '{s}' has no registered topic subject", .{guid});
        const resolved_version = version orelse "latest";
        const topic = if (std.mem.endsWith(u8, resolved_subject, "-value") or std.mem.endsWith(u8, resolved_subject, "-key"))
            app.topicFromSubject(resolved_subject)
        else
            null;
        const info = try self.makeInfo(value, resolved_subject, topic, resolved_version, cached, line);
        try self.schemas.put(self.alloc, cache_key, info);
        return info;
    }

    fn makeInfo(
        self: *Resolver,
        value: std.json.Value,
        subject: []const u8,
        topic: ?[]const u8,
        version: []const u8,
        cached: bool,
        line: usize,
    ) !*Info {
        const guid = registry_mod.stringValue(registry_mod.objectValue(value, "guid") orelse .null) orelse
            fatalLine(self.global, line, "registry response did not contain a schema GUID");
        const schema_text = registry_mod.stringValue(registry_mod.objectValue(value, "schema") orelse .null) orelse
            fatalLine(self.global, line, "registry response did not contain schema text");
        const document = jv.parse(self.alloc, schema_text) catch
            fatalFmt(self, "registered schema is not valid JSON on line {d}", .{line});
        var resources: []const compile.ResourceSource = &.{};
        const references = registry_mod.objectValue(value, "references") orelse .null;
        if (references == .array and references.array.items.len > 0) {
            if (cached and self.settings.schema_dir != null) {
                resources = schema_cache.referenceResources(self.init.io, self.alloc, self.settings.schema_dir.?, value) catch |err|
                    fatalFmt(self, "schema references are not available in cache ({s})", .{@errorName(err)});
            } else if (self.settings.urls.len > 0) {
                resources = self.registry.referenceResources(value, self.settings.schema_dir) catch |err|
                    fatalLine(self.global, line, self.registry.last_error orelse @errorName(err));
            } else {
                fatalLine(self.global, line, "schema references require a registry or populated schema cache");
            }
        }
        const plan = compile.compile(self.alloc, document, .{ .default_draft = .draft07, .extra_resources = resources }) catch |err|
            fatalFmt(self, "cannot compile schema: {s}", .{@errorName(err)});
        const plan_ptr = try self.alloc.create(compile.Plan);
        plan_ptr.* = plan;
        const info = try self.alloc.create(Info);
        info.* = .{ .value = value, .guid = guid, .subject = subject, .topic = topic, .version = version, .plan = plan_ptr };
        try self.schemas.put(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}@{s}", .{ subject, version }), info);
        if (!cached and self.settings.schema_dir != null) self.cacheInfo(info) catch |err|
            if (!self.global.quiet) writeNote(self.global, app.allocPrint(
                self.alloc,
                "wing write: could not write schema cache for GUID '{s}': {s}",
                .{ guid, @errorName(err) },
            ));
        return info;
    }

    fn cacheInfo(self: *Resolver, info: *const Info) !void {
        const compat = self.registry.compat(info.subject) catch "BACKWARD";
        const entry = .{
            .topic = info.topic,
            .version = info.version,
            .id = registry_mod.objectValue(info.value, "id") orelse .null,
            .guid = info.guid,
            .compat = compat,
            .schema = registry_mod.objectValue(info.value, "schema"),
            .references = registry_mod.objectValue(info.value, "references"),
            .metadata = registry_mod.objectValue(info.value, "metadata"),
            .ruleSet = registry_mod.objectValue(info.value, "ruleSet"),
            .subject = info.subject,
        };
        try schema_cache.write(self.init.io, self.alloc, self.settings.schema_dir.?, info.guid, entry);
    }
};

var active_stdout: ?*std.Io.File.Writer = null;
var interrupted = std.atomic.Value(bool).init(false);

pub fn run(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
    var reference: ?[]const u8 = null;
    var fit_enabled = false;
    var check = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--fit")) {
            fit_enabled = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            app.fatal(app.optionError(arg, &.{ "--fit", "--check" }) orelse "unexpected argument", global.errors_json, "write");
        } else if (reference == null) {
            reference = arg;
        } else {
            app.fatal("unexpected argument", global.errors_json, "write");
        }
    }
    if (reference) |ref| {
        if (!app.headerParseableGuid(ref)) {
            _ = app.parseReference(ref, true) catch |err| switch (err) {
                error.LegacyAtSyntax => fatal(global, "write", app.legacyReferenceMessage(init.arena.allocator(), ref)),
                error.InvalidVersion => fatal(global, "write", "version must be 'latest' or a positive integer"),
            };
        }
    }

    const alloc = init.arena.allocator();
    const settings = app.settingsForCache(init, global, "write");
    var resolver: Resolver = .{
        .init = init,
        .global = global,
        .settings = settings,
        .registry = app.registryFor(init, settings),
        .alloc = alloc,
    };
    var stdin_buffer: [8192]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var lines = record_io.LineReader.init(&input.interface, alloc);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    active_stdout = &output;
    installSignalHandlers();
    const color = !check and (std.Io.File.stdout().isTty(init.io) catch false) and term.colorEnabled(init.io, init.environ_map);
    if ((std.Io.File.stdin().isTty(init.io) catch false) and !global.quiet)
        writeNote(global, "wing write: reading JSON record lines from the terminal (Ctrl-D to finish)");
    var record_arena = std.heap.ArenaAllocator.init(alloc);
    defer record_arena.deinit();
    var line_number: usize = 0;
    var read_count: usize = 0;
    var passed: usize = 0;
    var written: usize = 0;
    var fitted: usize = 0;
    var check_changes: usize = 0;
    var failed: usize = 0;
    var empty: usize = 0;
    var reported: std.StringHashMapUnmanaged(void) = .empty;
    var dropped: std.StringHashMapUnmanaged(usize) = .empty;
    var rule_counts: [4]usize = .{ 0, 0, 0, 0 };

    while (true) {
        if (interrupted.load(.acquire)) break;
        const maybe_line = lines.next() catch |err| {
            if (interrupted.load(.acquire)) break;
            return err;
        };
        const line = maybe_line orelse break;
        line_number += 1;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        read_count += 1;
        _ = record_arena.reset(.retain_capacity);
        const line_alloc = record_arena.allocator();
        const input_record = record.Record.parse(line_alloc, line) catch |err| blk: {
            if (reference != null and err == error.InvalidRecord) {
                if (try bareValueRecord(line_alloc, line)) |wrapped| break :blk wrapped;
            }
            fatalLine(global, line_number, if (reference == null)
                "expected a kite JSON record ({\"value\": ...}); pass a topic to write bare JSON values"
            else
                "expected a JSON object per line, or a kite JSON record ({\"value\": ...})");
        };
        if (input_record.value_b64_bytes != null)
            fatalLine(global, line_number, "value_b64 is not supported by wing write; values must be JSON");

        const value_bytes = try input_record.payloadBytes(line_alloc, input_record.value);
        if (value_bytes.len == 0) empty += 1;
        var value_part: Part = .{ .payload = value_bytes, .source_string = input_record.value.value == .string };
        var value_info: ?*Info = null;
        if (value_bytes.len > 0) {
            value_info = try selectValue(&resolver, reference, input_record, line_number);
            value_part = try preparePart(line_alloc, value_info.?, value_bytes, fit_enabled);
        }

        var key_part: ?Part = null;
        var key_info: ?*Info = null;
        var selection_info = value_info;
        var missing_key_subject: ?[]const u8 = null;
        if (reference) |ref| {
            const selected = selection_info orelse try resolver.resolve(ref, false, line_number);
            selection_info = selected;
            if (selected.topic) |topic| {
                missing_key_subject = try app.subjectForTopic(line_alloc, topic, true);
                key_info = try resolver.latestKey(topic, line_number);
            }
        } else if (selection_info == null) {
            if (record.field(input_record.document.root, "schema")) |schema_node| {
                if (record.field(schema_node, "value")) |value_schema| {
                    if (record.field(value_schema, "guid")) |guid_node| {
                        if (guid_node.value == .string)
                            selection_info = try resolver.resolveGuid(
                                guid_node.value.string,
                                false,
                                recordTopic(input_record, value_schema),
                                line_number,
                            );
                    }
                }
            }
        }
        if (reference == null) {
            if (record.field(input_record.document.root, "schema")) |schema_node| {
                if (record.field(schema_node, "key")) |key_schema| {
                    if (record.field(key_schema, "guid")) |guid_node| {
                        if (guid_node.value == .string)
                            key_info = try resolver.resolveGuid(
                                guid_node.value.string,
                                true,
                                recordTopic(input_record, key_schema),
                                line_number,
                            );
                    }
                }
            }
        }
        if (input_record.key) |key_node| {
            if (key_node.value == .string) {
                const key_bytes = try input_record.payloadBytes(line_alloc, key_node);
                if (key_info) |info| key_part = try preparePart(line_alloc, info, key_bytes, fit_enabled);
            } else if (key_node.value != .null_value) {
                fatalLine(global, line_number, "key must be a string or null");
            }
        }
        if (selection_info) |selected|
            noteSelection(&reported, alloc, global, selected, key_info, missing_key_subject);
        if (value_info) |info| try warnRuleSet(&reported, alloc, global, info);
        if (key_info) |info| try warnRuleSet(&reported, alloc, global, info);

        const record_failed = value_part.failures.len > 0 or (if (key_part) |part| part.failures.len > 0 else false);
        const would_change = value_part.changed or (if (key_part) |part| part.changed else false);
        if (fit_enabled) {
            try logChanges(alloc, global, line_number, value_part.changes, &dropped, &rule_counts);
            if (key_part) |part| try logChanges(alloc, global, line_number, part.changes, &dropped, &rule_counts);
            if (global.errors_json) emitRecordPatch(line_number, input_record, value_part.changes, key_part);
        }
        if (record_failed) {
            failed += 1;
            if (global.errors_json) emitErrorJson(line_number, input_record, value_part.failures, key_part) else printFailures(line_number, value_part.failures, key_part, key_info);
            if (!check) {
                output.interface.flush() catch {};
                printDropNotes(dropped, global);
                printSummary(global, read_count, passed, failed, empty, written, fitted, fit_enabled, rule_counts);
                std.process.exit(2);
            }
        }
        if (!record_failed) passed += 1;
        if (check) {
            if (would_change) {
                fitted += 1;
                check_changes += 1;
            }
            if (record_failed or would_change)
                try writeLine(&output, line_alloc, line, false, global.errors_json);
        } else {
            const needs_render = record.field(input_record.document.root, "schema") != null or
                hasSchemaHeaders(input_record) or
                input_record.key_b64_bytes != null or
                (value_part.payload.len > 0 and value_info != null) or
                (key_part != null and key_info != null) or
                value_part.changed or
                (if (key_part) |part| part.changed else false);
            const rendered = if (needs_render)
                try renderRecord(line_alloc, input_record, value_part, key_part, value_info, key_info)
            else
                line;
            try writeLine(&output, line_alloc, rendered, color, global.errors_json);
            written += 1;
            if (would_change) fitted += 1;
        }
        if (!lines.hasCompleteLineBuffered())
            output.interface.flush() catch |err| outputFailure(err, global.errors_json);
    }
    output.interface.flush() catch |err| outputFailure(err, global.errors_json);
    printDropNotes(dropped, global);
    printSummary(global, read_count, passed, failed, empty, written, fitted, fit_enabled, rule_counts);
    std.process.exit(if (interrupted.load(.acquire)) 130 else if (failed > 0 or (check and check_changes > 0)) 2 else 0);
}

/// With a REF, a JSON object or array line without `value`/`value_b64` is the
/// record value itself; it is wrapped in a kite envelope.
fn bareValueRecord(alloc: std.mem.Allocator, line: []const u8) !?record.Record {
    const document = jv.parse(alloc, line) catch return null;
    switch (document.root.value) {
        .object => if (record.field(document.root, "value") != null or record.field(document.root, "value_b64") != null)
            return null,
        .array => {},
        else => return null,
    }
    const trimmed = jv.sourceSlice(document, document.root);
    const wrapped = try std.mem.concat(alloc, u8, &.{ "{\"value\":", trimmed, "}" });
    return record.Record.parse(alloc, wrapped) catch null;
}

fn selectValue(resolver: *Resolver, reference: ?[]const u8, input: record.Record, line: usize) !*Info {
    if (reference) |ref| return resolver.resolve(ref, false, line);
    const schema_node = record.field(input.document.root, "schema") orelse
        fatalLine(resolver.global, line, "no schema for this record; pass a topic (wing write TOPIC) or keep the schema field from wing read");
    const value_schema = record.field(schema_node, "value") orelse
        fatalLine(resolver.global, line, "missing schema.value.guid; pass a REF");
    const guid = record.field(value_schema, "guid") orelse
        fatalLine(resolver.global, line, "missing schema.value.guid; pass a REF");
    if (guid.value != .string) fatalLine(resolver.global, line, "schema.value.guid must be a string");
    return resolver.resolveGuid(guid.value.string, false, recordTopic(input, value_schema), line);
}

fn recordTopic(input: record.Record, schema: *const jv.Node) ?[]const u8 {
    return stringField(input.document.root, "topic") orelse stringField(schema, "topic");
}

fn stringField(node: *const jv.Node, name: []const u8) ?[]const u8 {
    const field = record.field(node, name) orelse return null;
    return if (field.value == .string) field.value.string else null;
}

fn preparePart(alloc: std.mem.Allocator, info: *Info, payload: []const u8, fit_enabled: bool) !Part {
    const document = jv.parse(alloc, payload) catch {
        const failures = try alloc.alloc(validate.Failure, 1);
        failures[0] = .{ .instanceLocation = "", .keywordLocation = "", .@"error" = "invalid JSON instance" };
        return .{ .payload = payload, .failures = failures };
    };
    var part: Part = .{
        .node = document.root,
        .payload = payload,
        .inline_value = (document.root.value == .object or document.root.value == .array) and
            document.root.span.start == 0 and document.root.span.end == payload.len,
    };
    if (fit_enabled) {
        const result = try fit.apply(alloc, info.plan, document.root);
        part.node = result.node;
        part.changes = result.changes;
        part.changed = result.changes.len > 0;
        if (part.changed) part.payload = try jv.stringify(alloc, result.node);
    }
    part.failures = try validate.validate(alloc, info.plan, part.node.?, .{});
    if (part.changed)
        part.inline_value = (part.node.?.value == .object or part.node.?.value == .array);
    return part;
}

fn renderRecord(
    alloc: std.mem.Allocator,
    input: record.Record,
    value: Part,
    key: ?Part,
    value_info: ?*Info,
    key_info: ?*Info,
) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(alloc);
    try output.writer.writeByte('{');
    var first = true;
    var value_written = false;
    var key_written = false;
    for (input.members) |member| {
        if (std.mem.eql(u8, member.key, "schema") or std.mem.eql(u8, member.key, "headers")) continue;
        if (std.mem.eql(u8, member.key, "value_b64") or std.mem.eql(u8, member.key, "key_b64")) continue;
        if (std.mem.eql(u8, member.key, "value")) {
            try fieldPrefix(&output.writer, &first, "value");
            try writeValue(&output.writer, input.document, input.value, value);
            value_written = true;
        } else if (std.mem.eql(u8, member.key, "key")) {
            if (key) |part| {
                try record.writeBytesField(&output.writer, &first, "key", "key_b64", part.payload);
            } else if (member.value.value == .null_value) {
                try fieldPrefix(&output.writer, &first, "key");
                try output.writer.writeAll(record.raw(input.document, member.value));
            } else {
                try record.writeBytesField(
                    &output.writer,
                    &first,
                    "key",
                    "key_b64",
                    try input.payloadBytes(alloc, member.value),
                );
            }
            key_written = true;
        } else {
            try fieldPrefix(&output.writer, &first, member.key);
            try output.writer.writeAll(record.raw(input.document, member.value));
        }
    }
    if (!value_written) {
        try fieldPrefix(&output.writer, &first, "value");
        try writeValue(&output.writer, input.document, input.value, value);
    }
    if (input.key != null and !key_written) {
        if (input.key.?.value == .null_value) {
            try fieldPrefix(&output.writer, &first, "key");
            try output.writer.writeAll(record.raw(input.document, input.key.?));
        } else if (key) |part| {
            try record.writeBytesField(&output.writer, &first, "key", "key_b64", part.payload);
        } else {
            try record.writeBytesField(
                &output.writer,
                &first,
                "key",
                "key_b64",
                try input.payloadBytes(alloc, input.key.?),
            );
        }
    }
    try fieldPrefix(&output.writer, &first, "headers");
    try writeHeaders(&output.writer, input, value, key, value_info, key_info);
    try output.writer.writeByte('}');
    return output.written();
}

fn writeValue(writer: *std.Io.Writer, document: jv.Document, original: *const jv.Node, part: Part) !void {
    if (part.payload.len == 0) return writer.writeAll(record.raw(document, original));
    if (part.inline_value) return writer.writeAll(part.payload);
    if (!part.changed and part.source_string) return writer.writeAll(record.raw(document, original));
    try record.writeString(writer, part.payload);
}

fn writeHeaders(
    writer: *std.Io.Writer,
    input: record.Record,
    value: Part,
    key: ?Part,
    value_info: ?*Info,
    key_info: ?*Info,
) !void {
    try writer.writeByte('[');
    var first = true;
    for (input.headers) |item| {
        if (isSchemaHeader(item.key)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        if (input.headers_node) |node| {
            if (node.value == .array) {
                try writer.writeAll(record.raw(input.document, item.node));
                continue;
            }
        }
        try writer.writeAll("{\"key\":");
        try record.writeString(writer, item.key);
        if (item.value) |bytes| {
            var header_first = false;
            try record.writeBytesField(writer, &header_first, "value", "value_b64", bytes);
        } else {
            try writer.writeAll(",\"value\":null");
        }
        try writer.writeByte('}');
    }
    if (value.payload.len > 0) if (value_info) |info| {
        const guid = try header.parseGuid(info.guid);
        var bytes: [17]u8 = undefined;
        _ = header.encodeGuid(guid, &bytes);
        if (!first) try writer.writeByte(',');
        first = false;
        try writeSchemaHeader(writer, "__value_schema_id", &bytes);
    };
    if (key) |part| {
        _ = part;
        if (key_info) |info| {
            const guid = try header.parseGuid(info.guid);
            var bytes: [17]u8 = undefined;
            _ = header.encodeGuid(guid, &bytes);
            if (!first) try writer.writeByte(',');
            try writeSchemaHeader(writer, "__key_schema_id", &bytes);
        }
    }
    try writer.writeByte(']');
}

fn writeSchemaHeader(writer: *std.Io.Writer, name: []const u8, bytes: []const u8) !void {
    try writer.writeAll("{\"key\":");
    try record.writeString(writer, name);
    try writer.writeAll(",\"value_b64\":");
    try record.writeBase64String(writer, bytes);
    try writer.writeByte('}');
}

test "schema header writer emits deterministic standard base64" {
    const guid = try header.parseGuid("6da336d8-f1d3-0f98-4c47-d03ee8a14a12");
    var bytes: [17]u8 = undefined;
    _ = header.encodeGuid(guid, &bytes);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeSchemaHeader(&output.writer, "__value_schema_id", &bytes);
    try output.writer.writeByte(',');
    try writeSchemaHeader(&output.writer, "__key_schema_id", &bytes);
    try std.testing.expectEqualStrings(
        "{\"key\":\"__value_schema_id\",\"value_b64\":\"AW2jNtjx0w+YTEfQPuihShI=\"},{\"key\":\"__key_schema_id\",\"value_b64\":\"AW2jNtjx0w+YTEfQPuihShI=\"}",
        output.written(),
    );
}

fn isSchemaHeader(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "_schema_id");
}

fn hasSchemaHeaders(input: record.Record) bool {
    for (input.headers) |item| if (isSchemaHeader(item.key)) return true;
    return false;
}

fn fieldPrefix(writer: *std.Io.Writer, first: *bool, name: []const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try record.writeString(writer, name);
    try writer.writeByte(':');
}

fn noteSelection(
    reported: *std.StringHashMapUnmanaged(void),
    alloc: std.mem.Allocator,
    global: cli.Global,
    value: *Info,
    key: ?*Info,
    missing_key_subject: ?[]const u8,
) void {
    const key_name = if (key) |info| info.subject else missing_key_subject orelse "";
    const key_version = if (key) |info| info.version else "no subject";
    var probe_memory = std.heap.stackFallback(512, alloc);
    const probe = std.fmt.allocPrint(probe_memory.get(), "{s}@{s}|{s}@{s}", .{
        value.subject, value.version, key_name, key_version,
    }) catch return;
    if (reported.contains(probe)) return;
    reported.put(alloc, alloc.dupe(u8, probe) catch return, {}) catch return;
    if (global.quiet) return;
    const diagnostics = app.Diagnostics.init("write", global);
    if (key) |info|
        diagnostics.notef("wing write: using {s} version {s}, {s} version {s}", .{
            value.subject, value.version, info.subject, info.version,
        })
    else if (missing_key_subject) |subject|
        diagnostics.notef("wing write: using {s} version {s}, no {s} subject", .{ value.subject, value.version, subject })
    else
        diagnostics.notef("wing write: using {s} version {s}, no key schema", .{ value.subject, value.version });
}

fn writeNote(global: cli.Global, message: []const u8) void {
    app.Diagnostics.init("write", global).note(message);
}

fn warnRuleSet(
    reported: *std.StringHashMapUnmanaged(void),
    alloc: std.mem.Allocator,
    global: cli.Global,
    info: *const Info,
) !void {
    const rule_set = registry_mod.objectValue(info.value, "ruleSet") orelse return;
    if (rule_set != .object) return;
    var active = false;
    for ([_][]const u8{ "domainRules", "migrationRules" }) |name| {
        if (registry_mod.objectValue(rule_set, name)) |rules|
            if (rules == .array and rules.array.items.len > 0) {
                active = true;
            };
    }
    if (!active or reported.contains(info.guid)) return;
    try reported.put(alloc, info.guid, {});
    app.Diagnostics.init("write", global).notef("wing write: schema {s} has rules that wing does not run", .{info.guid});
}

fn logChanges(
    alloc: std.mem.Allocator,
    global: cli.Global,
    line: usize,
    changes: []const fit.Change,
    dropped: *std.StringHashMapUnmanaged(usize),
    rule_counts: *[4]usize,
) !void {
    const diagnostics = app.Diagnostics.init("write", global);
    for (changes) |change| {
        rule_counts[@intFromEnum(change.rule)] += 1;
        if (change.rule == .drop_extra) {
            const entry = try dropped.getOrPut(alloc, change.path);
            if (!entry.found_existing) {
                entry.key_ptr.* = try alloc.dupe(u8, change.path);
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
        }
        if (global.verbose) {
            switch (change.rule) {
                .drop_extra => diagnostics.print("wing write: line {d}: {s} removed (drop-extra)", .{ line, change.path }),
                .defaults => diagnostics.print("wing write: line {d}: {s} set to {s} (default)", .{
                    line, change.path, change.after orelse "null",
                }),
                .coerce, .wrap => diagnostics.print("wing write: line {d}: {s} {s} -> {s} ({s})", .{
                    line,
                    change.path,
                    change.before orelse "null",
                    change.after orelse "null",
                    if (change.rule == .coerce) "coerce" else "wrap",
                }),
            }
        }
    }
}

const json_diagnostics: app.Diagnostics = .{ .command = "write", .json = true };
const text_diagnostics: app.Diagnostics = .{ .command = "write", .json = false };

fn emitRecordPatch(line: usize, input: record.Record, value: []const fit.Change, key: ?Part) void {
    const key_changes: []const fit.Change = if (key) |part| part.changes else &.{};
    if (value.len == 0 and key_changes.len == 0) return;
    json_diagnostics.fitPatch(line, input, &.{ value, key_changes });
}

fn printSummary(
    global: cli.Global,
    read_count: usize,
    passed: usize,
    failed: usize,
    empty: usize,
    written: usize,
    fitted: usize,
    fit_enabled: bool,
    rules: [4]usize,
) void {
    if (global.quiet) return;
    const diagnostics = app.Diagnostics.init("write", global);
    if (global.errors_json) {
        diagnostics.value(.{
            .command = "write",
            .kind = "summary",
            .read = read_count,
            .passed = passed,
            .failed = failed,
            .empty = empty,
            .fit = .{ .coerce = rules[0], .defaults = rules[1], .@"drop-extra" = rules[2], .wrap = rules[3] },
            .written = written,
            .fitted = fitted,
        });
        return;
    }
    const writer = diagnostics.begin();
    defer diagnostics.end(writer);
    writer.print("wing write: {d} written, {d} fitted", .{ written, fitted }) catch {};
    if (fit_enabled) {
        const names = [_][]const u8{ "coerce", "defaults", "drop-extra", "wrap" };
        var first = true;
        for (rules, names) |count, name| {
            if (count == 0) continue;
            writer.print("{s}{s} {d}", .{ if (first) " (" else ", ", name, count }) catch {};
            first = false;
        }
        if (!first) writer.writeByte(')') catch {};
    }
}

fn printDropNotes(dropped: std.StringHashMapUnmanaged(usize), global: cli.Global) void {
    const diagnostics = app.Diagnostics.init("write", global);
    var iterator = dropped.iterator();
    while (iterator.next()) |entry|
        diagnostics.notef("wing write: drop-extra removed {s} from {d} records", .{ entry.key_ptr.*, entry.value_ptr.* });
}

fn printFailures(line: usize, value: []const validate.Failure, key: ?Part, key_info: ?*Info) void {
    for (value) |failure| printOneFailure(line, "", failure, null);
    if (key) |part| for (part.failures) |failure| {
        const subject = if (key_info) |info| info.subject else "key schema";
        const version = if (key_info) |info| info.version else "?";
        printKeyFailure(line, subject, version, failure);
    };
}

fn printKeyFailure(line: usize, subject: []const u8, version: []const u8, failure: validate.Failure) void {
    const path = if (std.mem.startsWith(u8, failure.instanceLocation, "#")) failure.instanceLocation[1..] else failure.instanceLocation;
    const keyword = if (std.mem.startsWith(u8, failure.keywordLocation, "#")) failure.keywordLocation[1..] else failure.keywordLocation;
    const writer = text_diagnostics.begin();
    defer text_diagnostics.end(writer);
    writer.print("wing write: line {d}: key failed {s} version {s} (keys are validated because {s} exists): {s}{s}{s}", .{
        line,
        subject,
        version,
        subject,
        path,
        if (path.len > 0) ": " else "",
        failure.@"error",
    }) catch {};
    if (keyword.len > 0) writer.print(" [{s}]", .{keyword}) catch {};
}

fn printOneFailure(line: usize, prefix: []const u8, failure: validate.Failure, suffix: ?[]const u8) void {
    const path = if (std.mem.startsWith(u8, failure.instanceLocation, "#")) failure.instanceLocation[1..] else failure.instanceLocation;
    const keyword = if (std.mem.startsWith(u8, failure.keywordLocation, "#")) failure.keywordLocation[1..] else failure.keywordLocation;
    const writer = text_diagnostics.begin();
    defer text_diagnostics.end(writer);
    writer.print("wing write: line {d}: {s}{s}{s}{s}", .{
        line,
        prefix,
        path,
        if (path.len > 0) ": " else "",
        failure.@"error",
    }) catch {};
    if (keyword.len > 0) writer.print(" [{s}]", .{keyword}) catch {};
    if (suffix) |text| writer.print(": {s}", .{text}) catch {};
}

fn emitErrorJson(line: usize, input: record.Record, value: []const validate.Failure, key: ?Part) void {
    const key_failures: []const validate.Failure = if (key) |part| part.failures else &.{};
    json_diagnostics.invalid(line, input, &.{ value, key_failures });
}

fn writeLine(
    output: *std.Io.File.Writer,
    alloc: std.mem.Allocator,
    bytes: []const u8,
    color: bool,
    errors_json: bool,
) !void {
    var rendered = bytes;
    if (color) {
        var colored = std.Io.Writer.Allocating.init(alloc);
        try term.writeJsonColored(&colored.writer, bytes);
        rendered = colored.written();
    }
    record_io.writeLine(&output.interface, rendered) catch |err| {
        const cause = output.err orelse err;
        if (cause == error.BrokenPipe or stdoutClosed()) std.process.exit(0);
        app.fatal("failed writing stdout", errors_json, "write");
    };
}

fn outputFailure(err: anyerror, errors_json: bool) noreturn {
    const cause = if (active_stdout) |output| output.err orelse err else err;
    if (cause == error.BrokenPipe or stdoutClosed()) std.process.exit(0);
    app.fatal("failed writing stdout", errors_json, "write");
}

fn fatal(global: cli.Global, command: []const u8, message: []const u8) noreturn {
    app.fatal(message, global.errors_json, command);
}

fn fatalFmt(resolver: *Resolver, comptime fmt: []const u8, args: anytype) noreturn {
    const message = std.fmt.allocPrint(resolver.alloc, "wing write: {s}", .{
        std.fmt.allocPrint(resolver.alloc, fmt, args) catch "write failed",
    }) catch "wing write: write failed";
    if (resolver.global.errors_json) app.fatal(message, true, "write");
    std.debug.print("{s}\n", .{message});
    std.process.exit(1);
}

fn fatalLine(global: cli.Global, line: usize, message: []const u8) noreturn {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("wing write: line {d}: {s}", .{ line, message }) catch {};
    const full = writer.buffered();
    if (global.errors_json) app.fatal(full, true, "write");
    std.debug.print("{s}\n", .{full});
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
    const stop: std.posix.Sigaction = .{ .handler = .{ .handler = onInterrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &stop, null);
    std.posix.sigaction(.TERM, &stop, null);
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.PIPE, &ignore, null);
}

test "bare JSON lines become the record value; envelopes and scalars do not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const object = (try bareValueRecord(alloc, " {\"id\":1} ")).?;
    try std.testing.expectEqualStrings("{\"id\":1}", jv.sourceSlice(object.document, object.value));
    const array = (try bareValueRecord(alloc, "[1,2]")).?;
    try std.testing.expectEqualStrings("[1,2]", jv.sourceSlice(array.document, array.value));
    try std.testing.expect((try bareValueRecord(alloc, "{\"value\":{\"id\":1}}")) == null);
    try std.testing.expect((try bareValueRecord(alloc, "{\"value_b64\":\"AA==\"}")) == null);
    try std.testing.expect((try bareValueRecord(alloc, "42")) == null);
    try std.testing.expect((try bareValueRecord(alloc, "{not json")) == null);
}
