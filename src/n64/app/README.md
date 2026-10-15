# Game loops and render passes

`n64.App(.{})` owns an RGBA16 display and renderer. Add
`.geometry = true` for geometry and a depth buffer. Audio can share its public
`runtime`. Initialize the context **in place**, in persistent storage: the runtime
and queues contain internal pointers.

```zig
var memory: [1024 * 1024]u8 = undefined;
var arena = std.heap.FixedBufferAllocator.init(&memory);
var context: n64.App(.{ .geometry = true }) = undefined;

pub fn main() !void {
    n64.debug.init();
    try context.init(arena.allocator(), .{});
    var model_matrix: n64.math.FixedMat4 align(16) = .identity;
    var camera = n64.graphics.Viewport.init(320, 240);
    camera.setPerspective(n64.math.degreesToRadians(65), 1, 200);
    camera.lookAt(.init(0, 30, 80), .zero, .init(0, 1, 0));
    while (true) {
        const frame = try context.beginFrame(.{ .clear_color = .black });
        const world = try frame.beginGeometry(.{
            .camera = &camera,
            .lighting = .{
                .ambient = .fromBytes(100, 100, 100, 255),
                .lights = &.{.{ .directional = .{ .direction = .init(-1, 1, 1) } }},
            },
        });
        try world.drawModel(assets.model, &model_matrix);
        const hud = try frame.beginOverlay(.{});
        try hud.drawText(assets.font, 16, 20, "Hello!", .{});
        try frame.present();
    }
}
```

The examples repository's `collect` game demonstrates movement, pause/restart,
audio, and formatted HUD text. `model`, `texture-pipeline`, and `font-rendering`
are smaller introductions.

## Pass lifetime and state

A pass is a small borrowed handle. Starting another pass invalidates every copy
of the previous handle (`InvalidPass`). Passes may alternate geometry/overlay;
return to geometry by starting a new pass with a camera. A geometry-pass begin rejected for too many lights preserves the existing pass.
Submission rejects further drawing (`FrameSubmitted`); completing or discarding
the frame invalidates its frame and pass handles (`InvalidFrame`).

Pass boundaries synchronize pending triangles. They do not submit, wait for
completion, allocate, reset command storage, or invalidate texture residency.

Geometry state follows this precedence:

1. `GeometryOptions.pipeline` supplies the baseline for **each model draw**.
   Its default is `rdp.State.opaque_geometry`, white primitive/environment
   colors, and disabled fog. Edit the state value to choose antialiasing, dithering,
   or other defaults. Fog includes its color and near/far distances.
2. The model's material provider applies its own fields, including depth,
   blending, filtering, combiner, and any explicit colors or fog enable.
   `asset.withOverrides(...)` remains the way to change imported materials.
3. The next model draw reapplies the pass baseline. Optional material fields
   therefore inherit pass defaults rather than a preceding model's values.
   Material order *within* a model retains the native material-provider contract.

The borrowed camera is attached before lights are transformed. `Lighting.lights`
accepts directional and point lights in world space, up to
`graphics.max_lights`. That slice is consumed during pass creation and
can immediately be reused. Each new geometry pass establishes its own ambient
color and light count; default lighting is white ambient with no lights.

Overlay passes default to one-cycle alpha blending with depth and perspective
disabled. `OverlayOptions.pipeline` supplies a full `rdp.State` and environment
color, restored before each sprite or text draw. Edit `pipeline.state.modes` to
select filtering, antialiasing, blending, or cycle type, and `pipeline.state.combine`
for a custom combiner. The default combiner multiplies sprite RGB **and alpha**
by `SpriteOptions.tint` (white by default). Tint supplies the primitive color
register; a custom combiner determines how it is used. Font-specific combiner,
color, and coverage changes apply to that text draw and do not leak into the next
sprite. The pass synchronizes color register changes automatically.

```zig
const hud = try frame.beginOverlay(.{});
try hud.drawSprite(assets.icons, .{
    .position = .{ 16, 16 },
    .source = .{ .x = 8, .y = 0, .width = 8, .height = 8 },
    .scale = .{ 2, 2 },
    .tint = .fromInt(0xff808080),
});
var scratch: [64]u8 = undefined;
try hud.drawTextPrint(assets.font, 16, 48, &scratch, .{}, "SCORE {d}", .{score});
```

