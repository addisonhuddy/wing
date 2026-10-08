const std = @import("std");
const yaml = @import("yaml.zig");

pub const Settings = struct {
    urls: []const u8 = "",
    basic_auth: ?[]const u8 = null,
    bearer: ?[]const u8 = null,
    truststore: ?[]const u8 = null,
    insecure: bool = false,
    extra_headers: []const []const u8 = &.{},
    schema_dir: ?[]const u8 = null,
    target: ?[]const u8 = null,
    file: ?[]const u8 = null,
    registry_origin: ?[]const u8 = null,
    url_origin: ?[]const u8 = null,
    origins: std.StringHashMapUnmanaged([]const u8) = .empty,
};

const Props = std.StringHashMapUnmanaged([]const u8);
const Doc = struct {
    defaults: Props = .empty,
    registries: std.StringHashMapUnmanaged(Props) = .empty,
    default_name: ?[]const u8 = null,
};

fn envValue(env: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

fn readFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024));
}

fn parseProperties(alloc: std.mem.Allocator, content: []const u8) !Props {
    var out: Props = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '!') continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (key.len > 0) try out.put(alloc, key, value);
    }
    return out;
}

fn collectMap(alloc: std.mem.Allocator, node: yaml.Node) !Props {
    var out: Props = .empty;
    if (node != .map) return out;
    var it = node.map.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.*) {
        .scalar => |value| try out.put(alloc, entry.key_ptr.*, value),
        .map => {},
    };
    return out;
}

fn knownKey(key: []const u8) bool {
    const exact = [_][]const u8{
        "schema.registry.url",
        "basic.auth.user.info",
        "basic.auth.credentials.source",
        "bearer.auth.token",
        "schema.registry.ssl.truststore.location",
        "schema.registry.ssl.insecure",
        "schema.dir",
    };
    for (exact) |allowed| if (std.mem.eql(u8, key, allowed)) return true;
    return std.mem.startsWith(u8, key, "http.header.");
}

fn warnUnknownProps(props: Props) void {
    var it = props.iterator();
    while (it.next()) |entry| {
        if (!knownKey(entry.key_ptr.*)) warn("unknown config key '{s}' ignored", .{entry.key_ptr.*});
    }
}

fn warnProperties(props: Props) void {
    var it = props.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (knownKey(key) or
            std.mem.eql(u8, key, "bootstrap.servers") or
            std.mem.startsWith(u8, key, "sasl.") or
            std.mem.startsWith(u8, key, "security.") or
            std.mem.startsWith(u8, key, "ssl."))
        {
            continue;
        }
        warn("unknown config key '{s}' ignored", .{key});
    }
}

fn parseYaml(alloc: std.mem.Allocator, content: []const u8) !Doc {
    var diag: yaml.Diag = .{};
    const top = try yaml.parse(alloc, content, &diag);
    var doc: Doc = .{};
    var it = top.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const node = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "default")) {
            if (node == .scalar) doc.default_name = node.scalar;
        } else if (std.mem.eql(u8, key, "defaults")) {
            doc.defaults = try collectMap(alloc, node);
            warnUnknownProps(doc.defaults);
        } else if (std.mem.eql(u8, key, "registries")) {
            if (node != .map) continue;
            var entries = node.map.iterator();
            while (entries.next()) |registry| {
                if (registry.value_ptr.* != .map) continue;
                const props = try collectMap(alloc, registry.value_ptr.*);
                warnUnknownProps(props);
                try doc.registries.put(alloc, registry.key_ptr.*, props);
            }
        } else {
            warn("unknown config key '{s}' ignored", .{key});
        }
    }
    return doc;
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("wing: warning: " ++ fmt ++ "\n", args);
}

