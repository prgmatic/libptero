# ZSP

ZSP is the in-repository RSP transpiler. It translates `.zsp` source files to
GNU-style MIPS/RSP assembly, which can then be assembled into RSP microcode.

## Language layers

ZSP keeps three concerns visibly separate:

- Core ZSP expresses values, functions, control flow, memory, and modules.
- The `rsp.*` namespace exposes machine facilities. CP0 operations live under
  `rsp.cp0.*`, vector transfers and control registers under `rsp.vector.*`, and
  terminal operations such as `rsp.halt()` directly under `rsp`.
- The `@rspq.*` namespace supplies queue-framework metadata. Command handlers,
  encoded sizes, and command tables use `@rspq.command`,
  `@rspq.commandSize`, and `@rspq.commandTable`.

Start with core ZSP. Reach into `rsp.*` only when code communicates with the
machine, and use `@rspq.*` only when declaring integration with the queue
framework. The low-level `slot` and `exact` constructs are escape hatches for
machine placement and exact instruction order; they are not routine
optimization hints.

## Compiler stages

The parser produces the source AST. `rspq.zig` owns the framework-specific
semantic stage by resolving the command-table declaration and validating command indices, encoded
sizes, and parameter ABI bindings. Its `CommandAnalysis` is the invariant the
assembly writer consumes for command-table layout and manifest serialization;
the writer no longer rediscovers or validates those facts.

Name and call resolution, writes inference, control-flow/lifetime analysis,
register allocation, instruction selection, and function placement remain in
`asm_writer.zig`. They will be extracted incrementally while preserving output.

The current post-parse dependency map is:

- `rspq.analyzeCommands` validates command metadata and produces
  `CommandAnalysis`.
- `FunctionClobberRegistry.init` combines call/write analysis with the current
  lifetime and allocation simulation.
- `FunctionContext.prepareLifetimes` builds statement-position control flow and
  live ranges; `bindParameters` and the allocation helpers select registers.
- `writeFunction` and `writeStatements` perform placement, instruction
  selection, and direct assembly printing; `asm_optimizer.zig` then optimizes
  assembly text.

Command behavior and output coverage lives in the command-focused cases in
`tests.zig`; `rspq.zig` additionally tests normalized metadata and semantic
errors without depending on assembly text.

This document describes the language implemented in this repository.

## Building and running

```sh
zig build-exe tools/zsp/zsp.zig -femit-bin=/tmp/zsp
/tmp/zsp input.zsp output.s
zig cc -target mips-freestanding-none -c output.s -o output.o
```

The command-line syntax is:

```text
zsp <input.zsp> [--module-dir <dir>] [--module-file <name> <file>]
    [--depfile <file>] [--interface <file>] [--no-optimize] [--report] [output.s]
zsp explain <input.zsp> [--module-dir <dir>]
    [--module-file <name> <file>] [--no-optimize]
```

Assembly is written to standard output when `output.s` is omitted. Imports are
resolved relative to the importing file, then relative to `--module-dir`.
`--depfile` writes a Make-compatible dependency file containing every loaded
module. Optimization is enabled by default; `--no-optimize` preserves the
direct emitter output. `--interface` writes declarations for public exports,
and `--report` prints a compact function/instruction/IMEM summary.

## Types and literals

The scalar types are `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, and `dmem`. Every scalar
still occupies one 32-bit RSP general-purpose register. The declared width is a
type and memory contract, not an instruction inserted after every operation:

- loads extend from the requested memory width (`u8`/`u16` zero-extend and
  `i8`/`i16` sign-extend);
- stores write the low 8, 16, or 32 bits selected by the store type;
- signedness selects ordered comparisons and arithmetic right shift behavior;
- register-to-register arithmetic requires matching declared types; and
- arithmetic runs on the full 32-bit register value and does not implicitly
  truncate a narrow result.

Mask explicitly when an algorithm requires modulo-8-bit or modulo-16-bit
register semantics. This keeps width conversions visible in source and avoids
hidden instructions in hand-sized microcode.

The vector types are:

- `vec16`: eight 16-bit lanes in one 128-bit vector register.
- `vec32`: eight 16.16 fixed-point lanes in two adjacent vector registers. The
  named register holds the integer halves and the following register holds the
  fractional halves.

Decimal and hexadecimal integer literals are supported. `_` and `'` may be
used as digit separators, and a leading `-` is accepted.

