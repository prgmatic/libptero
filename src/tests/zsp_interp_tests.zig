//! Executes the shared standalone ZSP program cases in the host RSP
//! interpreter. The same table runs on hardware in `zsp_tests.zig`, so these
//! tests check both the compiler output and the interpreter's fidelity.
const std = @import("std");
const interp = @import("rsp_interp");
const programs = @import("zsp_host_programs");
const cases = @import("zsp_program_cases.zig");

const instruction_limit = 100_000;

fn runCase(comptime case: cases.Case) !interp.RunResult {
    var rdram: [64]u8 = @splat(0);
    var machine = interp.Machine.init(&rdram);
    if (case.seed) |seed| machine.writeDmem(u32, seed.offset, seed.value);
    machine.load(interp.Program.fromBlob(@field(programs, case.program)));
    machine.start(machine.pc);
    const result = try machine.run(instruction_limit);
    try std.testing.expectEqual(interp.Stop.broke, result.stop);
    for (case.checks) |check| {
        try std.testing.expectEqualSlices(u8, check.expected, machine.dmem[check.offset..][0..check.expected.len]);
    }
    for (case.orderings) |ordering| {
        const smaller = machine.readDmem(u32, ordering.smaller);
        const larger = machine.readDmem(u32, ordering.larger);
        if (smaller > larger + ordering.slack) std.debug.print("\"{s}\": {d} > {d}\n", .{ case.name, smaller, larger });
        try std.testing.expect(smaller <= larger + ordering.slack);
    }
    return result;
}

test "standalone ZSP programs match their hardware expectations" {
    inline for (cases.all) |case| {
        _ = runCase(case) catch |err| {
            std.debug.print("ZSP program case \"{s}\" failed\n", .{case.name});
            return err;
        };
    }
}
