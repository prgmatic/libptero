# Audio

The PCM command in `../rsp/ucode/audio_mixer.zsp` ports libdragon's
`src/audio/rsp_mixer.S` command 0 at commit
`5cb976aab11eb30622c33b112c120a1107eedb5e`. Its production MIPS I/o32 instruction
words match exactly except checked address relocations. Both the 8-slot and
32-slot cores, signed PCM8/PCM16, mono/stereo, point resampling, looping, volume
smoothing, and the misaligned output merge are preserved. This is normal ZSP;
it contains no inline assembly.

Build assets through the public SDK:

```zig
var assets = sdk.createAssets("audio_assets");
assets.addAudio("effect", b.path("effect.wav"), .{});
assets.addAudio("music", b.path("music.wav"), .{ .loop = true });
```

The converter accepts classic RIFF/WAVE PCM, 8 or 16 bits, one or two channels.
It preserves sample rate and channel order, converts unsigned PCM8 to signed
PCM8 and little-endian PCM16 to big-endian PCM16, and appends 64 readable bytes
of silence or repeated loop data. It emits raw bytes plus a typed
`n64.audio.Sample`, without wav64 headers or pointer fixups. The installed CLI
is `audio-compiler input.wav output.pcm output.zig name [--loop]`.

Initialize persistent objects at stable addresses:

```zig
runtime.init(); // One shared n64.rsp.Runtime for graphics and audio.
try output.init(allocator, .{ .frequency = 48000, .buffer_count = 4 });
try mixer.init(&runtime, 16);
try mixer.play(0, assets.music, output.timing.frequency);
try mixer.setVolume(0, 0.5, 0.5);
// Per application frame, after submitting graphics:
_ = try mixer.tryPlay(&output, 1_000_000);
```

`Mixer` borrows the runtime and registers one high-priority queue. Stereo
occupies two consecutive slots; controls reject the secondary slot. Frequency
and signed volume conversion match libdragon's fixed-point truncation. Stop
and frequency changes preserve the RSP volume filter. Only one mixer may attach
to a runtime. Finish mixing before editing sample data or settings. A timeout
retains borrowed resources: retry `mixer.wait`, then `output.commit` for the
buffer acquired by `tryPlay`. Complete all work and deinitialize the mixer
before its runtime.

`Output` owns AI and allocated PCM storage. Its short interrupt callback only
retires and schedules completed buffers. `acquire` also services AI through
polling, so output works when CPU interrupts are masked. Four buffers at
requested 48000 Hz on NTSC use the reference's reported frequency 47986 Hz and
1912 stereo frames per buffer. DAC divisor 1014 and bit divisor 15 match
libdragon. PAL and MPAL calculations are supported. Select the same region as
VI. Buffer storage includes the eight-byte workaround for AI's delayed address
carry when a DMA ends at an 8 KiB boundary. `submitted_buffers` counts scheduled
buffers. `deinit` drains them before stopping AI and freeing storage; a timeout
retains ownership for retry.

For custom PCM workloads, `Mixer.settings` exposes the exact 896-byte command
ABI. Submit interleaved stereo `[]align(4) i16` output and wait for completion.
The caller owns entire DMA/cache lines, including up to four bytes of trailing
DMA padding for an address that is 4 modulo 8. Sample memory includes 64 readable
bytes after its logical end. The built asset pipeline supplies that padding.

Resident samples must be smaller than 512 KiB; larger sources use the ROM-streamed
path below. wav64 loading, Opus decoding, tracker playback, and event
sequencing remain unsupported. The original mixertest uses compressed assets;
these examples deliberately play its original WAV PCM instead.

Host tests verify conversion, validation, fixed-point controls, FIFO ownership,
and generated metadata. ROM tests exercise the public generated assets, EOF
silence, looping/resampling, both cores, four-buffer AI draining, first-use
priority startup, and sustained preemption of clipped geometry across queue
refills. The benchmark pair compares startup smoothing, a volume transition,
PCM output and address-normalized channel state across 24 identical workloads.

## ROM-streamed PCM

Set `.storage = .rom` on `AssetBundle.addAudio` to emit a `StreamSample` instead
of a resident `Sample`. Input support remains mono/stereo PCM8/PCM16 WAV; the
converter emits signed PCM8 or big-endian PCM16. The payload stays in cartridge
ROM. Streamed assets can exceed the resident 512 KiB position limit and RAM size.
VADPCM assets use the same Stream API, as described below.

```zig
// Build: assets.addAudio("music", b.path("music.wav"),
//                        .{ .loop = true, .storage = .rom });
var storage: [16 * 1024]u8 align(16) = undefined;
var music: n64.audio.Stream = undefined;
// After initializing mixer/output:
music = try .init(assets.music, &storage);
try mixer.playStream(0, &music, output.timing.frequency);
try mixer.seek(0, assets.music.frequency * 30); // 30 seconds
try mixer.setVolume(0, 0.5, 0.5);
_ = try mixer.tryPlay(&output, 1_000_000);
```

