const UCode = @import("ucode.zig").UCode;

pub const fill_dmem_rsp align(8) = @embedFile("fill_dmem_rsp").*;
pub const fill_dmem = UCode.fromBlob(&fill_dmem_rsp);
