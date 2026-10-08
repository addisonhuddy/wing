const std = @import("std");
const jv = @import("jv.zig");
const schema = @import("schema/compile.zig");
const validator = @import("schema/validate.zig");
const fitter = @import("schema/fit.zig");
const regex = @import("regex.zig");
const app = @import("app.zig");
const record_io = @import("record_io.zig");

pub fn validateCommand(init: std.process.Init, args: []const []const u8) !noreturn {
    const alloc = init.arena.allocator();
    if (args.len == 0) usage();
    const schema_path = args[0];
    var draft: schema.Draft = .draft07;
    var remotes: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--draft") and index + 1 < args.len) {
            index += 1;
            draft = parseDraft(args[index]) orelse usage();
        } else if (std.mem.eql(u8, args[index], "--remotes") and index + 1 < args.len) {
            index += 1;
            remotes = args[index];
        } else usage();
    }
    const schema_text = std.Io.Dir.cwd().readFileAlloc(init.io, schema_path, alloc, .limited(16 * 1024 * 1024)) catch {
        app.stderr("cannot read schema file '{s}'", .{schema_path});
        std.process.exit(1);
    };
    var plan_arena = std.heap.ArenaAllocator.init(alloc);
    defer plan_arena.deinit();
    const plan_alloc = plan_arena.allocator();
    const document = jv.parse(plan_alloc, schema_text) catch {
        app.stderr("invalid JSON schema in '{s}'", .{schema_path});
        std.process.exit(1);
    };
    const resources = if (remotes) |path| try loadResources(init, plan_alloc, path, "http://localhost:1234/") else &.{};
    const plan = schema.compile(plan_alloc, document, .{ .default_draft = draft, .extra_resources = resources }) catch |err| {
        app.stderr("cannot compile schema '{s}': {s}", .{ schema_path, compileErrorMessage(alloc, document.root, err) });
        std.process.exit(1);
    };

    var stdin_buffer: [8192]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var lines = record_io.LineReader.init(&reader.interface, alloc);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var record_arena = std.heap.ArenaAllocator.init(alloc);
    defer record_arena.deinit();
    var invalid = false;
    while (try lines.next()) |line| {
        defer _ = record_arena.reset(.retain_capacity);
        const record_alloc = record_arena.allocator();
        const instance = jv.parse(record_alloc, line) catch {
            invalid = true;
            record_io.writeLine(&writer.interface, "invalid") catch
                app.fatal("failed writing stdout", false, "wing-testkit");
            record_io.writeLine(&writer.interface, "invalid JSON instance") catch
                app.fatal("failed writing stdout", false, "wing-testkit");
            continue;
        };
        const errors = try validator.validate(record_alloc, &plan, instance.root, .{});
        if (errors.len == 0) {
            writer.interface.writeAll("valid\n") catch
                app.fatal("failed writing stdout", false, "wing-testkit");
        } else {
            invalid = true;
            record_io.writeLine(&writer.interface, "invalid") catch
                app.fatal("failed writing stdout", false, "wing-testkit");
            for (errors) |failure| {
                writer.interface.print("{s}: {s}: {s}\n", .{
                    failure.instanceLocation,
                    failure.keywordLocation,
                    failure.@"error",
                }) catch app.fatal("failed writing stdout", false, "wing-testkit");
            }
        }
    }
    writer.interface.flush() catch app.fatal("failed writing stdout", false, "wing-testkit");
    std.process.exit(if (invalid) 2 else 0);
}

