# RDP rotating-star hardware benchmark

The two ROMs render the same fixed frame at 32, 64, and 128 stars. Each sample
uses a 320x240 RGBA16 target, clears to `0x404040`, uploads the procedural 32x32
RGBA32 star once, and draws each centered sprite at 0.25 radians as two textured
triangles with texture-times-primitive combining and source-alpha blending.

Both builds optimize for size (`ReleaseSmall` and `-Os`). Two fully completed
warmup frames precede eight measured frames. CP0 Count ticks run at 46.875 MHz.
`submit_ticks` ends after enqueueing the full-sync/detach; `total_ticks` ends only
after the RDP has completed the frame.

Build with:

```sh
zig build rdp-benchmark
make -C benchmarks/libdragon-rdp-stars
```

The comparison below uses libdragon trunk commit `c60bfbfc2`. The local
`preview` branch at `5cb976aab` is not equivalent: its in-development xform
triangle path locked up on this hardware workload. Build the pinned trunk
revision with libdragon's official container:

```sh
bench_ref_dir=$(mktemp -d /tmp/libdragon-rdp-stars.XXXXXX)
git -C /home/mt/dev/n64/ld-testing/libdragon archive c60bfbfc2 | \
  tar -x -C "$bench_ref_dir"
# Match ReleaseSmall. The static-inline change only fixes trunk's GNU inline
# linkage when vi_write_config is no longer forced inline by -O2.
sed -i 's/-DN64 -O2 /-DN64 -Os /' "$bench_ref_dir/n64.mk"
sed -i 's/^inline void vi_write_config/static inline void vi_write_config/' \
  "$bench_ref_dir/src/vi.h"
docker run --rm \
  -v "$bench_ref_dir":/libdragon \
  -v "$PWD":/work -w /work/benchmarks/libdragon-rdp-stars \
  ghcr.io/dragonminded/libdragon:latest \
  sh -lc 'make -C /libdragon && make -C /libdragon install tools-install && make'
```

Deploy each `.z64` with `zig run deploy.zig -- <rom>` and capture the
`@@RDP_STARS_BENCH@@` lines.

## 2026-08-22 hardware run

Both implementations completed on the same SC64/N64:

| Implementation | Stars | Submit ticks | Total ticks | Submit ms | Total ms |
|:---|---:|---:|---:|---:|---:|
| libptero | 32 | 356123 | 509406 | 7.60 | 10.87 |
| libptero | 64 | 620006 | 882122 | 13.23 | 18.82 |
| libptero | 128 | 1147867 | 1627177 | 24.49 | 34.71 |
| libdragon | 32 | 113772 | 193826 | 2.43 | 4.13 |
| libdragon | 64 | 233031 | 326738 | 4.97 | 6.97 |
| libdragon | 128 | 464045 | 609892 | 9.90 | 13.01 |

Libdragon is 2.5-3.1x faster at CPU submission and 2.6-2.7x faster end to end.
The asymptotic submission cost is about 8,248 ticks per libptero star versus
3,610 ticks per libdragon star. Both submit the same three vertex commands and
one triangle command per triangle; the remaining gap is queue/API overhead and
the generated overlay implementation, not an RDP triangle-count limitation.

## Bottleneck evidence

- CPU-side cost is material: at 128 stars libptero has already spent 24.49 ms
  when submission returns, versus 9.90 ms in libdragon. Libptero's
  `nativeTexturedTriangle` clamps and converts every X/Y/S/T/W component and
  routes each command through `Queue.ensureCapacity` plus slice-based
  `writeRawCommand`. Libdragon's `rdpq_triangle_rsp` does direct conversions and
  expands its compile-time `rspq_write` macro directly into volatile queue
  stores.
- Both low-priority queues use two 512-word buffers. Libptero keeps cached
  buffers and writes back both complete 2 KiB buffers on each rollover;
  libdragon allocates its queue buffers uncached and publishes commands by
  writing their first word last. A textured star consumes 44 queue words, so
  rollover occurs about every eleven stars and is common at all measured
  counts.