Custom sprite effects use the same draw API. For example, tint and fade in the
first cycle, then mix toward an environment color in the second:

```zig
var flash_state = n64.rdp.State.textured_sprite;
flash_state.modes.cycle_type = .two_cycle;
flash_state.combine = .{
    .cycle0 = .{
        .rgb_a = .tex0, .rgb_c = .primitive,
        .alpha_a = .tex0, .alpha_c = .primitive,
    },
    .cycle1 = .{
        .rgb_a = .environment, .rgb_b = .combined,
        .rgb_c = .environment_alpha, .rgb_d = .combined,
        .alpha_d = .combined,
    },
};
const sprites = try frame.beginOverlay(.{ .pipeline = .{
    .state = flash_state,
    .environment = .fromInt(0xffffff60), // White flash, strength in alpha.
} });
try sprites.drawSprite(assets.ptero, .{
    .position = .{ 160, 120 },
    .pivot = .center,
    .scale = .{ 4, 4 },
    .tint = .fromInt(0xffc080c0), // Warm tint, opacity in alpha.
});
```

Starting `frame.beginOverlay(.{})` again restores the default pipeline and
invalidates the previous pass handle. Pass settings are copied by value.

The pass pipeline is emitted once per pass and again only after text, and the
renderer skips repeated primitive and environment colors. For many sprites from
one image, `hud.sprites(image)` returns a batch handle that binds the texture
once; each `draw(SpriteOptions)` then emits only a changed tint and the
rectangle. A batch is borrowed like its pass and rebinds itself after text or
texture eviction in between:

```zig
var sparks = try hud.sprites(assets.spark);
for (particles) |p| try sparks.draw(.{
    .position = .{ p.x, p.y },
    .pivot = .center,
    .tint = p.color,
});
```

Sprite regions use texel coordinates and must fit the image. Omit `source` for
the entire image. Negative scales flip, zero scale draws nothing, and nonzero
scale must fit the RDP's signed texture step. A nonzero `rotation` (radians,
around the pivot) draws two textured triangles instead of a rectangle. Text Y
is the first baseline. Formatting scratch is consumed
while recording and may be immediately reused; `NoSpaceLeft` emits no commands.

## Borrowed geometry and recorded models

The context allocates color buffers and, for 3D, one depth buffer at initialization.
Command storage is embedded, including two 64 KiB RDP buffers. Frame/pass methods
allocate no heap memory. The context has no camera, transform, pose, or vertex upload
pool and no capacity settings for those resources.

`beginGeometry` borrows a `*const Viewport`. `drawModel` and `drawRecorded` borrow
`*const FixedMat4` transforms. `setPose` borrows the caller's fixed global bone
matrices for subsequent first-joint model draws. Vertices are borrowed from model
parts, just as in the native geometry API. Bind a pose explicitly before drawing
a skinned model; pass creation does not supply one.

Generate data directly into its final storage. Convert a floating-point transform
with `Mat4.writeFixed(&destination)` and a skeleton with
`Skeleton.writeMatrices(destination)`. Neither needs an intermediate fixed-point
snapshot or a second upload copy.

```zig
var matrices: [actor_count]n64.math.FixedMat4 align(16) = undefined;
// Inside a frame, each actor uses its own stable slot:
for (actors, 0..) |actor, index| {
    actor.transform.writeFixed(&matrices[index]);
    try world.drawModel(actor.asset, &matrices[index]);
}
```

Keep camera matrices, transforms, pose arrays, vertices, indices, textures, and
recorded commands alive and unchanged while any queued work may read them.
Recording can start RSP execution before `submit`. Starting another pass does
not release earlier passes' source data. Reuse buffers only after successful
render completion, usually `frame.present()` or `context.finish()`. A timeout keeps
the submission alive and **does not end the borrow**. Frame tokens validate
command recording; they cannot detect mutation or destruction of caller buffers.

A synchronous loop can reuse one buffer per actor after each presentation.
CPU/GPU overlap that updates the next frame's data needs separate source buffers
or an explicit completion wait before reuse. Using a loop-local matrix shared by
every actor is unsafe: all queued draws can reference the same overwritten value.

For deformation, initialize `graphics.MutableModel` once, edit its `vertices(...)`
in place after the previous render completes, and draw
`asset.withModel(instance.model())`. Its dynamic parts write back their vertex
buffers before RSP reads. Handwritten models can likewise borrow caller-owned
`[]VertexPair` buffers with `.data_usage = .dynamic`. No frame vertex-copy helper
is needed. Static asset vertices are borrowed directly and remain immutable.

