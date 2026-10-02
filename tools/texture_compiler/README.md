# Native texture compiler

`AssetBundle.addTexture(name, input_png, options)` converts PNG images to typed
borrowed images. Supported formats are RGBA16/32, YUV16, IA4/8/16, I4/8, and
CI4/8. Standalone invocation is:

```text
texture-compiler input.png texture.bin texture.zig name format
```

Direct textures contain raw hardware texels. Indexed textures place an RGBA16
palette after the texels at an eight-byte boundary in the same binary blob.
Generated Zig exposes `image.PalettedImage(Pixel)` with read-only texel and palette
slices. No runtime parser or pointer fixup is required. The public conversion API
also returns texels and palette separately for programmatic consumers.

CI4 uses up to 16 colors; CI8 uses up to 256. Images already within that limit
retain their colors. Larger images use deterministic median cut weighted by
pixel population, followed by nearest-color assignment. Transparent and opaque
pixels occupy separate palette groups; RGBA16 uses one-bit alpha. This supports
Tiny3D's source textures bearing `.ci4.png`/`.ci8.png` suffixes even when their
PNG files contain unquantized RGB/RGBA pixels.

Pass a generated texture to `render.useTextureSampler` or `Material.bind` as
usual. The renderer uploads the RGBA16 TLUT into upper TMEM, leaving 2048 bytes
for indexed texels. Thus a 64×64 CI4 or 64×32 CI8 image fits. Switching palettes
invalidates texture residency; switching to a direct texture disables lookup.
Texture pairs can share one palette and must jointly fit the lower bank. Other
palette combinations require a separate draw. Palette addresses must be eight-byte aligned. Storage must remain coherent and
alive until GPU completion.

The PNG decoder supports indexed bit depths 1/2/4/8 and palette transparency,
as well as the existing RGB/RGBA and intensity inputs. The conversion API retains
its gamma, ordered dithering for direct formats, and box-mipmap controls. The
SDK CLI emits the base level; application-managed mipmaps use the conversion API.