pub fn jstsCommand(init: std.process.Init, args: []const []const u8) !noreturn {
    const alloc = init.arena.allocator();
    if (args.len < 3 or !std.mem.eql(u8, args[1], "--draft")) usage();
    const draft = parseDraft(args[2]) orelse usage();
    const tests_path = args[0];
    const test_dir = std.Io.Dir.cwd().openDir(init.io, tests_path, .{ .iterate = true }) catch {
        app.stderr("cannot read JSON-Schema-Test-Suite draft directory '{s}'", .{tests_path});
        std.process.exit(1);
    };
    defer test_dir.close(init.io);
    const suite_root = try std.fs.path.join(alloc, &.{ tests_path, "..", ".." });
    const remote_path = try std.fs.path.join(alloc, &.{ suite_root, "remotes" });
    const resources = loadResources(init, alloc, remote_path, "http://localhost:1234/") catch &.{};
    var required_total: usize = 0;
    var required_failed: usize = 0;
    var required_files: usize = 0;
    var iter = test_dir.iterate();
    while (try iter.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const result = try runSuiteFile(init, alloc, test_dir, entry.name, draft, resources, false);
        required_total += result.total;
        required_failed += result.failed;
        required_files += 1;
    }
    if (required_total == 0) {
        app.stderr("{s}: no required tests found", .{draftName(draft)});
        std.process.exit(1);
    }
    app.stderr("{s}: {d}/{d} passed ({d} files)", .{ draftName(draft), required_total - required_failed, required_total, required_files });

    if (std.Io.Dir.cwd().openDir(init.io, try std.fs.path.join(alloc, &.{ tests_path, "optional" }), .{ .iterate = true })) |optional_dir| {
        defer optional_dir.close(init.io);
        var optional_iter = optional_dir.iterate();
        var optional_total: usize = 0;
        var optional_failed: usize = 0;
        while (try optional_iter.next(init.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            const result = try runSuiteFile(init, alloc, optional_dir, entry.name, draft, resources, true);
            optional_total += result.total;
            optional_failed += result.failed;
        }
        app.stderr("optional/{s}: {d}/{d} passed (informational)", .{ draftName(draft), optional_total - optional_failed, optional_total });
    } else |_| {}
    std.process.exit(if (required_failed == 0) 0 else 1);
}

pub fn fitPropertiesCommand(init: std.process.Init, args: []const []const u8) !noreturn {
    const alloc = init.arena.allocator();
    if (args.len != 1) usage();
    const tests_path = args[0];
    const test_dir = std.Io.Dir.cwd().openDir(init.io, tests_path, .{ .iterate = true }) catch {
        app.stderr("cannot read JSON-Schema-Test-Suite draft directory '{s}'", .{tests_path});
        std.process.exit(1);
    };
    defer test_dir.close(init.io);
    const suite_root = try std.fs.path.join(alloc, &.{ tests_path, "..", ".." });
    const remote_path = try std.fs.path.join(alloc, &.{ suite_root, "remotes" });
    const resources = loadResources(init, alloc, remote_path, "http://localhost:1234/") catch &.{};
    var iter = test_dir.iterate();
    var valid_count: usize = 0;
    var mutated_count: usize = 0;
    var fitted_mutations: usize = 0;
    var failures: usize = 0;
    while (try iter.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const source = try test_dir.readFileAlloc(init.io, entry.name, alloc, .limited(16 * 1024 * 1024));
        const file_doc = jv.parse(alloc, source) catch continue;
        if (file_doc.root.value != .array) continue;
        for (file_doc.root.value.array) |group| {
            const schema_node = objectField(group, "schema") orelse continue;
            const schema_doc = jv.Document{ .root = @constCast(schema_node), .source = source };
            const plan = schema.compile(alloc, schema_doc, .{ .default_draft = .draft07, .extra_resources = resources }) catch continue;
            const tests = objectField(group, "tests") orelse continue;
            if (tests.value != .array) continue;
            for (tests.value.array) |case| {
                const expected = objectField(case, "valid") orelse continue;
                if (expected.value != .boolean or !expected.value.boolean) continue;
                const original = objectField(case, "data") orelse objectField(case, "instance") orelse continue;
                var record_arena = std.heap.ArenaAllocator.init(alloc);
                const record_alloc = record_arena.allocator();

                const before = try jv.stringify(record_alloc, original);
                const valid_copy = try cloneInstance(record_alloc, original);
                const fitted = try fitter.apply(record_alloc, &plan, valid_copy);
                const after = try jv.stringify(record_alloc, fitted.node);
                if (!std.mem.eql(u8, before, after) or fitted.changes.len != 0 or
                    (try validator.validate(record_alloc, &plan, fitted.node, .{})).len != 0)
                {
                    failures += 1;
                    app.stderr("fit property failed for valid instance in {s}", .{entry.name});
                } else {
                    valid_count += 1;
                }
                const again = try fitter.apply(record_alloc, &plan, fitted.node);
                if (again.changes.len != 0) {
                    failures += 1;
                    app.stderr("fit idempotence failed for {s}", .{entry.name});
                }

                const mutated = try cloneInstance(record_alloc, original);
                if (mutateInstance(record_alloc, mutated)) {
                    mutated_count += 1;
                    const mutation_fit = try fitter.apply(record_alloc, &plan, mutated);
                    const output_errors = try validator.validate(record_alloc, &plan, mutation_fit.node, .{});
                    if (output_errors.len == 0) {
                        fitted_mutations += 1;
                        const second = try fitter.apply(record_alloc, &plan, mutation_fit.node);
                        if (second.changes.len != 0 or
                            (try validator.validate(record_alloc, &plan, second.node, .{})).len != 0)
                        {
                            failures += 1;
                            app.stderr("fit mutation property failed for {s}", .{entry.name});
                        }
                    }
                }
                record_arena.deinit();
            }
        }
    }
    app.stderr("fit draft7 properties: {d} valid, {d} mutated ({d} fitted-valid)", .{ valid_count, mutated_count, fitted_mutations });
    std.process.exit(if (valid_count == 0 or failures != 0) 1 else 0);
}

fn cloneInstance(alloc: std.mem.Allocator, source: *const jv.Node) !*jv.Node {
    const clone = try alloc.create(jv.Node);
    clone.* = source.*;
    switch (source.value) {
        .object => |members| {
            const copied = try alloc.alloc(jv.Member, members.len);
            for (members, 0..) |member, index| copied[index] = .{
                .key = member.key,
                .value = try cloneInstance(alloc, member.value),
            };
            clone.value = .{ .object = copied };
        },
        .array => |values| {
            const copied = try alloc.alloc(*jv.Node, values.len);
            for (values, 0..) |value, index| copied[index] = try cloneInstance(alloc, value);
            clone.value = .{ .array = copied };
        },
        else => {},
    }
    return clone;
}

fn mutateInstance(alloc: std.mem.Allocator, value: *jv.Node) bool {
    switch (value.value) {
        .object => |members| {
            const copied = alloc.alloc(jv.Member, members.len) catch return false;
            @memcpy(copied, members);
            if (members.len > 0) {
                const replacement = alloc.create(jv.Node) catch return false;
                replacement.* = .{ .value = .{ .string = "__fit_mutation__" }, .span = .{ .start = 0, .end = 0 } };
                copied[0].value = replacement;
                value.value = .{ .object = copied };
                return true;
            }
            const key = alloc.dupe(u8, "__fit_mutation__") catch return false;
            const item = alloc.create(jv.Node) catch return false;
            item.* = .{ .value = .{ .boolean = true }, .span = .{ .start = 0, .end = 0 } };
            const extended = alloc.alloc(jv.Member, 1) catch return false;
            extended[0] = .{ .key = key, .value = item };
            value.value = .{ .object = extended };
            return true;
        },
        .array => |values| {
            if (values.len == 0) return false;
            const copied = alloc.alloc(*jv.Node, values.len) catch return false;
            @memcpy(copied, values);
            const replacement = alloc.create(jv.Node) catch return false;
            replacement.* = .{ .value = .{ .string = "__fit_mutation__" }, .span = .{ .start = 0, .end = 0 } };
            copied[0] = replacement;
            value.value = .{ .array = copied };
            return true;
        },
        .string => {
            value.value = .{ .string = "__fit_mutation__" };
            return true;
        },
        .number => |text| {
            value.value = .{ .string = text };
            return true;
        },
        .boolean => |boolean| {
            value.value = .{ .string = if (boolean) "true" else "false" };
            return true;
        },
        .null_value => {
            value.value = .{ .string = "null" };
            return true;
        },
    }
}

const SuiteResult = struct { total: usize = 0, failed: usize = 0 };

fn runSuiteFile(
    init: std.process.Init,
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    name: []const u8,
    draft: schema.Draft,
    resources: []const schema.ResourceSource,
    optional: bool,
) !SuiteResult {
    const source = try dir.readFileAlloc(init.io, name, alloc, .limited(16 * 1024 * 1024));
    var file_arena = std.heap.ArenaAllocator.init(alloc);
    defer file_arena.deinit();
    const file_alloc = file_arena.allocator();
    const document = jv.parse(file_alloc, source) catch {
        app.stderr("{s}{s}: invalid test file", .{ if (optional) "optional/" else "", name });
        return .{ .total = 1, .failed = 1 };
    };
    if (document.root.value != .array) return .{ .total = 0, .failed = 0 };
    var result: SuiteResult = .{};
    for (document.root.value.array) |group| {
        const schema_value = objectField(group, "schema") orelse continue;
        const schema_doc = jv.Document{ .root = @constCast(schema_value), .source = source };
        var plan_arena = std.heap.ArenaAllocator.init(alloc);
        defer plan_arena.deinit();
        const plan_alloc = plan_arena.allocator();
        const plan = schema.compile(plan_alloc, schema_doc, .{ .default_draft = draft, .extra_resources = resources }) catch |err| {
            app.stderr("{s}{s}: schema compile failed: {s}", .{ if (optional) "optional/" else "", name, compileErrorMessage(alloc, schema_doc.root, err) });
            result.failed += arrayLength(objectField(group, "tests"));
            result.total += arrayLength(objectField(group, "tests"));
            continue;
        };
        const tests = objectField(group, "tests") orelse continue;
        if (tests.value != .array) continue;
        for (tests.value.array) |case| {
            const instance = objectField(case, "data") orelse objectField(case, "instance") orelse continue;
            const expected_node = objectField(case, "valid") orelse continue;
            if (expected_node.value != .boolean) continue;
            result.total += 1;
            var record_arena = std.heap.ArenaAllocator.init(alloc);
            defer record_arena.deinit();
            const failures = try validator.validate(record_arena.allocator(), &plan, instance, .{});
            const actual_valid = failures.len == 0;
            if (actual_valid != expected_node.value.boolean) {
                result.failed += 1;
                app.stderr("{s}{s}: {s}: expected {s}, got {s}", .{
                    if (optional) "optional/" else "",
                    name,
                    try std.fmt.allocPrint(alloc, "{s} / {s}", .{
                        stringField(group, "description") orelse "(unnamed group)",
                        stringField(case, "description") orelse "(unnamed test)",
                    }),
                    if (expected_node.value.boolean) "valid" else "invalid",
                    if (actual_valid) "valid" else "invalid",
                });
            }
        }
    }
    return result;
}

fn loadResources(init: std.process.Init, alloc: std.mem.Allocator, root_path: []const u8, base_uri: []const u8) ![]const schema.ResourceSource {
    const root = try std.Io.Dir.cwd().openDir(init.io, root_path, .{ .iterate = true });
    defer root.close(init.io);
    var walker = try root.walk(alloc);
    defer walker.deinit();
    var resources: std.ArrayListUnmanaged(schema.ResourceSource) = .empty;
    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        const content = root.readFileAlloc(init.io, entry.path, alloc, .limited(4 * 1024 * 1024)) catch continue;
        const document = jv.parse(alloc, content) catch continue;
        const resource_uri = try std.fmt.allocPrint(alloc, "{s}{s}", .{ base_uri, entry.path });
        try resources.append(alloc, .{ .uri = resource_uri, .document = document });
    }
    return resources.toOwnedSlice(alloc);
}

