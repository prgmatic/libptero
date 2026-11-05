//! Host-side RSP interpreter for behavior and differential testing of
//! microcode. See README.md for scope and fidelity notes.
pub const Machine = @import("Machine.zig");
pub const Program = @import("rsp_abi").Program;
pub const Error = Machine.Error;
pub const Stop = Machine.Stop;
pub const RunResult = Machine.RunResult;
pub const vector = @import("vector.zig");
pub const encode = @import("encode.zig");
pub const timing = @import("timing.zig");
pub const Profile = @import("Profile.zig");
pub const Session = @import("Session.zig");
pub const calibration = @import("calibration.zig");

test {
    _ = @import("vector.zig");
    _ = @import("vu_state.zig");
    _ = @import("vu_multiply.zig");
    _ = @import("vu_arith.zig");
    _ = @import("vu_divide.zig");
    _ = @import("vu_ops.zig");
    _ = @import("vector_memory.zig");
    _ = @import("fields.zig");
    _ = @import("cop0.zig");
    _ = @import("scalar.zig");
    _ = @import("timing.zig");
    _ = @import("encode.zig");
    _ = @import("Machine.zig");
    _ = @import("program_tests.zig");
    _ = @import("Profile.zig");
    _ = @import("Session.zig");
    _ = @import("calibration.zig");
}
