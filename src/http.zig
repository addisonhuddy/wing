const std = @import("std");

pub const Response = struct {
    status: u16,
    body: []const u8,
};

pub const Client = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    bases: []const []const u8,
    basic_auth: ?[]const u8,
    bearer: ?[]const u8,
    headers: []const []const u8,
    debug: bool,
    ca_bundle: ?[]const u8 = null,
    insecure: bool = false,

    pub fn request(self: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8) !Response {
        var last_err: anyerror = error.ConnectionFailed;
        for (self.bases) |base| {
            const url = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ std.mem.trimEnd(u8, base, "/"), path });
            var client: std.http.Client = .{ .allocator = self.alloc, .io = self.io };
            defer client.deinit();
            try client.initDefaultProxies(self.alloc, self.env);
            if (self.ca_bundle) |ca_path| if (!self.insecure) {
                const now = std.Io.Timestamp.now(self.io, .real);
                if (std.fs.path.isAbsolute(ca_path)) {
                    try client.ca_bundle.addCertsFromFilePathAbsolute(self.alloc, self.io, now, ca_path);
                } else {
                    try client.ca_bundle.addCertsFromFilePath(self.alloc, self.io, now, .cwd(), ca_path);
                }
                client.now = now;
            };
            if (noProxy(self.env, base)) {
                client.http_proxy = null;
                client.https_proxy = null;
            }
            var extra: std.ArrayListUnmanaged(std.http.Header) = .empty;
            try extra.append(self.alloc, .{ .name = "Accept", .value = "application/vnd.schemaregistry.v1+json" });
            try extra.append(self.alloc, .{ .name = "Confluent-Accept-Unknown-Properties", .value = "true" });
            if (payload != null) try extra.append(self.alloc, .{ .name = "Content-Type", .value = "application/vnd.schemaregistry.v1+json" });
            if (self.basic_auth) |auth| {
                const encoded_len = std.base64.standard.Encoder.calcSize(auth.len);
                const encoded = try self.alloc.alloc(u8, encoded_len);
                _ = std.base64.standard.Encoder.encode(encoded, auth);
                try extra.append(self.alloc, .{ .name = "Authorization", .value = try std.fmt.allocPrint(self.alloc, "Basic {s}", .{encoded}) });
            } else if (self.bearer) |token| {
                try extra.append(self.alloc, .{ .name = "Authorization", .value = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{token}) });
            }
            for (self.headers) |entry| {
                if (std.mem.indexOfScalar(u8, entry, '=')) |sep|
                    try extra.append(self.alloc, .{ .name = entry[0..sep], .value = entry[sep + 1 ..] });
            }
            if (self.debug) {
                std.debug.print("WING_DEBUG request {s} {s}\n", .{ @tagName(method), url });
                for (extra.items) |header| {
                    const value = if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) "[redacted]" else header.value;
                    std.debug.print("WING_DEBUG > {s}: {s}\n", .{ header.name, value });
                }
                if (payload) |body| std.debug.print("WING_DEBUG > {s}\n", .{body});
            }
            if (self.insecure and std.mem.startsWith(u8, base, "https://")) {
                const proxy = if (noProxy(self.env, base)) null else client.https_proxy;
                const result = insecureHttpsRequest(self, &client, url, method, extra.items, payload, proxy) catch |err| {
                    last_err = err;
                    continue;
                };
                if (self.debug) std.debug.print("WING_DEBUG response {d} {s}\n", .{ result.status, result.body });
                return result;
            }
            var body = std.Io.Writer.Allocating.init(self.alloc);
            const result = client.fetch(.{
                .location = .{ .url = url },
                .method = method,
                .payload = payload,
                .extra_headers = extra.items,
                .response_writer = &body.writer,
            }) catch |err| {
                last_err = err;
                continue;
            };
            if (self.debug) std.debug.print("WING_DEBUG response {d} {s}\n", .{ @intFromEnum(result.status), body.written() });
            return .{ .status = @intFromEnum(result.status), .body = try body.toOwnedSlice() };
        }
        return last_err;
    }
};

