# font-compiler

`font-compiler` converts text-format AngelCode BMFont (`.fnt`) files and their
PNG pages into libptero-native font assets. It emits RDP-ready RGBA16 texels and
a Zig module containing typed metrics, glyphs, ranges, kerning pairs, atlases,
and optional ellipsis layout data.

```sh
font-compiler assets/my-font.fnt build/font.texels build/font.zig my_font
```

Applications normally use `AssetBundle.addFont`, which runs the compiler and
adds the generated `n64.graphics.font.Font` value to the asset module.

The ellipsis width is the right edge of the final repeated glyph. Its advance
includes self-kerning when the source font defines it.

This initial port supports text BMFont input and RGBA16 atlases. TTF/OTF input,
outlines, variable-font axes, indexed-color atlases, and asset compression are
intentionally unsupported.

## Rendering

Generated assets expose an `n64.graphics.font.Font`. Text coordinates use a
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
