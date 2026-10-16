pub const dma_start_addr: *volatile u32 = @ptrFromInt(0xA4100000);
pub const dma_end_addr: *volatile u32 = @ptrFromInt(0xA4100004);
pub const dma_current_addr: *volatile u32 = @ptrFromInt(0xA4100008);
pub const status: *const volatile Status = @ptrFromInt(0xA410000C);
pub const status_write: *volatile u32 = @ptrFromInt(0xA410000C);

const clock_counter: *const volatile u32 = @ptrFromInt(0xA4100010);
const command_busy_counter: *const volatile u32 = @ptrFromInt(0xA4100014);
const pipe_busy_counter: *const volatile u32 = @ptrFromInt(0xA4100018);
const tmem_busy_counter: *const volatile u32 = @ptrFromInt(0xA410001C);

/// RDP activity counters, in RDP clock cycles (24-bit, wrap after ~268 ms).
pub const Counters = struct {
    clock: u32,
    command_busy: u32,
    pipe_busy: u32,
    tmem_busy: u32,

    pub const cycles_per_second: f32 = 62_500_000;

    pub fn read() Counters {
        return .{
            .clock = clock_counter.* & 0xffffff,
            .command_busy = command_busy_counter.* & 0xffffff,
            .pipe_busy = pipe_busy_counter.* & 0xffffff,
            .tmem_busy = tmem_busy_counter.* & 0xffffff,
        };
    }

    /// Clears the command, pipe and TMEM counters. The clock counter keeps
    /// running: the RSP timestamps idle periods with it (`rsp.Counters`).
    pub fn reset() void {
        status_write.* = (1 << 6) | (1 << 7) | (1 << 8);
    }
};

/// Free-running RDP clock (DPC_CLOCK), 24 bits at `Counters.cycles_per_second`.
pub fn clock() u32 {
    return clock_counter.* & 0xffffff;
}

pub fn setDmaSource(source: RdpDmaSource) void {
    status_write.* = switch (source) {
        .rdram => 1 << 0,
        .dmem => 1 << 1,
    };
}

const Status = packed struct(u32) {
    dma_source: RdpDmaSource,
    freeze_rdp_command_processing: bool,
    flush_all_rdp_transfers: bool,
    rdp_global_clock_enabled: bool,
    texture_memory_transfer_busy: bool,
    rdp_pipeline_busy: bool,
    rdp_command_processor_busy: bool,
    command_buffer_ready: bool,
    dma_engine_busy: bool,
    end_register_write_pending: bool,
    is_start_register_write_pending: bool,
    _pad: u21,
};

const RdpDmaSource = enum(u1) {
    rdram = 0,
    dmem = 1,
};
