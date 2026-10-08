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

const read_resolver = @import("read_resolver.zig");
const SchemaInfo = read_resolver.SchemaInfo;
const Resolver = read_resolver.Resolver;
const recordFatal = read_resolver.recordFatal;
const readNote = read_resolver.readNote;
const jsonUnsigned = read_resolver.jsonUnsigned;
const topicForSubject = read_resolver.topicForSubject;

var interrupted = std.atomic.Value(bool).init(false);

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
        if (!global.quiet) readNote(global, "wing read: reading kite consume --json lines from the terminal (Ctrl-D to finish)");
    }

    var stdin_buffer: [8192]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var lines = record_io.LineReader.init(&input.interface, alloc);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    read_resolver.active_stdout = &output;
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

        const value_bytes = try input_record.payloadBytes(record_alloc, input_record.value);
        const value_result = if (value_bytes.len == 0)
            PartResult{ .node = input_record.value, .payload = value_bytes, .source_was_string = input_record.value.value == .string and input_record.value_b64_bytes == null, .empty = true }
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
                printJsonInvalid(line_number, input_record, value_result.errors, key_result);
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
        } else if (value_result.empty and key_result == null and
            input_record.value_b64_bytes == null and input_record.key_b64_bytes == null)
        {
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
        const diagnostics = app.Diagnostics.init("read", global);
        if (global.errors_json) {
            diagnostics.value(.{
                .command = "read",
                .kind = "summary",
                .read = read_count,
                .passed = passed,
                .failed = failed,
                .empty = empty,
            });
        } else {
            diagnostics.print("wing read: {d} read, {d} passed, {d} failed{s}", .{
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
    const payload_all = try input.payloadBytes(alloc, node);
    var result: PartResult = .{
        .node = node,
        .payload = payload_all,
        .source_was_string = node.value == .string and
            !(node == input.value and input.value_b64_bytes != null) and
            !(if (input.key) |key_node| node == key_node and input.key_b64_bytes != null else false),
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
            result.errors = try singleFailure(alloc, try std.fmt.allocPrint(alloc, "corrupt {s} header ({d} bytes; was the line re-encoded by jq?; upgrade kite so it emits value_b64)", .{ header_name, bytes.len }));
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
    const topic = if (record.field(input.document.root, "topic")) |topic_node|
        if (topic_node.value == .string) topic_node.value.string else null
    else
        null;
    result.info = try resolver.resolve(prefix, key, topic, line_number);
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
        if (std.mem.eql(u8, name, "value_b64")) continue;
        if (std.mem.eql(u8, name, "value")) {
            if (member.value != input.value or wrote_value) continue;
            try writePartValue(&output.writer, alloc, &first, input.document, value, "value", "value_b64");
            wrote_value = true;
        } else if (std.mem.eql(u8, name, "key")) {
            if (input.key == null or member.value != input.key.? or wrote_key) continue;
            if (key) |part| {
                try writePartValue(&output.writer, alloc, &first, input.document, part, "key", "key_b64");
            } else if (member.value.value == .null_value) {
                try writeFieldPrefix(&output.writer, alloc, &first, "key");
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
            wrote_key = true;
        } else if (std.mem.eql(u8, name, "key_b64")) {
            if (input.key == null or member.value != input.key.? or wrote_key) continue;
            if (key) |part| {
                try writePartValue(&output.writer, alloc, &first, input.document, part, "key", "key_b64");
            } else {
                try record.writeBytesField(&output.writer, &first, "key", "key_b64", input.key_b64_bytes.?);
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
        try writePartValue(&output.writer, alloc, &first, input.document, value, "value", "value_b64");
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

fn writePartValue(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    first: *bool,
    document: jv.Document,
    part: PartResult,
    plain_name: []const u8,
    b64_name: []const u8,
) !void {
    if (part.inline_value) {
        try writeFieldPrefix(writer, alloc, first, plain_name);
        try writer.writeAll(part.payload);
    } else if (part.source_was_string and !part.stripped_prefix and part.node != null and
        std.unicode.utf8ValidateSlice(part.payload))
    {
        try writeFieldPrefix(writer, alloc, first, plain_name);
        try writer.writeAll(record.raw(document, part.node.?));
    } else {
        try record.writeBytesField(writer, first, plain_name, b64_name, part.payload);
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
            if (item.value) |bytes| {
                var header_first = false;
                try record.writeBytesField(writer, &header_first, "value", "value_b64", bytes);
            } else {
                try writer.writeAll(",\"value\":null");
            }
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
    const diagnostics: app.Diagnostics = .{ .command = "read", .json = false };
    const writer = diagnostics.begin();
    defer diagnostics.end(writer);
    writer.print("wing read: line {d}{s}: {s}{s}{s}{s}", .{
        line_number, position, prefix, if (instance.len > 0) instance else "", if (instance.len > 0) ": " else "", failure.@"error",
    }) catch {};
    if (keyword.len > 0) writer.print(" [{s}]", .{keyword}) catch {};
    if (context) |suffix| writer.print("{s}", .{suffix}) catch {};
}

fn printJsonInvalid(
    line_number: usize,
    input: record.Record,
    value_errors: []const schema_validate.Failure,
    key: ?PartResult,
) void {
    const key_errors: []const schema_validate.Failure = if (key) |part| part.errors else &.{};
    (app.Diagnostics{ .command = "read", .json = true }).invalid(line_number, input, &.{ value_errors, key_errors });
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
        var colored = std.Io.Writer.Allocating.init(alloc);
        try term.writeJsonColored(&colored.writer, bytes);
        rendered = colored.written();
    }
    record_io.writeLine(&output.interface, rendered) catch |err| {
        const cause = output.err orelse err;
        if (cause == error.BrokenPipe or stdoutClosed()) std.process.exit(0);
        return err;
    };
}

fn outputFailure(err: anyerror, errors_json: bool) noreturn {
    const cause = if (read_resolver.active_stdout) |output| output.err orelse err else err;
    if (cause == error.BrokenPipe or stdoutClosed()) std.process.exit(0);
    app.fatal("failed writing stdout", errors_json, "read");
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
