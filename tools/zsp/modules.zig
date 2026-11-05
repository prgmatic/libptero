const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const ast_walk = @import("ast_walk.zig");

pub const ParseDiagnostic = struct { path: []const u8, detail: parser_mod.Diagnostic };

const ModuleState = enum {
    loading,
    loaded,
};

pub const Module = struct {
    path: []u8,
    source: []u8,
    functions: []ast.Function,
    imports: []ast.Import,
    targets: []usize,
    state: ModuleState,
    program: @import("source.zig").Program,
};

pub const Loader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    module_dir: ?[]const u8,
    module_override_name: ?[]const u8 = null,
    module_override_path: ?[]const u8 = null,
    modules: std.ArrayList(Module) = .empty,
    diagnostic: ?ParseDiagnostic = null,
    generated_names: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Loader) void {
        if (self.diagnostic) |diagnostic| {
            self.allocator.free(diagnostic.path);
            self.allocator.free(diagnostic.detail.token_text);
        }
        for (self.generated_names.items) |name| self.allocator.free(name);
        self.generated_names.deinit(self.allocator);
        for (self.modules.items) |*module| {
            self.allocator.free(module.targets);
            module.program.deinit();
            self.allocator.free(module.source);
            self.allocator.free(module.path);
        }
        self.modules.deinit(self.allocator);
    }

    fn saveDiagnostic(self: *Loader, path: []const u8, detail: parser_mod.Diagnostic) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_text = try self.allocator.dupe(u8, detail.token_text);
        if (self.diagnostic) |previous| {
            self.allocator.free(previous.path);
            self.allocator.free(previous.detail.token_text);
        }
        self.diagnostic = .{ .path = owned_path, .detail = detail };
        self.diagnostic.?.detail.token_text = owned_text;
    }

    pub fn load(self: *Loader, path: []const u8) anyerror!usize {
        const resolved = try std.fs.path.resolve(self.allocator, &.{path});
        if (self.findLoaded(resolved)) |found| {
            self.allocator.free(resolved);
            return found;
        }
        const index = try self.appendModule(resolved);
        try self.loadImports(index);
        self.modules.items[index].state = .loaded;
        return index;
    }

    /// An already loaded module; reaching one still loading is a cycle.
    fn findLoaded(self: *const Loader, resolved: []const u8) ?anyerror!usize {
        for (self.modules.items, 0..) |module, index| {
            if (!std.mem.eql(u8, module.path, resolved)) continue;
            return if (module.state == .loading) error.ImportCycle else index;
        }
        return null;
    }

    /// Reads and parses a module; the loader owns `resolved` afterwards.
    fn appendModule(self: *Loader, resolved: []u8) !usize {
        errdefer self.allocator.free(resolved);
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, resolved, self.allocator, .limited(1024 * 1024));
        errdefer self.allocator.free(source);
        var program = try self.parse(resolved, source);
        errdefer program.deinit();
        for (program.functions) |*function| function.source_path = resolved;
        const targets = try self.allocator.alloc(usize, program.imports.len);
        errdefer self.allocator.free(targets);
        try self.modules.append(self.allocator, .{
            .path = resolved,
            .source = source,
            .functions = program.functions,
            .imports = program.imports,
            .targets = targets,
            .state = .loading,
            .program = program,
        });
        return self.modules.items.len - 1;
    }

    fn parse(self: *Loader, path: []const u8, source: []const u8) !@import("source.zig").Program {
        var parse_diagnostic: ?parser_mod.Diagnostic = null;
        return @import("source.zig").Program.parse(self.allocator, source, &parse_diagnostic) catch |err| {
            if (parse_diagnostic) |detail| try self.saveDiagnostic(path, detail);
            return err;
        };
    }

    fn loadImports(self: *Loader, index: usize) !void {
        for (0..self.modules.items[index].imports.len) |import_index| {
            const module = self.modules.items[index];
            module.targets[import_index] = try self.loadImport(module.path, module.imports[import_index].path);
        }
    }

    /// The override module, else a path relative to the importer, else one
    /// in the module directory.
    fn loadImport(self: *Loader, importer: []const u8, import_path: []const u8) !usize {
        if (self.overrides(import_path)) return self.load(self.module_override_path.?);
        const parent = std.fs.path.dirname(importer) orelse ".";
        return self.loadUnder(parent, import_path) catch |err| {
            if (err != error.FileNotFound) return err;
            return self.loadUnder(self.module_dir orelse return err, import_path);
        };
    }

    fn overrides(self: *const Loader, import_path: []const u8) bool {
        const name = self.module_override_name orelse return false;
        return std.mem.eql(u8, import_path, name);
    }

    fn loadUnder(self: *Loader, directory: []const u8, import_path: []const u8) !usize {
        const path = try std.fs.path.resolve(self.allocator, &.{ directory, import_path });
        defer self.allocator.free(path);
        return self.load(path);
    }

    pub fn link(self: *Loader, root: usize) ![]ast.Function {
        for (self.modules.items, 0..) |*module, module_index| {
            if (module_index != root) try self.prefixNames(module, module_index);
        }
        for (self.modules.items, 0..) |module, module_index| {
            for (module.functions) |function| try self.resolveCalls(module_index, function.statements);
        }
        var flattened: std.ArrayList(ast.Function) = .empty;
        errdefer flattened.deinit(self.allocator);
        for (self.modules.items) |module| try flattened.appendSlice(self.allocator, module.functions);
        return flattened.toOwnedSlice(self.allocator);
    }

    /// Emitted functions of imported modules get unique symbol names.
    fn prefixNames(self: *Loader, module: *Module, module_index: usize) !void {
        const stem = std.fs.path.stem(module.path);
        for (module.functions) |*function| {
            if (!function.emit_label or function.external) continue;
            const generated = try std.fmt.allocPrint(self.allocator, "zsp_m{d}_{s}__{s}", .{ module_index, stem, function.source_name });
            errdefer self.allocator.free(generated);
            try self.generated_names.append(self.allocator, generated);
            function.name = generated;
        }
    }

    /// Rewrites module-qualified function references to linked names.
    fn resolveCalls(self: *Loader, module_index: usize, statements: []const ast.Statement) anyerror!void {
        for (statements) |*item| {
            // Statement lists are owned, mutable allocations of the module's program.
            const statement = @constCast(item);
            try resolvers.get(std.meta.activeTag(statement.*))(self, module_index, statement);
            const nested = ast_walk.children(statement);
            for (nested.slice()) |list| try self.resolveCalls(module_index, list);
        }
    }

    const Resolver = *const fn (*Loader, usize, *ast.Statement) anyerror!void;

    const resolvers = blk: {
        var table = std.EnumArray(std.meta.Tag(ast.Statement), Resolver).initFill(&resolveNothing);
        table.set(.var_decl, &resolveDeclaration);
        table.set(.assignment, &resolveAssignment);
        table.set(.call, &resolveCall);
        table.set(.builtin, &resolveBuiltin);
        table.set(.conditional_direct_goto, &resolveConditionalDirectGoto);
        break :blk table;
    };

    fn resolveNothing(_: *Loader, _: usize, _: *ast.Statement) !void {}

    fn resolveDeclaration(self: *Loader, module_index: usize, statement: *ast.Statement) !void {
        if (statement.var_decl.value) |*value| try self.resolveValue(module_index, value);
    }

    fn resolveAssignment(self: *Loader, module_index: usize, statement: *ast.Statement) !void {
        const assignment = &statement.assignment;
        try self.resolveValue(module_index, &assignment.lhs);
        if (assignment.rhs) |*rhs| try self.resolveValue(module_index, rhs);
    }

    fn resolveCall(self: *Loader, module_index: usize, statement: *ast.Statement) !void {
        const call = &statement.call;
        var target: ast.FunctionRef = .{ .module = call.module, .name = call.name };
        try self.resolveFunctionRef(module_index, &target);
        call.module = null;
        call.name = target.name;
    }

    fn resolveBuiltin(self: *Loader, module_index: usize, statement: *ast.Statement) !void {
        switch (statement.builtin) {
            .direct_goto => |*branch| try self.resolveFunctionRef(module_index, &branch.target),
            .tail => |*tail| try self.resolveFunctionRef(module_index, &tail.target),
            else => {},
        }
    }

    fn resolveConditionalDirectGoto(self: *Loader, module_index: usize, statement: *ast.Statement) !void {
        try self.resolveFunctionRef(module_index, &statement.conditional_direct_goto.target);
    }

    fn resolveValue(self: *Loader, module_index: usize, value: *ast.Value) !void {
        switch (value.*) {
            .function_address => |*target| try self.resolveFunctionRef(module_index, target),
            .scalar_expression => |expression| {
                try self.resolveValue(module_index, &expression.lhs);
                try self.resolveValue(module_index, &expression.rhs);
            },
            else => {},
        }
    }

    fn resolveFunctionRef(self: *Loader, module_index: usize, target: *ast.FunctionRef) !void {
        const target_module = if (target.module) |alias| try self.resolveImport(module_index, alias) else module_index;
        const function = findSourceFunction(self.modules.items[target_module].functions, target.name) orelse return error.UnknownFunction;
        if (target.module != null and !function.public) return error.PrivateFunction;
        target.module = null;
        target.name = function.name;
    }

    fn resolveImport(self: *Loader, module_index: usize, alias: []const u8) !usize {
        const module = self.modules.items[module_index];
        var result: ?usize = null;
        for (module.imports, module.targets) |import, target| {
            if (!std.mem.eql(u8, import.name, alias)) continue;
            if (result != null) return error.DuplicateImportName;
            result = target;
        }
        return result orelse error.UnknownModule;
    }
};

