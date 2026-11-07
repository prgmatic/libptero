# ptero-deploy

`zig build install` installs `zig-out/bin/ptero-deploy`. It uploads ROMs to
SummerCart64 and EverDrive 3.0/X7, or launches ares, and relays debug text to
stdout. Cartridge protocols are implemented in Zig; no uploader executable is
needed. Linux and macOS use the libftdi1 shared library for USB access. Linux is
the hardware-verified host. Install libftdi1 and grant your user access to the
USB device; ares runs do not load that library.

```sh
ptero-deploy --target sc64 game.z64
ptero-deploy --target everdrive --serial A1234567 game.z64
ptero-deploy --target ares game.z64
ptero-deploy --target ares --wait --timeout-ms 60000 game.z64
ptero-deploy --target sc64 --test zig-out/tests.z64
```

ROM arguments are paths relative to the current directory. Big-endian `.z64`,
byte-swapped `.v64`, and little-endian `.n64` ROMs are validated; USB uploads
normalize the byte order in memory. The source file is never modified.

SC64 supports ROMs up to 78 MiB, including flash-backed shadow and extended ROM
regions, firmware 2.20+, direct boot, automatic IPL3 signing, and an optional
`--cic-seed`. Upload with the N64 off, then power it on. Without power control,
the tool stays attached while you switch on the console. It cannot physically
reset or power the console over the cartridge USB connection.

EverDrive supports the same models as UNFLoader: **EverDrive 3.0 and X7**, up to
64 MiB. The console must be on in its EverDrive OS menu before upload. OS 3.04+
is required; UNFLoader documents OS 3.07+ as incompatible with the 3.0 model.
X5 and 2.5 lack the required USB support. Core automatically detects the 3.0/X7
debug interface; text uses USB+Debug v2 framing. EverDrive hardware validation
is still needed; host tests verify its upload and packet protocols.

Use `--serial` to select an FTDI serial number or `--device-index` to select
the zero-based matching device. SC64 matches USB 0403:6014 / `SC64`; EverDrive
matches 0403:6001 / `FT245R USB FIFO`. `--save` selects cartridge save hardware;
the EverDrive path writes the ED save header in the upload copy and transmits
a bounded save filename. `sram1m` is SC64-only. This deploy tool's scope is ROM
upload, debug listening and run control; SD-card management, firmware updates,
save-file transfer and a GDB server remain separate tools.

## Run completion

ROMs initialize debug and report completion through the public API:

```zig
n64.debug.init();
// Work and ordinary logging...
n64.debug.finish(.success);
// Or: n64.debug.finish(.failure);
// Or: n64.debug.finish(.{ .tests = .{ .passed = 120, .failed = 0 } });
```

`finish` is allocation-free, sends a complete record, and returns. The host
then exits ares or powers down a managed console. Call it from normal execution,
not an interrupt. When no debug backend is available it has no effect. The ROM
should stop changing results after reporting completion.

The wire record is `@@LIBPTERO_RUN_END@@` followed by JSON with `code` (0 or 1),
`passed`, and `failed`, then a newline. Its definition and encoder live in
`src/n64/debug/run_protocol.zig`. Tests, examples and benchmarks use the API
instead of embedding marker strings. Historical benchmark comparison scripts
also accept their older completion records when reading saved logs.

The default interactive mode relays output until completion or Ctrl-C. A normal
ares window close also ends an interactive run. `--wait` requires completion
within `--timeout-ms` (30 seconds by default); `--test` requires completion and
ignores `--timeout-ms`: on hardware it uses a one-second startup deadline plus
200 ms per test, and on ares 20 seconds plus 10 seconds per test, since the
emulator takes seconds to start and runs RSP/RDP work slower than the console.
A `[Run] ` prefix at the start of a line refreshes the test deadline before its
trailing newline. Diagnostic output does not extend it. Override either with
`--startup-timeout-ms` and `--test-timeout-ms`.

Exit codes are 0 for successful completion, 1 for a reported ROM failure, 2 for
upload/protocol/timeout/power failures, and 130 for interruption. A child exiting
without completion is an error in wait/test mode. Overlong ordinary log lines
are relayed without breaking completion parsing; malformed completion records
are errors. The listener handles split records and strips USB text NUL padding.

ares supports both a normal interactive window and automated termination on
completion. It needs a working graphical display (an external virtual display
may be used on CI). `--ares` selects its executable. The launcher inspects
`--dump-all-settings` to select the version's homebrew setting. It captures
ISViewer output and sets `Input/Defocus=Block` so automation continues without
window focus. It owns only the emulator process it starts; it cleans that
process up on completion, timeout and interruption.

## Optional Home Assistant power control

Provide a URL, entity and token to enable power management. Tokens can come from
`PTERO_HA_TOKEN` or a file named by `--ha-token-file`. Tokens are never printed.
HTTP service calls use JSON escaping and refuse redirects. Ares rejects power
settings so an emulator run cannot inadvertently switch the physical console.

```sh
ptero-deploy --config deploy.local.json --test zig-out/tests.z64
ptero-deploy --config deploy.local.json power-on
ptero-deploy --config deploy.local.json power-off
```

Example `deploy.local.json` (keep machine configuration and tokens out of Git):

```json
{
  "target": "sc64",
  "ha_url": "http://homeassistant.local:8123",
  "ha_entity": "switch.n64",
  "ha_token_file": "token.txt",
  "power_delay_ms": 1500
}
```

`--config` or `PTERO_DEPLOY_CONFIG` selects JSON defaults. CLI flags override
them. Unknown keys are errors. A token path in JSON is relative to that JSON
file; CLI paths are relative to the working directory. `PTERO_HA_TOKEN` takes
precedence over a token file.

SC64 sequencing is power off, wait, upload while attached, then power on.
EverDrive sequencing is power on, wait for its menu, then upload and boot.
`--power-delay-ms` controls the initial settling/menu wait. Managed runs power
off on completion, failure, timeout and Ctrl-C. `--keep-on` leaves power on only
after a successful completed run. Signal handlers only record cancellation;
normal cleanup performs HTTP and closes USB/process resources. Power-off
failures are reported explicitly.

## Implementation and verification

`main.zig` owns process exit and diagnostics through `cli.zig`; `root.zig`
exposes protocol clients, ROM validation, configuration and the run monitor.
`stream.zig` is the injectable transport boundary. `sc64.zig`, `everdrive.zig`
and `packet.zig` own wire behavior; `ftdi.zig` owns USB library access. Lifecycle,
emulator and power control have separate modules.

Behavioral references:

- [UNFLoader](https://github.com/buu342/N64-UNFLoader), especially
  `device_everdrive.cpp`, `device_sc64.cpp`, and the IPL2 checksum algorithm in
  `device.cpp` (WTFPL).
- [SummerCart64](https://github.com/Polprzewodnikowy/SummerCart64), protocol
  behavior and command documentation used by `sw/deployer`.
- [ares](https://github.com/ares-emulator/ares), ISViewer and CLI behavior.

```sh
zig build test
zig build install tests deploy-smoke
ptero-deploy --target ares --wait zig-out/deploy-smoke.z64
ptero-deploy --config deploy.local.json --test zig-out/tests.z64
/home/mt/dev/zcrap/zig-out/bin/zcrap --coverage --project . --threshold 6 tools/deploy
```

The small `deploy-smoke` ROM emits a 513-byte text line and a successful
completion record, exercising debug buffer boundaries without graphics or
audio. Host tests cover fragmented USB transfers, packet validation, cartridge
command sequences, completion parsing, test deadlines, child-process cleanup,
configuration precedence and power lifecycle behavior.
