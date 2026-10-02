# glTF model compiler

`gltf-compiler` converts binary glTF 2.0 (`.glb`) meshes into native libptero
model assets. The output is generated Zig metadata plus one compact binary blob
containing RSP-ready vertex pairs and converted texture texels. Applications
normally invoke it through `AssetBundle.addModel`:

```zig
var assets = sdk.createAssets("assets");
assets.addModel("scene", b.path("assets/scene.glb"), .{ .scale = 64 });
```

The resulting value pairs a native `n64.graphics.model.Model` with a typed
material provider. Draw it with `geometry_context.drawModel(asset)` or
`geometry_context.drawModelWithTransform(asset, &matrix)`. Mesh primitives are remapped into batches that fit
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
texture assets and declarative bindings or a material callback; this metadata fallback does not load them.

Material state is exposed as `asset.material(index)` (a native
`n64.graphics.model.Material`). `context.drawModel(asset)` applies it
automatically for embedded textures. For external textures, callbacks can use
`asset.material(index).bind(context, texture)` without recreating material settings.
For ordinary bindings, use a value such as
`asset.withOverrides(.{.{ .index = 0, .texture = assets.crate, .fog = false }})`.
Overrides preserve imported material state and retain embedded textures for
unmodified materials. Any native material field can be replaced; `no_light`
updates that draw flag without replacing the other flags. `second_texture`
binds a texture pair. Later entries win; omitting `index` affects all materials.
`withModel(instance.model())` retains bindings for mutable/skinned geometry.

Pass a custom provider through `context.drawModelWithMaterials(asset.model, provider)`;
it implements `apply(context, material_index)`. Asset values contain borrowed geometry
and their provider, with no drawing methods or hidden renderer ownership.
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
data immutable; generated `vertex_count` describes logical vertices, while the
binary storage rounds up to complete hardware pairs. Handwritten dynamic parts can select `.data_usage = .dynamic`
to request cache writeback on every draw.

The standalone CLI is:

```text
gltf-compiler input.glb model.bin model.zig asset_name scale
```

Implementation layout:

- `main.zig` owns CLI arguments, diagnostics, and file IO.
- `root.zig` is the small public conversion facade used by builds and tests.
- `compiler.zig` owns GLB decoding, mesh conversion, packing, and Zig emission.

Skeletons and animation are native metadata on `asset.model`: `nodes`, `skins`,
and `animations`. Conversion preserves local SRT hierarchies, inverse bind
matrices, all four `JOINTS_0`/`WEIGHTS_0` influences, named clips, and translation,
rotation, and scale channels with STEP, LINEAR, or CUBICSPLINE interpolation.
Integer normalized skin weights are decoded and normalized. Bone translations,
animation translations/tangents, and inverse-bind translations use the same
position scale as packed geometry. Skinned source vertices remain in bind space;
rigid mesh node transforms and inherited transforms are baked into geometry with
inverse-transpose normals. See [runtime animation](../../src/n64/README.md#skeletons-and-animation)
for mutable skeletons, independent playback, blending, attachments, and CPU
skinning through `model.SkinnedModel`.

The default `.skinning = .weighted` preserves all four influences. Opt into
`.skinning = .first_joint` in `addModel` for Tiny3D-style RSP skinning: conversion
uses `JOINTS_0[0]` regardless of weights, transforms unquantized source vertices
and normals into that joint's bind-local space, and emits joint-grouped parts.
Mixed-joint triangles retain their independently transformed corners. Upload a
caller-owned fixed matrix pose with `Skeleton.writeMatrices` and
`Context.setPose` before drawing the model or its `RecordedModel`. Keep pose
storage alive and unchanged until completion. This is a deliberately different
skinning contract; use weighted assets with `SkinnedModel` when weighted
deformation is required.

Values below an absolute magnitude of `1e-18` are canonicalized to zero in
skeleton and animation metadata. They are negligible for unit quaternions, but
multiplying the tiny exporter-generated components otherwise creates subnormal
results unsupported by the VR4300 FPU. Runtime quaternion normalization and SRT
construction protect against the same issue after interpolation.

Remaining limitations are explicit: only embedded-buffer GLB files, triangle
primitives, one base-color texture per material, and PNG images are supported.
Node matrix transforms, instanced mesh nodes, animated rigid meshes, morph
targets, sparse accessors, external buffers/images, embedded texture palettes, automatic
loading of multiple texture units, and the full modern Fast64
combiner/render-mode extension are not implemented. External textures can be
bound with declarative asset overrides or a custom typed material provider.
External CI4/CI8 textures and their palettes are supported by the public texture SDK.
Two external textures can be bound with `render.useTexturePair`; generated legacy
materials expose both samplers and both combiner cycles. Key/conversion
constants, arbitrary advanced blender equations, texture generation, and material
lighting rigs remain unsupported. These limitations do not prevent conversion
of the GLBs used by Tiny3D's skeleton, animation, and animation viewer demos.
