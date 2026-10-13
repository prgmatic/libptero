//! Raw memory-mapped hardware. Managed APIs live in display, audio, pi, rsp and rdp.
/// MIPS interface: RCP interrupt and initialization registers.
pub const mi = @import("hw/mi.zig");
/// Video interface: framebuffer scanout and timing.
pub const vi = @import("hw/vi.zig");
/// Audio interface: output DMA.
pub const ai = @import("hw/ai.zig");
/// Peripheral interface: cartridge-bus DMA.
pub const pi = @import("hw/pi.zig");
/// Serial interface: PIF/Joybus DMA.
pub const si = @import("hw/si.zig");
/// Signal processor: RSP control, IMEM and DMEM.
pub const sp = @import("hw/sp.zig");
/// Display processor: RDP command DMA and status.
pub const dp = @import("hw/dp.zig");
