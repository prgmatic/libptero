# n64 runtime

See [API organization and migration](API.md) for namespaces, source paths, and
the ownership distinctions between App, renderers, encoders, and data views.

The public `n64` module exposes hardware interfaces, graphics, RSP queues,
input, math, cache operations, debugging, and display buffer management.

For a coordinated game loop with borrowed render data, input snapshots and explicit
submission, see [Game loops](app/README.md). The APIs below remain independently
usable.

## Display buffers

`n64.display.Swapchain(Pixel)` manages RGBA16 or RGBA32 framebuffers. It owns
one contiguous allocation when initialized with an allocator:

```zig
const Pixel = n64.graphics.pixel.Rgba16;
var display = try n64.display.Swapchain(Pixel).init(allocator, .{
    .resolution = .@"320x240p",
    .buffer_count = 3,
});

while (true) {
    const frame = try display.acquire();
    render.clear();
    render.setFrameBuffer(frame.image);
    render.clearScreen(Pixel.black);
    // Record drawing commands here.
    const completion = render.submit();
    try display.present(frame, completion, .{});
}
```

For allocation-free setup, supply a `[]align(64) Pixel` to `initBuffer`.
`requiredPixelCount(options)` returns the required number of pixels. The used
storage is cleared to black and written back; extra storage is untouched.
Borrowed memory is never freed by `deinit`, and its allocator argument is ignored.
The first buffer starts as the black front buffer. At least two are required.
The ROM main loop above retains its storage until reset. In a returning scope,
call `try display.deinit(allocator)` after completing all rendering, including
any work still pending after a timeout.

Each acquired frame exposes a borrowed `image` and an `index` suitable for
selecting matching application-owned depth buffers. One acquisition may be
outstanding at a time. Presenting or releasing it invalidates every copy of its
token. Call `release(frame)` to abandon an acquisition after any work using it
has completed. Do not access pixels after returning the frame.

Presentation is synchronous: it waits for the supplied render completion, then
changes VI origin during a fresh vertical blank. `render.submit()` submits RDP
commands and, for an RSP-backed render queue, inserts a stable RSP syncpoint.
`geometry.submit()` also synchronizes pending triangle work. The returned
`Completion` supports `poll()`, `isComplete()`, and `wait(.{ .max_attempts = ... })`.
Polling services DP interrupts even while RSP work is pending. A wait reports
`RspTimeout` or `RdpFenceTimeout` and can be retried. Copies of a completed token
stay complete after later submissions (within 2^31 completion markers).

Keep matrices, vertices, command buffers, and the queue itself alive until both
processors complete. A queue must remain at a stable address and must not be
reset while its token is pending. Submission and waiting allocate no memory.
Only one RDP fence and one RSP syncpoint may be outstanding; this API does not
introduce queued frames or multiple in-flight fences. For raw control,
`rdp.syncFull` remains available and `display.presentFence` accepts its fence,
with the caller responsible for separately finishing RSP work.

`.present_mode = .immediate` switches origin as soon as rendering finishes and
may tear. Acquisition uses free buffers immediately and waits only when recycling
a buffer whose scanout has not retired. A retrace during rendering already
satisfies retirement. The default `.vsync` finishes retirement during present.
Both modes poll VI directly and work without enabling CPU interrupts.
`Options.anti_alias_mode` selects VI resampling/fetch behavior, and
`divot_enabled` enables the VI divot filter independently. Polling
does not consume interrupt events. `max_attempts` limits polls, not elapsed time.
A presentation timeout retains the acquisition for retry; complete outstanding
work before releasing it. An acquire timeout does not acquire a frame.

Use `.framebuffer_access = .gpu_only` for frames rendered entirely by the GPU.
This avoids a full-frame cache invalidation on acquisition. Those frames must
not be accessed through cached CPU aliases; the default `.cpu_and_gpu` mode
keeps CPU framebuffer access coherent.

