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
