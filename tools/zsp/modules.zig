const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");

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
        var appended = false;
        errdefer if (!appended) self.allocator.free(resolved);

        for (self.modules.items, 0..) |module, index| {
            if (!std.mem.eql(u8, module.path, resolved)) continue;
            self.allocator.free(resolved);
            appended = true;
            if (module.state == .loading) return error.ImportCycle;
            return index;
        }

        const source = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            resolved,
            self.allocator,
            .limited(1024 * 1024),
        );
        errdefer if (!appended) self.allocator.free(source);

        var parse_diagnostic: ?parser_mod.Diagnostic = null;
        var program = @import("source.zig").Program.parse(self.allocator, source, &parse_diagnostic) catch |err| {
            if (parse_diagnostic) |detail| try self.saveDiagnostic(resolved, detail);
            return err;
        };
        errdefer if (!appended) program.deinit();
        const functions = program.functions;
        const imports = program.imports;
        for (functions) |*function| function.source_path = resolved;
        const targets = try self.allocator.alloc(usize, imports.len);
        errdefer if (!appended) self.allocator.free(targets);

        const index = self.modules.items.len;
        try self.modules.append(self.allocator, .{
            .path = resolved,
            .source = source,
            .functions = functions,
            .imports = imports,
            .targets = targets,
            .state = .loading,
            .program = program,
        });
        appended = true;

        for (imports, 0..) |import, import_index| {
            if (self.module_override_name) |override_name| {
                if (std.mem.eql(u8, import.path, override_name)) {
                    self.modules.items[index].targets[import_index] = try self.load(self.module_override_path.?);
                    continue;
                }
            }
            const parent = std.fs.path.dirname(resolved) orelse ".";
            const relative = try std.fs.path.resolve(self.allocator, &.{ parent, import.path });
            defer self.allocator.free(relative);
            const target = self.load(relative) catch |err| switch (err) {
                error.FileNotFound => if (self.module_dir) |module_dir| blk: {
                    const fallback = try std.fs.path.resolve(self.allocator, &.{ module_dir, import.path });
                    defer self.allocator.free(fallback);
                    break :blk try self.load(fallback);
                } else return err,
                else => return err,
            };
            self.modules.items[index].targets[import_index] = target;
        }
        self.modules.items[index].state = .loaded;
        return index;
    }

    pub fn link(self: *Loader, root: usize) ![]ast.Function {
        for (self.modules.items, 0..) |*module, module_index| {
            if (module_index == root) continue;
            const stem = std.fs.path.stem(module.path);
            for (module.functions) |*function| {
                if (!function.emit_label or function.external) continue;
                const generated = try std.fmt.allocPrint(
                    self.allocator,
                    "zsp_m{d}_{s}__{s}",
                    .{ module_index, stem, function.source_name },
                );
                try self.generated_names.append(self.allocator, generated);
                function.name = generated;
            }
        }

        for (self.modules.items, 0..) |*module, module_index| {
            for (module.functions) |*function| {
                try self.resolveCalls(module_index, function.statements);
            }
        }

        var flattened: std.ArrayList(ast.Function) = .empty;
        errdefer flattened.deinit(self.allocator);
        for (self.modules.items) |module| {
            try flattened.appendSlice(self.allocator, module.functions);
        }
        return flattened.toOwnedSlice(self.allocator);
    }

    fn resolveCalls(self: *Loader, module_index: usize, statements: []ast.Statement) anyerror!void {
        for (statements) |*statement| {
            switch (statement.*) {
                .var_decl => |*declaration| if (declaration.value) |*value| {
                    try self.resolveValue(module_index, value);
                },
                .assignment => |*assignment| {
                    try self.resolveValue(module_index, &assignment.lhs);
                    if (assignment.rhs) |*rhs| try self.resolveValue(module_index, rhs);
                },
                .call => |*call| {
                    var target_module = module_index;
                    if (call.module) |alias| {
                        target_module = try self.resolveImport(module_index, alias);
                    }
                    const function = findSourceFunction(
                        self.modules.items[target_module].functions,
                        call.name,
                    ) orelse return error.UnknownFunction;
                    if (call.module != null and !function.public) return error.PrivateFunction;
                    call.module = null;
                    call.name = function.name;
                    if (call.delay_slot) |delay_slot| try self.resolveCalls(module_index, delay_slot);
                },
                .builtin => |*builtin| switch (builtin.*) {
                    .direct_goto => |*branch| {
                        try self.resolveFunctionRef(module_index, &branch.target);
                        if (branch.delay_slot) |delay_slot| try self.resolveCalls(module_index, delay_slot);
                    },
                    .tail => |*tail| {
                        try self.resolveFunctionRef(module_index, &tail.target);
                        if (tail.delay_slot) |delay_slot| try self.resolveCalls(module_index, delay_slot);
                    },
                    .jump => |*jump| {
                        if (jump.delay_slot) |delay_slot| try self.resolveCalls(module_index, delay_slot);
                    },
                    .return_from_function => |delay_slot| if (delay_slot) |return_statements| {
                        try self.resolveCalls(module_index, return_statements);
                    },
                    else => {},
                },
                .while_loop => |*loop| try self.resolveCalls(module_index, loop.statements),
                .do_while_loop => |*loop| {
                    try self.resolveCalls(module_index, loop.statements);
                    if (loop.delay_slot) |delay| try self.resolveCalls(module_index, delay);
                },
                .labeled_block => |*block| {
                    try self.resolveCalls(module_index, block.statements);
                    if (block.exit_delay) |delay| try self.resolveCalls(module_index, delay);
                },
                .break_loop => |*transfer| if (transfer.delay_slot) |delay| try self.resolveCalls(module_index, delay),
                .ordered_block => |ordered| try self.resolveCalls(module_index, ordered),
                .goto => |*branch| if (branch.delay_slot) |delay_slot| {
                    try self.resolveCalls(module_index, delay_slot);
                },
                .conditional_goto => |*branch| if (branch.delay_slot) |delay_slot| {
                    try self.resolveCalls(module_index, delay_slot);
                },
                .conditional_direct_goto => |*branch| {
                    try self.resolveFunctionRef(module_index, &branch.target);
                    if (branch.delay_slot) |delay_slot| try self.resolveCalls(module_index, delay_slot);
                },
                .if_statement => |*if_statement| {
                    if (if_statement.delay_slot) |delay_slot| try self.resolveCalls(module_index, delay_slot);
                    try self.resolveCalls(module_index, if_statement.then_statements);
                    if (if_statement.else_statements) |else_statements| {
                        try self.resolveCalls(module_index, else_statements);
                    }
                },
                else => {},
            }
        }
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
        var target_module = module_index;
        if (target.module) |alias| {
            target_module = try self.resolveImport(module_index, alias);
        }
        const function = findSourceFunction(
            self.modules.items[target_module].functions,
            target.name,
        ) orelse return error.UnknownFunction;
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