fn contains(map: Props, key: []const u8) ?[]const u8 {
    const value = map.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

fn currentPath(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    const xdg = envValue(env, "XDG_CONFIG_HOME") orelse envValue(env, "HOME") orelse ".";
    if (envValue(env, "XDG_CONFIG_HOME") != null)
        return std.fmt.allocPrint(alloc, "{s}/wing/current", .{xdg});
    return std.fmt.allocPrint(alloc, "{s}/.config/wing/current", .{xdg});
}

fn readCurrent(io: std.Io, alloc: std.mem.Allocator, env: *std.process.Environ.Map) ?[]const u8 {
    const path = currentPath(alloc, env) catch return null;
    const contents = readFile(io, alloc, path) catch return null;
    const value = std.mem.trim(u8, contents, " \t\r\n");
    return if (value.len == 0) null else value;
}

fn property(env: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, "schema.registry.url")) return envValue(env, "SCHEMA_REGISTRY_URL");
    if (std.mem.eql(u8, key, "basic.auth.user.info")) return envValue(env, "SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO");
    if (std.mem.eql(u8, key, "bearer.auth.token")) return envValue(env, "SCHEMA_REGISTRY_BEARER_AUTH_TOKEN");
    if (std.mem.eql(u8, key, "schema.registry.ssl.truststore.location")) return envValue(env, "SCHEMA_REGISTRY_SSL_TRUSTSTORE_LOCATION");
    if (std.mem.eql(u8, key, "schema.registry.ssl.insecure")) return envValue(env, "SCHEMA_REGISTRY_SSL_INSECURE");
    if (std.mem.eql(u8, key, "schema.dir")) return envValue(env, "WING_SCHEMA_DIR");
    return null;
}

fn putOrigin(s: *Settings, alloc: std.mem.Allocator, key: []const u8, origin: []const u8) void {
    s.origins.put(alloc, key, origin) catch {};
}

fn first(props: Props, env: *std.process.Environ.Map, defaults: Props, key: []const u8, named: bool) ?[]const u8 {
    if (named) {
        if (contains(props, key)) |v| return v;
        if (property(env, key)) |v| return v;
    } else {
        if (property(env, key)) |v| return v;
        if (contains(props, key)) |v| return v;
    }
    if (!named) {
        if (contains(defaults, key)) |v| return v;
    } else if (contains(defaults, key)) |v| return v;
    return null;
}

pub fn load(
    io: std.Io,
    alloc: std.mem.Allocator,
    env: *std.process.Environ.Map,
    global: anytype,
) !Settings {
    return loadImpl(io, alloc, env, global, false);
}

pub fn loadAllowMissingRegistry(
    io: std.Io,
    alloc: std.mem.Allocator,
    env: *std.process.Environ.Map,
    global: anytype,
) !Settings {
    return loadImpl(io, alloc, env, global, true);
}

