const std = @import("std");
const ast = @import("ast.zig");
const asm_writer = @import("asm_writer.zig");
const asm_optimizer = @import("asm_optimizer.zig");
const parser_mod = @import("parser.zig");

const ModuleState = enum {
    loading,
    loaded,
};

const Module = struct {
    path: []u8,
    source: []u8,
    functions: []ast.Function,
    imports: []ast.Import,
    targets: []usize,
    state: ModuleState,
};

const Loader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    module_dir: ?[]const u8,
    modules: std.ArrayList(Module) = .empty,
    generated_names: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Loader) void {
        for (self.generated_names.items) |name| self.allocator.free(name);
        self.generated_names.deinit(self.allocator);
        for (self.modules.items) |module| {
            self.allocator.free(module.targets);
            self.allocator.free(module.imports);
            ast.freeFunctions(self.allocator, module.functions);
            self.allocator.free(module.source);
            self.allocator.free(module.path);
        }
        self.modules.deinit(self.allocator);
    }

    fn load(self: *Loader, path: []const u8) anyerror!usize {
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

        var parser = try parser_mod.Parser.init(self.allocator, source);
        const functions = parser.parse() catch |err| {
            reportParseError(&parser, resolved);
            return err;
        };
        errdefer if (!appended) ast.freeFunctions(self.allocator, functions);
        const imports = try parser.takeImports();
        errdefer if (!appended) self.allocator.free(imports);
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
        });
        appended = true;

        for (imports, 0..) |import, import_index| {
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

    fn link(self: *Loader, root: usize) ![]ast.Function {
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
                    .call_and_goto => |*call| {
                        try self.resolveFunctionRef(module_index, &call.callee);
                        try self.resolveFunctionRef(module_index, &call.continuation);
                    },
                    .tail => |*tail| {
                        try self.resolveFunctionRef(module_index, &tail.target);
                    },
                    .set_function_address => |*set_address| {
                        try self.resolveFunctionRef(module_index, &set_address.target);
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 2) return usage();
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var module_dir: ?[]const u8 = null;
    var depfile: ?[]const u8 = null;
    var optimize = true;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--module-dir")) {
            i += 1;
            if (i >= args.len) return usage();
            module_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--depfile")) {
            i += 1;
            if (i >= args.len) return usage();
            depfile = args[i];
        } else if (std.mem.eql(u8, args[i], "--no-optimize")) {
            optimize = false;
        } else if (input == null) {
            input = args[i];
        } else if (output == null) {
            output = args[i];
        } else {
            return usage();
        }
    }
    const input_path = input orelse return usage();

    var loader = Loader{
        .allocator = allocator,
        .io = init.io,
        .module_dir = module_dir,
    };
    defer loader.deinit();
    const root = try loader.load(input_path);
    const functions = try loader.link(root);
    defer allocator.free(functions);

    if (depfile) |depfile_path| {
        try writeDepfile(init.io, depfile_path, output orelse "zsp-output", loader.modules.items);
    }

    var out_buf: [4096]u8 = undefined;
    if (output) |output_path| {
        var out_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
        defer out_file.close(init.io);
        var writer = out_file.writer(init.io, &out_buf);
        try writeAssembly(allocator, &writer.interface, functions, optimize);
        try writer.interface.flush();
    } else {
        var writer = std.Io.File.stdout().writer(init.io, &out_buf);
        try writeAssembly(allocator, &writer.interface, functions, optimize);
        try writer.interface.flush();
    }
}

fn usage() error{InvalidArgs} {
    std.debug.print(
        "usage: zsp <input.zsp> [--module-dir <dir>] [--depfile <file>] [--no-optimize] [output.s]\n",
        .{},
    );
    return error.InvalidArgs;
}

fn writeAssembly(allocator: std.mem.Allocator, writer: *std.Io.Writer, functions: []const ast.Function, optimize: bool) !void {
    if (!optimize) return asm_writer.write(writer, functions);
    var unoptimized = std.Io.Writer.Allocating.init(allocator);
    defer unoptimized.deinit();
    try asm_writer.write(&unoptimized.writer, functions);
    try asm_optimizer.writeOptimized(allocator, writer, unoptimized.written());
}

fn writeDepfile(io: std.Io, path: []const u8, target: []const u8, modules: []const Module) !void {
    var buffer: [4096]u8 = undefined;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var writer = file.writer(io, &buffer);
    try writer.interface.print("{s}:", .{target});
    for (modules) |module| try writer.interface.print(" {s}", .{module.path});
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn reportParseError(parser: *const parser_mod.Parser, path: []const u8) void {
    if (parser.diagnostic) |diagnostic| {
        std.debug.print("{s}:{d}:{d}: {s}: '{s}'\n", .{
            path,
            diagnostic.line,
            diagnostic.column,
            parser_mod.errorString(diagnostic.err),
            diagnostic.token_text,
        });
    }
}

fn findSourceFunction(functions: []ast.Function, name: []const u8) ?*ast.Function {
    for (functions) |*function| {
        if (std.mem.eql(u8, function.source_name, name)) return function;
    }
    return null;
}
