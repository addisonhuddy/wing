const std = @import("std");
const http = @import("http.zig");
const config = @import("config.zig");
const header = @import("header.zig");

pub const Registry = struct {
    alloc: std.mem.Allocator,
    client: http.Client,
    last_error: ?[]const u8 = null,
    last_status: u16 = 0,

    pub fn init(
        io: std.Io,
        alloc: std.mem.Allocator,
        env: *std.process.Environ.Map,
        settings: config.Settings,
    ) Registry {
        var urls = std.mem.splitScalar(u8, settings.urls, ',');
        var bases: std.ArrayListUnmanaged([]const u8) = .empty;
        while (urls.next()) |url| {
            const trimmed = std.mem.trim(u8, url, " \t");
            if (trimmed.len > 0) bases.append(alloc, trimmed) catch {};
        }
        return .{
            .alloc = alloc,
            .client = .{
                .io = io,
                .alloc = alloc,
                .env = env,
                .bases = bases.items,
                .basic_auth = settings.basic_auth,
                .bearer = settings.bearer,
                .headers = settings.extra_headers,
                .debug = if (env.get("WING_DEBUG")) |v| std.mem.eql(u8, v, "1") else false,
                .ca_bundle = settings.truststore,
                .insecure = settings.insecure,
            },
        };
    }

    pub fn get(self: *Registry, path: []const u8) ![]const u8 {
        return self.request(.GET, path, null);
    }

    pub fn post(self: *Registry, path: []const u8, payload: []const u8) ![]const u8 {
        return self.request(.POST, path, payload);
    }

    pub fn delete(self: *Registry, path: []const u8) ![]const u8 {
        return self.request(.DELETE, path, null);
    }

    fn request(self: *Registry, method: std.http.Method, path: []const u8, payload: ?[]const u8) ![]const u8 {
        const response = self.client.request(method, path, payload) catch |err| {
            self.last_status = 0;
            self.last_error = try std.fmt.allocPrint(self.alloc, "cannot reach Schema Registry at {s}: {s}", .{
                self.client.last_url orelse "configured URL",
                try errorText(self.alloc, @errorName(err)),
            });
            return err;
        };
        self.last_status = response.status;
        if (response.status >= 200 and response.status < 300) return response.body;
        if (response.status == 401 or response.status == 403) {
            self.last_error = try std.fmt.allocPrint(self.alloc, "Schema Registry at {s} rejected the credentials ({d}); check basic.auth.user.info", .{
                self.client.last_url orelse "configured URL",
                response.status,
            });
            return error.RegistryFailure;
        }
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, response.body, .{ .allocate = .alloc_always, .parse_numbers = false }) catch null;
        if (parsed) |v| {
            const code = objectValue(v, "error_code");
            const message = objectValue(v, "message");
            if (message) |m| {
                const text = oneLine(self.alloc, stringValue(m) orelse "Schema Registry error") catch "Schema Registry error";
                self.last_error = try std.fmt.allocPrint(self.alloc, "{s} (error_code {s})", .{
                    text,
                    if (code) |c| valueText(self.alloc, c) catch "?" else "?",
                });
                return error.RegistryFailure;
            }
        }
        self.last_error = try std.fmt.allocPrint(self.alloc, "Schema Registry returned HTTP {d}", .{response.status});
        return error.RegistryFailure;
    }

    pub fn subjects(self: *Registry) !std.json.Value {
        const body = try self.get("/subjects");
        return std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{ .allocate = .alloc_always, .parse_numbers = false });
    }

    pub fn versions(self: *Registry, subject: []const u8) !std.json.Value {
        const path = try std.fmt.allocPrint(self.alloc, "/subjects/{s}/versions", .{try pathEscape(self.alloc, subject)});
        const body = try self.get(path);
        return std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{ .allocate = .alloc_always, .parse_numbers = false });
    }

    pub fn schema(self: *Registry, subject: []const u8, version: []const u8) !std.json.Value {
        const path = try std.fmt.allocPrint(self.alloc, "/subjects/{s}/versions/{s}", .{ try pathEscape(self.alloc, subject), version });
        const body = try self.get(path);
        return std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{ .allocate = .alloc_always, .parse_numbers = false });
    }

    pub fn schemaGuid(self: *Registry, guid_text: []const u8) !std.json.Value {
        _ = try header.parseGuid(guid_text);
        const path = try std.fmt.allocPrint(self.alloc, "/schemas/guids/{s}", .{guid_text});
        const body = try self.get(path);
        return std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{ .allocate = .alloc_always, .parse_numbers = false });
    }

    pub fn guidLocation(self: *Registry, guid_text: []const u8, key: bool) !struct { subject: ?[]const u8, version: ?[]const u8 } {
        const ids_body = try self.get(try std.fmt.allocPrint(self.alloc, "/schemas/guids/{s}/ids", .{guid_text}));
        const ids = try std.json.parseFromSliceLeaky(std.json.Value, self.alloc, ids_body, .{ .allocate = .alloc_always, .parse_numbers = false });
        if (ids != .array or ids.array.items.len == 0) return .{ .subject = null, .version = null };
        var best_subject: ?[]const u8 = null;
        var best_version: ?[]const u8 = null;
        for (ids.array.items) |id_value| {
            const id = try guidSchemaId(self.alloc, id_value) orelse continue;
            const versions_body = try self.get(try std.fmt.allocPrint(self.alloc, "/schemas/ids/{s}/versions", .{id}));
            const locations = try std.json.parseFromSliceLeaky(std.json.Value, self.alloc, versions_body, .{ .allocate = .alloc_always, .parse_numbers = false });
            if (locations != .array) continue;
            for (locations.array.items) |entry| {
                const subject_value = objectValue(entry, "subject") orelse continue;
                const subject = stringValue(subject_value) orelse continue;
                const suffix = if (key) "-key" else "-value";
                if (!std.mem.endsWith(u8, subject, suffix) or std.mem.indexOfScalar(u8, subject, ':') != null) continue;
                const version = if (objectValue(entry, "version")) |v| try valueText(self.alloc, v) else null;
                const is_first_subject = best_subject == null or std.mem.lessThan(u8, subject, best_subject.?);
                const is_earlier_version = if (version) |candidate|
                    best_subject != null and std.mem.eql(u8, subject, best_subject.?) and best_version != null and
                        (std.fmt.parseInt(u64, candidate, 10) catch std.math.maxInt(u64)) <
                            (std.fmt.parseInt(u64, best_version.?, 10) catch std.math.maxInt(u64))
                else
                    false;
                if (is_first_subject or is_earlier_version) {
                    best_subject = subject;
                    best_version = version;
                }
            }
        }
        return .{ .subject = best_subject, .version = best_version };
    }

    pub fn compat(self: *Registry, subject: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(self.alloc, "/config/{s}", .{try pathEscape(self.alloc, subject)});
        const body = self.get(path) catch try self.get("/config");
        const value = try std.json.parseFromSliceLeaky(std.json.Value, self.alloc, body, .{ .allocate = .alloc_always, .parse_numbers = false });
        return stringValue(objectValue(value, "compatibilityLevel") orelse .null) orelse "BACKWARD";
    }
};

