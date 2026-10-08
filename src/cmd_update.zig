const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const registry_mod = @import("registry.zig");
const term = @import("term.zig");
const jv = @import("jv.zig");
const header = @import("header.zig");
const app = @import("app.zig");
const fatal = app.fatal;
const writeStdout = app.writeStdout;
const has = app.has;
const optionError = app.optionError;
const allocPrint = app.allocPrint;

const update_script =
    \\set -eu
    \\repo=addisonhuddy/wing
    \\current=v$1 bin_dir=$2 want=$3
    \\installer_url=${WING_INSTALLER_URL:-https://raw.githubusercontent.com/$repo/main/install.sh}
    \\if command -v curl >/dev/null 2>&1; then
    \\    fetch() { curl -fsSL "$1"; }
    \\    headers() { curl -fsSI "$1"; }
    \\elif command -v wget >/dev/null 2>&1; then
    \\    fetch() { wget -qO- "$1"; }
    \\    headers() { wget -S --spider --max-redirect=0 "$1" 2>&1; }
    \\else echo "wing: curl or wget is required" >&2; exit 1
    \\fi
    \\if [ -z "$want" ]; then
    \\    want=$(headers "https://github.com/$repo/releases/latest" | tr -d '\r' |
    \\        sed -n 's|^ *[Ll]ocation: .*/releases/tag/\([^ ]*\).*|\1|p' | head -n 1)
    \\    [ -n "$want" ] || {
    \\        echo "wing: could not look up the latest release; see https://github.com/$repo/releases" >&2
    \\        exit 1
    \\    }
    \\    if [ "$want" = "$current" ]; then
    \\        echo "wing: already up to date ($current)" >&2
    \\        exit 0
    \\    fi
    \\fi
    \\echo "wing: updating $current to $want" >&2
    \\installer=$(fetch "$installer_url") || {
    \\    echo "wing: could not download install.sh from github.com/$repo" >&2
    \\    exit 1
    \\}
    \\printf '%s\n' "$installer" | sh -s -- --bin-dir "$bin_dir" --version "$want"
;

pub fn run(init: std.process.Init, global: cli.Global, args: []const []const u8, alloc: std.mem.Allocator) noreturn {
    if (has(args, "-h") or has(args, "--help")) {
        writeStdout(init.io, cli.help("update"), global.errors_json, "update");
        std.process.exit(0);
    }
    if (args.len > 1) fatal(allocPrint(alloc, "unexpected argument '{s}'", .{args[1]}), global.errors_json, "update");
    var version: []const u8 = "";
    if (args.len == 1 and !std.mem.eql(u8, args[0], "latest")) {
        const arg = args[0];
        if (std.mem.startsWith(u8, arg, "-"))
            fatal(cli.optionError(alloc, arg), global.errors_json, "update");
        if (arg.len == 0) fatal("version must be a release tag", global.errors_json, "update");
        for (arg) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_')
            fatal(allocPrint(alloc, "'{s}' is not a release tag (want e.g. v0.1.0)", .{arg}), global.errors_json, "update");
        if (std.mem.startsWith(u8, arg, "v")) {
            version = arg;
        } else if (std.ascii.isDigit(arg[0])) {
            version = std.fmt.allocPrint(alloc, "v{s}", .{arg}) catch fatal("out of memory", global.errors_json, "update");
        } else {
            fatal(allocPrint(alloc, "'{s}' is not a release tag (want e.g. v0.1.0)", .{arg}), global.errors_json, "update");
        }
    }
    const bin_dir = std.process.executableDirPathAlloc(init.io, alloc) catch
        fatal("cannot find the directory that holds the wing binary", global.errors_json, "update");
    const argv = [_][]const u8{ "/bin/sh", "-c", update_script, "wing-update", cli.version, bin_dir, version };
    const err = std.process.replace(init.io, .{ .argv = &argv });
    fatal(allocPrint(alloc, "cannot run /bin/sh: {s}", .{@errorName(err)}), global.errors_json, "update");
}
