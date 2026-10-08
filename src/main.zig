const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const registry_mod = @import("registry.zig");
const term = @import("term.zig");
const jv = @import("jv.zig");
const header = @import("header.zig");

pub const panic = std.debug.simple_panic;

fn stderr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("wing: " ++ fmt ++ "\n", args);
}

fn fatal(message: []const u8, json_errors: bool, command: []const u8) noreturn {
    if (json_errors) {
        var out = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        std.json.Stringify.value(.{ .kind = "error", .command = command, .message = message }, .{}, &out.writer) catch {};
        std.debug.print("{s}\n", .{out.written()});
    } else {
        stderr("{s}", .{message});
        if (std.mem.startsWith(u8, message, "unknown option") or
            std.mem.startsWith(u8, message, "unknown command") or
            std.mem.eql(u8, message, "missing command"))
            stderr("Try 'wing --help' for more information.", .{});
    }
    std.process.exit(1);
}

fn writeStdout(io: std.Io, bytes: []const u8, json_errors: bool, command: []const u8) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    writer.interface.writeAll(bytes) catch fatal("failed writing stdout", json_errors, command);
    writer.interface.flush() catch fatal("failed writing stdout", json_errors, command);
}

fn has(args: []const []const u8, value: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, value)) return true;
    return false;
}

fn argAt(args: []const []const u8, index: usize) ?[]const u8 {
    return if (index < args.len) args[index] else null;
}

fn isTty(io: std.Io, file: std.Io.File) bool {
    return file.isTty(io) catch false;
}

fn emitJson(alloc: std.mem.Allocator, io: std.Io, value: anytype, json_errors: bool, command: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeByte('\n');
    writeStdout(io, out.written(), json_errors, command);
}

fn emitJsonLines(alloc: std.mem.Allocator, io: std.Io, values: anytype, json_errors: bool, command: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(alloc);
    for (values) |value| {
        try std.json.Stringify.value(value, .{}, &out.writer);
        try out.writer.writeByte('\n');
    }
    writeStdout(io, out.written(), json_errors, command);
}

fn stringOf(value: std.json.Value) ?[]const u8 {
    return registry_mod.stringValue(value);
}

fn jsonField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return registry_mod.objectValue(value, key);
}

fn textField(value: std.json.Value, key: []const u8) ?[]const u8 {
    return if (jsonField(value, key)) |v| stringOf(v) else null;
}

fn subjectForTopic(alloc: std.mem.Allocator, topic: []const u8, key: bool) ![]const u8 {
    const suffix = if (key) "-key" else "-value";
    if (std.mem.endsWith(u8, topic, suffix)) return topic;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ topic, suffix });
}

fn validVersion(text: []const u8, allow_latest: bool) bool {
    if (allow_latest and std.mem.eql(u8, text, "latest")) return true;
    const number = std.fmt.parseInt(u64, text, 10) catch return false;
    return number > 0;
}

fn optionError(arg: []const u8, suggestions: []const []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, "-")) return null;
    for (suggestions) |valid| {
        if (std.mem.eql(u8, arg, valid)) return null;
    }
    return cli.optionError(std.heap.page_allocator, arg);
}

fn errorsRequested(args: []const []const u8) bool {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--errors=json")) return true;
        if (std.mem.eql(u8, arg, "--errors") and index + 1 < args.len and std.mem.eql(u8, args[index + 1], "json")) return true;
    }
    return false;
}

