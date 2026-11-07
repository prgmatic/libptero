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

Parsing. `parser.zig` owns parser state, symbol tables, token helpers, and
shared grammar metadata. `parse_declarations.zig` parses functions,
parameters, register and constant declarations, compile-time enums and flags,
imports, packed structs, and storage blocks. `parse_statements.zig`,
`parse_values.zig`, `parse_builtins.zig`, and `parse_memory.zig` handle
statements, expressions, `rsp.*` builtins, and memory operands. The parser
produces the source AST and a statement source map; `ast_walk.zig` gives
passes uniform access to nested statement lists.

Several source forms expand while parsing, so later stages only see the
ordinary AST: `parse_comptime.zig` evaluates constant expressions, unrolls
`inline for`, and splits register arrays into one register per element;
`parse_products.zig` lowers vector products and the `acc` accumulator;
`parse_lanes.zig` lowers lane-range transfers; `parse_pointers.zig` turns
typed-pointer dereferences into loads and stores; `parse_loops.zig`
attaches `while` continue expressions; `parse_arguments.zig` hoists
expression arguments into temporaries; and `parse_returns.zig` turns inline
return values into a result parameter bound to the caller's destination. The lexer-level substitutions that
make this work (unrolled indices, per-iteration names, and array elements)
live in `Parser.advance`.

Program setup. `cli.zig` owns the command's behavior and output files behind
injected writers, `main.zig` only connects it to the process, and
`options.zig` parses arguments without IO. `root.zig` exposes the
programmatic API. `modules.zig` loads and links modules, retaining source
locations and owning each module's parsed allocations through
`source.Program`, which releases partial ASTs on parse failure. `rspq.zig`
validates command indices, encoded sizes, and parameter ABI bindings; its
`CommandAnalysis` is what emission uses for the command table.
`compiler.zig` runs the shared compilation and explain pipeline, including the
final IMEM limit check.

