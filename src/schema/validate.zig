const std = @import("std");
const jv = @import("../jv.zig");
const number = @import("number.zig");
const compile_mod = @import("compile.zig");
const uri = @import("uri.zig");

pub const Failure = struct {
    instanceLocation: []const u8,
    keywordLocation: []const u8,
    @"error": []const u8,
};

pub const Options = struct { verbose: bool = false };

const Context = struct {
    alloc: std.mem.Allocator,
    plan: *const compile_mod.Plan,
    errors: std.ArrayListUnmanaged(Failure) = .empty,
    verbose: bool,
    depth: usize = 0,
    ref_prefix: ?[]const u8 = null,
    dynamic_scope: []const []const u8 = &.{},
    evaluations: std.ArrayListUnmanaged(Evaluation) = .empty,
    ref_stack: []const RefVisit = &.{},
};
const RefVisit = struct { node: *const compile_mod.Node, instance_path: []const u8 };
const Evaluation = union(enum) {
    property: struct { path: []const u8, name: []const u8 },
    item: struct { path: []const u8, index: usize },
};

pub fn validate(
    alloc: std.mem.Allocator,
    plan: *const compile_mod.Plan,
    instance: *const jv.Node,
    options: Options,
) ![]Failure {
    var context: Context = .{ .alloc = alloc, .plan = plan, .verbose = options.verbose };
    try visit(&context, plan.root, instance, "#");
    return context.errors.toOwnedSlice(alloc);
}

fn visit(ctx: *Context, schema: *const compile_mod.Node, instance: *const jv.Node, instance_path: []const u8) anyerror!void {
    if (ctx.depth >= 256) {
        try fail(ctx, schema, "maximum validation depth exceeded", instance_path, "schema");
        return;
    }
    ctx.depth += 1;
    defer ctx.depth -= 1;
    const previous_scope = ctx.dynamic_scope;
    const resource_uri = resourceUri(schema.base_uri);
    if (ctx.dynamic_scope.len == 0 or !compile_mod.sameSchemaUri(ctx.dynamic_scope[ctx.dynamic_scope.len - 1], resource_uri))
        ctx.dynamic_scope = try appendDynamicResource(ctx.alloc, ctx.dynamic_scope, resource_uri);
    defer ctx.dynamic_scope = previous_scope;
    if (schema.schema.value == .boolean) {
        if (!schema.schema.value.boolean) try fail(ctx, schema, "boolean schema is false", instance_path, "false");
        return;
    }

    for ([_][]const u8{ "$ref", "$dynamicRef", "$recursiveRef" }) |reference_keyword| {
        const reference = schema.keyword(reference_keyword) orelse continue;
        if (reference.value == .string) {
            var target: *const compile_mod.Node = compile_mod.resolveReference(ctx.alloc, ctx.plan, schema, reference.value.string) catch {
                try fail(ctx, schema, "reference could not be resolved", instance_path, reference_keyword);
                return;
            };
            if (std.mem.eql(u8, reference_keyword, "$dynamicRef")) {
                if (referenceAnchor(ctx, reference.value.string)) |name| {
                    if (schemaAnchorName(target, "$dynamicAnchor")) |target_name| {
                        if (std.mem.eql(u8, name, target_name)) {
                            if (dynamicTarget(ctx, name)) |dynamic| target = dynamic;
                        }
                    }
                }
            } else if (std.mem.eql(u8, reference_keyword, "$recursiveRef") and referenceAnchor(ctx, reference.value.string) != null) {
                if (hasRecursiveAnchor(target)) {
                    if (recursiveTarget(ctx)) |dynamic| target = dynamic;
                }
            }
            if (referenceActive(ctx, target, instance_path)) {
                try fail(ctx, schema, "reference loop detected", instance_path, reference_keyword);
                return;
            }
            const prior_prefix = ctx.ref_prefix;
            const prior_stack = ctx.ref_stack;
            ctx.ref_stack = try appendRefVisit(ctx.alloc, ctx.ref_stack, .{ .node = target, .instance_path = instance_path });
            ctx.ref_prefix = try keywordPath(ctx, schema, reference_keyword);
            defer ctx.ref_stack = prior_stack;
            try visitSubschema(ctx, target, instance, instance_path);
            ctx.ref_prefix = prior_prefix;
            if (std.mem.eql(u8, reference_keyword, "$ref") and
                (schema.draft == .draft04 or schema.draft == .draft06 or schema.draft == .draft07)) return;
        }
    }

    if (schema.keyword("type")) |type_value| if (!matchesType(ctx.alloc, type_value, instance, schema.draft)) {
        try fail(ctx, schema, try std.fmt.allocPrint(ctx.alloc, "expected {s}, got {s}", .{
            typeDescription(type_value),
            instanceType(instance),
        }), instance_path, "type");
    };
    if (schema.keyword("const")) |constant| if (!equalValue(ctx.alloc, constant, instance)) {
        try fail(ctx, schema, "must equal the schema const", instance_path, "const");
    };
    if (schema.keyword("enum")) |enumeration| if (enumeration.value == .array) {
        var found = false;
        for (enumeration.value.array) |candidate| if (equalValue(ctx.alloc, candidate, instance)) {
            found = true;
        };
        if (!found) try fail(ctx, schema, "value is not in enum", instance_path, "enum");
    };

    try validateCombinators(ctx, schema, instance, instance_path);
    switch (instance.value) {
        .number => |text| try validateNumber(ctx, schema, text, instance_path),
        .string => |text| try validateString(ctx, schema, text, instance_path),
        .object => |members| try validateObject(ctx, schema, instance, members, instance_path),
        .array => |items| try validateArray(ctx, schema, instance, items, instance_path),
        else => {},
    }
}