fn insecureHttpsRequest(
    client: *Client,
    http_client: *std.http.Client,
    url: []const u8,
    method: std.http.Method,
    headers: []const std.http.Header,
    payload: ?[]const u8,
    proxy: ?*std.http.Client.Proxy,
) !Response {
    const uri = try std.Uri.parse(url);
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidUrl;
    const host = (try uri.getHostAlloc(client.alloc)).bytes;
    const port = uri.port orelse 443;
    const stream = if (proxy) |p|
        try p.host.connect(client.io, p.port, .{ .mode = .stream })
    else blk: {
        const destination = try std.Io.net.HostName.init(host);
        break :blk try destination.connect(client.io, port, .{ .mode = .stream });
    };
    defer stream.close(client.io);

    var net_read_buffer: [std.crypto.tls.Client.min_buffer_len + 4096]u8 = undefined;
    var net_write_buffer: [std.crypto.tls.Client.min_buffer_len + 4096]u8 = undefined;
    var net_reader = stream.reader(client.io, &net_read_buffer);
    var net_writer = stream.writer(client.io, &net_write_buffer);

    const authority_host = uri.host.?.percent_encoded;
    const authority = try std.fmt.allocPrint(client.alloc, "{s}:{d}", .{ authority_host, port });
    var proxy_tls_read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var proxy_tls_write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var proxy_tls_entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    var proxy_tls: ?std.crypto.tls.Client = null;
    if (proxy) |p| {
        if (!p.supports_connect) return error.ProxyTunnelNotSupported;
        if (p.protocol == .tls) {
            const now = std.Io.Timestamp.now(client.io, .real);
            if (http_client.now == null) {
                try http_client.ca_bundle.rescan(client.alloc, client.io, now);
                http_client.now = now;
            }
            try client.io.randomSecure(&proxy_tls_entropy);
            proxy_tls = try std.crypto.tls.Client.init(&net_reader.interface, &net_writer.interface, .{
                .host = .{ .explicit = p.host.bytes },
                .ca = .{ .bundle = .{
                    .gpa = client.alloc,
                    .io = client.io,
                    .lock = &http_client.ca_bundle_lock,
                    .bundle = &http_client.ca_bundle,
                } },
                .read_buffer = &proxy_tls_read_buffer,
                .write_buffer = &proxy_tls_write_buffer,
                .entropy = &proxy_tls_entropy,
                .realtime_now = now,
            });
        }
        var connect_request = std.Io.Writer.Allocating.init(client.alloc);
        try connect_request.writer.print("CONNECT {s} HTTP/1.1\r\nHost: {s}\r\n", .{ authority, authority });
        if (p.authorization) |authorization| try connect_request.writer.print("Proxy-Authorization: {s}\r\n", .{authorization});
        try connect_request.writer.writeAll("Connection: keep-alive\r\n\r\n");
        const connect_writer = if (proxy_tls) |*outer| &outer.writer else &net_writer.interface;
        const connect_reader = if (proxy_tls) |*outer| &outer.reader else &net_reader.interface;
        try connect_writer.writeAll(connect_request.written());
        try connect_writer.flush();
        try net_writer.interface.flush();
        const status_line = std.mem.trimEnd(u8, try readHttpLine(connect_reader), "\r");
        if (try httpStatus(status_line) != 200) return error.ProxyTunnelFailed;
        while (true) {
            const line = std.mem.trimEnd(u8, try readHttpLine(connect_reader), "\r");
            if (line.len == 0) break;
        }
    }

    var bridge: TlsBridge = .{};
    var tls_input: *std.Io.Reader = &net_reader.interface;
    var tls_output: *std.Io.Writer = &net_writer.interface;
    if (proxy_tls) |*outer| {
        bridge.init(&outer.reader, &outer.writer, &net_writer.interface);
        tls_input = &bridge.reader;
        tls_output = &bridge.writer;
    }

    var tls_read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    try client.io.randomSecure(&entropy);
    var tls = try std.crypto.tls.Client.init(tls_input, tls_output, .{
        .host = .no_verification,
        .ca = .no_verification,
        .read_buffer = &tls_read_buffer,
        .write_buffer = &tls_write_buffer,
        .entropy = &entropy,
        .realtime_now = .now(client.io, .real),
        .allow_truncation_attacks = true,
    });

    var target = std.Io.Writer.Allocating.init(client.alloc);
    try uri.writeToStream(&target.writer, .{ .path = true, .query = true });
    var request = std.Io.Writer.Allocating.init(client.alloc);
    try request.writer.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n", .{ @tagName(method), target.written(), authority });
    if (payload) |body| try request.writer.print("Content-Length: {d}\r\n", .{body.len});
    for (headers) |header| try request.writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    try request.writer.writeAll("\r\n");
    if (payload) |body| try request.writer.writeAll(body);
    try tls.writer.writeAll(request.written());
    try tls.writer.flush();
    try net_writer.interface.flush();

    const status_line = std.mem.trimEnd(u8, try readHttpLine(&tls.reader), "\r");
    const status = try httpStatus(status_line);
    var content_length: ?usize = null;
    var chunked = false;
    while (true) {
        const line = std.mem.trimEnd(u8, try readHttpLine(&tls.reader), "\r");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = try std.fmt.parseInt(usize, value, 10);
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.mem.indexOf(u8, value, "chunked") != null) {
            chunked = true;
        }
    }

    const body = if (chunked)
        try readChunkedBody(client.alloc, &tls.reader)
    else if (content_length) |length| blk: {
        if (length > 16 * 1024 * 1024) return error.ResponseTooLarge;
        const bytes = try client.alloc.alloc(u8, length);
        errdefer client.alloc.free(bytes);
        try tls.reader.readSliceAll(bytes);
        break :blk bytes;
    } else try tls.reader.allocRemaining(client.alloc, .limited(16 * 1024 * 1024));
    return .{ .status = status, .body = body };
}