- RSP-side work is also material. After CPU submission at 128 stars, libptero
  needs another 479310 ticks (10.23 ms), while libdragon needs 145847 ticks
  (3.11 ms). Since the geometry, pixels, and final RDP triangle format are
  matched—and libptero gives its RSP more head start while its CPU submits—this
  is evidence that the generated ZSP triangle path and/or its RDP-buffer
  scheduling remains slower than libdragon's hand-scheduled overlay.

Concrete optimization targets are therefore: an uncached streaming command
queue (or dirty-range-only writeback), specialized fixed-size enqueue routines
that publish the header last, removing redundant vertex clamps/conversions for
typed inputs, and instruction-level comparison of ZSP's triangle fast path
against libdragon trunk's `rsp_rdpq` overlay.

## Optimization experiments

Hardware measurements below changed one queue/conversion strategy at a time.
They are retained here even when rejected so later work does not infer safety
from submission timing alone.

| Experiment | Stars | Submit ticks | Total ticks | Result |
|:---|---:|---:|---:|:---|
| KSEG1 queue buffers plus fixed triangle enqueue | 32 | 362675 | 514979 | Rejected: slower |
| KSEG1 queue buffers plus fixed triangle enqueue | 64 | 633598 | 894438 | Rejected: slower |
| KSEG1 queue buffers plus fixed triangle enqueue | 128 | 1175567 | 1652654 | Rejected: slower |
| Cached fixed triangle enqueue | 32 | 331717 | 485513 | Rejected: hardware-suite stall |
| Cached fixed triangle enqueue | 64 | 568023 | 829072 | Rejected: hardware-suite stall |
| Cached fixed triangle enqueue | 128 | 1041514 | 1520791 | Rejected: hardware-suite stall |
| Compact range-checked vertex conversion | 32 | 345658 | 499751 | Retained |
| Compact range-checked vertex conversion | 64 | 596960 | 859454 | Retained |
| Compact range-checked vertex conversion | 128 | 1099986 | 1578935 | Retained |
| 256-word cached queue buffers | 32 | 338154 | 484102 | Superseded by final queue layout |
| 256-word cached queue buffers | 64 | 577978 | 835642 | Superseded by final queue layout |
| 256-word cached queue buffers | 128 | 1064293 | 1538524 | Superseded by final queue layout |
| 128-word cached queue buffers | 32 | 335657 | 481908 | Superseded by final queue layout |
| 128-word cached queue buffers | 64 | 578363 | 832565 | Superseded by final queue layout |
| 128-word cached queue buffers | 128 | 1063473 | 1536060 | Superseded by final queue layout |
| Inline typed command wrapper | 32 | 330892 | 477398 | Retained |
| Inline typed command wrapper | 64 | 568624 | 823765 | Retained |
| Inline typed command wrapper | 128 | 1044190 | 1518194 | Retained |
| 256-byte-aligned 128-word buffers | 32 | 330935 | 477194 | Superseded; alignment invariant retained |
| 256-byte-aligned 128-word buffers | 64 | 568903 | 823721 | Superseded; alignment invariant retained |
| 256-byte-aligned 128-word buffers | 128 | 1044621 | 1518138 | Superseded; alignment invariant retained |
| Whole-triangle reservation after alignment fix | 32 | 332652 | 478488 | Rejected: slower |
| Whole-triangle reservation after alignment fix | 64 | 570629 | 826114 | Rejected: slower |
| Whole-triangle reservation after alignment fix | 128 | 1049811 | 1524002 | Rejected: slower |
| Direct one-word overlay commands | 32 | 148842 | 294925 | Retained |
| Direct one-word overlay commands | 64 | 250914 | 505599 | Retained |
| Direct one-word overlay commands | 128 | 455534 | 927732 | Retained |
| Native two-triangle quad command | 32 | 102509 | 249606 | Superseded by compatible batching |
| Native two-triangle quad command | 64 | 160325 | 415637 | Superseded by compatible batching |
| Native two-triangle quad command | 128 | 273722 | 748311 | Superseded by compatible batching |
| No-op RDP-buffer reattachment | 32 | 63740 | 210958 | Rejected: latent RDP-state corruption |
| No-op RDP-buffer reattachment | 64 | 132560 | 373857 | Rejected: latent RDP-state corruption |
| No-op RDP-buffer reattachment | 128 | 257162 | 693326 | Rejected: latent RDP-state corruption |
| Safe repeated-buffer cache-invalidation elision | 32 | 59144 | 208421 | Retained |
| Safe repeated-buffer cache-invalidation elision | 64 | 118095 | 372698 | Retained |
| Safe repeated-buffer cache-invalidation elision | 128 | 223187 | 695902 | Retained |
| Fetch-window-only streaming reset | 32 | 47723 | 196507 | Retained |
| Fetch-window-only streaming reset | 64 | 94881 | 350223 | Retained |
| Fetch-window-only streaming reset | 128 | 179638 | 652449 | Retained |
| Guard-cache-line-only streaming reset | 32 | 44857 | 193720 | Rejected: hardware-suite completion timeout |
| Guard-cache-line-only streaming reset | 64 | 89206 | 344277 | Rejected: hardware-suite completion timeout |
| Guard-cache-line-only streaming reset | 128 | 169042 | 641969 | Rejected: hardware-suite completion timeout |