fn visitSubschema(ctx: *Context, schema: *const compile_mod.Node, instance: *const jv.Node, instance_path: []const u8) anyerror!void {
    var branch: Context = .{
        .alloc = ctx.alloc,
        .plan = ctx.plan,
        .verbose = ctx.verbose,
        .depth = ctx.depth,
        .ref_prefix = ctx.ref_prefix,
        .dynamic_scope = ctx.dynamic_scope,
        .ref_stack = ctx.ref_stack,
    };
    try visit(&branch, schema, instance, instance_path);
    try ctx.errors.appendSlice(ctx.alloc, branch.errors.items);
    if (branch.errors.items.len == 0) try mergeEvaluations(ctx, &branch);
}

fn validateNumber(ctx: *Context, schema: *const compile_mod.Node, text: []const u8, path: []const u8) anyerror!void {
    const value = try number.parse(ctx.alloc, text);
    if (schema.keyword("multipleOf")) |multiple| {
        if (multiple.value == .number and !try number.multipleOf(ctx.alloc, value, try number.parse(ctx.alloc, multiple.value.number)))
            try fail(ctx, schema, "must be a multiple of the schema value", path, "multipleOf");
    }
    if (schema.draft == .draft04) {
        const minimum = schema.keyword("minimum");
        const exclusive_minimum = schema.keyword("exclusiveMinimum");
        if (minimum) |bound| if (bound.value == .number) {
            const exclusive = exclusive_minimum != null and exclusive_minimum.?.value == .boolean and exclusive_minimum.?.value.boolean;
            try checkNumberBound(ctx, schema, value, bound.value.number, exclusive, true, path, if (exclusive) "exclusiveMinimum" else "minimum");
        };
        const maximum = schema.keyword("maximum");
        const exclusive_maximum = schema.keyword("exclusiveMaximum");
        if (maximum) |bound| if (bound.value == .number) {
            const exclusive = exclusive_maximum != null and exclusive_maximum.?.value == .boolean and exclusive_maximum.?.value.boolean;
            try checkNumberBound(ctx, schema, value, bound.value.number, exclusive, false, path, if (exclusive) "exclusiveMaximum" else "maximum");
        };
    } else {
        if (schema.keyword("minimum")) |bound| if (bound.value == .number)
            try checkNumberBound(ctx, schema, value, bound.value.number, false, true, path, "minimum");
        if (schema.keyword("maximum")) |bound| if (bound.value == .number)
            try checkNumberBound(ctx, schema, value, bound.value.number, false, false, path, "maximum");
        if (schema.keyword("exclusiveMinimum")) |bound| if (bound.value == .number)
            try checkNumberBound(ctx, schema, value, bound.value.number, true, true, path, "exclusiveMinimum");
        if (schema.keyword("exclusiveMaximum")) |bound| if (bound.value == .number)
            try checkNumberBound(ctx, schema, value, bound.value.number, true, false, path, "exclusiveMaximum");
    }
}

fn checkNumberBound(ctx: *Context, schema: *const compile_mod.Node, value: number.Decimal, bound_text: []const u8, exclusive: bool, minimum: bool, path: []const u8, keyword: []const u8) !void {
    const comparison = number.compare(value, try number.parse(ctx.alloc, bound_text));
    const passes = if (minimum)
        (if (exclusive) comparison == .gt else comparison != .lt)
    else
        (if (exclusive) comparison == .lt else comparison != .gt);
    if (!passes) try fail(ctx, schema, try std.fmt.allocPrint(ctx.alloc, "must be {s} {s}", .{
        if (minimum) (if (exclusive) ">" else ">=") else (if (exclusive) "<" else "<="),
        bound_text,
    }), path, keyword);
}

fn validateString(ctx: *Context, schema: *const compile_mod.Node, text: []const u8, path: []const u8) anyerror!void {
    const length = try codepointLength(text);
    try boundInteger(ctx, schema, "minLength", length, true, path);
    try boundInteger(ctx, schema, "maxLength", length, false, path);
    if (schema.keyword("pattern")) |pattern| {
        if (pattern.value == .string) {
            const expression = schema.pattern(pattern.value.string) orelse return error.MissingCompiledPattern;
            if (!try expression.matches(ctx.alloc, text))
                try fail(ctx, schema, try std.fmt.allocPrint(ctx.alloc, "does not match pattern '{s}'", .{pattern.value.string}), path, "pattern");
        }
    }
}

