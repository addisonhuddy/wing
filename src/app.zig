const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const registry_mod = @import("registry.zig");
const term = @import("term.zig");
const jv = @import("jv.zig");
const header = @import("header.zig");
const validation = @import("schema/validate.zig");
const fit = @import("schema/fit.zig");
const record = @import("record.zig");

pub fn stderr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("wing: " ++ fmt ++ "\n", args);
}

pub fn fatal(message: []const u8, json_errors: bool, command: []const u8) noreturn {
    if (json_errors) {
        (Diagnostics{ .command = command, .json = true }).value(.{ .kind = "error", .command = command, .message = message });
    } else {
        if (std.mem.eql(u8, command, "push") or std.mem.eql(u8, command, "get") or
            std.mem.eql(u8, command, "ls") or std.mem.eql(u8, command, "rm") or
            std.mem.eql(u8, command, "registry"))
        {
            std.debug.print("wing {s}: {s}\n", .{ command, message });
        } else {
            stderr("{s}", .{message});
        }
        if (std.mem.startsWith(u8, message, "unknown option") or
            std.mem.startsWith(u8, message, "unknown command") or
            std.mem.eql(u8, message, "missing command") or
            std.mem.startsWith(u8, message, "missing ") or
            std.mem.startsWith(u8, message, "unexpected argument"))
            std.debug.print("{s}", .{cli.usage(command)});
    }
    std.process.exit(1);
}

pub fn writeStdout(io: std.Io, bytes: []const u8, json_errors: bool, command: []const u8) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    writer.interface.writeAll(bytes) catch fatal("failed writing stdout", json_errors, command);
    writer.interface.flush() catch fatal("failed writing stdout", json_errors, command);
}

pub fn has(args: []const []const u8, value: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, value)) return true;
    return false;
}

pub fn argAt(args: []const []const u8, index: usize) ?[]const u8 {
    return if (index < args.len) args[index] else null;
}

pub fn isTty(io: std.Io, file: std.Io.File) bool {
    return file.isTty(io) catch false;
}

pub fn emitJson(alloc: std.mem.Allocator, io: std.Io, value: anytype, json_errors: bool, command: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeByte('\n');
    writeStdout(io, out.written(), json_errors, command);
}

pub fn emitJsonLines(alloc: std.mem.Allocator, io: std.Io, values: anytype, json_errors: bool, command: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(alloc);
    for (values) |value| {
        try std.json.Stringify.value(value, .{}, &out.writer);
        try out.writer.writeByte('\n');
    }
    writeStdout(io, out.written(), json_errors, command);
}