Writing resident queue buffers through uncached KSEG1 addresses avoided cache
writeback at rollover but made the hot per-word stores expensive enough to
regress submission by roughly 2%. Cached fixed-size enqueueing reserved all 22
words of a native textured triangle once and improved 128-star submission by
9.3%. Replacing the `floorf`/`fminf`/`fmaxf` conversion chains with compact
range checks improved 128-star submission by 4.2% in the retained build. The
first faster builds appeared to stop after `ZSP: RDP triangle data`; this was
partly a separate SC64 debug-backend defect, which could overwrite its shared
buffer before the prior USB transfer completed and then wait forever. Bounded
readiness checks fixed conversion-only runs, which now pass 65/65 hardware
tests. Fixed triangle enqueue still reproduces the stall even with corrected
debug backpressure, so it remains reverted pending dedicated rollover coverage.

Reducing each cached resident queue buffer from 512 to 256 words publishes work
to the RSP earlier and improved 128-star total time by another 2.6%. A 128-word
buffer was marginally better again, especially at 32 stars, while still fitting
the 63-word maximum command and rollover epilogue. It passes the queue rollover
tests and the full 65-test hardware suite. The 128-star post-submit tail is now
472587 ticks, versus 478949 ticks with conversion alone, so publication cadence
helps overlap but does not explain most of the remaining RSP/RDP gap.

Inlining the trusted typed overlay wrapper removes one CPU call layer without
changing command validation, ordering, capacity checks, or rollover boundaries.
It improves 128-star submission by a further 1.8% and passes 65/65 hardware
tests. Inlining command-ID validation was 0.2% slower and was reverted. A fixed
seven-word vertex writer reproduced the same later suite stall as whole-triangle
batching and was also reverted; specialized stores therefore remain blocked on
isolating the code-layout-sensitive corruption rather than packet correctness.

The apparent specialized-writer corruption was ultimately a resident-fetch
storage invariant: queue buffers were only 8-byte aligned even though the RSP
always DMAs a complete 256-byte command window. Small code changes moved the
buffers and could make a later fetch observe adjacent data as commands. Aligning
each buffer to the fetch-window boundary makes the normal verbose 65-test suite
pass and is performance-neutral. Retrying whole-triangle reservation with that
fix was safe but 0.5% slower at 128 stars, so the batching change remains
rejected on performance grounds.

After reverting all three experiments, a repeat baseline measured 356108,
620049, and 1147964 submission ticks and 509332, 882150, and 1627274 total
ticks at 32, 64, and 128 stars respectively, within 0.03% of the original run.