const TlsBridge = struct {
    source: *std.Io.Reader = undefined,
    sink: *std.Io.Writer = undefined,
    raw: *std.Io.Writer = undefined,
    reader_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    writer_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    reader: std.Io.Reader = std.Io.Reader.failing,
    writer: std.Io.Writer = std.Io.Writer.failing,

    const reader_vtable: std.Io.Reader.VTable = .{ .stream = stream };
    const writer_vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn init(self: *TlsBridge, source: *std.Io.Reader, sink: *std.Io.Writer, raw: *std.Io.Writer) void {
        self.source = source;
        self.sink = sink;
        self.raw = raw;
        self.reader = .{ .vtable = &reader_vtable, .buffer = &self.reader_buffer, .seek = 0, .end = 0 };
        self.writer = .{ .vtable = &writer_vtable, .buffer = &self.writer_buffer, .end = 0 };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *TlsBridge = @fieldParentPtr("reader", reader);
        return self.source.stream(writer, limit);
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *TlsBridge = @fieldParentPtr("writer", writer);
        const count = try self.sink.writeSplat(data, splat);
        try self.sink.flush();
        try self.raw.flush();
        return count;
    }
};

fn readHttpLine(reader: *std.Io.Reader) ![]u8 {
    return try reader.takeDelimiter('\n') orelse error.EndOfStream;
}

fn httpStatus(line: []const u8) !u16 {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    _ = words.next() orelse return error.InvalidHttpResponse;
    return std.fmt.parseInt(u16, words.next() orelse return error.InvalidHttpResponse, 10);
}

fn readChunkedBody(alloc: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var body = std.Io.Writer.Allocating.init(alloc);
    while (true) {
        const line = std.mem.trim(u8, try readHttpLine(reader), " \t\r");
        const size_text = std.mem.sliceTo(line, ';');
        const size = try std.fmt.parseInt(usize, size_text, 16);
        if (size == 0) {
            while (true) {
                const trailer = std.mem.trimEnd(u8, try readHttpLine(reader), "\r");
                if (trailer.len == 0) break;
            }
            break;
        }
        if (size > 16 * 1024 * 1024 - body.written().len) return error.ResponseTooLarge;
        const chunk = try alloc.alloc(u8, size);
        defer alloc.free(chunk);
        try reader.readSliceAll(chunk);
        try body.writer.writeAll(chunk);
        if (std.mem.trimEnd(u8, try readHttpLine(reader), "\r").len != 0) return error.InvalidHttpResponse;
    }
    return body.toOwnedSlice();
}

