const std = @import("std");
const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");
const zsp_programs = @import("zsp_test_programs");

const rsp = n64.rsp;
const rdp = n64.graphics.rdp;
const geometry = n64.graphics.geometry;
const rsp_timeout_attempts: u32 = 1_000_000;

var dma_in_batch align(8) = [_]u32{
    0x01000100,
    0x12345678,
    0x00000000,
    0x00000000,
};

var invalid_command_batch: [rsp.command_queue.batch_word_count]u32 align(8) = .{0xff000000} ++
    .{0x00000000} ** (rsp.command_queue.batch_word_count - 1);

var command_queue_buffer: [rsp.command_queue.batch_word_count]u32 align(8) = undefined;
var boundary_queue_buffer: [rsp.command_queue.batch_word_count * 2]u32 align(8) = undefined;
var chained_queue_buffer: [rsp.command_queue.batch_word_count]u32 align(8) = undefined;
var called_block_buffer: [rsp.command_queue.batch_word_count]u32 align(8) = undefined;
var alternate_queue_buffer: [rsp.command_queue.batch_word_count]u32 align(8) = undefined;
var continuous_queue: rsp.Queue = undefined;
var queued_dma_queue: rsp.Queue = undefined;
var syncpoint_queue: rsp.Queue = undefined;
var high_priority_queue: rsp.Queue = undefined;
var rdp_queue: rsp.Queue = undefined;
var rdp_buffer: [4]u64 align(8) = .{ 0, 0, 0, 0 };
var rdp_color_image_buffer: [5]u64 align(8) = .{ 0, 0, 0, 0, 0 };
var rdp_mode_buffer: [5]u64 align(8) = .{ 0, 0, 0, 0, 0 };
var rdp_render_mode_buffer: [10]u64 align(8) = .{0} ** 10;
var rdp_mode_stack_buffer: [4]u64 align(8) = .{0} ** 4;
var rdp_reset_mode_buffer: [4]u64 align(8) = .{0} ** 4;
var rdp_passthrough_triangle_buffer: [52]u32 align(8) = .{0} ** 52;
var rdp_triangle_cull_buffer: [1]u64 align(8) = .{0};
var rdp_triangle_buffer: [23]u64 align(8) = .{0} ** 23;
var rdp_triangle_rollover_buffer: [22]u64 align(16) = .{0} ** 22;
var rdp_triangle_render_commands: [32]u64 align(8) = .{0} ** 32;
var rdp_triangle_render_target: [8 * 8]n64.graphics.color.Rgba16 align(8) = undefined;
var rdp_rectangle_buffer: [6]u64 align(8) = .{ 0, 0, 0, 0, 0, 0 };
var rdp_clear_z_target: [4096]u16 align(16) = undefined;
var rdp_clear_z_temporary: [0x1000]u8 align(16) = undefined;
var rdp_rollover_buffer: [2]u64 align(8) = .{ 0, 0 };
var rdp_syncpoint_source: [2]u32 align(8) = .{ 0, 0 };
var rdp_sync_state_output: [4]u32 align(8) = .{ 0, 0, 0, 0 };
var rsp_rdp_command_buffer: [4]u64 align(8) = undefined;
var rsp_rdp_dynamic_buffers: [2][rsp.rdp_dynamic_buffer_len]u8 align(16) = undefined;
var direct_rdp_command_buffer: [16]u64 align(8) = undefined;
var direct_rdp_render_target: [4 * 4]n64.graphics.color.Rgba32 align(64) = undefined;
var overlay_rdp_render_target: [4 * 4]n64.graphics.color.Rgba32 align(64) = undefined;
var overlay_rdp_render_target_16: [4 * 4]n64.graphics.color.Rgba16 align(64) = undefined;
var native_triangle_overlay_target: [16 * 16]n64.graphics.color.Rgba16 align(64) = undefined;
var native_triangle_texture: [4 * 4]n64.graphics.color.Rgba32 align(16) = undefined;
var font_render_target: [8 * 8]n64.graphics.color.Rgba16 align(64) = undefined;
var font_atlas_texels: [1]n64.graphics.color.Rgba16 align(8) = .{.white};
var queue_dma_source: [4]u32 align(8) = .{ 0x12345678, 0x89abcdef, 0x0badcafe, 0xfeedface };
var queue_dma_destination: [4]u32 align(8) = undefined;
var overlay_1: rsp.Overlay = undefined;
var overlay_2: rsp.Overlay = undefined;
var multi_slot_overlay: rsp.Overlay = undefined;
var rdp_overlay: rsp.Overlay = undefined;
var geometry_overlay: rsp.Overlay = undefined;
var geometry_matrix_input: [16]u32 align(16) = undefined;
var geometry_matrix_stack: [32]u32 align(16) = undefined;
var geometry_patch_target: [2]u32 align(8) = undefined;
var geometry_vertex_input: [64]u8 align(16) = undefined;
var geometry_triangle_output: [32]u64 align(16) = undefined;
var geometry_api_context: geometry.Context = undefined;
var geometry_strip_indices: [4]i16 align(8) = .{ 0x0408, 0x042c, 0x4450, 0 };

pub const tests = [_]runner.Test{
    .{ .name = "ZSP: arithmetic", .run = arithmetic },
    .{ .name = "ZSP: signed arithmetic", .run = signedArithmetic },
    .{ .name = "ZSP: bitwise", .run = bitwise },
    .{ .name = "ZSP: branches", .run = branches },
    .{ .name = "ZSP: comparisons", .run = comparisons },
    .{ .name = "ZSP: loops", .run = loops },
    .{ .name = "ZSP: shifts", .run = shifts },
    .{ .name = "ZSP: register operations", .run = registerOperations },
    .{ .name = "ZSP: large immediates", .run = largeImmediates },
    .{ .name = "ZSP: memory offsets", .run = memoryOffsets },
    .{ .name = "ZSP: scalar stores", .run = scalarStores },
    .{ .name = "ZSP: scalar loads", .run = scalarLoads },
    .{ .name = "ZSP: vector operations", .run = vectorOperations },
    .{ .name = "ZSP: data blocks", .run = dataBlocks },
    .{ .name = "ZSP: DMA in", .run = dmaIn },
    .{ .name = "ZSP: command dispatcher", .run = commandDispatcher },
    .{ .name = "ZSP: chained command buffers", .run = chainedCommandBuffers },
    .{ .name = "ZSP: called command block", .run = calledCommandBlock },
    .{ .name = "ZSP: indirect called command block", .run = indirectCalledCommandBlock },
    .{ .name = "ZSP: swapped command buffers", .run = swappedCommandBuffers },
    .{ .name = "ZSP: continuous double-buffered queue", .run = continuousDoubleBufferedQueue },
    .{ .name = "ZSP: command fetch boundary", .run = commandFetchBoundary },
    .{ .name = "ZSP: polling syncpoint", .run = pollingSyncpoint },
    .{ .name = "ZSP: high-priority queue", .run = highPriorityQueue },
    .{ .name = "RDP: direct CPU renderer", .run = directRdpRenderer },
    .{ .name = "RDP: RSP-submitted raw queue", .run = rspBackedRdpQueue },
    .{ .name = "RDP: completion fence", .run = rdpCompletionFence },
    .{ .name = "RDP: native overlay textured triangle", .run = nativeOverlayTexturedTriangle },
    .{ .name = "RDP: RSP text renderer", .run = rspTextRenderer },
    .{ .name = "RDP: overlay-backed renderer", .run = overlayBackedRdpRenderer },
    .{ .name = "ZSP: RDP buffer commands", .run = rdpBufferCommands },
    .{ .name = "ZSP: RDP triangle sort and normal", .run = rdpTriangleSortAndNormal },
    .{ .name = "ZSP: RDP triangle render", .run = rdpTriangleRender },
    .{ .name = "ZSP: RDP debug handoff", .run = rdpDebugHandoff },
    .{ .name = "ZSP: RDP AutoTMEM tile emission", .run = rdpAutoTmemTileEmission },
    .{ .name = "ZSP: RDP address fixups", .run = rdpAddressFixups },
    .{ .name = "ZSP: RDP full-sync state", .run = rdpFullSyncState },
    .{ .name = "ZSP: RDP color-image fixup", .run = rdpColorImageFixup },
    .{ .name = "ZSP: RDP mode state", .run = rdpModeState },
    .{ .name = "ZSP: RDP render mode commands", .run = rdpRenderModeCommands },
    .{ .name = "ZSP: RDP mode stack", .run = rdpModeStack },
    .{ .name = "ZSP: RDP reset mode", .run = rdpResetMode },
    .{ .name = "ZSP: RDP passthrough triangles", .run = rdpPassthroughTriangles },
    .{ .name = "ZSP: RDP triangle trivial reject", .run = rdpTriangleTrivialReject },
    .{ .name = "ZSP: RDP triangle data", .run = rdpTriangleData },
    .{ .name = "ZSP: RDP exclusive rectangles", .run = rdpExclusiveRectangles },
    .{ .name = "ZSP: RDP clear Z buffer", .run = rdpClearZBuffer },
    .{ .name = "ZSP: queued DMA command", .run = queuedDmaCommand },
    .{ .name = "ZSP: RSP-loaded overlay dispatch", .run = rspLoadedOverlayDispatch },
    .{ .name = "ZSP: multi-slot overlay dispatch", .run = multiSlotOverlayDispatch },
    .{ .name = "ZSP: RDP reserved loop slots", .run = rdpReservedLoopSlots },
    .{ .name = "ZSP: RDP persistent scalar state", .run = rdpPersistentScalarState },
    .{ .name = "ZSP: command dispatcher invalid command", .run = commandDispatcherInvalid },
    .{ .name = "ZSP: Geometry projection DMA", .run = geometryProjectionDma },
    .{ .name = "ZSP: Geometry state commands", .run = geometryStateCommands },
    .{ .name = "ZSP: Geometry lighting API", .run = geometryLightingApi },
    .{ .name = "ZSP: Geometry matrix overlay", .run = geometryMatrixOverlay },
    .{ .name = "ZSP: Geometry clipping swap", .run = geometryClippingSwap },
    .{ .name = "ZSP: Geometry vertex transform", .run = geometryVertexTransform },
    .{ .name = "ZSP: Geometry triangle submission", .run = geometryTriangleSubmission },
    .{ .name = "ZSP: Geometry clipped triangle", .run = geometryClippedTriangle },
    .{ .name = "ZSP: Geometry patch DMA", .run = geometryPatchDma },
    .{ .name = "ZSP: Geometry context initialization", .run = geometryContextInitialization },
    .{ .name = "ZSP: Geometry encoded triangle strip", .run = geometryTriangleStrip },
};

fn rspTextRenderer() !void {
    loadCommandDispatcher();
    rsp.releaseRdpToDirect();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_queue.init(.low);
    @memset(&font_render_target, .black);
    n64.cache.writebackData(&font_render_target);
    n64.cache.writebackData(&font_atlas_texels);

    const target = n64.graphics.image.ImgRgba16{ .width = 8, .height = 8, .texel_data = font_render_target[0..] };
    const atlas = n64.graphics.image.ImgRgba16{ .width = 1, .height = 1, .texel_data = font_atlas_texels[0..] };
    const test_font: n64.graphics.font.Font = .{
        .point_size = 2,
        .ascent = 1,
        .descent = -1,
        .line_height = 2,
        .ranges = &.{.{ .first_codepoint = 'A', .glyph_count = 2, .first_glyph = 0 }},
        .glyphs = &.{
            .{ .x_advance = 2, .x_offset = 0, .y_offset = -1, .width = 1, .height = 1, .s = 0, .t = 0, .atlas = 0 },
            .{ .x_advance = 2, .x_offset = 0, .y_offset = -1, .width = 1, .height = 1, .s = 0, .t = 0, .atlas = 0 },
        },
        .atlases = &.{atlas},
        .kernings = &.{.{ .first = 0, .second = 1, .amount = -1 }},
    };
    var render = rdp.OverlayRenderQueue.init(rdp.OverlayQueue.init(
        &rdp_queue,
        &rdp_overlay,
        .{ rsp_rdp_dynamic_buffers[0][0..], rsp_rdp_dynamic_buffers[1][0..] },
    ));
    render.setFrameBuffer(target);
    render.clearScreen(n64.graphics.color.Rgba16.black);
    const metrics = try test_font.draw(&render, 2, 4, "AB", .{ .color = .green });
    try testing.expectEqual(@as(f32, 3), metrics.width);
    const fence = rdp.syncFull(&render);
    try waitQueueTimeout(&rdp_queue);
    if (!fence.waitTimeout(rsp_timeout_attempts)) return error.RdpFenceTimeout;

    n64.cache.invalidateData(&font_render_target);
    var changed: usize = 0;
    for (font_render_target) |pixel| if (!std.meta.eql(pixel, n64.graphics.color.Rgba16.black)) {
        changed += 1;
        try testing.expectEqual(n64.graphics.color.Rgba16.green, pixel);
    };
    try testing.expectEqual(@as(usize, 2), changed);
    try testing.expectEqual(n64.graphics.color.Rgba16.green, font_render_target[3 * 8 + 2]);
    try testing.expectEqual(n64.graphics.color.Rgba16.green, font_render_target[3 * 8 + 3]);
    rsp.releaseRdpToDirect();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn geometryLightingApi() !void {
    loadCommandDispatcher();
    geometry_api_context.geometry_overlay.init(zsp_programs.geometry_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&geometry_api_context.geometry_overlay));
    geometry_api_context.queue.init(.low);

    geometry_api_context.view_matrix = n64.math.Mat4.lookAt(
        .init(10, 0, 0),
        .zero,
        .init(0, 1, 0),
    );
    geometry_api_context.setAmbientLight(.fromBytes(0x11, 0x22, 0x33, 0x44));
    geometry_api_context.setDirectionalLight(.fromBytes(0x55, 0x66, 0x77, 0x88), .init(0, 0, 1));
    rsp.flush(&geometry_api_context.queue);
    try waitQueueTimeout(&geometry_api_context.queue);

    try expectDmemWord(u32, 0x378, 0x11223344);
    try expectDmemWord(u32, 0x37c, 0x11223344);
    try expectDmemWord(u32, 0x380, 0x55667788);
    try expectDmemWord(u32, 0x384, 0x55667788);
    try expectDmemWord(u32, 0x388, 0x81000000);
    try expectDmemWord(u32, 0x38c, 0x81000000);
    try expectDmemWord(u16, 0x3fa, 0x1000);
    rsp.unregisterOverlay(&geometry_api_context.geometry_overlay);
}

