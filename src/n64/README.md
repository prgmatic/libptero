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
    const fence = n64.graphics.rdp.syncFull(&render);
    // Finish the RSP queue here when using an RSP-backed renderer.
    try display.present(frame, fence, .{});
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

Presentation is synchronous: it waits for the supplied RDP fence, then changes
VI origin during a fresh vertical blank. It neither submits rendering commands
nor waits for an RSP queue. Keep matrices, vertices, command buffers, and other
RSP resources alive until their queue finishes. The current RDP API supports
only one outstanding completion fence; the swapchain does not add queued fences.

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
