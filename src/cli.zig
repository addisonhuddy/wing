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
    const opt = if (std.mem.indexOfScalar(u8, arg, '=')) |at| arg[0..at] else arg;
    if (suggestion(opt)) |candidate|
        return std.fmt.allocPrint(alloc, "unknown option '{s}' (did you mean '{s}'?)", .{ arg, candidate }) catch "out of memory";
    return std.fmt.allocPrint(alloc, "unknown option '{s}'", .{arg}) catch "out of memory";
}

pub fn commandSuggestion(name: []const u8) ?[]const u8 {
    const commands = [_][]const u8{ "read", "write", "ls", "get", "push", "rm", "registry", "update" };
    var best: ?[]const u8 = null;
    var best_dist: usize = 3;
    var tie = false;
    for (commands) |candidate| {
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
        if (std.mem.eql(u8, arg, "--registry") or std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "--schema-dir") or std.mem.eql(u8, arg, "--errors")) {
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
        return "wing ls [TOPIC] [--key] [--json]\nList subjects or versions registered for a topic.\nOptions:\n  --key                 Select T-key instead of T-value.\n  --json                Print JSON lines instead of a table.\n  -h, --help            Show this help.\n";
    if (std.mem.eql(u8, command, "get"))
        return "wing get REF [--meta] [--key]\nPrint a registered JSON Schema.\nOptions:\n  --meta                Print the full registry envelope.\n  --key                 Select the topic key subject.\n  -h, --help            Show this help.\n";
    if (std.mem.eql(u8, command, "rm"))
        return "wing rm REF [-y] [--permanent] [--key]\nDelete a subject or one version.\nOptions:\n  -y, --yes             Skip terminal confirmation.\n  --permanent           Permanently delete after soft deletion.\n  --key                 Select the topic key subject.\n  -h, --help            Show this help.\n";
    if (std.mem.eql(u8, command, "registry"))
        return "wing registry [list [--json] | set NAME | init]\nPick, list, or configure registries.\nOptions:\n  --json                Print registry names as JSON.\n  -h, --help            Show this help.\n";
    if (std.mem.eql(u8, command, "read")) return "wing read [--check]\nRead kite --json records. Not implemented yet.\n";
    if (std.mem.eql(u8, command, "write")) return "wing write [REF] [--fit] [--check]\nWrite kite --json records. Not implemented yet.\n";
    if (std.mem.eql(u8, command, "push"))
        return "wing push TOPIC [OPTIONS]\nPublish a JSON Schema. Not implemented yet.\nOptions:\n  --check               Validate without registering.\n  --fixtures DIR        Validate example records.\n  --compat LEVEL        Set the compatibility level.\n  --meta                Read a wing get --meta envelope.\n  --key                 Register a key schema.\n";
    if (std.mem.eql(u8, command, "update")) return "wing update [VERSION]\nInstall a wing release from addisonhuddy/wing.\n";
    return "wing - Confluent Schema Registry CLI for JSON Schema\nUsage:\n  wing COMMAND [OPTIONS] [@NAME]\nCommands:\n  read       Read and validate kite records.\n  write      Validate and annotate records for production.\n  ls         List subjects or versions.\n  get        Fetch a schema.\n  push       Register a schema.\n  rm         Delete a schema subject or version.\n  registry   Configure registries.\n  update     Update wing.\nGlobal options:\n  --registry URL        Select a Schema Registry URL.\n  --config FILE         Use a config file instead of searching.\n  --schema-dir DIR      Set the offline schema cache.\n  --errors=json         Emit diagnostics as JSON lines.\n  -q, -v, -h, -V        Quiet, verbose, help, version.\n";
}

test "suggestions use adjacent-transposition edit distance" {
    try std.testing.expectEqualStrings("--json", suggestion("--jsn").?);
}
