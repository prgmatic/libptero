const cpu = @import("../cpu.zig");

const mode:         *volatile u32 = @ptrFromInt(0xA4700000);
const config:       *volatile u32 = @ptrFromInt(0xA4700004);
const current_load: *volatile u32 = @ptrFromInt(0xA4700008);
const select:       *volatile u32 = @ptrFromInt(0xA470000C);
const refresh:      *volatile u32 = @ptrFromInt(0xA4700010);
const latency:      *volatile u32 = @ptrFromInt(0xA4700014);
const err:          *volatile u32 = @ptrFromInt(0xA4700018);
const bank_status:  *volatile u32 = @ptrFromInt(0xA470001C);

const START_ADDR = 0xA0000000;

const CONFIG_AUTO_CALIBRATION = 0x40;
const SELECT_RX_TX = 0x14;

pub fn init() u32 {
    if(isWarm())
        return getMemSize();

    // TODO: Implement a cold boot.

    return 0;
}

inline fn isWarm() bool {
    return select.* == SELECT_RX_TX;
}

fn getMemSize() u32 {
    var chip_id: u32 = 0;
    var mem_size: u32 = 0;

    while(chip_id < 8) : (chip_id += 2) {
        const ptr: *volatile u32 = @ptrFromInt(START_ADDR + chip_id * 1024 * 1024); 
        ptr.* = 0;
        ptr.* = 0x12345678;
        if(ptr.* != 0x12345678) 
            break;
        mem_size += 2 * 1024 * 1024;
    }
    return mem_size;
}