For CPU rendering, fill `frame.image` and use `presentCpu(frame, .{})`, which
writes the pixels back before presentation. Acquire invalidates the buffer's
CPU cache lines so reads see the most recent hardware contents. GPU presentation
does not write back framebuffer cache lines. When combining CPU and RDP writes,
write back CPU changes before submitting GPU commands.

Only one swapchain may control VI at a time. Do not change its buffers, VI
configuration, or origin through the low-level API while it is active. The
swapchain is single-threaded. Complete GPU work before `deinit`; it blanks VI and
waits for a fresh retrace before freeing owned storage. On timeout, storage is
retained and teardown can be retried. Use the same allocator that initialized it.

All existing progressive resolutions, both pixel formats, arbitrary buffer
counts of two or greater, and NTSC/PAL/M-PAL timing selection are supported.
Interlaced resolutions return `UnsupportedResolution`: field-aware interlaced
scanout is not implemented in this manager. The raw VI API remains available for
custom display management. See `examples/src/spinning-cube.zig` in the examples
repository for the owning renderer and swapchain frame loop.

## Render state

Render queues accept complete pipeline values through `getModes`/`setModes` and
`getState`/`setState`. State is compared against the last emitted values before
drawing; there are no public dirty flags. Reapplying the same state emits no
redundant mode commands. Convenience setters update the same tracked values.

```zig
var state = n64.rdp.State.opaque_geometry;
state.modes.antialias_en = false;
render.setState(state);
```

`opaque_geometry`, `translucent_geometry`, and `textured_sprite` are editable
`State` values. They include modes and the combiner; they do not bind textures,
set color registers, or change geometry flags. `withBlend` returns a modified
copy for a custom blender. Use `flushModes` to emit changes explicitly.
`clearScreen`, `clearDepth`, and `drawRect` temporarily use fill mode and restore
the requested modes on the next draw. After bypassing the renderer through
`cmd_queue`, call `invalidateState` to invalidate mode and TMEM tracking. Clearing
a CPU command buffer also invalidates tracking because its commands are discarded.

## RSP runtime, renderer, and optional geometry

Setup is explicit and separate from allocation and display:

```zig
var runtime: n64.rsp.Runtime = undefined;
runtime.init();
var renderer: n64.rdp.Renderer = undefined;
renderer.init(&runtime);
// Sprite and font drawing uses &renderer.render directly.

var geometry: n64.graphics.GeometryEncoder = undefined;
geometry.init(&renderer); // Optional: adds geometry and clipping support.
// Model drawing uses &geometry and shares renderer.render's tracked state.
```

Declare these large objects in persistent application storage. They initialize
in place and must not move after initialization: their queues and overlays
contain pointers into their own storage. `Runtime` loads the built-in resident
program and registers RDP. `Renderer` borrows it and contains the command queue
and two 64 KiB RDP buffers. It does not initialize geometry or allocate a heap.
`graphics.GeometryEncoder` borrows the renderer's queue and render state, registers its
own geometry overlay, and prepares clipping support. Font and sprite examples
need only the first two objects.

Complete pending RSP/RDP work before attaching or detaching geometry. Teardown
order is `geometry.deinit()`, `renderer.deinit()`, `runtime.deinit()`. The renderer
remains usable for 2D drawing after geometry is detached. Only one runtime may
control the hardware, one renderer may attach to it, and one geometry context
may attach to that renderer. Raw RSP programs, queues, overlays, and direct RDP
render queues remain available for custom storage and hardware scheduling.

## Image storage and depth buffers

`graphics.Image(Pixel)` and `graphics.ConstImage(Pixel)` are borrowed views.
`Image(Pixel)` explicitly names the pixel format of a mutable view. Construct a
view with `initBuffer(pixels, width, height)` to validate caller-owned storage, or
use a literal when storage has already been checked. Views never free memory.
Embedded textures, model textures, and font atlases expose `ConstImage` values.
Framebuffer bindings require mutable storage.

`graphics.ImageBuffer(Pixel)` owns an aligned allocation and takes an explicit
allocator for both initialization and teardown:

```zig
var color = try n64.graphics.ImageBuffer(Pixel).init(allocator, width, height);
defer color.deinit(allocator);
var depth = try n64.graphics.DepthBuffer.init(allocator, width, height);
defer depth.deinit(allocator);

render.setFrameBuffer(color.view());
render.setDepthBuffer(depth.view());
render.clearDepth(depth.view(), color.view());
render.clearScreen(Pixel.black);
const completion = render.submit();
try completion.wait(.{});
```

Keep owners alive and do not resize, overwrite, or free their storage until GPU
work completes. Owners are not implicitly copyable: each allocation must be freed
exactly once. `view()` permits CPU mutation; `constView()` exposes read-only texels.
Views do not flush CPU caches. Write back CPU changes before GPU reads and
invalidate cached pixels after GPU writes before reading them on the CPU.

Four-bit image storage holds two logical pixels per element, including across odd
row widths. `get`, `set`, `fill`, and `fillRegion` use logical pixel coordinates
and raw four-bit values for these formats. Allocation rounds odd pixel counts up
to one final pair. The other formats use their native pixel values.

`DepthBuffer` owns hardware packed 16-bit depth values. Its borrowed `depth.Image`
view can also wrap caller-owned 64-byte aligned storage. `setDepthBuffer` and
`clearDepth` require dimensions matching the current framebuffer; `clearDepth`
uses the packed far value and restores the color target. Raw command queues retain
`setDepthImage` for custom hardware scheduling.

## Frame setup

`beginFrame(color, options)` is available on RDP render queues, `rdp.Renderer`, and
`graphics.GeometryEncoder`. It binds borrowed color/depth images, sets a full-target
scissor, and performs only the clears requested by the caller:

```zig
renderer.beginFrame(frame.image, .{
    .depth = depth.view(), // Optional.
    .clear_color = Pixel.black, // Omit to preserve color contents.
    .clear_depth = true, // Defaults to false; requires a depth image.
});
```

Previous GPU work must be complete. The helper clears CPU command storage but
keeps streamed RSP buffers attached. Pipeline state, lights, and geometry settings
persist; no state preset is applied automatically. It does not allocate, submit,
wait, or present. Targets remain borrowed until submission completes. The typed
`rdp.FrameOptions(Pixel)` is available when storing or passing options explicitly.
Individual target, scissor, and clear methods remain available.

A synchronous frame loop can reuse one depth buffer across all swapchain frames:
VI scans color only, and presentation waits for GPU completion before the next
frame starts. Separate depth buffers are useful only when their contents must be
preserved independently.

## Owning geometry renderer

For the standard 3D path, `graphics.Renderer` owns the runtime, RDP renderer, and
geometry context together. It initializes in place without heap allocation:

```zig
var renderer: n64.graphics.Renderer = undefined;
renderer.init();
// Access components directly as renderer.runtime, renderer.rdp, renderer.geometry.
renderer.beginFrame(frame.image, .{ .depth = depth.view(), .clear_depth = true });
renderer.geometry.attachViewport(&viewport);
const completion = renderer.submit();
try completion.wait(.{});
renderer.deinit();
```

Keep it in persistent storage: its components contain pointers to one another and
must not move after initialization. It starts an exclusive RSP session, submits
both geometry and RDP completion markers, and tears down in dependency order.
Complete all borrowed-resource work before teardown. It does not own display,
images, vertices, or application matrices. The individual `rsp.Runtime`,
`rdp.Renderer`, and `graphics.GeometryEncoder` types remain available for applications
that need separate lifetimes or an RDP-only renderer.

## Point lights and generated UVs

Attach the viewport before configuring view-dependent lights. Directional and
point lights share seven consecutively numbered slots, in addition to ambient:

```zig
const g = &renderer.geometry;
g.attachViewport(&viewport);
g.setAmbientLight(.fromBytes(20, 20, 20, 0));
g.setPointLightAt(0, .fromBytes(255, 100, 40, 0), position, 50, false);
g.setPointLightAt(1, .fromBytes(0, 0, 0, 255), camera_position, 1000, false);
g.setLightCount(2);
```