fn geometryContextInitialization() !void {
    geometry_api_context = undefined;
    geometry_api_context.init();

    const vertex_handler = blk: {
        for (0..geometry_api_context.geometry_overlay.program.commandCount()) |metadata_index| {
            const command = geometry_api_context.geometry_overlay.program.commandAt(metadata_index);
            if (command.index == 4) break :blk command.handler_offset;
        }
        return error.MissingGeometryVertexCommand;
    };
    try testing.expectEqual(
        vertex_handler + 0x2bc,
        rsp.io.readDmem(u16, 0x3fc).*,
    );

    rsp.unregisterOverlay(&geometry_api_context.geometry_overlay);
    rsp.unregisterOverlay(&geometry_api_context.rdp_overlay);
}

fn arithmetic() !void {
    try run(zsp_programs.arithmetic);
    try expectDmemWord(u32, 0, 15);
}

fn signedArithmetic() !void {
    try run(zsp_programs.signed_arithmetic);
    try expectDmemWord(i32, 0, -24);
    try expectDmemWord(i32, 4, -9);
    try expectDmemWord(i32, 8, -18);
}

fn bitwise() !void {
    try run(zsp_programs.bitwise);
    try expectDmemWord(u32, 0, 0x4f);
}

fn branches() !void {
    try run(zsp_programs.branches);
    try expectDmemWord(u32, 0, 2);
}

fn comparisons() !void {
    try run(zsp_programs.comparisons);
    try expectDmemWord(u32, 0, 4095);
}

fn loops() !void {
    try run(zsp_programs.loops);
    try expectDmemWord(u32, 0, 4);
}

fn shifts() !void {
    try run(zsp_programs.shifts);
    try expectDmemWord(u32, 0, 4);
}

fn registerOperations() !void {
    try run(zsp_programs.register_ops);
    try expectDmemWord(u32, 0, 0x08000000);
    try expectDmemWord(i32, 4, -4);
    try expectDmemWord(i32, 8, 0x3ffffffc);
    try expectDmemWord(u32, 12, 0xf0f0ff00);
}

fn largeImmediates() !void {
    try run(zsp_programs.immediates);
    try expectDmemWord(u32, 0, 0x89abcdef);
    try expectDmemWord(i32, 4, -2147483648);
    try expectDmemWord(u32, 8, 0x12340000);
    try expectDmemWord(i32, 12, -32768);
}

fn memoryOffsets() !void {
    try run(zsp_programs.memory_offsets);
    try expectDmemWord(u32, 0, 0x11aa3344);
    try expectDmemWord(u32, 4, 0x5566beef);
    try expectDmemWord(u32, 8, 0x99aabb80);
    try expectDmemWord(u32, 16, 0xaa);
    try expectDmemWord(i32, 20, -128);
    try expectDmemWord(u32, 24, 0xbeef);
    try expectDmemWord(u32, 28, 0xaa334455);
}

fn scalarStores() !void {
    try run(zsp_programs.scalar_stores);
    try expectDmemWord(u8, 0, 0xab);
    try expectDmemWord(i8, 1, -85);
    try expectDmemWord(u16, 2, 0xabcd);
    try expectDmemWord(i16, 4, -21555);
    try expectDmemWord(u32, 8, 0x0abcdef0);
    try expectDmemWord(i32, 12, 0x00abcdef);
}

fn scalarLoads() !void {
    seedLoadSource(0x80ff8001);
    try run(zsp_programs.scalar_loads);
    try expectDmemWord(u32, 4, 0x00000080);
    try expectDmemWord(i32, 8, -128);
    try expectDmemWord(u32, 12, 0x000080ff);
    try expectDmemWord(i32, 16, -32513);
    try expectDmemWord(u32, 20, 0x80ff8001);
    try expectDmemWord(i32, 24, -2130739199);
}

fn vectorOperations() !void {
    try run(zsp_programs.vector_ops);

    const add_expected = [_]u32{ 0x00040006, 0x00007fff, 0x80003456, 0xb9b94645 };
    const sub_expected = [_]u32{ 0xfffefffe, 0xfffe8001, 0x7ffef012, 0x9b9b9b9b };
    const and_expected = [_]u32{ 0x00010000, 0x00018000, 0x00010220, 0x0a0a5050 };
    const or_expected = [_]u32{ 0x00030006, 0xffffffff, 0x7fff3236, 0xafaff5f5 };
    const xor_expected = [_]u32{ 0x00020006, 0xfffe7fff, 0x7ffe3016, 0xa5a5a5a5 };
    const not_expected = [_]u32{ 0xfffefffd, 0x00007fff, 0x8000edcb, 0x55550f0f };
    const nor_expected = [_]u32{ 0xfffcfff9, 0x00000000, 0x8000cdc9, 0x50500a0a };

    try expectDmemWords(0x100, &add_expected);
    try expectDmemWords(0x110, &sub_expected);
    try expectDmemWords(0x120, &and_expected);
    try expectDmemWords(0x130, &or_expected);
    try expectDmemWords(0x140, &xor_expected);
    try expectDmemWords(0x150, &not_expected);
    try expectDmemWords(0x180, &nor_expected);
    const multiply_expected = [_]u32{ 0, 0, 0, 0 };
    try expectDmemWords(0x1a0, &multiply_expected);
    const reciprocal_expected = [_]u32{ 0x0002c000, 0x7fff0000, 0, 0 };
    try expectDmemWords(0x1b0, &reciprocal_expected);
    const reciprocal_sqrt_expected = [_]u32{ 0xc0000000, 0, 0, 0 };
    try expectDmemWords(0x210, &reciprocal_sqrt_expected);
    const unsigned_bytes_expected = [_]u32{ 0x00000080, 0x00000100, 0x7f807f80, 0x40000000 };
    try expectDmemWords(0x1c0, &unsigned_bytes_expected);
    const partial_words_expected = [_]u32{ 0x00010002, 0, 0x7fff1234, 0 };
    try expectDmemWords(0x1d0, &partial_words_expected);
    const shifted_left_expected = [_]u32{ 0x40008000, 0xc0000000, 0xc0000000, 0x80000000 };
    const shifted_arithmetic_expected = [_]u32{ 0x00000000, 0xffffe000, 0x1fff048d, 0xeaaafc3c };
    const shifted_logical_expected = [_]u32{ 0x00000000, 0x01ff0100, 0x00ff0024, 0x015501e1 };
    try expectDmemWords(0x1e0, &shifted_left_expected);
    try expectDmemWords(0x1f0, &shifted_arithmetic_expected);
    try expectDmemWords(0x200, &shifted_logical_expected);

    const wide_expected = [_]u32{
        0x00040004, 0x00040004, 0x00040004, 0x00040004,
        0x00000000, 0x00000000, 0x00000000, 0x00000000,
    };
    try expectDmemWords(0x160, &wide_expected);
}

fn dataBlocks() !void {
    try run(zsp_programs.data_blocks);

    try expectDmemWord(u32, 0x100, 0x12345678);
    try expectDmemWord(u32, 0x104, 0x11);
    try expectDmemWord(u32, 0x108, 0x44);
    try expectDmemWord(u32, 0x10c, 0x89abcdef);
    try expectDmemWord(u32, 0x110, 0x76543210);

    try expectDmemWord(u32, 0x114, 0xdeadbeef);
    try expectDmemWord(u32, 0x118, 0xbeef);
    try expectDmemWord(u32, 0x11c, 0xcafe);

    try expectDmemWord(u32, 0x120, 0x00);
    try expectDmemWord(u32, 0x124, 0x10);
    try expectDmemWord(u32, 0x128, 0x04);
    try expectDmemWord(u32, 0x12c, 0x14);
    try expectDmemWord(u32, 0x130, 0x08);
}

fn dmaIn() !void {
    submitCommandBatch(&dma_in_batch);
    try run(zsp_programs.dma_in);
    for (dma_in_batch, 0..) |expected, index| {
        try expectDmemWord(u32, 0x20 + @as(u32, @intCast(index * 4)), expected);
    }
}

fn commandDispatcher() !void {
    loadCommandDispatcher();
    var queue = rsp.CommandQueue.init(command_queue_buffer[0..]);
    queue.writeDmem(0x100, 0x12345678);
    queue.stop();
    rsp.submitCommands(&queue);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x100, 0x12345678);
}

fn chainedCommandBuffers() !void {
    loadCommandDispatcher();
    var second = rsp.CommandQueue.init(chained_queue_buffer[0..]);
    second.writeDmem(0x308, 0x89abcdef);
    second.stop();
    var first = rsp.CommandQueue.init(command_queue_buffer[0..]);
    first.writeDmem(0x304, 0x12345678);
    first.jump(&second);
    rsp.submitCommands(&first);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x304, 0x12345678);
    try expectDmemWord(u32, 0x308, 0x89abcdef);
}

fn calledCommandBlock() !void {
    loadCommandDispatcher();
    var block = rsp.CommandQueue.init(called_block_buffer[0..]);
    block.writeDmem(0x30c, 0x89abcdef);
    block.returnFromCall();

    var queue = rsp.CommandQueue.init(command_queue_buffer[0..]);
    queue.writeDmem(0x308, 0x12345678);
    queue.call(&block);
    queue.writeDmem(0x310, 0xcafebabe);
    queue.stop();
    rsp.submitCommands(&queue);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x308, 0x12345678);
    try expectDmemWord(u32, 0x30c, 0x89abcdef);
    try expectDmemWord(u32, 0x310, 0xcafebabe);
}

fn indirectCalledCommandBlock() !void {
    loadCommandDispatcher();
    var block = rsp.CommandQueue.init(called_block_buffer[0..]);
    block.writeDmem(0x344, 0x89abcdef);
    block.returnFromCall();

    const target: u32 = @truncate(@intFromPtr(block.buffer.ptr) & 0x00ffffff);
    var queue = rsp.CommandQueue.init(command_queue_buffer[0..]);
    queue.writeDmem(0x340, target);
    queue.callIndirect(&block, 0x340);
    queue.writeDmem(0x348, 0xcafebabe);
    queue.stop();
    rsp.submitCommands(&queue);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x344, 0x89abcdef);
    try expectDmemWord(u32, 0x348, 0xcafebabe);
}

fn swappedCommandBuffers() !void {
    loadCommandDispatcher();
    var alternate = rsp.CommandQueue.init(alternate_queue_buffer[0..]);
    alternate.writeDmem(0x318, 0x89abcdef);
    alternate.swapBuffersToCaller(0);
    alternate.stop();

    var queue = rsp.CommandQueue.init(command_queue_buffer[0..]);
    queue.writeDmem(0x314, 0x12345678);
    queue.swapBuffers(&alternate, 0);
    queue.writeDmem(0x31c, 0xcafebabe);
    queue.stop();
    rsp.submitCommands(&queue);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x314, 0x12345678);
    try expectDmemWord(u32, 0x318, 0x89abcdef);
    try expectDmemWord(u32, 0x31c, 0xcafebabe);
}

fn continuousDoubleBufferedQueue() !void {
    loadCommandDispatcher();
    continuous_queue.init(.low);
    for (0..520) |index| {
        continuous_queue.writeDmem(0x400, @intCast(index));
    }
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);
    try expectDmemWord(u32, 0x400, 519);

    continuous_queue.writeDmem(0x404, 0x89abcdef);
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);
    try expectDmemWord(u32, 0x404, 0x89abcdef);
}

fn commandFetchBoundary() !void {
    loadCommandDispatcher();
    @memset(&boundary_queue_buffer, 0);
    for (boundary_queue_buffer[0..63]) |*word| word.* = 0x06000000;
    boundary_queue_buffer[63] = 0x01000350;
    boundary_queue_buffer[64] = 0x12345678;
    boundary_queue_buffer[65] = 0x00000000;
    n64.cache.writebackData(&boundary_queue_buffer);

    rsp.halt();
    rsp.waitHalted();
    rsp.io.readDmem(u32, 0x80).* = @truncate(@intFromPtr(&boundary_queue_buffer) & 0x1fffffff);
    rsp.io.status_register_write.* = rsp.io.status_set_signal7;
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x350, 0x12345678);
}

