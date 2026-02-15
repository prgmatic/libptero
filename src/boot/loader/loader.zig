const n64 = @import("n64");

var print_buffer: [0x200]u8 = undefined;

export fn __start() linksection(".loader") callconv(.c) noreturn {

    n64.io.is_viewer.print("hello\n");
    n64.io.is_viewer.print("hello2\n");
    while (true) {
    }
    undefined;
}
