const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const registry_mod = @import("registry.zig");
const term = @import("term.zig");
const jv = @import("jv.zig");
const header = @import("header.zig");
const app = @import("app.zig");
const schema_cache = @import("schema_cache.zig");
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
                    app.stderr("could not write schema cache for GUID '{s}': {s}", .{ guid, @errorName(err) });
            }
        }
    }
    if (jsonField(schema, "references")) |references| {
        if (references == .array and references.array.items.len > 0)
            fatal("schema references are present but reference bundling is not implemented yet", global.errors_json, "get");
    }
    if (meta) {
        try emitJson(alloc, io, metadata, global.errors_json, "get");
    } else {
        const schema_text = textField(schema, "schema") orelse fatal("registry response has no schema text", global.errors_json, "get");
        const pretty = isTty(io, std.Io.File.stdout());
        if (pretty) {
            const parsed = jv.parse(alloc, schema_text) catch {
                writeStdout(io, schema_text, global.errors_json, "get");
                return;
            };
            const formatted = try jv.pretty(alloc, parsed.root, term.colorEnabled(io, init.environ_map));
            writeStdout(io, formatted, global.errors_json, "get");
            writeStdout(io, "\n", global.errors_json, "get");
        } else {
            writeStdout(io, schema_text, global.errors_json, "get");
            writeStdout(io, "\n", global.errors_json, "get");
        }
    }
}