Analysis. `param_alloc.zig` chooses registers for unpinned parameters of
internal functions (see [Functions, calls, and modules](#functions-calls-and-modules)).
`clobbers.zig` infers each function's transitive write set.
`lifetime_scan.zig` and `flow.zig` record statement positions, reads and
writes, and control-flow edges into `lifetimes.zig`; `call_requirements.zig`
adds the registers call arguments must arrive in, and
`lifetime_analysis.zig` runs these steps. `context.zig` holds one function's
symbols and allocates registers over those lifetimes. `analysis.zig` is a
facade over these files. `placement.zig` computes function order and tail
fallthrough.

Emission. `codegen.zig` writes each function through `emit_statements.zig`,
which dispatches to `emit_scalar.zig`, `emit_control.zig`, `emit_calls.zig`,
`emit_memory.zig`, `emit_vectors.zig`, `emit_builtins.zig`, and
`emit_storage.zig`; `emit_common.zig` and `emit_operands.zig` hold shared type
rules and operand materialization. Emitters append typed instructions to an
`Emitter.zig` buffer rather than text. `ir.zig` defines the instruction IR,
whose `encode()` gives the machine word; `ir_print.zig` prints assembly and
`ir_parse.zig` reads assembly, including `asm` lines, back into the IR.

Optimization. `optimizer.zig` runs the passes in `peephole.zig` and
`schedule.zig` over the IR (see [Optimizer](#optimizer)), using the
instruction effects in `ir_effects.zig` and the dependence graph in
`ir_deps.zig`. `registers.zig` supplies register metadata, `interface.zig`
writes `--interface` declarations, and `explain.zig` formats allocation
reports and diagnostics.

`tests.zig` imports the complete host suite. The `tests/` directory groups
regressions by analysis, optimizer, vectors, memory, commands, control flow,
calls, parser, and scalar emission. `rspq.zig` additionally tests normalized
metadata and semantic errors without depending on assembly text.

This document describes the language implemented in this repository.

The programmatic entry point is `root.zig`. `Program.parse(allocator, source,
&diagnostic)` owns parsed allocations and borrows the source bytes; keep those
bytes alive until `Program.deinit()`. Pass `program.functions` to `compile` to
obtain an owned assembly result, or use `Loader` for file-based module linking.
`Result.deinit(allocator)` releases assembly bytes. Compilation and explain use
the same final IMEM validation. Backend diagnostics retain statement source
locations when available.

## Building and running

```sh
zig build install          # installs zig-out/bin/zsp
zig-out/bin/zsp input.zsp output.s
zig cc -target mips-freestanding-none -c output.s -o output.o
```

The scheduler scores instruction orders with the RSP interpreter's timing
model, so a standalone build must supply that module:

```sh
zig build-exe --dep rsp_timing -Mroot=tools/zsp/main.zig \
    -Mrsp_timing=tools/rsp_interp/timing.zig -femit-bin=/tmp/zsp
```

Invoking the tool without arguments or with `--help` prints usage. Invalid
arguments and compilation failures exit with a concise diagnostic.

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

Wherever a literal is expected (memory offsets, lane indices, array
lengths, `inline for` bounds) a constant expression may be used instead. It
combines literals, `const` names, `inline for` indices, enum and flags
members, `sizeOf(T)`, and `offsetOf(Struct, field)` with the binary
operators, unary `-` and `~`, and parentheses. Scalar expressions whose operands are all
constants fold to a single immediate, and a 32-bit constant whose upper half
is the sign extension of its lower half loads with one `addiu`:

```zig
reg header_end: u32 = load(u32, base, sizeOf(Header) * 2 + offsetOf(Header, address));
```

`sizeOf` accepts the scalar types, `vec16` (16 bytes), `vec32` (32 bytes),
and packed structs.

A typed DMEM pointer `*T` is a `dmem` value that remembers what it points
at: a scalar type, `vec16`/`vec32`, or a packed struct. See
[Typed pointers](#typed-pointers).

## Register variables and constants

Register variables use `reg`, optionally pinned to a hardware register:

```zig
reg count: u32 = 0;
reg($t0) status: u32 = undefined;
reg inferred = load(u16, address);
```

`undefined` reserves a register without emitting initialization. A type may be
inferred only from a `load`. An initializer may be any expression; it is
equivalent to a declaration followed by an assignment.

A register array declares one register per element. Index it with a
constant, usually an `inline for` index; each element is an ordinary
register named `name[index]` in diagnostics and allocation reports:

```zig
reg sums: [4]u32 = 0;              // every element starts at 0
reg rows: [4]vec32 = undefined;
reg($v08) bank: [8]vec16 = undefined; // consecutive registers $v08-$v15
sums[2] += 1;
```

A pinned array must hold vectors; it occupies consecutive registers from
the one named (two per `vec32` element). Unpinned scalar registers are allocated from
`$t0` through `$t9`, `$k0`, `$sp`, `$fp`, and `$s0` through `$s7`. `$zero`,
`$at`, `$v0`, `$v1`, `$gp`, `$k1`, and `$ra` retain explicit ABI or backend
meaning and are not allocated automatically. `$gp` may still be explicitly
pinned.

Automatic allocation is definition- and control-flow-aware: scalar and vector
registers are reused after their values die along every reachable path. The
analysis follows branches, loops, labels, gotos, nested blocks, and branch delay
slots. A value produced in a call's delay slot is live across the callee, while
a value defined by the callee is not treated as a live input. An automatic
value avoids registers that a later value with an overlapping lifetime is
pinned to or must arrive in for a call.

Calls prefer to allocate scalar arguments directly in their fixed
calling-convention registers. When a scalar input is already in a different
register, ZSP inserts the required move before the transfer. Values live across
a call avoid the transitive register writes inferred from the call graph, and
automatic callee locals avoid pinned caller locals that must survive the call.
Inline function bodies receive the same lifetime and call analysis while
reserving the caller's live registers.

ZSP does not insert spills or save/restore instructions. Vector arguments and
parameters written by the callee must already use the target parameter's
register; the allocator places such an argument there when it can. Scalar
argument moves are emitted as a parallel assignment (see
[Functions, calls, and modules](#functions-calls-and-modules)). If no safe
assignment exists under those restrictions, compilation fails.

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

Names may not be duplicated in a visible global or function scope; blocks
that are not nested in each other may each declare the same name. The old
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
reg delta: i32 = -(left + right); // negation applies to any operand
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

The offset is optional and must be a constant expression. A storage label can
be combined with a runtime base register inside a scalar load or store:

```zig
reg value: u32 = load(u32, table + index);
value = load(u32, table + index, 12);
store(u32, table + index, value, 12);
```

These forms emit relocation-bearing MIPS memory operands such as
`%lo(table + 12)($t0)`. A label without a runtime base uses `$zero`.

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
16-byte offset.

Part of a vector is transferred by naming the lanes, `first..end` with the
end excluded, on the load's destination or in the stored value. One, two,
four, or eight lanes select `lsv`/`ssv`, `llv`/`slv`, `ldv`/`sdv`, or
`lqv`/`sqv`; the other lanes keep their values:

```zig
row[0..4] = load(vec16, matrix, 0);     // ldv: lanes 0-3 from 8 bytes
row[4..8] = load(vec16, matrix, 0);     // ldv: the same bytes into lanes 4-7
words[2..4] = load(vec16, input, 4);    // llv
value[3] = load(vec16, input, 6);       // lsv: one lane
store(vec16, output, row[4..8], 16);    // sdv
```

A whole `vec32` transfers its integer lanes at the offset and its fraction
lanes immediately after them, matching 16.16 rows stored as four integer
halfwords followed by four fraction halfwords; select one half with a view
(`pair.sfract[0..4]`) to transfer only that register. Eight lanes must start
at lane 0, and the selection must stay inside the register.

The lane argument of `rsp.vector.loadQuad`, `loadTranspose`, and the other
lane-addressed vector memory builtins is a constant expression, so an
`inline for` index can select it.

`loadVectorBytes(address, offset)` loads eight packed bytes and expands
them as signed packed values into a `vec16`; `loadVectorBytesUnsigned`
performs the unsigned form.

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
immediate as writing the numeric byte offset directly. Storage labels are
typed pointers to their declared type, so `header.size` and `counter.*`
read and write them directly (see [Typed pointers](#typed-pointers)). `data` requires literal
initializers and arrays require exactly the declared number of elements. `bss`
and `state` reserve addressable storage. The complete `state` section is padded
to an eight-byte boundary and is intended to survive replacement of an
overlay. Storage labels are compile-time DMEM addresses. `pub` exports a
storage label and `extern` references storage
provided by another linked unit; external declarations have no initializer.
Several modules of one program may each declare the same `extern`
storage they use.

## Typed pointers

`*T` declares a DMEM address that points at a `T`. Fields of a pointed-to
packed struct are read and written by name, and `.*` dereferences a pointer
to a scalar or vector. Each access becomes one load or store with the
field's type and byte offset:

```zig
packed struct Header { opcode: u8; size: i16; address: u32; }

fn parse(header: *Header, words: *u32, vector: *vec16) {
    reg size: i16 = header.size;     // lh size, 1(header)
    header.opcode = size;            // sb
    reg word: u32 = words.*;
    reg value: vec16 = vector.*;     // lqv
    value[0..4] = vector.*;          // ldv: lane ranges work too
    header += sizeOf(Header);        // pointer arithmetic is in bytes
    reg next: *Header = header;
}
```

A pointer is a `dmem` value everywhere else: it can be passed where `dmem`
is expected, compared, and advanced. Copying one typed pointer to another
requires the same pointee. Storage labels are typed pointers too, so
`header.size` on a `bss { header: Header; }` label reads relative to
`$zero`. Field reads are values (initializers and assignment sources);
declare storage before the code that dereferences it.

## Functions, calls, and modules

Functions may be prefixed by `export`, `pub`, and/or `inline`, and may have the
`noreturn` modifier. `align(n)`, also after the parameters, starts the
function at a multiple of `n` bytes (a power of two from 4 to 4096), as for a
DMA target:

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

Parameters of internal functions need no register. The compiler gives each
unpinned parameter the register its callers most often already hold the
argument in, avoiding registers the function pins or its callees write, so
calls usually need no argument moves. This covers vector parameters too:

```zig
fn scale(value: u32, vector: vec16) { ... }   // registers chosen per callers
```

Functions whose convention other code depends on keep the structural one:
`export` functions, commands, `extern` declarations, and functions whose
address is taken. There the first four unpinned scalar parameters use `$a0`
through `$a3`, and other parameters, including all vector ones, must specify
a register.

Arguments may be expressions: `helper(base + 16, -offset)` evaluates each
expression argument into a temporary just before the statement making the
call, so the callee still receives a register.

A register array parameter, `rows: [4]vec32`, takes one parameter per
element (`rows[0]` to `rows[3]`); callers pass a register array of that
length by name, or the elements individually. Pinned, `reg($v04) rows:
[2]vec16` occupies consecutive registers.

Calls remain stackless. A storage label passed as an argument passes its
DMEM address. Scalar input arguments are moved into the callee's
registers when allocation cannot place them there directly; moves that form a
cycle, such as swapped arguments, go through `$at` (or `$v1` when an argument
is in `$at`). Constants and literals can be materialized in pinned scalar
parameters. Vector arguments and parameters written by the callee require
exact register matches. Signed and unsigned scalar arguments of the same width
are representation-compatible.

A function that calls another overwrites its own `$ra`, so only code that
never returns, such as `_start`, can make nested calls without saving it.
`inline` functions are expanded at the call site. An unpinned inline
parameter names its argument directly, wherever the caller keeps it: reads
and writes of the parameter are reads and writes of the argument, and a
constant argument stays a constant. Parameter names shadow caller names,
and the expansion's temporaries avoid every caller register still in use. A pinned inline parameter receives its
argument in that register. Other functions use the repository's stackless
fixed-register calling convention. `export` emits a
global assembly symbol, while `pub` permits access from another ZSP module.

Inline functions may return a value. `T` after the parameters makes the
final statement `return value;` assign the caller's destination; a named
result, `name: T`, is assigned directly in the body, so the value is built in
the caller's register without a copy:

```zig
inline fn packCodes(codes: u32) result: u32 {
    result = codes & 0x0307;
    reg high: u32 = result >> 5;
    result |= high;
}

inline fn twice(x: u32) u32 {
    return x + x;
}

reg clip: u32 = packCodes(codes);   // declares `clip`, then expands
clip = twice(clip);
```

Only inline functions return values, `return value;` must be the body's last
statement, and a call is the whole initializer or right-hand side.

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

The final RSP pack step can emit linked DMEM and IMEM symbols as a generated Zig
module with `--symbols <output.zig>`. Asset bundles do this automatically, so
CPU code can use compile-time constants such as
`programs.geometry_overlay_symbols.vertex_buffer` instead of duplicating linker
addresses or deriving an interior function from a command handler. IMEM values
are offsets from IMEM base; DMEM values are DMEM offsets. Symbol names and tables
remain host-side build metadata and are not included in the packed program or
final ROM.

For a post-link memory report, run:

```sh
rsp_pack program.elf --map program.map program.rsp
```

The report lists the linked data, persistent state, temporary BSS, and text
ranges followed by every packed symbol. This is the authoritative view when
checking overlay workspace or comparing a layout with another microcode.

Generated symbol modules are deliberately separate from `.rsp` blobs: the
packed format remains header, text, data, command metadata, and initialized
state only. Referencing a generated address is therefore a compile-time CPU
relocation and adds no symbol table or symbol strings to a production ROM.

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
signedness taken from the left register. An `if` or `else` body is a block
or one statement, so `if (done == 0) return;` and `else if` chains need no
braces. `while (true)` and
`do { } while (true)` loop until a transfer leaves them:

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

while (index != count) : (index += 1) {
    if (skip != 0) {
        continue;    // runs `index += 1`, then tests the condition
    }
    process(index);
}

while (true) {
    status = rsp.cp0.spStatus();
    if (status == 0) {
        break;
    }
}
```

A `while` loop is rotated so each iteration costs one branch: the
condition guards entry and is tested again after the body, as in
`if (c) do { ... } while (c)`. A continue expression after `:` runs at the
end of every iteration, including one reached by `continue`.
`if (c) { break; }` and `if (c) { continue; }` lower to a single branch to
the loop's exit or condition. A `while (true)` body that ends in
`if (c) { break; }` and has no `continue` becomes `do { ... } while (!c)`,
so the exit test is the back edge.

An `if` without `else` whose body ends in a transfer (`tail`, `jump`,
`break`, `goto`), followed by statements that also end in one, is laid out
with the body after them: the common path falls through and the body costs
no taken branch.

```zig
if (priority == requested) {
    tail swapBuffers(36, 32, enter_high_priority);   // placed out of line
}
dispatch();
jump(handler);
```

A block that opens with `@branchHint(.cold);` marks its `if` (or a
`while`'s entry test) as rarely taken. When the `if` has no `else`, its body
is placed after the function's return and jumps back, so the common path
falls through without a taken branch. Inside a loop or labeled block the
body must not `break` or `continue`; such bodies stay inline:

```zig
while (dma_busy != 0) {
    @branchHint(.cold);
    dma_busy = rsp.cp0.dmaBusy();
}
```

Bodies stay inline when the function falls through into the next one.

`if (c) tail f(args);` puts a single argument-setup instruction in the
branch's delay slot. Longer setup runs before the test and must not touch
the registers the test reads or uses.

`inline for (first..end) |index| { ... }` repeats its body once per index,
with `index` a constant expression inside it. Registers and labels declared
in the body are separate per iteration, so the body can declare its own
temporaries:

```zig
inline for (0..4) |row| {
    left[row][0..4] = load(vec32, matrix, row * 16);
    reg sum: u32 = load(u32, totals, row * 4);
    sum += 1;
    store(u32, totals, sum, row * 4);
}
```

An empty range emits nothing; a range may unroll at most 256 iterations.

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

`break` and `continue` target the innermost loop unless followed by a
label; labeled blocks are only targeted by name. A `do`/`while` loop can explicitly fill its backward branch slot
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
call(function_address);     // indirect call through a typed function pointer
code.addressOf(label);      // materialize a function or local code label
dmem.addressOf(data, 8);    // materialize a data address plus an optional offset
```

`dmem.addressOf` produces a typed `dmem` value.

Use a normal call unless the callee must not return. Use `tail` for the normal
non-returning case. `jump` is the advanced escape hatch when code requires an
exact direct transfer or already has a function address in a register. Direct
jumps retain function argument type checking; indirect jumps accept a raw
scalar address. Both forms accept a one-statement `slot` block. A direct raw
jump may also be conditional, for example
`if (condition) jump function(arguments) slot { ... }`.

Function addresses are ordinary typed values. Pin a value to `$ra` when raw
control flow needs an explicit continuation: `reg($ra) next: fn() = &finish;`.
`code.addressOf` accepts a function or local label and may initialize either a
typed function pointer or a raw scalar ABI register.
An interior entry point that must be visible to other functions or linked code
uses `export entryName:`. It emits the label without function-local mangling.
Conditional `goto` may target such an exported label in another function,
including register-to-register equality tests.

`bitCast(value)` reinterprets the bits of one scalar type as the destination
scalar type. It emits only a register move when the registers differ and no
instruction when source and destination share a fixed register.

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
`.x`, `.y`, `.z`, `.w`, `.X`, `.Y`, `.Z`, and `.W` are also supported. Lane
indices may be constant expressions.

Vector instruction operands accept the native RSP element-selection patterns:

```text
.xyzwXYZW  .xxzzXXZZ  .yywwYYWW  .xxxxXXXX
.yyyyYYYY  .zzzzZZZZ  .wwwwWWWW
.xxxxxxxx  .yyyyyyyy  .zzzzzzzz  .wwwwwwww
.XXXXXXXX  .YYYYYYYY  .ZZZZZZZZ  .WWWWWWWW
```

The same broadcasts can be selected by a constant index, which suits
`inline for` bodies: `.lane(i)` repeats lane `i` in every lane (`.lane(0)`
is `.xxxxxxxx`), `.halfLane(i)` repeats lane `i` of each four-lane half
(`.halfLane(1)` is `.yyyyYYYY`), and `.quarterLane(i)` repeats lane `i` of
each pair (`.quarterLane(0)` is `.xxzzXXZZ`).

Typed views select how multiplication operands and results are interpreted:
`.sint`, `.uint`, `.sfract`, and `.ufract`. On a `vec32`, `.sint`/`.uint`
select the integer register and `.sfract`/`.ufract` the fraction register.

## Vector products and the accumulator

Multiplication is written with `*` and the RSP multiply accumulator is
named `acc`. `acc = a * b;` starts a chain, `acc += a * b;` adds a product,
and `r = acc;` (or `reg r: T = acc;`) reads the result. `r = a * b;` is a
one-product chain. The operand types choose the multiplies:

| Product | Multiplies | Readable result |
| --- | --- | --- |
| `vec32 * vec32` | `vmudl`, `vmadm`, `vmadn`, `vmadh` | `vec32`, or either half |
| `vec32 * vec16` | `vmudn`, `vmadh` | `vec32`, or either half |
| `vec16 * vec32` | `vmudm`, `vmadh` | integer half (`vec16`) |
| `vec16 * vec16` | `vmudh` | `vec16` |
| `a.sint * b.ufract` | `vmudm` | `vec16` |
| `a.ufract * b.sint` | `vmudn` | `vec16` |
| `a.ufract * b.ufract` | `vmudl` | `vec16` |
| `a.sfract * b.sfract` | `vmulf` | `vec16` |

A `vec32` operand is a 16.16 pair; a `vec16` without a view is an integer.
The first multiply of a chain clears the accumulator (`vmud*`/`vmulf`) and
every later one accumulates (`vmad*`/`vmacf`). Only the right operand may
be swizzled:

```zig
acc = left[0] * right.halfLane(0);
inline for (1..4) |row| {
    acc += left[row] * right.halfLane(row);
}
reg rows: vec32 = acc;
```

The read is folded into the last product: its multiplies write their
clamped accumulator slices straight into `r` (the fraction from
`vmadn`, the integer from `vmadh`), and the other multiplies write a
compiler-chosen scratch register. The read must therefore directly follow
the product it reads; other statements may sit between the products of a
chain, but vector instructions there also change the accumulator. A whole
`vec32` result needs a final product whose left operand is a `vec32`. For
raw, unclamped slices use `accumulator(.high)`, `.middle`, or `.low`. A
program variable named `acc` is an ordinary register and disables the
syntax in its scope.

The instruction forms below remain available for multiplies the table does
not cover, such as `vmulu`, and for code that must name each instruction.

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
- Reciprocals: `vrcp`, `vrcpl`, `vrcph`, `vrsq`, `vrsql`, `vrsqh`.

Operand widths, typed views, destination views, and swizzle placement are
validated according to the selected instruction.

The VCC-backed vector operations are `vlt`, `veq`, `vne`, `vge`, `vch`,
`vcl`, and `vmrg`:

```zig
mask_result = vlt(left, right);
merged = vmrg(if_true, if_false);
```

These map directly to RSP vector instructions; they are not scalar booleans or
general structured conditions.

Operators, products, and lane assignment are the readable layer; an explicit
vector instruction is always written as its RSP mnemonic, the name every RSP
reference uses, so each operation has one spelling:

```zig
sum = vadd(left, right);          // saturating; `left + right` wraps (VADDC)
difference = vsubc(left, right);
mask = vlt(left, right);
clip = vch(value, boundary);
merged = vmrg(if_true, if_false);
result[0] = vrcp(source[0]);
result[0] = vrsqh(source[0]);
destination[3] = source[6];       // VMOV
```

A plain lane-to-lane assignment emits `VMOV`; assigning a scalar register to
a vector lane emits `MTC2`.

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

Partial transfers use lane ranges (see [Memory and storage](#memory-and-storage)).
The remaining specialized transfers are statement builtins. Their lane and
offset arguments are compile-time integers:

```zig
rsp.vector.loadQuad(vector, lane, address, offset); // lqv starting at lane
rsp.vector.loadRight(vector, address, offset);      // lrv unaligned suffix
rsp.vector.storeRight(vector, address, offset);     // srv unaligned suffix
rsp.vector.loadTranspose(bank, lane, address, offset); // ltv: bank is v00/v08/v16/v24
rsp.vector.loadPackedSigned(vector, address, offset);
rsp.vector.loadPackedUnsigned(vector, address, offset);
rsp.vector.storePackedSigned(vector, lane, address, offset);
rsp.vector.storePackedUnsigned(vector, lane, address, offset);
```

`loadTranspose` writes one lane in each of the eight registers starting at the
selected bank. Bind the bank explicitly and keep its registers available; its
exported clobber contract includes all eight. Quad, right and transpose offsets
are multiples of 16, matching their hardware encodings.

Use `reserved reg($v1) name: u32 = undefined;` to give an ABI-reserved scalar
register a name while preventing the backend from silently using `$v1` as its
temporary register.
The same form may explicitly claim `$k1` in a non-returning command that uses
the resident command-return register as application-defined state.
`reserved` also keeps any other scalar register but `$zero` and `$at` for the
whole function and every function it calls, as when code entered from
elsewhere must leave its callers' registers alone:

```zig
reserved reg($s1) caller_state: u32 = undefined;
```

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

## Verifying microcode changes

ZSP output is no longer compared byte for byte with libdragon/Tiny3D. Check
changes to the compiler or to shipped `.zsp` sources with:

```sh
zig build test            # includes the RSP interpreter workloads and baseline gate
zig build rsp-baseline    # estimated cycles per workload and hottest functions
```

The host workloads must reproduce their recorded outputs and stay within 2% of
the recorded cycles. Record intended improvements with
`zig build rsp-baseline -- --update`. Run the hardware tests as well. See
`src/tests/microcode/README.md` and `tools/rsp_interp/README.md`.

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

## Diagnostics

Compilation errors name the source position, the function, and the value
concerned, with a hint for the usual fix. When register allocation fails, the
message also lists the values occupying registers over that value's lifetime:

```text
kernel.zsp:12:5: zsp: error in function 'blend' for 'weight': scalar register allocation failed; ... (OutOfFreeRegisters)
  21 live values: a in $t0, b in $t1, ... (+9 more)
```

## Optimizer

The optimizer works on the instruction IR, so it sees real operands rather
than assembly text. Its passes run in order:

1. Relocation folding merges `symbol + constant` address arithmetic into the
   memory operand.
2. Repeated-constant removal drops an `addiu`/`ori` from `$zero` that sets a
   register to the value it already holds in the same straight-line run, as
   when consecutive vector loads from one label each materialize its address.
3. Dead-write removal drops register writes that are overwritten before any
   read.
4. Polling-loop folding tightens common CP0 busy-wait loops.
5. Lane-encoding selection spells each VMOV/VRCP/VRSQ destination element
   (bit 3 is ignored by hardware) to avoid false dependences.
6. List scheduling reorders each straight-line block together with the branch
   that ends it and that branch's delay slot. A beam search (32 candidates,
   windows of up to 64 instructions) scores orders with the RSP interpreter's
   calibrated timing model (`tools/rsp_interp/timing.zig`), so it accounts for
   load latency, vector result latency, and dual issue. Each window starts
   from the pipeline state left by the instructions that fall through into
   it, so results still in flight from the previous block count.
7. Delay-slot filling moves an independent instruction into each remaining
   branch slot when the timing model says the code around it does not get
   slower.
8. Loop-exit slots: a backward branch whose slot is still empty takes the
   first instruction after the loop when repeating it each iteration is
   harmless, such as `dma.exec`'s descriptor setup after its DMA-full poll.
   The loop body may branch forward within itself (an `if` in the loop);
   only its unconditional prefix counts as overwriting the moved result.
9. Fall-through slots: a conditional branch whose slot is still empty takes
   one of the next few instructions when it has no side effects and what it
   writes is dead where the branch goes. Liveness comes from a bounded walk
   over the program, through jumps and into one level of calls; returns,
   indirect jumps, and unknown targets count as reads.
10. Call continuations: a call followed by a jump to a local label,
    `jal f; slot; j next; nop`, becomes `addiu $ra, $zero, %lo(next); j f;
    slot`, so the callee returns straight to `next`, as at the end of a loop
    body. Returning through the old `$ra` led to `next` as well; the slot
    must leave `$ra` alone. Transfers to a lone `j target; nop` are first
    sent to `target` directly, so the jump's own label may disappear.

Dependences come from per-instruction effects: registers, the vector
accumulator, VCO/VCC/VCE, the divide unit, memory, and IO. Partial vector
writes count as read-modify-write, `ltv`/`stv` touch their whole eight-register
bank, and CP0 accesses order all memory. Memory operations with the same base
register and symbol whose byte ranges are disjoint are independent. Writes to
state that is dead afterwards are ordered only against the live ranges around
them.

Instructions in `exact` blocks are never moved or removed, and `asm` lines
are parsed into the IR when possible and otherwise act as barriers. Use
`--no-optimize` to inspect direct code generation. Shipped microcode can be
written plainly: `src/tests/ucode/matrix_kernels.zsp` checks on hardware that
matrix multiply and normalization written with `vec32` rows, `*` products,
register arrays, and `inline for`, without pins or `exact`, match the
hand-scheduled Tiny3D versions, and the host interpreter checks that they
take no more cycles.

## Current limitations

Statement keywords such as `packed`, `state`, and `data` are contextual:
`state = 0;` assigns a variable of that name.

Notable omissions include general scalar multiplication/division, casts,
ternary expressions, value returns from non-inline functions, general vector shifts, general-purpose annotations, and
macros. Register-array indices and `inline for` bounds must be constants;
typed-pointer fields cannot be arrays. Selected unaligned and transposed transfers are supported through the
explicit `rsp.vector.*` operations described above.

Analysis and parser tables grow as needed, so function size is limited only by
IMEM. Function pointer types take at most 16 parameters. Raw assembly still
uses conservative register allocation because its effects cannot be inferred
from source.

See `tools/zsp/tests/` and the `.zsp` files under `src/n64/rsp/ucode/` and
`src/tests/ucode/` for executable examples of the supported subset.