/// Writes stderr diagnostics for one command. Every message is one line,
/// written under the stderr lock straight into a fixed buffer, so emitting a
/// diagnostic never allocates.
pub const Diagnostics = struct {
    command: []const u8,
    json: bool,
    quiet: bool = false,
    verbose: bool = false,

    var stderr_buffer: [4096]u8 = undefined;

    pub fn init(command: []const u8, global: cli.Global) Diagnostics {
        return .{ .command = command, .json = global.errors_json, .quiet = global.quiet, .verbose = global.verbose };
    }

    /// Locks stderr for one diagnostic line; finish it with `end`.
    pub fn begin(_: Diagnostics) *std.Io.Writer {
        return &std.debug.lockStderr(&stderr_buffer).file_writer.interface;
    }

    pub fn end(_: Diagnostics, writer: *std.Io.Writer) void {
        writer.writeByte('\n') catch {};
        std.debug.unlockStderr();
    }

    pub fn print(self: Diagnostics, comptime fmt: []const u8, args: anytype) void {
        const writer = self.begin();
        writer.print(fmt, args) catch {};
        self.end(writer);
    }

    pub fn value(self: Diagnostics, payload: anytype) void {
        const writer = self.begin();
        std.json.Stringify.value(payload, .{ .emit_null_optional_fields = false }, writer) catch {};
        self.end(writer);
    }

    pub fn note(self: Diagnostics, message: []const u8) void {
        if (self.json)
            self.value(.{ .command = self.command, .kind = "note", .message = message })
        else
            self.print("{s}", .{message});
    }

    /// Formats a note into a fixed buffer; long notes are truncated.
    pub fn notef(self: Diagnostics, comptime fmt: []const u8, args: anytype) void {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print(fmt, args) catch {};
        self.note(writer.buffered());
    }

    /// `{"command","kind":"invalid",["line",topic,partition,offset,]"output":{"valid":false,"errors":[...]}}`
    pub fn invalid(self: Diagnostics, line: ?usize, input: ?record.Record, groups: []const []const validation.Failure) void {
        const writer = self.begin();
        defer self.end(writer);
        var stream: std.json.Stringify = .{ .writer = writer };
        self.writeInvalid(&stream, line, input, groups) catch {};
    }

    /// `{"command","kind":"fit","line",...,"patch":[RFC 6902 operations]}`
    pub fn fitPatch(self: Diagnostics, line: usize, input: record.Record, groups: []const []const fit.Change) void {
        const writer = self.begin();
        defer self.end(writer);
        var stream: std.json.Stringify = .{ .writer = writer };
        self.writeFitPatch(&stream, line, input, groups) catch {};
    }

    fn writeInvalid(
        self: Diagnostics,
        stream: *std.json.Stringify,
        line: ?usize,
        input: ?record.Record,
        groups: []const []const validation.Failure,
    ) std.json.Stringify.Error!void {
        try self.writeHead(stream, "invalid", line, input);
        try stream.objectField("output");
        try stream.beginObject();
        try stream.objectField("valid");
        try stream.write(false);
        try stream.objectField("errors");
        try stream.beginArray();
        for (groups) |failures| for (failures) |failure| try stream.write(validation.Failure{
            .instanceLocation = stripFragment(failure.instanceLocation),
            .keywordLocation = stripFragment(failure.keywordLocation),
            .@"error" = failure.@"error",
        });
        try stream.endArray();
        try stream.endObject();
        try stream.endObject();
    }

    fn writeFitPatch(
        self: Diagnostics,
        stream: *std.json.Stringify,
        line: usize,
        input: record.Record,
        groups: []const []const fit.Change,
    ) std.json.Stringify.Error!void {
        try self.writeHead(stream, "fit", line, input);
        try stream.objectField("patch");
        try stream.beginArray();
        for (groups) |changes| for (changes) |change| {
            try stream.beginObject();
            try stream.objectField("op");
            try stream.write(switch (change.rule) {
                .defaults => "add",
                .drop_extra => "remove",
                .coerce, .wrap => "replace",
            });
            try stream.objectField("path");
            try stream.write(change.path);
            if (change.rule != .drop_extra) {
                try stream.objectField("value");
                try writeRaw(stream, change.after orelse "null");
            }
            try stream.endObject();
        };
        try stream.endArray();
        try stream.endObject();
    }

    fn writeHead(
        self: Diagnostics,
        stream: *std.json.Stringify,
        kind: []const u8,
        line: ?usize,
        input: ?record.Record,
    ) std.json.Stringify.Error!void {
        try stream.beginObject();
        try stream.objectField("command");
        try stream.write(self.command);
        try stream.objectField("kind");
        try stream.write(kind);
        if (line) |number| {
            try stream.objectField("line");
            try stream.write(number);
        }
        const parsed = input orelse return;
        if (record.field(parsed.document.root, "topic")) |topic| if (topic.value == .string) {
            try stream.objectField("topic");
            try stream.write(topic.value.string);
        };
        for ([_][]const u8{ "partition", "offset" }) |name| {
            if (record.field(parsed.document.root, name)) |node| {
                try stream.objectField(name);
                try writeRaw(stream, record.raw(parsed.document, node));
            }
        }
    }

    fn writeRaw(stream: *std.json.Stringify, json_text: []const u8) std.json.Stringify.Error!void {
        try stream.beginWriteRaw();
        try stream.writer.writeAll(json_text);
        stream.endWriteRaw();
    }

    fn stripFragment(location: []const u8) []const u8 {
        return if (std.mem.startsWith(u8, location, "#")) location[1..] else location;
    }
};

pub fn stringOf(value: std.json.Value) ?[]const u8 {
    return registry_mod.stringValue(value);
}

pub fn jsonField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return registry_mod.objectValue(value, key);
}

pub fn textField(value: std.json.Value, key: []const u8) ?[]const u8 {
    return if (jsonField(value, key)) |v| stringOf(v) else null;
}

