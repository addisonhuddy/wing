const std = @import("std");

pub const Decimal = struct {
    negative: bool,
    digits: []const u8,
    scale: i64,
    lexical_integer: bool,

    pub fn isInteger(self: Decimal, draft04: bool) bool {
        if (draft04) return self.lexical_integer;
        return std.mem.eql(u8, self.digits, "0") or self.scale <= 0;
    }
};

pub fn parse(alloc: std.mem.Allocator, text: []const u8) !Decimal {
    if (text.len == 0) return error.InvalidNumber;
    var index: usize = 0;
    var negative = false;
    if (text[index] == '-') {
        negative = true;
        index += 1;
        if (index == text.len) return error.InvalidNumber;
    }
    const integer_start = index;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
    if (index == integer_start) return error.InvalidNumber;
    if (index - integer_start > 1 and text[integer_start] == '0') return error.InvalidNumber;
    const integer_end = index;
    var fraction_start = index;
    var fraction_end = index;
    var has_fraction = false;
    if (index < text.len and text[index] == '.') {
        has_fraction = true;
        index += 1;
        fraction_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        fraction_end = index;
        if (fraction_end == fraction_start) return error.InvalidNumber;
    }
    var exponent: i64 = 0;
    var has_exponent = false;
    if (index < text.len and (text[index] == 'e' or text[index] == 'E')) {
        has_exponent = true;
        index += 1;
        if (index == text.len) return error.InvalidNumber;
        const exponent_start = index;
        if (text[index] == '+' or text[index] == '-') index += 1;
        const digits_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        if (digits_start == index) return error.InvalidNumber;
        exponent = std.fmt.parseInt(i64, text[exponent_start..index], 10) catch return error.ExponentTooLarge;
    }
    if (index != text.len) return error.InvalidNumber;

    if (!has_fraction and !has_exponent) return .{
        .negative = negative,
        .digits = text[integer_start..integer_end],
        .scale = 0,
        .lexical_integer = true,
    };

    const integer_length = integer_end - integer_start;
    const fraction_length = fraction_end - fraction_start;
    const digits = try alloc.alloc(u8, integer_length + fraction_length);
    @memcpy(digits[0..integer_length], text[integer_start..integer_end]);
    if (has_fraction)
        @memcpy(digits[integer_length..], text[fraction_start..fraction_end]);
    var first: usize = 0;
    while (first < digits.len and digits[first] == '0') : (first += 1) {}
    if (first == digits.len) return .{
        .negative = false,
        .digits = "0",
        .scale = 0,
        .lexical_integer = !has_fraction and !has_exponent,
    };
    var last = digits.len;
    var scale = std.math.sub(i64, @intCast(fraction_end - fraction_start), exponent) catch return error.ExponentTooLarge;
    while (last > first + 1 and digits[last - 1] == '0') {
        last -= 1;
        scale = std.math.sub(i64, scale, 1) catch return error.ExponentTooLarge;
    }
    return .{
        .negative = negative,
        .digits = digits[first..last],
        .scale = scale,
        .lexical_integer = !has_fraction and !has_exponent,
    };
}

