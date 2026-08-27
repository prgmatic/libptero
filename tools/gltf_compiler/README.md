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
texture palettes, multiple texture units, alpha-mask cutoff, and the full
Fast64 combiner/render-mode extension are not implemented.
