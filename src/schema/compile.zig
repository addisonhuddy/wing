const std = @import("std");
const jv = @import("../jv.zig");
const metaschemas = @import("metaschemas.zig");
const regex = @import("../regex.zig");
const uri = @import("uri.zig");
const number = @import("number.zig");

pub const Draft = metaschemas.Draft;
pub const default_base_uri = "https://wing.invalid/root";
pub const MetaRegistration = struct { uri: []const u8, draft: Draft };
pub const Options = struct {
    default_draft: Draft = .draft07,
    base_uri: []const u8 = default_base_uri,
    registered_metaschemas: []const MetaRegistration = &.{},
    extra_resources: []const ResourceSource = &.{},
};
pub const ResourceSource = struct { uri: []const u8, document: jv.Document };
pub const Keyword = struct {
    name: []const u8,
    value: *const jv.Node,
    location: []const u8,
};
pub const NumericKeywords = struct {
    multiple_of: ?number.Decimal = null,
    minimum: ?number.Decimal = null,
    maximum: ?number.Decimal = null,
    exclusive_minimum: ?number.Decimal = null,
    exclusive_maximum: ?number.Decimal = null,
    min_length: ?number.Decimal = null,
    max_length: ?number.Decimal = null,
    min_items: ?number.Decimal = null,
    max_items: ?number.Decimal = null,
    min_contains: ?number.Decimal = null,
    max_contains: ?number.Decimal = null,
    min_properties: ?number.Decimal = null,
    max_properties: ?number.Decimal = null,

    fn set(self: *NumericKeywords, name: []const u8, value: number.Decimal) void {
        if (std.mem.eql(u8, name, "multipleOf")) self.multiple_of = value else if (std.mem.eql(u8, name, "minimum")) self.minimum = value else if (std.mem.eql(u8, name, "maximum")) self.maximum = value else if (std.mem.eql(u8, name, "exclusiveMinimum")) self.exclusive_minimum = value else if (std.mem.eql(u8, name, "exclusiveMaximum")) self.exclusive_maximum = value else if (std.mem.eql(u8, name, "minLength")) self.min_length = value else if (std.mem.eql(u8, name, "maxLength")) self.max_length = value else if (std.mem.eql(u8, name, "minItems")) self.min_items = value else if (std.mem.eql(u8, name, "maxItems")) self.max_items = value else if (std.mem.eql(u8, name, "minContains")) self.min_contains = value else if (std.mem.eql(u8, name, "maxContains")) self.max_contains = value else if (std.mem.eql(u8, name, "minProperties")) self.min_properties = value else if (std.mem.eql(u8, name, "maxProperties")) self.max_properties = value;
    }
};
pub const Child = struct {
    keyword: []const u8,
    selector: ?[]const u8,
    node: *Node,
};
pub const Pattern = struct { source: []const u8, expression: regex.Regex };
pub const Vocabularies = struct {
    core: bool = true,
    applicator: bool = true,
    validation: bool = true,
    unevaluated: bool = true,
    meta_data: bool = true,
    format: bool = true,
    content: bool = true,
};
pub const Node = struct {
    schema: *const jv.Node,
    location: []const u8,
    base_uri: []const u8,
    draft: Draft,
    vocabularies: Vocabularies,
    keywords: []const Keyword,
    active_keywords: []const Keyword = &.{},
    numeric: NumericKeywords = .{},
    has_references: bool = false,
    has_const: bool = false,
    has_enum: bool = false,
    has_combinators: bool = false,
    has_dependencies: bool = false,
    children: []const Child,
    patterns: []Pattern,

    pub fn keyword(self: *const Node, name: []const u8) ?*const jv.Node {
        var low: usize = 0;
        var high = self.active_keywords.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const item = self.active_keywords[middle];
            if (std.mem.lessThan(u8, item.name, name)) {
                low = middle + 1;
            } else if (std.mem.lessThan(u8, name, item.name)) {
                high = middle;
            } else {
                return item.value;
            }
        }
        return null;
    }

    pub fn child(self: *const Node, keyword_name: []const u8, selector: ?[]const u8) ?*Node {
        var low: usize = 0;
        var high = self.children.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const item = self.children[middle];
            switch (compareChild(item, keyword_name, selector)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return item.node,
            }
        }
        return null;
    }

    pub fn pattern(self: *const Node, source: []const u8) ?*const regex.Regex {
        for (self.patterns) |*item| if (std.mem.eql(u8, item.source, source)) return &item.expression;
        return null;
    }
};