fn loadImpl(
    io: std.Io,
    alloc: std.mem.Allocator,
    env: *std.process.Environ.Map,
    global: anytype,
    allow_missing_registry: bool,
) !Settings {
    var s: Settings = .{};
    const explicit = global.config orelse envValue(env, "WING_CONFIG");
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    if (explicit) |p| {
        try paths.append(alloc, p);
    } else {
        try paths.appendSlice(alloc, &.{"./wing.yaml"});
        try paths.appendSlice(alloc, &.{"./wing.properties"});
        if (envValue(env, "XDG_CONFIG_HOME")) |xdg| {
            try paths.append(alloc, try std.fmt.allocPrint(alloc, "{s}/wing/wing.yaml", .{xdg}));
            try paths.append(alloc, try std.fmt.allocPrint(alloc, "{s}/wing/wing.properties", .{xdg}));
        }
        if (envValue(env, "HOME")) |home| {
            try paths.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.config/wing/wing.yaml", .{home}));
            try paths.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.config/wing/wing.properties", .{home}));
        }
    }
    var content: ?[]u8 = null;
    var doc: Doc = .{};
    for (paths.items) |path| {
        content = readFile(io, alloc, path) catch |err| {
            if (explicit != null) return error.ConfigFileNotFound;
            if (err == error.FileNotFound) continue;
            continue;
        };
        s.file = path;
        if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".properties")) {
            doc.defaults = try parseProperties(alloc, content.?);
            warnProperties(doc.defaults);
            try doc.registries.put(alloc, "default", doc.defaults);
            doc.default_name = "default";
        } else {
            doc = try parseYaml(alloc, content.?);
        }
        break;
    }

    const explicit_target = global.target orelse envValue(env, "WING_TARGET");
    const current = readCurrent(io, alloc, env);
    var target = explicit_target orelse current orelse doc.default_name;
    if (explicit_target == null and current != null and s.file != null and doc.registries.get(current.?) == null) {
        warn("current registry '{s}' is not in {s}; ignoring it", .{ current.?, s.file orelse "the config file" });
        target = doc.default_name;
    }
    s.target = target;
    if (global.target) |name| {
        s.registry_origin = try std.fmt.allocPrint(alloc, "from @{s}", .{name});
    } else if (envValue(env, "WING_TARGET") != null) {
        s.registry_origin = "from WING_TARGET";
    } else if (current != null) {
        const path = try currentPath(alloc, env);
        const display_path = if (envValue(env, "XDG_CONFIG_HOME") == null and envValue(env, "HOME") != null) blk: {
            const home = envValue(env, "HOME").?;
            if (std.mem.startsWith(u8, path, home))
                break :blk try std.fmt.allocPrint(alloc, "~{s}", .{path[home.len..]});
            break :blk path;
        } else path;
        s.registry_origin = try std.fmt.allocPrint(alloc, "current registry, from {s}", .{display_path});
    } else if (doc.default_name) |name| {
        s.registry_origin = if (s.file) |file|
            try std.fmt.allocPrint(alloc, "default '{s}' in {s}", .{ name, file })
        else
            try std.fmt.allocPrint(alloc, "default '{s}'", .{name});
    }
    var selected = Props.empty;
    var named = false;
    if (target) |name| {
        if (s.file == null and explicit_target != null) return error.TargetWithoutFile;
        if (doc.registries.get(name)) |entry| {
            selected = entry;
            named = true;
        } else if (s.file != null and (doc.registries.count() > 0 or target != null)) {
            return error.NoSuchRegistry;
        }
    }

    const keys = [_][]const u8{
        "schema.registry.url",
        "basic.auth.user.info",
        "bearer.auth.token",
        "schema.registry.ssl.truststore.location",
        "schema.registry.ssl.insecure",
        "schema.dir",
    };
    var values: [keys.len]?[]const u8 = undefined;
    for (keys, 0..) |key, i| {
        values[i] = if (global.registry != null and std.mem.eql(u8, key, "schema.registry.url"))
            global.registry
        else if (global.schema_dir != null and std.mem.eql(u8, key, "schema.dir"))
            global.schema_dir
        else
            first(selected, env, doc.defaults, key, named);
        if (values[i] != null) {
            const origin: []const u8 = if (global.registry != null and std.mem.eql(u8, key, "schema.registry.url"))
                "flag"
            else if (global.schema_dir != null and std.mem.eql(u8, key, "schema.dir"))
                "flag"
            else if (named and contains(selected, key) != null)
                "registry"
            else if (property(env, key) != null)
                "environment"
            else if (contains(selected, key) != null)
                "registry"
            else if (contains(doc.defaults, key) != null)
                "defaults"
            else
                "file";
            putOrigin(&s, alloc, key, origin);
            if (std.mem.eql(u8, key, "schema.registry.url")) {
                s.url_origin = if (std.mem.eql(u8, origin, "flag"))
                    "from --registry"
                else if (std.mem.eql(u8, origin, "environment"))
                    "from SCHEMA_REGISTRY_URL"
                else if (std.mem.eql(u8, origin, "registry"))
                    if (s.target) |name|
                        try std.fmt.allocPrint(alloc, "from registry '{s}' in {s}", .{ name, s.file orelse "config" })
                    else
                        try std.fmt.allocPrint(alloc, "from {s}", .{s.file orelse "config"})
                else if (std.mem.eql(u8, origin, "defaults"))
                    try std.fmt.allocPrint(alloc, "from defaults in {s}", .{s.file orelse "config"})
                else
                    try std.fmt.allocPrint(alloc, "from {s}", .{s.file orelse "config"});
            }
        }
    }
    s.urls = values[0] orelse "";
    s.basic_auth = values[1];
    s.bearer = values[2];
    s.truststore = values[3];
    s.insecure = if (values[4]) |v| std.ascii.eqlIgnoreCase(v, "true") else false;
    s.schema_dir = global.schema_dir orelse values[5];
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    var chosen = selected.iterator();
    while (chosen.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "http.header.")) {
            const name = entry.key_ptr.*["http.header.".len..];
            try headers.append(alloc, try std.fmt.allocPrint(alloc, "{s}={s}", .{ name, entry.value_ptr.* }));
        }
    }
    var fallback = doc.defaults.iterator();
    while (fallback.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "http.header.") and contains(selected, entry.key_ptr.*) == null) {
            const name = entry.key_ptr.*["http.header.".len..];
            try headers.append(alloc, try std.fmt.allocPrint(alloc, "{s}={s}", .{ name, entry.value_ptr.* }));
        }
    }
    s.extra_headers = headers.items;
    if (s.truststore) |path| {
        if (std.ascii.endsWithIgnoreCase(path, ".jks") or std.ascii.endsWithIgnoreCase(path, ".p12"))
            return error.JavaTruststore;
    }
    if (s.insecure) warn("schema.registry.ssl.insecure is set; TLS certificate verification is disabled", .{});
    if (s.urls.len == 0 and !allow_missing_registry) return error.MissingRegistry;
    return s;
}