```zig
const mask: u32 = 0xff00_ff00;
reg signed_value: i32 = -32;
```

## Register variables and constants

Register variables use `reg`, optionally pinned to a hardware register:

```zig
reg count: u32 = 0;
reg($t0) status: u32 = undefined;
reg inferred = load(u16, address);
```

`undefined` reserves a register without emitting initialization. A type may be
inferred only from a `load`. Unpinned scalar registers are allocated from
`$t0` through `$t9`, `$k0`, `$sp`, `$fp`, and `$s0` through `$s7`. `$zero`,
`$at`, `$v0`, `$v1`, `$gp`, `$k1`, and `$ra` retain explicit ABI or backend
meaning and are not allocated automatically. `$gp` may still be explicitly
pinned.

Automatic allocation is definition- and control-flow-aware: scalar and vector
registers are reused after their values die along every reachable path. The
analysis follows branches, loops, labels, gotos, nested blocks, and branch delay
slots. A value produced in a call's delay slot is live across the callee, while
a value defined by the callee is not treated as a live input.

Calls prefer to allocate scalar arguments directly in their fixed
calling-convention registers. When a scalar input is already in a different
register, ZSP inserts the required move before the transfer. Values live across
a call avoid the transitive register writes inferred from the call graph, and
automatic callee locals avoid pinned caller locals that must survive the call.
Inline function bodies receive the same lifetime and call analysis while
reserving the caller's live registers.

ZSP does not insert spills or save/restore instructions. Vector arguments and
parameters written by the callee must already use the target parameter's
register. Scalar argument moves are emitted as a parallel assignment, but a
cyclic register permutation currently fails instead of using a temporary
register. If no safe assignment exists under those restrictions, compilation
fails.

External functions can declare their complete register-write contract after
their parameter list:

```zig
extern fn dmaWait(reg($t2) flags: u32) writes($at);
extern fn resumeQueue() writes() noreturn;
```

Both scalar and vector hardware registers are accepted by `writes(...)`.
An external function without a contract is conservatively assumed to write
every register. A live explicitly pinned value that conflicts with an external
contract is a compile error because the allocator cannot move that value or
make the external routine preserve it.

`const` declares a compile-time scalar value. Constants are emitted as
immediates where possible and do not consume registers:

```zig
const dmem_end: dmem = 0x1000;
```

Names may not be duplicated in a visible global or function scope. The old
`var` spelling is not supported.

## Scalar expressions

All scalar types support assignment, arithmetic, shifts, bitwise operations,
and comparisons. Expressions use conventional precedence; parentheses override
it. From strongest to weakest, the binary groups are `* /`, `+ +% - -%`,
`<< >> >>>`, `&`, `^`, and `| ~|`. Operations of equal precedence associate
left-to-right.

```zig
value = left + right;
value = left & mask | bits; // `(left & mask) | bits`
value = left + count << 2;  // `(left + count) << 2`
value += 1;
value +%= 1;       // wrapping addition
value -= amount;
value -%= amount;  // wrapping subtraction
value *= 8;
value /= 4;
value <<= amount;
value >>= amount;  // arithmetic for signed values, logical for unsigned
value >>>= amount; // explicitly logical
value &= mask;
value |= bits;
value ^= bits;
value = left ~| right;
value = ~value;
value = -value;
flag = left < right; // normalized to 0 or 1
```

The corresponding non-compound operators are `+`, `+%`, `-`, `-%`, `*`, `/`,
`<<`, `>>`, `>>>`, `&`, `|`, `^`, and `~|`. Ordinary addition and subtraction
emit trapping RSP instructions; the `%` forms emit wrapping instructions.
Unary `-` likewise emits trapping `sub` for signed types and wrapping `subu`
for unsigned types.