fn findSourceFunction(functions: []ast.Function, name: []const u8) ?*ast.Function {
    for (functions) |*function| {
        if (std.mem.eql(u8, function.source_name, name)) return function;
    }
    return null;
}

test "module loading links public imports and deduplicates files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "helper.zsp", .data = "pub fn helper() { return; }" });
    try temp.dir.writeFile(io, .{ .sub_path = "root.zsp", .data = "const helpers = import(\"helper.zsp\"); export fn entry() { helpers.helper(); }" });
    const path = try temp.dir.realPathFileAlloc(io, "root.zsp", a);
    defer a.free(path);
    var loader = Loader{ .allocator = a, .io = io, .module_dir = null };
    defer loader.deinit();
    const root = try loader.load(path);
    try std.testing.expectEqual(root, try loader.load(path));
    const functions = try loader.link(root);
    defer a.free(functions);
    try std.testing.expectEqual(@as(usize, 2), loader.modules.items.len);
    try std.testing.expectEqual(@as(usize, 2), functions.len);
    try std.testing.expectEqualStrings(functions[1].name, functions[0].statements[0].call.name);
    try std.testing.expect(functions[0].statements[0].call.module == null);
}

test "failed module parses release partial AST and retain source diagnostics" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "bad.zsp", .data = "fn first() { reg value: u32 = 1; } fn broken() { reg value: u32 = ; }" });
    const path = try temp.dir.realPathFileAlloc(io, "bad.zsp", a);
    defer a.free(path);
    var loader = Loader{ .allocator = a, .io = io, .module_dir = null };
    defer loader.deinit();
    try std.testing.expectError(error.ParseError, loader.load(path));
    try std.testing.expectEqualStrings(path, loader.diagnostic.?.path);
    try std.testing.expectEqualStrings(";", loader.diagnostic.?.detail.token_text);
    try std.testing.expectEqual(@as(usize, 0), loader.modules.items.len);
}

