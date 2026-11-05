//! Host microcode workload tests and the baseline regression gate.
test {
    _ = @import("workloads.zig");
    _ = @import("baseline.zig");
    _ = @import("coverage.zig");
}
