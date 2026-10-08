const std = @import("std");

/// Optimal string alignment distance; 255 for inputs longer than 64 bytes.
pub fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return 255;
    var d: [66][66]u16 = undefined;
    for (0..a.len + 1) |i| d[i][0] = @intCast(i);
    for (0..b.len + 1) |j| d[0][j] = @intCast(j);
    for (1..a.len + 1) |i| for (1..b.len + 1) |j| {
        const cost: u16 = if (a[i - 1] == b[j - 1]) 0 else 1;
        var best = @min(@min(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + cost);
        if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1])
            best = @min(best, d[i - 2][j - 2] + 1);
        d[i][j] = best;
    };
    return d[a.len][b.len];
}
