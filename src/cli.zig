const std = @import("std");

pub const version = "0.1.0";
pub const Global = struct {
    registry: ?[]const u8 = null,
    config: ?[]const u8 = null,
    schema_dir: ?[]const u8 = null,
    target: ?[]const u8 = null,
    errors_json: bool = false,
    quiet: bool = false,
    verbose: bool = false,
};
pub const Invocation = struct {
    global: Global,
    command: []const u8,
    args: []const []const u8,
};
/// Every user-facing command. Dispatch, suggestions, error attribution and
/// completion checks all read this one table.
pub const Command = enum { read, write, ls, get, push, rm, registry, update };
pub const command_names = std.meta.fieldNames(Command);
/// Global options that take a separate value argument.
pub const global_value_options = [_][]const u8{ "--registry", "--config", "--schema-dir", "--errors" };

pub fn isGlobalValueOption(arg: []const u8) bool {
    for (global_value_options) |option| if (std.mem.eql(u8, arg, option)) return true;
    return false;
}

pub const ParseResult = union(enum) { help, version, ok: Invocation, err: []const u8 };

const options = [_][]const u8{
    "--registry", "--config", "--schema-dir", "--errors", "--quiet",     "--verbose",  "--help",   "--version",
    "--key",      "--json",   "--meta",       "--yes",    "--permanent", "--fixtures", "--compat", "--check",
};

fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return 255;
    var d: [66][66]u16 = undefined;
    for (0..a.len + 1) |i| d[i][0] = @intCast(i);
    for (0..b.len + 1) |j| d[0][j] = @intCast(j);
    for (1..a.len + 1) |i| for (1..b.len + 1) |j| {
        const cost: u16 = if (a[i - 1] == b[j - 1]) 0 else 1;
        var best = @min(@min(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + cost);
        if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1])
            best = @min(best, d[i - 2][j - 2] + 1);
        d[i][j] = best;
    };
    return d[a.len][b.len];
}

fn suggestion(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = 3;
    var tie = false;
    for (options) |candidate| {
        const d = distance(name, candidate);
        if (d < best_dist) {
            best = candidate;
            best_dist = d;
            tie = false;
        } else if (d == best_dist) {
            tie = true;
        }
    }
    return if (best_dist <= 2 and !tie) best else null;
}

pub fn optionError(alloc: std.mem.Allocator, arg: []const u8) []const u8 {
    return optionErrorFor(alloc, arg, &options);
}

pub fn optionErrorFor(alloc: std.mem.Allocator, arg: []const u8, valid_options: []const []const u8) []const u8 {
    const opt = if (std.mem.indexOfScalar(u8, arg, '=')) |at| arg[0..at] else arg;
    var best: ?[]const u8 = null;
    var best_dist: usize = 3;
    var tie = false;
    for (valid_options) |candidate| {
        const candidate_dist = distance(opt, candidate);
        if (candidate_dist < best_dist) {
            best = candidate;
            best_dist = candidate_dist;
            tie = false;
        } else if (candidate_dist == best_dist) {
            tie = true;
        }
    }
    if (best_dist <= 2 and !tie)
        return std.fmt.allocPrint(alloc, "unknown option '{s}' (did you mean '{s}'?)", .{ arg, best.? }) catch "out of memory";
    return std.fmt.allocPrint(alloc, "unknown option '{s}'", .{arg}) catch "out of memory";
}

fn globalOptionError(alloc: std.mem.Allocator, arg: []const u8) []const u8 {
    const opt = if (std.mem.indexOfScalar(u8, arg, '=')) |at| arg[0..at] else arg;
    if (suggestion(opt)) |candidate|
        return std.fmt.allocPrint(alloc, "unknown option '{s}' (did you mean '{s}'?)", .{ arg, candidate }) catch "out of memory";
    return std.fmt.allocPrint(alloc, "unknown option '{s}'", .{arg}) catch "out of memory";
}

pub fn commandSuggestion(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = 3;
    var tie = false;
    for (command_names) |candidate| {
        const d = distance(name, candidate);
        if (d == 0) continue;
        if (d < best_dist) {
            best = candidate;
            best_dist = d;
            tie = false;
        } else if (d == best_dist) tie = true;
    }
    return if (best_dist <= 2 and !tie) best else null;
}