The RSP has no general integer multiply or divide instructions. Scalar `*` and
`/` therefore require a power-of-two constant and lower to shifts. Types must
match when copying or combining register values. `signedLessThan(a, b)` exposes
an explicitly signed scalar comparison as a value.

`==`, `!=`, `<`, `<=`, `>`, and `>=` produce a normalized scalar `0` or `1`.
Signedness for ordered comparisons comes from the operands' scalar type.

## Memory and storage

Scalar and full-vector memory operations use:

```zig
reg word = load(u32, address, 4);
store(u16, address, value, 2);

reg vector: vec16 = load(vec16, address, 16);
store(vec16, address, vector, 32);
```

The offset is optional and must be a literal. A storage label can be combined
with a runtime base register inside a scalar load or store:

```zig
reg value: u32 = load(u32, table + index);
value = load(u32, table + index, 12);
store(u32, table + index, value, 12);
```

These forms emit relocation-bearing MIPS memory operands such as
`%lo(table + 12)($t0)`. A label without a runtime base uses `$zero`. The older
`load(u32, index, table, 12)` and corresponding `store` spelling remains
supported for compatibility.

Scalar loads use signed or unsigned byte/halfword instructions according to
the type; stores accept every scalar type. Signed narrow loads may widen into
32-bit registers. Scalar offsets must fit the underlying 16-bit instruction
immediate.

The base address of every RSP memory operation has type `dmem`. Storage labels
already have this type, and `dmem.addressOf(label, offset)` materializes a label
plus a constant offset into a `dmem` register. Numeric memory addresses must be
in the range `0..4095`; `4096` is accepted as a one-past-the-end `dmem` value
for loop bounds but cannot be dereferenced. A `u32` or `i32` value can be
assigned explicitly to a `dmem` register when an encoded command or memory word
contains an address. That annotation is the trust boundary for runtime values;
ZSP cannot prove the range of a register at compile time.

Full-vector operations lower to `lqv` and `sqv`. Their byte offsets must be
multiples of 16 in the signed seven-bit scaled range (-1024 through 1008). A
`vec32` transfer emits two operations, with the fractional register at the next
16-byte offset. A single `vec16` lane can be transferred with
`lane = load(vec16, address, offset)` or `store(vec16, address, vector[lane],
offset)`. `loadVectorBytes(address, offset)` loads eight packed bytes and expands
them as signed packed values into a `vec16`; `loadVectorBytesUnsigned` performs
the unsigned form. `loadVectorWords(address, offset, lane)` loads four bytes into
the selected two-lane position without modifying the rest of the rsp.vector.

ZSP supports initialized data, zero/uninitialized storage, and persistent
overlay state:

```zig
packed struct Header {
    opcode: u8;
    size: u8;
    address: u32;
}

data {
    magic: u32 = 0x12345678;
    bytes: [4]u8 = .{ 1, 2, 3, 4 };
    header: Header = .{ 1, 6, 0x100 };
}

bss {
    scratch: [16]u32;
    pub shared_value: u32;
    extern linked_value: u32;
}

state {
    persistent_counter: u32;
}
```

Packed structs contain scalar fields without padding. Use
`offsetOf(Header, address)` as a compile-time memory offset; it emits the same
immediate as writing the numeric byte offset directly. `data` requires literal
initializers and arrays require exactly the declared number of elements. `bss`
and `state` reserve addressable storage. The complete `state` section is padded
to an eight-byte boundary and is intended to survive replacement of an
overlay. Storage labels are compile-time DMEM addresses. `pub` exports a
storage label and `extern` references storage
provided by another linked unit; external declarations have no initializer.

## Functions, calls, and modules

Functions may be prefixed by `export`, `pub`, and/or `inline`, and may have the
`noreturn` modifier:

```zig
inline pub fn add(
    reg($a0) left: u32,
    reg($a1) right: u32,
) {
    left += right;
}

export fn _start() noreturn {
    add(1, 2);
    rsp.halt();
}
```

The first four unpinned scalar parameters use `$a0` through `$a3`. Parameters
outside that default, and all vector parameters, must specify a register. Calls
remain stackless, but scalar input arguments are moved into the lowered
signature's registers when allocation cannot coalesce them there directly.
Constants and literals can be materialized in pinned scalar parameters. Vector
arguments and parameters written by the callee still require exact register
matches, and cyclic scalar move permutations are not yet supported. Signed and
unsigned scalar arguments of the same width are representation-compatible.
`inline` functions are expanded at the call site; other functions use the
repository's stackless fixed-register calling convention. `export` emits a
global assembly symbol, while `pub` permits access from another ZSP module.

Function pointers use structural lowered signatures. Unpinned types use the
same default argument registers, and exceptional registers can be explicit:

```zig
reg writer: fn(u32, u32, u32, u32) = &write8;
reg dma_writer: fn(reg($t0) u32, reg($s0) u32);
reg continuation: fn() = &finish;
```

Public exported functions use their source name as their generated interface
and linker name, just like C:

```zig
pub export fn out(reg($t0) size: u32) noreturn {
    // ...
}
```

`--interface <file>` writes importable external declarations for public
exports, including their inferred transitive `writes()` contracts. Build tools
use the accompanying `@zsp-symbol` metadata to bind those names to symbols in a
separately linked resident program, including implementations from imported
modules whose assembly labels are internally mangled.

Modules use relative imports and qualified calls:

```zig
const dma = import("dma.zsp");

export fn _start() noreturn {
    dma.exec(15, 0, rdram, 0x20, 0x0c);
}
```

Only `pub` functions may be referenced through an import. Import cycles,
unknown modules/functions, and duplicate import aliases are rejected.

## Control flow

Structured conditions support `==`, `!=`, `<`, `<=`, `>`, and `>=`, with
signedness taken from the left register:

```zig
if (count < limit) {
    count += 1;
} else {
    count = 0;
}

while (count != 0) {
    count -= 1;
}

copy: do {
    count -= 1;
} while (count != 0);

outer: while (active != 0) {
    if (finished != 0) {
        break outer;
    }
    continue outer;
}
```

Structured conditionals may carry an explicit `slot` block when the transfer-slot
instruction is part of the algorithm rather than merely scheduling:

```zig
if (ready != 0) slot {
    status = next_status;
} {
    consume();
}
```

The slot block executes whether the branch is taken or not. The emitter may
invert a condition and place a terminating arm first when that removes an
otherwise necessary jump.

Labeled blocks provide structured forward exits. Conditional exits lower to a
direct branch to the block end, without an intermediate jump:

```zig
done: block {
    if (value == 0) {
        break done slot {
            status = next_status;
        }
    }
    value += 1;
}
```

When the exit instruction must also fill the hardware slot of a terminal
conditional transfer, attach an explicit shared exit slot:

```zig
done: block {
    if (invalid != 0) jump failed();
} exit slot {
    status = next_status;
}
```

`break` and `continue` target the innermost loop unless followed by a loop
label. A `do`/`while` loop can explicitly fill its backward branch slot
without reverting to labels and gotos:

```zig
do {
    status &= mask;
} while (status != 0) slot {
    status = rsp.cp0.read(4);
}
```

Local labels and explicit branches are also available. A `slot` block must
contain exactly one source statement:

```zig
retry:
if (status != 0) goto retry slot {
    status = load(u32, address);
}

goto done, .branch slot {
    result = 1;
}
done:
```

`slot` is semantic, not a scheduling hint: its statement executes as the
hardware transfer slot on both paths. Leave it off when the statement is only
an optimization opportunity; ZSP fills safe slots automatically. A slot that
contains only `rsp.nop()` is rejected as unnecessary.

`goto label` targets a local label and accepts `.jump` (the default) or
`.branch`. Across functions, ZSP has three control-transfer forms:

```zig
function(arguments);        // normal call; returns to the next statement
tail function(arguments);   // tail call; does not return
jump function(arguments);   // advanced raw direct jump
jump(address);              // advanced raw indirect jump
dmem.addressOf(data, 8);         // materialize a data address plus an optional offset
```

Use a normal call unless the callee must not return. Use `tail` for the normal
non-returning case. `jump` is the advanced escape hatch when code requires an
exact direct transfer or already has a function address in a register. Direct
jumps retain function argument type checking; indirect jumps accept a raw
scalar address. Both forms accept a one-statement `slot` block. A direct raw
jump may also be conditional, for example
`if (condition) jump function(arguments) slot { ... }`.

Function addresses are ordinary typed values. Pin a value to `$ra` when raw
control flow needs an explicit continuation: `reg($ra) next: fn() = &finish;`.

Use `tail` for a non-returning transfer with normal function argument checking:

```zig
fn first(reg($a0) value: u32) noreturn {
    tail helpers.prepare(value);
}
```

The emitter places a tail target immediately after its caller when possible,
including targets imported from another module, so the transfer costs zero
bytes. If another placement edge has already claimed the target, `tail` emits
`j target` and a `nop` delay slot. Function order is selected deterministically;
source code does not specify physical layout.

An adjacent normal call followed by a zero-argument tail call is treated as a
continuation pair:

```zig
append(arguments);
tail commandLoop();
```

When `commandLoop` can be placed immediately after the caller, the call returns
by falling through into it. If that placement is already claimed, ZSP emits a
stackless continuation: it jumps to `append` while loading `commandLoop` into
`$ra` in the jump's delay slot. This keeps the source in terms of ordinary call
and tail-call semantics without requiring a combined control-transfer builtin.

Machine operations use an explicit namespace: `rsp.nop()` emits a literal no-op
and `rsp.halt(code)` emits the RSP break instruction, where the optional code is
a 20-bit unsigned value. `asm("instruction")` emits a raw assembly line and
acts as an optimization barrier when its effects are unknown.

An `exact` block preserves the emitted instructions and their order, and forms
an optimization barrier at both boundaries. Use it only for hand-authored
hardware sequences whose exact encoding or timing is part of the program:

```zig
exact {
    mask = 0x3f000000;
    command ^= mask;
}
```

No optimizer transformation moves, removes, or rewrites instructions within an
exact block, or moves instructions across either boundary. Raw assembly uses
the same construct: `exact { asm("instruction"); }`; there is no separate
`asmExact` spelling.

`return;` emits `jr $ra`. It accepts the same optional one-statement `slot`
block as other control transfers:

```zig
return slot {
    rsp.cp0.startDmaWrite(length);
}
```

## Commands and command tables

`@rspq.command(index)` marks functions for the resident/overlay command ABI. Indices
range from 0 through 239 and must be unique:

```zig
@rspq.command(2) fn write(
    reg($a0) header: dmem,
    reg($a1) value: u32,
) noreturn {
    store(u32, header, value);
    tail commandLoop();
}

const commands = @rspq.commandTable();
```

Command parameters describe fixed ABI registers and command size. A parameter
named `_` contributes to the size without defining a symbol. `@rspq.commandTable()`
emits handler and size metadata, including empty slots and extended overlay
indices.

Handlers that consume a variable-length command directly from `$gp` can use
`@rspq.commandSize(bytes)` to override the inferred size. The override must be a
nonzero multiple of four and cannot be smaller than the declared parameters.

## Vector registers and basic operations

Vector registers use two decimal digits (`$v00` through `$v31`) to distinguish
them from scalar `$v0` and `$v1`:

```zig
reg($v01) left: vec16 = load(vec16, address);
reg($v02) right: vec16 = load(vec16, address, 16);
reg result: vec16 = left + right;
result ^= right;
```

`$v00` and `$v29`-`$v31` are reserved by automatic allocation. Automatically
allocated vectors use `$v01`-`$v28`; `vec32` allocation keeps its pair
contiguous. An explicitly pinned `vec32` must also have a valid adjacent
register.

