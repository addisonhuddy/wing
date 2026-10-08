const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const registry_mod = @import("registry.zig");
const term = @import("term.zig");
const jv = @import("jv.zig");
const header = @import("header.zig");
const app = @import("app.zig");
const stderr = app.stderr;
const fatal = app.fatal;
const has = app.has;
const isTty = app.isTty;
const jsonField = app.jsonField;
const textField = app.textField;
const subjectForTopic = app.subjectForTopic;
const validVersion = app.validVersion;
const optionError = app.optionError;
const settingsFor = app.settingsFor;
const noSchemaMessage = app.noSchemaMessage;
const topicFromSubject = app.topicFromSubject;
const hasVersion = app.hasVersion;
const unknownVersionMessage = app.unknownVersionMessage;
const registryFor = app.registryFor;
const commandError = app.commandError;
const headerParseableGuid = app.headerParseableGuid;
const allocPrint = app.allocPrint;

pub fn run(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
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
    if (!yes and !isTty(init.io, std.Io.File.stderr()))
        fatal("refusing to delete without -y (stderr is not a terminal)", global.errors_json, "rm");
    const settings = settingsFor(init, global, "rm");
    var reg = registryFor(init, settings);
    const at = std.mem.lastIndexOfScalar(u8, ref, '@');
    const raw_subject = if (at) |idx| ref[0..idx] else ref;
    const subject = try subjectForTopic(init.arena.allocator(), raw_subject, key);
    const version: ?[]const u8 = if (at) |idx| ref[idx + 1 ..] else null;
    if (version) |v| if (!validVersion(v, false))
        fatal("version must be a positive integer", global.errors_json, "rm");
    const versions = reg.versions(subject) catch |err| {
        if (reg.last_status == 404)
            fatal(noSchemaMessage(init.arena.allocator(), topicFromSubject(raw_subject), subject, global, settings), global.errors_json, "rm");
        commandError(&reg, err, global, "rm");
    };
    if (versions != .array or versions.array.items.len == 0)
        fatal(noSchemaMessage(init.arena.allocator(), topicFromSubject(raw_subject), subject, global, settings), global.errors_json, "rm");
    if (version) |v| if (!hasVersion(init.arena.allocator(), versions, v))
        fatal(unknownVersionMessage(init.arena.allocator(), subject, v, versions), global.errors_json, "rm");
    if (!yes) {
        if (versions == .array) {
            for (versions.array.items) |version_value| {
                const version_text = try registry_mod.valueText(init.arena.allocator(), version_value);
                const schema = reg.schema(subject, version_text) catch |err| commandError(&reg, err, global, "rm");
                const id = registry_mod.valueText(init.arena.allocator(), jsonField(schema, "id") orelse .null) catch "?";
                const guid = textField(schema, "guid") orelse "?";
                std.debug.print("wing rm:   {s}@{s} id={s} guid={s}\n", .{ subject, version_text, id, guid });
            }
        }
        const prompt = if (version) |v|
            try std.fmt.allocPrint(init.arena.allocator(), "delete {s}@{s}? [y/N] ", .{ subject, v })
        else
            try std.fmt.allocPrint(init.arena.allocator(), "delete {s} ({d} versions)? [y/N] ", .{ subject, if (versions == .array) versions.array.items.len else 0 });
        const confirmed = term.confirm(init.io, prompt) orelse
            fatal("refusing to delete without -y (stderr is not a terminal)", global.errors_json, "rm");
        if (!confirmed) fatal("deletion cancelled", global.errors_json, "rm");
    }
    const suffix = if (version) |v| try std.fmt.allocPrint(init.arena.allocator(), "/{s}", .{v}) else "";
    const path = try std.fmt.allocPrint(init.arena.allocator(), "/subjects/{s}{s}", .{ try registry_mod.pathEscape(init.arena.allocator(), subject), suffix });
    _ = reg.delete(path) catch |err| commandError(&reg, err, global, "rm");
    if (permanent) {
        const hard = try std.fmt.allocPrint(init.arena.allocator(), "{s}?permanent=true", .{path});
        _ = reg.delete(hard) catch |err| commandError(&reg, err, global, "rm");
    }
    if (!global.quiet) std.debug.print("wing rm: deleted {s}\n", .{subject});
}