Record static geometry/materials once in persistent caller-owned storage:

```zig
var recorded: n64.graphics.RecordedModel = undefined;
// In a geometry pass, once; the asset and recording must remain alive:
try world.recordModel(&recorded, assets.model);
try world.drawRecorded(&recorded, &model_matrix);
```

Recording uses the existing fixed command-block capacity. Recorded commands
capture material/pipeline choices, including modes inherited when recorded.
Those commands take precedence over the replaying pass's baseline. Re-record
when those choices change, after all users of the old block finish. Camera,
lights, transform, and the separately bound pose remain dynamic. Replay does not
allocate, copy payloads, or rebuild the model commands.

## Timing, submission, and shutdown

`beginFrame` finishes a previously submitted frame, acquires a framebuffer,
polls input, and reports elapsed seconds in
`frame.delta` (clamped to `Options.max_delta`, default 0.25). Omitted color clear
preserves contents. Depth clears default on for 3D.

`frame.present()` submits if necessary, waits for both processors, and presents.
For overlap, call `frame.submit()`, do independent CPU work or service
`audio.Player`, then call `frame.present()` or `context.finish()`. Starting the next
frame also finishes an outstanding submission. There is one GPU submission in
flight, with no additional in-flight fence or frame queue.

`context.lastFrameStats()` reports the last finished frame: `frame_ms`,
`record_ms` (beginFrame to submit), `present_wait_ms`, and the RDP's own
hardware counters `rdp_busy_ms`, `rdp_pipe_ms` and `rdp_tmem_ms`. It needs no
debug output, so it is cheap enough to leave on.

Timeouts retain the frame and submission; the caller must retain borrowed data. Retry `present` or
`finish`; do not reuse hardware-owned memory. `frame.discard()` submits and
drains commands before releasing the frame because streamed commands may have
already executed. Discard can also time out and be retried. `deinit(allocator)`
rejects an unsubmitted active frame, waits for a submitted one, retires scanout,
and tears down in dependency order. Detach audio first. A scanout timeout retains
allocations for retry.

The default framebuffer access is `.gpu_only`, avoiding acquisition cache
invalidation. Select `.cpu_and_gpu` for CPU pixel access and follow the display
coherency rules. Custom pixel formats and allocation-free display setup remain
available through `display.Swapchain`.

Controller snapshots retain raw axes. `frame.input.stick(.{ .deadzone = 0.15,
.range = 80 })` applies a radial deadzone and clamps diagonal magnitude to one.
Disable polling with `.input = false` for deterministic render workloads.

## Direct access and migration

`runtime`, `renderer`, and `geometry` remain available for specialized work.
Direct context access follows the lower-level state/lifetime contract: it cannot
be observed or validated by a pass. Start a fresh pass after such work before
resuming pass drawing, and follow the render queue's `invalidateState` rule when
bypassing its state tracker with raw commands.

Frame-level `setCamera`, `drawModel`, and `drawText` remain direct-state
helpers. Calling them invalidates active pass handles. Their state semantics
remain direct; new code should use passes for per-draw defaults.

Geometry drawing now has one borrowing API:

- Pass `&camera` to `beginGeometry` or `setCamera`.
- Pass a fixed-matrix pointer to `drawModel` or `drawRecorded`; generate it with
  `writeFixed` directly into stable caller storage.
- Pass the final pose buffer to `setPose`.
- Edit a mutable model's vertices directly instead of calling `uploadVertices`.

The `*Borrowed` aliases, automatic snapshots, `uploads` field, and the `transforms`,
`cameras`, `pose_matrices`, and `vertex_pairs` context options have been removed.
`beginOverlay()` is `const hud = try frame.beginOverlay(.{})`; draw through `hud`.
`frame.drawSprite` has been removed; use `hud.drawSprite(image, SpriteOptions)`.
The former overlay `filter` and `antialias` options are now
`pipeline.state.modes.texture_sample` and `pipeline.state.modes.antialias_en`.

The lower-level renderer/context `beginFrame` still preserves pipeline state.
The context's initial preset is for direct-state drawing. Pass options, rather
than setters before `beginFrame`, determine the state used by pass drawing.