const Resource = struct { uri: []const u8, root: *Node };
const Anchor = struct { resource_uri: []const u8, name: []const u8, node: *Node, dynamic: bool };
pub const Plan = struct {
    draft: Draft,
    root: *Node,
    uses_dynamic_refs: bool = false,
    nodes: std.StringHashMapUnmanaged(*Node) = .empty,
    resources: std.ArrayListUnmanaged(Resource) = .empty,
    anchors: std.ArrayListUnmanaged(Anchor) = .empty,
};

pub const Cache = struct {
    plans: std.StringHashMapUnmanaged(*Plan) = .empty,

    pub fn get(self: *const Cache, key: []const u8) ?*Plan {
        return self.plans.get(key);
    }

    pub fn put(self: *Cache, alloc: std.mem.Allocator, key: []const u8, plan: *Plan) !void {
        try self.plans.put(alloc, key, plan);
    }
};

const Builder = struct {
    alloc: std.mem.Allocator,
    plan: *Plan,
    draft: Draft,
    vocabularies: Vocabularies = .{},
    active: std.StringHashMapUnmanaged(void) = .empty,

    fn compileNode(self: *Builder, schema: *const jv.Node, location: []const u8, parent_base: []const u8) anyerror!*Node {
        if (self.active.contains(location)) return error.SchemaCycle;
        try self.active.put(self.alloc, location, {});
        defer _ = self.active.remove(location);

        if (schema.value == .boolean) {
            if (self.draft == .draft04) return error.BooleanSchemaNotSupported;
            const node = try self.alloc.create(Node);
            node.* = .{
                .schema = schema,
                .location = location,
                .base_uri = parent_base,
                .draft = self.draft,
                .vocabularies = self.vocabularies,
                .keywords = &.{},
                .children = &.{},
                .patterns = &.{},
            };
            try self.plan.nodes.put(self.alloc, location, node);
            return node;
        }
        if (schema.value != .object) return error.InvalidSchema;

        var base = parent_base;
        const id_name = if (self.draft == .draft04) "id" else "$id";
        const ignored_ref_siblings = self.draft == .draft04 or self.draft == .draft06 or self.draft == .draft07;
        if (keywordEnabled(self.vocabularies, id_name) and
            !(ignored_ref_siblings and field(schema, "$ref") != null))
        {
            if (field(schema, id_name)) |id_value| {
                if (id_value.value == .string) base = try uri.resolve(self.alloc, parent_base, id_value.value.string);
            }
        }
        const node = try self.alloc.create(Node);
        node.* = .{
            .schema = schema,
            .location = location,
            .base_uri = base,
            .draft = self.draft,
            .vocabularies = self.vocabularies,
            .keywords = &.{},
            .children = &.{},
            .patterns = &.{},
        };
        try self.plan.nodes.put(self.alloc, location, node);
        if (std.mem.eql(u8, location, "#") or std.mem.eql(u8, location, parent_base) or
            !sameSchemaUri(baseWithoutFragment(base), baseWithoutFragment(parent_base)))
            try self.plan.resources.append(self.alloc, .{ .uri = baseWithoutFragment(base), .root = node });

        var keywords: std.ArrayListUnmanaged(Keyword) = .empty;
        var active_keywords: std.ArrayListUnmanaged(Keyword) = .empty;
        var children: std.ArrayListUnmanaged(Child) = .empty;
        var patterns: std.ArrayListUnmanaged(Pattern) = .empty;
        var numeric: NumericKeywords = .{};
        for (schema.value.object) |member| {
            const keyword_location = try appendPointer(self.alloc, location, member.key);
            try keywords.append(self.alloc, .{
                .name = member.key,
                .value = member.value,
                .location = keyword_location,
            });
            if (draftDefinesKeyword(self.draft, member.key) and keywordEnabled(self.vocabularies, member.key)) {
                try active_keywords.append(self.alloc, .{
                    .name = member.key,
                    .value = member.value,
                    .location = keyword_location,
                });
                if (std.mem.eql(u8, member.key, "$ref") or std.mem.eql(u8, member.key, "$dynamicRef") or std.mem.eql(u8, member.key, "$recursiveRef"))
                    node.has_references = true;
                if (std.mem.eql(u8, member.key, "const")) node.has_const = true;
                if (std.mem.eql(u8, member.key, "enum")) node.has_enum = true;
                if (std.mem.eql(u8, member.key, "allOf") or std.mem.eql(u8, member.key, "anyOf") or std.mem.eql(u8, member.key, "oneOf") or std.mem.eql(u8, member.key, "not") or std.mem.eql(u8, member.key, "if"))
                    node.has_combinators = true;
                if (std.mem.eql(u8, member.key, "dependencies") or std.mem.eql(u8, member.key, "dependentRequired") or std.mem.eql(u8, member.key, "dependentSchemas"))
                    node.has_dependencies = true;
                if (member.value.value == .number)
                    numeric.set(member.key, try number.parse(self.alloc, member.value.value.number));
                if (std.mem.eql(u8, member.key, "$dynamicRef") or std.mem.eql(u8, member.key, "$recursiveRef"))
                    self.plan.uses_dynamic_refs = true;
                if (std.mem.eql(u8, member.key, "pattern")) {
                    if (member.value.value == .string) {
                        const expression = try regex.compile(self.alloc, member.value.value.string);
                        try patterns.append(self.alloc, .{ .source = member.value.value.string, .expression = expression });
                    }
                } else if (std.mem.eql(u8, member.key, "patternProperties") and member.value.value == .object) {
                    for (member.value.value.object) |entry| {
                        const expression = try regex.compile(self.alloc, entry.key);
                        try patterns.append(self.alloc, .{ .source = entry.key, .expression = expression });
                    }
                }
                try self.compileChildren(member.key, member.value, keyword_location, base, &children);
            }
        }
        var sort_index: usize = 1;
        while (sort_index < active_keywords.items.len) : (sort_index += 1) {
            var current = sort_index;
            while (current > 0 and std.mem.lessThan(u8, active_keywords.items[current].name, active_keywords.items[current - 1].name)) : (current -= 1) {
                std.mem.swap(Keyword, &active_keywords.items[current], &active_keywords.items[current - 1]);
            }
        }
        node.keywords = try keywords.toOwnedSlice(self.alloc);
        node.active_keywords = try active_keywords.toOwnedSlice(self.alloc);
        node.numeric = numeric;
        std.mem.sort(Child, children.items, {}, childLessThan);
        node.children = try children.toOwnedSlice(self.alloc);
        node.patterns = try patterns.toOwnedSlice(self.alloc);
        try self.registerAnchors(node);
        return node;
    }

    fn registerAnchors(self: *Builder, node: *Node) !void {
        const resource_uri = baseWithoutFragment(node.base_uri);
        if (node.draft == .draft04 or node.draft == .draft06 or node.draft == .draft07) {
            const identifier_name = if (node.draft == .draft04) "id" else "$id";
            if (node.keyword(identifier_name)) |identifier| {
                if (identifier.value == .string) {
                    if (std.mem.indexOfScalar(u8, identifier.value.string, '#')) |hash| {
                        const fragment = identifier.value.string[hash + 1 ..];
                        if (fragment.len > 0 and fragment[0] != '/') try self.plan.anchors.append(self.alloc, .{
                            .resource_uri = resource_uri,
                            .name = try uri.percentDecode(self.alloc, fragment),
                            .node = node,
                            .dynamic = false,
                        });
                    }
                }
            }
        }
        if (node.keyword("$anchor")) |value| {
            if (value.value == .string) try self.plan.anchors.append(self.alloc, .{
                .resource_uri = resource_uri,
                .name = value.value.string,
                .node = node,
                .dynamic = false,
            });
        }
        if (node.keyword("$dynamicAnchor")) |value| {
            if (value.value == .string) try self.plan.anchors.append(self.alloc, .{
                .resource_uri = resource_uri,
                .name = value.value.string,
                .node = node,
                .dynamic = true,
            });
        }
        if (node.keyword("$recursiveAnchor")) |value| {
            if (value.value == .boolean and value.value.boolean) try self.plan.anchors.append(self.alloc, .{
                .resource_uri = resource_uri,
                .name = "",
                .node = node,
                .dynamic = true,
            });
        }
    }

    fn compileChildren(
        self: *Builder,
        name: []const u8,
        value: *const jv.Node,
        keyword_location: []const u8,
        base: []const u8,
        children: *std.ArrayListUnmanaged(Child),
    ) anyerror!void {
        if (isSingleSchemaKeyword(name) and isSchema(value, self.draft)) {
            const child_location = try std.fmt.allocPrint(self.alloc, "{s}", .{keyword_location});
            const child = try self.compileNode(value, child_location, base);
            try children.append(self.alloc, .{ .keyword = name, .selector = null, .node = child });
            return;
        }
        if (isSchemaMapKeyword(name) and value.value == .object) {
            for (value.value.object) |entry| {
                if (!isSchema(entry.value, self.draft)) continue;
                const child_location = try appendPointer(self.alloc, keyword_location, entry.key);
                const child = try self.compileNode(entry.value, child_location, base);
                try children.append(self.alloc, .{ .keyword = name, .selector = entry.key, .node = child });
            }
            return;
        }
        if (isSchemaArrayKeyword(name) and value.value == .array) {
            for (value.value.array, 0..) |entry, index| {
                if (!isSchema(entry, self.draft)) continue;
                const selector = try std.fmt.allocPrint(self.alloc, "{d}", .{index});
                const child_location = try appendPointer(self.alloc, keyword_location, selector);
                const child = try self.compileNode(entry, child_location, base);
                try children.append(self.alloc, .{ .keyword = name, .selector = selector, .node = child });
            }
        } else if (std.mem.eql(u8, name, "items") and value.value == .array) {
            for (value.value.array, 0..) |entry, index| {
                if (!isSchema(entry, self.draft)) continue;
                const selector = try std.fmt.allocPrint(self.alloc, "{d}", .{index});
                const child_location = try appendPointer(self.alloc, keyword_location, selector);
                const child = try self.compileNode(entry, child_location, base);
                try children.append(self.alloc, .{ .keyword = name, .selector = selector, .node = child });
            }
        } else if (std.mem.eql(u8, name, "dependencies") and value.value == .object) {
            for (value.value.object) |entry| {
                if (!isSchema(entry.value, self.draft)) continue;
                const child_location = try appendPointer(self.alloc, keyword_location, entry.key);
                const child = try self.compileNode(entry.value, child_location, base);
                try children.append(self.alloc, .{ .keyword = name, .selector = entry.key, .node = child });
            }
        }
    }
};