fn commandFromArgs(args: []const []const u8) []const u8 {
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

fn settingsFor(init: std.process.Init, global: cli.Global, command: []const u8) config.Settings {
    var settings = config.load(init.io, init.arena.allocator(), init.environ_map, global) catch |err| {
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
        if (settings.file) |file| stderr("config file: {s}", .{file});
        var it = settings.origins.iterator();
        while (it.next()) |entry| stderr("{s} from {s}", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    return settings;
}

fn registryFor(init: std.process.Init, settings: config.Settings) registry_mod.Registry {
    return registry_mod.Registry.init(init.io, init.arena.allocator(), init.environ_map, settings);
}

fn commandError(reg: *registry_mod.Registry, err: anyerror, global: cli.Global, command: []const u8) noreturn {
    fatal(reg.last_error orelse @errorName(err), global.errors_json, command);
}

fn runLs(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    var topic: ?[]const u8 = null;
    var key = false;
    const as_json = has(args, "--json");
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--key")) {
            key = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            fatal(optionError(arg, &.{ "--key", "--json" }).?, global.errors_json, "ls");
        } else if (topic == null) {
            topic = arg;
        } else {
            fatal(try std.fmt.allocPrint(alloc, "unexpected argument '{s}'", .{arg}), global.errors_json, "ls");
        }
    }
    var reg = registryFor(init, settingsFor(init, global, "ls"));
    const subjects = reg.subjects() catch |err| commandError(&reg, err, global, "ls");
    if (subjects != .array) return error.InvalidResponse;
    const TopicRow = struct { topic: []const u8, versions: usize, compat: []const u8 };
    const VersionRow = struct { version: u64, id: u64, guid: []const u8 };
    var topic_rows: std.ArrayListUnmanaged(TopicRow) = .empty;
    var version_rows: std.ArrayListUnmanaged(VersionRow) = .empty;
    for (subjects.array.items) |item| {
        const subject = stringOf(item) orelse continue;
        if (std.mem.indexOfScalar(u8, subject, ':') != null) continue;
        if (topic) |t| {
            const expected = try subjectForTopic(alloc, t, key);
            if (!std.mem.eql(u8, subject, expected)) continue;
        } else if (!std.mem.endsWith(u8, subject, if (key) "-key" else "-value")) continue;
        const topic_name = subject[0 .. subject.len - (if (key) "-key".len else "-value".len)];
        const versions = reg.versions(subject) catch |err| commandError(&reg, err, global, "ls");
        if (versions != .array) continue;
        if (topic == null) {
            try topic_rows.append(alloc, .{
                .topic = topic_name,
                .versions = versions.array.items.len,
                .compat = reg.compat(subject) catch "BACKWARD",
            });
            continue;
        }
        for (versions.array.items) |version_value| {
            const version = try registry_mod.valueText(alloc, version_value);
            const schema = reg.schema(subject, version) catch |err| commandError(&reg, err, global, "ls");
            const id_value = jsonField(schema, "id") orelse .null;
            const guid = textField(schema, "guid") orelse "";
            const id_text = registry_mod.valueText(alloc, id_value) catch "0";
            try version_rows.append(alloc, .{
                .version = std.fmt.parseInt(u64, version, 10) catch 0,
                .id = std.fmt.parseInt(u64, id_text, 10) catch 0,
                .guid = guid,
            });
        }
    }
    std.mem.sort(TopicRow, topic_rows.items, {}, struct {
        fn less(_: void, a: TopicRow, b: TopicRow) bool {
            return std.mem.lessThan(u8, a.topic, b.topic);
        }
    }.less);
    std.mem.sort(VersionRow, version_rows.items, {}, struct {
        fn less(_: void, a: VersionRow, b: VersionRow) bool {
            return a.version < b.version;
        }
    }.less);
    if (as_json) {
        if (topic != null) {
            try emitJsonLines(alloc, io, version_rows.items, global.errors_json, "ls");
        } else {
            try emitJsonLines(alloc, io, topic_rows.items, global.errors_json, "ls");
        }
    } else if (isTty(io, std.Io.File.stdout())) {
        var out = std.Io.Writer.Allocating.init(alloc);
        if (topic != null) {
            try out.writer.writeAll("VERSION  ID       GUID\n");
            for (version_rows.items) |row| try out.writer.print("{d:<8} {d:<8} {s}\n", .{ row.version, row.id, row.guid });
        } else {
            try out.writer.writeAll("TOPIC                           VERSIONS  COMPAT\n");
            for (topic_rows.items) |row| try out.writer.print("{s:<31} {d:<9} {s}\n", .{ row.topic, row.versions, row.compat });
        }
        writeStdout(io, out.written(), global.errors_json, "ls");
    } else {
        var out = std.Io.Writer.Allocating.init(alloc);
        if (topic != null) {
            for (version_rows.items) |row| try out.writer.print("{d}\n", .{row.version});
        } else {
            for (topic_rows.items) |row| try out.writer.print("{s}\n", .{row.topic});
        }
        writeStdout(io, out.written(), global.errors_json, "ls");
    }
}

fn runGet(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
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
    var reg = registryFor(init, settingsFor(init, global, "get"));
    var schema: std.json.Value = undefined;
    var subject: ?[]const u8 = null;
    var version_text: ?[]const u8 = null;
    if (reference.len == 36 and headerParseableGuid(reference)) {
        schema = reg.schemaGuid(reference) catch |err| commandError(&reg, err, global, "get");
        const loc = reg.guidLocation(reference, key) catch |err| commandError(&reg, err, global, "get");
        subject = loc.subject;
        version_text = loc.version;
        if (subject == null or version_text == null)
            fatal("GUID is not registered under a default-context topic subject", global.errors_json, "get");
    } else {
        const at = std.mem.lastIndexOfScalar(u8, reference, '@');
        const raw_subject = if (at) |idx| reference[0..idx] else reference;
        if (at) |idx| if (!validVersion(reference[idx + 1 ..], true))
            fatal("version must be 'latest' or a positive integer", global.errors_json, "get");
        subject = try subjectForTopic(alloc, raw_subject, key);
        version_text = if (at) |idx| reference[idx + 1 ..] else "latest";
        schema = reg.schema(subject.?, version_text.?) catch |err| commandError(&reg, err, global, "get");
        if (jsonField(schema, "version")) |resolved|
            version_text = registry_mod.valueText(alloc, resolved) catch version_text;
    }
    if (jsonField(schema, "references")) |references| {
        if (references == .array and references.array.items.len > 0)
            fatal("schema references are present but reference bundling is not implemented yet", global.errors_json, "get");
    }
    if (meta) {
        const topic_name = if (subject) |s|
            if (std.mem.endsWith(u8, s, "-value")) s[0 .. s.len - "-value".len] else if (std.mem.endsWith(u8, s, "-key")) s[0 .. s.len - "-key".len] else s
        else
            null;
        try emitJson(alloc, io, .{
            .topic = topic_name,
            .version = jsonField(schema, "version") orelse std.json.Value{ .number_string = version_text.? },
            .id = jsonField(schema, "id"),
            .guid = jsonField(schema, "guid"),
            .compat = if (subject) |s| reg.compat(s) catch "BACKWARD" else "BACKWARD",
            .schema = jsonField(schema, "schema"),
            .references = jsonField(schema, "references"),
            .metadata = jsonField(schema, "metadata"),
            .ruleSet = jsonField(schema, "ruleSet"),
        }, global.errors_json, "get");
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

fn runRm(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
    var reference: ?[]const u8 = null;
    const yes = has(args, "-y") or has(args, "--yes");
    const permanent = has(args, "--permanent");
    const key = has(args, "--key");
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--permanent") or std.mem.eql(u8, arg, "--key")) continue;
        if (std.mem.startsWith(u8, arg, "-")) fatal(optionError(arg, &.{ "-y", "--yes", "--permanent", "--key" }).?, global.errors_json, "rm");
        if (reference == null) reference = arg else fatal("unexpected argument", global.errors_json, "rm");
    }
    const ref = reference orelse fatal("missing REF", global.errors_json, "rm");
    if (ref.len == 36 and headerParseableGuid(ref))
        fatal("rm requires a subject or subject@version, not a GUID", global.errors_json, "rm");
    var reg = registryFor(init, settingsFor(init, global, "rm"));
    const at = std.mem.lastIndexOfScalar(u8, ref, '@');
    const raw_subject = if (at) |idx| ref[0..idx] else ref;
    const subject = try subjectForTopic(init.arena.allocator(), raw_subject, key);
    const version: ?[]const u8 = if (at) |idx| ref[idx + 1 ..] else null;
    if (version) |v| if (!validVersion(v, false))
        fatal("version must be a positive integer", global.errors_json, "rm");
    if (!yes and !isTty(init.io, std.Io.File.stderr()))
        fatal("refusing to delete without --yes when stderr is not a terminal", global.errors_json, "rm");
    if (!yes) {
        const versions = reg.versions(subject) catch |err| commandError(&reg, err, global, "rm");
        if (versions == .array) {
            for (versions.array.items) |version_value| {
                const version_text = try registry_mod.valueText(init.arena.allocator(), version_value);
                const schema = reg.schema(subject, version_text) catch |err| commandError(&reg, err, global, "rm");
                const id = registry_mod.valueText(init.arena.allocator(), jsonField(schema, "id") orelse .null) catch "?";
                const guid = textField(schema, "guid") orelse "?";
                stderr("  {s}@{s} id={s} guid={s}", .{ subject, version_text, id, guid });
            }
        }
        const prompt = if (version) |v|
            try std.fmt.allocPrint(init.arena.allocator(), "delete {s}@{s}? [y/N] ", .{ subject, v })
        else
            try std.fmt.allocPrint(init.arena.allocator(), "delete {s} ({d} versions)? [y/N] ", .{ subject, if (versions == .array) versions.array.items.len else 0 });
        const confirmed = term.confirm(init.io, prompt) orelse
            fatal("refusing to delete without --yes when stderr is not a terminal", global.errors_json, "rm");
        if (!confirmed) fatal("deletion cancelled", global.errors_json, "rm");
    }
    const suffix = if (version) |v| try std.fmt.allocPrint(init.arena.allocator(), "/{s}", .{v}) else "";
    const path = try std.fmt.allocPrint(init.arena.allocator(), "/subjects/{s}{s}", .{ try registry_mod.pathEscape(init.arena.allocator(), subject), suffix });
    _ = reg.delete(path) catch |err| commandError(&reg, err, global, "rm");
    if (permanent) {
        const hard = try std.fmt.allocPrint(init.arena.allocator(), "{s}?permanent=true", .{path});
        _ = reg.delete(hard) catch |err| commandError(&reg, err, global, "rm");
    }
    if (!global.quiet) stderr("deleted {s}", .{subject});
}

fn headerParseableGuid(text: []const u8) bool {
    _ = header.parseGuid(text) catch return false;
    return true;
}

fn setCurrentRegistry(init: std.process.Init, name: []const u8) !void {
    const path = try config.currentFilePath(init.arena.allocator(), init.environ_map);
    const parent = std.fs.path.dirname(path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(init.io, parent);
    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, name);
}

fn runRegistry(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
    const implicit_list = args.len == 0;
    const action_index: usize = if (argAt(args, 0)) |first| if (std.mem.startsWith(u8, first, "-")) 0 else 1 else 0;
    const action = if (action_index == 0) "list" else args[0];
    if (std.mem.eql(u8, action, "list")) {
        if (args.len - action_index > 1) fatal("unexpected argument", global.errors_json, "registry");
        for (args[action_index..]) |arg| if (!std.mem.eql(u8, arg, "--json"))
            fatal(optionError(arg, &.{"--json"}) orelse "unexpected argument", global.errors_json, "registry");
        if (global.target != null) fatal("use 'wing registry set NAME' to switch registries", global.errors_json, "registry");
        const data = config.registryNames(init.arena.allocator(), init.io, init.environ_map, global) catch fatal("no config file found", global.errors_json, "registry");
        const picker = implicit_list and isTty(init.io, std.Io.File.stdin()) and isTty(init.io, std.Io.File.stderr());
        if (has(args, "--json")) {
            try emitJson(init.arena.allocator(), init.io, .{ .file = data.file, .current = data.current, .registries = data.names }, global.errors_json, "registry");
        } else if (!picker) {
            var out = std.Io.Writer.Allocating.init(init.arena.allocator());
            const terminal = isTty(init.io, std.Io.File.stdout());
            for (data.names) |name| {
                const selected = data.current != null and std.mem.eql(u8, name, data.current.?);
                if (terminal) {
                    try out.writer.print("{s}{s}\n", .{ if (selected) "* " else "  ", name });
                } else {
                    try out.writer.print("{s}{s}\n", .{ name, if (selected) " *" else "" });
                }
            }
            writeStdout(init.io, out.written(), global.errors_json, "registry");
            if (!global.quiet) stderr("registries from {s}", .{data.file});
        }
        if (picker and data.names.len > 0) {
            var prompt = std.Io.Writer.Allocating.init(init.arena.allocator());
            for (data.names, 0..) |name, index| {
                const selected = data.current != null and std.mem.eql(u8, name, data.current.?);
                try prompt.writer.print("{s} {d}) {s}\n", .{ if (selected) "*" else " ", index + 1, name });
            }
            stderr("{s}", .{prompt.written()});
            var input_buf: [128]u8 = undefined;
            var input = std.Io.File.stdin().reader(init.io, &input_buf);
            const answer = nextAnswer(&input.interface, init.arena.allocator(), "Select registry (number or name): ") orelse fatal("aborted", global.errors_json, "registry");
            var selected: ?[]const u8 = null;
            for (data.names, 0..) |name, index| {
                if (std.mem.eql(u8, name, answer)) selected = name;
                const number = std.fmt.allocPrint(init.arena.allocator(), "{d}", .{index + 1}) catch "";
                if (std.mem.eql(u8, number, answer)) selected = name;
            }
            const name = selected orelse fatal("unknown registry selection", global.errors_json, "registry");
            try setCurrentRegistry(init, name);
            stderr("registry set to '{s}'", .{name});
        }
    } else if (std.mem.eql(u8, action, "set")) {
        const name = argAt(args, 1) orelse fatal("missing NAME", global.errors_json, "registry");
        if (args.len != 2) fatal("unexpected argument", global.errors_json, "registry");
        const data = config.registryNames(init.arena.allocator(), init.io, init.environ_map, global) catch fatal("no config file found", global.errors_json, "registry");
        var found = false;
        for (data.names) |item| {
            if (std.mem.eql(u8, item, name)) found = true;
        }
        if (!found) fatal(try std.fmt.allocPrint(init.arena.allocator(), "no registry '{s}' in {s}", .{ name, data.file }), global.errors_json, "registry");
        try setCurrentRegistry(init, name);
        if (!global.quiet) stderr("registry set to '{s}'", .{name});
    } else if (std.mem.eql(u8, action, "init")) {
        if (args.len != 1) fatal("unexpected argument", global.errors_json, "registry");
        try runRegistryInit(init, global);
    } else {
        fatal("unknown registry action (want list, set, or init)", global.errors_json, "registry");
    }
}

fn nextAnswer(reader: *std.Io.Reader, alloc: std.mem.Allocator, prompt: []const u8) ?[]const u8 {
    std.debug.print("{s}", .{prompt});
    const line = reader.takeDelimiter('\n') catch return null;
    return if (line) |value| alloc.dupe(u8, std.mem.trim(u8, value, " \t\r")) catch null else null;
}

test "registry init answers outlive reader buffer reuse" {
    const alloc = std.testing.allocator;
    var input = "name\nhttp://localhost:8081\n".*;
    var reader = std.Io.Reader.fixed(&input);
    const name = nextAnswer(&reader, alloc, "") orelse return error.EndOfStream;
    defer alloc.free(name);
    @memcpy(input[0..4], "used");
    const url = nextAnswer(&reader, alloc, "") orelse return error.EndOfStream;
    defer alloc.free(url);
    try std.testing.expectEqualStrings("name", name);
    try std.testing.expectEqualStrings("http://localhost:8081", url);
}

fn nextSecret(init: std.process.Init, reader: *std.Io.Reader, alloc: std.mem.Allocator, prompt: []const u8) ?[]const u8 {
    if (!(std.Io.File.stdin().isTty(init.io) catch false)) return nextAnswer(reader, alloc, prompt);
    std.debug.print("{s}", .{prompt});
    const fd = std.posix.STDIN_FILENO;
    const saved = std.posix.tcgetattr(fd) catch return nextAnswer(reader, alloc, "");
    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(fd, .NOW, raw) catch {};
    defer std.posix.tcsetattr(fd, .NOW, saved) catch {};
    var out = std.ArrayListUnmanaged(u8).empty;
    var byte: [1]u8 = undefined;
    while (true) {
        const count = std.posix.read(fd, &byte) catch return null;
        if (count == 0) return null;
        if (byte[0] == '\r' or byte[0] == '\n') break;
        if (byte[0] == 3) return null;
        if (byte[0] == 8 or byte[0] == 127) {
            if (out.items.len > 0) {
                out.items.len -= 1;
                std.debug.print("\x08 \x08", .{});
            }
        } else {
            out.append(alloc, byte[0]) catch return null;
            std.debug.print("*", .{});
        }
    }
    std.debug.print("\n", .{});
    return out.items;
}

fn runRegistryInit(init: std.process.Init, global: cli.Global) !void {
    const alloc = init.arena.allocator();
    const env = init.environ_map;
    var target_path: ?[]const u8 = global.config orelse env.get("WING_CONFIG");
    if (target_path == null) {
        const candidates = [_][]const u8{ "./wing.yaml", "./wing.properties" };
        for (candidates) |candidate| {
            if (std.Io.Dir.cwd().access(init.io, candidate, .{})) |_| {
                target_path = candidate;
                break;
            } else |_| {}
        }
        if (target_path == null) {
            if (env.get("XDG_CONFIG_HOME")) |xdg| {
                target_path = try std.fmt.allocPrint(alloc, "{s}/wing/wing.yaml", .{xdg});
            } else {
                target_path = try std.fmt.allocPrint(alloc, "{s}/.config/wing/wing.yaml", .{env.get("HOME") orelse "."});
            }
        }
    }
    const path = target_path.?;
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".properties"))
        fatal("registry init cannot write a .properties file", global.errors_json, "registry");
    var contents: []const u8 = "";
    const existing = std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(4 * 1024 * 1024)) catch null;
    if (existing) |text| {
        contents = text;
        _ = config.spliceRegistry(alloc, contents, "validation-only", "  validation-only:\n    schema.registry.url: http://localhost:8081\n") catch fatal("invalid config YAML", global.errors_json, "registry");
    }

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buf);
    const reader = &stdin_reader.interface;
    const raw_name = nextAnswer(reader, alloc, "Registry name (local): ") orelse fatal("aborted", global.errors_json, "registry");
    const name = if (raw_name.len == 0) "local" else raw_name;
    if (name.len == 0) fatal("registry name must not be empty", global.errors_json, "registry");
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
        fatal("registry name must contain only letters, numbers, '_' or '-'", global.errors_json, "registry");
    };
    const raw_url = nextAnswer(reader, alloc, "Schema Registry URL (http://localhost:8081): ") orelse fatal("aborted", global.errors_json, "registry");
    const url = if (raw_url.len == 0) "http://localhost:8081" else raw_url;
    const api_key = nextAnswer(reader, alloc, "API key (empty for no auth): ") orelse fatal("aborted", global.errors_json, "registry");
    const secret = nextSecret(init, reader, alloc, "API secret (empty to leave it out): ") orelse fatal("aborted", global.errors_json, "registry");
    const creds = if (api_key.len > 0 and secret.len > 0) try std.fmt.allocPrint(alloc, "{s}:{s}", .{ api_key, secret }) else null;

    if (existing != null) {
        const info = config.registryNames(alloc, init.io, env, global) catch null;
        if (info) |data| for (data.names) |known| {
            if (std.mem.eql(u8, known, name)) {
                const answer = nextAnswer(reader, alloc, try std.fmt.allocPrint(alloc, "Registry '{s}' exists; overwrite? [y/N] ", .{name})) orelse fatal("aborted", global.errors_json, "registry");
                if (!std.ascii.eqlIgnoreCase(answer, "y") and !std.ascii.eqlIgnoreCase(answer, "yes")) fatal("aborted", global.errors_json, "registry");
            }
        };
    }

    const settings: config.Settings = .{ .urls = url, .basic_auth = creds };
    var reg = registryFor(init, settings);
    var connection_ok = true;
    if (reg.get("/config")) |_| {} else |err| {
        connection_ok = false;
        stderr("connection check failed: {s}", .{reg.last_error orelse @errorName(err)});
    }
    var schema_count: usize = 0;
    var subject_values: std.json.Value = .null;
    if (connection_ok) {
        if (reg.subjects()) |value| {
            subject_values = value;
        } else |err| {
            connection_ok = false;
            stderr("connection check failed: {s}", .{reg.last_error orelse @errorName(err)});
        }
        if (subject_values == .array) schema_count = subject_values.array.items.len;
    }
    if (!connection_ok) {
        const answer = nextAnswer(reader, alloc, "Save anyway? [y/N] ") orelse "";
        if (!std.ascii.eqlIgnoreCase(answer, "y") and !std.ascii.eqlIgnoreCase(answer, "yes")) fatal("aborted", global.errors_json, "registry");
    } else {
        stderr("connected: global compatibility, {d} subjects", .{schema_count});
    }

    const qurl = try yamlScalar(alloc, url);
    var block_writer = std.Io.Writer.Allocating.init(alloc);
    try block_writer.writer.print("  {s}:\n    schema.registry.url: {s}\n", .{ name, qurl });
    if (creds) |credential| try block_writer.writer.print("    basic.auth.user.info: {s}\n", .{try yamlScalar(alloc, credential)});
    const new_contents = config.spliceRegistry(alloc, contents, name, block_writer.written()) catch fatal("could not update config YAML", global.errors_json, "registry");
    const parent = std.fs.path.dirname(path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(init.io, parent);
    const holds_secret = creds != null or std.mem.indexOf(u8, new_contents, "basic.auth.user.info:") != null;
    const permissions: std.Io.File.Permissions = if (holds_secret) @enumFromInt(0o600) else .default_file;
    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{ .permissions = permissions });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, new_contents);
    if (holds_secret) try file.setPermissions(init.io, permissions);

    const current_path = try config.currentFilePath(alloc, env);
    const current_dir = std.fs.path.dirname(current_path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(init.io, current_dir);
    var current = try std.Io.Dir.cwd().createFile(init.io, current_path, .{});
    defer current.close(init.io);
    try current.writeStreamingAll(init.io, name);
    if (!global.quiet) {
        stderr("wrote registry '{s}' to {s}", .{ name, path });
        stderr("registry set to '{s}'", .{name});
        stderr("try: wing ls", .{});
        if (api_key.len > 0 and creds == null) stderr("set SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO=KEY:SECRET to use API authentication", .{});
    }
}

