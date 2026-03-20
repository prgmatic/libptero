const print = @import("debug.zig").dmemPrint;
const n64 = @import("n64");
const pi = n64.io.pi;

const mode:         *volatile u32 = @ptrFromInt(0xA4700000);
const config:       *volatile u32 = @ptrFromInt(0xA4700004);
const current_load: *volatile u32 = @ptrFromInt(0xA4700008);
const select:       *volatile u32 = @ptrFromInt(0xA470000C);
const refresh:      *volatile u32 = @ptrFromInt(0xA4700010);
const latency:      *volatile u32 = @ptrFromInt(0xA4700014);
const err_reg:      *volatile u32 = @ptrFromInt(0xA4700018);
const bank_status:  *volatile u32 = @ptrFromInt(0xA470001C);

const registers: [*]volatile u32 = @ptrFromInt(0xA3F00000);
const broadcast_registers: [*]volatile u32 = @ptrFromInt(0xA3F80000);

const START_ADDR = 0xA0000000;
const CONFIG_AUTO_CALIBRATION = 0x20;
const SELECT_RX_TX = 0x14;
const MODE_RESET = 0x0;
const MODE_STANDARD = 0x2 | 0x4 | 0x8;
const MAX_DEVICE_ID = 511;

pub fn init() u32 {
    if(isWarm())
        return getMemSize();

    config.* = CONFIG_AUTO_CALIBRATION;
    n64.cpu.waitCycles(0x100);
    current_load.* = 0;

    select.* = SELECT_RX_TX;

    mode.* = MODE_RESET;
    n64.cpu.waitCycles(0x100);
    mode.* = MODE_STANDARD;
    n64.cpu.waitCycles(0x100);

    regInit();

    regWriteAll(.DeviceId, createChipId(MAX_DEVICE_ID));
    regWriteAll(.Mode, (1 << 6) | (1 << 2));
    regWriteAll(.RefRow, 0);

    var total_memory: u32 = 0;
    var chip_id: u32 = 0;
    while(true) {

        regWrite(MAX_DEVICE_ID, .DeviceId, createChipId(chip_id));
        regWrite(chip_id, .Mode, (1 << 6) | (1 << 1) | (1 << 2));
        // Check device enable bit
        if(regRead(chip_id, .Mode) & (1 << 1) == 0) {
            break;
        }

        // RI only supports 4 chips
        if(chip_id >= 8) break;

        const current = calibrateChipCurrent(chip_id);

        const info: DeviceInfo = @bitCast(regRead(chip_id, .DeviceType));
        if(info.bank != 1 or info.row != 9 or info.column != 11 or !info.ninth_bit) {
            print("invalid geometry", &.{info.bank, info.row, info.column, @intFromBool(info.ninth_bit)});
        }

        const manufacturer: ChipManufacturer = @bitCast(regRead(chip_id, .DeviceManufacturer));
        const ras_interval =
            if(manufacturer.manufacturer == .Nec or info.low_latency)
                makeRasInterval(1, 7, 10, 4)
            else
                makeRasInterval(2, 6, 9, 4);
        regWrite(chip_id, .RasInterval, ras_interval);


        // Touch each bank to "settle timing circutes"
        for(0..4) |bank| {
            const ptr: [*]volatile u32 = @ptrFromInt(0xA0000000 + chip_id * 1024 * 1024 + bank * 512 * 1024);
            _ = ptr[0];
            _ = ptr[1];
        }

        print("Chip ", &.{chip_id});
        print("\tManufacturer ", &.{@intFromEnum(manufacturer.manufacturer)});
        print("\tGeometry ", &.{info.bank, info.row, info.column});
        print("\tCurrent ", &.{current});
        print("\tRAS ", &.{ras_interval});

        chip_id += 2;
        total_memory += 1024 * 1024 * 2;
    }

    refresh.* = buildRefreshValue(chip_id);
    return total_memory;
}

fn regInit() void {
    // Set delay for all chips
    const delay = get_reg_delay(1, 3, 7, 5);
    n64.cpu.enableRepeatMode(16);
    regWriteAll(.Delay, delay);
}

fn regWrite(chip_id: u32, reg: RegisterType, value: u32) void {
    const swapped = @byteSwap(value);
    registers[(chip_id << 8) + @intFromEnum(reg)] = swapped;
}

fn regWriteAll(reg: RegisterType, value: u32) void {
    const swapped = @byteSwap(value);
    broadcast_registers[@intFromEnum(reg)] = swapped;
}

fn regRead(chip_id: u32, reg: RegisterType) u32 {
    if(@intFromEnum(reg) & 1 > 0)
        n64.cpu.setUpperMode();
    const result = registers[(chip_id << 8) + @intFromEnum(reg)];
    if(@intFromEnum(reg) & 1 > 0)
        n64.cpu.clearUpperMode();
    return @byteSwap(result);
}

fn createChipId(value: u32) u32 {
    var result: u32 = 0;

    result |= ((value >>  0) & 0x03F) <<  2;   // Bits 0..5
    result |= ((value >>  6) & 0x1FF) << 15;   // Bits 6..14
    result |= ((value >> 15) & 0x001) << 31;   // Bit  15
    return result;
}

