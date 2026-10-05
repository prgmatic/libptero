# Game loops

`n64.app.App(.{})` is an optional RGBA16 application owner for 2D games.
`App(.{ .geometry = true })` adds geometry and a matching depth buffer. Both
share one public `runtime` with audio. Initialize the app **in place**, in
persistent storage: its renderer, runtime, and queues contain internal pointers.

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
        const movement = frame.input.stick(.{});
        _ = movement;
        try frame.setCamera(camera);
        try frame.drawModel(assets.model, .identity);
        try frame.beginOverlay();
        try frame.drawText(assets.font, 16, 20, "Hello!", .{});
        try frame.present();
    }
}
```

See the examples repository's `collect` target for a complete game with a title,
three rounds, time-based movement, pause/restart, effects and HUD. `model`,
`texture-pipeline` and `font-rendering` are smaller introductions.

## Ownership and performance

Initialization allocates color buffers and (for 3D) one depth buffer using the
supplied allocator. Frame methods allocate no heap memory. Renderer command
storage is embedded, including two 64 KiB RDP buffers. The 2D app reserves no
matrix or camera upload arrays. The 3D defaults reserve 128 matrices and four
camera snapshots; change the compile-time budgets to suit the game.

`setCamera` snapshots a viewport. `drawModel` packs a transform directly into
independent aligned frame storage. Both return `FrameStorageFull` before drawing
when their budget is exhausted. `uploads.matrix_high_water` reports actual peak
transform usage. `drawModelBorrowed` avoids copying a persistent fixed-point
matrix; the caller must keep it and the model unchanged until completion. All
asset payloads remain borrowed; copying a transform does not copy geometry or
textures. Pose/vertex uploads still use the existing explicit geometry API.

Frame storage is recycled only after completion and presentation. Frame handles
carry a generation; copies become invalid together. Drawing after submission
returns `FrameSubmitted`, and old handles return `InvalidFrame`. Do not move or
reinitialize the app while handles/work are live. As with other owners, using a
handle after destroying/reinitializing its owner is invalid.

`beginFrame` completes any previously submitted frame, acquires a framebuffer,
establishes an opaque-geometry or textured-sprite state, polls input, and reports
elapsed seconds in `frame.delta` (clamped by `Options.max_delta`, default 0.25).
Omitted color clear preserves contents. Depth clears default on for 3D.
`beginOverlay` synchronizes triangles and establishes sprite state before HUD
commands. Public `renderer`, `geometry`, and `runtime` remain available for
custom lights, materials, recorded models, poses and low-level drawing. Work
submitted through those escape hatches must still respect the app's lifetime.

The default framebuffer mode is GPU-only, avoiding acquisition cache
invalidation. Explicitly select `.display.framebuffer_access = .cpu_and_gpu`
when accessing frame pixels on the CPU and follow the display coherency rules.
The app handles RGBA16 progressive display modes; custom pixel formats and
allocation-free display storage remain available through `display.Swapchain`.

## Submission, errors and shutdown

`frame.present()` submits if necessary, waits for both processors and presents.
For overlap, call `frame.submit()`, perform independent CPU work or service
`audio.Player`, then call `frame.present()` or `app.finish()`. Starting the next
frame also finishes an outstanding submitted frame. This supports CPU/GPU
overlap, with one GPU submission in flight; it does not introduce multiple
outstanding fences.

A timeout retains the frame, submission and upload storage. Retry `present` or
`finish`; do not reuse/free hardware-owned memory. `frame.discard()` submits and
drains commands before releasing an abandoned frame, because streamed commands
may already have executed during recording. Discard can also time out and be
retried. `deinit(allocator)` rejects an unsubmitted active frame, waits for a
submitted one, retires scanout, and tears down in dependency order. Detach audio
first. A scanout timeout retains allocations and permits teardown retry.

Controller snapshots retain raw axes. `snapshot.stick(.{ .deadzone = 0.15,
.range = 80 })` applies a radial deadzone and clamps diagonal magnitude to one.
Input can be disabled with `.input = false` for deterministic render workloads.