fn pollingSyncpoint() !void {
    loadCommandDispatcher();
    syncpoint_queue.init(.low);
    syncpoint_queue.writeDmem(0x320, 0x12345678);
    syncpoint_queue.syncpoint();
    if (!syncpoint_queue.waitSyncpointTimeout(rsp_timeout_attempts)) {
        rsp.halt();
        rsp.waitHalted();
        return error.RspSignalTimeout;
    }

    try expectDmemWord(u32, 0x320, 0x12345678);
    try testing.expect(!rsp.io.status_register_read.signal2);
    try testing.expect(!syncpoint_queue.storage.syncpoint_pending);

    syncpoint_queue.writeDmem(0x324, 0x89abcdef);
    syncpoint_queue.syncpoint();
    if (!syncpoint_queue.waitSyncpointTimeout(rsp_timeout_attempts)) {
        rsp.halt();
        rsp.waitHalted();
        return error.RspSignalTimeout;
    }
    try expectDmemWord(u32, 0x324, 0x89abcdef);
}

fn highPriorityQueue() !void {
    loadCommandDispatcher();
    rsp.io.status_register_write.* = rsp.io.status_set_signal0 | rsp.io.status_set_signal1 |
        rsp.io.status_clear_signal3 | rsp.io.status_clear_signal4 | rsp.io.status_clear_signal5;

    continuous_queue.init(.low);
    continuous_queue.writeDmem(0x330, 1);
    continuous_queue.waitThenWriteStatus(rsp.io.status_signal0, 0);
    continuous_queue.waitThenWriteStatus(rsp.io.status_signal1, 0);
    continuous_queue.writeDmem(0x334, 3);
    rsp.flush(&continuous_queue);
    try waitDmemValueTimeout(0x330, 1);

    high_priority_queue.init(.high);
    high_priority_queue.writeDmem(0x334, 2);
    rsp.submitHighPriority(&high_priority_queue);
    rsp.io.status_register_write.* = rsp.io.status_clear_signal0;
    if (!rsp.waitHighPriorityTimeout(&high_priority_queue, rsp_timeout_attempts)) {
        rsp.halt();
        rsp.waitHalted();
        return error.RspSignalTimeout;
    }

    try expectDmemWord(u32, 0x334, 2);
    try testing.expect(!rsp.io.status_register_read.signal3);
    try testing.expect(!rsp.io.status_register_read.signal4);
    rsp.io.status_register_write.* = rsp.io.status_clear_signal1;
    try waitQueueTimeout(&continuous_queue);
    try expectDmemWord(u32, 0x334, 3);
}

