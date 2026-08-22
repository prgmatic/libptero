# ZSP

ZSP is the in-repository RSP transpiler. It translates `.zsp` source files to
GNU-style MIPS/RSP assembly, which can then be assembled into RSP microcode.

This document describes the language implemented in this repository.

## Building and running

```sh
zig build-exe tools/zsp/zsp.zig -femit-bin=/tmp/zsp
/tmp/zsp input.zsp output.s
zig cc -target mips-freestanding-none -c output.s -o output.o
```

The command-line syntax is:

```text
zsp <input.zsp> [--module-dir <dir>] [--depfile <file>] [--no-optimize] [output.s]
```

Assembly is written to standard output when `output.s` is omitted. Imports are
resolved relative to the importing file, then relative to `--module-dir`.
`--depfile` writes a Make-compatible dependency file containing every loaded
module. Optimization is enabled by default; `--no-optimize` preserves the
direct emitter output.

## Types and literals

The scalar types are `u8`, `u16`, `u32`, `i8`, `i16`, and `i32`. They describe
the value's signedness and memory access width; scalar values live in 32-bit RSP
general-purpose registers.

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

Calls constrain automatic arguments directly to fixed ABI registers. Values
live across a call avoid the transitive register clobbers inferred from the
call graph, and automatic callee locals avoid pinned caller locals that must
survive the call. Inline function bodies receive the same lifetime and call
analysis while reserving the caller's live registers.

ZSP never inserts spills, argument moves, or save/restore instructions for
automatic allocation. If no safe assignment exists without extra code,
compilation fails.

External functions can declare their complete register-clobber contract after
their parameter list:

```zig
extern fn dmaWait(reg($t2) flags: u32) clobbers($at);
extern fn resumeQueue() clobbers() noreturn;
```

Both scalar and vector hardware registers are accepted by `clobbers(...)`.
An external function without a contract is conservatively assumed to clobber
every register. A live explicitly pinned value that conflicts with an external
contract is a compile error because the allocator cannot move that value or
make the external routine preserve it.

`const` declares a compile-time scalar value. Constants are emitted as
immediates where possible and do not consume registers:

```zig
const dmem_end: u16 = 0x1000;
```

Names may not be duplicated in a visible global or function scope. The old
`var` spelling is not supported.

## Scalar expressions

All scalar types support assignment, arithmetic, shifts, bitwise operations,
and comparisons. An unparenthesized assignment has one operator. An explicitly
parenthesized chain is evaluated left-to-right in the destination register, so
it adds no temporary registers or hidden instructions.

```zig
value = left + right;
value = (left & mask | bits); // `(left & mask) | bits`, reusing `value`
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

Full-vector operations lower to `lqv` and `sqv`. Their byte offsets must be
multiples of 16 in the signed seven-bit scaled range (-1024 through 1008). A
`vec32` transfer emits two operations, with the fractional register at the next
16-byte offset. A single `vec16` lane can be transferred with
`lane = load(vec16, address, offset)` or `store(vec16, address, vector[lane],
offset)`. `load_vec_u8(address, offset)` loads eight packed bytes and expands
them as signed packed values into a `vec16`; `load_vec_u8_unsigned` performs
the unsigned form. `load_vec_u32(address, offset, lane)` loads four bytes into
the selected two-lane position without modifying the rest of the vector.

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
`@offsetOf(Header, address)` as a compile-time memory offset; it emits the same
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
    @break();
}
```

Every parameter must specify a fixed scalar or vector register. Calls do not
implement a conventional stack ABI: arguments must match the parameter type
and register binding. Constants and literals can be materialized in pinned
scalar parameters. Vector arguments must already occupy the exact required
register. `inline` functions are expanded at the call site; other functions
use the repository's stackless fixed-register calling convention. `export`
emits a global assembly symbol, while `pub` permits access from another ZSP
module.

Modules use relative imports and qualified calls:

```zig
const dma = @import("dma.zsp");

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

Structured conditionals may carry an explicit delay block when the delay-slot
instruction is part of the algorithm rather than merely scheduling:

```zig
if (ready != 0) delay {
    status = next_status;
} {
    consume();
}
```

The delay block executes whether the branch is taken or not. The emitter may
invert a condition and place a terminating arm first when that removes an
otherwise necessary jump.

Labeled blocks provide structured forward exits. Conditional exits lower to a
direct branch to the block end, without an intermediate jump:

```zig
done: block {
    if (value == 0) {
        break done delay {
            status = next_status;
        }
    }
    value += 1;
}
```

When the exit instruction must also fill the delay slot of a terminal
conditional transfer, attach an explicit shared exit delay:

```zig
done: block {
    if (invalid != 0) @goto(failed);
} exit delay {
    status = next_status;
}
```

`break` and `continue` target the innermost loop unless followed by a loop
label. A `do`/`while` loop can explicitly fill its backward branch delay slot
without reverting to labels and gotos:

```zig
do {
    status &= mask;
} while (status != 0) delay {
    status = cp0.read(4);
}
```

Local labels and explicit branches are also available. A `delay` block must
contain exactly one source statement:

```zig
retry:
if (status != 0) goto retry delay {
    status = load(u32, address);
}

