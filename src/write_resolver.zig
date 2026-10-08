//! Schema selection for `wing write`: REF, schema headers and GUIDs.
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

pub const Info = struct {
    value: std.json.Value,
    guid: []const u8,
    subject: []const u8,
    topic: ?[]const u8,
    version: []const u8,
    plan: *compile.Plan,
};

pub const Part = struct {
    node: ?*jv.Node = null,
    payload: []const u8 = "",
    failures: []const validate.Failure = &.{},
    changes: []const fit.Change = &.{},
    inline_value: bool = false,
    source_string: bool = false,
    changed: bool = false,
};

pub const Resolver = struct {
    init: std.process.Init,
    global: cli.Global,
    settings: config.Settings,
    registry: registry_mod.Registry,
    alloc: std.mem.Allocator,
    schemas: std.StringHashMapUnmanaged(*Info) = .empty,
    lookups: std.StringHashMapUnmanaged(?*Info) = .empty,

    pub fn resolve(self: *Resolver, reference: []const u8, key: bool, line: usize) !*Info {
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

    pub fn latestKey(self: *Resolver, topic: []const u8, line: usize) !?*Info {
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

    pub fn resolveGuid(self: *Resolver, record_guid: []const u8, key: bool, record_topic: ?[]const u8, line: usize) !*Info {
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

    pub fn makeInfo(
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

    pub fn cacheInfo(self: *Resolver, info: *const Info) !void {
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

pub fn fatalFmt(resolver: *Resolver, comptime fmt: []const u8, args: anytype) noreturn {
    const message = std.fmt.allocPrint(resolver.alloc, "wing write: {s}", .{
        std.fmt.allocPrint(resolver.alloc, fmt, args) catch "write failed",
    }) catch "wing write: write failed";
    if (resolver.global.errors_json) app.fatal(message, true, "write");
    std.debug.print("{s}\n", .{message});
    std.process.exit(1);
}

pub fn fatal(global: cli.Global, command: []const u8, message: []const u8) noreturn {
    app.fatal(message, global.errors_json, command);
}

pub fn fatalLine(global: cli.Global, line: usize, message: []const u8) noreturn {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("wing write: line {d}: {s}", .{ line, message }) catch {};
    const full = writer.buffered();
    if (global.errors_json) app.fatal(full, true, "write");
    std.debug.print("{s}\n", .{full});
    std.process.exit(1);
}

pub fn writeNote(global: cli.Global, message: []const u8) void {
    app.Diagnostics.init("write", global).note(message);
}
