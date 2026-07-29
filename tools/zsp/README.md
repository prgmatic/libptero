# ZSP

ZSP is the in-repository Zig implementation of the RSPL-inspired RSP
transpiler. Source files are transpiled to MIPS/RSP assembly and then assembled
as RSP microcode.

## Vector support

The initial vector subset provides `vec16` and `vec32` register values:

```zig
reg($v01) left: vec16 = load(vec16, address);
reg($v02) right: vec16 = load(vec16, address, 16);
reg result: vec16 = 0;

result = left + right;
result ^= right;
store(vec16, address, result, 32);
```

`vec16` occupies one 128-bit vector register. `vec32` represents eight 16.16
fixed-point lanes and occupies an adjacent pair: the named register contains
the integer halves and the following register contains the fractional halves.
For example, `reg($v08) value: vec32` reserves `$v08` and `$v09`.

Vector registers use two decimal digits (`$v00` through `$v31`) so they remain
distinct from the scalar MIPS registers `$v0` and `$v1`. `$v00` and
`$v29`–`$v31` are reserved by the backend. Automatic allocation uses
`$v01`–`$v28` and keeps `vec32` pairs contiguous.

The supported vector operators are:

- Assignment and zero initialization
- Addition and subtraction: `+`, `-`, `+=`, `-=`
- Logic: `&`, `|`, `^`, `~|`, `~`, including compound assignments

`vec32` addition and subtraction propagate carry or borrow from the fractional
register to the integer register. Copies, inversion, and zero initialization do
not assume that `$v00` already contains zero.

Functions may declare fixed vector-register parameters:

```zig
inline fn accumulate(
    reg($v01) value: vec16,
    reg($v02) addend: vec16,
) {
    value += addend;
}
```

Call arguments must have the same vector type and exact fixed register as the
corresponding parameter.

Full-vector memory operations currently lower to `lqv` and `sqv`. Their
immediate offsets must be multiples of 16 in the signed seven-bit scaled range
(-1024 through 1008 bytes). A `vec32` transfer performs two operations, with
the fractional register at an additional 16-byte offset.

Swizzles, lane transfers, packed or partial vector memory operations, vector
casts, multiplication, accumulator operations, comparisons, and shifts are
not part of this initial subset.
