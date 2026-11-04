//! An immutable, reusable RSP command block containing a model draw.
const std = @import("std");
const rsp = @import("../rsp.zig");
const rdp = @import("../rdp.zig");
const GeometryEncoder = @import("GeometryEncoder.zig");
const DrawFlags = @import("geometry.zig").DrawFlags;
const VertexEffect = @import("geometry.zig").VertexEffect;
const RecordedModel = @This();

buffer: [rsp.CommandBuffer.rdram_buffer_word_count]u32 align(rsp.CommandBuffer.fetch_window_byte_len) = undefined,
commands: rsp.CommandBuffer = undefined,
final_state: MaterialState = undefined,
/// One more than the highest bone the recorded parts use; replay requires a
/// pose at least this long.
pose_len: usize = 0,

/// Encode a model and its material setup once for later draws.
pub fn record(self: *RecordedModel, context: *GeometryEncoder, asset: @import("ModelAsset.zig")) void {
    const model = asset.model;
    self.commands = rsp.CommandBuffer.init(self.buffer[0..]);
    self.pose_len = 0;
    for (model.parts) |part| if (part.bone) |bone| {
        self.pose_len = @max(self.pose_len, @as(usize, bone) + 1);
    };
    context.settleTriangles();
    context.render.prepare();
    context.render.invalidateState();
    const previous = MaterialState.read(context);
    context.last_draw_flags = null;
    context.queue.beginBlock(&self.commands);
    @import("model/draw.zig").draw(context, model, asset.materials);
    context.queue.endBlock(&self.commands);
    self.final_state = MaterialState.read(context);
    previous.restore(context);
    context.render.invalidateState();
}

/// Append a call to this recorded model to the active render queue.
pub fn draw(self: *const RecordedModel, context: *GeometryEncoder) void {
    if (self.pose_len > context.pose_len) @panic(GeometryEncoder.pose_panic);
    context.settleTriangles();
    context.queue.runBlock(&self.commands);
    self.final_state.restore(context);
    context.render.invalidateState();
}

// Keep CPU state tracking aligned with recorded and replayed material commands.
const MaterialState = struct {
    flags: DrawFlags,
    fog: bool,
    effect: VertexEffect,
    tile: u3,
    mode: rdp.OtherModes,
    combine: rdp.CombineMode,
    fn read(context: *const GeometryEncoder) MaterialState {
        return .{ .flags = context.draw_flags, .fog = context.fog_enabled, .effect = context.vertex_effect, .tile = context.render.material_tile, .mode = context.render.getModes(), .combine = context.render.getState().combine };
    }
    fn restore(self: MaterialState, context: *GeometryEncoder) void {
        context.draw_flags = self.flags;
        context.fog_enabled = self.fog;
        context.vertex_effect = self.effect;
        context.render.material_tile = self.tile;
        context.render.setState(.{ .modes = self.mode, .combine = self.combine });
        context.last_draw_flags = null;
    }
};
test "recorded material snapshots restore CPU trackers without claiming TMEM residency" {
    var render: rdp.RenderEncoder(rdp.backend.Overlay) = undefined;
    var context: GeometryEncoder = undefined;
    context.render = &render;
    context.draw_flags = .{ .textured = true, .no_light = true };
    context.fog_enabled = true;
    context.render.material_tile = 6;
    context.render.mode = .{ .cycle_type = .two_cycle, .z_update_en = false };
    context.render.combine_mode = .decal_rgba;
    const state = MaterialState.read(&context);
    context.draw_flags = .{};
    context.fog_enabled = false;
    context.render.material_tile = 0;
    context.last_draw_flags = .{};
    state.restore(&context);
    try std.testing.expect(context.draw_flags.textured and context.draw_flags.no_light);
    try std.testing.expect(context.fog_enabled);
    try std.testing.expectEqual(@as(u3, 6), context.render.material_tile);
    try std.testing.expectEqual(rdp.CycleType.two_cycle, context.render.mode.cycle_type);
    try std.testing.expect(std.meta.eql(rdp.CombineMode.decal_rgba, context.render.combine_mode));
    try std.testing.expect(context.last_draw_flags == null);
}
