# font-compiler

`font-compiler` converts text-format AngelCode BMFont (`.fnt`) files and their
PNG pages into libptero-native font assets. It emits RDP-ready RGBA16 or outlined CI4 texels and
a Zig module containing typed metrics, glyphs, ranges, kerning pairs, atlases,
and optional ellipsis layout data.

```sh
font-compiler assets/my-font.fnt build/font.texels build/font.zig my_font
```

Applications normally use `AssetBundle.addFont`, which runs the compiler and
adds the generated `n64.graphics.Font` value to the asset module.

The ellipsis width is the right edge of the final repeated glyph. Its advance
includes self-kerning when the source font defines it.

The default format retains RGBA16 colors. Select `.format = .mono_outline` in
`addFont` (or pass `--mono-outline` to the CLI) for an opaque monochrome fill
and outline mask: white visible pixels become fill, black visible pixels become
outline, and alpha below 128 becomes transparent. The compiler packs two
independent two-bit glyph layers into each 64×64 CI4 atlas, with two IA16 palette
banks. `TextOptions.color` sets the fill; `outline_color` defaults to gray64.
Scaling and fractional coordinates remain supported.

TTF/OTF rasterization, automatic outline generation, variable-font axes, arbitrary
indexed-color atlases, and asset compression remain intentionally unsupported.

## Rendering

Generated assets expose an `n64.graphics.Font`. Text coordinates use a
baseline, like libdragon's RDPQ text API. Rendering goes through any libptero
RDP render queue; the default geometry context uses the RSP overlay queue:

```zig
_ = try assets.my_font.draw(&renderer.render, 24, 48, "Hello, N64!", .{
    .color = .white,
    .scale = 2,
});
```

The current runtime API supports UTF-8 glyph lookup, kerning, newlines, color,
uniform scaling, line spacing, and measurement. Layout features that require
compiler support beyond the initial port (styles, wrapping, alignment, and
ellipsis truncation) are intentionally not exposed yet.