fn parseDraft(value: []const u8) ?schema.Draft {
    if (std.mem.eql(u8, value, "4") or std.mem.eql(u8, value, "draft4") or std.mem.eql(u8, value, "draft-04")) return .draft04;
    if (std.mem.eql(u8, value, "6") or std.mem.eql(u8, value, "draft6") or std.mem.eql(u8, value, "draft-06")) return .draft06;
    if (std.mem.eql(u8, value, "7") or std.mem.eql(u8, value, "draft7") or std.mem.eql(u8, value, "draft-07")) return .draft07;
    if (std.mem.eql(u8, value, "draft2019-09") or std.mem.eql(u8, value, "2019-09")) return .draft2019_09;
    if (std.mem.eql(u8, value, "draft2020-12") or std.mem.eql(u8, value, "2020-12")) return .draft2020_12;
    return null;
}

fn draftName(draft: schema.Draft) []const u8 {
    return switch (draft) {
        .draft04 => "draft4",
        .draft06 => "draft6",
        .draft07 => "draft7",
        .draft2019_09 => "draft2019-09",
        .draft2020_12 => "draft2020-12",
    };
}

fn objectField(node: *const jv.Node, name: []const u8) ?*const jv.Node {
    if (node.value != .object) return null;
    for (node.value.object) |member| if (std.mem.eql(u8, member.key, name)) return member.value;
    return null;
}

