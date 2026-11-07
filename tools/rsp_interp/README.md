# rsp-interp

`rsp-interp` is a host-side interpreter for the N64 RSP. It runs packed `.rsp`
programs (the `rsp_pack` output used by `AssetBundle`) so microcode behavior can
be tested without hardware and code generation can be compared by estimated
cycle count.

It replaces byte-for-byte comparison with libdragon/Tiny3D as ZSP's safety net:
changed microcode must reproduce the outputs pinned by the host workloads
(`src/tests/microcode/`), pass the hardware tests, and stay within the cycle
tolerance of the recorded baseline.

## Library

| File | Responsibility |
| --- | --- |
| `Machine.zig` | Architectural state, delay slots, `step`/`run`, program loading |
| `scalar.zig`, `cop0.zig` | Scalar ISA; SP DMA/status and RDP command registers |
| `dma.zig` | DMA queue, calibrated transfer costs, and hazard detection |
| `vu_*.zig`, `vector*.zig` | Vector unit: compute ops, divide unit, loads/stores |
| `timing.zig` | Dual-issue/stall cycle estimate, calibrated on hardware |
| `Profile.zig` | Per-instruction costs attributed to IMEM symbols |
| `Session.zig` | Drives the resident dispatcher and overlays like the CPU runtime |
| `calibration.zig` | Timing microbenchmarks shared with the test ROM |
| `encode.zig` | Instruction encoders for test programs |

Run a standalone program:

```zig
const interp = @import("rsp_interp");

var rdram: [1 << 20]u8 = @splat(0);
var machine = interp.Machine.init(&rdram);
machine.load(interp.Program.fromBlob(blob));
machine.start(machine.pc);
const result = try machine.run(100_000);
// result.stop: .broke, .halted, or .instruction_limit
// result.instructions, result.cycles (estimate)
```

Run command streams through the real resident dispatcher:

```zig
var session = interp.Session.init(rdram, resident_program, .{ ... resident symbols ... });
const overlay = try session.registerOverlay(overlay_program, id);
var queue = try session.commands(256);
try queue.overlayCommand(overlay, 3, inline_argument, &.{argument});
_ = try session.submit(queue.address, limit);
```

Session RDRAM addresses are offsets into the machine's RDRAM slice. Overlay
registration uses the runtime's `overlay_layout.zig`, so the dispatcher sees
the same descriptor blocks it does on hardware. `submit` returns
`DispatcherFault` when the dispatcher rejects a command.

Set `machine.rdp_output` to capture RDP command bytes submitted through
DP_START/DP_END, from DMEM (XBUS) or RDRAM. Set `machine.profile` to collect
per-instruction costs; `Profile.attribute` groups them by symbol, using the
`zsp_imem_symbols` table that `rsp_pack --symbols` emits.

## CLI

```text
rsp-interp <program.rsp> [--limit <instructions>] [--rdram-size <bytes>]
                         [--dmem-out <file>] [--rdp-out <file>]
```

It prints the stop reason, final PC, retired instructions, estimated cycles,
and captured RDP bytes.

## Fidelity

- **Scalar unit:** full RSP subset with delay slots. ADD/ADDI/SUB do not trap.
  64-bit, multiply/divide, and likely-branch encodings raise
  `InvalidInstruction`.
- **Vector unit:** every computational op, the 48-bit accumulator,
  VCO/VCC/VCE, VRCP/VRSQ tables with double-precision sequencing, and every
  LWC2/SWC2 form. Semantics follow ares (hardware-validated). LWV is rejected.
  The standalone ZSP programs' hardware expectations, the VADPCM reference
  decoder, and the hardware test ROM cross-check this.
- **COP0:** SP DMA (count/skip, DMEM/IMEM) queues like hardware: one
  transfer in flight and one pending, each finishing a calibrated number of
  cycles after it starts (`dma.zig`, fitted to the `dma_*` benchmarks).
  DMA busy/full reflect the queue, so wait loops cost what they cost on the
  console. Bytes move when a transfer completes, in issue order; a halt or
  break completes the rest, as the CPU would observe. SP_STATUS pairs,
  signals, the semaphore, and BREAK interrupts are modeled. DPC_CLOCK reads
  the estimated cycle count.
- **DMA hazards:** a load, store, or instruction fetch that touches RSP
  memory an unfinished transfer fills, or a store to memory one is still
  reading, stops the run with `error.DmaHazard`; `Machine.hazard` records the
  PC, address, and transfer direction. Starting a third transfer while two
  are queued returns `error.DmaQueueFull`. The check is conservative: it
  treats a transfer's whole range as busy until it completes.
- **RDP:** always ready. Commands are captured at DP_END, not rasterized.

## Timing

`timing.zig` models:

- scalar/vector dual issue (never across a branch/delay-slot pair);
- result latencies: 3 for scalar loads and COP moves, 4 for vector ops and
  vector loads;
- one cycle for VCO/VCC/VCE flags to reach CFC2;
- a stall when a store issues two cycles after a load;
- a bubble per taken branch.

`resultLatency(producer, consumer)` gives the cycles between two
instructions when the second reads the first's result. ZSP's scheduler uses
it for critical-path priorities and scores whole candidate orders with
`Pipeline`, so improving the model improves scheduling.

`calibration.zig` holds 37 microbenchmarks that time themselves with
DPC_CLOCK. The test ROM runs them on the console and prints the cycle counts,
which are recorded in `calibration.zig`. The host test fails if the model
drifts more than 10% from them, and lists every drifting benchmark first.

Entries with a `model_gap` are reported but do not fail the test. Two gaps
are documented:

- back-to-back VADDC→CFC2 chains stall two cycles per pair more than
  modeled;
- a store waiting for one of two just-issued vector results delays the next
  instruction more than modeled (`add_pair_then_store_pair`,
  `add_pair_then_one_store`, `mac_then_store`). The other store benchmarks
  pin down the cases that do match. No simple rule fit all of them without
  mis-estimating the shipped workloads. This gap costs the plain matrix
  multiply in `src/tests/ucode/matrix_kernels.zsp` one cycle against the
  hand-scheduled version.

To recalibrate after changing the model or adding a benchmark, run the hardware
tests (see `AGENTS.md`), copy the printed
`RSP calibration: microbenchmark cycles` values into `measured`, and rerun
`zig build test`.

## Known gaps

- RDP timing is not modeled. DMA costs ignore RDRAM contention with the CPU
  and RDP, so on a busy console transfers take longer than estimated.
- Profiles key costs by IMEM address only. When overlays or the clipping
  payload swap code at the same addresses, attribution uses the symbols the
  caller supplies for that range.
- Branches inside delay slots and other undefined sequences are not emulated
  specially. LTV/STV register dependencies are approximated by their base
  register in the timing model.
