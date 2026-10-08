const std = @import("std");

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const cyan = "\x1b[36m";
pub const red = "\x1b[31m";

pub fn colorEnabled(io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("WING_COLOR")) |v| {
        if (std.mem.eql(u8, v, "always")) return true;
        if (std.mem.eql(u8, v, "never")) return false;
    }
    if (env.get("NO_COLOR")) |v| if (v.len > 0) return false;
    return std.Io.File.stderr().isTty(io) catch false;
}

pub fn confirm(io: std.Io, prompt: []const u8) ?bool {
    if (!(std.Io.File.stderr().isTty(io) catch false)) return null;
    const tty = std.Io.Dir.cwd().openFile(io, "/dev/tty", .{}) catch return null;
    defer tty.close(io);
    std.debug.print("wing: {s}", .{prompt});
    var buf: [128]u8 = undefined;
    var reader = tty.reader(io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch return false;
    const answer = std.mem.trim(u8, line orelse return false, " \t\r");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}