Positions are world-space. Strength uses Tiny3D's distance/falloff parameter,
clamped to 0..4096. Normal-dependent point lighting produces directional falloff;
`ignore_normals = true` instead produces a spherical field. Lighting alpha is
independent of lighting RGB and can drive cutouts, reveals, and Fresnel in the
combiner.
`Viewport.setOrthographic(left, right, bottom, top, near, far)` supports
orthographic camera projection alongside perspective.

`Material.vertex_effect = .{ .spherical = .{ .width = 32, .height = 32 } }`
generates reflection UVs in the RSP. `.none` restores source UVs. Imported legacy
Fast64 texture-generation metadata sets this automatically, including a reset
when the following material uses ordinary UVs. Custom draws can call
`Context.setVertexEffect` directly. `Material.blend` accepts an explicit
`rdp.BlendMode` override for effects such as blending against the blend-color
register. `rdp.BlendMode.additive` adds into the framebuffer but wraps, rather
than saturates, on overflow. A texture pair can reuse the same texels in TMEM with separate tile
shifts and offsets; `useTexturePair` uploads identical images once.

## Drawing model data

Models contain packed parts; generated `n64.graphics.ModelAsset(Materials)` values pair that
geometry with a typed material provider. They carry no renderer or drawing
methods. Submit model draws through the geometry context:

```zig
renderer.geometry.drawModel(assets.model);
renderer.geometry.drawModelWithTransform(assets.model, &model_matrix);
// For custom material bindings:
renderer.geometry.drawModelWithMaterials(assets.model.model, MyMaterials{});
```

`drawModelWithTransform` queues push/draw/pop, restoring the previous matrix while
leaving material/pipeline changes visible. The matrix is borrowed, not copied;
keep it unchanged and alive until RSP/RDP completion. Neither draw method submits,
waits, or allocates. Custom providers implement `apply(context, material_index)`;
texture types remain known at compile time. `asset.material(index)` still reads
native material metadata. Use `GeometryEncoder.drawModelWithMaterials` for a custom material provider.

## Skeletons and animation

Generated model data exposes `nodes`, `skins`, and `animations`. The
`graphics.animation` module keeps these immutable definitions separate from
mutable instances:

```zig
const animation = n64.graphics.animation;
var skeleton = try animation.Skeleton.init(allocator, assets.snake.model.nodes);
defer skeleton.deinit(allocator);
var player: animation.Player = .{ .clip = &assets.snake.model.animations[0] };
var mesh = try n64.graphics.SkinnedModel.init(allocator, assets.snake.model);
defer mesh.deinit(allocator);

player.update(&skeleton, delta_seconds);
skeleton.update();
mesh.update(&skeleton);
renderer.geometry.drawModelWithMaterials(mesh.model(), assets.snake.materials);
const completion = renderer.submit();
try completion.wait(.{});
```

`Skeleton.bones` holds editable local translation, quaternion rotation, and
scale. `reset()` restores the rest pose; `findBone(name)` returns a node index.
`update()` calculates global matrices, including transformed ancestors, without
allocation. Node ordering need not place parents before children; initialization
rejects invalid parents and cycles. A global matrix from `skeleton.matrices[i]`
can attach another model to that node after conversion with `toFixed3x4()`.
Keep the fixed attachment matrix alive until GPU completion.

Each `Player` has independent time, speed, playing, and looping state. `seek()`
clamps to the clip's duration, and `apply()` samples the current time.
`update(skeleton, delta)` advances when playing and applies even while paused,
so seeking a paused clip updates its pose. Looping handles multiple wraps and
negative playback; a nonlooping clip stops on its final pose. Only targeted
properties change. Applying another player later overrides the properties it
targets. Tracks support step, linear (spherical quaternion interpolation), and
cubic Hermite interpolation. Cubic quaternion results are normalized.

To blend animations, initialize a second skeleton from the same nodes, sample
another player into it, then call `skeleton.blend(&skeleton, &other, factor)`
before `skeleton.update()`. The destination can alias either source. Blend
factors are clamped to 0–1, and rotations use normalized shortest-path blending.

