const cli = @import("cli.zig");
const app = @import("app.zig");

pub fn run(global: cli.Global) noreturn {
    app.fatal("not implemented yet", global.errors_json, "push");
}
