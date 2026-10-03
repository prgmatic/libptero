# PCM audio

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

This first port supports fully resident samples smaller than 512 KiB. It does
not implement streaming sample buffers, wav64 loading, VADPCM or Opus decoding,
tracker playback, or event sequencing. The original mixertest uses compressed
assets; these examples deliberately play its original WAV PCM instead.

Host tests verify conversion, validation, fixed-point controls, FIFO ownership,
and generated metadata. ROM tests exercise the public generated assets, EOF
silence, looping/resampling, both cores, four-buffer AI draining, first-use
priority startup, and sustained preemption of clipped geometry across queue
refills. The benchmark pair compares startup smoothing, a volume transition,
PCM output and address-normalized channel state across 24 identical workloads.