pub fn compare(a: Decimal, b: Decimal) std.math.Order {
    const a_zero = std.mem.eql(u8, a.digits, "0");
    const b_zero = std.mem.eql(u8, b.digits, "0");
    if (a_zero and b_zero) return .eq;
    const a_negative = a.negative and !a_zero;
    const b_negative = b.negative and !b_zero;
    if (a_negative != b_negative) return if (a_negative) .lt else .gt;
    if (a_zero) return .lt;
    if (b_zero) return .gt;
    const magnitude = compareMagnitude(a, b);
    if (!a_negative) return magnitude;
    return switch (magnitude) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

pub fn equal(a: Decimal, b: Decimal) bool {
    return compare(a, b) == .eq;
}

fn compareMagnitude(a: Decimal, b: Decimal) std.math.Order {
    const a_order = @as(i128, @intCast(a.digits.len)) - a.scale;
    const b_order = @as(i128, @intCast(b.digits.len)) - b.scale;
    if (a_order != b_order) return if (a_order < b_order) .lt else .gt;
    const count = @max(a.digits.len, b.digits.len);
    for (0..count) |i| {
        const ac = if (i < a.digits.len) a.digits[i] else '0';
        const bc = if (i < b.digits.len) b.digits[i] else '0';
        if (ac != bc) return if (ac < bc) .lt else .gt;
    }
    return .eq;
}

pub fn multipleOf(alloc: std.mem.Allocator, value: Decimal, divisor: Decimal) !bool {
    if (std.mem.eql(u8, divisor.digits, "0")) return false;
    if (std.mem.eql(u8, value.digits, "0")) return true;
    if (std.mem.eql(u8, divisor.digits, "1")) {
        var value_scale = value.scale;
        var last = value.digits.len;
        while (last > 0 and value.digits[last - 1] == '0') : (last -= 1)
            value_scale = std.math.sub(i64, value_scale, 1) catch return error.ExponentTooLarge;
        return value_scale <= divisor.scale;
    }
    const shift = std.math.sub(i64, divisor.scale, value.scale) catch return error.ExponentTooLarge;
    if (shift > 100_000 or shift < -100_000) return error.ExpansionTooLarge;
    var numerator = std.ArrayListUnmanaged(u8).empty;
    var denominator = std.ArrayListUnmanaged(u8).empty;
    try numerator.appendSlice(alloc, value.digits);
    try denominator.appendSlice(alloc, divisor.digits);
    if (shift > 0) {
        try numerator.appendNTimes(alloc, '0', @intCast(shift));
    } else if (shift < 0) {
        const magnitude = std.math.sub(i64, 0, shift) catch return error.ExponentTooLarge;
        try denominator.appendNTimes(alloc, '0', @intCast(magnitude));
    }
    return isZero(try remainder(alloc, numerator.items, denominator.items));
}

fn isZero(digits: []const u8) bool {
    for (digits) |digit| if (digit != '0') return false;
    return true;
}

fn trimLeading(digits: []u8) []u8 {
    var first: usize = 0;
    while (first + 1 < digits.len and digits[first] == '0') : (first += 1) {}
    return digits[first..];
}

fn compareInteger(a: []const u8, b: []const u8) std.math.Order {
    const left = trimLeading(@constCast(a));
    const right = trimLeading(@constCast(b));
    if (left.len != right.len) return if (left.len < right.len) .lt else .gt;
    return switch (std.mem.order(u8, left, right)) {
        .lt => .lt,
        .gt => .gt,
        .eq => .eq,
    };
}

fn subtractInPlace(left: []u8, right: []const u8) void {
    var borrow: i16 = 0;
    var li = left.len;
    var ri = right.len;
    while (li > 0) {
        li -= 1;
        var digit: i16 = @as(i16, left[li] - '0') - borrow;
        if (ri > 0) {
            ri -= 1;
            digit -= @as(i16, right[ri] - '0');
        }
        if (digit < 0) {
            digit += 10;
            borrow = 1;
        } else {
            borrow = 0;
        }
        left[li] = @intCast(digit + '0');
    }
}

fn remainder(alloc: std.mem.Allocator, numerator: []const u8, denominator: []const u8) ![]u8 {
    var rem = std.ArrayListUnmanaged(u8).empty;
    for (numerator) |digit| {
        try rem.append(alloc, digit);
        while (rem.items.len > 1 and rem.items[0] == '0') {
            std.mem.copyForwards(u8, rem.items[0 .. rem.items.len - 1], rem.items[1..]);
            rem.items.len -= 1;
        }
        while (compareInteger(rem.items, denominator) != .lt) subtractInPlace(rem.items, denominator);
    }
    return rem.toOwnedSlice(alloc);
}

test "decimal comparison and numeric equality are exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const a = try parse(alloc, "1");
    const b = try parse(alloc, "1.0");
    const huge = try parse(alloc, "900719925474099312345");
    const larger = try parse(alloc, "900719925474099312346");
    const zero = try parse(alloc, "0");
    const positive_fraction = try parse(alloc, "0.1");
    const negative_fraction = try parse(alloc, "-0.1");
    try std.testing.expect(equal(a, b));
    try std.testing.expectEqual(std.math.Order.gt, compare(positive_fraction, zero));
    try std.testing.expectEqual(std.math.Order.lt, compare(zero, positive_fraction));
    try std.testing.expectEqual(std.math.Order.lt, compare(negative_fraction, zero));
    try std.testing.expect(compare(huge, larger) == .lt);
    try std.testing.expectEqual(std.math.Order.gt, compare(try parse(alloc, "-1e308"), try parse(alloc, "-1e307")));
}

test "draft integer rules and decimal multipleOf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const one_point_zero = try parse(alloc, "1.0");
    try std.testing.expect(!one_point_zero.isInteger(true));
    try std.testing.expect(!try parse(alloc, "1e0").isInteger(true));
    try std.testing.expect(one_point_zero.isInteger(false));
    try std.testing.expect(try multipleOf(alloc, try parse(alloc, "0.015"), try parse(alloc, "0.0075")));
    try std.testing.expect(try multipleOf(alloc, try parse(alloc, "23.64"), try parse(alloc, "0.01")));
    try std.testing.expect(!(try multipleOf(alloc, try parse(alloc, "1.234"), try parse(alloc, "0.01"))));
    try std.testing.expect(try multipleOf(alloc, try parse(alloc, "100"), try parse(alloc, "10")));
    try std.testing.expect(!(try multipleOf(alloc, try parse(alloc, "0.01"), try parse(alloc, "0.0075"))));
    try std.testing.expect(try multipleOf(alloc, try parse(alloc, "1e-8"), try parse(alloc, "1e-8")));
    try std.testing.expect(try multipleOf(alloc, try parse(alloc, "1e308"), try parse(alloc, "1e-8")));
    try std.testing.expect(try multipleOf(alloc, try parse(alloc, "9007199254740993"), try parse(alloc, "3")));
    try std.testing.expect(!(try multipleOf(alloc, try parse(alloc, "7"), try parse(alloc, "2"))));
    try std.testing.expect(!(try multipleOf(alloc, try parse(alloc, "35"), try parse(alloc, "1.5"))));
    try std.testing.expect(!(try multipleOf(alloc, try parse(alloc, "0.00751"), try parse(alloc, "0.0001"))));
    try std.testing.expectError(error.InvalidNumber, parse(alloc, "01"));
}
