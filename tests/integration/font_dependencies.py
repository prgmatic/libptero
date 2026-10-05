"""Exercise AssetBundle caching when only a referenced font page changes."""
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib


def png(pixel):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b'\0' + bytes(pixel))) + chunk(b'IEND', b''))


with tempfile.TemporaryDirectory(prefix='ptero-font-') as directory:
    root = pathlib.Path(directory)
    core = os.path.relpath(pathlib.Path(sys.argv[2]).resolve(), root)
    (root / 'build.zig.zon').write_text('.{ .name = .font_dependency_test, .version = "0.0.0", '
        '.fingerprint = 0x35015cf9354bc424, .dependencies = .{ .libptero = .{ .path = "' + core + '" } }, .paths = .{""} }')
    (root / 'build.zig').write_text('''const std = @import("std");
const ptero = @import("libptero");
pub fn build(b: *std.Build) void {
    var sdk = ptero.init(b, .{ .target = b.graph.host, .builtin_rsp_programs = false, .console_font = false });
    var assets = sdk.createAssets("assets");
    assets.addFont("font", b.path("font.fnt"), .{});
    const exe = b.addExecutable(.{ .name = "check", .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"), .target = b.graph.host,
        .imports = &.{.{ .name = "assets", .module = assets.createModule() }},
    }) });
    b.step("run", "Read converted pixel").dependOn(&b.addRunArtifact(exe).step);
}
''')
    (root / 'main.zig').write_text('''const std = @import("std");
pub fn main() void {
    const font = @import("assets").font;
    const pixel = std.mem.readInt(u16, std.mem.asBytes(&font.atlases[0].texel_data[0]), .big);
    std.debug.print("PIXEL={x}\\n", .{pixel});
}
''')
    (root / 'font.fnt').write_text('''info face="fixture" size=1
common lineHeight=1 base=1 scaleW=1 scaleH=1 pages=1 packed=0
page id=0 file="font page.png"
chars count=1
char id=46 x=0 y=0 width=1 height=1 xoffset=0 yoffset=0 xadvance=1 page=0 chnl=15
''')
    outputs = []
    for pixel in [(255, 0, 0, 255), (0, 255, 0, 255)]:
        (root / 'font page.png').write_bytes(png(pixel))
        result = subprocess.run([sys.argv[1], 'build', 'run'], cwd=root, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        outputs.append(result.stderr)
    assert 'PIXEL=f801' in outputs[0], outputs
    assert 'PIXEL=7c1' in outputs[1], outputs
print('Font page-only edit rebuilt the typed asset (including a path with spaces).')
