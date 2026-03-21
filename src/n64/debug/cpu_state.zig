

pub const TrapFrame = extern struct {
    /// General-purpose registers (r0–r31)
    gpr: [32]u64,

    /// Multiply/divide result registers
    lo: u64,        // Low result
    hi: u64,        // High result

    /// Processor state
    status: u32,    // Status register (SR)
    cause: u32,     // Cause register (CR)

    /// Exception program counter
    epc: u32,

    /// Floating-point control/status
    fcsr: u32,

    /// Floating-point registers (f0–f31)
    fpr: [32]u64,
};

pub const GprIndex = enum(u5) {
    z0, at, v0, v1,
    a0, a1, a2, a3,
    t0, t1, t2, t3, t4, t5, t6, t7,
    s0, s1, s2, s3, s4, s5, s6, s7,
    t8, t9, k0, k1,
    gp, sp, fp, ra,
};