fn validateObject(
    ctx: *Context,
    schema: *const compile_mod.Node,
    instance: *const jv.Node,
    members: []const jv.Member,
    path: []const u8,
) anyerror!void {
    try boundInteger(ctx, schema, "minProperties", members.len, true, path);
    try boundInteger(ctx, schema, "maxProperties", members.len, false, path);
    if (schema.keyword("required")) |required| if (required.value == .array) {
        for (required.value.array) |item| {
            if (item.value != .string) continue;
            if (objectField(instance, item.value.string) == null)
                try fail(ctx, schema, try std.fmt.allocPrint(ctx.alloc, "missing required property '{s}'", .{item.value.string}), path, "required");
        }
    };

    for (members) |member| {
        var matched = false;
        if (schema.child("properties", member.key)) |child| {
            matched = true;
            try markProperty(ctx, path, member.key);
            try visitSubschema(ctx, child, member.value, try appendInstance(ctx.alloc, path, member.key));
        }
        if (schema.keyword("patternProperties")) |patterns| if (patterns.value == .object) {
            for (patterns.value.object) |pattern_entry| {
                const expression = schema.pattern(pattern_entry.key) orelse continue;
                if (try expression.matches(ctx.alloc, member.key)) {
                    matched = true;
                    try markProperty(ctx, path, member.key);
                    if (schema.child("patternProperties", pattern_entry.key)) |child|
                        try visitSubschema(ctx, child, member.value, try appendInstance(ctx.alloc, path, member.key));
                }
            }
        };
        if (!matched) {
            if (schema.child("additionalProperties", null)) |child| {
                try markProperty(ctx, path, member.key);
                try visitSubschema(ctx, child, member.value, try appendInstance(ctx.alloc, path, member.key));
            } else if (schema.keyword("additionalProperties")) |additional| {
                try markProperty(ctx, path, member.key);
                if (additional.value == .boolean and !additional.value.boolean)
                    try fail(ctx, schema, try std.fmt.allocPrint(ctx.alloc, "property '{s}' is not allowed", .{member.key}), path, "additionalProperties");
            }
        }
        if (schema.child("propertyNames", null)) |child| {
            const name_node = try ctx.alloc.create(jv.Node);
            name_node.* = .{ .value = .{ .string = member.key } };
            try visitSubschema(ctx, child, name_node, try appendInstance(ctx.alloc, path, member.key));
        }
    }

    try validateDependencies(ctx, schema, instance, members, path);
    if (schema.draft == .draft2019_09 or schema.draft == .draft2020_12) {
        if (schema.keyword("unevaluatedProperties")) |unevaluated| {
            for (members) |member| {
                if (wasPropertyEvaluated(ctx, path, member.key)) continue;
                if (unevaluated.value == .boolean and !unevaluated.value.boolean)
                    try fail(ctx, schema, try std.fmt.allocPrint(ctx.alloc, "property '{s}' is not allowed", .{member.key}), path, "unevaluatedProperties")
                else if (schema.child("unevaluatedProperties", null)) |child| {
                    try markProperty(ctx, path, member.key);
                    try visitSubschema(ctx, child, member.value, try appendInstance(ctx.alloc, path, member.key));
                }
            }
        }
    }
}

fn validateDependencies(ctx: *Context, schema: *const compile_mod.Node, instance: *const jv.Node, members: []const jv.Member, path: []const u8) anyerror!void {
    for ([_][]const u8{ "dependencies", "dependentRequired" }) |keyword| {
        const dependencies = schema.keyword(keyword) orelse continue;
        if (dependencies.value != .object) continue;
        for (dependencies.value.object) |dependency| {
            if (objectField(instance, dependency.key) == null) continue;
            if (dependency.value.value == .array) {
                for (dependency.value.value.array) |required| {
                    if (required.value == .string and objectField(instance, required.value.string) == null)
                        try fail(ctx, schema, try std.fmt.allocPrint(ctx.alloc, "property '{s}' is required by '{s}'", .{ required.value.string, dependency.key }), path, keyword);
                }
            } else if (std.mem.eql(u8, keyword, "dependencies")) {
                if (schema.child("dependencies", dependency.key)) |child| {
                    var branch: Context = .{ .alloc = ctx.alloc, .plan = ctx.plan, .verbose = ctx.verbose, .depth = ctx.depth, .ref_prefix = ctx.ref_prefix, .dynamic_scope = ctx.dynamic_scope, .ref_stack = ctx.ref_stack };
                    try visit(&branch, child, instance, path);
                    try ctx.errors.appendSlice(ctx.alloc, branch.errors.items);
                    if (branch.errors.items.len == 0) try mergeEvaluations(ctx, &branch);
                }
            }
        }
    }
    if (schema.keyword("dependentSchemas")) |dependencies| if (dependencies.value == .object) {
        for (dependencies.value.object) |dependency| {
            if (objectField(instance, dependency.key) != null) {
                if (schema.child("dependentSchemas", dependency.key)) |child| {
                    var branch: Context = .{ .alloc = ctx.alloc, .plan = ctx.plan, .verbose = ctx.verbose, .depth = ctx.depth, .ref_prefix = ctx.ref_prefix, .dynamic_scope = ctx.dynamic_scope, .ref_stack = ctx.ref_stack };
                    try visit(&branch, child, instance, path);
                    try ctx.errors.appendSlice(ctx.alloc, branch.errors.items);
                    if (branch.errors.items.len == 0) try mergeEvaluations(ctx, &branch);
                }
            }
        }
    };
    _ = members;
}