pub fn compile(alloc: std.mem.Allocator, document: jv.Document, options: Options) !Plan {
    const draft = try selectDraft(document.root, options);
    var plan: Plan = .{ .draft = draft, .root = undefined };
    const vocabularies = try vocabulariesFor(document.root, options);
    var builder: Builder = .{ .alloc = alloc, .plan = &plan, .draft = draft, .vocabularies = vocabularies };
    plan.root = try builder.compileNode(document.root, "#", options.base_uri);
    for (options.extra_resources) |resource| {
        const resolved_uri = try uri.resolve(alloc, plan.root.base_uri, resource.uri);
        const root = try builder.compileNode(resource.document.root, resource.uri, resolved_uri);
        for ([_][]const u8{ resource.uri, resolved_uri, baseWithoutFragment(root.base_uri) }) |resource_name| {
            var registered = false;
            for (plan.resources.items) |existing| if (sameSchemaUri(existing.uri, resource_name)) {
                registered = true;
                break;
            };
            if (!registered) try plan.resources.append(alloc, .{ .uri = resource_name, .root = root });
        }
    }
    if (containsEmbeddedReference(document.root)) {
        const main_vocabularies = builder.vocabularies;
        for (metaschemas.entries) |entry| {
            const embedded_doc = try jv.parse(alloc, entry.source);
            builder.draft = entry.draft;
            builder.vocabularies = .{};
            _ = try builder.compileNode(embedded_doc.root, entry.uri, entry.uri);
        }
        builder.draft = draft;
        builder.vocabularies = main_vocabularies;
    }
    return plan;
}