pub fn subjectForTopic(alloc: std.mem.Allocator, topic: []const u8, key: bool) ![]const u8 {
    const suffix = if (key) "-key" else "-value";
    if (std.mem.endsWith(u8, topic, suffix)) return topic;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ topic, suffix });
}

pub fn validVersion(text: []const u8, allow_latest: bool) bool {
    if (allow_latest and std.mem.eql(u8, text, "latest")) return true;
    const number = std.fmt.parseInt(u64, text, 10) catch return false;
    return number > 0;
}

pub const Reference = struct {
    subject: []const u8,
    version: ?[]const u8,
};

pub const ReferenceError = error{
    LegacyAtSyntax,
    InvalidVersion,
};

pub fn parseReference(reference: []const u8, allow_latest: bool) ReferenceError!Reference {
    if (std.mem.indexOfScalar(u8, reference, '@') != null)
        return error.LegacyAtSyntax;
    const separator = std.mem.lastIndexOfScalar(u8, reference, ':') orelse
        return .{ .subject = reference, .version = null };
    const suffix = reference[separator + 1 ..];
    if (validVersion(suffix, allow_latest))
        return .{ .subject = reference[0..separator], .version = suffix };
    if (std.mem.startsWith(u8, reference, ":."))
        return .{ .subject = reference, .version = null };
    return error.InvalidVersion;
}

pub fn legacyReferenceMessage(alloc: std.mem.Allocator, reference: []const u8) []const u8 {
    var corrected: std.ArrayListUnmanaged(u8) = .empty;
    defer corrected.deinit(alloc);
    for (reference) |character|
        corrected.append(alloc, if (character == '@') ':' else character) catch return "out of memory";
    return std.fmt.allocPrint(alloc, "'{s}': use '{s}' to pin a version ('@NAME' selects a registry)", .{
        reference,
        corrected.items,
    }) catch "out of memory";
}

pub fn optionError(arg: []const u8, suggestions: []const []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, "-")) return null;
    for (suggestions) |valid| {
        if (std.mem.eql(u8, arg, valid)) return null;
    }
    return cli.optionErrorFor(std.heap.page_allocator, arg, suggestions);
}

pub fn errorsRequested(args: []const []const u8) bool {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--errors=json")) return true;
        if (std.mem.eql(u8, arg, "--errors") and index + 1 < args.len and std.mem.eql(u8, args[index + 1], "json")) return true;
    }
    return false;
}

pub fn commandFromArgs(args: []const []const u8) []const u8 {
    const commands = [_][]const u8{ "read", "write", "ls", "get", "push", "rm", "registry", "update" };
    var skip_value = false;
    for (args) |arg| {
        if (skip_value) {
            skip_value = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--registry") or std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "--schema-dir") or std.mem.eql(u8, arg, "--errors")) {
            skip_value = true;
            continue;
        }
        for (commands) |command| if (std.mem.eql(u8, arg, command)) return command;
    }
    return "";
}

pub fn settingsFor(init: std.process.Init, global: cli.Global, command: []const u8) config.Settings {
    return settingsForMode(init, global, command, false);
}

pub fn settingsForCache(init: std.process.Init, global: cli.Global, command: []const u8) config.Settings {
    return settingsForMode(init, global, command, true);
}

