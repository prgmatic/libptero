const std = @import("std");
const ast = @import("ast.zig");

pub const max_commands = 240;

pub const Command = struct {
    function: *const ast.Function,
    size: u8,
};

/// Facts established by RSPQ semantic analysis. Entries retain command-index
/// order for table layout while each entry points back to its source function.
pub const CommandAnalysis = struct {
    table_name: ?[]const u8 = null,
    entries: [max_commands]?Command = @splat(null),
    table_len: usize = 0,

    pub fn find(self: *const CommandAnalysis, index: u8) ?Command {
        return self.entries[index];
    }

    fn addFunction(self: *CommandAnalysis, function: *const ast.Function) !void {
        if (function.command_indices.len == 0) return;
        try validateCommandFunction(function.*);
        for (function.command_indices, 0..) |index, command_position| {
            if (self.entries[index] != null) return error.DuplicateCommandIndex;
            self.entries[index] = .{ .function = function, .size = commandSize(function.*, command_position) };
            self.table_len = @max(self.table_len, @as(usize, index) + 1);
        }
    }
};

/// Resolves the single RSPQ command-table declaration and validates every command's
/// index, encoded size, and parameter ABI before assembly emission begins.
pub fn analyzeCommands(functions: []const ast.Function) !CommandAnalysis {
    var result = CommandAnalysis{ .table_name = try findCommandTable(functions) };
    for (functions) |*function| try result.addFunction(function);
    if (result.table_name != null and result.table_len == 0) return error.EmptyCommandTable;
    return result;
}

fn findCommandTable(functions: []const ast.Function) !?[]const u8 {
    var name: ?[]const u8 = null;
    for (functions) |function| for (function.statements) |statement| {
        if (statement != .command_table_decl) continue;
        if (name != null) return error.MultipleCommandTables;
        name = statement.command_table_decl;
    };
    return name;
}

fn commandSize(function: ast.Function, command_position: usize) u8 {
    if (function.command_sizes.len == 0) return @intCast(function.parameters.len * 4);
    if (function.command_sizes.len == 1) return function.command_sizes[0];
    return function.command_sizes[command_position];
}

fn validateCommandFunction(function: ast.Function) !void {
    if (function.inline_call) return error.InvalidCommandFunction;
    if (!validCommandSizes(function) or !validCommandParameters(function.parameters)) return error.InvalidCommandParameters;
}

/// One size for every index, or one per index; each a whole number of
/// words holding at least the parameters.
fn validCommandSizes(function: ast.Function) bool {
    const count = function.command_sizes.len;
    if (count > 1 and count != function.command_indices.len) return false;
    for (function.command_sizes) |size| {
        if (!validCommandSize(size, function.parameters.len)) return false;
    }
    return true;
}

fn validCommandSize(size: u8, parameter_count: usize) bool {
    return size != 0 and size & 3 == 0 and size >= parameter_count * 4;
}

fn validCommandParameters(parameters: []const ast.Parameter) bool {
    if (parameters.len > 63) return false;
    for (parameters, 0..) |parameter, index| {
        if (!validCommandParameter(parameter, index)) return false;
    }
    return true;
}

/// The queue passes a command's first four words in `$a0`-`$a3`; later
/// words stay in DMEM, so their parameters must be unnamed.
fn validCommandParameter(parameter: ast.Parameter, index: usize) bool {
    if (isVectorType(parameter.data_type)) return false;
    if (index >= 4) return std.mem.eql(u8, parameter.name, "_");
    return parameter.reg == @as(ast.Register, @enumFromInt(@intFromEnum(ast.Register.a0) + index));
}

fn isVectorType(data_type: ast.DataType) bool {
    return data_type == .vec16 or data_type == .vec32;
}

fn testFunction(name: []const u8, indices: []const u8, sizes: []const u8, parameters: []const ast.Parameter) ast.Function {
    return .{
        .name = name,
        .source_name = name,
        .export_symbol = false,
        .public = false,
        .inline_call = false,
        .no_return = false,
        .command_indices = indices,
        .command_sizes = sizes,
        .parameters = parameters,
        .statements = &.{},
    };
}

test "command analysis normalizes sizes and retains index order" {
    const parameters = [_]ast.Parameter{
        .{ .name = "header", .data_type = .u32, .reg = .a0 },
    };
    const functions = [_]ast.Function{
        testFunction("first", &.{ 2, 0 }, &.{8}, &parameters),
        testFunction("second", &.{1}, &.{}, &.{}),
    };

    const analysis = try analyzeCommands(&functions);
    try std.testing.expectEqual(@as(usize, 3), analysis.table_len);
    try std.testing.expectEqualStrings("first", analysis.find(0).?.function.name);
    try std.testing.expectEqual(@as(u8, 8), analysis.find(2).?.size);
    try std.testing.expectEqual(@as(u8, 0), analysis.find(1).?.size);
}

test "command analysis rejects duplicate indices independently of emission" {
    const functions = [_]ast.Function{
        testFunction("first", &.{7}, &.{}, &.{}),
        testFunction("second", &.{7}, &.{}, &.{}),
    };
    try std.testing.expectError(error.DuplicateCommandIndex, analyzeCommands(&functions));
}

test "command analysis validates the parameter ABI" {
    const parameters = [_]ast.Parameter{
        .{ .name = "header", .data_type = .u32, .reg = .a1 },
    };
    const functions = [_]ast.Function{
        testFunction("bad", &.{0}, &.{}, &parameters),
    };
    try std.testing.expectError(error.InvalidCommandParameters, analyzeCommands(&functions));
}