test "module cycles and private targets report semantic errors" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "cycle.zsp", .data = "const cycle = import(\"cycle.zsp\");" });
    try temp.dir.writeFile(io, .{ .sub_path = "private.zsp", .data = "fn hidden() { return; }" });
    try temp.dir.writeFile(io, .{ .sub_path = "root.zsp", .data = "const helper = import(\"private.zsp\"); fn entry() { helper.hidden(); }" });
    const cycle = try temp.dir.realPathFileAlloc(io, "cycle.zsp", a);
    defer a.free(cycle);
    const root_path = try temp.dir.realPathFileAlloc(io, "root.zsp", a);
    defer a.free(root_path);
    var loader = Loader{ .allocator = a, .io = io, .module_dir = null };
    defer loader.deinit();
    try std.testing.expectError(error.ImportCycle, loader.load(cycle));
    const root = try loader.load(root_path);
    try std.testing.expectError(error.PrivateFunction, loader.link(root));
}

test "function addresses resolve through imports" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "lib.zsp", .data = "pub fn run() { return; }" });
    try temp.dir.writeFile(io, .{ .sub_path = "root.zsp", .data =
        \\const lib = import("lib.zsp");
        \\fn entry() { reg target: fn() = &lib.run; target = &lib.run; }
    });
    const path = try temp.dir.realPathFileAlloc(io, "root.zsp", a);
    defer a.free(path);
    var loader = Loader{ .allocator = a, .io = io, .module_dir = null };
    defer loader.deinit();
    const functions = try loader.link(try loader.load(path));
    defer a.free(functions);
    const target = functions[0].statements[0].var_decl.value.?.function_address;
    try std.testing.expect(target.module == null);
    try std.testing.expectEqualStrings(functions[1].name, target.name);
}