fn errorText(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (name, 0..) |char, index| {
        if (std.ascii.isUpper(char) and index > 0) try out.append(alloc, ' ');
        try out.append(alloc, std.ascii.toLower(char));
    }
    return out.toOwnedSlice(alloc);
}

test "connection error names are human readable" {
    const actual = try errorText(std.testing.allocator, "ConnectionRefused");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("connection refused", actual);
}

fn guidSchemaId(alloc: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    if (value != .object) return null;
    if (objectValue(value, "context")) |context| {
        if (stringValue(context)) |name| {
            if (!std.mem.eql(u8, name, ".")) return null;
        }
    }
    const id = objectValue(value, "id") orelse return null;
    return try valueText(alloc, id);
}

fn oneLine(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    var previous_space = false;
    for (text) |byte| {
        if (byte == '\n' or byte == '\r' or byte == '\t') {
            if (!previous_space) try out.writer.writeByte(' ');
            previous_space = true;
        } else {
            try out.writer.writeByte(byte);
            previous_space = byte == ' ';
        }
    }
    return out.toOwnedSlice();
}

test "registry error messages are single-line" {
    try std.testing.expectEqualStrings("first second third", try oneLine(std.testing.allocator, "first\r\nsecond\tthird"));
}

test "GUID schema ID responses select only default-context entries" {
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        std.testing.allocator,
        "[{\"context\":\".\",\"id\":3},{\"context\":\".other\",\"id\":4}]",
        .{ .allocate = .alloc_always, .parse_numbers = false },
    );
    try std.testing.expectEqualStrings("3", (try guidSchemaId(std.testing.allocator, parsed.array.items[0])).?);
    try std.testing.expect((try guidSchemaId(std.testing.allocator, parsed.array.items[1])) == null);
}

pub fn objectValue(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

pub fn stringValue(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

pub fn valueText(alloc: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .integer => |number| try std.fmt.allocPrint(alloc, "{d}", .{number}),
        .number_string => |number| number,
        else => error.InvalidResponse,
    };
}

pub fn pathEscape(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(alloc, c);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hex[c >> 4]);
            try out.append(alloc, hex[c & 15]);
        }
    }
    return out.toOwnedSlice(alloc);
}

test "encode REST path segment" {
    try std.testing.expectEqualStrings("a%2Fb", try pathEscape(std.testing.allocator, "a/b"));
}

test "registry scalar values preserve numeric identifiers" {
    try std.testing.expectEqualStrings("9007199254740993", try valueText(std.testing.allocator, .{ .number_string = "9007199254740993" }));
}
