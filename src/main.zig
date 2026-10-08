const std = @import("std");
const cli = @import("cli.zig");
const app = @import("app.zig");
const cmd_ls = @import("cmd_ls.zig");
const cmd_get = @import("cmd_get.zig");
const cmd_rm = @import("cmd_rm.zig");
const cmd_registry = @import("cmd_registry.zig");
const cmd_update = @import("cmd_update.zig");
const cmd_read = @import("cmd_read.zig");
const cmd_write = @import("cmd_write.zig");
const cmd_push = @import("cmd_push.zig");

pub const panic = std.debug.simple_panic;

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(alloc);
    if (argv.len == 2 and (std.mem.eql(u8, argv[1], "-V") or std.mem.eql(u8, argv[1], "--version"))) {
        app.writeStdout(init.io, "wing " ++ cli.version ++ "\n", false, "");
        return;
    }
    const parsed = cli.parse(alloc, if (argv.len > 0) argv[1..] else &.{});
    const invocation = switch (parsed) {
        .help => {
            app.writeStdout(init.io, cli.help(""), false, "");
            return;
        },
        .version => {
            app.writeStdout(init.io, "wing " ++ cli.version ++ "\n", false, "");
            return;
        },
        .err => |message| app.fatal(message, app.errorsRequested(if (argv.len > 0) argv[1..] else &.{}), app.commandFromArgs(if (argv.len > 0) argv[1..] else &.{})),
        .ok => |value| value,
    };
    if (app.has(invocation.args, "--help") or app.has(invocation.args, "-h")) {
        app.writeStdout(init.io, cli.help(invocation.command), false, invocation.command);
        return;
    }
    const command = std.meta.stringToEnum(cli.Command, invocation.command) orelse {
        const message = if (cli.commandSuggestion(invocation.command)) |candidate|
            try std.fmt.allocPrint(alloc, "unknown command '{s}'; did you mean '{s}'?", .{ invocation.command, candidate })
        else
            try std.fmt.allocPrint(alloc, "unknown command '{s}'", .{invocation.command});
        app.fatal(message, invocation.global.errors_json, invocation.command);
    };
    const global = invocation.global;
    const args = invocation.args;
    switch (command) {
        .read => try cmd_read.run(init, global, args),
        .write => try cmd_write.run(init, global, args),
        .ls => try cmd_ls.run(init, global, args),
        .get => try cmd_get.run(init, global, args),
        .push => try cmd_push.run(init, global, args),
        .rm => try cmd_rm.run(init, global, args),
        .registry => try cmd_registry.run(init, global, args),
        .update => cmd_update.run(init, global, args, alloc),
    }
}