fn validateArray(ctx: *Context, schema: *const compile_mod.Node, instance: *const jv.Node, items: []const *jv.Node, path: []const u8) anyerror!void {
    _ = instance;
    try boundInteger(ctx, schema, "minItems", items.len, true, path);
    try boundInteger(ctx, schema, "maxItems", items.len, false, path);
    if (schema.keyword("uniqueItems")) |unique| if (unique.value == .boolean and unique.value.boolean) {
        for (items, 0..) |item, index| for (items[index + 1 ..]) |other| {
            if (try equalNode(ctx.alloc, item, other)) {
                try fail(ctx, schema, "array items must be unique", path, "uniqueItems");
                break;
            }
        };
    };

    var prefix_count: usize = 0;
    const prefix_keyword = if (schema.draft == .draft2020_12) "prefixItems" else "items";
    const tuple_items = schema.draft != .draft2020_12 and schema.keyword("items") != null and
        schema.keyword("items").?.value == .array;
    if (schema.keyword(prefix_keyword)) |prefix| if (prefix.value == .array) {
        prefix_count = @min(items.len, prefix.value.array.len);
        for (0..prefix_count) |index| {
            try markItem(ctx, path, index);
            if (schema.child(prefix_keyword, try std.fmt.allocPrint(ctx.alloc, "{d}", .{index}))) |child|
                try visitSubschema(ctx, child, items[index], try appendInstance(ctx.alloc, path, try std.fmt.allocPrint(ctx.alloc, "{d}", .{index})));
        }
    };
    for (items[prefix_count..], prefix_count..) |item, index| {
        if (schema.child("items", null)) |child| {
            try markItem(ctx, path, index);
            try visitSubschema(ctx, child, item, try appendInstance(ctx.alloc, path, try std.fmt.allocPrint(ctx.alloc, "{d}", .{index})));
        } else if (tuple_items) {
            if (schema.child("additionalItems", null)) |child| {
                try markItem(ctx, path, index);
                try visitSubschema(ctx, child, item, try appendInstance(ctx.alloc, path, try std.fmt.allocPrint(ctx.alloc, "{d}", .{index})));
            } else if (schema.keyword("additionalItems")) |item_schema| {
                try markItem(ctx, path, index);
                if (item_schema.value == .boolean and !item_schema.value.boolean)
                    try fail(ctx, schema, "additional array item is not allowed", path, "additionalItems");
            }
        }
    }

    if (schema.child("contains", null)) |contains| {
        var count: usize = 0;
        for (items, 0..) |item, index| {
            var branch: Context = .{ .alloc = ctx.alloc, .plan = ctx.plan, .verbose = false, .depth = ctx.depth, .ref_prefix = ctx.ref_prefix, .dynamic_scope = ctx.dynamic_scope, .ref_stack = ctx.ref_stack };
            try visit(&branch, contains, item, try appendInstance(ctx.alloc, path, try std.fmt.allocPrint(ctx.alloc, "{d}", .{index})));
            if (branch.errors.items.len == 0) {
                count += 1;
                try markItem(ctx, path, index);
                try mergeEvaluations(ctx, &branch);
            }
        }
        if (schema.keyword("minContains") == null and count == 0)
            try fail(ctx, schema, "array must contain a matching item", path, "contains")
        else
            try boundInteger(ctx, schema, "minContains", count, true, path);
        try boundInteger(ctx, schema, "maxContains", count, false, path);
    }
    if (schema.draft == .draft2019_09 or schema.draft == .draft2020_12) {
        if (schema.keyword("unevaluatedItems")) |unevaluated| {
            for (items, 0..) |item, index| {
                if (wasItemEvaluated(ctx, path, index)) continue;
                if (unevaluated.value == .boolean and !unevaluated.value.boolean) {
                    const item_path = try appendInstance(ctx.alloc, path, try std.fmt.allocPrint(ctx.alloc, "{d}", .{index}));
                    try fail(ctx, schema, "array item is not allowed", item_path, "unevaluatedItems");
                } else if (schema.child("unevaluatedItems", null)) |child| {
                    try markItem(ctx, path, index);
                    try visitSubschema(ctx, child, item, try appendInstance(ctx.alloc, path, try std.fmt.allocPrint(ctx.alloc, "{d}", .{index})));
                }
            }
        }
    }
}

