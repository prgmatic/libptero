const n64 = @import("n64");

export fn __start() linksection(".text.startup") void {
    n64.debug.init(.IsViewer);
    n64.io.is_viewer.print("hello from n64\n");
}