Both vector types support copy, zero initialization, `+`, `-`, `+=`, `-=`,
`&`, `|`, `^`, `~|`, `~`, and the corresponding compound bitwise operations.
`vec32` addition and subtraction propagate carry or borrow from the fractional
register to the integer register. Copies, inversion, and zero initialization
do not assume `$v00` contains zero.

One specialized packed-vector shift is available: `vec16 >>> 8` lowers to the
RSP `vsrl` form used by the resident command dispatcher. Other vector shifts
are rejected.

## Vector lanes, swizzles, and views

A lane may be read or written with an index from 0 through 7:

```zig
scalar = vector[3];
vector[5] = scalar;
```

Lane transfers use the RSP COP2 halfword instructions. The single-lane aliases
`.x`, `.y`, `.z`, `.w`, `.X`, `.Y`, `.Z`, and `.W` are also supported.

Vector instruction operands accept the native RSP element-selection patterns:

```text
.xyzwXYZW  .xxzzXXZZ  .yywwYYWW  .xxxxXXXX
.yyyyYYYY  .zzzzZZZZ  .wwwwWWWW
.xxxxxxxx  .yyyyyyyy  .zzzzzzzz  .wwwwwwww
.XXXXXXXX  .YYYYYYYY  .ZZZZZZZZ  .WWWWWWWW
```

Typed views select how multiplication operands and results are interpreted:
`.sint`, `.uint`, `.sfract`, and `.ufract`.

## Vector multiply, accumulator, and comparison

ZSP exposes the RSP vector unit operations as expression functions:

```zig
result.sfract = vmulf(source.sfract, factor.x);
result.sfract = vmacf(addend.sfract, factor.yyyyyyyy);
result = vmudh(left, right);
result = vmadh(left, right);
result = accumulator(.middle);
```

The supported multiply families are:

- Fractional: `vmulf`, `vmulu`, `vmacf`, `vmacu`.
- Partial product: `vmudl`, `vmudm`, `vmudn`, `vmudh`, `vmadl`, `vmadm`,
  `vmadn`, `vmadh`.
- Accumulator reads: `accumulator(.high)`, `accumulator(.middle)`, and
  `accumulator(.low)`.

Operand widths, typed views, destination views, and swizzle placement are
validated according to the selected instruction.

The VCC-backed vector operations are `vlt`, `veq`, `vne`, `vge`, and `vmrg`:

```zig
mask_result = vlt(left, right);
merged = vmrg(if_true, if_false);
```

These map directly to RSP vector instructions; they are not scalar booleans or
general structured conditions.

More explicit aliases are available for code that should describe the vector
unit state it manipulates:

```zig
sum = vectorAdd(left, right);
difference = vectorSubtract(left, right);
sum = vectorAddCarry(left, right);
difference = vectorSubtractCarry(left, right);
mask = vectorCompareLessThan(left, right);
mask = vectorCompareEqual(left, right);
mask = vectorCompareNotEqual(left, right);
mask = vectorCompareGreaterOrEqual(left, right);
merged = vectorSelectByCompareCode(if_true, if_false);

high = readVectorAccumulatorHigh();
middle = readVectorAccumulatorMiddle();
low = readVectorAccumulatorLow();
result[0] = vectorReciprocal(source[0]);
result[0] = vectorReciprocalLow(source[0]);
result[0] = vectorReciprocalHigh(source[0]);
destination[3] = vectorMove(source[6]);
```

`vectorMove` emits the RSP's native `VMOV` destination-element encoding. A
plain lane-to-lane assignment retains the legacy encoding; assigning a scalar
register to a vector lane emits `MTC2`.

The vector control registers use their full hardware names. Reads return a
scalar value and writes consume one:

```zig
carry = rsp.vector.getCarryOut();
compare = rsp.vector.getCompareCode();
extension = rsp.vector.getCompareExtension();
rsp.vector.setCarryOut(carry);
rsp.vector.setCompareCode(compare);
rsp.vector.setCompareExtension(extension);
```

