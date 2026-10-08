//! wing-testkit: conformance and differential harness commands, built only
//! by `zig build testkit` so they stay out of the release binary.
const std = @import("std");
const cmd_validate = @import("cmd_validate.zig");

pub const panic = std.debug.simple_panic;

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const command = if (argv.len > 1) argv[1] else "";
    const args = if (argv.len > 2) argv[2..] else &.{};
    if (std.mem.eql(u8, command, "validate")) try cmd_validate.validateCommand(init, args);
    if (std.mem.eql(u8, command, "jsts")) try cmd_validate.jstsCommand(init, args);
    if (std.mem.eql(u8, command, "fitprops")) try cmd_validate.fitPropertiesCommand(init, args);
    std.debug.print("usage: wing-testkit validate|jsts|fitprops ARGS...\n", .{});
    std.process.exit(2);
}

test {
    _ = cmd_validate;
}
