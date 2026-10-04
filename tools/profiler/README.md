# Hardware profiler

`n64.debug.profiler` records bounded traces in caller-owned RDRAM. Recording
allocates no memory, performs no debug transmission, and never waits for RSP,
RDP, PI or AI. Hooks are dormant until an application calls `start`.

The installed `ptero-profiler` tool converts a saved debug log into a standalone
HTML timeline, compact JSON, or Chrome/Perfetto trace-event JSON. It has no
network or hardware dependency and refuses to overwrite existing outputs.

## Capture through the public SDK

```zig
const profiler = n64.debug.profiler;
var events: [8192]profiler.Event = undefined;
var recorder = profiler.Recorder.init(&events);

// Keep both recorder and events alive and at stable addresses during capture.
try profiler.start(&recorder);
{
    const update = profiler.scope("Actor update");
    defer update.end();
    updateActors();
}
profiler.instant(.cpu, "Frame", frame_number);
profiler.counter(.cpu, "Visible actors", visible_actors);
// Continue normal frame/audio service for a bounded number of frames.
try profiler.stop(&recorder);

// Finish normal GPU work and drain/stop audio before slow debug transmission.
// Initialize n64.debug first. Never export from an interrupt handler.
try profiler.exportTrace(&recorder, 1);
```

For an asynchronous operation, use `begin(lane, comptime_name, value)` and
retain its returned `Scope` until completion. Call `end` or `endValue` exactly
once. Scope tokens carry a capture generation; ending an old token after
another capture starts cannot corrupt the new capture. Work begun before
capture is not assigned a synthetic start. Work that finishes after capture
has an open interval in its saved prefix.

There is one active recorder. `start` returns `AlreadyCapturing` when one is
installed; `stop` requires that same recorder and otherwise returns
`NotCapturing`. Starting again resets the storage, label dictionary and counts.
The console is single-core: recording masks CPU interrupts only while updating
the recorder, then restores the previous status. Hooks in AI and DP servicing
may append records safely even when invoked from an interrupt. These hooks do
not transmit or run mixing inside interrupts. Call start/stop/export from normal
application code, and do not directly mutate the installed recorder.

Names are compile-time, printable ASCII strings of 1–63 bytes. Up to 64 unique
names are interned without allocation. Each event retains its timestamp, lane,
kind, label, span ID and numeric value. Payload events occupy 24 bytes on N64;
8192 events reserve 196,608 bytes, plus the recorder's fixed metadata. The
buffer retains its initial events when full; it never overwrites earlier ones.
Omitted writes increment a saturating `dropped` count. Label exhaustion also
counts omissions. The viewer warns about loss and marks unfinished intervals
with dashed outlines; complete-scope totals exclude them.

Timestamps extend the 32-bit CP0 Count register using wrapping subtraction and
use the 46,875,000 Hz Count clock. Record at least once every 91.6 seconds, or
keep captures shorter than that interval; multiple wraps between observations
cannot be reconstructed. Duration is recorded at stop, including quiet gaps.
No wall-clock timer, allocation, interrupt clock, or global time service is needed.

## Built-in observations

| Lane | Events and interpretation |
| --- | --- |
| CPU | Explicit application scopes, RSP submission/wait wrappers, render completion waits, audio service/refill |
| RSP low | Queue submission markers (value = pre-epilogue words); syncpoint publication to CPU-observed completion (value = target sequence) |
| RSP high | High-priority batch request to CPU-observed completion (value = sealed command words) |
| RDP | Fence arm to DP interrupt service or polling acknowledgement (value = target sequence) |
| PI | DMA issue to first completed poll (value = bytes; endpoint value 1 on PI error) |
| Audio | AI enqueue markers (value = submitted buffer sequence), queued-buffer and underrun counters |

These are CPU observations on one clock, **not exact hardware execution times**.
RSP/RDP intervals include queueing, preemption, command construction where
applicable, and acknowledgement delay. PI completion is an upper bound when
polling is infrequent. Overlapping RSP lanes do not imply simultaneous RSP
execution. AI counters show serviced FIFO state, not a sampled waveform.
Nested CPU scopes are inclusive; adding their totals double-counts nested work.
No extra fences, syncpoints, DMA, processor halts or completion polls are inserted
for tracing, and command ABI/microcode remain unchanged.

