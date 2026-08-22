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
        if (std.mem.eql(u8, trimmed, ".text")) {
            in_text = true;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, ".section") or
            std.mem.eql(u8, trimmed, ".data") or
            std.mem.eql(u8, trimmed, ".bss"))
        {
            in_text = false;
            continue;
        }
        if (!in_text or trimmed.len == 0 or trimmed[0] == '#' or
            std.mem.endsWith(u8, trimmed, ":")) continue;
        if (trimmed[0] != '.' or std.mem.startsWith(u8, trimmed, ".word")) {
            instruction_count += 1;
        }
    }
    return .{
        .instruction_count = instruction_count,
        .text_bytes = instruction_count * 4,
    };
}

pub fn errorHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.OutOfFreeRegisters,
        error.OutOfFreeRegistersInExpression,
        => "scalar register allocation failed; shorten overlapping live ranges, split the expression, or pin fewer locals",
        error.OutOfFreeVectorRegisters =>
            "vector register allocation failed; shorten overlapping vector live ranges or pin fewer vectors",
        error.RegisterAlreadyInUse =>
            "explicit register lifetimes overlap; remove one pin or move a declaration past the other value's last use",
        error.RegisterReadBeforeAssignment =>
            "register may be read before every control-flow path assigns it; initialize it or assign it in every path",
        error.PinnedRegisterOverwrittenByCallArgument =>
            "a live pinned value overlaps a call argument register; move the value, shorten its lifetime, or change the ABI pin",
        error.PinnedRegisterClobberedByCall,
        error.PinnedRegisterClobberedByExternalCall,
        error.AutomaticRegisterClobberedByCall,
        => "a value live across this call uses a clobbered register; declare an accurate clobbers() contract or shorten the live range",
        error.FunctionArgumentCountMismatch =>
            "transfer argument count does not match the target function ABI",
        error.FunctionArgumentTypeMismatch =>
            "transfer argument type does not match the target function ABI",
        error.FunctionArgumentRegisterMismatch =>
            "transfer argument is not in the register required by the target ABI",
        error.UnknownFunction, error.UnknownModule, error.UnresolvedModuleCall =>
            "transfer target could not be resolved; check its import alias, visibility, and spelling",
        error.PrivateFunction =>
            "an imported transfer target must be declared pub",
        error.ImemOverflow =>
            "emitted text exceeds the RSP's 4096-byte IMEM capacity; reduce code or split it into overlays",
        else => null,
    };
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
        "clobbers()",
    ) != null);
    try std.testing.expect(errorHint(error.NotDir) == null);
}