goto done, .branch delay {
    result = 1;
}
done:
```

`goto label` targets a local label and accepts `.jump` (the default) or
`.branch`. Function-level transfers use these builtins:

```zig
@goto(function);                 // direct jump
@goto(module.function, .branch); // imported public function
@jump(address);                  // indirect jump through a scalar value
@setReturn(label);               // materialize this function's return label
@setFunctionAddress(value, fn);  // materialize a function address in value's register
@setDataAddress(value, data, 8); // materialize a data address plus an optional offset
```

`@goto` and `@jump` also accept a one-statement `delay` block. Conditional
forms such as `if (condition) @goto(function) delay { ... }` are supported.

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

Other builtins are `@nop()` and `@break(code)`, where the optional break code
is a 20-bit unsigned value. `asm("instruction")` emits a raw assembly line and
acts as an optimization barrier when its effects are unknown.

An `ordered` block preserves the emitted instruction order and forms an
optimization barrier at both boundaries. Use it for hand-scheduled hardware
sequences while retaining normal ZSP expressions and type checking:

```zig
ordered {
    mask = 0x3f000000;
    command ^= mask;
}
```

No optimizer transformation moves, removes, or rewrites instructions within an
ordered block, or moves instructions across either boundary.

`@return()` emits `jr $ra`. It accepts the same optional one-statement delay
block as other control transfers:

```zig
@return() delay {
    dma.writeLengthAndStart(length);
}
```

## Commands and command tables

`command(index)` marks functions for the resident/overlay command ABI. Indices
range from 0 through 239 and must be unique:

```zig
command(2) fn write(
    reg($a0) header: u32,
    reg($a1) value: u32,
) noreturn {
    store(u32, header, value);
    @goto(commandLoop);
}

const commands = @commandTable();
```

Command parameters describe fixed ABI registers and command size. A parameter
named `_` contributes to the size without defining a symbol. `@commandTable()`
emits handler and size metadata, including empty slots and extended overlay
indices.

Handlers that consume a variable-length command directly from `$gp` can use
`commandSize(bytes)` to override the inferred size. The override must be a
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
carry = @readVectorCarryOut();
compare = @readVectorCompareCode();
extension = @readVectorCompareExtension();
@writeVectorCarryOut(carry);
@writeVectorCompareCode(compare);
@writeVectorCompareExtension(extension);
```

`vectorShiftLeft8(source, amount)` accepts amounts 8 through 15, and
`vectorShiftRightArithmetic(source, amount)` accepts amounts 1 through 8.
`vectorShiftRightLogical(source, amount)` accepts amounts 1 through 8. They
describe the RSP multiply-based vector shift forms explicitly.

Partial and packed vector transfers are statement builtins. Their lane and
offset arguments are compile-time integers:

```zig
@loadVector16(vector, lane, address, offset);
@loadVector32(vector, lane, address, offset);
@loadVector64(vector, lane, address, offset);
@loadVector128(vector, address, offset);
@storeVector16(vector, lane, address, offset);
@storeVector32(vector, lane, address, offset);
@storeVector64(vector, lane, address, offset);
@storeVector128(vector, address, offset);
@loadVectorPackedSigned(vector, address, offset);
@loadVectorPackedUnsigned(vector, address, offset);
```

Use `reserved reg($v1) name: u32 = undefined;` to give an ABI-reserved scalar
register a name while preventing the backend from silently using `$v1` as its
temporary register.

The RSP hardware namespaces expose the CP0 operations needed by DMA and RDP
command submission:

```zig
busy = dma.busy();
dma.writeMemoryAddress(dmem_address);
dma.writeRdramAddress(rdram_address);
dma.writeLengthAndStart(length);
rdp.writeCommandEnd(command_end);
```

Any CP0 register can be accessed without inline assembly. `cp0.read(index)` is
a scalar expression and `cp0.write(index, value)` is a statement. The
`readRegister` and `writeRegister` forms accept an explicit fixed register for
ABI helpers that intentionally operate on a register not declared as a value:

```zig
status = cp0.read(4);
cp0.write(9, command_end);
cp0.readRegister(5, $at);
```

## Optimizer

The assembly optimizer performs conservative RSP scheduling. It can fill
branch delay slots, hide scalar load latency, pair independent scalar and
vector pipeline instructions, and tighten common CP0 polling loops. It tracks
register and memory dependencies, preserves memory order, leaves already-filled
delay slots intact, and treats unknown raw assembly as a barrier. Use
`--no-optimize` when inspecting direct code generation.

## Current limitations

Notable omissions include general scalar multiplication/division, precedence-
based arbitrary expression trees, casts, ternary expressions, general vector shifts, packed
vector stores, unaligned vector operations, transposed vector operations,
annotations, and macros.

See `tools/zsp/tests.zig` and the `.zsp` files under `src/n64/rsp/ucode/` and
`src/tests/ucode/` for executable examples of the supported subset.