fn rdpBufferCommands() !void {
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2) | (1 << 0);
    n64.interfaces.mips.clearRdpInterrupt();
    loadCommandDispatcher();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_buffer);
    const buffer_address: u32 = @truncate(@intFromPtr(&rdp_buffer) & 0x00ffffff);
    const sentinel_address = buffer_address + @sizeOf(@TypeOf(rdp_buffer));

    rdp_queue.init(.low);
    rdp_queue.setRdpBuffer(buffer_address, buffer_address, sentinel_address);
    rdp_queue.appendRdpBuffer(buffer_address);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 38, 0, &.{0});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 39, 0, &.{0});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 36, 0, &.{ 0, 0, 0 });
    rdp_queue.writeOverlayCommand(&rdp_overlay, 26, 0, &.{});
    rsp.flush(&rdp_queue);
    if (!rsp.waitTimeout(&rdp_queue, 100_000_000)) return error.RspSignalTimeout;

    n64.cache.invalidateData(&rdp_buffer);
    try testing.expectEqual(@as(u64, 0xe600000000000000), rdp_buffer[0]);
    try testing.expectEqual(@as(u64, 0xe700000000000000), rdp_buffer[1]);
    try testing.expectEqual(@as(u64, 0xe400000000000000), rdp_buffer[2]);
    try testing.expectEqual(@as(u64, 0), rdp_buffer[3]);
    try expectDmemWord(u32, 0x1d0, buffer_address + 32);
    try expectDmemWord(u32, 0x1d4, sentinel_address);
    try testing.expectEqual(buffer_address, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
    try testing.expectEqual(buffer_address + 32, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);
    var dp_wait = rsp_timeout_attempts;
    while ((dp_status_write.* & 0x300) != 0) : (dp_wait -= 1) {
        if (dp_wait == 0) return error.RdpBufferIdleTimeout;
    }

    rdp_rollover_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_rollover_buffer);
    const rollover_address: u32 = @truncate(@intFromPtr(&rdp_rollover_buffer) & 0x00ffffff);
    rdp_queue.writeDmem(0x1c8, buffer_address);
    rdp_queue.writeDmem(0x1cc, rollover_address);
    rdp_queue.setRdpBuffer(buffer_address + 32, buffer_address, buffer_address + 32);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 39, 0, &.{0});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_rollover_buffer);
    try testing.expectEqual(@as(u64, 0xe700000000000000), rdp_rollover_buffer[0]);
    try testing.expectEqual(@as(u64, 0xffffffffffffffff), rdp_rollover_buffer[1]);
    try expectDmemWord(u32, 0x1d0, rollover_address + 8);
    try expectDmemWord(u32, 0x1d4, rollover_address + 0x10000);
    try expectDmemWord(u32, 0x1c8, rollover_address);
    try expectDmemWord(u32, 0x1cc, buffer_address);
    try testing.expectEqual(rollover_address, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
    try testing.expectEqual(rollover_address + 8, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);
    dp_wait = rsp_timeout_attempts;
    while ((dp_status_write.* & 0x300) != 0) : (dp_wait -= 1) {
        if (dp_wait == 0) return error.RdpBufferIdleTimeout;
    }
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpDebugHandoff() !void {
    loadCommandDispatcher();
    rdp_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_buffer);
    const buffer_address: u32 = @truncate(@intFromPtr(&rdp_buffer) & 0x00ffffff);

    var queue = rsp.CommandQueue.init(command_queue_buffer[0..]);
    queue.setRdpBuffer(buffer_address, buffer_address, buffer_address + @sizeOf(@TypeOf(rdp_buffer)));
    queue.stop();
    rsp.submitCommands(&queue);
    rsp.writeDmemByte(rsp.rdp_target_bitdepth_dmem, 0xff);
    rsp.io.status_register_write.* = rsp.io.status_clear_signal0 | rsp.io.status_clear_interrupt;
    rsp.runAsync(rsp.programs.command_dispatcher.pc_start);

    var remaining = rsp_timeout_attempts;
    while (!rsp.io.status_register_read.signal0) : (remaining -= 1) {
        if (remaining != 0) continue;
        rsp.halt();
        rsp.waitHalted();
        return error.RspSignalTimeout;
    }
    rsp.io.status_register_write.* = rsp.io.status_clear_signal0 | rsp.io.status_clear_interrupt;
    try waitQueueTimeout(&rdp_queue);
    try testing.expectEqual(buffer_address, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
}

fn rdpAddressFixups() !void {
    loadCommandDispatcher();
    rsp.writeDmemByte(rsp.rdp_target_bitdepth_dmem, 0);
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_buffer) & 0x00ffffff);
    const lookup_base = output_address + 0x100;
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2) | (1 << 0);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + 2 * @sizeOf(u64);
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;
    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 1, 3 << 2, &.{lookup_base});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 62, 0, &.{(@as(u32, 3) << 26) | 0x40});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 39, 0, &.{0});
    rsp.flush(&rdp_queue);
    try waitBrokeTimeout();

    n64.cache.invalidateData(&rdp_buffer);
    try testing.expectEqual(
        @as(u64, 0xfe00000000000000) | (@as(u64, (@as(u32, 3) << 26) + lookup_base + 0x40)),
        rdp_buffer[0],
    );
    try testing.expectEqual(@as(u64, 0xe700000000000000), rdp_buffer[1]);
    const state = rsp.overlayState(&rdp_overlay);
    try testing.expectEqual(lookup_base, std.mem.readInt(u32, state[24 + 3 * @sizeOf(u32) ..][0..4], .big));
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2) | (1 << 0);
    n64.interfaces.mips.clearRdpInterrupt();
    while (rsp.io.dma_busy.* != 0) {}
    rsp.halt();
    rsp.waitHalted();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpFullSyncState() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.io.status_register_write.* = rsp.io.status_clear_signal1 | rsp.io.status_clear_signal2;

    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff };
    rdp_syncpoint_source = .{ 0x13579bdf, 0x2468ace0 };
    rdp_sync_state_output = .{ 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff };
    n64.cache.writebackData(&rdp_buffer);
    n64.cache.writebackData(&rdp_syncpoint_source);
    n64.cache.writebackData(&rdp_sync_state_output);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_buffer) & 0x00ffffff);
    const syncpoint_address: u32 = @truncate(@intFromPtr(&rdp_syncpoint_source) & 0x00ffffff);
    const state_output_address: u32 = @truncate(@intFromPtr(&rdp_sync_state_output) & 0x00ffffff);

    var state = rsp.overlayState(&rdp_overlay);
    std.mem.writeInt(u32, state[16..20], state_output_address, .big);
    std.mem.writeInt(u32, state[20..24], syncpoint_address, .big);
    rsp.writebackOverlayState(&rdp_overlay);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(u64);
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;

    rdp_queue.init(.low);
    // A held batch must preserve command order and become visible when the
    // full-sync handler publishes its completed DMA range.
    rdp_queue.holdRdpPublication();
    rdp_queue.writeOverlayCommand(&rdp_overlay, 41, 0x00abcdef, &.{0x89abcdef});
    rsp.flush(&rdp_queue);
    if (!rsp.waitTimeout(&rdp_queue, rsp_timeout_attempts)) {
        const status: u32 = @bitCast(rsp.io.status_register_read.*);
        n64.cache.invalidateData(&rdp_buffer);
        n64.cache.invalidateData(&rdp_sync_state_output);
        n64.debug.print("\n      sync PC=0x{x:0>4} status=0x{x:0>8} current=0x{x:0>8} ongoing=0x{x:0>2}\n", .{
            rsp.io.program_counter.*,
            status,
            rsp.io.readDmem(u32, 0x1d0).*,
            rsp.io.readDmem(u8, rsp.rdp_syncfull_ongoing_dmem).*,
        });
        n64.debug.print("      rdp=0x{x:0>16} state={x:0>8},{x:0>8},{x:0>8},{x:0>8}\n", .{
            rdp_buffer[0],
            rdp_sync_state_output[0],
            rdp_sync_state_output[1],
            rdp_sync_state_output[2],
            rdp_sync_state_output[3],
        });
        rsp.io.status_register_write.* = rsp.io.status_clear_signal1 | rsp.io.status_clear_signal2;
        rsp.halt();
        rsp.waitHalted();
        return error.RspSignalTimeout;
    }

    n64.cache.invalidateData(&rdp_buffer);
    n64.cache.invalidateData(&rdp_sync_state_output);
    try testing.expectEqual(@as(u64, 0xe9abcdef89abcdef), rdp_buffer[0]);
    try testing.expectEqual(@as(u32, 0xe9abcdef), rdp_sync_state_output[0]);
    try testing.expectEqual(@as(u32, 0x89abcdef), rdp_sync_state_output[1]);
    try testing.expectEqual(@as(u32, 0x13579bdf), rdp_sync_state_output[2]);
    try testing.expectEqual(@as(u32, 0x2468ace0), rdp_sync_state_output[3]);
    try testing.expect(rsp.io.status_register_read.signal1);
    try expectDmemWord(u8, rsp.rdp_syncfull_ongoing_dmem, 0x40);
    try expectDmemWord(u8, rsp.rdp_publication_held_dmem, 0);
    try testing.expectEqual(output_address + 8, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);

    rsp.io.status_register_write.* = rsp.io.status_clear_signal1;
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpColorImageFixup() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_color_image_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_color_image_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_color_image_buffer) & 0x00ffffff);
    const image_base = output_address + 0x100;
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(rdp_color_image_buffer));
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;

    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 17, 1, &.{});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 1, 2 << 2, &.{image_base});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 22, 0, &.{0x89abcdef});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 63, (2 << 19) | 319, &.{(@as(u32, 2) << 26) | 0x40});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 63, (3 << 19) | 159, &.{(@as(u32, 2) << 26) | 0x80});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_color_image_buffer);
    try testing.expectEqual(@as(u64, 0xf70000008d738d73), rdp_color_image_buffer[0]);
    try testing.expectEqual(
        @as(u64, 0xff10013f00000000) | (@as(u64, (@as(u32, 2) << 26) + image_base + 0x40)),
        rdp_color_image_buffer[1],
    );
    try testing.expectEqual(@as(u64, 0xf70000008d738d73), rdp_color_image_buffer[2]);
    try testing.expectEqual(
        @as(u64, 0xff18009f00000000) | (@as(u64, (@as(u32, 2) << 26) + image_base + 0x80)),
        rdp_color_image_buffer[3],
    );
    try testing.expectEqual(@as(u64, 0xf700000089abcdef), rdp_color_image_buffer[4]);
    try testing.expectEqual(@as(i8, -125), rsp.io.readDmem(i8, rsp.rdp_target_bitdepth_dmem).*);

    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.writeDmemByte(rsp.rdp_target_bitdepth_dmem, 0);
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpModeState() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_mode_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_mode_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_mode_buffer) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(rdp_mode_buffer));
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;

    const initial_mode = [_]u32{ 0x01020304, 0x11121314, 0x21222324, 0x31323334, 0x41424344, 0x51525354, 0, 0x71727374 };
    for (initial_mode, 0..) |word, index| {
        rsp.io.readDmem(u32, rsp.rdp_mode_dmem + @as(u32, @intCast(index * 4))).* = word;
    }
    var state = rsp.overlayState(&rdp_overlay);
    for (0..24) |index| {
        std.mem.writeInt(u32, state[112 + index * 4 ..][0..4], 0x80000000 + @as(u32, @intCast(index)), .big);
    }
    rsp.writebackOverlayState(&rdp_overlay);

    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 6, 0, &.{});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 58, 0x001122, &.{0xaabbccdd});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 19, (2 << 16) | 0x55, &.{0});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 18, 0x001002, &.{0x003004});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 47, 0x00200000, &.{0x12345678});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_mode_buffer);
    try testing.expectEqual(@as(u64, 0xfa001122aabbccdd), rdp_mode_buffer[0]);
    try testing.expectEqual(@as(u64, 0xfa020077aabbccdd), rdp_mode_buffer[1]);
    try testing.expectEqual(@as(u64, 0xed00100200003004), rdp_mode_buffer[2]);
    try testing.expectEqual(@as(u64, 0xef20000012345678), rdp_mode_buffer[3]);
    try testing.expectEqual(@as(u64, 0xed00100200002004), rdp_mode_buffer[4]);
    for (initial_mode, 0..) |word, index| {
        try expectDmemWord(u32, rsp.programs.rdp_overlay.state_offset + 112 + @as(u32, @intCast(index * 4)), word);
    }
    for (0..8) |index| {
        try expectDmemWord(
            u32,
            rsp.programs.rdp_overlay.state_offset + 144 + @as(u32, @intCast(index * 4)),
            0x80000000 + @as(u32, @intCast(index)),
        );
    }
    try expectDmemWord(u32, rsp.rdp_mode_dmem + 24, 0x00200000);
    try expectDmemWord(u32, rsp.rdp_mode_dmem + 28, 0x12345678);

    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpRenderModeCommands() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_render_mode_buffer = .{0xffffffffffffffff} ** 10;
    n64.cache.writebackData(&rdp_render_mode_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_render_mode_buffer) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(rdp_render_mode_buffer));
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;
    for (0..8) |index| {
        rsp.io.readDmem(u32, rsp.rdp_mode_dmem + @as(u32, @intCast(index * 4))).* = 0;
    }

    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 27, 0x123456, &.{ 0x89abcdef, 0, 0 });
    rdp_queue.writeOverlayCommand(&rdp_overlay, 25, 0, &.{0});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 24, 0, &.{0});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 5, 0x654321, &.{0x01234567});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 20, 4, &.{ 0xfffffff7, 8 });
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_render_mode_buffer);
    const expected = [_]u64{
        0xfc12345689abcdef, 0xef00000000000200,
        0xfc12345689abcdef, 0xef00000000000200,
        0xfc12345689abcdef, 0xef00000000000200,
        0xfc65432101234567, 0xef10000000000200,
        0xef10000000000208, 0x0000000000000000,
    };
    for (expected, rdp_render_mode_buffer) |expected_word, actual_word| {
        try testing.expectEqual(expected_word, actual_word);
    }
    try expectDmemWord(u32, rsp.rdp_mode_dmem + 16, 0);
    try expectDmemWord(u32, rsp.rdp_mode_dmem + 20, 0);
    try expectDmemWord(u32, rsp.rdp_mode_dmem + 24, 0x00100000);
    try expectDmemWord(u32, rsp.rdp_mode_dmem + 28, 0x208);

    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpModeStack() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_mode_stack_buffer = .{0xffffffffffffffff} ** 4;
    n64.cache.writebackData(&rdp_mode_stack_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_mode_stack_buffer) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(rdp_mode_stack_buffer));
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;
    for (0..8) |index| {
        rsp.io.readDmem(u32, rsp.rdp_mode_dmem + @as(u32, @intCast(index * 4))).* = 0;
    }

    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 18, 0x001002, &.{0x003004});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 6, 0, &.{});
    rdp_queue.writeDmem(rsp.rdp_mode_dmem, 0x7c123456);
    rdp_queue.writeDmem(rsp.rdp_mode_dmem + 4, 0x89abcdef);
    rdp_queue.writeDmem(rsp.rdp_mode_dmem + 28, 0x12345678);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 7, 0, &.{});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_mode_stack_buffer);
    const expected = [_]u64{
        0xed00100200003004,
        0xed00100200003004,
        0xfc00000000000000,
        0xef00000000000200,
    };
    for (expected, rdp_mode_stack_buffer) |expected_word, actual_word| {
        try testing.expectEqual(expected_word, actual_word);
    }
    for (0..7) |index| {
        try expectDmemWord(u32, rsp.rdp_mode_dmem + @as(u32, @intCast(index * 4)), 0);
    }
    try expectDmemWord(u32, rsp.rdp_mode_dmem + 28, 0x200);

    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpResetMode() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_reset_mode_buffer = .{0xffffffffffffffff} ** 4;
    n64.cache.writebackData(&rdp_reset_mode_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_reset_mode_buffer) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(rdp_reset_mode_buffer));
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;
    for (0..8) |index| {
        rsp.io.readDmem(u32, rsp.rdp_mode_dmem + @as(u32, @intCast(index * 4))).* = 0xffffffff;
    }
    rsp.io.readDmem(u32, rsp.rdp_mode_dmem + 24).* = 0x00200000;

    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 18, 0x001002, &.{0x003004});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 4, 0x123456, &.{ 0x89abcdef, 0, 0 });
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_reset_mode_buffer);
    const expected = [_]u64{
        0xed00100200002004,
        0xed00100200003004,
        0xfc12345689abcdef,
        0xef00000000000200,
    };
    for (expected, rdp_reset_mode_buffer) |expected_word, actual_word| {
        try testing.expectEqual(expected_word, actual_word);
    }
    const expected_mode = [_]u32{ 0x7c123456, 0x89abcdef, 0, 0, 0, 0, 0, 0x200 };
    for (expected_mode, 0..) |word, index| {
        try expectDmemWord(u32, rsp.rdp_mode_dmem + @as(u32, @intCast(index * 4)), word);
    }

    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpPassthroughTriangles() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_passthrough_triangle_buffer = .{0xffffffff} ** 52;
    n64.cache.writebackData(&rdp_passthrough_triangle_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_passthrough_triangle_buffer) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(rdp_passthrough_triangle_buffer));
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;
    rsp.io.readDmem(u32, rsp.rdp_mode_dmem + 24).* = 0x38000000;

    var short_arguments: [7]u32 = undefined;
    for (&short_arguments, 1..) |*word, index| word.* = 0x10000000 + @as(u32, @intCast(index));
    var long_arguments: [43]u32 = undefined;
    for (&long_arguments, 1..) |*word, index| word.* = 0x20000000 + @as(u32, @intCast(index));
    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 8, 1, &short_arguments);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 15, 2, &long_arguments);
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_passthrough_triangle_buffer);
    try testing.expectEqual(@as(u32, 0xc8380001), rdp_passthrough_triangle_buffer[0]);
    for (rdp_passthrough_triangle_buffer[1..8], 1..) |word, index| {
        try testing.expectEqual(0x10000000 + @as(u32, @intCast(index)), word);
    }
    try testing.expectEqual(@as(u32, 0xcf380002), rdp_passthrough_triangle_buffer[8]);
    for (rdp_passthrough_triangle_buffer[9..], 1..) |word, index| {
        try testing.expectEqual(0x20000000 + @as(u32, @intCast(index)), word);
    }

    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpTriangleTrivialReject() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);

    // Zero negated reject flags means every vertex is outside at least one
    // enlarged clip plane, so command 30 must emit no triangle and return.
    var overlay_state = rsp.overlayState(&rdp_overlay);
    @memset(overlay_state[208..304], 0);
    rsp.writebackOverlayState(&rdp_overlay);

    rdp_triangle_cull_buffer[0] = 0xffffffffffffffff;
    n64.cache.writebackData(&rdp_triangle_cull_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_triangle_cull_buffer) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(rdp_triangle_cull_buffer));
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;

    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 30, 0, &.{});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 39, 0, &.{0});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_triangle_cull_buffer);
    try testing.expectEqual(@as(u64, 0xe700000000000000), rdp_triangle_cull_buffer[0]);

    // Passing reject flags with a real clip-plane bit takes libdragon's clip
    // exit. The current overlay, like its command wrapper reference, routes
    // that exit through the no-output cull completion path.
    overlay_state = rsp.overlayState(&rdp_overlay);
    inline for (.{ 208, 240, 272 }) |vertex_offset| {
        overlay_state[vertex_offset + 6] = 1;
        overlay_state[vertex_offset + 7] = 0x3f;
    }
    rsp.writebackOverlayState(&rdp_overlay);
    rdp_triangle_cull_buffer[0] = 0xffffffffffffffff;
    n64.cache.writebackData(&rdp_triangle_cull_buffer);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;
    rdp_queue.writeOverlayCommand(&rdp_overlay, 30, 0, &.{});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 39, 0, &.{0});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);
    n64.cache.invalidateData(&rdp_triangle_cull_buffer);
    try testing.expectEqual(@as(u64, 0xe700000000000000), rdp_triangle_cull_buffer[0]);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpTriangleSortAndNormal() !void {
    loadCommandDispatcher();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    var overlay_state = rsp.overlayState(&rdp_overlay);
    @memset(overlay_state[208..304], 0);
    const xy = [_]u32{ 0x000a001e, 0x0014000a, 0x001e0014 };
    inline for (.{ 208, 240, 272 }, xy) |vertex_offset, value| {
        std.mem.writeInt(u32, overlay_state[vertex_offset..][0..4], value, .big);
        std.mem.writeInt(u16, overlay_state[vertex_offset + 4 ..][0..2], 0x1234, .big);
        overlay_state[vertex_offset + 7] = 0x3f;
        std.mem.writeInt(u32, overlay_state[vertex_offset + 8 ..][0..4], 0x11223344, .big);
        std.mem.writeInt(u32, overlay_state[vertex_offset + 16 ..][0..4], 0x00010000, .big);
        std.mem.writeInt(u32, overlay_state[vertex_offset + 20 ..][0..4], 0x00010000, .big);
    }
    rsp.writebackOverlayState(&rdp_overlay);

    rdp_queue.init(.low);
    @memset(&rdp_triangle_buffer, 0xff);
    n64.cache.writebackData(&rdp_triangle_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_triangle_buffer) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(rdp_triangle_buffer));
    rsp.writeDmemByte(rsp.rdp_syncfull_ongoing_dmem, 0x40);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 30, 0x700, &.{});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);
    n64.cache.invalidateData(&rdp_triangle_buffer);
    const primitive = std.mem.asBytes(&rdp_triangle_buffer);

    try expectBufferWord(u16, primitive, 2, 30);
    try expectBufferWord(u16, primitive, 4, 20);
    try expectBufferWord(u16, primitive, 6, 10);
    // Six signed 16.16 edge words in RDP order: XL, DxLDy, XH, DxHDy,
    // XM, DxMDy. These are the exact RSP reciprocal/refinement results, not
    // idealized CPU divisions.
    try expectBufferWord(u32, primitive, 8, 0x00078000);
    try expectBufferWord(u32, primitive, 12, 0xfffdfff8);
    try expectBufferWord(u32, primitive, 16, 0x00054001);
    try expectBufferWord(u32, primitive, 20, 0xffff7ffe);
    try expectBufferWord(u32, primitive, 24, 0x00047ffe);
    try expectBufferWord(u32, primitive, 28, 0x00010003);
    // Constant attributes have zero derivatives. The normalized 1/W lane is
    // 0x7fff (libdragon's exact-one workaround followed by its divide by two).
    try expectBufferWord(u32, primitive, 0x20, 0x00110022);
    try expectBufferWord(u32, primitive, 0x24, 0x00330044);
    inline for (.{ 0x28, 0x2c, 0x30, 0x34, 0x38, 0x3c }) |offset| {
        try expectBufferWord(u32, primitive, offset, 0);
    }
    try expectBufferWord(u32, primitive, 0x60, 0);
    try expectBufferWord(u32, primitive, 0x64, 0x7fff1234);
    inline for (.{ 0x68, 0x6c, 0x70, 0x74, 0x78, 0x7c }) |offset| {
        try expectBufferWord(u32, primitive, offset, 0);
    }
    try expectBufferWord(u32, primitive, 0xa0, 0x12340000);
    try expectBufferWord(u32, primitive, 0xa4, 0);
    try expectBufferWord(u32, primitive, 0xa8, 0);
    try expectBufferWord(u32, primitive, 0xac, 0);
    var expected_primitive: [176]u8 = undefined;
    @memcpy(&expected_primitive, primitive[0..176]);

    // Force the exact triangle slow path: the current buffer has no room, so
    // it must swap the resident dynamic-buffer pair, call RdpSetBuffer, restore
    // the primitive size, and resume the asynchronous DMA into the new buffer.
    @memset(&rdp_triangle_rollover_buffer, 0xff);
    n64.cache.writebackData(&rdp_triangle_rollover_buffer);
    const rollover_address: u32 = @truncate(@intFromPtr(&rdp_triangle_rollover_buffer) & 0x00ffffff);
    const old_end = output_address;
    rsp.io.readDmem(u32, 0x1d0).* = old_end;
    rsp.io.readDmem(u32, 0x1d4).* = old_end;
    rsp.io.readDmem(u32, 0x1c8).* = output_address;
    rsp.io.readDmem(u32, 0x1cc).* = rollover_address;
    rsp.writeDmemByte(rsp.rdp_syncfull_ongoing_dmem, 0);
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2) | (1 << 0);
    n64.interfaces.mips.clearRdpInterrupt();
    // RdpSetBuffer advances END from DPC CURRENT to rdp_current before switching
    // START. Pre-consume the valid old range so those two cursors agree.
    dp_start_write.* = output_address;
    dp_end_write.* = old_end;
    var dp_wait = rsp_timeout_attempts;
    while ((dp_status_write.* & 0x300) != 0) : (dp_wait -= 1) {
        if (dp_wait == 0) return error.RdpPrepIdleTimeout;
    }
    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 30, 0x700, &.{});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_triangle_rollover_buffer);
    const rollover_primitive = std.mem.asBytes(&rdp_triangle_rollover_buffer);
    for (expected_primitive, rollover_primitive[0..176]) |expected, actual| {
        try testing.expectEqual(expected, actual);
    }
    try expectDmemWord(u32, 0x1d0, rollover_address + 176);
    try expectDmemWord(u32, 0x1d4, rollover_address + rsp.rdp_dynamic_buffer_len);
    try expectDmemWord(u32, 0x1c8, rollover_address);
    try expectDmemWord(u32, 0x1cc, output_address);
    rsp.halt();
    rsp.waitHalted();
    rsp.io.waitDma();
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2) | (1 << 0);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpTriangleRender() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2) | (1 << 0);
    n64.interfaces.mips.clearRdpInterrupt();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);

    @memset(&rdp_triangle_render_commands, 0);
    @memset(&rdp_triangle_render_target, n64.graphics.color.Rgba16.black);
    n64.cache.writebackData(&rdp_triangle_render_commands);
    n64.cache.writebackData(&rdp_triangle_render_target);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_triangle_render_commands) & 0x00ffffff);
    const target_address: u32 = @truncate(@intFromPtr(&rdp_triangle_render_target) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(rdp_triangle_render_commands));
    // Suppress the triangle helper's live DP_END update while it constructs
    // the primitive. The completed bytes are submitted below with deterministic
    // setup commands so a malformed test cannot deadlock the resident queue.
    rsp.writeDmemByte(rsp.rdp_syncfull_ongoing_dmem, 0x40);

    var overlay_state = rsp.overlayState(&rdp_overlay);
    @memset(overlay_state[208..304], 0);
    const xy = [_]u32{ 0x00040004, 0x00180008, 0x00040018 };
    inline for (.{ 208, 240, 272 }, xy) |vertex_offset, value| {
        std.mem.writeInt(u32, overlay_state[vertex_offset..][0..4], value, .big);
        overlay_state[vertex_offset + 7] = 0x3f;
        std.mem.writeInt(u32, overlay_state[vertex_offset + 8 ..][0..4], 0xff0000ff, .big);
        std.mem.writeInt(u32, overlay_state[vertex_offset + 16 ..][0..4], 0x00010000, .big);
        std.mem.writeInt(u32, overlay_state[vertex_offset + 20 ..][0..4], 0x00010000, .big);
    }
    rsp.writebackOverlayState(&rdp_overlay);

    rdp_queue.init(.low);
    // Libdragon encodes the RDP triangle opcode in bits 8..15 of the command
    // payload. 0xCC is the shaded, untextured, no-Z variant.
    rdp_queue.writeOverlayCommand(&rdp_overlay, 30, 0xcc00, &.{});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    const emitted_bytes = rsp.io.readDmem(u32, 0x1d0).* - output_address;
    if (emitted_bytes != 96) return error.UnexpectedRdpTriangleSize;
    n64.cache.invalidateData(&rdp_triangle_render_commands);
    const setup_words = 5;
    std.mem.copyBackwards(
        u64,
        rdp_triangle_render_commands[setup_words .. setup_words + emitted_bytes / 8],
        rdp_triangle_render_commands[0 .. emitted_bytes / 8],
    );
    const other_modes: u64 = @bitCast(rdp.OtherModes{});
    rdp_triangle_render_commands[0] = 0xe700000000000000;
    rdp_triangle_render_commands[1] = 0xff10000700000000 | @as(u64, target_address);
    rdp_triangle_render_commands[2] = 0xed00000000020020;
    rdp_triangle_render_commands[3] = other_modes;
    rdp_triangle_render_commands[4] = 0xfc887f1088fe793c;
    const end_index = setup_words + emitted_bytes / 8;
    rdp_triangle_render_commands[end_index] = 0xe900000000000000;
    n64.cache.writebackData(rdp_triangle_render_commands[0 .. end_index + 1]);

    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2) | (1 << 0);
    n64.interfaces.mips.clearRdpInterrupt();
    dp_start_write.* = output_address;
    dp_end_write.* = output_address + @as(u32, @intCast((end_index + 1) * @sizeOf(u64)));
    var dp_wait = rsp_timeout_attempts;
    while ((dp_status_write.* & 0x300) != 0) : (dp_wait -= 1) {
        if (dp_wait == 0) return error.RdpTriangleRenderTimeout;
    }

    n64.cache.invalidateData(&rdp_triangle_render_target);
    var changed: usize = 0;
    var checksum: u32 = 0;
    for (rdp_triangle_render_target) |pixel| {
        const bits: u16 = @bitCast(pixel);
        if (bits != @as(u16, @bitCast(n64.graphics.color.Rgba16.black))) changed += 1;
        checksum = checksum *% 16777619 ^ bits;
    }
    try testing.expectEqual(@as(usize, 14), changed);
    try testing.expectEqual(@as(u32, 0x8bc20d40), checksum);

    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2) | (1 << 0);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.writeDmemByte(rsp.rdp_syncfull_ongoing_dmem, 0);
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpTriangleData() !void {
    loadCommandDispatcher();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 31, 0, &.{ 0x11223344, 0x55667788, 0x99aabbcc, 0x01020304, 0x05060708, 0x090a0b0c });
    rdp_queue.writeOverlayCommand(&rdp_overlay, 31, 32, &.{ 0x21324354, 0x65768798, 0xa9bacbdc, 0x11121314, 0x15161718, 0x191a1b1c });
    rdp_queue.writeOverlayCommand(&rdp_overlay, 31, 64, &.{ 0x31425364, 0x758697a8, 0xb9cadbec, 0x21222324, 0x25262728, 0x292a2b2c });
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    const state = rsp.programs.rdp_overlay.state_offset + 208;
    const expected = [_]u32{
        0x11223344, 0x556677ff, 0x99aabbcc, 0x01020304, 0x05060708, 0x090a0b0c,
        0,          0,          0x21324354, 0x657687ff, 0xa9bacbdc, 0x11121314,
        0x15161718, 0x191a1b1c, 0,          0,          0x31425364, 0x758697ff,
        0xb9cadbec, 0x21222324, 0x25262728, 0x292a2b2c,
    };
    for (expected, 0..) |word, index| {
        try expectDmemWord(u32, state + @as(u32, @intCast(index * 4)), word);
    }
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpExclusiveRectangles() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_rectangle_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_rectangle_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_rectangle_buffer) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(rdp_rectangle_buffer));
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;
    rsp.io.readDmem(u32, rsp.rdp_mode_dmem + 24).* = 0x00200000;

    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 2, 0x00abcdef, &.{0x01234567});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 16, 0x00123456, &.{ 0x89abcdef, 0x0badcafe, 0x12345678 });
    rdp_queue.writeDmem(rsp.rdp_mode_dmem + 24, 0);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 2, 0x00abcdef, &.{0x76543210});
    rdp_queue.writeOverlayCommand(&rdp_overlay, 16, 0x00123456, &.{ 0xfedcba98, 0xfeedface, 0x87654321 });
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_rectangle_buffer);
    try testing.expectEqual(@as(u64, 0xf6ab8deb01234567), rdp_rectangle_buffer[0]);
    try testing.expectEqual(@as(u64, 0xe411f45289abcdef), rdp_rectangle_buffer[1]);
    try testing.expectEqual(@as(u64, 0x0badcafe48d05678), rdp_rectangle_buffer[2]);
    try testing.expectEqual(@as(u64, 0xf6abcdef76543210), rdp_rectangle_buffer[3]);
    try testing.expectEqual(@as(u64, 0xe4123456fedcba98), rdp_rectangle_buffer[4]);
    try testing.expectEqual(@as(u64, 0xfeedface87654321), rdp_rectangle_buffer[5]);

    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpClearZBuffer() !void {
    loadCommandDispatcher();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    @memset(&rdp_clear_z_target, 0x1234);
    @memset(&rdp_clear_z_temporary, 0xcc);
    n64.cache.writebackData(&rdp_clear_z_target);
    n64.cache.writebackData(&rdp_clear_z_temporary);
    var overlay_state = rsp.overlayState(&rdp_overlay);
    std.mem.writeInt(u32, overlay_state[24..28], 0x89abcdef, .big);
    rsp.writebackOverlayState(&rdp_overlay);

    const target_address: u32 = @truncate(@intFromPtr(&rdp_clear_z_target) & 0x00ffffff);
    const temporary_address: u32 = @truncate(@intFromPtr(&rdp_clear_z_temporary) & 0x00ffffff);
    const target_dma_size: u32 = (1 << 12) | (4096 - 1);
    rdp_queue.init(.low);
    rdp_queue.writeOverlayCommand(
        &rdp_overlay,
        3,
        target_address,
        &.{ target_dma_size, temporary_address, 0x7fff },
    );
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_clear_z_target);
    for (rdp_clear_z_target) |value| try testing.expectEqual(@as(u16, 0x7fff), value);
    try expectDmemWord(u32, rsp.programs.rdp_overlay.state_offset + 24, 0x89abcdef);
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rspBackedRdpQueue() !void {
    loadCommandDispatcher();
    rsp.releaseRdpToDirect();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    @memset(rsp_rdp_dynamic_buffers[0][0..], 0xff);
    @memset(rsp_rdp_dynamic_buffers[1][0..], 0xff);
    n64.cache.writebackData(&rsp_rdp_dynamic_buffers);
    rdp_queue.init(.low);
    var render_queue = rdp.RspRenderQueue.init(rdp.RspQueue.init(
        &rdp_queue,
        rsp_rdp_command_buffer[0..],
        .{ rsp_rdp_dynamic_buffers[0][0..], rsp_rdp_dynamic_buffers[1][0..] },
    ));
    render_queue.cmd_queue.pipeSync();
    render_queue.execute();
    try waitQueueTimeout(&rdp_queue);

    const start: u32 = @truncate(@intFromPtr(&rsp_rdp_command_buffer) & 0x00ffffff);
    const first_dynamic: u32 = @truncate(@intFromPtr(&rsp_rdp_dynamic_buffers[0]) & 0x00ffffff);
    const second_dynamic: u32 = @truncate(@intFromPtr(&rsp_rdp_dynamic_buffers[1]) & 0x00ffffff);
    try testing.expectEqual(@as(u64, 0xe700000000000000), rsp_rdp_command_buffer[0]);
    try testing.expectEqual(start, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
    try testing.expectEqual(start + 8, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);
    try expectDmemWord(u32, 0x1d4, start + 8);
    try expectDmemWord(u32, 0x1c8, first_dynamic);
    try expectDmemWord(u32, 0x1cc, second_dynamic);

    rdp_queue.writeOverlayCommand(&rdp_overlay, 39, 0, &.{0});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);
    n64.cache.invalidateData(&rsp_rdp_dynamic_buffers[1]);
    try testing.expectEqual(
        @as(u64, 0xe700000000000000),
        std.mem.readInt(u64, rsp_rdp_dynamic_buffers[1][0..8], .big),
    );
    try testing.expectEqual(second_dynamic, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
    try testing.expectEqual(second_dynamic + 8, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);
    try expectDmemWord(u32, 0x1d0, second_dynamic + 8);
    try expectDmemWord(u32, 0x1d4, second_dynamic + rsp.rdp_dynamic_buffer_len);
    rsp.unregisterOverlay(&rdp_overlay);
}

fn directRdpRenderer() !void {
    @memset(&direct_rdp_render_target, n64.graphics.color.Rgba32.black);
    n64.cache.writebackData(&direct_rdp_render_target);
    const image = n64.graphics.image.ImgRgba32{
        .width = 4,
        .height = 4,
        .texel_data = direct_rdp_render_target[0..],
    };
    var render_queue = rdp.DirectRenderQueue.init(.{ .buffer = direct_rdp_command_buffer[0..] });
    render_queue.setFrameBuffer(image);
    render_queue.clearScreen(n64.graphics.color.Rgba32.green);
    const fence = rdp.syncFull(&render_queue);
    if (!fence.waitTimeout(rsp_timeout_attempts)) return error.RdpFenceTimeout;

    n64.cache.invalidateData(&direct_rdp_render_target);
    for (direct_rdp_render_target) |pixel| {
        try testing.expectEqual(n64.graphics.color.Rgba32.green, pixel);
    }
}

fn rdpCompletionFence() !void {
    loadCommandDispatcher();
    rdp_queue.init(.low);
    var render_queue = rdp.RspRenderQueue.init(rdp.RspQueue.init(
        &rdp_queue,
        rsp_rdp_command_buffer[0..],
        .{ rsp_rdp_dynamic_buffers[0][0..], rsp_rdp_dynamic_buffers[1][0..] },
    ));
    const fence = rdp.syncFull(&render_queue);
    if (!fence.waitTimeout(rsp_timeout_attempts)) return error.RdpFenceTimeout;

    const start: u32 = @truncate(@intFromPtr(&rsp_rdp_command_buffer) & 0x00ffffff);
    try testing.expectEqual(@as(u64, 0xe900000000000000), rsp_rdp_command_buffer[0]);
    try testing.expectEqual(start, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
    try testing.expectEqual(start + 8, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);
    try testing.expect(fence.isComplete());
    rsp.releaseRdpToDirect();
}

fn overlayBackedRdpRenderer() !void {
    loadCommandDispatcher();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    @memset(&overlay_rdp_render_target, n64.graphics.color.Rgba32.black);
    n64.cache.writebackData(&overlay_rdp_render_target);

    rdp_queue.init(.low);
    const image = n64.graphics.image.ImgRgba32{
        .width = 4,
        .height = 4,
        .texel_data = overlay_rdp_render_target[0..],
    };
    var render_queue = rdp.OverlayRenderQueue.init(rdp.OverlayQueue.init(
        &rdp_queue,
        &rdp_overlay,
        .{ rsp_rdp_dynamic_buffers[0][0..], rsp_rdp_dynamic_buffers[1][0..] },
    ));
    render_queue.setFrameBuffer(image);
    render_queue.clearScreen(n64.graphics.color.Rgba32.red);
    const fence = rdp.syncFull(&render_queue);
    try waitQueueTimeout(&rdp_queue);
    if (!fence.waitTimeout(rsp_timeout_attempts)) return error.RdpFenceTimeout;
    n64.cache.invalidateData(&overlay_rdp_render_target);
    for (overlay_rdp_render_target) |pixel| {
        try testing.expectEqual(n64.graphics.color.Rgba32.red, pixel);
    }

    rsp.io.status_register_write.* = rsp.io.status_clear_signal1;
    @memset(&overlay_rdp_render_target, n64.graphics.color.Rgba32.black);
    n64.cache.writebackData(&overlay_rdp_render_target);
    render_queue.clear();
    render_queue.setFrameBuffer(image);
    render_queue.clearScreen(n64.graphics.color.Rgba32.blue);
    const second_fence = rdp.syncFull(&render_queue);
    try waitQueueTimeout(&rdp_queue);
    if (!second_fence.waitTimeout(rsp_timeout_attempts)) return error.RdpFenceTimeout;
    n64.cache.invalidateData(&overlay_rdp_render_target);
    for (overlay_rdp_render_target) |pixel| {
        try testing.expectEqual(n64.graphics.color.Rgba32.blue, pixel);
    }

    rsp.io.status_register_write.* = rsp.io.status_clear_signal1;
    @memset(&overlay_rdp_render_target_16, n64.graphics.color.Rgba16.black);
    n64.cache.writebackData(&overlay_rdp_render_target_16);
    const image_16 = n64.graphics.image.ImgRgba16{
        .width = 4,
        .height = 4,
        .texel_data = overlay_rdp_render_target_16[0..],
    };
    const gray = n64.graphics.color.Rgba16.fromInt(0x404040ff);
    render_queue.clear();
    render_queue.setFrameBuffer(image_16);
    render_queue.clearScreen(gray);
    const third_fence = rdp.syncFull(&render_queue);
    try waitQueueTimeout(&rdp_queue);
    if (!third_fence.waitTimeout(rsp_timeout_attempts)) return error.RdpFenceTimeout;
    n64.cache.invalidateData(&overlay_rdp_render_target_16);
    for (overlay_rdp_render_target_16) |pixel| {
        try testing.expectEqual(gray, pixel);
    }

    rsp.io.status_register_write.* = rsp.io.status_clear_signal1;
    rsp.releaseRdpToDirect();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn nativeOverlayTexturedTriangle() !void {
    const black = n64.graphics.color.Rgba16.black;
    const green = n64.graphics.color.Rgba32.green;
    @memset(&native_triangle_overlay_target, black);
    @memset(&native_triangle_texture, n64.graphics.color.Rgba32.white);
    n64.cache.writebackData(&native_triangle_overlay_target);
    n64.cache.writebackData(&native_triangle_texture);

    const texture_image = n64.graphics.image.ImgRgba32{
        .width = 4,
        .height = 4,
        .texel_data = native_triangle_texture[0..],
    };
    loadCommandDispatcher();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_queue.init(.low);
    const overlay_image = n64.graphics.image.ImgRgba16{
        .width = 16,
        .height = 16,
        .texel_data = native_triangle_overlay_target[0..],
    };
    var overlay_render = rdp.OverlayRenderQueue.init(rdp.OverlayQueue.init(
        &rdp_queue,
        &rdp_overlay,
        .{ rsp_rdp_dynamic_buffers[0][0..], rsp_rdp_dynamic_buffers[1][0..] },
    ));
    renderNativeTriangleScene(&overlay_render, overlay_image, texture_image, green);
    const overlay_fence = rdp.syncFull(&overlay_render);
    try waitQueueTimeout(&rdp_queue);
    if (!overlay_fence.waitTimeout(rsp_timeout_attempts)) return error.RdpFenceTimeout;

    n64.cache.invalidateData(&native_triangle_overlay_target);
    var overlay_changed: usize = 0;
    var overlay_checksum: u32 = 0;
    for (native_triangle_overlay_target) |overlay_pixel| {
        if (!std.meta.eql(overlay_pixel, black)) overlay_changed += 1;
        overlay_checksum = overlay_checksum *% 16777619 ^ @as(u16, @bitCast(overlay_pixel));
    }
    try testing.expectEqual(@as(usize, 63), overlay_changed);
    try testing.expectEqual(@as(u32, 0xee5baec0), overlay_checksum);
    try testing.expectEqual(n64.graphics.color.Rgba16.green, native_triangle_overlay_target[8 * 16 + 8]);

    @memset(&native_triangle_overlay_target, black);
    n64.cache.writebackData(&native_triangle_overlay_target);
    var next_overlay_render = rdp.OverlayRenderQueue.init(rdp.OverlayQueue.init(
        &rdp_queue,
        &rdp_overlay,
        .{ rsp_rdp_dynamic_buffers[0][0..], rsp_rdp_dynamic_buffers[1][0..] },
    ));
    next_overlay_render.clear();
    next_overlay_render.setFrameBuffer(overlay_image);
    next_overlay_render.clearScreen(black);
    next_overlay_render.setCombineMode(.single(.{ .rgb_a = .tex0, .rgb_c = .primitive, .alpha_d = .tex0 }));
    next_overlay_render.setBlendMode(.alpha);
    next_overlay_render.setPrimColor(green);
    for (0..10) |_| {
        next_overlay_render.drawSprite(texture_image, 8, 8, .{
            .rotation = 0.35,
            .pivot = .center,
            .scale_x = 2,
            .scale_y = 2,
        });
    }
    const rollover_fence = rdp.syncFull(&next_overlay_render);
    if (!rsp.waitTimeout(&rdp_queue, 100_000_000)) return error.RspSignalTimeout;
    if (!rollover_fence.waitTimeout(rsp_timeout_attempts)) return error.RdpFenceTimeout;
    n64.cache.invalidateData(&native_triangle_overlay_target);
    overlay_changed = 0;
    overlay_checksum = 0;
    for (native_triangle_overlay_target) |overlay_pixel| {
        if (!std.meta.eql(overlay_pixel, black)) overlay_changed += 1;
        overlay_checksum = overlay_checksum *% 16777619 ^ @as(u16, @bitCast(overlay_pixel));
    }
    try testing.expectEqual(@as(usize, 63), overlay_changed);
    try testing.expectEqual(@as(u32, 0xee5baec0), overlay_checksum);

    rsp.releaseRdpToDirect();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn renderNativeTriangleScene(render_queue: anytype, target: anytype, texture_image: anytype, color: n64.graphics.color.Rgba32) void {
    render_queue.setFrameBuffer(target);
    render_queue.clearScreen(n64.graphics.color.Rgba16.black);
    render_queue.setCombineMode(.single(.{ .rgb_a = .tex0, .rgb_c = .primitive, .alpha_d = .tex0 }));
    render_queue.setBlendMode(.alpha);
    render_queue.setPrimColor(color);
    render_queue.drawSprite(texture_image, 8, 8, .{
        .rotation = 0.35,
        .pivot = .center,
        .scale_x = 2,
        .scale_y = 2,
    });
}

fn queuedDmaCommand() !void {
    loadCommandDispatcher();
    queued_dma_queue.init(.low);
    queued_dma_queue.dmaToDmem(0x600, std.mem.asBytes(&queue_dma_source), false);
    queued_dma_queue.dmaToRdram(std.mem.asBytes(&queue_dma_destination), 0x600, false);
    rsp.flush(&queued_dma_queue);
    try waitQueueTimeout(&queued_dma_queue);
    n64.cache.invalidateData(&queue_dma_destination);

    try expectDmemWords(0x600, &queue_dma_source);
    for (queue_dma_source, queue_dma_destination) |expected, actual| {
        try testing.expectEqual(expected, actual);
    }
}

fn waitQueueTimeout(queue: *const rsp.Queue) !void {
    if (rsp.waitTimeout(queue, rsp_timeout_attempts)) return;
    n64.debug.print(
        "\n      RSP pc={x:0>3} sp={x:0>8} dp={x:0>8} current={x:0>8} sentinel={x:0>8}\n      buffers={x:0>8},{x:0>8} dp_start={x:0>8} dp_end={x:0>8} assertion={x:0>8}\n",
        .{
            rsp.io.program_counter.*,
            @as(u32, @bitCast(rsp.io.status_register_read.*)),
            @as(u32, @bitCast(n64.interfaces.rdp.status.*)),
            readDmemInt(u32, 0x1d0),
            readDmemInt(u32, 0x1d4),
            readDmemInt(u32, 0x1c8),
            readDmemInt(u32, 0x1cc),
            n64.interfaces.rdp.dma_start_addr.*,
            n64.interfaces.rdp.dma_end_addr.*,
            readDmemInt(u32, 0x84),
        },
    );
    rsp.halt();
    rsp.waitHalted();
    return error.RspSignalTimeout;
}

fn waitDmemValueTimeout(offset: u32, expected: u32) !void {
    var remaining = rsp_timeout_attempts;
    while (readDmemInt(u32, offset) != expected) {
        if (remaining == 0) {
            rsp.halt();
            rsp.waitHalted();
            return error.RspSignalTimeout;
        }
        remaining -= 1;
    }
}

fn rspLoadedOverlayDispatch() !void {
    loadCommandDispatcher();
    overlay_1.init(zsp_programs.static_overlay);
    overlay_2.init(zsp_programs.static_overlay_2);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&overlay_1));
    try testing.expectEqual(@as(u8, 2), rsp.registerOverlay(&overlay_2));
    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&overlay_1, 0, 0x504, &.{});
    continuous_queue.writeOverlayCommand(&overlay_1, 1, 0x508, &.{0xdeadbeef});
    continuous_queue.writeOverlayCommand(&overlay_1, 0, 0x50c, &.{});
    continuous_queue.writeOverlayCommand(&overlay_2, 0, 0x510, &.{});
    continuous_queue.writeOverlayCommand(&overlay_2, 0, 0x514, &.{});
    continuous_queue.writeOverlayCommand(&overlay_1, 0, 0x518, &.{});

    try expectDmemWord(u32, 0x48, 0x00040800);
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);

    try expectDmemWord(u32, 0x504, 1);
    try expectDmemWord(u32, 0x508, 0xdeadbeef);
    try expectDmemWord(u32, 0x50c, 2);
    try expectDmemWord(u32, 0x510, 1);
    try expectDmemWord(u32, 0x514, 2);
    try expectDmemWord(u32, 0x518, 3);
    try expectDmemWord(u16, 0x1f8, zsp_programs.static_overlay.state_offset);
    try expectDmemWord(u16, 0x200, 1 << 5);
    try expectDmemWord(u16, 0x202, 1 << 2);
    try expectDmemWord(u16, 0x208, @intCast(zsp_programs.static_overlay.text.len - 1));
    try expectDmemWord(u16, 0x20a, rsp.io.dma_imem_addr + zsp_programs.static_overlay.text_offset);
    const first_command = zsp_programs.static_overlay.commandAt(0);
    const descriptor = @as(u16, first_command.size) << 8 | first_command.handler_offset >> 2;
    try expectDmemWord(u16, 0x214, descriptor);
    const argument_command = zsp_programs.static_overlay.commandAt(1);
    const argument_descriptor = @as(u16, argument_command.size) << 8 |
        argument_command.handler_offset >> 2;
    try expectDmemWord(u16, 0x216, argument_descriptor);

    const overlay_1_state = rsp.overlayState(&overlay_1);
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, overlay_1_state[0..4], .big));
    std.mem.writeInt(u32, overlay_1_state[0..4], 9, .big);
    rsp.writebackOverlayState(&overlay_1);
    try expectDmemWord(u32, zsp_programs.static_overlay.state_offset, 9);
    rsp.unregisterOverlay(&overlay_1);
    rsp.unregisterOverlay(&overlay_2);
    try expectDmemWord(u32, 0x3c, 0);
    try expectDmemWord(u32, 0x40, 0);
    try expectDmemWord(u32, 0x48, 0);

    overlay_2.init(zsp_programs.static_overlay_2);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&overlay_2));
}