fn validateCombinators(ctx: *Context, schema: *const compile_mod.Node, instance: *const jv.Node, path: []const u8) anyerror!void {
    if (schema.keyword("allOf")) |all| if (all.value == .array) {
        var all_valid = true;
        var annotations: std.ArrayListUnmanaged(Evaluation) = .empty;
        for (all.value.array, 0..) |_, index| {
            if (schema.child("allOf", try std.fmt.allocPrint(ctx.alloc, "{d}", .{index}))) |child| {
                var branch: Context = .{ .alloc = ctx.alloc, .plan = ctx.plan, .verbose = ctx.verbose, .depth = ctx.depth, .ref_prefix = ctx.ref_prefix, .dynamic_scope = ctx.dynamic_scope, .ref_stack = ctx.ref_stack };
                try visit(&branch, child, instance, path);
                try ctx.errors.appendSlice(ctx.alloc, branch.errors.items);
                if (branch.errors.items.len == 0) {
                    try annotations.appendSlice(ctx.alloc, branch.evaluations.items);
                } else {
                    all_valid = false;
                }
            }
        }
        if (all_valid) try ctx.evaluations.appendSlice(ctx.alloc, annotations.items);
    };
    for ([_][]const u8{ "anyOf", "oneOf" }) |keyword| {
        const alternatives = schema.keyword(keyword) orelse continue;
        if (alternatives.value != .array) continue;
        var successes: std.ArrayListUnmanaged(usize) = .empty;
        var success_evaluations: std.ArrayListUnmanaged(Evaluation) = .empty;
        var best_errors: []const Failure = &.{};
        var best_discriminator = false;
        var best_depth: usize = 0;
        for (alternatives.value.array, 0..) |_, index| {
            const child = schema.child(keyword, try std.fmt.allocPrint(ctx.alloc, "{d}", .{index})) orelse continue;
            var branch: Context = .{ .alloc = ctx.alloc, .plan = ctx.plan, .verbose = ctx.verbose, .depth = ctx.depth, .ref_prefix = ctx.ref_prefix, .dynamic_scope = ctx.dynamic_scope, .ref_stack = ctx.ref_stack };
            try visit(&branch, child, instance, path);
            if (branch.errors.items.len == 0) {
                try successes.append(ctx.alloc, index);
                try success_evaluations.appendSlice(ctx.alloc, branch.evaluations.items);
            } else {
                const discriminator = matchesDiscriminator(ctx.alloc, child, instance);
                const depth = deepestError(branch.errors.items);
                if ((discriminator and !best_discriminator) or
                    (discriminator == best_discriminator and depth > best_depth))
                {
                    best_errors = branch.errors.items;
                    best_discriminator = discriminator;
                    best_depth = depth;
                }
            }
            if (ctx.verbose) try ctx.errors.appendSlice(ctx.alloc, branch.errors.items);
        }
        const valid = if (std.mem.eql(u8, keyword, "anyOf")) successes.items.len > 0 else successes.items.len == 1;
        if (valid) try ctx.evaluations.appendSlice(ctx.alloc, success_evaluations.items);
        if (!valid) {
            if (successes.items.len > 1 and std.mem.eql(u8, keyword, "oneOf")) {
                var indexes = std.ArrayListUnmanaged(u8).empty;
                for (successes.items, 0..) |index, i| {
                    if (i > 0) try indexes.appendSlice(ctx.alloc, ", ");
                    try indexes.appendSlice(ctx.alloc, try std.fmt.allocPrint(ctx.alloc, "{d}", .{index}));
                }
                try fail(ctx, schema, try std.fmt.allocPrint(ctx.alloc, "matched {d} branches ({s})", .{ successes.items.len, indexes.items }), path, keyword);
            } else {
                if (best_errors.len > 0 and !ctx.verbose)
                    try ctx.errors.appendSlice(ctx.alloc, best_errors)
                else
                    try fail(ctx, schema, if (std.mem.eql(u8, keyword, "anyOf")) "must match an anyOf schema" else "must match exactly one oneOf schema", path, keyword);
            }
        }
    }
    if (schema.child("not", null)) |child| {
        var branch: Context = .{ .alloc = ctx.alloc, .plan = ctx.plan, .verbose = false, .depth = ctx.depth, .ref_prefix = ctx.ref_prefix, .dynamic_scope = ctx.dynamic_scope, .ref_stack = ctx.ref_stack };
        try visit(&branch, child, instance, path);
        if (branch.errors.items.len == 0) try fail(ctx, schema, "must not match the not schema", path, "not");
    }
    if (schema.child("if", null)) |condition| {
        var branch: Context = .{ .alloc = ctx.alloc, .plan = ctx.plan, .verbose = false, .depth = ctx.depth, .ref_prefix = ctx.ref_prefix, .dynamic_scope = ctx.dynamic_scope, .ref_stack = ctx.ref_stack };
        try visit(&branch, condition, instance, path);
        const condition_valid = branch.errors.items.len == 0;
        if (condition_valid) try mergeEvaluations(ctx, &branch);
        const selected = if (condition_valid) schema.child("then", null) else schema.child("else", null);
        if (selected) |child| {
            var selected_branch: Context = .{ .alloc = ctx.alloc, .plan = ctx.plan, .verbose = ctx.verbose, .depth = ctx.depth, .ref_prefix = ctx.ref_prefix, .dynamic_scope = ctx.dynamic_scope, .ref_stack = ctx.ref_stack };
            try visit(&selected_branch, child, instance, path);
            try ctx.errors.appendSlice(ctx.alloc, selected_branch.errors.items);
            if (selected_branch.errors.items.len == 0) try mergeEvaluations(ctx, &selected_branch);
        }
    }
}

fn boundInteger(ctx: *Context, schema: *const compile_mod.Node, keyword: []const u8, value: usize, minimum: bool, path: []const u8) anyerror!void {
    const bound = schema.keyword(keyword) orelse return;
    if (bound.value != .number) return;
    const actual = try number.parse(ctx.alloc, try std.fmt.allocPrint(ctx.alloc, "{d}", .{value}));
    const limit = try number.parse(ctx.alloc, bound.value.number);
    const comparison = number.compare(actual, limit);
    if ((minimum and comparison == .lt) or (!minimum and comparison == .gt))
        try fail(ctx, schema, try std.fmt.allocPrint(ctx.alloc, "{s} is {d}, limit is {s}", .{ keyword, value, bound.value.number }), path, keyword);
}