pub fn selectDraft(root: *const jv.Node, options: Options) !Draft {
    const schema = field(root, "$schema") orelse return options.default_draft;
    if (schema.value != .string) return error.InvalidSchemaUri;
    if (draftForUri(schema.value.string)) |draft| return draft;
    for (options.registered_metaschemas) |registered| {
        if (sameSchemaUri(registered.uri, schema.value.string)) return registered.draft;
    }
    for (options.extra_resources) |resource| {
        if (!sameSchemaUri(resource.uri, schema.value.string)) continue;
        const declared = field(resource.document.root, "$schema") orelse continue;
        if (declared.value == .string) {
            if (draftForUri(declared.value.string)) |draft| return draft;
            if (metaschemas.declaredDraft(declared.value.string)) |draft| return draft;
        }
    }
    if (metaschemas.declaredDraft(schema.value.string)) |draft| return draft;
    return error.UnknownMetaSchema;
}

fn vocabulariesFor(root: *const jv.Node, options: Options) !Vocabularies {
    const schema_uri = field(root, "$schema") orelse return .{};
    if (schema_uri.value != .string) return error.InvalidSchemaUri;
    for (options.extra_resources) |resource| {
        if (!sameSchemaUri(resource.uri, schema_uri.value.string)) continue;
        const vocabulary = field(resource.document.root, "$vocabulary") orelse return .{};
        if (vocabulary.value != .object) return error.InvalidVocabulary;
        var result: Vocabularies = .{ .core = false, .applicator = false, .validation = false, .unevaluated = false };
        for (vocabulary.value.object) |entry| {
            if (entry.value.value != .boolean) return error.InvalidVocabulary;
            const required = entry.value.value.boolean;
            const name = vocabularyName(entry.key) orelse {
                if (required) return error.UnsupportedVocabulary;
                continue;
            };
            if (std.mem.eql(u8, name, "core")) {
                result.core = required;
            } else if (std.mem.eql(u8, name, "applicator")) {
                result.applicator = required;
            } else if (std.mem.eql(u8, name, "validation")) {
                result.validation = required;
            } else if (std.mem.eql(u8, name, "unevaluated")) {
                result.unevaluated = required;
            } else if (std.mem.eql(u8, name, "meta-data")) {
                result.meta_data = required;
            } else if (std.mem.eql(u8, name, "format") or std.mem.eql(u8, name, "format-annotation") or
                std.mem.eql(u8, name, "format-assertion"))
            {
                result.format = required;
            } else if (std.mem.eql(u8, name, "content")) {
                result.content = required;
            } else if (required) {
                return error.UnsupportedVocabulary;
            }
        }
        return result;
    }
    return .{};
}

