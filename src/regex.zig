const std = @import("std");
const unicode = @import("schema/unicode_categories.zig");

const unset = std.math.maxInt(usize);

const Op = enum { character, any, character_class, begin, end, boundary, split, match };
const Instruction = struct {
    op: Op,
    out: usize = unset,
    out2: usize = unset,
    character: u21 = 0,
    class_index: usize = 0,
    negate: bool = false,
};
const Range = struct { first: u21, last: u21 };
const TermKind = enum { digit, word, space, category };
const Term = struct { kind: TermKind, negate: bool = false, categories: u32 = 0 };
const CharacterClass = struct {
    ranges: []const Range,
    terms: []const Term,
    negate: bool,
};
const Pair = struct { left: *Ast, right: *Ast };
const Repeat = struct { child: *Ast, min: usize, max: ?usize };
const Ast = union(enum) {
    empty,
    character: u21,
    any,
    class: usize,
    begin,
    end,
    boundary: bool,
    concat: Pair,
    alternate: Pair,
    repeat: Repeat,
};
const Atom = union(enum) { character: u21, term: Term };

const Parser = struct {
    alloc: std.mem.Allocator,
    pattern: []const u8,
    position: usize = 0,
    classes: std.ArrayListUnmanaged(CharacterClass) = .empty,

    fn node(self: *Parser, value: Ast) !*Ast {
        const result = try self.alloc.create(Ast);
        result.* = value;
        return result;
    }

    fn parse(self: *Parser) !*Ast {
        const result = try self.expression();
        if (self.position != self.pattern.len) return error.InvalidRegex;
        return result;
    }

    fn expression(self: *Parser) anyerror!*Ast {
        var left = try self.concatenation();
        while (self.peek('|')) {
            self.position += 1;
            const right = try self.concatenation();
            left = try self.node(.{ .alternate = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn concatenation(self: *Parser) anyerror!*Ast {
        var first: ?*Ast = null;
        while (self.position < self.pattern.len and !self.peek(')') and !self.peek('|')) {
            const item = try self.repetition();
            first = if (first) |left|
                try self.node(.{ .concat = .{ .left = left, .right = item } })
            else
                item;
        }
        return first orelse try self.node(.empty);
    }

    fn repetition(self: *Parser) anyerror!*Ast {
        const atom_node = try self.atom();
        if (self.position >= self.pattern.len) return atom_node;
        var minimum: usize = 0;
        var maximum: ?usize = null;
        switch (self.pattern[self.position]) {
            '*' => self.position += 1,
            '+' => {
                minimum = 1;
                self.position += 1;
            },
            '?' => {
                maximum = 1;
                self.position += 1;
            },
            '{' => {
                const saved = self.position;
                self.position += 1;
                minimum = self.decimalCount() orelse {
                    self.position = saved;
                    return atom_node;
                };
                if (self.peek('}')) {
                    maximum = minimum;
                    self.position += 1;
                } else if (self.peek(',')) {
                    self.position += 1;
                    maximum = self.decimalCount();
                    if (!self.peek('}')) return error.InvalidQuantifier;
                    self.position += 1;
                } else return error.InvalidQuantifier;
                if (maximum) |max| if (max < minimum) return error.InvalidQuantifier;
            },
            else => return atom_node,
        }
        if (self.peek('?')) self.position += 1;
        if (self.position < self.pattern.len and
            (self.peek('*') or self.peek('+') or self.peek('?') or self.peek('{')))
            return error.InvalidQuantifier;
        return self.node(.{ .repeat = .{ .child = atom_node, .min = minimum, .max = maximum } });
    }

    fn decimalCount(self: *Parser) ?usize {
        const start = self.position;
        var value: usize = 0;
        while (self.position < self.pattern.len and std.ascii.isDigit(self.pattern[self.position])) : (self.position += 1) {
            value = std.math.mul(usize, value, 10) catch return null;
            value = std.math.add(usize, value, self.pattern[self.position] - '0') catch return null;
            if (value > 1024) return null;
        }
        return if (self.position == start) null else value;
    }

    fn atom(self: *Parser) anyerror!*Ast {
        if (self.position >= self.pattern.len) return error.InvalidRegex;
        const start = self.position;
        const c = self.pattern[start];
        self.position += 1;
        return switch (c) {
            '(' => self.group(),
            ')' => error.InvalidRegex,
            '[' => self.characterClass(false),
            '.' => self.node(.any),
            '^' => self.node(.begin),
            '$' => self.node(.end),
            '\\' => self.escape(false),
            '*', '+', '?', '{' => error.InvalidQuantifier,
            else => blk: {
                const length = std.unicode.utf8ByteSequenceLength(c) catch return error.InvalidRegex;
                const end = start + length;
                if (end > self.pattern.len) return error.InvalidRegex;
                self.position = end;
                const character = std.unicode.utf8Decode(self.pattern[start..end]) catch return error.InvalidRegex;
                break :blk self.node(.{ .character = character });
            },
        };
    }

    fn group(self: *Parser) anyerror!*Ast {
        if (self.peek('?')) {
            self.position += 1;
            if (!self.peek(':')) return error.UnsupportedRegex;
            self.position += 1;
        }
        const child = try self.expression();
        if (!self.peek(')')) return error.UnclosedGroup;
        self.position += 1;
        return child;
    }

    fn escape(self: *Parser, in_class: bool) anyerror!*Ast {
        if (!in_class and self.position < self.pattern.len and
            (self.pattern[self.position] == 'b' or self.pattern[self.position] == 'B'))
        {
            const negate = self.pattern[self.position] == 'B';
            self.position += 1;
            return self.node(.{ .boundary = negate });
        }
        const atom_value = try self.readEscape(in_class);
        return switch (atom_value) {
            .character => |character| self.node(.{ .character = character }),
            .term => |term| blk: {
                const class = try self.alloc.create(CharacterClass);
                class.* = .{ .ranges = &.{}, .terms = try self.alloc.dupe(Term, &.{term}), .negate = false };
                const class_index = self.classes.items.len;
                try self.classes.append(self.alloc, class.*);
                break :blk self.node(.{ .class = class_index });
            },
        };
    }

    fn readEscape(self: *Parser, in_class: bool) anyerror!Atom {
        if (self.position >= self.pattern.len) return error.InvalidRegex;
        const c = self.pattern[self.position];
        self.position += 1;
        return switch (c) {
            '1'...'9' => error.UnsupportedRegex,
            'k' => if (in_class) .{ .character = 'k' } else error.UnsupportedRegex,
            'd' => .{ .term = .{ .kind = .digit } },
            'D' => .{ .term = .{ .kind = .digit, .negate = true } },
            'w' => .{ .term = .{ .kind = .word } },
            'W' => .{ .term = .{ .kind = .word, .negate = true } },
            's' => .{ .term = .{ .kind = .space } },
            'S' => .{ .term = .{ .kind = .space, .negate = true } },
            'b' => if (in_class) .{ .character = 8 } else error.InvalidRegex,
            'B' => error.InvalidRegex,
            'p', 'P' => self.unicodeProperty(c == 'P'),
            'n' => .{ .character = '\n' },
            'r' => .{ .character = '\r' },
            't' => .{ .character = '\t' },
            'f' => .{ .character = 12 },
            'v' => .{ .character = 11 },
            '0' => .{ .character = 0 },
            'x' => .{ .character = try self.hexEscape(2) },
            'u' => .{ .character = try self.hexEscape(4) },
            'c' => .{ .character = try self.controlEscape() },
            else => .{ .character = c },
        };
    }

    fn controlEscape(self: *Parser) anyerror!u21 {
        if (self.position >= self.pattern.len or !std.ascii.isAlphabetic(self.pattern[self.position]))
            return error.InvalidRegex;
        const control = self.pattern[self.position] & 0x1f;
        self.position += 1;
        return control;
    }

    fn unicodeProperty(self: *Parser, negate: bool) anyerror!Atom {
        if (!self.peek('{')) return error.InvalidUnicodeProperty;
        self.position += 1;
        const start = self.position;
        while (self.position < self.pattern.len and !self.peek('}')) : (self.position += 1) {}
        if (!self.peek('}')) return error.InvalidUnicodeProperty;
        const mask = propertyMask(self.pattern[start..self.position]) orelse return error.InvalidUnicodeProperty;
        self.position += 1;
        return .{ .term = .{ .kind = .category, .negate = negate, .categories = mask } };
    }

    fn hexEscape(self: *Parser, count: usize) anyerror!u21 {
        if (self.position + count > self.pattern.len) return error.InvalidRegex;
        var value: u21 = 0;
        for (self.pattern[self.position .. self.position + count]) |c| {
            const digit = std.fmt.charToDigit(c, 16) catch return error.InvalidRegex;
            value = value * 16 + digit;
        }
        self.position += count;
        return value;
    }

    fn characterClass(self: *Parser, _: bool) anyerror!*Ast {
        const negate = if (self.peek('^')) blk: {
            self.position += 1;
            break :blk true;
        } else false;
        var ranges: std.ArrayListUnmanaged(Range) = .empty;
        var terms: std.ArrayListUnmanaged(Term) = .empty;
        var first_item = true;
        var closed = false;
        while (self.position < self.pattern.len) {
            if (self.peek(']') and !first_item) {
                self.position += 1;
                closed = true;
                break;
            }
            first_item = false;
            const first = try self.classAtom();
            if (first == .character and self.peek('-') and
                self.position + 1 < self.pattern.len and self.pattern[self.position + 1] != ']')
            {
                self.position += 1;
                const last = try self.classAtom();
                if (last != .character or last.character < first.character) return error.InvalidCharacterRange;
                try ranges.append(self.alloc, .{ .first = first.character, .last = last.character });
            } else switch (first) {
                .character => |character| try ranges.append(self.alloc, .{ .first = character, .last = character }),
                .term => |term| try terms.append(self.alloc, term),
            }
        }
        if (!closed) return error.UnclosedCharacterClass;
        const class_index = self.classes.items.len;
        try self.classes.append(self.alloc, .{
            .ranges = try ranges.toOwnedSlice(self.alloc),
            .terms = try terms.toOwnedSlice(self.alloc),
            .negate = negate,
        });
        return self.node(.{ .class = class_index });
    }

    fn classAtom(self: *Parser) anyerror!Atom {
        if (self.position >= self.pattern.len) return error.UnclosedCharacterClass;
        const start = self.position;
        const c = self.pattern[self.position];
        self.position += 1;
        if (c == '\\') return self.readEscape(true);
        const length = std.unicode.utf8ByteSequenceLength(c) catch return error.InvalidRegex;
        const end = start + length;
        if (end > self.pattern.len) return error.InvalidRegex;
        self.position = end;
        return .{ .character = std.unicode.utf8Decode(self.pattern[start..end]) catch return error.InvalidRegex };
    }

    fn peek(self: *const Parser, c: u8) bool {
        return self.position < self.pattern.len and self.pattern[self.position] == c;
    }
};

fn propertyMask(name: []const u8) ?u32 {
    const groups = [_][]const u8{
        "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl",
        "No", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "Sm", "Sc",
        "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co", "Cn",
    };
    const singles = [_][]const u8{
        "Uppercase_Letter",    "Lowercase_Letter",      "Titlecase_Letter",  "Modifier_Letter",  "Other_Letter",
        "Nonspacing_Mark",     "Spacing_Mark",          "Enclosing_Mark",    "Decimal_Number",   "Letter_Number",
        "Other_Number",        "Connector_Punctuation", "Dash_Punctuation",  "Open_Punctuation", "Close_Punctuation",
        "Initial_Punctuation", "Final_Punctuation",     "Other_Punctuation", "Math_Symbol",      "Currency_Symbol",
        "Modifier_Symbol",     "Other_Symbol",          "Space_Separator",   "Line_Separator",   "Paragraph_Separator",
        "Control",             "Format",                "Surrogate",         "Private_Use",      "Unassigned",
    };
    if (std.mem.startsWith(u8, name, "General_Category=")) return propertyMask(name["General_Category=".len..]);
    if (std.mem.startsWith(u8, name, "gc=")) return propertyMask(name["gc=".len..]);
    if (std.mem.eql(u8, name, "Digit") or std.mem.eql(u8, name, "digit")) return @as(u32, 1) << 8;
    for (groups, 0..) |short, index| {
        if (std.mem.eql(u8, name, short) or std.mem.eql(u8, name, singles[index]))
            return @as(u32, 1) << @intCast(index);
    }
    const group_names = [_][]const u8{ "L", "Letter", "M", "Mark", "N", "Number", "P", "Punctuation", "S", "Symbol", "Z", "Separator", "C", "Other" };
    const bounds = [_]struct { first: u5, last: u5 }{
        .{ .first = 0, .last = 4 },   .{ .first = 0, .last = 4 },
        .{ .first = 5, .last = 7 },   .{ .first = 5, .last = 7 },
        .{ .first = 8, .last = 10 },  .{ .first = 8, .last = 10 },
        .{ .first = 11, .last = 17 }, .{ .first = 11, .last = 17 },
        .{ .first = 18, .last = 21 }, .{ .first = 18, .last = 21 },
        .{ .first = 22, .last = 24 }, .{ .first = 22, .last = 24 },
        .{ .first = 25, .last = 29 }, .{ .first = 25, .last = 29 },
    };
    for (group_names, bounds) |group, bound| {
        if (std.mem.eql(u8, name, group)) {
            var mask: u32 = 0;
            for (bound.first..@as(u5, bound.last + 1)) |category| mask |= @as(u32, 1) << @intCast(category);
            return mask;
        }
    }
    return null;
}

const Compiler = struct {
    alloc: std.mem.Allocator,
    instructions: std.ArrayListUnmanaged(Instruction) = .empty,

    fn emit(self: *Compiler, instruction: Instruction) !usize {
        const index = self.instructions.items.len;
        try self.instructions.append(self.alloc, instruction);
        return index;
    }

    fn compile(self: *Compiler, node: *Ast, next: usize) anyerror!usize {
        return switch (node.*) {
            .empty => next,
            .character => |character| self.emit(.{ .op = .character, .character = character, .out = next }),
            .any => self.emit(.{ .op = .any, .out = next }),
            .class => |index| self.emit(.{ .op = .character_class, .class_index = index, .out = next }),
            .begin => self.emit(.{ .op = .begin, .out = next }),
            .end => self.emit(.{ .op = .end, .out = next }),
            .boundary => |negate| self.emit(.{ .op = .boundary, .negate = negate, .out = next }),
            .concat => |pair| blk: {
                const right = try self.compile(pair.right, next);
                break :blk try self.compile(pair.left, right);
            },
            .alternate => |pair| blk: {
                const left = try self.compile(pair.left, next);
                const right = try self.compile(pair.right, next);
                break :blk try self.emit(.{ .op = .split, .out = left, .out2 = right });
            },
            .repeat => |repeat| self.compileRepeat(repeat, next),
        };
    }

    fn compileRepeat(self: *Compiler, repeat: Repeat, next: usize) anyerror!usize {
        var start = next;
        if (repeat.max) |maximum| {
            var optional = maximum - repeat.min;
            while (optional > 0) : (optional -= 1) {
                const child = try self.compile(repeat.child, start);
                start = try self.emit(.{ .op = .split, .out = child, .out2 = start });
            }
        } else {
            const split = try self.emit(.{ .op = .split, .out2 = start });
            const child = try self.compile(repeat.child, split);
            self.instructions.items[split].out = child;
            start = split;
        }
        var mandatory = repeat.min;
        while (mandatory > 0) : (mandatory -= 1) start = try self.compile(repeat.child, start);
        return start;
    }
};

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    pattern: []const u8,
    instructions: []const Instruction,
    classes: []const CharacterClass,
    start: usize,

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    pub fn matches(self: *const Regex, alloc: std.mem.Allocator, text: []const u8) !bool {
        return self.matchesWithBudget(alloc, text, null);
    }

    pub fn matchesWithBudget(self: *const Regex, alloc: std.mem.Allocator, text: []const u8, budget: ?*usize) !bool {
        const points = try decode(alloc, text);
        defer alloc.free(points);
        var current: std.ArrayListUnmanaged(usize) = .empty;
        defer current.deinit(alloc);
        var next: std.ArrayListUnmanaged(usize) = .empty;
        defer next.deinit(alloc);
        var current_seen = try alloc.alloc(bool, self.instructions.len);
        defer alloc.free(current_seen);
        var next_seen = try alloc.alloc(bool, self.instructions.len);
        defer alloc.free(next_seen);
        @memset(current_seen, false);
        @memset(next_seen, false);

        for (0..points.len + 1) |position| {
            try self.addState(alloc, &current, current_seen, self.start, position, points, budget);
            for (current.items) |index| if (self.instructions[index].op == .match) return true;
            if (position == points.len) break;
            next.clearRetainingCapacity();
            @memset(next_seen, false);
            for (current.items) |index| {
                if (budget) |steps| {
                    steps.* += 1;
                    if (steps.* > 20_000_000) return error.StepLimit;
                }
                const instruction = self.instructions[index];
                const accepted = switch (instruction.op) {
                    .character => points[position] == instruction.character,
                    .any => !isLineTerminator(points[position]),
                    .character_class => classMatches(self.classes[instruction.class_index], points[position]),
                    else => false,
                };
                if (accepted) try self.addState(alloc, &next, next_seen, instruction.out, position + 1, points, budget);
            }
            std.mem.swap(std.ArrayListUnmanaged(usize), &current, &next);
            std.mem.swap([]bool, &current_seen, &next_seen);
        }
        return false;
    }

    fn addState(
        self: *const Regex,
        alloc: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(usize),
        seen: []bool,
        index: usize,
        position: usize,
        points: []const u21,
        budget: ?*usize,
    ) anyerror!void {
        if (index == unset or index >= self.instructions.len or seen[index]) return;
        seen[index] = true;
        if (budget) |steps| {
            steps.* += 1;
            if (steps.* > 20_000_000) return error.StepLimit;
        }
        const instruction = self.instructions[index];
        switch (instruction.op) {
            .split => {
                try self.addState(alloc, list, seen, instruction.out, position, points, budget);
                try self.addState(alloc, list, seen, instruction.out2, position, points, budget);
            },
            .begin => if (position == 0) try self.addState(alloc, list, seen, instruction.out, position, points, budget),
            .end => if (position == points.len) try self.addState(alloc, list, seen, instruction.out, position, points, budget),
            .boundary => {
                const previous = position > 0 and isWord(points[position - 1]);
                const following = position < points.len and isWord(points[position]);
                if ((previous != following) != instruction.negate)
                    try self.addState(alloc, list, seen, instruction.out, position, points, budget);
            },
            else => try list.append(alloc, index),
        }
    }
};

fn decode(alloc: std.mem.Allocator, text: []const u8) ![]u21 {
    var points: std.ArrayListUnmanaged(u21) = .empty;
    var position: usize = 0;
    while (position < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[position]) catch return error.InvalidUtf8;
        const end = position + length;
        if (end > text.len) return error.InvalidUtf8;
        try points.append(alloc, std.unicode.utf8Decode(text[position..end]) catch return error.InvalidUtf8);
        position = end;
    }
    return points.toOwnedSlice(alloc);
}

fn isLineTerminator(point: u21) bool {
    return point == '\n' or point == '\r' or point == 0x2028 or point == 0x2029;
}

fn isWord(point: u21) bool {
    return point == '_' or (point < 128 and std.ascii.isAlphanumeric(@intCast(point)));
}

fn termMatches(term: Term, point: u21) bool {
    const matched = switch (term.kind) {
        .digit => point >= '0' and point <= '9',
        .word => isWord(point),
        .space => isWhitespace(point),
        .category => ((term.categories >> @intCast(unicode.category(point))) & 1) != 0,
    };
    return matched != term.negate;
}

fn isWhitespace(point: u21) bool {
    return point == 0x20 or (point >= 0x09 and point <= 0x0d) or point == 0xa0 or
        point == 0x1680 or (point >= 0x2000 and point <= 0x200a) or
        point == 0x2028 or point == 0x2029 or point == 0x202f or point == 0x205f or point == 0x3000 or point == 0xfeff;
}

fn classMatches(class: CharacterClass, point: u21) bool {
    var matched = false;
    for (class.ranges) |range| {
        if (point >= range.first and point <= range.last) {
            matched = true;
            break;
        }
    }
    if (!matched) for (class.terms) |term| {
        if (termMatches(term, point)) {
            matched = true;
            break;
        }
    };
    return matched != class.negate;
}

pub fn compile(alloc: std.mem.Allocator, pattern: []const u8) !Regex {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();
    var parser: Parser = .{ .alloc = arena_alloc, .pattern = pattern };
    const root = try parser.parse();
    var compiler: Compiler = .{ .alloc = arena_alloc };
    const match = try compiler.emit(.{ .op = .match });
    const start = try compiler.compile(root, match);
    return .{
        .arena = arena,
        .pattern = pattern,
        .instructions = try compiler.instructions.toOwnedSlice(arena_alloc),
        .classes = try parser.classes.toOwnedSlice(arena_alloc),
        .start = start,
    };
}

pub fn compileErrorMessage(alloc: std.mem.Allocator, pattern: []const u8, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(alloc, "cannot compile regex '{s}': {s}", .{ pattern, @errorName(err) });
}

test "linear Pike VM handles alternation, classes, repetitions and Unicode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var regex = try compile(alloc, "^(?:[a-z]+|\\p{Letter}{2,4})\\d?$");
    defer regex.deinit();
    try std.testing.expect(try regex.matches(alloc, "hello"));
    try std.testing.expect(try regex.matches(alloc, "é"));
    try std.testing.expect(!try regex.matches(alloc, "Hello!"));
}

test "nested repetition runs with a bounded Pike VM step count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var regex = try compile(alloc, "(a*)*b");
    defer regex.deinit();
    const text = try alloc.alloc(u8, 100_000);
    @memset(text, 'a');
    var steps: usize = 0;
    try std.testing.expect(!try regex.matchesWithBudget(alloc, text, &steps));
    try std.testing.expect(steps < text.len * 100);
}

test "unsupported lookaround and backreferences are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedRegex, compile(arena.allocator(), "(?=x)x"));
    try std.testing.expectError(error.UnsupportedRegex, compile(arena.allocator(), "(a)\\1"));
}

test "ECMAScript control escapes and digit category alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var control = try compile(arena.allocator(), "^\\cC$");
    defer control.deinit();
    try std.testing.expect(try control.matches(arena.allocator(), "\x03"));
    try std.testing.expect(!try control.matches(arena.allocator(), "\x04"));
    var digits = try compile(arena.allocator(), "^\\p{digit}+$");
    defer digits.deinit();
    try std.testing.expect(try digits.matches(arena.allocator(), "123"));
}
