const queue = @import("rdp/queue.zig");
const rq = @import("rdp/render_queue.zig");
const blender = @import("rdp/blender.zig");
const modes = @import("rdp/modes.zig");
const cc = @import("rdp/combiner.zig");
const interrupt = @import("../interrupt.zig");

pub const FixedQueue = queue.FixedQueue;
pub const RspQueue = queue.RspQueue;
pub const DirectQueue = queue.DirectQueue;
pub const RspSubmittedQueue = queue.RspSubmittedQueue;
pub const OverlayQueue = queue.OverlayQueue;
pub const CommandQueue = queue.CommandQueue;
pub const FixedCommandQueue = queue.FixedCommandQueue;
pub const RspCommandQueue = queue.RspCommandQueue;
pub const DirectCommandQueue = queue.DirectCommandQueue;
pub const RspSubmittedCommandQueue = queue.RspSubmittedCommandQueue;
pub const OverlayCommandQueue = queue.OverlayCommandQueue;
pub const LoadTextureOptions = queue.LoadTextureOptions;

pub const RenderQueue = rq.RenderQueue;
pub const FixedRenderQueue = rq.FixedRenderQueue;
pub const RspRenderQueue = rq.RspRenderQueue;
pub const DirectRenderQueue = rq.DirectRenderQueue;
pub const RspSubmittedRenderQueue = rq.RspSubmittedRenderQueue;
pub const OverlayRenderQueue = rq.OverlayRenderQueue;
// Canonical high-level renderer. Use DirectRenderQueue or
// RspSubmittedRenderQueue when raw CPU command construction is intentional.
pub const DefaultRenderQueue = OverlayRenderQueue;
pub const Fence = interrupt.RdpFence;

pub fn syncFull(render_queue: anytype) Fence {
    render_queue.fullSync();
    const fence = interrupt.armRdpFence();
    render_queue.execute();
    return fence;
}
pub const SpriteDrawOptions = rq.SpriteDrawOptions;
pub const Pivot = rq.Pivot;
pub const TexVertex = rq.TexVertex;

pub const OtherModes = modes.OtherModes;
pub const CycleType = modes.CycleType;
pub const ZMode = modes.ZMode;
pub const CoverageDest = modes.CoverageDest;
pub const RgbDither = modes.RgbDither;
pub const AlphaDither = modes.AlphaDither;
pub const TlutFormat = modes.TlutFormat;
pub const SampleType = modes.SampleType;

pub const BlendMode = blender.BlendMode;
pub const BlendCycle = blender.BlendCycle;
pub const BlendColorSrc = blender.BlendColorSrc;
pub const BlendAlphaSrc = blender.BlendAlphaSrc;
pub const BlendInvSrc = blender.BlendInvSrc;

pub const CombineMode = cc.CombineMode;
pub const CycleMode = cc.CycleMode;
