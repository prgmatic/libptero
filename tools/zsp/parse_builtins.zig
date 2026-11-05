//! Statement builtins under `rsp`, `rsp.cp0`, and `rsp.vector`.
const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const parser_mod = @import("parser.zig");

const Parser = parser_mod.Parser;

/// `@name(...)` statements; none are currently supported.
pub fn parseBuiltinStatement(self: *Parser) !ast.Statement {
    const name = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    return self.fail(name, .unsupported_builtin);
}

/// `rsp.halt(code)` and `rsp.nop()`.
pub fn parseRspStatement(self: *Parser, operation: token.Token) !ast.Statement {
    _ = try self.expect(.l_paren);
    const statement = try parseRspOperation(self, operation);
    try expectCallEnd(self);
    return statement;
}

fn parseRspOperation(self: *Parser, operation: token.Token) !ast.Statement {
    if (std.mem.eql(u8, operation.text, "nop")) return .{ .builtin = .nop };
    if (!std.mem.eql(u8, operation.text, "halt")) return self.fail(operation, .unsupported_builtin);
    const code = if (self.current.tag != .r_paren) try self.parseNumberValue(try self.expect(.number)) else 0;
    if (code < 0 or code > 0xfffff) return error.InvalidBreakCode;
    return .{ .builtin = .{ .breakpoint = @intCast(code) } };
}

fn expectCallEnd(self: *Parser) !void {
    _ = try self.expect(.r_paren);
    _ = try self.expect(.semicolon);
}

// ------------------------------------------------------------------- cp0

/// `rsp.cp0.readRegister(n, $reg)`, `writeRegister(n, $reg)`,
/// `write(n, value)`, and the named writes such as `setSpStatus(value)`.
pub fn parseCp0Statement(self: *Parser, operation_name: token.Token) !ast.Statement {
    _ = try self.expect(.l_paren);
    const statement = try parseCp0Operation(self, operation_name);
    try expectCallEnd(self);
    return statement;
}

fn parseCp0Operation(self: *Parser, operation_name: token.Token) !ast.Statement {
    const name = operation_name.text;
    if (std.mem.eql(u8, name, "readRegister")) return parseRegisterTransfer(self, .read);
    if (std.mem.eql(u8, name, "writeRegister")) return parseRegisterTransfer(self, .write);
    if (std.mem.eql(u8, name, "write")) return parseNumberedWrite(self);
    const register = parser_mod.cp0NamedWriteRegister(name) orelse return self.fail(operation_name, .unsupported_builtin);
    return hardwareWrite(register, try self.parseValueRef(), register == 0);
}

fn hardwareWrite(register: u4, value: ast.ValueRef, requires_dmem: bool) ast.Statement {
    return .{ .builtin = .{ .hardware_write = .{ .operation = .{ .cp0 = register }, .value = value, .requires_dmem = requires_dmem } } };
}

fn parseHardwareRegisterIndex(self: *Parser) !u4 {
    const register_token = try self.expect(.number);
    const register = try self.parseNumberValue(register_token);
    if (register < 0 or register > 15) return self.fail(register_token, .invalid_hardware_register);
    _ = try self.expect(.comma);
    return @intCast(register);
}

fn parseRegisterTransfer(self: *Parser, direction: enum { read, write }) !ast.Statement {
    const hardware_register = try parseHardwareRegisterIndex(self);
    const scalar_token = try self.expect(.register);
    const scalar = parser_mod.parseRegister(scalar_token) orelse return self.fail(scalar_token, .expected_scalar_register);
    if (direction == .read) {
        return .{ .builtin = .{ .hardware_read_register = .{ .hardware_register = hardware_register, .destination = scalar } } };
    }
    return .{ .builtin = .{ .hardware_write_register = .{ .hardware_register = hardware_register, .source = scalar } } };
}

fn parseNumberedWrite(self: *Parser) !ast.Statement {
    const register = try parseHardwareRegisterIndex(self);
    return hardwareWrite(register, try self.parseValueRef(), false);
}

// ---------------------------------------------------------------- vector

const VectorMemory = @FieldType(ast.Builtin, "vector_memory");

/// `rsp.vector.setCarryOut(value)` and the like, or a vector load or
/// store such as `rsp.vector.load64(v, lane, address, offset)`.
pub fn parseVectorStatement(self: *Parser, operation_name: token.Token) !ast.Statement {
    _ = try self.expect(.l_paren);
    const statement = try parseVectorOperation(self, operation_name);
    try expectCallEnd(self);
    return statement;
}

fn parseVectorOperation(self: *Parser, operation_name: token.Token) !ast.Statement {
    if (parser_mod.vectorControlRegisterForOperation(operation_name.text, "set")) |register| {
        return .{ .builtin = .{ .write_vector_control = .{ .register = register, .value = try self.parseValueRef() } } };
    }
    const operation = parser_mod.vectorMemoryOperationForBuiltin(operation_name.text) orelse
        return self.fail(operation_name, .unsupported_builtin);
    return .{ .builtin = .{ .vector_memory = try parseVectorMemory(self, operation) } };
}

fn parseVectorMemory(self: *Parser, operation: ast.VectorMemoryOperation) !VectorMemory {
    const vector_token = self.current;
    const vector = try parser_mod.vectorAccessFromRef(try self.parseValueRef()) orelse
        return self.fail(vector_token, .expected_vector_operand);
    _ = try self.expect(.comma);
    const lane: u3 = if (parser_mod.vectorMemoryOperationHasLane(operation)) try parseVectorLane(self) else 0;
    const address = try self.parseValueRef();
    const offset = if (try self.eat(.comma)) try self.parseLiteralOffset() else 0;
    return .{ .operation = operation, .vector = vector, .lane = lane, .address = address, .offset = offset };
}

fn parseVectorLane(self: *Parser) !u3 {
    const lane_token = try self.expect(.number);
    const lane = try self.parseNumberValue(lane_token);
    if (lane < 0 or lane > 7) return self.fail(lane_token, .invalid_vector_lane);
    _ = try self.expect(.comma);
    return @intCast(lane);
}
