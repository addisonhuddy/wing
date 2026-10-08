//! Schema lookup for `wing read`: header IDs/GUIDs to compiled schemas.
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

pub var active_stdout: ?*std.Io.File.Writer = null;

pub const SchemaInfo = struct {
    schema_value: std.json.Value,
    guid: ?[]const u8,
    subject: ?[]const u8,
    topic: ?[]const u8,
    version: []const u8,
    plan: *schema_compile.Plan,
    rule_set: ?std.json.Value,
};

pub const Resolver = struct {
    init: std.process.Init,
    global: cli.Global,
    settings: config.Settings,
    registry: registry_mod.Registry,
    alloc: std.mem.Allocator,
    schemas: std.StringHashMapUnmanaged(*SchemaInfo) = .empty,
    warned_rules: std.StringHashMapUnmanaged(void) = .empty,

    pub fn resolve(self: *Resolver, prefix: header.Prefix, key: bool, topic: ?[]const u8, line_number: usize) !*SchemaInfo {
        var probe_memory = std.heap.stackFallback(512, self.alloc);
        const probe_key = try prefixKey(probe_memory.get(), prefix, key, topic);
        if (self.schemas.get(probe_key)) |found| return found;
        const schema_key = try self.alloc.dupe(u8, probe_key);

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
                            if (registry_mod.stringValue(registry_mod.objectValue(value, "topic") orelse .null)) |cached_topic|
                                subject = try app.subjectForTopic(self.alloc, cached_topic, key);
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
                }
                if (!was_cached and self.settings.urls.len > 0) {
                    const location = self.registry.guidLocation(text, key, topic) catch |err| {
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
                const location = self.registry.idLocation(id, key, topic) catch |err|
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
            if (!was_cached and self.settings.schema_dir != null)
                self.writeCache(info) catch |err| {
                    if (!self.global.quiet) readNote(self.global, std.fmt.allocPrint(
                        self.alloc,
                        "wing read: could not write schema cache for GUID '{s}': {s}",
                        .{ guid_text, @errorName(err) },
                    ) catch "wing read: could not write schema cache");
                };
        }
        return info;
    }

    pub fn prefixKey(alloc: std.mem.Allocator, prefix: header.Prefix, key: bool, topic: ?[]const u8) ![]const u8 {
        const role = if (key) "key" else "value";
        const topic_name = topic orelse "";
        return switch (prefix) {
            .guid => |bytes| blk: {
                var formatted: [36]u8 = undefined;
                break :blk try std.fmt.allocPrint(alloc, "guid:{s}:{s}:{d}:{s}", .{
                    header.formatGuid(bytes, &formatted), role, topic_name.len, topic_name,
                });
            },
            .id => |id| try std.fmt.allocPrint(alloc, "id:{d}:{s}:{d}:{s}", .{
                id, role, topic_name.len, topic_name,
            }),
        };
    }

    pub fn writeCache(self: *Resolver, info: *const SchemaInfo) !void {
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

    pub fn warnRuleSet(self: *Resolver, info: *const SchemaInfo) !void {
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
        readNote(self.global, try std.fmt.allocPrint(self.alloc, "wing read: schema {s} has rules that wing does not run", .{key}));
    }
};

pub fn recordFatal(global: cli.Global, alloc: std.mem.Allocator, line_number: usize, comptime fmt: []const u8, args: anytype) noreturn {
    if (active_stdout) |output| output.interface.flush() catch {};
    const message = std.fmt.allocPrint(alloc, fmt, args) catch "record processing failed";
    if (global.errors_json) {
        const full = std.fmt.allocPrint(alloc, "wing read: line {d}: {s}", .{ line_number, message }) catch message;
        app.fatal(full, true, "read");
    }
    std.debug.print("wing read: line {d}: {s}\n", .{ line_number, message });
    std.process.exit(1);
}

pub fn readNote(global: cli.Global, message: []const u8) void {
    app.Diagnostics.init("read", global).note(message);
}

pub fn jsonUnsigned(alloc: std.mem.Allocator, value: std.json.Value) ?u32 {
    const text = registry_mod.valueText(alloc, value) catch return null;
    return std.fmt.parseInt(u32, text, 10) catch null;
}

pub fn topicForSubject(subject: ?[]const u8) ?[]const u8 {
    const name = subject orelse return null;
    if (std.mem.endsWith(u8, name, "-value")) return name[0 .. name.len - "-value".len];
    if (std.mem.endsWith(u8, name, "-key")) return name[0 .. name.len - "-key".len];
    return null;
}
