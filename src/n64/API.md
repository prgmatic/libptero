# Finding an API

Import the runtime with `const n64 = @import("n64");`. Lowercase namespaces group
related operations. Types use TitleCase and functions use camelCase. Concrete
file structs live in matching files: `audio.Player` is `audio/Player.zig`.
Generic families live in lowercase files, such as `graphics/image.zig` and
`display/swapchain.zig`. Supporting enums and options stay beside their owner.

| Namespace | Start here | Purpose |
| --- | --- | --- |
| `n64.App(config)` | [app.zig](app.zig) | Coordinated display, input, timing, frame passes and submission |
| `graphics` | [graphics.zig](graphics.zig) | Visual data, materials, fonts, geometry and animation |
| `display` | [display.zig](display.zig) | Framebuffer acquisition and presentation |
| `audio` | [audio.zig](audio.zig) | Resident/streamed playback, mixing and output |
| `input` | [input.zig](input.zig) | Controller snapshots and raw Joybus transactions |
| `rom` | [rom.zig](rom.zig) | Cartridge regions, typed assets and scheduled loading |
| `rsp` | [rsp.zig](rsp.zig) | Programs, overlays, queues and execution control |
| `rdp` | [rdp.zig](rdp.zig) | Command encoding, render state, textures and completion |
| `pi` | [pi.zig](pi.zig) | Cache-aware, bounded cartridge DMA |
| `cpu` | [cpu.zig](cpu.zig) | CPU operations, CP0, cache, addressing and exceptions |
| `hw` | [hw.zig](hw.zig) | Raw MI, VI, AI, PI, SI, SP and DP registers |
| `interrupt` | [interrupt.zig](interrupt.zig) | Interrupt dispatch, hooks, masks and waiting |
| `math` | [math.zig](math.zig) | Vectors, matrices, quaternions and frusta |
| `time` | [time.zig](time.zig) | Instants, durations, timers and frame-rate measurement |
| `debug` | [debug.zig](debug.zig) | Output, crash UI, source maps, diagnostics and profiling |

## Choose an owner

- `App(config)` owns display buffers, input polling, timing and rendering. Use
  `App.Options`, `App.FrameOptions`, `App.GeometryPass.Options` and
  `App.OverlayPass.Options`. Pass state types are `GeometryPass.State` and
  `OverlayPass.State`. See [the frame-loop guide](app/README.md).
- `graphics.Renderer` owns an `rsp.Runtime`, an `rdp.Renderer`, and a
  `graphics.GeometryEncoder`. It leaves display and input to the application.
- `rdp.Renderer` owns command storage and borrows an `rsp.Runtime`.
- `graphics.GeometryEncoder` borrows an `rdp.Renderer` and adds geometry recording.
- `audio.Player` owns its mixer/output and borrows an `rsp.Runtime`.

These hardware owners initialize in place. Keep their addresses stable and
complete pending work before teardown. Renaming these types did not change
allocation, synchronization, borrowing, or cache-coherency requirements.

## Data and configuration

`graphics.Image(Pixel)` and `ConstImage(Pixel)` are borrowed views;
`ImageBuffer(Pixel)` owns allocated storage. `DepthImage` and `DepthBuffer` follow
the same distinction. Pixel types live in `graphics.pixel`, including indexed
and intensity formats. Use `Image(pixel.Rgba16)` rather than a format alias.

`graphics.Model` holds borrowed geometry and metadata. Its supporting types are
`Model.Part` and `Model.DataUsage`. `ModelAsset` pairs a model with a
`[]const Material` table; every model shares this type. `Texture` is the
format-erased image reference that materials store. Draw through `GeometryEncoder`; use `MutableModel` or
`SkinnedModel` when writable instance storage is needed. Animation definitions
and playback live in `graphics.animation`.

`graphics.Font` exposes `DrawOptions`, `Metrics`, `Range`, `Glyph`, `Kerning` and
`Ellipsis`. `Material`, `Light`, `Lighting`, and `Fog` live directly in `graphics`.

Options belong to their type: `audio.Player.Options`, `Player.PlayOptions`,
`Player.UpdateOptions`, `display.Swapchain(Pixel).Options`,
`Swapchain(Pixel).PresentOptions`, `rom.Scheduler.Options`, and
`time.FpsCounter.Options`. `input.Snapshot.Options` configures normalized stick
reads. Controller identification is `Snapshot.device_type` / `input.DeviceType`.