## Final result

The dominant CPU defect was not fixed-point conversion but the generic raw
packet path used by one-word typed commands. Every primitive-color update was
copied through a 22-word accumulator and then searched through overlay command
metadata. Direct emission through the already validated typed ABI reduced
128-star submission from 1,044,621 to 455,534 ticks by itself.

Rotated sprites now upload four unique vertices instead of six. They submit the
first triangle, replace one vertex, and submit the second triangle with
alternate state-slot indices. Each remains an independently terminated TRI_TEX
RDP primitive. Attempts to defer the first triangle's RDP-buffer publication
were rejected because later hardware tests exposed latent RDP-state corruption.
The retained alternate-slot encoding uses a private high bit of the existing
triangle command, so reserved overlay command slots retain their prior behavior.

Reconstructing a render-state wrapper still performs the proven DMEM and DP
reattachment sequence. When the authoritative resident addresses show that the
same buffers remain RSP-owned, it now skips only the redundant 128 KiB cache
invalidation. `releaseRdpToDirect` waits for the resident dispatcher to halt
before changing ownership. The standard mode defaults also match libdragon:
dithering disabled and coverage forced full.

The final queue uses a 320-word stride, a multiple of the RSP's 256-byte fetch
window. On rollover, it clears and writes back the alternate buffer's first
complete fetch window. Clearing only its leading invalid guard benchmarked
faster, but the full 65-test ROM printed 64 passes and then timed out before the
final test and completion marker, so that experiment was rejected. The
completed range of the published buffer is the only part written back. The
retained, fetch-window-safe reset still removes nearly all prior rollover memory
traffic.

| Stars | Libptero submit | Libdragon submit | Difference | Libptero total | Libdragon total | Difference |
|---:|---:|---:|---:|---:|---:|---:|
| 32 | 50,734 | 113,703 | -55.4% | 167,826 | 193,820 | -13.4% |
| 64 | 101,714 | 233,078 | -56.4% | 280,947 | 326,744 | -14.0% |
| 128 | 193,434 | 464,017 | -58.3% | 506,894 | 609,855 | -16.9% |

Submission and total completion are faster than the pinned libdragon reference
at every size. Libptero completes 13.4% faster at 32 stars, 14.0% faster at 64,
and 16.9% faster at 128. The generated triangle core is 279 instructions versus 282 in the pinned
hand-scheduled reference, and temporary hardware instrumentation confirmed only
one overlay load for the full run. Before the retained scheduling change,
temporary split timing measured the RSP queue complete at about 171,000 ticks
in the 128-star case, far ahead of the roughly 650,000-tick RDP fence. That
diagnosis identified complete-prefix visibility as the remaining lever. All
profiling instrumentation was removed before the measurements above; the
benchmark's CP0 reads, workload, and timing boundaries were not changed.

## RDP-consumption investigation

Temporary instrumentation decoded the completed dynamic RDP streams, reset and
read the four DPC performance counters around each frame, and hashed the complete
RGBA16 framebuffer after the full-sync fence. The instrumentation was absent
from the authoritative timing run above. It found:

| Stars | Implementation | RDP commands | Command bytes | TRI_TEX | Primitive color | Sync load/pipe/tile/full |
|---:|:---|---:|---:|---:|---:|:---|
| 32 | libptero | 117 | 6,568 | 64 | 32 | 2 / 2 / 1 / 1 |
| 32 | libdragon | 127 | 6,648 | 64 | 32 | 0 / 1 / 0 / 2 |
| 64 | libptero | 213 | 12,968 | 128 | 64 | 2 / 2 / 1 / 1 |
| 64 | libdragon | 223 | 13,048 | 128 | 64 | 0 / 1 / 0 / 2 |
| 128 | libptero | 405 | 25,768 | 256 | 128 | 2 / 2 / 1 / 1 |
| 128 | libdragon | 415 | 25,848 | 256 | 128 | 0 / 1 / 0 / 2 |

