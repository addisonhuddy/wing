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
const writeStdout = app.writeStdout;
const has = app.has;
const argAt = app.argAt;
const isTty = app.isTty;
const emitJson = app.emitJson;
const optionError = app.optionError;
const registryFor = app.registryFor;
const allocPrint = app.allocPrint;

fn setCurrentRegistry(init: std.process.Init, name: []const u8) !void {
    const path = try config.currentFilePath(init.arena.allocator(), init.environ_map);
    const parent = std.fs.path.dirname(path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(init.io, parent);
    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, name);
}

pub fn run(init: std.process.Init, global: cli.Global, args: []const []const u8) !void {
    const implicit_list = args.len == 0;
    const action_index: usize = if (argAt(args, 0)) |first| if (std.mem.startsWith(u8, first, "-")) 0 else 1 else 0;
    const action = if (action_index == 0) "list" else args[0];
    if (std.mem.eql(u8, action, "list")) {
        if (args.len - action_index > 1) fatal("unexpected argument", global.errors_json, "registry");
        for (args[action_index..]) |arg| if (!std.mem.eql(u8, arg, "--json"))
            fatal(optionError(arg, &.{"--json"}) orelse "unexpected argument", global.errors_json, "registry");
        if (global.target != null) fatal("use 'wing registry set NAME' to switch registries", global.errors_json, "registry");
        const data = config.registryNames(init.arena.allocator(), init.io, init.environ_map, global) catch fatal("no config file found; run 'wing registry init' to create one", global.errors_json, "registry");
        const picker = implicit_list and isTty(init.io, std.Io.File.stdin()) and isTty(init.io, std.Io.File.stderr());
        if (has(args, "--json")) {
            try emitJson(init.arena.allocator(), init.io, .{ .file = data.file, .current = data.current, .registries = data.names }, global.errors_json, "registry");
        } else if (!picker) {
            var out = std.Io.Writer.Allocating.init(init.arena.allocator());
            const terminal = isTty(init.io, std.Io.File.stdout());
            if (terminal) {
                var name_width: usize = "NAME".len;
                for (data.names) |name| name_width = @max(name_width, name.len);
                try term.writeTableCell(&out.writer, "NAME", name_width);
                try out.writer.writeAll("  CURRENT\n");
                for (data.names) |name| {
                    const selected = data.current != null and std.mem.eql(u8, name, data.current.?);
                    try term.writeTableCell(&out.writer, name, name_width);
                    try out.writer.print("  {s}\n", .{if (selected) "*" else ""});
                }
            } else {
                for (data.names) |name| {
                    const selected = data.current != null and std.mem.eql(u8, name, data.current.?);
                    try out.writer.print("{s}{s}\n", .{ name, if (selected) " *" else "" });
                }
            }
            writeStdout(init.io, out.written(), global.errors_json, "registry");
            if (!global.quiet) std.debug.print("wing registry: registries from {s}\n", .{data.file});
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
            std.debug.print("wing registry: registry set to '{s}'\n", .{name});
        }
    } else if (std.mem.eql(u8, action, "set")) {
        const name = argAt(args, 1) orelse fatal("missing NAME", global.errors_json, "registry");
        if (args.len != 2) fatal("unexpected argument", global.errors_json, "registry");
        const data = config.registryNames(init.arena.allocator(), init.io, init.environ_map, global) catch fatal("no config file found; run 'wing registry init' to create one", global.errors_json, "registry");
        var found = false;
        for (data.names) |item| {
            if (std.mem.eql(u8, item, name)) found = true;
        }
        if (!found) fatal(try std.fmt.allocPrint(init.arena.allocator(), "no registry '{s}' in {s}", .{ name, data.file }), global.errors_json, "registry");
        try setCurrentRegistry(init, name);
        if (!global.quiet) std.debug.print("wing registry: registry set to '{s}'\n", .{name});
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
    var compatibility_level: []const u8 = "BACKWARD";
    if (reg.get("/config")) |value| {
        const config_value = std.json.parseFromSliceLeaky(std.json.Value, alloc, value, .{
            .allocate = .alloc_always,
            .parse_numbers = false,
        }) catch .null;
        compatibility_level = registry_mod.stringValue(registry_mod.objectValue(config_value, "compatibilityLevel") orelse .null) orelse "BACKWARD";
    } else |err| {
        connection_ok = false;
        std.debug.print("wing registry: connection check failed: {s}\n", .{reg.last_error orelse @errorName(err)});
    }
    var schema_count: usize = 0;
    var subject_values: std.json.Value = .null;
    if (connection_ok) {
        if (reg.subjects()) |value| {
            subject_values = value;
        } else |err| {
            connection_ok = false;
            std.debug.print("wing registry: connection check failed: {s}\n", .{reg.last_error orelse @errorName(err)});
        }
        if (subject_values == .array) schema_count = subject_values.array.items.len;
    }
    if (!connection_ok) {
        const answer = nextAnswer(reader, alloc, "Save anyway? [y/N] ") orelse "";
        if (!std.ascii.eqlIgnoreCase(answer, "y") and !std.ascii.eqlIgnoreCase(answer, "yes")) fatal("aborted", global.errors_json, "registry");
    } else {
        stderr("connected to {s} ({d} subjects, compatibility {s})", .{ url, schema_count, compatibility_level });
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
        std.debug.print("wing registry: wrote registry '{s}' to {s}\n", .{ name, path });
        std.debug.print("wing registry: registry set to '{s}'\n", .{name});
        std.debug.print("wing registry: try: wing ls\n", .{});
        if (api_key.len > 0 and creds == null) std.debug.print("wing registry: set SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO=KEY:SECRET to use API authentication\n", .{});
    }
}

fn yamlScalar(alloc: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}