fn stringField(node: *const jv.Node, name: []const u8) ?[]const u8 {
    const value = objectField(node, name) orelse return null;
    return if (value.value == .string) value.value.string else null;
}

fn arrayLength(node: ?*const jv.Node) usize {
    if (node) |value| return if (value.value == .array) value.value.array.len else 0;
    return 0;
}

fn compileErrorMessage(alloc: std.mem.Allocator, root: *const jv.Node, err: anyerror) []const u8 {
    if (findRegexError(alloc, root)) |message| return message;
    return @errorName(err);
}

fn findRegexError(alloc: std.mem.Allocator, node: *const jv.Node) ?[]const u8 {
    switch (node.value) {
        .object => |members| {
            for (members) |member| {
                if (std.mem.eql(u8, member.key, "pattern") and member.value.value == .string) {
                    var expression = regex.compile(alloc, member.value.value.string) catch |err| {
                        return regex.compileErrorMessage(alloc, member.value.value.string, err) catch null;
                    };
                    expression.deinit();
                } else if (std.mem.eql(u8, member.key, "patternProperties") and member.value.value == .object) {
                    for (member.value.value.object) |entry| {
                        var expression = regex.compile(alloc, entry.key) catch |err| {
                            return regex.compileErrorMessage(alloc, entry.key, err) catch null;
                        };
                        expression.deinit();
                    }
                }
                if (findRegexError(alloc, member.value)) |message| return message;
            }
        },
        .array => |items| for (items) |item| {
            if (findRegexError(alloc, item)) |message| return message;
        },
        else => {},
    }
    return null;
}

fn usage() noreturn {
    app.stderr("usage: wing-testkit validate SCHEMA_FILE [--draft D] [--remotes DIR]", .{});
    app.stderr("usage: wing-testkit jsts TESTS_DRAFT_DIR --draft D", .{});
    std.process.exit(1);
}