`SkinnedModel` allocates writable packed vertex copies and per-skin position
and normal palettes once. The normal palette uses an additional 64 bytes per
joint to cache inverse-transpose transforms for single-joint vertices. Initialization rejects invalid skin indices, vertex/influence counts,
joint references, and weights. Use a skeleton created from the same model nodes.
`update()` performs CPU skinning with all four joint weights and inverse
bind matrices, including inverse-transpose normals of the blended vertex transform for
nonuniform scale. The
original asset stays untouched. UVs, colors, materials, and triangle topology
are preserved, and draws use the dynamic cache-writeback path. This initial
implementation spends CPU time and writable memory on skinning; it does not
submit a separate RSP skinning job.

For first-joint assets (`addModel(..., .{ .skinning = .first_joint })`), retain
immutable bind-local vertices and use the geometry RSP instead:

```zig
const pose = try allocator.alloc(n64.math.FixedMat4, skeleton.matrices.len);
// Reuse or free pose only after GPU completion.
skeleton.writeMatrices(pose);
renderer.geometry.setPose(pose);
renderer.geometry.drawModelWithMaterials(assets.snake.model, assets.snake.materials);
```

`setPose` writes back the fixed matrices and selects the pose for subsequent
draws. Parts load each joint group under its bone matrix before drawing
mixed-joint triangles. Recorded model blocks use relative bone addresses, so
they can replay against a different pose buffer each frame. Choose this contract
explicitly: first-joint conversion ignores the other influences and weights,
and `SkinnedModel.init` rejects these parts. The weighted default is unchanged.

Wait for completion before updating or freeing a mesh instance. Alternatively,
keep one instance per application frame slot and reuse it only after that slot's
GPU work completes. Skeleton transforms may change after CPU skinning, but
queued fixed matrices, vertices, and textures retain the usual borrowed-resource
lifetime. `Skeleton` and `SkinnedModel` own allocations; free each instance once
with `deinit()` and keep their immutable source model alive throughout.

## Controller snapshots

`input.Controllers` owns fixed, aligned storage for all four ports. Initialization
and polling allocate nothing and finish SI DMA before returning. Systems and
snapshots are movable, but only one system or raw Joybus transaction may use SI
at a time. No teardown is required.

```zig
var controllers = n64.input.Controllers.init();
controllers.poll();
const input = controllers.get(.one);
if (input.pressed(.a)) jump();
if (input.held(.r)) accelerate();
if (input.released(.z)) stopCharging();
const horizontal = input.state.stick_x;
```

`Button` is an enum; held/pressed/released exclude axes and reserved PIF bits.
Edges remain stable until the next poll. Failed or absent-device reads produce
neutral input and release previously held buttons. `refresh()` updates controller
styles after hot-plugging. Raw `State` preserves the hardware's packed response
layout. This replaces the global joypad array, allocator-based initialization,
and manual previous-state comparisons.

## Time and FPS

`time.Instant.now()` reads Count; `later.since(earlier)` returns a `Duration`.
`Duration.seconds()`, `milliseconds()`, and `nanoseconds()` provide conversions.
`Timer.start()`, `read()`, `reset()`, and `lap()` follow the usual timer pattern:

```zig
var timer = n64.time.Timer.start();
var fps = n64.time.FpsCounter.init(.{ .refresh_rate = 60 });
const elapsed = timer.lap();
update(elapsed.seconds());
const filtered_fps = fps.update(elapsed);
```

Count wraps about every 91.6 seconds. Differences handle one wrap; read/lap before
a full counter period elapses. These are interval timers, not a persistent wall
clock, and require no interrupts. FPS filtering is separate from the timer.
Omit `refresh_rate` for immediate presentation; set it to the display's refresh
rate when whole refresh intervals are appropriate. `smoothing` and `initial_fps`
are explicit options.

## Formatted text and debug output

