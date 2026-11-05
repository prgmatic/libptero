//! Resident dispatcher command identifiers (command table indices 0-10).
pub const InternalCommand = enum(u8) {
    invalid = 0x00,
    write_word = 0x01,
    jump = 0x02,
    call = 0x03,
    ret = 0x04,
    dma = 0x05,
    write_status = 0x06,
    swap_buffers = 0x07,
    wait_then_write_status = 0x08,
    rdp_set_buffer = 0x09,
    rdp_append_buffer = 0x0a,
};
