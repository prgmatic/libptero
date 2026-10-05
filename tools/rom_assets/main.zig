const std = @import("std");
const assets = @import("rom_assets");
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("usage: rom-assets <payload.bin> <handles.zig> [<name> <file>]...\nrom-assets: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn run(init: std.process.Init) !void {
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    if (args.len == 1 or (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")))) {
        std.debug.print("usage: rom-assets <payload.bin> <handles.zig> [<name> <file>]...\n", .{});
        return;
    }
    const count = try inputCount(args);
    const inputs = try a.alloc(assets.Input, count);
    defer a.free(inputs);
    try loadInputs(init.io, a, args[3..], inputs);
    defer freeInputs(a, inputs);
    const result = try assets.pack(a, inputs);
    defer result.deinit(a);
    try writeFile(init.io, args[1], result.data);
    try writeFile(init.io, args[2], result.source);
}
fn inputCount(args: []const []const u8) !usize {
    if (args.len < 3) return error.Usage;
    if ((args.len - 3) % 2 != 0) return error.Usage;
    return (args.len - 3) / 2;
}
fn freeInputs(a: std.mem.Allocator, inputs: []const assets.Input) void {
    for (inputs) |input| a.free(input.data);
}
fn loadInputs(io: std.Io, a: std.mem.Allocator, args: []const []const u8, inputs: []assets.Input) !void {
    var loaded: usize = 0;
    errdefer freeInputs(a, inputs[0..loaded]);
    for (inputs, 0..) |*input, index| {
        input.* = .{ .name = args[index * 2], .data = try readFile(io, a, args[index * 2 + 1]) };
        loaded += 1;
    }
}
test "CLI validates name/file pairs and permits an empty payload" {
    try std.testing.expectError(error.Usage, inputCount(&.{"rom-assets"}));
    try std.testing.expectError(error.Usage, inputCount(&.{ "rom-assets", "data", "zig", "missing" }));
    try std.testing.expectEqual(@as(usize, 0), try inputCount(&.{ "rom-assets", "data", "zig" }));
    try std.testing.expectEqual(@as(usize, 1), try inputCount(&.{ "rom-assets", "data", "zig", "clip", "file" }));
}
fn readFile(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(a, .limited(64 * 1024 * 1024));
}
fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
