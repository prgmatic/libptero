pub const dma_start_addr: *volatile u32 = @ptrFromInt(0xA4100000);
pub const dma_end_addr: *volatile u32 = @ptrFromInt(0xA4100004);
pub const dma_current_addr: *volatile u32 = @ptrFromInt(0xA4100008);
pub const status: *volatile Status = @ptrFromInt(0xA410000C);

pub fn setDmaSource(source: RdpDmaSource) void {
    status.*.dma_source = source;
}



const Status = packed struct(u32) {
    /// bit 0: DMA transfer source (0 = RDRAM, 1 = DMEM via XBUS)
    dma_source: RdpDmaSource,
    /// RDP command processing is frozen when set
    freeze_rdp_command_processing: bool,
    /// Immediately terminates all in-progress or pending RDP transfers
    flush_all_rdp_transfers: bool,
    /// RDP global clock active (0 = paused, 1 = running)
    rdp_global_clock_enabled: bool,
    ///  RDP TMEM load in progress
    texture_memory_transfer_busy: bool,
    /// RDP pipeline busy (set on DMA start, cleared on SYNC_FULL)
    rdp_pipeline_busy: bool,
    /// RDP command processor busy
    rdp_command_processor_busy: bool,
    /// Command buffer ready (undocumented / partially known)
    command_buffer_ready: bool,
    /// DMA engine busy (undocumented / partially known)
    dma_engine_busy: bool,
    /// dma_end_addr write pending due to active transfer
    end_register_write_pending: bool,
    /// dma_starta_addr write pending (waiting for END or active transfer)
    is_start_register_write_pending: bool,
    reserved: u21,
};

const RdpDmaSource = enum(u1) {
    rdram = 0,
    dmem  = 1,
};