pub fn resolveReference(alloc: std.mem.Allocator, plan: *const Plan, from: *const Node, reference: []const u8) !*Node {
    const resolved = try uri.resolve(alloc, from.base_uri, reference);
    const hash = std.mem.indexOfScalar(u8, resolved, '#') orelse resolved.len;
    const resource_uri = resolved[0..hash];
    var resource: ?Resource = null;
    if (resource_uri.len == 0 or sameSchemaUri(resource_uri, baseWithoutFragment(plan.root.base_uri))) {
        resource = .{ .uri = resource_uri, .root = plan.root };
    } else {
        for (plan.resources.items) |candidate| {
            if (sameSchemaUri(candidate.uri, resource_uri)) resource = candidate;
        }
        if (resource == null and sameSchemaUri(from.base_uri, resource_uri)) {
            resource = .{ .uri = resource_uri, .root = plan.root };
        }
    }
    const root = (resource orelse return error.RemoteReferenceNotFound).root;
    if (hash == resolved.len) return root;
    const fragment = resolved[hash + 1 ..];
    if (fragment.len == 0) return root;
    const decoded_fragment = try uri.percentDecode(alloc, fragment);
    if (decoded_fragment[0] != '/') {
        const anchor_name = decoded_fragment;
        for (plan.anchors.items) |anchor| {
            if (sameSchemaUri(anchor.resource_uri, resource_uri) and std.mem.eql(u8, anchor.name, anchor_name))
                return anchor.node;
        }
        return error.ReferenceTargetNotFound;
    }
    const tokens = try uri.pointerTokens(alloc, fragment);
    var path = root.location;
    for (tokens) |token| path = try appendPointer(alloc, path, token);
    return plan.nodes.get(path) orelse error.ReferenceTargetNotSchema;
}

pub fn keywordPath(alloc: std.mem.Allocator, parent: []const u8, key: []const u8) ![]const u8 {
    return appendPointer(alloc, parent, key);
}

fn draftForUri(text: []const u8) ?Draft {
    const normalized = std.mem.trimEnd(u8, text, "#");
    const versions = [_]struct { uri: []const u8, draft: Draft }{
        .{ .uri = "http://json-schema.org/draft-04/schema", .draft = .draft04 },
        .{ .uri = "https://json-schema.org/draft-04/schema", .draft = .draft04 },
        .{ .uri = "http://json-schema.org/draft-06/schema", .draft = .draft06 },
        .{ .uri = "https://json-schema.org/draft-06/schema", .draft = .draft06 },
        .{ .uri = "http://json-schema.org/draft-07/schema", .draft = .draft07 },
        .{ .uri = "https://json-schema.org/draft-07/schema", .draft = .draft07 },
        .{ .uri = "http://json-schema.org/draft/2019-09/schema", .draft = .draft2019_09 },
        .{ .uri = "https://json-schema.org/draft/2019-09/schema", .draft = .draft2019_09 },
        .{ .uri = "http://json-schema.org/draft/2020-12/schema", .draft = .draft2020_12 },
        .{ .uri = "https://json-schema.org/draft/2020-12/schema", .draft = .draft2020_12 },
    };
    for (versions) |version| {
        if (std.mem.eql(u8, normalized, version.uri)) return version.draft;
    }
    return null;
}