pub fn registryNames(alloc: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, global: anytype) !struct { names: [][]const u8, file: []const u8, current: ?[]const u8 } {
    const explicit = global.config orelse envValue(env, "WING_CONFIG");
    const path = explicit orelse blk: {
        if (std.Io.Dir.cwd().access(io, "./wing.yaml", .{})) |_| break :blk "./wing.yaml" else |_| {}
        if (std.Io.Dir.cwd().access(io, "./wing.properties", .{})) |_| break :blk "./wing.properties" else |_| {}
        if (envValue(env, "XDG_CONFIG_HOME")) |xdg| {
            const y = try std.fmt.allocPrint(alloc, "{s}/wing/wing.yaml", .{xdg});
            if (std.Io.Dir.cwd().access(io, y, .{})) |_| break :blk y else |_| {}
            const p = try std.fmt.allocPrint(alloc, "{s}/wing/wing.properties", .{xdg});
            if (std.Io.Dir.cwd().access(io, p, .{})) |_| break :blk p else |_| {}
        }
        if (envValue(env, "HOME")) |home| {
            const y = try std.fmt.allocPrint(alloc, "{s}/.config/wing/wing.yaml", .{home});
            if (std.Io.Dir.cwd().access(io, y, .{})) |_| break :blk y else |_| {}
            const p = try std.fmt.allocPrint(alloc, "{s}/.config/wing/wing.properties", .{home});
            if (std.Io.Dir.cwd().access(io, p, .{})) |_| break :blk p else |_| {}
        }
        return error.ConfigFileNotFound;
    };
    const contents = try readFile(io, alloc, path);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var default_name: ?[]const u8 = null;
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".properties")) {
        try names.append(alloc, "default");
        default_name = "default";
    } else {
        const doc = try parseYaml(alloc, contents);
        default_name = doc.default_name;
        var it = doc.registries.iterator();
        while (it.next()) |entry| try names.append(alloc, entry.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
    }
    var current = envValue(env, "WING_TARGET") orelse readCurrent(io, alloc, env) orelse default_name;
    if (current) |selected| {
        var found = false;
        for (names.items) |name| {
            if (std.mem.eql(u8, selected, name)) found = true;
        }
        if (!found) {
            warn("current registry '{s}' is not in {s}; ignoring it", .{ selected, path });
            current = default_name;
        }
    }
    return .{ .names = names.items, .file = path, .current = current };
}