pub fn parse(alloc: std.mem.Allocator, args: []const []const u8) ParseResult {
    var global: Global = .{};
    var rest: std.ArrayListUnmanaged([]const u8) = .empty;
    var command: ?[]const u8 = null;
    var want_help = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            if (command == null) {
                want_help = true;
            } else {
                rest.append(alloc, arg) catch return .{ .err = "out of memory" };
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            if (args.len == 1) return .version;
            if (command == null) return .{ .err = optionError(alloc, arg) };
            rest.append(alloc, arg) catch return .{ .err = "out of memory" };
            continue;
        }
        if (arg.len > 0 and arg[0] == '@') {
            if (arg.len == 1) return .{ .err = "bare '@' is not a registry name" };
            for (arg[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-')
                return .{ .err = "registry names use only letters, numbers, '_' and '-'" };
            if (global.target) |previous| {
                if (!std.mem.eql(u8, previous, arg[1..]))
                    return .{ .err = std.fmt.allocPrint(alloc, "@{s} cannot be combined with {s}", .{ previous, arg }) catch "out of memory" };
            } else global.target = arg[1..];
            continue;
        }
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            global.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            global.verbose = true;
            continue;
        }
        if (isGlobalValueOption(arg)) {
            i += 1;
            if (i >= args.len) return .{ .err = std.fmt.allocPrint(alloc, "{s} requires a value", .{arg}) catch "out of memory" };
            const value = args[i];
            if (std.mem.eql(u8, arg, "--registry")) global.registry = value else if (std.mem.eql(u8, arg, "--config")) global.config = value else if (std.mem.eql(u8, arg, "--schema-dir")) global.schema_dir = value else if (std.mem.eql(u8, value, "json")) global.errors_json = true else return .{ .err = "--errors only supports json" };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--registry=")) {
            global.registry = arg["--registry=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            global.config = arg["--config=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--schema-dir=")) {
            global.schema_dir = arg["--schema-dir=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--errors=json")) {
            global.errors_json = true;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-' and command == null) return .{ .err = optionError(alloc, arg) };
        if (command == null) {
            command = arg;
        } else {
            rest.append(alloc, arg) catch return .{ .err = "out of memory" };
        }
    }
    if (want_help) return .help;
    const cmd = command orelse return .{ .err = "missing command" };
    return .{ .ok = .{ .global = global, .command = cmd, .args = rest.items } };
}

pub fn help(command: []const u8) []const u8 {
    if (std.mem.eql(u8, command, "ls"))
        return
        \\Usage: wing ls [TOPIC] [--key] [--json]
        \\
        \\List schemas registered for a topic, or list versions for a subject.
        \\
        \\Options:
        \\  --key                 Select the topic's key schema.
        \\  --json                Print JSON instead of a table.
        \\
        \\Examples:
        \\  wing ls
        \\  wing ls orders
        \\  wing ls orders --key --json
        \\
    ;
    if (std.mem.eql(u8, command, "get"))
        return
        \\Usage: wing get REF [--meta] [--key]
        \\
        \\Fetch a schema by topic, subject, version, or GUID.
        \\Pin a version with SUBJECT:VERSION; use @NAME only for registry selection.
        \\
        \\Options:
        \\  --meta                Print the registry response envelope.
        \\  --key                 Select the topic's key schema.
        \\
        \\Examples:
        \\  wing get orders
        \\  wing get orders:2
        \\  wing get orders --meta
        \\
    ;
    if (std.mem.eql(u8, command, "rm"))
        return
        \\Usage: wing rm REF [-y] [--permanent] [--key]
        \\
        \\Delete a subject or one version. Deletion is soft by default.
        \\Pin a version with SUBJECT:VERSION; use @NAME only for registry selection.
        \\
        \\Options:
        \\  -y                    Skip terminal confirmation.
        \\  --permanent           Permanently delete after soft deletion.
        \\  --key                 Select the topic's key schema.
        \\
        \\Examples:
        \\  wing rm orders
        \\  wing rm orders:2 -y
        \\  wing rm orders --permanent -y
        \\
    ;
    if (std.mem.eql(u8, command, "registry"))
        return
        \\Usage: wing registry [list [--json] | set NAME | init]
        \\
        \\List, select, or configure Schema Registry connections.
        \\
        \\Options:
        \\  --json                Print registry names as JSON.
        \\
        \\Examples:
        \\  wing registry list
        \\  wing registry set prod
        \\  wing registry init
        \\
    ;
    if (std.mem.eql(u8, command, "read"))
        return
        \\Usage: wing read [OPTIONS] [@NAME]
        \\
        \\Read kite --json records, validate them, and add schema metadata.
        \\
        \\Options:
        \\  --check               Validate without changing records.
        \\
        \\Examples:
        \\  kite consume --json orders | wing read | jq .
        \\
    ;
    if (std.mem.eql(u8, command, "write"))
        return
        \\Usage: wing write [REF] [OPTIONS] [@NAME]
        \\
        \\Validate JSON records and prepare them for kite produce.
        \\Input is kite JSON records ({"value": ...}). With a REF, a JSON object
        \\line without a "value" member is taken as the record value.
        \\Pin a version with TOPIC:VERSION; use @NAME only for registry selection.
        \\
        \\Options:
        \\  --fit                 Fit records to the selected schema.
        \\  --check               Validate without adding a header.
        \\
        \\Examples:
        \\  wing write orders < orders.jsonl | kite produce --json orders
        \\  wing write orders --fit < orders.jsonl
        \\  kite consume --json raw | wing write orders:latest --fit
        \\
    ;
    if (std.mem.eql(u8, command, "push"))
        return
        \\Usage: wing push TOPIC [OPTIONS] < schema.json
        \\
        \\Register a JSON Schema for a topic.
        \\
        \\Options:
        \\  --check               Validate without registering.
        \\  --fixtures DIR        Validate example records.
        \\  --compat LEVEL        Set the compatibility level.
        \\  --meta                Read a wing get --meta envelope.
        \\  --key                 Register a key schema.
        \\
        \\Examples:
        \\  wing push orders < orders.schema.json
        \\  wing push orders --check < orders.schema.json
        \\  wing push orders --meta < orders.meta.json
        \\
    ;
    if (std.mem.eql(u8, command, "update"))
        return
        \\Usage: wing update [VERSION]
        \\
        \\Install a release from addisonhuddy/wing.
        \\
        \\Examples:
        \\  wing update
        \\  wing update v0.1.0
        \\
    ;
    return
    \\wing - Confluent Schema Registry CLI for JSON Schema
    \\
    \\Usage:
    \\  wing read [OPTIONS] [@NAME]
    \\  wing write [REF] [OPTIONS] [@NAME]
    \\  wing ls [TOPIC] [--key] [--json]
    \\  wing get REF [--meta] [--key]
    \\  wing push TOPIC [OPTIONS] < schema.json
    \\  wing rm REF [-y] [--permanent] [--key]
    \\  wing registry [list|set NAME|init]
    \\  wing update [VERSION]
    \\
    \\Select a named registry with @NAME; the explicit choice overrides
    \\WING_TARGET and the current registry.
    \\
    \\Global options:
    \\  --registry URL        Select a Schema Registry URL.
    \\  --config FILE         Use a config file instead of searching.
    \\  --schema-dir DIR      Set the offline schema cache.
    \\  --errors=json         Emit diagnostics as JSON lines.
    \\  -q, -v, -h, -V        Quiet, verbose, help, version.
    \\
    \\Examples:
    \\  wing write orders < orders.jsonl | kite produce --json orders
    \\  kite consume --json orders | wing read | jq -c '.value.total += 1' |
    \\    wing write --fit | kite produce --json orders
    \\  wing ls orders
    \\  wing get orders:latest
    \\  wing push orders < orders.schema.json
    \\
    \\Configuration:
    \\  Search: ./wing.yaml, ./wing.properties, XDG config, then ~/.config.
    \\  Environment: SCHEMA_REGISTRY_URL, SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO,
    \\    SCHEMA_REGISTRY_BEARER_AUTH_TOKEN, WING_TARGET.
    \\  Select the saved registry with: wing registry set NAME
    \\
    ;
}

pub fn usage(command: []const u8) []const u8 {
    if (command.len == 0)
        return "Usage: wing COMMAND [OPTIONS] [@NAME]\nTry 'wing --help' for the list of commands.\n";
    if (std.mem.eql(u8, command, "ls"))
        return "Usage: wing ls [TOPIC] [--key] [--json]\nTry 'wing ls --help' for examples.\n";
    if (std.mem.eql(u8, command, "get"))
        return "Usage: wing get REF [--meta] [--key]\nTry 'wing get --help' for examples.\n";
    if (std.mem.eql(u8, command, "rm"))
        return "Usage: wing rm REF [-y] [--permanent] [--key]\nTry 'wing rm --help' for examples.\n";
    if (std.mem.eql(u8, command, "registry"))
        return "Usage: wing registry [list|set NAME|init] [OPTIONS]\nTry 'wing registry --help' for examples.\n";
    if (std.mem.eql(u8, command, "update"))
        return "Usage: wing update [VERSION]\nTry 'wing update --help' for examples.\n";
    if (std.mem.eql(u8, command, "read"))
        return "Usage: wing read [OPTIONS]\nTry 'wing read --help' for examples.\n";
    if (std.mem.eql(u8, command, "write"))
        return "Usage: wing write [REF] [OPTIONS]\nTry 'wing write --help' for examples.\n";
    if (std.mem.eql(u8, command, "push"))
        return "Usage: wing push TOPIC [OPTIONS] < schema.json\nTry 'wing push --help' for examples.\n";
    return usage("");
}

test "suggestions use adjacent-transposition edit distance" {
    try std.testing.expectEqualStrings("--json", suggestion("--jsn").?);
}
