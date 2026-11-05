//! Converts a linked RSP ELF into libptero's `.rsp` image, optionally
//! writing a memory map or a Zig module of symbol addresses.
const std = @import("std");
const elf_file = @import("elf_file.zig");
const symbols = @import("symbols.zig");

pub const pack = @import("image.zig").pack;

pub const usage = "usage: rsp_pack <input.elf> [--map <output.map> | --symbols <output.zig>] <output.rsp>\n";

pub const Listing = enum { map, symbols };

pub const Options = struct {
    input: []const u8,
    output: []const u8,
    listing: ?struct { kind: Listing, path: []const u8 } = null,
};

/// Arguments exclude argv[0].
pub fn parseArgs(args: []const []const u8) ?Options {
    if (args.len == 2) return .{ .input = args[0], .output = args[1] };
    if (args.len != 4) return null;
    const kind = listingFlag(args[1]) orelse return null;
    return .{ .input = args[0], .output = args[3], .listing = .{ .kind = kind, .path = args[2] } };
}

fn listingFlag(arg: []const u8) ?Listing {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    return std.meta.stringToEnum(Listing, arg[2..]);
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    const options = parseArgs(args) orelse return error.InvalidArguments;
    const cwd = std.Io.Dir.cwd();
    const elf_bytes = try cwd.readFileAlloc(io, options.input, allocator, .unlimited);
    defer allocator.free(elf_bytes);
    const image = try pack(allocator, elf_bytes);
    defer allocator.free(image);
    if (options.listing) |listing| try writeListing(allocator, io, elf_bytes, listing.kind, listing.path);
    try cwd.writeFile(io, .{ .sub_path = options.output, .data = image });
}

fn writeListing(allocator: std.mem.Allocator, io: std.Io, elf_bytes: []const u8, kind: Listing, path: []const u8) !void {
    const file = try elf_file.File.parse(elf_bytes);
    const sections = try elf_file.Sections.find(file);
    const found = try symbols.collect(allocator, file, sections);
    defer allocator.free(found);
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    switch (kind) {
        .map => try symbols.formatMap(&text.writer, sections, found),
        .symbols => try symbols.formatModule(&text.writer, found),
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.written() });
}

const testing = std.testing;
const test_elf = @import("test_elf.zig");

test {
    _ = @import("commands.zig");
    _ = @import("image.zig");
    _ = @import("symbols.zig");
}

test "arguments name an input, an optional listing, and an output" {
    try testing.expectEqualStrings("out.rsp", parseArgs(&.{ "in.elf", "out.rsp" }).?.output);
    const listed = parseArgs(&.{ "in.elf", "--symbols", "s.zig", "out.rsp" }).?;
    try testing.expectEqual(Listing.symbols, listed.listing.?.kind);
    try testing.expectEqualStrings("s.zig", listed.listing.?.path);
    try testing.expectEqual(@as(?Options, null), parseArgs(&.{ "in.elf", "-map", "m", "out.rsp" }));
    try testing.expectEqual(@as(?Options, null), parseArgs(&.{ "in.elf", "--other", "m", "out.rsp" }));
    try testing.expectEqual(@as(?Options, null), parseArgs(&.{"in.elf"}));
    try testing.expectError(error.InvalidArguments, run(testing.allocator, testing.io, &.{}));
}

test "packing writes the image with a symbol module or a memory map" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const strings = "\x00start\x00table\x00.hidden\x00limit\x00";
    const entries = test_elf.symbol(1, 0x1000, 1) ++ test_elf.symbol(7, 0x20, 2) ++
        test_elf.symbol(13, 0x1000, 1) ++ test_elf.symbol(21, 0x1004, std.elf.SHN_ABS) ++ test_elf.symbol(1, 0, 0);
    const bytes = try test_elf.build(testing.allocator, 0x1000, &.{
        .{ .name = ".text", .addr = 0x1000, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .name = ".data", .addr = 0x20, .data = &.{ 1, 2, 3, 4, 5, 6, 7, 8 } },
        .{ .name = ".symtab", .type = std.elf.SHT_SYMTAB, .data = &entries, .link = 4, .entsize = 16 },
        .{ .name = ".strtab", .type = std.elf.SHT_STRTAB, .data = strings },
    });
    defer testing.allocator.free(bytes);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "in.elf", .data = bytes });
    const directory = try temp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(directory);
    const input = try std.fs.path.join(testing.allocator, &.{ directory, "in.elf" });
    defer testing.allocator.free(input);
    const output = try std.fs.path.join(testing.allocator, &.{ directory, "out.rsp" });
    defer testing.allocator.free(output);
    const listing = try std.fs.path.join(testing.allocator, &.{ directory, "listing" });
    defer testing.allocator.free(listing);

    try run(testing.allocator, testing.io, &.{ input, "--symbols", listing, output });
    const module = try temp.dir.readFileAlloc(testing.io, "listing", testing.allocator, .unlimited);
    defer testing.allocator.free(module);
    try testing.expectEqualStrings(
        \\pub const @"limit": u16 = 0x0004; // imem
        \\pub const @"start": u16 = 0x0000; // imem
        \\pub const @"table": u16 = 0x0020; // dmem
        \\pub const zsp_imem_symbols = [_]struct { name: []const u8, offset: u16 }{
        \\    .{ .name = "limit", .offset = 0x0004 },
        \\    .{ .name = "start", .offset = 0x0000 },
        \\};
        \\
    , module);

    try run(testing.allocator, testing.io, &.{ input, "--map", listing, output });
    const map = try temp.dir.readFileAlloc(testing.io, "listing", testing.allocator, .unlimited);
    defer testing.allocator.free(map);
    try testing.expectEqualStrings(
        \\RSP linked memory map
        \\
        \\Sections:
        \\  data  0x0020..0x0028 (8 bytes)
        \\  text  0x0000..0x0008 (8 bytes)
        \\
        \\Symbols:
        \\  dmem 0x0020 table
        \\  imem 0x0000 start
        \\  imem 0x0004 limit
        \\
    , map);
    const image = try temp.dir.readFileAlloc(testing.io, "out.rsp", testing.allocator, .unlimited);
    defer testing.allocator.free(image);
    try testing.expectEqual(@as(usize, 24 + 8 + 8), image.len);
}

test "duplicate names and malformed symbol tables are errors" {
    const strings = "\x00twice\x00";
    const entries = test_elf.symbol(1, 0x1000, 1) ++ test_elf.symbol(1, 0x1004, 1);
    const bytes = try test_elf.build(testing.allocator, 0x1000, &.{
        .{ .name = ".text", .addr = 0x1000, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .name = ".symtab", .type = std.elf.SHT_SYMTAB, .data = &entries, .link = 3, .entsize = 16 },
        .{ .name = ".strtab", .type = std.elf.SHT_STRTAB, .data = strings },
    });
    defer testing.allocator.free(bytes);
    const file = try elf_file.File.parse(bytes);
    try testing.expectError(error.DuplicateSymbol, symbols.collect(testing.allocator, file, try elf_file.Sections.find(file)));
    const malformed = try test_elf.build(testing.allocator, 0x1000, &.{
        .{ .name = ".text", .addr = 0x1000, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .name = ".symtab", .type = std.elf.SHT_SYMTAB, .data = entries[0..12], .link = 3, .entsize = 16 },
        .{ .name = ".strtab", .type = std.elf.SHT_STRTAB, .data = strings },
    });
    defer testing.allocator.free(malformed);
    const bad = try elf_file.File.parse(malformed);
    try testing.expectError(error.InvalidSymbolTable, symbols.collect(testing.allocator, bad, try elf_file.Sections.find(bad)));
}
