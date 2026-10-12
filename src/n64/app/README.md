# Game loops and render passes

`n64.app.App(.{})` owns an RGBA16 display and renderer. Add
`.geometry = true` for geometry and a depth buffer. Audio can share its public
`runtime`. Initialize the app **in place**, in persistent storage: the runtime
and queues contain internal pointers.

```zig
var memory: [1024 * 1024]u8 = undefined;
var arena = std.heap.FixedBufferAllocator.init(&memory);
var app: n64.app.App(.{ .geometry = true, .transforms = 64, .cameras = 2 }) = undefined;

pub fn main() !void {
    n64.debug.init();
    try app.init(arena.allocator(), .{});
    var camera = n64.graphics.geometry.Viewport.init(320, 240);
    camera.setPerspective(n64.math.degreesToRadians(65), 1, 200);
    camera.lookAt(.init(0, 30, 80), .zero, .init(0, 1, 0));
    while (true) {
        const frame = try app.beginFrame(.{ .clear_color = .black });
        const world = try frame.beginGeometry(.{
            .camera = camera,
            .lighting = .{
                .ambient = .fromBytes(100, 100, 100, 255),
                .lights = &.{.{ .directional = .{ .direction = .init(-1, 1, 1) } }},
            },
        });
        try world.drawModel(assets.model, .identity);
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
return to geometry by starting a new pass with a camera. A failed geometry-pass
begin (camera capacity or too many lights) preserves the existing pass.
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

Camera snapshots are attached before lights are transformed. `Lighting.lights`
accepts directional and point lights in world space, up to
`graphics.geometry.max_lights`. That slice is consumed during pass creation and
can immediately be reused. Each new geometry pass establishes its own ambient
color and light count; default lighting is white ambient with no lights.

Overlay passes use one-cycle alpha blending with depth and perspective disabled.
`OverlayOptions` selects texture filtering and antialiasing. Each sprite or text
draw restores that baseline. Sprite RGB **and alpha** multiply the texture by
`SpriteOptions.tint` (white by default). Font-specific combiner, color, and
coverage changes apply to that text draw and do not leak into the next sprite.

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

Sprite regions use texel coordinates and must fit the image. Omit `source` for
the entire image. Negative scales flip, zero scale draws nothing, and nonzero
scale must fit the RDP's signed texture step. Rotation is not exposed by this
rectangle path. Text Y is the first baseline. Formatting scratch is consumed
while recording and may be immediately reused; `NoSpaceLeft` emits no commands.

## Bounded uploads and recorded models

Initialization allocates color buffers and, for 3D, one depth buffer using the
supplied allocator. Frame/pass methods allocate no heap memory. Command storage
is embedded, including two 64 KiB RDP buffers. The 2D app reserves no geometry
upload arrays. The 3D defaults reserve 128 transforms and four camera snapshots.
Pose and vertex uploads are opt-in:

```zig
var app: n64.app.App(.{
    .geometry = true,
    .transforms = 64,
    .cameras = 2,
    .pose_matrices = 128, // Total fixed bone matrices copied per frame.
    .vertex_pairs = 256, // Total packed VertexPair values copied per frame.
}) = undefined;
```

`world.drawModel` packs a transform into independent aligned frame storage.
`world.setPose(fixed_global_bones)` copies a pose and binds it for subsequent
first-joint model draws. Bind a pose explicitly before drawing a skinned model;
pass creation does not supply one. `drawModelBorrowed` and `setPoseBorrowed`
accept persistent storage without copying. Borrowed data must remain unchanged
until completion. These paths retain the native geometry cache-writeback rules.

`frame.uploadVertices(pairs)` copies packed vertices and returns a read-only
slice valid through frame completion. Use that slice in a `.dynamic` model part
so drawing writes it back before the RSP reads it:

```zig
var part = asset.model.parts[0];
part.vertices = try frame.uploadVertices(deformed_pairs);
part.data_usage = .dynamic;
var model = asset.model;
model.parts = (&part)[0..1];
try world.drawModel(asset.withModel(model), transform);
```

Part descriptors are consumed while recording. Referenced vertices, strips,
textures, and other payloads remain borrowed through completion. Uploading
vertices does not copy indices or materials. For multiple parts, construct a
caller-owned descriptor array in the same way. Frame upload exhaustion returns
`FrameStorageFull` before that upload/draw emits commands. Source arrays can be
reused after a successful copy. The app retains uploads through timeout recovery;
`uploads.matrix_high_water`, `pose_high_water`, and `vertex_high_water` report
peak usage across frames.

Record static geometry/materials once in persistent caller-owned storage:

```zig
var recorded: n64.graphics.geometry.RecordedModel = undefined;
// In a geometry pass, once; the asset and recording must remain alive:
try world.recordModel(&recorded, assets.model);
try world.drawRecorded(&recorded, transform);
```

Recording uses the existing fixed command-block capacity. Recorded commands
capture material/pipeline choices, including modes inherited when recorded.
Those commands take precedence over the replaying pass's baseline. Re-record
when those choices change, after all users of the old block finish. Camera,
lights, transform, and the separately bound pose remain dynamic.
`drawRecordedBorrowed` also accepts a persistent fixed transform. Neither replay
method allocates or rebuilds the recorded model commands.

## Timing, submission, and shutdown

`beginFrame` finishes a previously submitted frame, acquires a framebuffer,
resets completed upload storage, polls input, and reports elapsed seconds in
`frame.delta` (clamped to `Options.max_delta`, default 0.25). Omitted color clear
preserves contents. Depth clears default on for 3D.

`frame.present()` submits if necessary, waits for both processors, and presents.
For overlap, call `frame.submit()`, do independent CPU work or service
`audio.Player`, then call `frame.present()` or `app.finish()`. Starting the next
frame also finishes an outstanding submission. There is one GPU submission in
flight, with no additional in-flight fence or frame queue.

Timeouts retain the frame, submission, and upload storage. Retry `present` or
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

Existing frame-level `setCamera`, `drawModel`, `drawModelBorrowed`, `drawSprite`,
and `drawText` remain direct-state compatibility helpers. Calling them invalidates
active pass handles. They retain their original state semantics; new code should
use passes for per-draw defaults. `beginOverlay()` has changed to
`const hud = try frame.beginOverlay(.{})`; draw through `hud` afterward.

The lower-level renderer/context `beginFrame` still preserves pipeline state.
The app's initial preset is for direct-state compatibility. Pass options, rather
than setters before `beginFrame`, determine the state used by pass drawing.