pub fn sameSchemaUri(a: []const u8, b: []const u8) bool {
    const left = std.mem.trimEnd(u8, a, "#");
    const right = std.mem.trimEnd(u8, b, "#");
    if (std.mem.eql(u8, left, right)) return true;
    if (std.mem.startsWith(u8, left, "http://json-schema.org/") and std.mem.startsWith(u8, right, "https://json-schema.org/"))
        return std.mem.eql(u8, left["http://".len..], right["https://".len..]);
    if (std.mem.startsWith(u8, left, "https://json-schema.org/") and std.mem.startsWith(u8, right, "http://json-schema.org/"))
        return std.mem.eql(u8, left["https://".len..], right["http://".len..]);
    return false;
}

fn keywordEnabled(vocabularies: Vocabularies, name: []const u8) bool {
    if (std.mem.eql(u8, name, "unevaluatedProperties") or std.mem.eql(u8, name, "unevaluatedItems"))
        return vocabularies.unevaluated;
    if (std.mem.eql(u8, name, "title") or std.mem.eql(u8, name, "description") or
        std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "examples") or
        std.mem.eql(u8, name, "deprecated") or std.mem.eql(u8, name, "readOnly") or
        std.mem.eql(u8, name, "writeOnly"))
        return vocabularies.meta_data;
    if (std.mem.eql(u8, name, "format")) return vocabularies.format;
    if (std.mem.eql(u8, name, "contentEncoding") or std.mem.eql(u8, name, "contentMediaType") or
        std.mem.eql(u8, name, "contentSchema"))
        return vocabularies.content;
    if (std.mem.eql(u8, name, "$schema") or std.mem.eql(u8, name, "$id") or std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "$ref") or std.mem.eql(u8, name, "$anchor") or std.mem.eql(u8, name, "$dynamicRef") or
        std.mem.eql(u8, name, "$dynamicAnchor") or std.mem.eql(u8, name, "$recursiveRef") or
        std.mem.eql(u8, name, "$recursiveAnchor") or std.mem.eql(u8, name, "$defs") or std.mem.eql(u8, name, "definitions"))
        return vocabularies.core;
    if (std.mem.eql(u8, name, "properties") or std.mem.eql(u8, name, "patternProperties") or
        std.mem.eql(u8, name, "additionalProperties") or std.mem.eql(u8, name, "additionalItems") or
        std.mem.eql(u8, name, "items") or std.mem.eql(u8, name, "prefixItems") or
        std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "propertyNames") or
        std.mem.eql(u8, name, "dependencies") or std.mem.eql(u8, name, "dependentSchemas") or
        std.mem.eql(u8, name, "allOf") or std.mem.eql(u8, name, "anyOf") or
        std.mem.eql(u8, name, "oneOf") or std.mem.eql(u8, name, "not") or
        std.mem.eql(u8, name, "if") or std.mem.eql(u8, name, "then") or std.mem.eql(u8, name, "else"))
        return vocabularies.applicator;
    if (std.mem.eql(u8, name, "type") or std.mem.eql(u8, name, "enum") or std.mem.eql(u8, name, "const") or
        std.mem.eql(u8, name, "multipleOf") or std.mem.eql(u8, name, "maximum") or
        std.mem.eql(u8, name, "exclusiveMaximum") or std.mem.eql(u8, name, "minimum") or
        std.mem.eql(u8, name, "exclusiveMinimum") or std.mem.eql(u8, name, "maxLength") or
        std.mem.eql(u8, name, "minLength") or std.mem.eql(u8, name, "pattern") or
        std.mem.eql(u8, name, "maxItems") or std.mem.eql(u8, name, "minItems") or
        std.mem.eql(u8, name, "uniqueItems") or std.mem.eql(u8, name, "maxProperties") or
        std.mem.eql(u8, name, "minProperties") or std.mem.eql(u8, name, "required") or
        std.mem.eql(u8, name, "dependentRequired") or std.mem.eql(u8, name, "minContains") or
        std.mem.eql(u8, name, "maxContains"))
        return vocabularies.validation;
    return true;
}

