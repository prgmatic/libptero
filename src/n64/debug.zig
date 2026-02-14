const io = @import("io.zig");

pub const Backend = enum(u8) {
    None,
    IsViewer,
};

pub var current_backend = Backend.None;

pub fn init(backend: Backend) void {
    current_backend = backend;
}

