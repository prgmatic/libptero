# Render diagnostics

Diagnostics are opt-in through `n64.debug.diagnostics`. They allocate no memory
on the console and use the currently initialized SC64 or IS Viewer debug backend.
Do not enable continuous capture in performance measurements: hexadecimal output
is deliberately simple and portable, but slow. No scene-specific behavior is built in.

## Framebuffer capture

Capture a tightly packed `ImgRgba16` or `ImgRgba32` after submitting its final
full-sync fence. Keep the image alive and prevent CPU/RSP/RDP writes or buffer reuse
until capture returns. For an RSP-backed renderer, finish its queue as well:

```zig
const fence = n64.graphics.rdp.syncFull(rq);
if (!n64.rsp.waitTimeout(&renderer.queue, 1_000_000)) {
    n64.debug.diagnostics.reportRenderTimeout("frame queue", &renderer.queue);
    return error.RspTimeout;
}
try n64.debug.diagnostics.captureFramebuffer(frame, fence, 1, 1_000_000);
```

The fence passed to capture must be the fence for this frame, not an unrelated or
old fence. Do not schedule another fence before capture. Direct CPU RDP submission
does not need the RSP wait. Capture reads KSEG1 uncached RDRAM and does not alter CPU
cache contents. CPU changes intended for RDP must already have been written back
before submission. Only RDRAM KSEG0/KSEG1 pointers are supported.

Relay console debug output to a file with your existing hardware/emulator runner.
Build and decode with:

```sh
zig build install
zig-out/bin/framebuffer-capture /tmp/debug.log /tmp/frame.png
```

The output must not exist (the tool refuses to overwrite). The tool decodes the
first capture, accepts ordinary surrounding logs and prefixes, and rejects partial,
out-of-order, duplicate, or invalid chunks. Captures use unique numeric IDs and
`@@PTERO_FB_BEGIN@@`, `@@PTERO_FB_DATA@@`, and `@@PTERO_FB_END@@` lines. Transfers
are contiguous: do not interleave debug writes/other captures from interrupts.
Transport loss is detected by offsets and exact length, but there is no retransmit
or checksum for silent corruption. Supported pixel formats are RGBA5551 and RGBA8888;
PNGs preserve their alpha values (RDP coverage bits can therefore appear transparent).
The tool saves raw framebuffer pixels, not VI filtering/gamma output. It reads a
saved log rather than owning SC64 transport, console power, or credentials.

## Geometry probes

```zig
const result = n64.debug.diagnostics.probeVertices(vertices[0..2], 8);
// result.compared_bytes and result.mismatched_bytes
```

This compares CPU-visible `geometry.VertexPair` bytes against their uncached RDRAM
alias, logging at most eight differing byte locations plus a summary. Stop CPU/RSP
writes first. Do not flush/invalidate just before the probe when investigating a
missing writeback: that would hide the problem. Probe again after the writeback to
confirm. Geometry probes read submitted packed input, not RSP transformed DMEM output.

## Timeout reports

```zig
if (!fence.waitTimeout(1_000_000)) {
    n64.debug.diagnostics.reportRenderTimeout("HUD fence", &renderer.queue);
    return error.RdpFenceTimeout;
}
```

Use `null` for direct RDP submission without an RSP queue. Reports include RSP
status/PC/DMA busy/full, RDP status/start/end/current, and both software command-buffer
addresses, word counts, sealing, link presence, queue priority/submission/recording
state. `RenderSnapshot.read()` also exposes raw hardware values for other reporters.
No hardware waits, RSP halt, DMA, semaphore reads, or allocation are performed while
collecting a snapshot. It is best-effort, not atomic: hardware can advance between
MMIO reads. Transmission still inherits backend waits, so a failed debug connection
can delay reporting. Queue pointers must refer to initialized, stable queues.

Host parser/PNG tests run with `zig build test`. The hardware ROM includes a render
diagnostics test with a 4×4 green RGBA32 capture (ID 9001), a vertex-writeback probe,
and a deliberately labeled snapshot self-test. Run `zig build tests` to build it.
