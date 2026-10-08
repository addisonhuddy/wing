const std = @import("std");
const jv = @import("jv.zig");
const schema_compile = @import("schema/compile.zig");

pub fn read(
    io: std.Io,
    alloc: std.mem.Allocator,
    directory: []const u8,
    guid: []const u8,
) !?std.json.Value {
    const file_path = try cachePath(alloc, directory, guid);
    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, alloc, .limited(16 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch return error.InvalidCache;
    if (value != .object or value.object.get("schema") == null or value.object.get("guid") == null)
        return error.InvalidCache;
    return value;
}

pub fn write(
    io: std.Io,
    alloc: std.mem.Allocator,
    directory: []const u8,
    guid: []const u8,
    value: anytype,
) !void {
    const directory_permissions: std.Io.File.Permissions = @enumFromInt(0o700);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, directory, directory_permissions);
    const file_path = try cachePath(alloc, directory, guid);
    var output = std.Io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(value, .{}, &output.writer);
    try output.writer.writeByte('\n');

    const file_permissions: std.Io.File.Permissions = @enumFromInt(0o600);
    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .permissions = file_permissions });
    defer file.close(io);
    try file.writeStreamingAll(io, output.written());
    try file.setPermissions(io, file_permissions);
}

pub fn referenceResources(
    io: std.Io,
    alloc: std.mem.Allocator,
    directory: []const u8,
    root_schema: std.json.Value,
) ![]const schema_compile.ResourceSource {
    const dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var index: std.StringHashMapUnmanaged(std.json.Value) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".json")) continue;
        const source = dir.readFileAlloc(io, entry.path, alloc, .limited(16 * 1024 * 1024)) catch continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{
            .allocate = .alloc_always,
            .parse_numbers = false,
        }) catch continue;
        const subject = textField(value, "subject") orelse continue;
        const version = valueText(alloc, field(value, "version") orelse continue) catch continue;
        try index.put(alloc, try referenceKey(alloc, subject, version), value);
    }

    var resources: std.ArrayListUnmanaged(schema_compile.ResourceSource) = .empty;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    try appendCachedReferences(alloc, root_schema, &index, &resources, &names);
    return resources.toOwnedSlice(alloc);
}

fn appendCachedReferences(
    alloc: std.mem.Allocator,
    schema_value: std.json.Value,
    index: *const std.StringHashMapUnmanaged(std.json.Value),
    resources: *std.ArrayListUnmanaged(schema_compile.ResourceSource),
    names: *std.StringHashMapUnmanaged(void),
) !void {
    const references = field(schema_value, "references") orelse return;
    if (references != .array) return error.InvalidCache;
    for (references.array.items) |reference| {
        const name = textField(reference, "name") orelse return error.InvalidCache;
        const subject = textField(reference, "subject") orelse return error.InvalidCache;
        const version_value = field(reference, "version") orelse return error.InvalidCache;
        const version = try valueText(alloc, version_value);
        if (names.contains(name)) continue;
        try names.put(alloc, name, {});
        const key = try referenceKey(alloc, subject, version);
        const cached = index.get(key) orelse return error.ReferenceNotCached;
        const schema_text = textField(cached, "schema") orelse return error.InvalidCache;
        const document = try jv.parse(alloc, schema_text);
        try resources.append(alloc, .{ .uri = name, .document = document });
        try appendCachedReferences(alloc, cached, index, resources, names);
    }
}

fn referenceKey(alloc: std.mem.Allocator, subject: []const u8, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ subject, version });
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn textField(value: std.json.Value, name: []const u8) ?[]const u8 {
    return if (field(value, name)) |entry| if (entry == .string) entry.string else null else null;
}

fn valueText(alloc: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .integer => |number| try std.fmt.allocPrint(alloc, "{d}", .{number}),
        .number_string => |number| number,
        else => error.InvalidCache,
    };
}

fn cachePath(alloc: std.mem.Allocator, directory: []const u8, guid: []const u8) ![]const u8 {
    const filename = try std.fmt.allocPrint(alloc, "{s}.json", .{guid});
    return std.fs.path.join(alloc, &.{ directory, filename });
}

test "cached registry references resolve recursively by declared name" {
    const alloc = std.testing.allocator;
    const root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"references\":[{\"name\":\"common.json\",\"subject\":\"common-value\",\"version\":1}]}",
        .{ .allocate = .alloc_always, .parse_numbers = false },
    );
    const common = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"subject\":\"common-value\",\"version\":1,\"schema\":\"{\\\"$ref\\\":\\\"nested.json\\\"}\",\"references\":[{\"name\":\"nested.json\",\"subject\":\"nested-value\",\"version\":2}]}",
        .{ .allocate = .alloc_always, .parse_numbers = false },
    );
    const nested = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"subject\":\"nested-value\",\"version\":2,\"schema\":\"{\\\"type\\\":\\\"object\\\"}\"}",
        .{ .allocate = .alloc_always, .parse_numbers = false },
    );
    var index: std.StringHashMapUnmanaged(std.json.Value) = .empty;
    try index.put(alloc, try referenceKey(alloc, "common-value", "1"), common);
    try index.put(alloc, try referenceKey(alloc, "nested-value", "2"), nested);
    var resources: std.ArrayListUnmanaged(schema_compile.ResourceSource) = .empty;
    var names: std.StringHashMapUnmanaged(void) = .empty;

    try appendCachedReferences(alloc, root, &index, &resources, &names);

    try std.testing.expectEqual(@as(usize, 2), resources.items.len);
    try std.testing.expectEqualStrings("common.json", resources.items[0].uri);
    try std.testing.expectEqualStrings("nested.json", resources.items[1].uri);
    try std.testing.expectEqualStrings("{\"$ref\":\"nested.json\"}", resources.items[0].document.source);
}