fn noProxy(env: *const std.process.Environ.Map, base: []const u8) bool {
    const value = env.get("NO_PROXY") orelse env.get("no_proxy") orelse return false;
    return noProxyList(value, base);
}

fn noProxyList(value: []const u8, base: []const u8) bool {
    const host_start = (std.mem.indexOf(u8, base, "://") orelse return false) + 3;
    const authority = base[host_start..];
    const authority_end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
    const host_port = authority[0..authority_end];
    const host: []const u8 = if (std.mem.startsWith(u8, host_port, "[")) blk: {
        const end = std.mem.indexOfScalar(u8, host_port, ']') orelse return false;
        break :blk host_port[1..end];
    } else host_port[0 .. std.mem.indexOfScalar(u8, host_port, ':') orelse host_port.len];
    const request_port = if (std.mem.startsWith(u8, host_port, "[")) blk: {
        const end = std.mem.indexOfScalar(u8, host_port, ']') orelse return false;
        if (end + 1 >= host_port.len or host_port[end + 1] != ':') break :blk null;
        break :blk std.fmt.parseInt(u16, host_port[end + 2 ..], 10) catch return false;
    } else if (std.mem.indexOfScalar(u8, host_port, ':')) |colon|
        std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return false
    else
        null;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const raw_item = std.mem.trim(u8, part, " \t");
        if (raw_item.len == 0) continue;
        if (std.mem.eql(u8, raw_item, "*")) return true;
        const item_end = std.mem.indexOfAny(u8, raw_item, "/?#") orelse raw_item.len;
        const item_authority = raw_item[0..item_end];
        const item_host: []const u8 = if (std.mem.startsWith(u8, item_authority, "[")) blk: {
            const end = std.mem.indexOfScalar(u8, item_authority, ']') orelse continue;
            break :blk item_authority[1..end];
        } else item_authority[0 .. std.mem.indexOfScalar(u8, item_authority, ':') orelse item_authority.len];
        const item_port = if (std.mem.startsWith(u8, item_authority, "[")) blk: {
            const end = std.mem.indexOfScalar(u8, item_authority, ']') orelse continue;
            if (end + 1 >= item_authority.len or item_authority[end + 1] != ':') break :blk null;
            break :blk std.fmt.parseInt(u16, item_authority[end + 2 ..], 10) catch continue;
        } else if (std.mem.indexOfScalar(u8, item_authority, ':')) |colon|
            std.fmt.parseInt(u16, item_authority[colon + 1 ..], 10) catch continue
        else
            null;
        if (item_port) |port| {
            if (request_port == null or request_port.? != port) continue;
        }
        const item = if (std.mem.startsWith(u8, item_host, ".")) item_host[1..] else item_host;
        if (item.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(host, item)) return true;
        if (std.ascii.endsWithIgnoreCase(host, item) and host.len > item.len and host[host.len - item.len - 1] == '.') return true;
    }
    return false;
}

test "NO_PROXY matches exact hosts and domain suffixes" {
    try std.testing.expect(noProxyList("localhost,.example.com", "http://localhost:8081"));
    try std.testing.expect(noProxyList("example.com", "https://api.example.com"));
    try std.testing.expect(noProxyList(".example.com", "https://example.com"));
    try std.testing.expect(noProxyList("localhost:8081", "http://localhost:8081"));
    try std.testing.expect(!noProxyList("example.com", "https://notexample.com"));
    try std.testing.expect(!noProxyList("localhost:8080", "http://localhost:8081"));
    try std.testing.expect(!noProxyList("localhost", "http://127.0.0.1:8081"));
}