fn geometryProjectionDma() !void {
    loadCommandDispatcher();
    geometry_overlay.init(zsp_programs.geometry_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&geometry_overlay));

    const identity = [_]u32{
        0x00010000, 0x00000000, 0, 0,
        0x00000001, 0x00000000, 0, 0,
        0x00000000, 0x00010000, 0, 0,
        0x00000000, 0x00000001, 0, 0,
    };
    geometry_matrix_input = identity;
    n64.cache.writebackData(&geometry_matrix_input);
    const input_address: u32 = @truncate(@intFromPtr(&geometry_matrix_input) & 0x00ffffff);
    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&geometry_overlay, 7, input_address, &.{});
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);
    const state = rsp.overlayState(&geometry_overlay);
    try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(&identity), state[0..0x40]));
    rsp.unregisterOverlay(&geometry_overlay);
}

fn geometryStateCommands() !void {
    loadCommandDispatcher();
    geometry_overlay.init(zsp_programs.geometry_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&geometry_overlay));

    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(
        &geometry_overlay,
        1,
        0x0302,
        &.{ 0x00100020, 0x00300040, 0x12345678 },
    );
    continuous_queue.writeOverlayCommand(&geometry_overlay, 9, 1, &.{});
    continuous_queue.writeOverlayCommand(
        &geometry_overlay,
        5,
        0x378,
        &.{ 0x11223344, 0x55667788, 0x99aabbcc },
    );
    continuous_queue.writeOverlayCommand(&geometry_overlay, 6, 2, &.{0x01000000});
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);

    const state = rsp.overlayState(&geometry_overlay);
    try testing.expectEqual(@as(u32, 0x00300040), std.mem.readInt(u32, state[0xe0..][0..4], .big));
    try testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, state[0xe4..][0..4], .big));
    try testing.expectEqual(@as(u32, 0x00100020), std.mem.readInt(u32, state[0xe8..][0..4], .big));
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, state[0x116..][0..2], .big));
    try testing.expectEqual(@as(u8, 2), state[0x103]);
    try testing.expectEqual(@as(u8, 2), state[0x107]);
    try testing.expectEqual(@as(u8, 0xfe), state[0x10f]);
    try testing.expectEqual(@as(u8, 0xfe), state[0x113]);
    try testing.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, state[0x148..][0..4], .big));
    try testing.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, state[0x14c..][0..4], .big));
    try testing.expectEqual(@as(u32, 0x55667788), std.mem.readInt(u32, state[0x150..][0..4], .big));
    try testing.expectEqual(@as(u32, 0x99aabbcc), std.mem.readInt(u32, state[0x154..][0..4], .big));
    try testing.expectEqual(@as(u32, 0x01000000), std.mem.readInt(u32, state[0x1c0..][0..4], .big));
    try testing.expectEqual(@as(u8, 2), state[0x1c8]);
    try testing.expectEqual(@as(u8, 1), state[0x1c9]);
    rsp.unregisterOverlay(&geometry_overlay);
}