fn draftDefinesKeyword(draft: Draft, name: []const u8) bool {
    const common = [_][]const u8{
        "$schema",          "$ref",              "definitions",          "type",     "enum",   "allOf",       "anyOf",    "oneOf",    "not",
        "properties",       "patternProperties", "additionalProperties", "required", "items",  "uniqueItems", "maxItems", "minItems", "maxProperties",
        "minProperties",    "maxLength",         "minLength",            "pattern",  "format", "multipleOf",  "minimum",  "maximum",  "exclusiveMinimum",
        "exclusiveMaximum", "title",             "description",          "default",
    };
    for (common) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    if (std.mem.eql(u8, name, "dependencies")) return draft == .draft04 or draft == .draft06 or draft == .draft07;
    if (std.mem.eql(u8, name, "additionalItems")) return draft != .draft2020_12;
    if (std.mem.eql(u8, name, "id")) return draft == .draft04;
    if (std.mem.eql(u8, name, "$id")) return draft != .draft04;
    if (draft == .draft04) return false;
    const draft06 = [_][]const u8{ "const", "contains", "propertyNames" };
    for (draft06) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    if (draft == .draft06) return false;
    const draft07 = [_][]const u8{ "if", "then", "else", "$comment", "examples", "readOnly", "writeOnly", "contentEncoding", "contentMediaType" };
    for (draft07) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    if (draft == .draft07) return false;
    const draft2019 = [_][]const u8{
        "$defs",            "$vocabulary", "$anchor",     "$recursiveAnchor",      "$recursiveRef",    "dependentRequired",
        "dependentSchemas", "minContains", "maxContains", "unevaluatedProperties", "unevaluatedItems", "contentSchema",
        "deprecated",
    };
    for (draft2019) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    if (draft == .draft2019_09) return false;
    return std.mem.eql(u8, name, "$dynamicAnchor") or std.mem.eql(u8, name, "$dynamicRef") or
        std.mem.eql(u8, name, "prefixItems");
}

fn vocabularyName(uri_value: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{
        "https://json-schema.org/draft/2019-09/vocab/",
        "https://json-schema.org/draft/2020-12/vocab/",
        "http://json-schema.org/draft/2019-09/vocab/",
        "http://json-schema.org/draft/2020-12/vocab/",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, uri_value, prefix)) return uri_value[prefix.len..];
    }
    return null;
}

fn field(node: *const jv.Node, name: []const u8) ?*const jv.Node {
    if (node.value != .object) return null;
    for (node.value.object) |member| if (std.mem.eql(u8, member.key, name)) return member.value;
    return null;
}

fn isSchema(node: *const jv.Node, draft: Draft) bool {
    return node.value == .object or (node.value == .boolean and draft != .draft04);
}

fn isSingleSchemaKeyword(name: []const u8) bool {
    const names = [_][]const u8{
        "additionalItems", "additionalProperties", "contains", "else",             "if",                    "items",
        "not",             "propertyNames",        "then",     "unevaluatedItems", "unevaluatedProperties",
    };
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn isSchemaMapKeyword(name: []const u8) bool {
    const names = [_][]const u8{
        "$defs", "definitions", "dependentSchemas", "patternProperties", "properties",
    };
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn isSchemaArrayKeyword(name: []const u8) bool {
    const names = [_][]const u8{ "allOf", "anyOf", "oneOf", "prefixItems" };
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn appendPointer(alloc: std.mem.Allocator, parent: []const u8, token: []const u8) ![]const u8 {
    var escaped = std.ArrayListUnmanaged(u8).empty;
    for (token) |c| switch (c) {
        '~' => try escaped.appendSlice(alloc, "~0"),
        '/' => try escaped.appendSlice(alloc, "~1"),
        else => try escaped.append(alloc, c),
    };
    const separator: []const u8 = if (std.mem.indexOfScalar(u8, parent, '#') == null) "#" else "";
    return std.fmt.allocPrint(alloc, "{s}{s}/{s}", .{ parent, separator, escaped.items });
}

fn baseWithoutFragment(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '#') orelse text.len];
}

fn containsEmbeddedReference(node: *const jv.Node) bool {
    switch (node.value) {
        .object => |members| {
            for (members) |member| {
                if ((std.mem.eql(u8, member.key, "$id") or std.mem.eql(u8, member.key, "id")) and
                    member.value.value == .string and metaschemas.declaredDraft(member.value.value.string) != null)
                    return true;
                if ((std.mem.eql(u8, member.key, "$ref") or std.mem.eql(u8, member.key, "$dynamicRef") or std.mem.eql(u8, member.key, "$recursiveRef")) and member.value.value == .string and
                    (std.mem.startsWith(u8, member.value.value.string, "https://json-schema.org/") or
                        std.mem.startsWith(u8, member.value.value.string, "http://json-schema.org/")))
                    return true;
                if (containsEmbeddedReference(member.value)) return true;
            }
        },
        .array => |items| for (items) |item| if (containsEmbeddedReference(item)) return true,
        else => {},
    }
    return false;
}

fn compareChild(item: Child, keyword_name: []const u8, selector: ?[]const u8) std.math.Order {
    const keyword_order = std.mem.order(u8, item.keyword, keyword_name);
    if (keyword_order != .eq) return keyword_order;
    if (item.selector) |item_selector| {
        if (selector) |target_selector| return std.mem.order(u8, item_selector, target_selector);
        return .gt;
    }
    return if (selector == null) .eq else .lt;
}

fn childLessThan(_: void, a: Child, b: Child) bool {
    return compareChild(a, b.keyword, b.selector) == .lt;
}

test "draft selection accepts supported HTTP and HTTPS identifiers" {
    try std.testing.expectEqual(Draft.draft04, draftForUri("http://json-schema.org/draft-04/schema#").?);
    try std.testing.expectEqual(Draft.draft2020_12, draftForUri("https://json-schema.org/draft/2020-12/schema").?);
}

test "plan contains absolute keyword locations and local resources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const document = try jv.parse(arena.allocator(), "{\"$id\":\"https://example.test/root\",\"properties\":{\"a/b\":{\"type\":\"string\"}}}");
    const plan = try compile(arena.allocator(), document, .{});
    try std.testing.expect(plan.root.child("properties", "a/b") != null);
    try std.testing.expectEqualStrings("#/properties/a~1b/type", plan.root.child("properties", "a/b").?.keywords[0].location);
}

