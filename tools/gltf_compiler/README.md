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
workspace allows. Positions, 5.6.5 normals, gamma-adjusted vertex colors, UVs,
restart-encoded triangle indices, material flags, embedded PNG images, and the
Fast64-style intensity format suffix used by Tiny3D's `01_model` are supported.

The current renderer places a synchronous RDP fence between model parts that
reload the vertex cache. Asynchronous multi-part submission and recorded model
display lists remain future performance work; this does not change generated
asset data or the public `draw` API.

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
PNG images are supported. Node transforms, skins, animations, morph targets,
sparse accessors, external buffers/images, texture palettes, multiple texture
units, and the full Fast64 combiner/render-mode extension are not implemented.
Generated materials are currently double-sided because independent restart-
encoded triangles do not yet preserve Tiny3D's back-face culling convention.
