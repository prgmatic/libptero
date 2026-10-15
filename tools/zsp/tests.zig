//! Host test entry point; build/tests.zig instruments this complete suite.
test {
    _ = @import("compiler.zig");
    _ = @import("modules.zig");
    _ = @import("options.zig");
    _ = @import("tests/analysis.zig");
    _ = @import("tests/optimizer.zig");
    _ = @import("tests/vectors.zig");
    _ = @import("tests/memory.zig");
    _ = @import("tests/commands.zig");
    _ = @import("tests/control_flow.zig");
    _ = @import("tests/calls.zig");
    _ = @import("tests/parser.zig");
    _ = @import("tests/scalar.zig");
}
