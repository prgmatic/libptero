const std = @import("std");
const deploy = @import("deploy");
pub fn main(init: std.process.Init) void {
    const code = deploy.cli.run(init) catch |err| deploy.cli.report(err);
    std.process.exit(code);
}