fn geometryMatrixOverlay() !void {
    loadCommandDispatcher();
    geometry_overlay.init(zsp_programs.geometry_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&geometry_overlay));

    const identity = [_]u32{
        0x00010000, 0x00000000, 0, 0,
        0x00000001, 0x00000000, 0, 0,
        0x00000000, 0x00010000, 0, 0,
        0x00000000, 0x00000001, 0, 0,
    };
    geometry_matrix_input = identity;
    @memset(&geometry_matrix_stack, 0xcccccccc);
    n64.cache.writebackData(&geometry_matrix_input);
    n64.cache.writebackData(&geometry_matrix_stack);

    const input_address: u32 = @truncate(@intFromPtr(&geometry_matrix_input) & 0x00ffffff);
    const stack_address: u32 = @truncate(@intFromPtr(&geometry_matrix_stack) & 0x00ffffff);
    var state = rsp.overlayState(&geometry_overlay);
    @memcpy(state[0..0x40], std.mem.sliceAsBytes(&identity));
    std.mem.writeInt(u32, state[0x1c4..0x1c8], stack_address, .big);
    rsp.writebackOverlayState(&geometry_overlay);

    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&geometry_overlay, 2, 0, &.{input_address});
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);

    n64.cache.invalidateData(&geometry_matrix_stack);
    try testing.expect(std.mem.eql(u32, &identity, geometry_matrix_stack[0..16]));
    state = rsp.overlayState(&geometry_overlay);
    try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(&identity), state[0x40..0x80]));
    try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(&identity), state[0x80..0xc0]));
    rsp.unregisterOverlay(&geometry_overlay);
}

