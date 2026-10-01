# glTF model compiler

`gltf-compiler` converts binary glTF 2.0 (`.glb`) meshes into native libptero
model assets. The output is generated Zig metadata plus one compact binary blob
containing RSP-ready vertex pairs and converted texture texels. Applications
normally invoke it through `AssetBundle.addModel`:

```zig
var assets = sdk.createAssets("assets");
assets.addModel("scene", b.path("assets/scene.glb"), .{ .scale = 64 });
```

The resulting value owns a native `n64.graphics.model.Model` and exposes
`draw(&geometry_context)`. Mesh primitives are remapped into batches that fit
the shared RSP vertex/index workspace, preserving as much vertex reuse as that
workspace allows. It reorders triangles for vertex-cache locality and emits
winding-preserving strips. Positions, 5.6.5 normals, gamma-adjusted vertex
colors, UVs, restart-encoded triangle indices, nested Fast64 front/back culling
flags, embedded PNG images, and the Fast64-style intensity format suffix used
by Tiny3D's `01_model` are supported. Opaque geometry is reordered for cache
locality. glTF `BLEND` materials preserve source triangle order and use alpha
blending without depth writes. Fast64-wrapped materials instead use their N64
render-mode preset to distinguish opaque and translucent surfaces.

Legacy Fast64 `extras.f3d_mat.tex0` tile bounds supply UV dimensions when no
embedded image dimensions are available. External images still need separate
texture assets and a material callback; this metadata fallback does not load them.

Material state is exposed as `asset.material(index)` (a native
`n64.graphics.model.Material`). The generated `asset.draw(context)` applies it
automatically for embedded textures. For external textures, callbacks can use
`asset.material(index).bind(context, texture)` without recreating material settings.
The legacy Fast64 subset preserves front/back culling, unlit shading, fog enable,
sampler masks/clamping/mirroring/signed shifts for both texture units, point/median/
bilinear filtering, one/two-cycle combiners, and primitive/environment colors.
glTF `MASK` preserves its alpha cutoff; `BLEND` preserves alpha and disables depth
writes. Unsupported sampler/filter/combiner values are conversion errors.

Filtered UVs receive the half-texel adjustment at conversion (subtract 16 in 10.5
fixed-point); point-filtered UVs do not. Do not apply another runtime adjustment.
Geometry automatically samples the most recently bound material tile, including
cache hits on nonzero tiles. Recorded models restore tracked material state when
replayed; callers do not need to discard the texture cache at each material change.

Native materials handle fog plus transparency with two-cycle blending and a
passthrough second combiner when needed. `rdp.BlendMode.fogVisibility(translucent)`
is also available for handwritten materials; it interprets shade alpha as visibility.
Application code still owns fog color/range and animated sampler offsets.

The renderer streams model parts asynchronously through the RSP command queue.
The queue rolls over according to its actual word capacity, so model code does
not guess a safe batch size from triangle counts. Generated parts declare their
data immutable; handwritten dynamic parts can select `.data_usage = .dynamic`
to request cache writeback on every draw.

The standalone CLI is:

```text
gltf-compiler input.glb model.bin model.zig asset_name scale
```

Implementation layout:

- `main.zig` owns CLI arguments, diagnostics, and file IO.
- `root.zig` is the small public conversion facade used by builds and tests.
- `compiler.zig` owns GLB decoding, mesh conversion, packing, and Zig emission.

Current initial-port limitations are explicit: only embedded-buffer GLB files,
triangle primitives, static meshes, one base-color texture per material, and
PNG images are supported. `JOINTS_0` and `WEIGHTS_0` are parsed and rejected as
`UnsupportedSkinning` instead of being silently discarded. Node transforms,
skins, animations, morph targets, sparse accessors, external buffers/images,
texture palettes, automatic loading of multiple texture units, and the full modern
Fast64 combiner/render-mode extension are not implemented. Two external textures
can be bound with `render.useTexturePair`; generated legacy materials expose both
samplers and both combiner cycles. Key/conversion constants, arbitrary advanced
blender equations, texture generation, and material lighting rigs remain unsupported.