Libdragon therefore submits ten extra fixed commands and 80 extra fixed bytes;
the difference does not grow with the star count. Every per-star primitive is
identical: hashes over all 96-byte TRI_TEX packets were respectively
`6d5e88523b381925`, `426d2472f973d725`, and `d8c13ab6d83a7b25` for both ROMs.
The combiner was corrected to multiply both color and alpha by primitive color,
matching libdragon's `fc119623882fffff` command. Framebuffer hashes then also
matched exactly (`830b2ba6d324c5a6`, `2baef214021e843b`, and
`830b2ba6d324c5a6`). The prior alpha-passthrough formula happened not to affect
the timing materially, but it was not a pixel-identical comparison.

The RSP send paths establish the publication cadence without changing the timed
workload. Both wait for each triangle's 96-byte DMA and then write `DP_END`;
each primitive-color command is a separate 8-byte publication. Thus both have
the same scaling term of three publications per star (one 8-byte color and two
96-byte triangles). Libptero's raw overlay path also publishes each fixed RDP
packet separately, giving 117, 213, and 405 packet publications. Libdragon can
coalesce a few fixed setup commands in one staging send, but its difference is
constant and it performs no fewer per-star publications. Its triangle routine
also writes the already-current end pointer before the next DMA, an idempotent
write that does not expose additional command bytes.

Low-perturbation counter runs gave the following averages. Profiling changes
code and allocation layout, so these diagnose the hardware phase rather than
replace the clean timings above.

| Stars | Implementation | DP clock | Command busy | Pipe busy | TMEM busy |
|---:|:---|---:|---:|---:|---:|
| 32 | libptero | 272,390 | 193,671 | 269,660 | 1,742 |
| 32 | libdragon | 253,008 | 229,394 | 230,697 | 2,306 |
| 64 | libptero | 480,039 | 337,943 | 477,328 | 1,737 |
| 64 | libdragon | 426,034 | 410,126 | 411,417 | 2,294 |
| 128 | libptero | 892,970 | 627,322 | 890,249 | 1,745 |
| 128 | libdragon | 790,687 | 767,429 | 768,721 | 2,292 |

The original interpretation that a greater-than-99% PIPE_BUSY ratio ruled out
starvation was too strong. Later submission-boundary and direct-replay counters
showed that PIPE_BUSY remains asserted while an incrementally exposed stream is
waiting for more command bytes. Libptero's much lower command-busy count was the
important signal. TMEM busy is small and constant. Clearing the final unused
second-cycle blender bit
made the complete Other Modes word identical (`ef000cf000404240`) without a
speedup, ruling out the remaining mode-word difference. A later controlled
placement sweep (below) showed that the apparent framebuffer-address effect in
these differently instrumented ROMs was code-layout noise rather than a
reproducible RDRAM effect.

The evidence rules out extra per-star commands, different triangle geometry,
different rendered pixels, and TMEM loading. The remaining end-to-end
difference is low-level command-buffer visibility and overlap, not intrinsically
slower rasterization of the triangle bytes. It is not CPU submission work that can be
closed by removing benchmark measurements; both clean ROMs retain the original
warmups, eight samples, workload, and timing boundaries.

## Follow-up placement and scheduling experiments

A controlled benchmark linker placed libptero's two dynamic command buffers,
framebuffer, and texture at the exact physical addresses printed by the pinned
libdragon diagnostic ROM: `0x74320`, `0x84340`, `0x94380`, and `0xb9bc0`.
Libptero still measured 196623, 350181, and 652472 total ticks, versus 192514,
325240, and 606823 for that libdragon layout run. Exact placement therefore did
not close the scaling gap. The temporary linker and address instrumentation were
removed after the experiment.

Dynamic-buffer alignment sweeps likewise produced indistinguishable RDP
counters:

| Alignment | Dynamic buffers | Framebuffer | 128-star total | DP clock | Pipe busy |
|---:|:---|:---|---:|---:|---:|
| 4 KiB | `0x10000`, `0x20000` | `0x30100` | 652667 | 870231 | 868123 |
| 32 KiB | `0x18000`, `0x28000` | `0x38100` | 652637 | 870192 | 868081 |
| 64 KiB | `0x20000`, `0x30000` | `0x40100` | 652616 | 870163 | 868063 |

Moving only the framebuffer from `0x40100` to `0x60000` changed the 128-star
DP clock from 870163 to 870717, within run/layout noise.

Hardware rejected every publication-cadence variant:

| Experiment | 32-star total | 64-star total | 128-star total | Result |
|:---|---:|---:|---:|:---|
| Publish both triangles together | 196817 | 350753 | 653362 | Rejected: slower |
| Flush fixed clear setup early | 197194 | 352085 | 655086 | Rejected: slower |
| Add ten fixed no-ops to match stream offset | 198804 | 351705 | 654653 | Rejected: slower |
| One pre-load pipe sync, matching libdragon order | 196279 | 350432 | 653266 | Rejected: slower |
| Flush after first complete star | 198365 | 352530 | 657640 | Rejected: slower |
| Resident 200-byte threshold | -- | -- | -- | Rejected: streaming deadlock |
| Explicit one-star visibility window | 208657 | 369933 | 690724 | Rejected: no DPC reduction; instrumented layout |
| Explicit eight-star visibility window | 210175 | 369553 | 691185 | Rejected: no DPC reduction; instrumented layout |
| 256-word resident stride | 203381 | 366132 | 684417 | Rejected: slower |
| 384-word resident stride | 221638 | 392785 | 735507 | Rejected: slower |
| 448-word resident stride | 196406 | 350370 | 650523 | Rejected: no uniform gain |
| 512-word resident stride | 200256 | 349924 | 648503 | Rejected: small-frame regression |
| 576-word resident stride | 201416 | 350516 | 647237 | Rejected: small-frame regression |
| 640-word resident stride | 200041 | 351108 | 652026 | Rejected: slower |
| 768-word resident stride | 202803 | 356849 | 654568 | Rejected: slower |
| 576-word stride, first flush at 320 | 204090 | 361059 | 673333 | Rejected: slower |
| 100-cycle pacing after each star | 200031 | 356863 | 665679 | Rejected: slower |
| RSP-side 32-iteration publication delay | 197787 | 351173 | 652826 | Rejected: slower |
| Rollover-safe 200-byte star publication | 197841 | 351973 | 655811 | Rejected: slower |
| Cached open queue, publish every star | 207061 | 372374 | 700823 | Rejected: cache traffic dominates |
| Cached open queue, 128-word threshold | 207278 | 373046 | 701571 | Rejected: slower |
| Cached open queue, 256-word threshold | 199689 | 355437 | 664054 | Rejected: slower |
| One-triangle look-behind publication | 167826 | 280947 | 506894 | Retained: faster than libdragon |

The full 200-byte primitive-color-plus-two-triangles design was also evaluated.
Making it rollover-safe requires checking 200 bytes of capacity before the first
DMA, preserving the old-buffer publication when a rollover is required, and
carrying batch state through both triangle handlers. Initially that path exceeded
the RDP overlay's fixed 4 KiB IMEM budget by 60 bytes. Aliasing four command
entries directly to their existing handlers and removing a redundant batch-bit
mask recovered enough IMEM without splitting the overlay. A two-count resident
publication state then let the primitive-color send reserve the complete range,
let both triangle DMAs advance the private write cursor, and expose the range
only after the second DMA. It fit with 68 instruction bytes free and the full
65-test physical ROM passed, but clean totals regressed to 197841, 351973, and
655811 ticks. The batching state and its temporary IMEM compaction were therefore
removed. A smaller two-triangle-only
implementation was also slower, so no publication batching is retained.