fn geometryVertexTransform() !void {
    loadCommandDispatcher();
    geometry_overlay.init(zsp_programs.geometry_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&geometry_overlay));

    const identity = [_]u32{
        0x00010000, 0x00000000, 0, 0,
        0x00000001, 0x00000000, 0, 0,
        0x00000000, 0x00010000, 0, 0,
        0x00000000, 0x00000001, 0, 0,
    };
    @memset(&geometry_vertex_input, 0);
    @memset(geometry_vertex_input[16..24], 0xff);
    geometry_vertex_input[33] = 7;
    geometry_vertex_input[41] = 13;
    @memset(geometry_vertex_input[48..56], 0xff);
    n64.cache.writebackData(&geometry_vertex_input);

    const vertex_address: u32 = @truncate(@intFromPtr(&geometry_vertex_input) & 0x00ffffff);
    var state = rsp.overlayState(&geometry_overlay);
    @memcpy(state[0x40..0x80], std.mem.sliceAsBytes(&identity));
    const vertex_handler = blk: {
        for (0..zsp_programs.geometry_overlay.commandCount()) |index| {
            const command = zsp_programs.geometry_overlay.commandAt(index);
            if (command.index == 4) break :blk command.handler_offset;
        }
        return error.MissingGeometryVertexCommand;
    };
    std.mem.writeInt(u32, state[0x1c0..0x1c4], 0x01000000, .big);
    std.mem.writeInt(u16, state[0x1cc..0x1ce], vertex_handler + 0x2bc, .big);
    rsp.writebackOverlayState(&geometry_overlay);
    for (0..4 * 36 / 4) |index| {
        rsp.io.readDmem(u32, 0x408 + @as(u32, @intCast(index * 4))).* = 0xdeadbeef;
    }

    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&geometry_overlay, 4, 64, &.{ vertex_address, 0x0f000408 });
    rsp.flush(&continuous_queue);
    if (!rsp.waitTimeout(&continuous_queue, 100)) {
        n64.debug.print("\n      Geometry vertex timeout: pc={x:0>3} status={x:0>8}\n", .{
            rsp.io.program_counter.*,
            @as(u32, @bitCast(rsp.io.status_register_read.*)),
        });
        return error.RspSignalTimeout;
    }

    try testing.expectEqual(@as(u8, 0), rsp.io.readDmem(u8, 0x40e).*);
    try testing.expectEqual(@as(u8, 0xff), rsp.io.readDmem(u8, 0x40f).*);
    try testing.expectEqual(@as(u8, 0), rsp.io.readDmem(u8, 0x432).*);
    try testing.expectEqual(@as(u8, 0xff), rsp.io.readDmem(u8, 0x433).*);
    try testing.expect(rsp.io.readDmem(u32, 0x410).* != 0);
    try testing.expect(rsp.io.readDmem(u32, 0x434).* != 0);

    var batch_output: [4 * 36 / 4]u32 = undefined;
    for (&batch_output, 0..) |*word, index| {
        word.* = rsp.io.readDmem(u32, 0x408 + @as(u32, @intCast(index * 4))).*;
    }

    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&geometry_overlay, 4, 32, &.{ vertex_address, 0x0f200408 });
    continuous_queue.writeOverlayCommand(&geometry_overlay, 4, 32, &.{ vertex_address + 32, 0x0f200450 });
    rsp.flush(&continuous_queue);
    if (!rsp.waitTimeout(&continuous_queue, 200)) return error.RspSignalTimeout;

    for (batch_output, 0..) |expected, index| {
        try testing.expectEqual(
            expected,
            rsp.io.readDmem(u32, 0x408 + @as(u32, @intCast(index * 4))).*,
        );
    }
    rsp.unregisterOverlay(&geometry_overlay);
}

fn geometryClippingSwap() !void {
    loadCommandDispatcher();
    geometry_overlay.init(zsp_programs.geometry_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&geometry_overlay));

    const clipping = zsp_programs.geometry_clipping;
    const payload_offset = 0x08b0 - clipping.text_offset;
    const payload_len = 0x3a0;
    const original_offset = 0x08b0 - zsp_programs.geometry_overlay.text_offset;
    const clipping_address: u32 = @truncate(
        @intFromPtr(clipping.text.ptr + payload_offset) & 0x00ffffff,
    );
    const original_address: u32 = @truncate(
        @intFromPtr(zsp_programs.geometry_overlay.text.ptr + original_offset) & 0x00ffffff,
    );
    var state = rsp.overlayState(&geometry_overlay);
    std.mem.writeInt(u16, state[0x1ce..][0..2], payload_len, .big);
    std.mem.writeInt(u32, state[0x1d0..][0..4], clipping_address, .big);
    std.mem.writeInt(u32, state[0x1d4..][0..4], original_address, .big);
    rsp.writebackOverlayState(&geometry_overlay);

    rsp.halt();
    rsp.waitHalted();
    rsp.io.waitDmaReady();
    rsp.io.dmaFromDram(0x18b0, clipping_address, payload_len - 1);
    rsp.io.waitDma();
    rsp.writeDmemByte(0x400, 1);
    try testing.expectEqual(
        std.mem.readInt(u32, clipping.text[payload_offset..][0..4], .big),
        @as(*volatile u32, @ptrFromInt(0xa40018b0)).*,
    );

    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&geometry_overlay, 10, 0, &.{});
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);
    try expectDmemWord(u8, 0x400, 0);
    try testing.expectEqual(
        std.mem.readInt(u32, zsp_programs.geometry_overlay.text[original_offset..][0..4], .big),
        @as(*volatile u32, @ptrFromInt(0xa40018b0)).*,
    );
    rsp.unregisterOverlay(&geometry_overlay);
}

fn geometryTriangleSubmission() !void {
    loadCommandDispatcher();
    geometry_overlay.init(zsp_programs.geometry_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&geometry_overlay));

    var state = rsp.overlayState(&geometry_overlay);
    std.mem.writeInt(u32, state[0x1c0..][0..4], 0x01000000, .big);
    state[0x1c8] = 2;
    const vertex_offsets = [_]usize{ 0x1d8, 0x1fc, 0x220 };
    const screen_xy = [_]u32{ 0x000a001e, 0x0014000a, 0x001e0014 };
    for (vertex_offsets, screen_xy) |offset, xy| {
        @memset(state[offset..][0..36], 0);
        std.mem.writeInt(u32, state[offset..][0..4], xy, .big);
        std.mem.writeInt(u16, state[offset + 4 ..][0..2], 0x1234, .big);
        std.mem.writeInt(u32, state[offset + 8 ..][0..4], 0x11223344, .big);
        std.mem.writeInt(u32, state[offset + 16 ..][0..4], 0x00010000, .big);
        std.mem.writeInt(u32, state[offset + 20 ..][0..4], 0x00010000, .big);
    }
    rsp.writebackOverlayState(&geometry_overlay);

    @memset(&geometry_triangle_output, 0xff);
    n64.cache.writebackData(&geometry_triangle_output);
    const output_address: u32 = @truncate(@intFromPtr(&geometry_triangle_output) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(geometry_triangle_output));
    rsp.writeDmemByte(rsp.rdp_publication_held_dmem, 1);
    rsp.writeDmemByte(rsp.rdp_syncfull_ongoing_dmem, 1);

    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&geometry_overlay, 0, 0x408, &.{0x042c0450});
    continuous_queue.writeOverlayCommand(&geometry_overlay, 10, 0, &.{});
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);

    n64.cache.invalidateData(&geometry_triangle_output);
    try testing.expect(geometry_triangle_output[0] != std.math.maxInt(u64));
    rsp.unregisterOverlay(&geometry_overlay);
}

fn geometryTriangleStrip() !void {
    loadCommandDispatcher();
    geometry_overlay.init(zsp_programs.geometry_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&geometry_overlay));

    var state = rsp.overlayState(&geometry_overlay);
    std.mem.writeInt(u32, state[0x1c0..][0..4], 0x01000000, .big);
    state[0x1c8] = 2;
    const vertex_offsets = [_]usize{ 0x1d8, 0x1fc, 0x220 };
    const screen_xy = [_]u32{ 0x000a001e, 0x0014000a, 0x001e0014 };
    for (vertex_offsets, screen_xy) |offset, xy| {
        @memset(state[offset..][0..36], 0);
        std.mem.writeInt(u32, state[offset..][0..4], xy, .big);
        std.mem.writeInt(u32, state[offset + 8 ..][0..4], 0x11223344, .big);
        std.mem.writeInt(u32, state[offset + 16 ..][0..4], 0x00010000, .big);
        std.mem.writeInt(u32, state[offset + 20 ..][0..4], 0x00010000, .big);
    }
    rsp.writebackOverlayState(&geometry_overlay);

    @memset(&geometry_triangle_output, 0xff);
    n64.cache.writebackData(&geometry_triangle_output);
    n64.cache.writebackData(&geometry_strip_indices);
    const output_address: u32 = @truncate(@intFromPtr(&geometry_triangle_output) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(geometry_triangle_output));
    rsp.writeDmemByte(rsp.rdp_publication_held_dmem, 1);
    rsp.writeDmemByte(rsp.rdp_syncfull_ongoing_dmem, 1);

    const index_address: u32 = @truncate(@intFromPtr(&geometry_strip_indices) & 0x00ffffff);
    const dmem_address: u32 = (0x8000 | ((0x0dd0 - 6) & ~@as(u32, 7))) << 16;
    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&geometry_overlay, 11, index_address, &.{dmem_address | 5});
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);

    n64.cache.invalidateData(&geometry_triangle_output);
    try testing.expect(geometry_triangle_output[0] != std.math.maxInt(u64));
    rsp.unregisterOverlay(&geometry_overlay);
}

