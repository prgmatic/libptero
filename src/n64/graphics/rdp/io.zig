pub const dma_start_addr: *volatile u32 = @ptrFromInt(0xA4100000);
pub const dma_end_addr: *volatile u32 = @ptrFromInt(0xA4100004);
pub const dma_current_addr: *volatile u32 = @ptrFromInt(0xA4100008);
pub const status: *volatile Status = @ptrFromInt(0xA410000C);

pub fn setDmaSource(source: RdpDmaSource) void {
    status.*.dma_source = source;
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
    dmem  = 1,
};