fn yamlScalar(alloc: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

const update_script =
    \\set -eu
    \\repo=addisonhuddy/wing
    \\current=v$1 bin_dir=$2 want=$3
    \\if command -v curl >/dev/null 2>&1; then
    \\    fetch() { curl -fsSL "$1"; }
    \\    headers() { curl -fsSI "$1"; }
    \\elif command -v wget >/dev/null 2>&1; then
    \\    fetch() { wget -qO- "$1"; }
    \\    headers() { wget -S --spider --max-redirect=0 "$1" 2>&1; }
    \\else echo "wing: curl or wget is required" >&2; exit 1
    \\fi
    \\if [ -z "$want" ]; then
    \\    want=$(headers "https://github.com/$repo/releases/latest" | tr -d '\r' |
    \\        sed -n 's|^ *[Ll]ocation: .*/releases/tag/\([^ ]*\).*|\1|p' | head -n 1)
    \\    [ -n "$want" ] || {
    \\        echo "wing: could not look up the latest release; see https://github.com/$repo/releases" >&2
    \\        exit 1
    \\    }
    \\    if [ "$want" = "$current" ]; then
    \\        echo "wing: already up to date ($current)" >&2
    \\        exit 0
    \\    fi
    \\fi
    \\echo "wing: updating $current to $want" >&2
    \\installer=$(fetch "https://raw.githubusercontent.com/$repo/main/install.sh") || {
    \\    echo "wing: could not download install.sh from github.com/$repo" >&2
    \\    exit 1
    \\}
    \\printf '%s\n' "$installer" | sh -s -- --bin-dir "$bin_dir" --version "$want"
;

fn runUpdate(init: std.process.Init, global: cli.Global, args: []const []const u8, alloc: std.mem.Allocator) noreturn {
    if (has(args, "-h") or has(args, "--help")) {
        writeStdout(init.io, cli.help("update"), global.errors_json, "update");
        std.process.exit(0);
    }
    if (args.len > 1) fatal(allocPrint(alloc, "unexpected argument '{s}'", .{args[1]}), global.errors_json, "update");
    var version: []const u8 = "";
    if (args.len == 1 and !std.mem.eql(u8, args[0], "latest")) {
        const arg = args[0];
        if (std.mem.startsWith(u8, arg, "-"))
            fatal(cli.optionError(alloc, arg), global.errors_json, "update");
        if (arg.len == 0) fatal("version must be a release tag", global.errors_json, "update");
        for (arg) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_')
            fatal(allocPrint(alloc, "'{s}' is not a release tag (want e.g. v0.1.0)", .{arg}), global.errors_json, "update");
        if (std.mem.startsWith(u8, arg, "v")) {
            version = arg;
        } else if (std.ascii.isDigit(arg[0])) {
            version = std.fmt.allocPrint(alloc, "v{s}", .{arg}) catch fatal("out of memory", global.errors_json, "update");
        } else {
            fatal(allocPrint(alloc, "'{s}' is not a release tag (want e.g. v0.1.0)", .{arg}), global.errors_json, "update");
        }
    }
    const bin_dir = std.process.executableDirPathAlloc(init.io, alloc) catch
        fatal("cannot find the directory that holds the wing binary", global.errors_json, "update");
    const argv = [_][]const u8{ "/bin/sh", "-c", update_script, "wing-update", cli.version, bin_dir, version };
    const err = std.process.replace(init.io, .{ .argv = &argv });
    fatal(allocPrint(alloc, "cannot run /bin/sh: {s}", .{@errorName(err)}), global.errors_json, "update");
}

fn allocPrint(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, fmt, args) catch "out of memory";
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(alloc);
    if (argv.len == 2 and (std.mem.eql(u8, argv[1], "-V") or std.mem.eql(u8, argv[1], "--version"))) {
        writeStdout(init.io, "wing " ++ cli.version ++ "\n", false, "");
        return;
    }
    const parsed = cli.parse(alloc, if (argv.len > 0) argv[1..] else &.{});
    const invocation = switch (parsed) {
        .help => {
            writeStdout(init.io, cli.help(""), false, "");
            return;
        },
        .version => {
            writeStdout(init.io, "wing " ++ cli.version ++ "\n", false, "");
            return;
        },
        .err => |message| fatal(message, errorsRequested(if (argv.len > 0) argv[1..] else &.{}), commandFromArgs(if (argv.len > 0) argv[1..] else &.{})),
        .ok => |value| value,
    };
    if (has(invocation.args, "--help") or has(invocation.args, "-h")) {
        writeStdout(init.io, cli.help(invocation.command), false, invocation.command);
        return;
    }
    if (std.mem.eql(u8, invocation.command, "ls")) try runLs(init, invocation.global, invocation.args) else if (std.mem.eql(u8, invocation.command, "get")) try runGet(init, invocation.global, invocation.args) else if (std.mem.eql(u8, invocation.command, "rm")) try runRm(init, invocation.global, invocation.args) else if (std.mem.eql(u8, invocation.command, "registry")) try runRegistry(init, invocation.global, invocation.args) else if (std.mem.eql(u8, invocation.command, "read") or std.mem.eql(u8, invocation.command, "write") or std.mem.eql(u8, invocation.command, "push")) {
        fatal("not implemented yet", invocation.global.errors_json, invocation.command);
    } else if (std.mem.eql(u8, invocation.command, "update")) {
        runUpdate(init, invocation.global, invocation.args, alloc);
    } else {
        const message = if (cli.commandSuggestion(invocation.command)) |candidate|
            try std.fmt.allocPrint(alloc, "unknown command '{s}'; did you mean '{s}'?", .{ invocation.command, candidate })
        else
            try std.fmt.allocPrint(alloc, "unknown command '{s}'", .{invocation.command});
        fatal(message, invocation.global.errors_json, invocation.command);
    }
}