`vectorShiftLeft8(source, amount)` accepts amounts 8 through 15, and
`vectorShiftRightArithmetic(source, amount)` accepts amounts 1 through 8.
`vectorShiftRightLogical(source, amount)` accepts amounts 1 through 8. They
describe the RSP multiply-based vector shift forms explicitly.

Partial and packed vector transfers are statement builtins. Their lane and
offset arguments are compile-time integers:

```zig
rsp.vector.load16(vector, lane, address, offset);
rsp.vector.load32(vector, lane, address, offset);
rsp.vector.load64(vector, lane, address, offset);
rsp.vector.load128(vector, address, offset);
rsp.vector.store16(vector, lane, address, offset);
rsp.vector.store32(vector, lane, address, offset);
rsp.vector.store64(vector, lane, address, offset);
rsp.vector.store128(vector, address, offset);
rsp.vector.loadPackedSigned(vector, address, offset);
rsp.vector.loadPackedUnsigned(vector, address, offset);
```

Use `reserved reg($v1) name: u32 = undefined;` to give an ABI-reserved scalar
register a name while preventing the backend from silently using `$v1` as its
temporary register.

The `cp0` hardware namespace exposes named, value-returning register reads and
register-agnostic writes. The destination of a read is the register allocated
to the receiving ZSP value; operation names never encode a scalar register:

```zig
status = rsp.cp0.spStatus();
busy = rsp.cp0.dmaBusy();
rsp.cp0.setDmaMemoryAddress(dmem_address);
rsp.cp0.setDmaRdramAddress(rdram_address);
rsp.cp0.startDmaRead(length);
rsp.cp0.setRdpCommandEnd(command_end);
```

Named reads also include `dmaMemoryAddress`, `dmaRdramAddress`, `dmaFull`,
`rdpCommandStart`, `rdpCommandEnd`, and `rdpStatus`. Named writes include
`setSpStatus`, `startDmaWrite`, and `setRdpCommandStart`.

`rsp.cp0.dmaMemoryAddress()` returns `dmem`, and
`rsp.cp0.setDmaMemoryAddress(address)` requires `dmem`. The RDRAM and other CP0
registers remain ordinary 32-bit scalar values.

Advanced code may access a numbered CP0 register with `rsp.cp0.read(index)` and
`rsp.cp0.write(index, value)`. The `readRegister` and `writeRegister` forms operate
on an explicit hardware register not represented by a ZSP value:

```zig
status = rsp.cp0.read(4);
rsp.cp0.write(9, command_end);
rsp.cp0.readRegister(5, $at);
```

## Explain

`zsp explain <input.zsp>` compiles and links the program without writing an
assembly file, then reports the compiler decisions that are otherwise hard to
see from source:

- each parameter and local's actual scalar or vector register, including
  whether the choice was automatic or fixed;
- each function's transitive scalar and vector write set;
- command indices, handlers, and encoded command sizes;
- IMEM text size before and after optimization; and
- whether optimization changed the assembly and which pass families ran.

Module lookup flags and `--no-optimize` work the same way as normal compilation.
The report comes from the resolved allocator and write analysis, not from
guessing register use after assembly emission.

## Optimizer

The assembly optimizer performs conservative RSP scheduling. It can fill
branch delay slots, hide scalar load latency, pair independent scalar and
vector pipeline instructions, and tighten common CP0 polling loops. It tracks
register and memory dependencies, preserves memory order, leaves already-filled
delay slots intact, and treats unknown raw assembly as a barrier. Use
`--no-optimize` when inspecting direct code generation.

## Current limitations

Notable omissions include general scalar multiplication/division, casts,
ternary expressions, general vector shifts, packed
vector stores, unaligned vector operations, transposed vector operations,
annotations, and macros.

See `tools/zsp/tests.zig` and the `.zsp` files under `src/n64/rsp/ucode/` and
`src/tests/ucode/` for executable examples of the supported subset.
