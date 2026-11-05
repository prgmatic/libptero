# RSP microcode workloads and baseline

These host tests run every shipped RSP program through the resident command
dispatcher in the RSP interpreter (`tools/rsp_interp`). Command streams use
the runtime's own encoders and layouts where they are pure:

- `CommandEncoder`, `overlayPacket`
- `GeometryEncoder`'s command builders, `clippingPatch`
- `overlay_layout`
- `Mixer.frequencyStep`

| Workload | Exercises |
| --- | --- |
| `dispatcher` | DMEM writes, call/return, jump, DMA, status writes, swap buffers |
| `rdp_state` | Mode stack, combiner/blend/fog, fixups, AutoTMEM, passthrough triangles, rectangles, Z clear |
| `rdp` | RDP buffers, fills, scissor, native triangles, full sync, buffer switch |
| `vadpcm_mono` | 64-block mono decode, checked against the reference decoder |
| `vadpcm_stereo_batches` | Two stereo batches joined by `setState`, checked against the reference |
| `mixer_4voice` | 8-bit, 16-bit, stereo, and resampled voices |
| `geometry_lit_mesh` | Lit, fogged vertices; a 50-triangle strip and an immediate triangle |
| `geometry_clipped_mesh` | The mesh crossing the near plane, with the clipping payload swapped in |

## What the tests enforce

- **Behavior:** the per-workload tests assert specific outcomes, such as
  reference-decoder equality, triangle counts, mixer positions, and mode-stack
  state.
- **Baseline (`baseline.zon`):** each workload's outputs must hash to the
  recorded digest. Outputs include RDP bytes, RDRAM results, and selected DMEM.
  Estimated cycles must not exceed the recorded value by more than
  `tolerance_percent` (2%).
- **Coverage (`coverage.zig`):** every command handler of every shipped
  program must run in some workload. The only exemptions are in `exemptions`:
  geometry `drawTriangleSequence`, which has no runtime caller, and
  `patchCode`, which is covered by hardware tests.

## Workflow

```sh
(cd core && zig build test)            # behavior, digests, cycles, coverage
(cd core && zig build rsp-baseline)    # table: sizes, cycles vs baseline, hottest functions
(cd core && zig build rsp-baseline -- --update)   # record a new baseline
```

Update the baseline only when the change is intended:

- **Faster code:** record it so the gate tightens.
- **Deliberately changed outputs:** explain why in the commit.

An unexpected `output_changed` is a behavior regression. Also run the hardware
tests: they check the interpreter's assumptions on the real console.

To add a workload, append it to a `*_workloads.zig` `all` list with its
`overlay` and `symbols`, give it a behavior test, then record the baseline.