fn settingsForMode(init: std.process.Init, global: cli.Global, command: []const u8, allow_missing_registry: bool) config.Settings {
    var settings = (if (allow_missing_registry)
        config.loadAllowMissingRegistry(init.io, init.arena.allocator(), init.environ_map, global)
    else
        config.load(init.io, init.arena.allocator(), init.environ_map, global)) catch |err| {
        if (err == error.NoSuchRegistry) {
            const alloc = init.arena.allocator();
            if (config.registryNames(alloc, init.io, init.environ_map, global)) |data| {
                const name = global.target orelse init.environ_map.get("WING_TARGET") orelse data.current orelse "unknown";
                if (std.ascii.eqlIgnoreCase(std.fs.path.extension(data.file), ".properties"))
                    fatal(allocPrint(alloc, "no registry '{s}' in {s}; a properties file defines a single registry", .{ name, data.file }), global.errors_json, command);
                const available = std.mem.join(alloc, ", ", data.names) catch "";
                fatal(allocPrint(alloc, "no registry '{s}' in {s} (available: {s})", .{ name, data.file, available }), global.errors_json, command);
            } else |_| {}
        }
        const message: []const u8 = if (err == error.MissingRegistry)
            "no Schema Registry configured; pass --registry URL, set SCHEMA_REGISTRY_URL, or run wing registry init"
        else if (err == error.ConfigFileNotFound)
            "config file not found"
        else if (err == error.TargetWithoutFile)
            "@NAME requires a config file with a registries section"
        else if (err == error.JavaTruststore)
            "Java truststores (.jks/.p12) are not supported; configure a PEM CA bundle"
        else if (err == error.InvalidRequestTimeout)
            "schema.registry.request.timeout.ms must be a positive integer"
        else
            @errorName(err);
        fatal(message, global.errors_json, command);
    };
    if (settings.basic_auth != null and settings.file != null and
        !std.mem.eql(u8, settings.origins.get("basic.auth.user.info") orelse "", "environment"))
    {
        if (std.Io.Dir.cwd().statFile(init.io, settings.file.?, .{})) |stat| {
            if (stat.permissions.toMode() & 0o077 != 0)
                stderr("warning: {s} is readable by other users; run chmod 600 {s}", .{ settings.file.?, settings.file.? });
        } else |_| {}
    }
    if (global.verbose) {
        var sources: std.ArrayListUnmanaged([]const u8) = .empty;
        if (global.registry != null or global.config != null or global.schema_dir != null or global.target != null)
            sources.append(init.arena.allocator(), "flags") catch {};
        const env_keys = [_][]const u8{
            "SCHEMA_REGISTRY_URL",
            "SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO",
            "SCHEMA_REGISTRY_BEARER_AUTH_TOKEN",
            "SCHEMA_REGISTRY_SSL_TRUSTSTORE_LOCATION",
            "SCHEMA_REGISTRY_SSL_INSECURE",
            "SCHEMA_REGISTRY_REQUEST_TIMEOUT_MS",
            "WING_SCHEMA_DIR",
            "WING_TARGET",
        };
        for (env_keys) |key| {
            if (init.environ_map.get(key) != null) {
                sources.append(init.arena.allocator(), "environment") catch {};
                break;
            }
        }
        if (settings.file) |file| sources.append(init.arena.allocator(), file) catch {};
        if (sources.items.len > 0) {
            const chain = std.mem.join(init.arena.allocator(), " > ", sources.items) catch "";
            stderr("config from {s}", .{chain});
        }
        if (settings.urls.len > 0) {
            stderr("{s}", .{registryDescription(init.arena.allocator(), global, settings)});
        } else if (settings.schema_dir) |directory| {
            stderr("schema cache {s}", .{directory});
        }
    }
    return settings;
}

pub fn registryDescription(alloc: std.mem.Allocator, global: cli.Global, settings: config.Settings) []const u8 {
    if (settings.url_origin) |origin| {
        if (std.mem.eql(u8, origin, "from --registry") or std.mem.eql(u8, origin, "from SCHEMA_REGISTRY_URL"))
            return std.fmt.allocPrint(alloc, "registry URL {s} ({s})", .{ settings.urls, origin }) catch "registry URL";
    }
    if (global.registry) |url|
        return std.fmt.allocPrint(alloc, "registry URL {s} (from --registry)", .{url}) catch "registry URL";
    if (settings.target) |name| {
        const origin = settings.registry_origin orelse settings.url_origin orelse "from config";
        return std.fmt.allocPrint(alloc, "registry '{s}' ({s})", .{ name, origin }) catch "registry";
    }
    return std.fmt.allocPrint(alloc, "registry URL {s} ({s})", .{ settings.urls, settings.url_origin orelse "from config" }) catch "registry URL";
}

pub fn noSchemaMessage(
    alloc: std.mem.Allocator,
    topic: []const u8,
    subject: []const u8,
    global: cli.Global,
    settings: config.Settings,
) []const u8 {
    const registry = registryDescription(alloc, global, settings);
    return std.fmt.allocPrint(alloc, "no schema for topic '{s}' (subject {s} not found in {s})", .{ topic, subject, registry }) catch "schema not found";
}

pub fn topicFromSubject(subject: []const u8) []const u8 {
    if (std.mem.endsWith(u8, subject, "-value")) return subject[0 .. subject.len - "-value".len];
    if (std.mem.endsWith(u8, subject, "-key")) return subject[0 .. subject.len - "-key".len];
    return subject;
}

