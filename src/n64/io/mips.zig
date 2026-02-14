pub var version: *volatile u32 = @ptrFromInt(0xA4300004);

pub fn getVersion() u32 {
    return version.*;
}
