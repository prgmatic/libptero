# Emergency crash screen

Zig panics and unhandled CPU exceptions display the same 640×240 RGBA5551 UI.
It uses CPU writes, cache writeback and direct VI presentation; it submits no
RSP/RDP commands and does not wait for graphics completion. Fixed BSS storage
reserves a 307,200-byte framebuffer and a bounded report of up to 20 frames.
No allocator is used. Source-map results are copied before entering the input loop.

L/R switch main tabs; the screen labels these controls LB/RB. The D-pad scrolls
Stack Trace in both directions and Registers vertically, with delayed repeat
while held. Registers has a fixed heading and two columns of 64-bit GPRs.
The D-pad icon doubles its bitmap columns so it appears square at 4:3.
Only Stack Trace has a horizontal scrollbar. Memory has neither scrollbar.
Controller polling uses bounded SI waits with interrupts disabled. An absent
controller leaves the display intact. Reset the console to restart execution.

Stack Trace displays functions, addresses, locations, source text and fault
columns when the ROM contains a source map. Registers displays the saved 64-bit
GPRs for CPU exceptions. System groups Code/EPC/Cause/Status/BadVAddr beside
FCSR, all six decoded FPU cause flags, and HI/LO. A Zig panic has no exception
register snapshot; its System page shows the panic origin, frame count and
available memory-bank sizes instead.

Vertical padding is kept small because the 640×240 framebuffer stretches to
4:3 on the display. The content viewport is 148 native rows tall; stack frames
use 51 rows with source text or 31 without. Registers shows eight rows at once.

## Memory inspection

C-left/right switch RDRAM, Cart, DMEM and IMEM sub-tabs. Each bank remembers its
own address. D-pad up/down moves one 16-byte row; left/right moves an 80-byte
page. The display includes one preceding context row when possible, printable
ASCII beside grouped hex bytes, and highlights the fault instruction in RDRAM.
The final page stops at the bank boundary rather than reading unrelated MMIO.

Press A to edit the address inline. D-pad left/right selects one of eight hex
digits; up/down changes it. A applies a valid address, B cancels. Invalid addresses
remain in the editor with an `Outside bank` indicator. Switching bank or main tab
cancels an unfinished edit without changing the stored address.

RDRAM reads use the uncached alias and do not flush application data. Both KSEG0
and KSEG1 addresses are accepted within detected 4/8 MiB RDRAM. Standard runtime
startup saves the IPL3 memory-size word from SP DMEM before application code can
reuse it; custom entry points should call `memory.initBootBounds()` after BSS
clearing and before SP initialization. Without this call, the bound is 4 MiB.

Cart views the 64 MiB ROM window at `0xb0000000`; this is the hardware address
window, not the packed ROM's file size. Reads use the existing PI transfer API
and fixed aligned storage, with bounded waits. A busy or failed PI read displays
a status message. The viewer does not steal an application's transfer or reset
PI; its own timed-out transfer retains its buffer until completion.

DMEM and IMEM use word-sized CPU reads of their respective 4 KiB regions at
`0xa4000000` and `0xa4001000`. Inspection does not submit work, halt RSP, or wait
for RSP/RDP. Live memory snapshots are best effort if hardware is still writing.
Inspection writes no viewed memory; only the viewer's private PI destination and
framebuffer are modified. Snapshots refresh on navigation and are held stable
while editing an address.

`n64.debug.crash_screen` exposes `Report`, `State`, `model`, `font` and `ui` for
the dummy example and host previews. `ui.render(image, &report, state)` requires
a 640×240 image and valid bounded report lengths. Runtime `show`/`showException`
disable interrupts and present the first frame; `waitForInput` never returns.

Exception decoding lives in `../exception_codes.zig`, based on libdragon's
R4300 table. All 32 Cause codes decode safely, including reserved values.
Descriptions refine address faults, coprocessor numbers, divide traps, emulator
faults and FPU causes. Branch-delay exceptions use EPC+4. Instruction reads are
guarded by the executable text bounds. Libdragon-specific TLS and GCC pattern
heuristics are not applicable to this runtime.

Crash text uses heavy proportional Adwaita Sans baked as static one-bit glyphs,
with baseline-relative metrics. Proportional masks are thresholded from the
grayscale master, trimmed and spaced by their ink width with a one-pixel gap.
The bake adds one horizontal ink column for TV readability; the Memory byte
table uses compact bold Adwaita Mono
to retain all 16 hex/ASCII bytes. Glyphs retain their native aspect;
the 640×240 framebuffer fills the TV's 4:3 display. Regenerate the assets with
`python3 tools/crash_screen_fonts.py` at the core root (Pillow required).
See [font license](LICENSE.txt). Text supports printable ASCII and four-space
tabs; other bytes render as `?`.

Host tests cover decoding, clipping, bank bounds, editing, navigation, repeat and
scrollbar endpoints. Hardware tests verify RDRAM aliases, cartridge header reads,
SP byte order and bank ends, and preservation of PI transfer ownership:

```sh
zig build test
zig build install tests
zig build crash-screen-smoke
zig build crash-screen-smoke -Dcrash-screen-exception=true
```

The smoke ROM deliberately panics, or raises a breakpoint with distinct HI/LO
patterns. It remains halted until reset. Framebuffer capture is opt-in through
the existing diagnostics workflow; the crash handler never captures automatically.
