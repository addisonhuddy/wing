const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const registry_mod = @import("registry.zig");
const term = @import("term.zig");
const jv = @import("jv.zig");
const header = @import("header.zig");
const app = @import("app.zig");
const fatal = app.fatal;
const writeStdout = app.writeStdout;
const has = app.has;
const isTty = app.isTty;
const emitJsonLines = app.emitJsonLines;
const stringOf = app.stringOf;
const jsonField = app.jsonField;
const textField = app.textField;
const subjectForTopic = app.subjectForTopic;
const optionError = app.optionError;
const settingsFor = app.settingsFor;
const noSchemaMessage = app.noSchemaMessage;
const topicFromSubject = app.topicFromSubject;
const registryFor = app.registryFor;
const commandError = app.commandError;
const allocPrint = app.allocPrint;

pub fn run(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
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
    const settings = settingsFor(init, global, "ls");
    var reg = registryFor(init, settings);
    const subjects = reg.subjects() catch |err| commandError(&reg, err, global, "ls");
    if (subjects != .array) return error.InvalidResponse;
    const TopicRow = struct { topic: []const u8, versions: usize, compat: []const u8 };
    const VersionRow = struct { version: u64, id: u64, guid: []const u8 };
    var topic_rows: std.ArrayListUnmanaged(TopicRow) = .empty;
    var version_rows: std.ArrayListUnmanaged(VersionRow) = .empty;
    var found_subject = false;
    for (subjects.array.items) |item| {
        const subject = stringOf(item) orelse continue;
        if (std.mem.indexOfScalar(u8, subject, ':') != null) continue;
        if (topic) |t| {
            const expected = try subjectForTopic(alloc, t, key);
            if (!std.mem.eql(u8, subject, expected)) continue;
            found_subject = true;
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
    if (topic != null and (!found_subject or version_rows.items.len == 0)) {
        const subject = try subjectForTopic(alloc, topic.?, key);
        fatal(noSchemaMessage(alloc, topicFromSubject(topic.?), subject, global, settings), global.errors_json, "ls");
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
    } else {
        var out = std.Io.Writer.Allocating.init(alloc);
        if (topic != null) {
            var version_width: usize = "VERSION".len;
            var id_width: usize = "ID".len;
            var guid_width: usize = "GUID".len;
            for (version_rows.items) |row| {
                version_width = @max(version_width, (try std.fmt.allocPrint(alloc, "{d}", .{row.version})).len);
                id_width = @max(id_width, (try std.fmt.allocPrint(alloc, "{d}", .{row.id})).len);
                guid_width = @max(guid_width, row.guid.len);
            }
            try term.writeTableCell(&out.writer, "VERSION", version_width);
            try out.writer.writeAll("  ");
            try term.writeTableCell(&out.writer, "ID", id_width);
            try out.writer.writeAll("  ");
            try term.writeTableCell(&out.writer, "GUID", guid_width);
            try out.writer.writeByte('\n');
            for (version_rows.items) |row| {
                try term.writeTableCell(&out.writer, try std.fmt.allocPrint(alloc, "{d}", .{row.version}), version_width);
                try out.writer.writeAll("  ");
                try term.writeTableCell(&out.writer, try std.fmt.allocPrint(alloc, "{d}", .{row.id}), id_width);
                try out.writer.writeAll("  ");
                try out.writer.writeAll(row.guid);
                try out.writer.writeByte('\n');
            }
        } else {
            var topic_width: usize = "TOPIC".len;
            var versions_width: usize = "VERSIONS".len;
            var compat_width: usize = "COMPAT".len;
            for (topic_rows.items) |row| {
                topic_width = @max(topic_width, row.topic.len);
                versions_width = @max(versions_width, (try std.fmt.allocPrint(alloc, "{d}", .{row.versions})).len);
                compat_width = @max(compat_width, row.compat.len);
            }
            try term.writeTableCell(&out.writer, "TOPIC", topic_width);
            try out.writer.writeAll("  ");
            try term.writeTableCell(&out.writer, "VERSIONS", versions_width);
            try out.writer.writeAll("  ");
            try term.writeTableCell(&out.writer, "COMPAT", compat_width);
            try out.writer.writeByte('\n');
            for (topic_rows.items) |row| {
                try term.writeTableCell(&out.writer, row.topic, topic_width);
                try out.writer.writeAll("  ");
                try term.writeTableCell(&out.writer, try std.fmt.allocPrint(alloc, "{d}", .{row.versions}), versions_width);
                try out.writer.writeAll("  ");
                try out.writer.writeAll(row.compat);
                try out.writer.writeByte('\n');
            }
        }
        writeStdout(io, out.written(), global.errors_json, "ls");
    }
}