`rom.Region` describes raw cartridge bytes. `rom.Asset(Definition)` is a typed
asset descriptor; its `Loaded` type owns or borrows RAM storage explicitly.
`rom.Slot(assets)` manages a reusable loading slot. Asset generators emit these
public types directly. Loaded owners expose `LoadOptions` and `WaitOptions`;
`load(.{})` returns the borrowed native value, while `wait(.{})` finishes a
previously started transfer. Their default polling budget is 1,000,000 attempts.

`audio.Sample` borrows resident PCM. `audio.RomSample` describes cartridge audio
that can be streamed through `audio.Stream` or loaded through the generic
`rom.LoadedAsset` lifecycle (PCM only for RAM loading).

## Explicit command encoding

Most callers use a renderer. Custom storage and scheduling use two generic
layers: `rdp.CommandEncoder(Backend)` encodes raw commands;
`rdp.RenderEncoder(Backend)` adds tracked rendering state and drawing helpers.

| Backend | Behavior |
| --- | --- |
| `rdp.backend.Direct` | CPU command buffer submitted directly to DP |
| `rdp.backend.RspSubmitted` | CPU command buffer scheduled through the resident RSP queue |
| `rdp.backend.Overlay` | Commands sent through the RDP overlay with state/address fixups |

The streaming RSP queue is `rsp.Queue`; explicit recorded command storage is
`rsp.CommandBuffer`. Microcode is an `rsp.Program`, with built-ins in
`rsp.programs`. `rdp.Fence` tracks DP completion; `rdp.Completion` also accounts
for RSP work. Neither completion type owns the submitted resources.

## Migration from the previous namespaces

| Previous name | Current name |
| --- | --- |
| `context.Context(config)` | `App(config)` |
| `context.Config` | `AppConfig` |
| `graphics.Renderer` | `rdp.Renderer` |
| `graphics.geometry.Context` | `graphics.GeometryEncoder` |
| `graphics.geometry.Renderer` | `graphics.Renderer` |
| `graphics.geometry.Viewport`, `VertexPair`, etc. | `graphics.Viewport`, `VertexPair`, etc. |
| `graphics.model.Model`, `Material`, etc. | `graphics.Model`, `Material`, etc. |
| `graphics.model.Asset(Materials)` | `graphics.ModelAsset` |
| `graphics.font.Font` | `graphics.Font` |
| `font.TextOptions`, `font.TextMetrics` | `Font.DrawOptions`, `Font.Metrics` |
| `graphics.image.Image(Pixel)` | `graphics.Image(Pixel)` |
| `graphics.color` | `graphics.pixel` |
| `graphics.rdp` | `rdp` |
| `io.joypad.System` | `input.Controllers` |
| `io.joybus`, `io.pi` | `input.joybus`, `pi` |
| `cache` | `cpu.cache` |
| `interfaces.video`, `audio`, `parallel`, `serial`, `mips` | `hw.vi`, `ai`, `pi`, `si`, `mi` |
| `interfaces.rdp`, `rsp.io` | `hw.dp`, `hw.sp` |
| `rsp.UCode`, `rsp.Ucode` | `rsp.Program` |
| `rsp.runUCode` | `rsp.runProgram` |
| `rsp.CommandQueue` | `rsp.CommandBuffer` |
| `rsp.physicalAddress` | `cpu.physicalAddress` |
| `rom.Asset`, `rom.TypedAsset(T)` | `rom.Region`, `rom.Asset(T)` |
| `audio.mixer.Mixer`, `audio.output.Output` | `audio.Mixer`, `audio.Output` |
| `debug.exception`, `debug.TrapFrame` | `cpu.exception`, `cpu.exception.TrapFrame` |
| `debug.srcmap`, `debug.writeStr` | `debug.source_map`, `debug.writeAll` |
| `debug.sc64`, `everdrive`, `is_viewer` | `debug.backends.sc64`, `everdrive`, `is_viewer` |
| `math.fastSin`, `fastCos`, `fastMod` | `math.fast.sin`, `cos`, `mod` |

The previous compatibility aliases are removed. Update generated assets by
rebuilding them with the matching SDK. Serialized assets and hardware command
formats are unchanged.
