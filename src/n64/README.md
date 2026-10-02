# n64 runtime

The public `n64` module exposes hardware interfaces, graphics, RSP queues,
input, math, cache operations, debugging, and display buffer management.

## Display buffers

`n64.display.Swapchain(Pixel)` manages RGBA16 or RGBA32 framebuffers. It owns
one contiguous allocation when initialized with an allocator:

```zig
const Pixel = n64.graphics.color.Rgba16;
var display = try n64.display.Swapchain(Pixel).init(allocator, .{
    .resolution = .@"320x240p",
    .buffer_count = 3,
});

while (true) {
    const frame = try display.acquire();
    render.clear();
    render.setFrameBuffer(frame.image);
    render.clearScreen(Pixel.black);
    // Record drawing commands here.
    const completion = render.submit();
    try display.present(frame, completion, .{});
}
```

For allocation-free setup, supply a `[]align(64) Pixel` to `initBuffer`.
`requiredPixelCount(options)` returns the required number of pixels. The used
storage is cleared to black and written back; extra storage is untouched.
Borrowed memory is never freed by `deinit`, and its allocator argument is ignored.
The first buffer starts as the black front buffer. At least two are required.
The ROM main loop above retains its storage until reset. In a returning scope,
call `try display.deinit(allocator)` after completing all rendering, including
any work still pending after a timeout.

Each acquired frame exposes a borrowed `image` and an `index` suitable for
selecting matching application-owned depth buffers. One acquisition may be
outstanding at a time. Presenting or releasing it invalidates every copy of its
token. Call `release(frame)` to abandon an acquisition after any work using it
has completed. Do not access pixels after returning the frame.

Presentation is synchronous: it waits for the supplied render completion, then
changes VI origin during a fresh vertical blank. `render.submit()` submits RDP
commands and, for an RSP-backed render queue, inserts a stable RSP syncpoint.
`geometry.submit()` also synchronizes pending triangle work. The returned
`Completion` supports `poll()`, `isComplete()`, and `wait(.{ .max_attempts = ... })`.
Polling services DP interrupts even while RSP work is pending. A wait reports
`RspTimeout` or `RdpFenceTimeout` and can be retried. Copies of a completed token
stay complete after later submissions (within 2^31 completion markers).

Keep matrices, vertices, command buffers, and the queue itself alive until both
processors complete. A queue must remain at a stable address and must not be
reset while its token is pending. Submission and waiting allocate no memory.
Only one RDP fence and one RSP syncpoint may be outstanding; this API does not
introduce queued frames or multiple in-flight fences. For raw control,
`rdp.syncFull` remains available and `display.presentFence` accepts its fence,
with the caller responsible for separately finishing RSP work.

`.present_mode = .immediate` switches origin as soon as rendering finishes and
may tear. Its next `acquire` waits for a fresh retrace before making the previous
scanout reusable. The default `.vsync` finishes this retirement during present.
Both modes poll VI directly and work without enabling VI interrupts. Polling
does not consume interrupt events. `max_attempts` limits polls, not elapsed time.
A presentation timeout retains the acquisition for retry; complete outstanding
work before releasing it. An acquire timeout does not acquire a frame.

For CPU rendering, fill `frame.image` and use `presentCpu(frame, .{})`, which
writes the pixels back before presentation. Acquire invalidates the buffer's
CPU cache lines so reads see the most recent hardware contents. GPU presentation
does not write back framebuffer cache lines. When combining CPU and RDP writes,
write back CPU changes before submitting GPU commands.

Only one swapchain may control VI at a time. Do not change its buffers, VI
configuration, or origin through the low-level API while it is active. The
swapchain is single-threaded. Complete GPU work before `deinit`; it blanks VI and
waits for a fresh retrace before freeing owned storage. On timeout, storage is
retained and teardown can be retried. Use the same allocator that initialized it.

All existing progressive resolutions, both pixel formats, arbitrary buffer
counts of two or greater, and NTSC/PAL/M-PAL timing selection are supported.
Interlaced resolutions return `UnsupportedResolution`: field-aware interlaced
scanout is not implemented in this manager. The raw VI API remains available for
custom display management. See `examples/src/spinning-cube.zig` in the examples
repository for manual allocation and presentation.

## Render state

Render queues accept complete pipeline values through `getModes`/`setModes` and
`getState`/`setState`. State is compared against the last emitted values before
drawing; there are no public dirty flags. Reapplying the same state emits no
redundant mode commands. Convenience setters update the same tracked values.

```zig
var state = n64.graphics.rdp.State.opaque_geometry;
state.modes.antialias_en = false;
render.setState(state);
```

`opaque_geometry`, `translucent_geometry`, and `textured_sprite` are editable
`State` values. They include modes and the combiner; they do not bind textures,
set color registers, or change geometry flags. `withBlend` returns a modified
copy for a custom blender. Use `flushModes` to emit changes explicitly.
`clearScreen`, `clearDepth`, and `drawRect` temporarily use fill mode and restore
the requested modes on the next draw. After bypassing the renderer through
`cmd_queue`, call `invalidateState` to invalidate mode and TMEM tracking. Clearing
a CPU command buffer also invalidates tracking because its commands are discarded.

## RSP runtime, renderer, and optional geometry

Setup is explicit and separate from allocation and display:

```zig
var runtime: n64.rsp.Runtime = undefined;
runtime.init();
var renderer: n64.graphics.Renderer = undefined;
renderer.init(&runtime);
// Sprite and font drawing uses &renderer.render directly.

var geometry: n64.graphics.geometry.Context = undefined;
geometry.init(&renderer); // Optional: adds geometry and clipping support.
// Model drawing uses &geometry and shares renderer.render's tracked state.
```

Declare these large objects in persistent application storage. They initialize
in place and must not move after initialization: their queues and overlays
contain pointers into their own storage. `Runtime` loads the built-in resident
program and registers RDP. `Renderer` borrows it and contains the command queue
and two 64 KiB RDP buffers. It does not initialize geometry or allocate a heap.
`geometry.Context` borrows the renderer's queue and render state, registers its
own geometry overlay, and prepares clipping support. Font and sprite examples
need only the first two objects.

Complete pending RSP/RDP work before attaching or detaching geometry. Teardown
order is `geometry.deinit()`, `renderer.deinit()`, `runtime.deinit()`. The renderer
remains usable for 2D drawing after geometry is detached. Only one runtime may
control the hardware, one renderer may attach to it, and one geometry context
may attach to that renderer. Raw RSP programs, queues, overlays, and direct RDP
render queues remain available for custom storage and hardware scheduling.