fn calibrateChipCurrent(chip_id: u32) u32 {
    const attempt_count = 1;
    var weighted_cc: u32 = 0;
    for(0..attempt_count) |_| {
        var weighted_sum: f32 = 0;
        var prev_accuracy: f32 = 0;
        const vaddr: [*]volatile u32 = @ptrFromInt(0xA0000000 + chip_id * 1024 * 1024);
        for(0..64) |cc| {
            // Go through all possible current values
            _ = regWriteMode(chip_id, false, @intCast(cc));

            const accuracy = memoryTest(vaddr);
            weighted_sum += (accuracy - prev_accuracy) * @as(f32, @floatFromInt(cc));

            if(accuracy >= 1.0) break;
            prev_accuracy = accuracy;

        }

        const target_cc: u32 = @intFromFloat(weighted_sum * 2.2 + 0.5);
        if(target_cc == 0)
            continue;

        var min_error: u32 = 0;
        var auto_cc: u32 = 0;
        for(0..64) |cc| {
            const cc_readback = regWriteMode(chip_id, true, @intCast(cc));

            const err = @abs(cc_readback - target_cc);
            if(cc == 0 or err < min_error) {
                min_error = err;
                auto_cc = cc;
            }
            if(cc_readback > target_cc){
                break;
            }
        }
        weighted_cc += auto_cc;
    }

    if(weighted_cc == 0) {
        print("current calib fail", &.{chip_id});
    }
    const target_cc = weighted_cc / attempt_count;
    _ = regWriteMode(chip_id, true, @intCast(target_cc));

    return target_cc;
}

fn regWriteMode(chip_id: u32, auto_current: bool, cci: u8) u32 {

    const cc = cci ^ 0x3F;
    const x2 = 1 << 6;
    const current_control_auto = 1 << 7;
    const auto_skip = 1 << 2;
    const device_en = 1 << 1;

    var value: u32 = device_en | auto_skip | x2;
    if(auto_current) value |= current_control_auto;
    value |= ccValue(cc);

    regWrite(chip_id, .Mode, value);

    if(auto_current) {
        n64.cpu.waitCycles(0x100);
        _ = regReadMode(chip_id);
        return regReadMode(chip_id);
    }

    return cc;
}

fn ccValue(cc: u32) u32 {
    return (((cc >> 0) & 1) << 30) |
           (((cc >> 1) & 1) << 22) |
           (((cc >> 2) & 1) << 14) |
           (((cc >> 3) & 1) << 31) |
           (((cc >> 4) & 1) << 23) |
           (((cc >> 5) & 1) << 15);
}

fn regReadMode(chip_id: u32) u32 {
    const value = regRead(chip_id, .Mode);
    const cc0 = (value >> 30) &  1;
    const cc1 = (value >> 21) &  2;
    const cc2 = (value >> 12) &  4;
    const cc3 = (value >> 28) &  8;
    const cc4 = (value >> 19) & 16;
    const cc5 = (value >> 10) & 32;
    return cc0 | cc1 | cc2 | cc3 | cc4 | cc5;
}

fn memoryTest(vaddr: [*]volatile u32) f32 {
    const num_of_tests = 10;

    var accuracy: f32 = 0;
    for(0..num_of_tests) |_| {
        vaddr[0] = 0xFFFFFFFF;
        vaddr[1] = 0xFFFFFFFF;

        const byte_ptr: [*]volatile u8 = @ptrCast(vaddr);

        var b = byte_ptr[5];
        while(b > 0){
            if((b & 1) > 0) accuracy += 1;
            b >>= 1;
        }
    }
    const max_score: f32 = num_of_tests * 8;
    return accuracy / max_score;
}

inline fn get_reg_delay(write: u32, ack: u32, read: u32, ackwin: u32) u32 {
    const result: u32= write << 27 | ack << 19 | read << 11 | ackwin << 3;
    return (result >> 16) | (result << 16);
}

inline fn makeRasInterval( row_precharge: u32, row_sense: u32, row_imp_restore: u32, row_exp_restore: u32) u32 {
    return (rev5(row_precharge)        ) |
           (rev5(row_sense)       <<  8) |
           (rev5(row_imp_restore) << 16) |
           (rev5(row_exp_restore) << 24);
}

inline fn rev5(x: u32) u32 {
    // Keep only 5 bits, reverse them, then move back down
    return (@bitReverse(x & 0x1F) >> 27);
}

fn buildRefreshValue(chip_id: u32) u32 {
    const shift: u5 = @intCast(chip_id >> 1); // ensures 0–31
    const refresh_multibanks: u32 = (@as(u32, 1) << shift) - 1;

    return
        (1 << 17) | // RI_REFRESH_AUTO
        (1 << 18) | // RI_REFRESH_OPTIMIZE
        (52 & 0xFF) |
        ((54 & 0xFF) << 8) |
        ((refresh_multibanks & 0xF) << 19);
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

const RegisterType = enum(u8) {
    DeviceType = 0,
    DeviceId = 1,
    Delay = 2,
    Mode = 3,
    RefIntevnal = 4,
    RefRow = 5,
    RasInterval = 6,
    MinInterval = 7,
    AddrSelect = 8,
    DeviceManufacturer = 9,
    Row = 128
};

const DeviceInfo = packed struct(u32) {
    low_latency: bool,
    unused0: u1,
    ninth_bit: bool,
    unused1: u1,
    column: u4,
    row: u4,
    bank: u4,
    unused2: u8,
    device_type: u4,
    version: u4,
};

const ChipManufacturer = packed struct(u32) {
    code: u16,
    manufacturer: Manufacturer,
};

const Manufacturer = enum(u16) {
    Toshiba = 0x2,
    Fujitsu = 0x3,
    Nec = 0x5,
    Hitachi = 0x7,
    Oki = 0x9,
    Lg = 0xA,
    Samsung = 0x10,
    Hyndai = 0x13
};