pub fn versionList(alloc: std.mem.Allocator, versions: std.json.Value) []const u8 {
    if (versions != .array) return "";
    var values: std.ArrayListUnmanaged([]const u8) = .empty;
    for (versions.array.items) |value| {
        values.append(alloc, registry_mod.valueText(alloc, value) catch "?") catch {};
    }
    return std.mem.join(alloc, ", ", values.items) catch "";
}

pub fn hasVersion(alloc: std.mem.Allocator, versions: std.json.Value, wanted: []const u8) bool {
    if (versions != .array) return false;
    for (versions.array.items) |value| {
        if (std.mem.eql(u8, registry_mod.valueText(alloc, value) catch "", wanted)) return true;
    }
    return false;
}

pub fn latestVersion(alloc: std.mem.Allocator, versions: std.json.Value) []const u8 {
    if (versions != .array or versions.array.items.len == 0) return "latest";
    var latest = versions.array.items[0];
    var latest_number = std.fmt.parseInt(u64, registry_mod.valueText(alloc, latest) catch "0", 10) catch 0;
    for (versions.array.items[1..]) |candidate| {
        const number = std.fmt.parseInt(u64, registry_mod.valueText(alloc, candidate) catch "0", 10) catch 0;
        if (number > latest_number) {
            latest = candidate;
            latest_number = number;
        }
    }
    return registry_mod.valueText(alloc, latest) catch "latest";
}

pub fn unknownVersionMessage(
    alloc: std.mem.Allocator,
    subject: []const u8,
    version: []const u8,
    versions: std.json.Value,
) []const u8 {
    return std.fmt.allocPrint(alloc, "{s} has no version {s} (versions: {s})", .{
        subject,
        version,
        versionList(alloc, versions),
    }) catch "unknown schema version";
}

test "registry diagnostics include selection origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const settings: config.Settings = .{
        .urls = "http://localhost:8081",
        .target = "prod",
        .registry_origin = "from @prod",
    };
    const description = registryDescription(alloc, .{}, settings);
    try std.testing.expectEqualStrings("registry 'prod' (from @prod)", description);
    const message = noSchemaMessage(alloc, "orders", "orders-value", .{}, settings);
    try std.testing.expectEqualStrings(
        "no schema for topic 'orders' (subject orders-value not found in registry 'prod' (from @prod))",
        message,
    );
}

test "parse reference syntax" {
    const Case = struct {
        reference: []const u8,
        allow_latest: bool,
        subject: []const u8,
        version: ?[]const u8,
    };
    const cases = [_]Case{
        .{ "orders", true, "orders", null },
        .{ "orders:3", true, "orders", "3" },
        .{ "orders:latest", true, "orders", "latest" },
        .{ "orders-value:7", true, "orders-value", "7" },
        .{ ":.ctx:orders-value", true, ":.ctx:orders-value", null },
        .{ ":.ctx:orders-value:3", true, ":.ctx:orders-value", "3" },
    };
    inline for (cases) |case| {
        const parsed = try parseReference(case[0], case[1]);
        try std.testing.expectEqualStrings(case[2], parsed.subject);
        if (case[3]) |version| {
            try std.testing.expectEqualStrings(version, parsed.version.?);
        } else {
            try std.testing.expect(parsed.version == null);
        }
    }
    try std.testing.expectError(error.InvalidVersion, parseReference("orders:abc", true));
    try std.testing.expectError(error.InvalidVersion, parseReference("orders:0", true));
    try std.testing.expectError(error.InvalidVersion, parseReference("orders:latest", false));
}

pub fn registryFor(init: std.process.Init, settings: config.Settings) registry_mod.Registry {
    return registry_mod.Registry.init(init.io, init.arena.allocator(), init.environ_map, settings);
}

pub fn commandError(reg: *registry_mod.Registry, err: anyerror, global: cli.Global, command: []const u8) noreturn {
    fatal(reg.last_error orelse @errorName(err), global.errors_json, command);
}

pub fn headerParseableGuid(text: []const u8) bool {
    _ = header.parseGuid(text) catch return false;
    return true;
}

pub fn allocPrint(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, fmt, args) catch "out of memory";
}