Keep Stream and its storage at stable addresses until it is detached. Stereo
uses two mixer slots. Separate Stream instances and windows can play the same
asset independently. Volume, frequency and stop controls are shared with resident
voices; `Mixer.seek` operates on an attached streamed voice, measured in source
frames. Seeking retains the volume filter. Stop releases the stream; play starts
it at frame zero. EOF clamps its cursor to the logical end and detaches it.
`positionFrames` reports the source position and preserves fractional progression
internally. Tail loops are supported through `loop_frames` metadata; the build
option generates a full-track loop. Windows expand loop crossings and zero-pad
finite EOF, including the microcode's 64-byte DMA overread. Tiny loops are repeated
in RAM after their first read. The PCM microcode is unchanged.

Windows must be a multiple of 16 bytes, at least 80 bytes and smaller than
512 KiB. Actual minimum size depends on output batch length, playback frequency,
channels, and format. A too-small window returns `StreamBufferTooSmall` before
submission. For 1912-frame output batches, stereo16 at 22050/47986 Hz fits easily
in 16 KiB. Each Stream additionally owns a fixed 4 KiB ROM reader. No allocation
happens during mixing. Refill is synchronous before RSP submission; existing
window data is reused until a batch plus overread no longer fits.

`Mixer.stream_read_attempts` bounds each reader wait. On a PI timeout, no output
is submitted to the RSP. The stream reader retains its window destination;
complete `stream.reader.wait` before stopping/freeing it, then retry submission.
A subsequent `submit` first finishes a pending read and refills the window.
The existing RSP timeout contract still applies after submission. Do not mutate
Stream metadata, cursors, storage or mixer settings while a batch is pending.

`Output.underruns()` counts AI FIFO exhaustion after playback starts. Startup
before the first buffer and intentional `deinit` drain are excluded. It requires
regular service or AI interrupts; it reports scheduling gaps, not audio quality.
Stream `refills`, reader byte/transfer counts, and batch Count timings support
memory/refill benchmarks. Exact hardware comparisons cover all four PCM formats,
half/native/double and fractional rates, volume transitions, looping, seek, EOF,
independent voices, PI retry, and forced geometry preemption with clipping.

## VADPCM compression

```zig
assets.addAudio("music", b.path("music.wav"),
    .{ .compression = .vadpcm, .storage = .rom, .loop = true });
```

Compression selects a ROM-backed `StreamSample`. It accepts the same mono/stereo
PCM8/PCM16 WAV inputs and decodes to PCM16 at the original sample rate. VADPCM is
lossy: sixteen PCM16 samples become nine bytes per channel. The host converter
uses the same four-predictor, order-two encoder as libdragon, vendored under
MPL-2.0 in `tools/audio_compiler/vendor/vadpcm`. The installed CLI's `--vadpcm`
switch implies ROM storage. Generated metadata contains a 256-byte aligned
codebook; compressed blocks and seek histories remain in cartridge ROM.

`audio_vadpcm.zsp` ports libdragon's VADPCM_Decompress and VADPCM_SetState
commands as **184 identical instructions**, with verified address
relocations and normal ZSP only. The decoder has its own shared-DMEM overlay;
its scratch ends at `0xFE8`, leaving 24 bytes. Codebook banks are aligned so the
reference's stereo XOR toggle works. Maximum batches are 94 mono or 47 stereo
blocks (1504 source frames mono, 752 stereo). Decoder state is a caller-owned
32-byte RDRAM history, so voices remain independent across overlay switches.

Mixer lazily registers the decoder when a compressed stream starts. Refill
reads encoded blocks, runs decoder commands on the high-priority queue, waits,
and copies PCM into the existing stream window. The unchanged PCM overlay then
mixes that window. Every 1024 source frames has a 32-byte history checkpoint.
An arbitrary seek restores the preceding checkpoint and discards at most 1023
frames before the requested position. Loops and EOF preserve exact logical
frame counts, including boundaries inside a sixteen-sample encoded block.

No allocation happens during refill. Each Stream owns an additional 3072-byte
RDRAM decode workspace and 32-byte history; its existing PCM window and 4 KiB
ROM reader remain caller/fixed storage. Uncompressed voices also carry this
fixed codec storage in the current Stream type. Refills and `compressed.decoded_blocks`
can be used to measure workload. VADPCM's payload ratio excludes checkpoint and
codebook overhead. Huffman-packed VADPCM and wav64 container loading are not
implemented; generated assets use native metadata and plain VADPCM blocks.

A PI timeout retains the Reader destination. An RSP decoder timeout retains the
workspace/history and rejects mixer controls/deinitialization with `MixerBusy`.
Retry `Mixer.submit`/`tryPlay` to finish the pending decode and refill; to abandon
playback, first complete `stream.reader.wait` and `mixer.decoder.wait`, then stop.
The raw `n64.audio.vadpcm.Decoder` also exposes asynchronous `submit`,
`submitState`, and `wait`; keep it and its borrowed buffers stable, and destroy
it before the runtime. Raw output may have any even byte alignment, provided the
caller owns complete DMA/cache lines and eight trailing padding bytes.