test "reference resolution honors pointer escapes and HTTP aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const document = try jv.parse(alloc, "{\"$id\":\"https://example.test/root\",\"$defs\":{\"a/b\":{\"type\":\"string\"}},\"$ref\":\"#%2F%24defs/a~1b\"}");
    const plan = try compile(alloc, document, .{});
    const target = try resolveReference(alloc, &plan, plan.root, "#%2F%24defs/a~1b");
    try std.testing.expectEqualStrings("#/$defs/a~1b", target.location);

    const meta_document = try jv.parse(alloc, "{\"$ref\":\"http://json-schema.org/draft-07/schema#\"}");
    const meta_plan = try compile(alloc, meta_document, .{});
    const meta = try resolveReference(alloc, &meta_plan, meta_plan.root, "http://json-schema.org/draft-07/schema#");
    try std.testing.expectEqualStrings("https://json-schema.org/draft-07/schema", meta.location);
    try std.testing.expectEqualStrings("https://json-schema.org/draft-07/schema#/$schema", meta.keywords[0].location);
}

test "relative references resolve against the default base and referenced ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const root = try jv.parse(alloc, "{\"$ref\":\"./money.json#/properties/amount\"}");
    const money = try jv.parse(alloc, "{\"$id\":\"money.json\",\"type\":\"object\",\"properties\":{\"amount\":{\"type\":\"number\"}}}");
    const resources = [_]ResourceSource{.{ .uri = "money.json", .document = money }};
    const plan = try compile(alloc, root, .{ .extra_resources = &resources });
    const resolved = try resolveReference(alloc, &plan, plan.root, "./money.json#/properties/amount");
    try std.testing.expectEqualStrings("number", field(resolved.schema, "type").?.value.string);
}

test "draft keywords and custom vocabularies are gated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old_document = try jv.parse(alloc, "{\"const\":1}");
    const old_plan = try compile(alloc, old_document, .{ .default_draft = .draft04 });
    try std.testing.expect(old_plan.root.keyword("const") == null);
    const new_plan = try compile(alloc, old_document, .{ .default_draft = .draft06 });
    try std.testing.expect(new_plan.root.keyword("const") != null);

    const meta_document = try jv.parse(alloc, "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"$vocabulary\":{\"https://json-schema.org/draft/2020-12/vocab/core\":true,\"https://json-schema.org/draft/2020-12/vocab/applicator\":true}}");
    const custom_document = try jv.parse(alloc, "{\"$schema\":\"https://example.test/meta\",\"type\":\"number\",\"title\":\"label\",\"format\":\"email\",\"contentEncoding\":\"base64\",\"properties\":{\"name\":{\"type\":\"string\"}}}");
    const resources = [_]ResourceSource{.{ .uri = "https://example.test/meta", .document = meta_document }};
    const custom_plan = try compile(alloc, custom_document, .{ .extra_resources = &resources });
    try std.testing.expect(custom_plan.root.keyword("type") == null);
    try std.testing.expect(custom_plan.root.keyword("title") == null);
    try std.testing.expect(custom_plan.root.keyword("format") == null);
    try std.testing.expect(custom_plan.root.keyword("contentEncoding") == null);
    try std.testing.expect(custom_plan.root.child("properties", "name") != null);
}