Libdragon uses 512-word low-priority resident command buffers, versus the
retained libptero 320-word buffers. Sweeping through 448, 512, 576, 640, and
768 words showed that fewer handoffs can improve the 128-star case slightly;
576 words reached 647237 ticks. It simultaneously regressed 32 stars to 201416
because the first useful queue launch moved later. A hybrid 576-word buffer
forced to launch first at the original 320-word threshold was slower at every
size. Short CPU pacing after each star also regressed every total. Queue-buffer
handoff frequency therefore contributes a few thousand ticks but is not the
scaling term, and the uniform 320-word stride remains the best compromise.

A temporary direct-replay diagnostic waited for the resident RSP queue after
each authoritative sample group, then submitted the exact completed libptero
dynamic buffer directly through DPC. It did not rebuild, split, or otherwise
change the overlay. The replay consumed 6,568, 12,968, and 25,768 bytes and
completed in 145386, 251496, and 469536 ticks. The corresponding normal
post-submission intervals were 148947, 255526, and 473308 ticks. Bypassing the
resident command dispatcher therefore saved only 3--4 thousand CPU ticks after
the submission boundary. Counter resets around the 128-star replay exposed the
larger hardware distinction: one-shot replay used about 625990 DP clock and
625843 PIPE_BUSY cycles, versus about 871406 and 869343 for incremental
submission of the same bytes. Thus the post-submission CPU intervals alone hide
work already overlapped before submission, while PIPE_BUSY includes incremental
visibility stalls.

Matched phase-counter instrumentation confirmed the overlap difference. At the
CPU submission boundary libptero had accumulated 238504 of its final 869343
PIPE_BUSY cycles (27%), while libdragon had accumulated 453888 of 770794 (59%).
At 64 stars the corresponding pairs were 125257/466022 and 224915/412583; at
32 they were 62338/260844 and 96973/230530. The exact completed stream is fast
when exposed as one DPC range, but safe resident hold/flush prototypes spanning
one or eight stars did not reduce the counters, and a generic 200-byte threshold
deadlocked. All replay, phase-counter, and hold/flush instrumentation was removed.

The retained scheduling change uses the triangle generator's existing early,
idempotent `DP_END` update deliberately. At the start of an overlay batch,
ordinary append operations advance the private RDRAM cursor without updating
`DP_END`. The first triangle exposes the completed fixed setup; every later
triangle exposes the preceding completed triangle and any intervening color
command. The full-sync handler clears the hold before sending its own packet,
so the last triangle and sync become visible together. `OverlayQueue.execute`
also emits an explicit release when no full sync is present, preserving its
existing public semantics. Buffer rollover publishes the completed old buffer
before ownership switches and begins the same look-behind schedule in the new
buffer. The RDP byte stream and ordering are unchanged; only complete-prefix
visibility timing changes.

Platform-state comparisons also found identical RDRAM chip delay and RAS
registers and identical VI timing, scaling, and filter status. Libdragon's VI
scanout origin differed because `display_init` owns display buffers; temporarily
matching that origin changed the 128-star result by less than 0.1%. `RI_CONFIG`
read back differently between the two IPL3 implementations, but matching it at
runtime had no timing effect. A changing bit in `RI_REFRESH` was live readback
state rather than a stable configuration difference; forcing it caused memory
corruption and was rejected. No platform register override was retained.

A complete fixed-command dump found one additional state difference: libdragon
sets S/T clamp bits on its load and render tiles while libptero leaves them
clear. Temporarily matching `0x80200` in both tile descriptors preserved output
but measured 654648 ticks at 128 stars, so it was rejected. The remaining fixed
differences are extra libdragon attachment/detachment, mode, image, and sync
commands; adding padding commands also regressed. With identical triangle
packets, combiner, final modes, framebuffer checksum, and physical placement,
the retained one-triangle look-behind schedule closes the prior gap and beats
libdragon without splitting or replacing the overlay. Deleting measurements or
changing the raster workload was never part of the optimization.