fn matchesDiscriminator(alloc: std.mem.Allocator, schema: *const compile_mod.Node, instance: *const jv.Node) bool {
    if (schema.keyword("const")) |constant| if (equalValue(alloc, constant, instance)) return true;
    if (schema.keyword("enum")) |enumeration| if (enumeration.value == .array) {
        for (enumeration.value.array) |candidate| if (equalValue(alloc, candidate, instance)) return true;
    };
    for (schema.children) |child| {
        if (std.mem.eql(u8, child.keyword, "properties")) {
            const name = child.selector orelse continue;
            const value = objectField(instance, name) orelse continue;
            if (matchesDiscriminator(alloc, child.node, value)) return true;
        } else if (std.mem.eql(u8, child.keyword, "allOf") or std.mem.eql(u8, child.keyword, "anyOf") or
            std.mem.eql(u8, child.keyword, "oneOf"))
        {
            if (matchesDiscriminator(alloc, child.node, instance)) return true;
        }
    }
    return false;
}

fn deepestError(errors: []const Failure) usize {
    var depth: usize = 0;
    for (errors) |failure| depth = @max(depth, failure.instanceLocation.len + failure.keywordLocation.len);
    return depth;
}

fn matchesType(alloc: std.mem.Allocator, type_value: *const jv.Node, instance: *const jv.Node, draft: compile_mod.Draft) bool {
    if (type_value.value == .array) {
        for (type_value.value.array) |candidate| if (matchesType(alloc, candidate, instance, draft)) return true;
        return false;
    }
    if (type_value.value != .string) return true;
    const expected = type_value.value.string;
    if (std.mem.eql(u8, expected, "number")) return instance.value == .number;
    if (std.mem.eql(u8, expected, "integer")) {
        if (instance.value != .number) return false;
        const value = number.parse(alloc, instance.value.number) catch return false;
        return value.isInteger(draft == .draft04);
    }
    if (std.mem.eql(u8, expected, "string")) return instance.value == .string;
    if (std.mem.eql(u8, expected, "boolean")) return instance.value == .boolean;
    if (std.mem.eql(u8, expected, "null")) return instance.value == .null_value;
    if (std.mem.eql(u8, expected, "object")) return instance.value == .object;
    if (std.mem.eql(u8, expected, "array")) return instance.value == .array;
    return true;
}

fn typeDescription(value: *const jv.Node) []const u8 {
    if (value.value == .string) return value.value.string;
    return "declared type";
}

fn instanceType(instance: *const jv.Node) []const u8 {
    return switch (instance.value) {
        .null_value => "null",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .object => "object",
        .array => "array",
    };
}

