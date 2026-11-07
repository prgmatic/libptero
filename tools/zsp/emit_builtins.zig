//! Machine builtins: transfers, breakpoints, COP0/COP2 moves, and vector
//! memory statements.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const calls = @import("emit_calls.zig");
const common = @import("emit_common.zig");
const operands = @import("emit_operands.zig");
const statements_ = @import("emit_statements.zig");
const vectors = @import("emit_vectors.zig");

const Gen = common.Gen;
const Builtin = ast.Builtin;
const Tag = std.meta.Tag(Builtin);

pub fn writeBuiltin(g: Gen, builtin: Builtin) !void {
    return writers.get(std.meta.activeTag(builtin))(g, builtin);
}

const Writer = *const fn (Gen, Builtin) anyerror!void;

const writers = std.EnumArray(Tag, Writer).init(.{
    .nop = &nop,
    .breakpoint = &breakpoint,
    .jump = &jump,
    .indirect_call = &indirectCall,
    .return_from_function = &returnFromFunction,
    .direct_goto = &directGoto,
    .tail = &tail,
    .write_vector_control = &writeVectorControl,
    .vector_memory = &vectorMemory,
    .hardware_write = &hardwareWrite,
    .hardware_read_register = &hardwareReadRegister,
    .hardware_write_register = &hardwareWriteRegister,
});

fn nop(g: Gen, _: Builtin) !void {
    try g.out.nop();
}

fn breakpoint(g: Gen, builtin: Builtin) !void {
    try g.out.breakpoint(builtin.breakpoint);
}

fn jump(g: Gen, builtin: Builtin) !void {
    const transfer = builtin.jump;
    try g.out.jumpRegister(.jr, try operands.valueAsAddressReg(g, transfer.address));
    try statements_.writeDelaySlot(g, transfer.delay_slot);
}

fn indirectCall(g: Gen, builtin: Builtin) !void {
    const call = builtin.indirect_call;
    try g.out.jumpRegister(.jalr, try operands.valueAsAddressReg(g, call.address));
    try statements_.writeDelaySlot(g, call.delay_slot);
}

fn returnFromFunction(g: Gen, builtin: Builtin) !void {
    try g.out.jumpRegister(.jr, .ra);
    try statements_.writeDelaySlot(g, builtin.return_from_function);
}

fn directGoto(g: Gen, builtin: Builtin) !void {
    const branch = builtin.direct_goto;
    try common.expectLocal(branch.target.module);
    if (branch.typed) try calls.writeFunctionArguments(g, try common.findFunction(g, branch.target.name), branch.arguments, true, branch.delay_slot);
    try g.out.jump(if (branch.encoding == .jump) .j else .b, branch.target.name);
    try statements_.writeDelaySlot(g, branch.delay_slot);
}

/// A tail call to the function placed next falls through; its slot
/// statement still executes.
fn tail(g: Gen, builtin: Builtin) !void {
    const transfer = builtin.tail;
    try common.expectLocal(transfer.target.module);
    const function = try common.findFunction(g, transfer.target.name);
    if (function.inline_call) return error.CannotTailInlineFunction;
    try calls.writeFunctionArguments(g, function, transfer.arguments, true, transfer.delay_slot);
    if (!calls.isOmittedTail(g, transfer.target.name)) {
        try g.out.jump(.j, transfer.target.name);
        return statements_.writeDelaySlot(g, transfer.delay_slot);
    }
    try statements_.writeStructuredDelaySlot(g, transfer.delay_slot);
}

fn writeVectorControl(g: Gen, builtin: Builtin) !void {
    const write = builtin.write_vector_control;
    try g.out.controlMove(.ctc2, try operands.valueAsAddressReg(g, write.value), @intFromEnum(write.register));
}

fn vectorMemory(g: Gen, builtin: Builtin) !void {
    const memory = builtin.vector_memory;
    const vector = try g.lookup(memory.vector.name);
    if (memory.vector.lane != null) return error.PartialVectorMemoryRequiresVec16;
    const reg = try analysis.vectorRegisterForView(vector, memory.vector.view);
    if (vector.data_type != .vec16 and memory.vector.view == null) return error.PartialVectorMemoryRequiresVec16;
    if (memory.operation == .load_transpose) _ = try analysis.reserveTransposeBank(g.context, vector, reg);
    const base = try operands.valueAsDmemReg(g, memory.address);
    try vectors.writeVectorMemoryOperation(g, memory.operation, reg, memory.lane, base, memory.offset);
}

fn hardwareWrite(g: Gen, builtin: Builtin) !void {
    const write = builtin.hardware_write;
    const source = if (write.requires_dmem)
        try operands.valueAsDmemReg(g, write.value)
    else
        try operands.valueAsAddressReg(g, write.value);
    try g.out.cop0(.mtc0, source, write.operation.cp0);
}

fn hardwareReadRegister(g: Gen, builtin: Builtin) !void {
    const transfer = builtin.hardware_read_register;
    try g.out.cop0(.mfc0, transfer.destination, transfer.hardware_register);
}

fn hardwareWriteRegister(g: Gen, builtin: Builtin) !void {
    const transfer = builtin.hardware_write_register;
    try g.out.cop0(.mtc0, transfer.source, transfer.hardware_register);
}
