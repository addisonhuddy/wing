# Contributing

Use Zig 0.16.0. Keep changes focused and consistent with nearby code. Run
`zig fmt --check src build.zig`, `zig build`, `zig build test`, and
`scripts/cli-check.sh` before proposing a change. For schema-validator changes,
also run `scripts/jsts.sh`; for registry/record behavior, run the applicable
live smoke checks.

Do not commit credentials, registry URLs containing secrets, cache contents,
or generated test-suite checkouts. Keep record bytes and diagnostics on their
documented streams, and add regression coverage for behavioral changes.

The project uses Apache-2.0 licensing. Contributions should include the
appropriate copyright/license headers when adding files that require them.