fn geometryClippedTriangle() !void {
    loadCommandDispatcher();
    geometry_overlay.init(zsp_programs.geometry_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&geometry_overlay));

    const clipping = zsp_programs.geometry_clipping;
    const payload_offset = 0x08b0 - clipping.text_offset;
    const original_offset = 0x08b0 - zsp_programs.geometry_overlay.text_offset;
    const clipping_address: u32 = @truncate(
        @intFromPtr(clipping.text.ptr + payload_offset) & 0x00ffffff,
    );
    const original_address: u32 = @truncate(
        @intFromPtr(zsp_programs.geometry_overlay.text.ptr + original_offset) & 0x00ffffff,
    );

    var state = rsp.overlayState(&geometry_overlay);
    std.mem.writeInt(u32, state[0x1c0..][0..4], 0x01000000, .big);
    state[0x1c8] = 2;
    std.mem.writeInt(u16, state[0x1ce..][0..2], 0x3a0, .big);
    std.mem.writeInt(u32, state[0x1d0..][0..4], clipping_address, .big);
    std.mem.writeInt(u32, state[0x1d4..][0..4], original_address, .big);
    const vertex_offsets = [_]usize{ 0x1d8, 0x1fc, 0x220 };
    const screen_xy = [_]u32{ 0x000a001e, 0x0014000a, 0x001e0014 };
    for (vertex_offsets, screen_xy, 0..) |offset, xy, index| {
        @memset(state[offset..][0..36], 0);
        std.mem.writeInt(u32, state[offset..][0..4], xy, .big);
        state[offset + 6] = if (index == 0) 1 else 0;
        std.mem.writeInt(u32, state[offset + 8 ..][0..4], 0x11223344, .big);
        std.mem.writeInt(i16, state[offset + 16 ..][0..2], if (index == 0) 2 else 0, .big);
        std.mem.writeInt(i16, state[offset + 18 ..][0..2], 0, .big);
        std.mem.writeInt(i16, state[offset + 20 ..][0..2], 0, .big);
        std.mem.writeInt(i16, state[offset + 22 ..][0..2], 1, .big);
    }
    rsp.writebackOverlayState(&geometry_overlay);

    @memset(&geometry_triangle_output, 0xff);
    n64.cache.writebackData(&geometry_triangle_output);
    const output_address: u32 = @truncate(@intFromPtr(&geometry_triangle_output) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + @sizeOf(@TypeOf(geometry_triangle_output));
    rsp.writeDmemByte(rsp.rdp_publication_held_dmem, 1);
    rsp.writeDmemByte(rsp.rdp_syncfull_ongoing_dmem, 1);

    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&geometry_overlay, 0, 0x408, &.{0x042c0450});
    continuous_queue.writeOverlayCommand(&geometry_overlay, 10, 0, &.{});
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);

    try expectDmemWord(u8, 0x400, 0);
    n64.cache.invalidateData(&geometry_triangle_output);
    try testing.expect(geometry_triangle_output[0] != std.math.maxInt(u64));
    rsp.unregisterOverlay(&geometry_overlay);
}

fn geometryPatchDma() !void {
    loadCommandDispatcher();
    geometry_overlay.init(zsp_programs.geometry_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&geometry_overlay));

    geometry_patch_target = .{ 0, 0 };
    n64.cache.writebackData(&geometry_patch_target);
    const target: u32 = @truncate(@intFromPtr(&geometry_patch_target) & 0x00ffffff);
    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&geometry_overlay, 3, 0x3f0, &.{0x12345678});
    continuous_queue.writeOverlayCommand(&geometry_overlay, 3, 0x8000 | 0x3f8, &.{0x0000abcd});
    continuous_queue.writeOverlayCommand(&geometry_overlay, 13, target, &.{ 0x12345678, 0x89abcdef });
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);
    n64.cache.invalidateData(&geometry_patch_target);
    try testing.expectEqual(@as(u32, 0x12345678), geometry_patch_target[0]);
    try testing.expectEqual(@as(u32, 0x89abcdef), geometry_patch_target[1]);
    const state = rsp.overlayState(&geometry_overlay);
    try testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, state[0x1c0..0x1c4], .big));
    try testing.expectEqual(@as(u16, 0xabcd), std.mem.readInt(u16, state[0x1c8..0x1ca], .big));
    rsp.unregisterOverlay(&geometry_overlay);
}

fn multiSlotOverlayDispatch() !void {
    loadCommandDispatcher();
    multi_slot_overlay.init(zsp_programs.multi_slot_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&multi_slot_overlay));
    try testing.expectEqual(@as(u8, 4), multi_slot_overlay.slot_count);

    continuous_queue.init(.low);
    const indices = [_]u8{ 0, 15, 16, 31, 32, 47, 48, 63 };
    for (indices, 0..) |index, result_index| {
        continuous_queue.writeOverlayCommand(
            &multi_slot_overlay,
            index,
            0x520 + @as(u32, @intCast(result_index * 4)),
            &.{},
        );
    }
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);

    for (indices, 0..) |index, result_index| {
        try expectDmemWord(u32, 0x520 + @as(u32, @intCast(result_index * 4)), index);
    }
    rsp.unregisterOverlay(&multi_slot_overlay);
}

fn rdpReservedLoopSlots() !void {
    loadCommandDispatcher();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    continuous_queue.init(.low);
    inline for (.{ 21, 23, 32, 33, 34, 35 }) |index| {
        continuous_queue.writeOverlayCommand(&rdp_overlay, index, 0, &.{0});
    }
    // A command after every reserved slot proves each alias returned to the
    // resident loop instead of breaking, hanging, or consuming the wrong size.
    continuous_queue.writeOverlayCommand(&rdp_overlay, 17, 1, &.{});
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);
    try testing.expectEqual(@as(i8, -128), rsp.io.readDmem(i8, rsp.rdp_target_bitdepth_dmem).*);
    rsp.writeDmemByte(rsp.rdp_target_bitdepth_dmem, 0);
    rsp.unregisterOverlay(&rdp_overlay);
}

fn commandDispatcherInvalid() !void {
    loadCommandDispatcher();
    submitDispatcherBatch(&invalid_command_batch);
    try runLoadedCommandDispatcher();
}

fn rdpPersistentScalarState() !void {
    loadCommandDispatcher();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    overlay_1.init(zsp_programs.static_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&overlay_1));
    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&rdp_overlay, 17, 1, &.{});
    continuous_queue.writeOverlayCommand(&rdp_overlay, 28, 0, &.{});
    continuous_queue.writeOverlayCommand(&rdp_overlay, 28, 24, &.{});
    continuous_queue.writeOverlayCommand(&overlay_1, 0, 0x530, &.{});
    continuous_queue.writeOverlayCommand(&rdp_overlay, 28, 0x00ffffff, &.{});
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);

    try testing.expectEqual(@as(i8, -128), rsp.io.readDmem(i8, rsp.rdp_target_bitdepth_dmem).*);
    const state = rsp.programs.rdp_overlay.state_offset;
    try expectDmemWord(u16, state + 88, 24);
    try expectDmemWord(u16, state + 90, 0);
    try expectDmemWord(u16, state + 92, 512);
    try expectDmemWord(u8, state + 94, 0);
    try expectDmemWord(u32, 0x530, 1);
    rsp.writeDmemByte(rsp.rdp_target_bitdepth_dmem, 0);
    rsp.unregisterOverlay(&overlay_1);
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpAutoTmemTileEmission() !void {
    loadCommandDispatcher();
    const dp_status_write: *volatile u32 = @ptrFromInt(0xa410000c);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&rdp_overlay, 12);
    rdp_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_buffer);
    const output_address: u32 = @truncate(@intFromPtr(&rdp_buffer) & 0x00ffffff);
    rsp.io.readDmem(u32, 0x1d0).* = output_address;
    rsp.io.readDmem(u32, 0x1d4).* = output_address + 2 * @sizeOf(u64);
    const dp_start_write: *volatile u32 = @ptrFromInt(0xa4100000);
    const dp_end_write: *volatile u32 = @ptrFromInt(0xa4100004);
    dp_start_write.* = output_address;
    dp_end_write.* = output_address;

    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&rdp_overlay, 28, 0, &.{});
    continuous_queue.writeOverlayCommand(&rdp_overlay, 28, 24, &.{});
    continuous_queue.writeOverlayCommand(&rdp_overlay, 29, 3 << 19, &.{0x76543210});
    continuous_queue.writeOverlayCommand(&rdp_overlay, 39, 0, &.{0});
    continuous_queue.writeOverlayCommand(&rdp_overlay, 28, 0x00ffffff, &.{});
    rsp.flush(&continuous_queue);
    if (!rsp.waitTimeout(&continuous_queue, rsp_timeout_attempts)) {
        n64.cache.invalidateData(&rdp_buffer);
        const status: u32 = @bitCast(rsp.io.status_register_read.*);
        n64.debug.print("\n      RSP PC=0x{x:0>4} status=0x{x:0>8} output=0x{x:0>8} current=0x{x:0>8}\n", .{
            rsp.io.program_counter.*,
            status,
            output_address,
            rsp.io.readDmem(u32, 0x1d0).*,
        });
        n64.debug.print("      words=0x{x:0>16} 0x{x:0>16}\n", .{ rdp_buffer[0], rdp_buffer[1] });
        n64.debug.print("      queues=0x{x:0>8} 0x{x:0>8} queue_dmem=0x{x:0>8}\n", .{
            @as(u32, @truncate(@intFromPtr(&continuous_queue.storage.queues[0].buffer) & 0x00ffffff)),
            @as(u32, @truncate(@intFromPtr(&continuous_queue.storage.queues[1].buffer) & 0x00ffffff)),
            rsp.io.readDmem(u32, 0x80).*,
        });
        rsp.halt();
        rsp.waitHalted();
        return error.RspSignalTimeout;
    }

    n64.cache.invalidateData(&rdp_buffer);
    try testing.expectEqual(@as(u64, 0xf518001876543210), rdp_buffer[0]);
    try testing.expectEqual(@as(u64, 0xe700000000000000), rdp_buffer[1]);
    const state = rsp.programs.rdp_overlay.state_offset;
    try expectDmemWord(u16, state + 88, 24);
    try expectDmemWord(u16, state + 90, 0);
    try expectDmemWord(u16, state + 92, 256);
    try expectDmemWord(u8, state + 94, 0);
    dp_status_write.* = 1 << 5;
    dp_status_write.* = (1 << 4) | (1 << 2);
    n64.interfaces.mips.clearRdpInterrupt();
    rsp.unregisterOverlay(&rdp_overlay);
}

fn loadCommandDispatcher() void {
    rsp.halt();
    rsp.waitHalted();
    rsp.loadResident(rsp.programs.command_dispatcher);
}

fn runLoadedCommandDispatcher() !void {
    rsp.runAsync(rsp.programs.command_dispatcher.pc_start);
    try waitBrokeTimeout();
}

fn submitDispatcherBatch(batch: *[rsp.command_queue.batch_word_count]u32) void {
    n64.cache.writebackData(batch);

    rsp.halt();
    rsp.waitHalted();
    const physical_address: u32 = @truncate(@intFromPtr(batch) & 0x1fffffff);
    rsp.io.readDmem(u32, 0x80).* = physical_address;
}

fn submitCommandBatch(batch: *[4]u32) void {
    n64.cache.writebackData(batch);

    rsp.halt();
    rsp.waitHalted();
    const physical_address: u32 = @truncate(@intFromPtr(batch) & 0x1fffffff);
    rsp.io.readDmem(u32, 0).* = physical_address;
}

fn run(program: rsp.UCode) !void {
    rsp.runUCode(program);
    try waitBrokeTimeout();
}

fn seedLoadSource(value: u32) void {
    rsp.halt();
    rsp.waitHalted();
    rsp.io.readDmem(u32, 0).* = value;
}

fn waitBrokeTimeout() !void {
    var remaining = rsp_timeout_attempts;
    while (!rsp.is_broke()) : (remaining -= 1) {
        if (remaining != 0) continue;
        rsp.halt();
        rsp.waitHalted();
        return error.RspTimeout;
    }
}

fn expectDmemWord(comptime T: type, offset: u32, expected: T) !void {
    try testing.expectEqual(expected, readDmemInt(T, offset));
}

fn expectBufferWord(comptime T: type, bytes: []const u8, offset: usize, expected: T) !void {
    try testing.expectEqual(expected, std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big));
}

fn expectDmemWords(offset: u32, expected: []const u32) !void {
    for (expected, 0..) |word, index| {
        try expectDmemWord(u32, offset + @as(u32, @intCast(index * 4)), word);
    }
}

fn readDmemInt(comptime T: type, offset: u32) T {
    const info = @typeInfo(T).int;
    if (info.bits == 0 or info.bits > 32 or info.bits % 8 != 0) {
        @compileError("DMEM test reads support 8, 16, and 32-bit integer types");
    }

    const word = rsp.io.readDmem(u32, offset & ~@as(u32, 3)).*;
    if (info.bits == 32) {
        return switch (info.signedness) {
            .signed => @bitCast(word),
            .unsigned => word,
        };
    }

    const byte_len = info.bits / 8;
    const byte_offset = offset & 3;
    if (byte_offset + byte_len > 4) {
        @panic("DMEM test read crosses a word boundary");
    }

    const shift: u5 = @intCast((4 - byte_offset - byte_len) * 8);
    const Unsigned = std.meta.Int(.unsigned, info.bits);
    const raw: Unsigned = @truncate(word >> shift);
    return switch (info.signedness) {
        .signed => @bitCast(raw),
        .unsigned => raw,
    };
}