pub fn spliceRegistry(alloc: std.mem.Allocator, text: []const u8, name: []const u8, block: []const u8) ![]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| try lines.append(alloc, line);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) lines.items.len -= 1;
    var section: ?usize = null;
    for (lines.items, 0..) |line, i| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, line, " ") or std.mem.startsWith(u8, line, "\t")) continue;
        if (std.mem.eql(u8, trimmed, "registries:")) {
            section = i;
            break;
        }
    }
    var output: std.ArrayListUnmanaged(u8) = .empty;
    if (section) |start| {
        var end = lines.items.len;
        for (lines.items[start + 1 ..], start + 1..) |line, i| {
            if (line.len > 0 and line[0] != ' ' and line[0] != '\t' and line[0] != '#') {
                end = i;
                break;
            }
        }
        var replace_start: ?usize = null;
        var replace_end: usize = 0;
        for (lines.items[start + 1 .. end], start + 1..) |line, i| {
            if (line.len < 3 or line[0] != ' ' or line[1] != ' ') continue;
            const rest = std.mem.trimStart(u8, line, " ");
            if (std.mem.startsWith(u8, rest, name) and rest.len > name.len and rest[name.len] == ':') {
                replace_start = i;
                replace_end = i + 1;
                while (replace_end < end) : (replace_end += 1) {
                    const next = lines.items[replace_end];
                    if (next.len == 0 or next[0] == '#') continue;
                    if (next.len >= 2 and next[0] == ' ' and next[1] == ' ' and
                        (next.len == 2 or (next[2] != ' ' and next[2] != '\t'))) break;
                    if (next[0] == ' ' or next[0] == '\t') continue;
                    break;
                }
                break;
            }
        }
        if (replace_start) |at| {
            for (lines.items[0..at]) |line| {
                try output.appendSlice(alloc, line);
                try output.append(alloc, '\n');
            }
            try output.appendSlice(alloc, block);
            for (lines.items[replace_end..]) |line| {
                try output.appendSlice(alloc, line);
                try output.append(alloc, '\n');
            }
        } else {
            for (lines.items[0..end]) |line| {
                try output.appendSlice(alloc, line);
                try output.append(alloc, '\n');
            }
            try output.appendSlice(alloc, block);
            for (lines.items[end..]) |line| {
                try output.appendSlice(alloc, line);
                try output.append(alloc, '\n');
            }
        }
    } else {
        for (lines.items) |line| {
            try output.appendSlice(alloc, line);
            try output.append(alloc, '\n');
        }
        if (lines.items.len > 0) try output.append(alloc, '\n');
        try output.appendSlice(alloc, "registries:\n");
        try output.appendSlice(alloc, block);
    }
    const result = try output.toOwnedSlice(alloc);
    _ = try parseYaml(alloc, result);
    return result;
}

pub fn currentFilePath(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    return currentPath(alloc, env);
}

test "registry properties parse key value config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const props = try parseProperties(arena.allocator(), "schema.registry.url=http://localhost:8081\n#x\n");
    try std.testing.expectEqualStrings("http://localhost:8081", props.get("schema.registry.url").?);
}

test "registry splice preserves following entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const original =
        \\registries:
        \\  local:
        \\    schema.registry.url: http://old
        \\  prod:
        \\    schema.registry.url: http://prod
    ;
    const updated = try spliceRegistry(arena.allocator(), original, "local", "  local:\n    schema.registry.url: http://new\n");
    try std.testing.expect(std.mem.indexOf(u8, updated, "schema.registry.url: http://new") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "schema.registry.url: http://prod") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "schema.registry.url: http://old") == null);
}