fn equalValue(alloc: std.mem.Allocator, a: *const jv.Node, b: *const jv.Node) bool {
    if (a.value == .number and b.value == .number) {
        const left = number.parse(alloc, a.value.number) catch return false;
        const right = number.parse(alloc, b.value.number) catch return false;
        return number.equal(left, right);
    }
    if (std.meta.activeTag(a.value) != std.meta.activeTag(b.value)) return false;
    return switch (a.value) {
        .null_value => true,
        .boolean => |value| value == b.value.boolean,
        .string => |value| std.mem.eql(u8, value, b.value.string),
        .number => unreachable,
        .array => |values| blk: {
            if (values.len != b.value.array.len) break :blk false;
            for (values, b.value.array) |left, right| if (!equalValue(alloc, left, right)) break :blk false;
            break :blk true;
        },
        .object => |members| blk: {
            if (members.len != b.value.object.len) break :blk false;
            for (members) |member| {
                const other = objectField(b, member.key) orelse break :blk false;
                if (!equalValue(alloc, member.value, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn equalNode(alloc: std.mem.Allocator, a: *const jv.Node, b: *const jv.Node) !bool {
    return equalValue(alloc, a, b);
}

fn objectField(node: *const jv.Node, name: []const u8) ?*const jv.Node {
    if (node.value != .object) return null;
    for (node.value.object) |member| if (std.mem.eql(u8, member.key, name)) return member.value;
    return null;
}

fn codepointLength(text: []const u8) !usize {
    var count: usize = 0;
    var position: usize = 0;
    while (position < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[position]) catch return error.InvalidUtf8;
        position += length;
        if (position > text.len) return error.InvalidUtf8;
        count += 1;
    }
    return count;
}

fn appendInstance(alloc: std.mem.Allocator, path: []const u8, token: []const u8) ![]const u8 {
    return compile_mod.keywordPath(alloc, path, token);
}

fn markProperty(ctx: *Context, path: []const u8, name: []const u8) !void {
    try ctx.evaluations.append(ctx.alloc, .{ .property = .{ .path = path, .name = name } });
}

fn markItem(ctx: *Context, path: []const u8, index: usize) !void {
    try ctx.evaluations.append(ctx.alloc, .{ .item = .{ .path = path, .index = index } });
}

fn wasPropertyEvaluated(ctx: *const Context, path: []const u8, name: []const u8) bool {
    for (ctx.evaluations.items) |evaluation| switch (evaluation) {
        .property => |property| {
            if (std.mem.eql(u8, property.path, path) and std.mem.eql(u8, property.name, name)) return true;
        },
        .item => {},
    };
    return false;
}

fn wasItemEvaluated(ctx: *const Context, path: []const u8, index: usize) bool {
    for (ctx.evaluations.items) |evaluation| switch (evaluation) {
        .item => |item| {
            if (std.mem.eql(u8, item.path, path) and item.index == index) return true;
        },
        .property => {},
    };
    return false;
}

fn mergeEvaluations(ctx: *Context, branch: *const Context) !void {
    try ctx.evaluations.appendSlice(ctx.alloc, branch.evaluations.items);
}

fn appendDynamicResource(alloc: std.mem.Allocator, scope: []const []const u8, resource_uri: []const u8) ![]const []const u8 {
    const updated = try alloc.alloc([]const u8, scope.len + 1);
    @memcpy(updated[0..scope.len], scope);
    updated[scope.len] = resource_uri;
    return updated;
}

fn resourceUri(base_uri: []const u8) []const u8 {
    const fragment = std.mem.indexOfScalar(u8, base_uri, '#') orelse return base_uri;
    return base_uri[0..fragment];
}

fn appendRefVisit(alloc: std.mem.Allocator, stack: []const RefVisit, ref_visit: RefVisit) ![]const RefVisit {
    const updated = try alloc.alloc(RefVisit, stack.len + 1);
    @memcpy(updated[0..stack.len], stack);
    updated[stack.len] = ref_visit;
    return updated;
}

fn referenceActive(ctx: *const Context, node: *const compile_mod.Node, instance_path: []const u8) bool {
    for (ctx.ref_stack) |prior_visit| {
        if (prior_visit.node == node and std.mem.eql(u8, prior_visit.instance_path, instance_path)) return true;
    }
    return false;
}

fn schemaAnchorName(schema: *const compile_mod.Node, keyword: []const u8) ?[]const u8 {
    const anchor = schema.keyword(keyword) orelse return null;
    return if (anchor.value == .string) anchor.value.string else null;
}

fn referenceAnchor(ctx: *Context, reference: []const u8) ?[]const u8 {
    const hash = std.mem.indexOfScalar(u8, reference, '#') orelse return null;
    const fragment = reference[hash + 1 ..];
    if (fragment.len > 0 and fragment[0] == '/') return null;
    return uri.percentDecode(ctx.alloc, fragment) catch null;
}

fn dynamicTarget(ctx: *Context, anchor_name: []const u8) ?*const compile_mod.Node {
    for (ctx.dynamic_scope) |resource_uri| {
        for (ctx.plan.anchors.items) |anchor| {
            if (anchor.dynamic and compile_mod.sameSchemaUri(anchor.resource_uri, resource_uri) and
                std.mem.eql(u8, anchor.name, anchor_name))
                return anchor.node;
        }
    }
    return null;
}

fn hasRecursiveAnchor(schema: *const compile_mod.Node) bool {
    const anchor = schema.keyword("$recursiveAnchor") orelse return false;
    return anchor.value == .boolean and anchor.value.boolean;
}

fn recursiveTarget(ctx: *Context) ?*const compile_mod.Node {
    for (ctx.dynamic_scope) |resource_uri| {
        for (ctx.plan.anchors.items) |anchor| {
            if (anchor.dynamic and compile_mod.sameSchemaUri(anchor.resource_uri, resource_uri) and anchor.name.len == 0)
                return anchor.node;
        }
    }
    return null;
}

fn keywordPath(ctx: *Context, schema: *const compile_mod.Node, name: []const u8) ![]const u8 {
    const location = for (schema.keywords) |keyword| {
        if (std.mem.eql(u8, keyword.name, name)) break keyword.location;
    } else try compile_mod.keywordPath(ctx.alloc, schema.location, name);
    if (ctx.ref_prefix) |prefix| return std.fmt.allocPrint(ctx.alloc, "{s} -> {s}", .{ prefix, location });
    return location;
}

fn fail(ctx: *Context, schema: *const compile_mod.Node, message: []const u8, instance_path: []const u8, keyword: []const u8) !void {
    try ctx.errors.append(ctx.alloc, .{
        .instanceLocation = instance_path,
        .keywordLocation = try keywordPath(ctx, schema, keyword),
        .@"error" = message,
    });
}

test "validator checks types, exact numbers, objects, and arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema_doc = try jv.parse(alloc, "{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"integer\",\"minimum\":1},\"tags\":{\"type\":\"array\",\"uniqueItems\":true}}}");
    const plan = try compile_mod.compile(alloc, schema_doc, .{});
    const good = try jv.parse(alloc, "{\"id\":1.0,\"tags\":[\"a\",\"b\"]}");
    const bad = try jv.parse(alloc, "{\"tags\":[\"a\",\"a\"]}");
    try std.testing.expectEqual(@as(usize, 0), (try validate(alloc, &plan, good.root, .{})).len);
    try std.testing.expect((try validate(alloc, &plan, bad.root, .{})).len >= 2);
}

test "reference siblings follow draft rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const document = try jv.parse(alloc, "{\"$ref\":\"#/definitions/number\",\"minimum\":5,\"definitions\":{\"number\":{\"type\":\"number\"}}}");
    const instance = try jv.parse(alloc, "1");
    const old_plan = try compile_mod.compile(alloc, document, .{ .default_draft = .draft04 });
    const new_plan = try compile_mod.compile(alloc, document, .{ .default_draft = .draft07 });
    try std.testing.expectEqual(@as(usize, 0), (try validate(alloc, &old_plan, instance.root, .{})).len);
    try std.testing.expect((try validate(alloc, &new_plan, instance.root, .{})).len > 0);
}

test "draft 4 reference ignores a sibling identifier for resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const document = try jv.parse(alloc, "{\"id\":\"https://example.test/base/\",\"definitions\":{\"target\":{\"id\":\"target\",\"type\":\"number\"}},\"allOf\":[{\"id\":\"https://example.test/sibling/\",\"$ref\":\"target\"}]}");
    const plan = try compile_mod.compile(alloc, document, .{ .default_draft = .draft04 });
    const valid = try jv.parse(alloc, "1");
    const invalid = try jv.parse(alloc, "\"text\"");
    try std.testing.expectEqual(@as(usize, 0), (try validate(alloc, &plan, valid.root, .{})).len);
    try std.testing.expect((try validate(alloc, &plan, invalid.root, .{})).len > 0);
}

test "unevaluated properties receive allOf annotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const document = try jv.parse(alloc, "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"allOf\":[{\"properties\":{\"x\":true}}],\"unevaluatedProperties\":false}");
    const plan = try compile_mod.compile(alloc, document, .{});
    const evaluated = try jv.parse(alloc, "{\"x\":1}");
    const unevaluated = try jv.parse(alloc, "{\"y\":1}");
    try std.testing.expectEqual(@as(usize, 0), (try validate(alloc, &plan, evaluated.root, .{})).len);
    try std.testing.expect((try validate(alloc, &plan, unevaluated.root, .{})).len > 0);
}

