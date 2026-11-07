const std = @import("std");

pub const AssemblyReport = struct {
    instruction_count: usize,
    text_bytes: usize,
};

pub fn analyzeAssembly(assembly: []const u8) AssemblyReport {
    var in_text = false;
    var instruction_count: usize = 0;
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (sectionChange(trimmed)) |text| {
            in_text = text;
        } else if (in_text and isInstructionLine(trimmed)) {
            instruction_count += 1;
        }
    }
    return .{ .instruction_count = instruction_count, .text_bytes = instruction_count * 4 };
}

/// True on entering `.text`, false on entering another section.
fn sectionChange(line: []const u8) ?bool {
    if (std.mem.eql(u8, line, ".text")) return true;
    if (std.mem.startsWith(u8, line, ".section") or std.mem.eql(u8, line, ".data") or std.mem.eql(u8, line, ".bss")) return false;
    return null;
}

/// Instructions and `.word`-encoded instructions; not labels, comments, or
/// other directives.
fn isInstructionLine(line: []const u8) bool {
    if (line.len == 0 or line[0] == '#' or std.mem.endsWith(u8, line, ":")) return false;
    return line[0] != '.' or std.mem.startsWith(u8, line, ".word");
}

const error_hints = std.StaticStringMap([]const u8).initComptime(.{
    .{ "AnalysisCapacityExceeded", "function exceeds compiler analysis capacity; split it into smaller functions" },
    .{ "OutOfFreeRegisters", "scalar register allocation failed; shorten overlapping live ranges, split the expression, or pin fewer locals" },
    .{ "OutOfFreeRegistersInExpression", "scalar register allocation failed; shorten overlapping live ranges, split the expression, or pin fewer locals" },
    .{ "OutOfFreeVectorRegisters", "no vector register is free for this value (vector values never spill); end a listed value's live range earlier, reuse one for this temporary, or avoid the unavailable registers" },
    .{ "RegisterAlreadyInUse", "explicit register lifetimes overlap; remove one pin or move a declaration past the other value's last use" },
    .{ "RegisterReadBeforeAssignment", "register may be read before every control-flow path assigns it; initialize it or assign it in every path" },
    .{ "PinnedRegisterOverwrittenByCallArgument", "a live pinned value overlaps a call argument register; move the value, shorten its lifetime, or change the parameter register" },
    .{ "PinnedRegisterClobberedByCall", "a value live across this call uses a written register; declare an accurate writes() contract or shorten the live range" },
    .{ "PinnedRegisterClobberedByExternalCall", "a value live across this call uses a written register; declare an accurate writes() contract or shorten the live range" },
    .{ "AutomaticRegisterClobberedByCall", "a value live across this call uses a written register; declare an accurate writes() contract or shorten the live range" },
    .{ "PreservedFunctionHasNoContract", "preserves() needs a function with a writes() contract, such as one imported from a generated interface" },
    .{ "DelaySlotAssignsMovedArgument", "a delay slot assigns an argument that must be moved into its parameter register before the transfer; assign it before the transfer, or pin it to the parameter register" },
    .{ "FunctionArgumentCountMismatch", "transfer argument count does not match the target function signature" },
    .{ "FunctionArgumentTypeMismatch", "transfer argument type does not match the target function signature" },
    .{ "ConditionalTailArgumentConflict", "a conditional tail call's argument setup conflicts with its condition; compute the condition into another register or pass fewer arguments" },
    .{ "FunctionArgumentRegisterMismatch", "a vector or callee-written argument is not in the register required by the target function signature" },
    .{ "FunctionArgumentMoveCycle", "scalar argument moves form a register cycle and no backend scratch register is free to break it; reorder the values or pass one in a different register" },
    .{ "UnknownFunction", "transfer target could not be resolved; check its import alias, visibility, and spelling" },
    .{ "UnknownModule", "transfer target could not be resolved; check its import alias, visibility, and spelling" },
    .{ "UnresolvedModuleCall", "transfer target could not be resolved; check its import alias, visibility, and spelling" },
    .{ "PrivateFunction", "an imported transfer target must be declared pub" },
    .{ "ImemOverflow", "emitted text exceeds the RSP's 4096-byte IMEM capacity; reduce code or split it into overlays" },
    .{ "InvalidSlot", "a slot must contain exactly one source statement" },
    .{ "MissingSharedExitSlot", "the terminal transfer requires the labeled block's shared exit slot" },
    .{ "UnnecessarySlot", "an explicit slot containing only rsp.nop() has no program effect; omit it and let the optimizer fill the hardware slot" },
    .{ "ExpectedDmemAddress", "RSP memory operations require a value of type dmem; use dmem.addressOf(...) for a data symbol" },
    .{ "DmemAddressOutOfRange", "a literal DMEM address must be between 0 and 4095" },
});

pub fn errorHint(err: anyerror) ?[]const u8 {
    return error_hints.get(@errorName(err));
}

test "assembly report counts final text instructions and raw words" {
    const report = analyzeAssembly(
        \\.data
        \\  .word 1
        \\.text
        \\start:
        \\  addiu $t0, $zero, 1
        \\  .word 0x4a000000
        \\# comment
        \\.section .zsp_commands,"",@progbits
        \\  .word start
    );
    try std.testing.expectEqual(@as(usize, 2), report.instruction_count);
    try std.testing.expectEqual(@as(usize, 8), report.text_bytes);
}

test "backend errors provide focused remedies" {
    try std.testing.expect(std.mem.indexOf(
        u8,
        errorHint(error.OutOfFreeRegisters).?,
        "live ranges",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        errorHint(error.PinnedRegisterClobberedByCall).?,
        "writes()",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        errorHint(error.FunctionArgumentRegisterMismatch).?,
        "callee-written",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        errorHint(error.FunctionArgumentMoveCycle).?,
        "cycle",
    ) != null);
    try std.testing.expect(errorHint(error.NotDir) == null);
}
