//! Small finite ROM for checking host deployment and debug transport boundaries.
const n64 = @import("n64");
pub fn main() !void {
    n64.debug.init();
    n64.debug.writeAll("DEPLOY_SMOKE_BEGIN\n");
    n64.debug.writeAll("x" ** 513 ++ "\n");
    n64.debug.writeAll("DEPLOY_SMOKE_END\n");
    n64.debug.finish(.success);
    while (true) {}
}