test "draft 2020 tuple validation uses prefixItems and items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const document = try jv.parse(alloc, "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"prefixItems\":[{\"type\":\"string\"},{\"type\":\"integer\"}],\"items\":false}");
    const plan = try compile_mod.compile(alloc, document, .{});
    const valid = try jv.parse(alloc, "[\"name\",2]");
    const invalid = try jv.parse(alloc, "[\"name\",2,3]");
    try std.testing.expectEqual(@as(usize, 0), (try validate(alloc, &plan, valid.root, .{})).len);
    try std.testing.expect((try validate(alloc, &plan, invalid.root, .{})).len > 0);
}

test "discriminator ranking recognizes nested const values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const document = try jv.parse(alloc, "{\"oneOf\":[{\"properties\":{\"kind\":{\"const\":\"order\"}},\"required\":[\"other\"]}]}");
    const instance = try jv.parse(alloc, "{\"kind\":\"order\"}");
    const plan = try compile_mod.compile(alloc, document, .{});
    const branch = plan.root.child("oneOf", "0").?;
    try std.testing.expect(matchesDiscriminator(alloc, branch, instance.root));
}

test "draft 4 references preserve ids and additionalItems scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const valid_integer = try jv.parse(alloc, "1");
    const invalid_string = try jv.parse(alloc, "\"1\"");
    const invalid_plan_doc = try jv.parse(alloc, "{\"$ref\":\"#foo\",\"definitions\":{\"A\":{\"id\":\"#foo\",\"type\":\"integer\"}}}");
    const invalid_plan = try compile_mod.compile(alloc, invalid_plan_doc, .{ .default_draft = .draft04 });
    try std.testing.expectEqual(@as(usize, 0), (try validate(alloc, &invalid_plan, valid_integer.root, .{})).len);
    try std.testing.expect((try validate(alloc, &invalid_plan, invalid_string.root, .{})).len > 0);

    const items_doc = try jv.parse(alloc, "{\"additionalItems\":false}");
    const items_plan = try compile_mod.compile(alloc, items_doc, .{ .default_draft = .draft04 });
    const items = try jv.parse(alloc, "[1,2]");
    try std.testing.expectEqual(@as(usize, 0), (try validate(alloc, &items_plan, items.root, .{})).len);

    const modern_doc = try jv.parse(alloc, "{\"$id\":\"https://example.test/root\",\"$ref\":\"#foo\",\"definitions\":{\"A\":{\"$id\":\"#foo\",\"type\":\"integer\"}}}");
    const modern_plan = try compile_mod.compile(alloc, modern_doc, .{ .default_draft = .draft06 });
    try std.testing.expectEqual(@as(usize, 0), (try validate(alloc, &modern_plan, valid_integer.root, .{})).len);
    try std.testing.expect((try validate(alloc, &modern_plan, invalid_string.root, .{})).len > 0);
}

test "contains defaults to requiring one matching item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const document = try jv.parse(alloc, "{\"contains\":{\"const\":\"x\"}}");
    const plan = try compile_mod.compile(alloc, document, .{ .default_draft = .draft06 });
    const matching = try jv.parse(alloc, "[\"y\",\"x\"]");
    const non_matching = try jv.parse(alloc, "[\"y\"]");
    const empty = try jv.parse(alloc, "[]");
    try std.testing.expectEqual(@as(usize, 0), (try validate(alloc, &plan, matching.root, .{})).len);
    try std.testing.expect((try validate(alloc, &plan, non_matching.root, .{})).len > 0);
    try std.testing.expect((try validate(alloc, &plan, empty.root, .{})).len > 0);
}