`Font.drawPrint` formats into caller-provided scratch storage and draws through
the same font API. Formatting overflow returns `NoSpaceLeft` before any render
commands are emitted. Scratch can be reused immediately after the call; font
atlas storage remains borrowed until GPU completion.
Outlined monochrome assets use `.format = .mono_outline` in `addFont` and
CI4 atlases with two IA16 palette banks. `TextOptions.color` and `outline_color`
control fill and outline independently. Integer placement uses one rectangle per
glyph; scaling and fractional placement use the general sprite path.

```zig
var text: [64]u8 = undefined;
_ = try assets.console.drawPrint(render, 16, 20, &text, .{}, "FPS: {d:.2}", .{fps});
```

`debug.init()` detects a backend. `debug.print` uses a local 256-byte formatting
buffer, with no heap initialization or shared formatting storage. Oversized
messages emit their buffered prefix and `[truncated]`. `debug.writeAll` remains
the raw path for panic handling. The exception module is `cpu.exception` and
backend enum tags are `none`, `is_viewer`, and `sc64`.

## Model overrides and writable instances

Generated model assets expose declarative overrides while retaining typed texture
bindings, imported pipeline state, and embedded textures on unmodified materials:

```zig
const map = assets.map.withOverrides(.{
    .{ .fog = false }, // No index: apply to every material.
    .{ .index = 0, .texture = assets.sand },
    .{ .index = 1, .texture = assets.stone, .no_light = true },
});
renderer.geometry.drawModelWithTransform(map, &matrix);
```

Entries are a heterogeneous tuple. They may contain any `Material` field, a full
`material` replacement, `no_light`, and a typed `texture`. `second_texture` binds
a pair and requires `texture` in the same entry. Imported samplers are retained
unless overridden. Anonymous nested structs such as `.sampler = .{ .mask_s = 5 }`
patch only their named fields; explicitly typed values replace the whole field.
Binding textures preserves the material's draw flags and
combiner: override those explicitly when adding texturing to an untextured source.
Later entries win; an omitted index affects all materials. Repeated
`withOverrides` calls compose and retain earlier texture bindings.
`asset.material(index)` reads the resulting state. Generated providers implement
`get(index)` and `bind(context, index, material)`; custom draw providers can still
implement just `apply(context, index)`.

`withModel(model)` replaces borrowed geometry while retaining the asset's
material provider. Use it for both skinned and otherwise mutable instances:

```zig
var mesh = try n64.graphics.MutableModel.init(allocator, assets.lava.model);
defer mesh.deinit(allocator);
var vertices = mesh.vertices(0).iterator();
while (vertices.next()) |vertex| vertex.position[1] = 20;
renderer.geometry.drawModel(assets.lava.withModel(mesh.model()));
const completion = renderer.submit();
try completion.wait(.{});
```

`MutableModel` copies vertex storage, borrows node/skin/animation metadata and
triangle topology, and marks its parts dynamic. Draws perform cache writeback;
application code does not cast away source constness or manually flush the mesh.
`vertices(part_index).get(index)` and `iterator().next()` expose logical vertices,
including odd vertex counts without exposing the final pair's padding. References
contain position, normal, color, and UV pointers. `reset()` restores source data.
Wait for GPU completion before changing, resetting, or freeing an instance.
Models draw through the geometry context; `SkinnedModel.draw` has been removed.
`Model.findAnimation(name)` returns an optional borrowed clip pointer.

All allocator-owned runtime image/model/skeleton types now accept the original
allocator in `deinit(allocator)`; they do not retain an allocator internally.
Renderers/runtime retain their allocation-free in-place initialization and
stable-address requirement.


`Material.z_mode` can override the surface depth comparison (for example, a
coplanar translucent decal). `depth_test` and `depth_write` switch the RDP's Z
compare and update without changing the RSP triangle format or lighting, unlike
clearing `flags.depth`. `Material.bind` resolves spherical-map dimensions
and bounds power-of-two wrap masks to the externally supplied image. Explicit
low-level `useTextureSampler` bindings retain the caller's exact tile settings.