Dormant hooks check the active-recorder pointer without reading Count or masking
interrupts. Active hooks include the short interrupt critical section, label
lookup and record stores. Profiling changes CPU timing: use the example's
hardware calibration to quantify the cost for that build and capture only when
needed. The recorder API's `*At` methods are a hardware-independent model for
unit testing, not an alternative concurrent recording interface.

## Example and viewer

From the epoch workspace:

```sh
(cd core && zig build install tests)
(cd examples && zig build profiler)
set -o pipefail
zig run deploy.zig -- examples/zig-out/profiler.z64 2>&1 | tee /tmp/profile.log
core/zig-out/bin/ptero-profiler /tmp/profile.log /tmp/profile.html
core/zig-out/bin/ptero-profiler /tmp/profile.log /tmp/profile.json
core/zig-out/bin/ptero-profiler /tmp/profile.log /tmp/profile.chrome.json --chrome
```

The example shares the existing public-SDK compressed-audio cube scene. It
calibrates 256 dormant markers, 256 recorded markers, and 256 scope pairs before
AI starts, warms up for 30 frames, captures 120 frames, then finishes its finite
180-frame run. It exercises a distant seek and periodic resident sound effects.
Audio drains before export; the normal benchmark completion marker lets the
existing runner power off the console. `@@PROFILE_OVERHEAD@@` reports raw Count
ticks and `@@PROFILE_CAPTURE@@` reports event/storage/loss/underrun counts.
Ordinary audio targets reserve no trace payload arrays.

Open the HTML in a browser. Filter labels, toggle lanes, zoom with the wheel or
buttons, drag to pan, and click the overview to navigate. Click a scope, instant
marker or counter sample to inspect values. Keyboard `+`/`-` zoom, arrows pan,
and `0` fits the capture when the timeline has focus. Download data exports the
compact JSON. The page embeds its complete data and uses no external resources.
For huge captures, prefer Chrome/Perfetto export; the built-in viewer draws all
matching events when refreshing the view.

## Transport and host API

Capture IDs must be unique within one log. Export one stopped capture at a time;
do not interleave other debug writes from interrupts. Backend output is
best-effort and can block. The decoder rejects a lost/truncated transfer rather
than manufacturing a trace. It decodes the first capture and ignores ordinary
surrounding logs and prefixes.

Protocol v1 uses BEGIN (ID, version, clock Hz, event count, label count, dropped,
duration ticks), indexed hexadecimal LABEL names, indexed EVENT records (ticks,
kind, lane, label, span, value), and END (ID, CRC32). Kind and lane IDs follow
`src/n64/debug/profiler/trace.zig`. The CRC covers canonical big-endian header
fields, length-prefixed label bytes and all event fields, independent of host
endian or Zig padding. Indexes, counts, IDs, timestamp order, enum values and span
pairing are validated. Host decoding caps event count at one million, label
count at 64, and timestamps at JavaScript's maximum exact integer. The CLI caps
input at 256 MiB. Raw JSON preserves Count ticks; Chrome JSON uses microseconds.

`tools/profiler/root.zig` exposes `decode(allocator, log)`, `Trace.deinit`,
`writeHtml`, `writeJson`, and `writeChrome` with a `std.Io.Writer`. `main.zig`
owns CLI parsing, diagnostics and IO. Host regressions run with `zig build test`;
the standard hardware ROM checks balanced PI/RSP/RDP observations and intact
rendered pixels. With Node.js available, `zig build test` also runs the actual
embedded viewer script against a small DOM/canvas test double; these checks are
also available as `zig build test-profiler-viewer`. They cover nesting, filters,
lane selection, event inspection, zoom/pan, overflow and empty captures without
requiring a browser. Node.js is optional for the SDK and installed host tool.
Temporary traces and logs belong outside Git.
