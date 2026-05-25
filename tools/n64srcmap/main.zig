const std = @import("std");
const sm = @import("n64").debug.srcmap;
const AddrInfo = sm.AddrInfo;
const SourceLineInfo = sm.SourceLineInfo;
var stdout: *std.Io.Writer = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    stdout = &stdout_writer.interface;

    const elf_path = args[1];
    const out_path = args[2];

    try elf_find_callsites(io, allocator, elf_path, out_path);
    try stdout.flush();
}

// Intermediate per-address record; holds indices needed to build blobs before
// final AddrInfo (which only stores start_addr, column, source_line_offset).
const AddrEntry = struct {
    addr: u64,
    column: u16,
    source_line_idx: u32,
};

fn elf_find_callsites(io: std.Io, alloc: std.mem.Allocator, in_path: []const u8, out_path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, in_path, .{});
    defer file.close(io);

    const paths: std.debug.ElfFile.DebugInfoSearchPaths = .none;
    var elf = try std.debug.ElfFile.load(alloc, io, file, null, &paths);
    var dwarf = &elf.dwarf.?;
    try dwarf.open(alloc, .big);

    var text_arena = std.heap.ArenaAllocator.init(alloc);
    defer text_arena.deinit();

    var addr_entries: std.ArrayList(AddrEntry) = .empty;
    defer addr_entries.deinit(alloc);

    var used_addr: std.AutoHashMap(u64, void) = .init(alloc);
    defer used_addr.deinit();

    var file_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (file_names.items) |n| alloc.free(n);
        file_names.deinit(alloc);
    }
    var file_map: std.StringHashMap(u16) = .init(alloc);
    defer file_map.deinit();
    var next_file_idx: u16 = 0;

    var func_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (func_names.items) |n| alloc.free(n);
        func_names.deinit(alloc);
    }
    var func_map: std.StringHashMap(u16) = .init(alloc);
    defer func_map.deinit();
    var next_func_idx: u16 = 0;

    const SourceLine = struct {
        file_idx: u16,
        line_num: u16,
        func_idx: u16,
        text: []const u8,
    };
    var source_lines: std.ArrayList(SourceLine) = .empty;
    defer {
        for (source_lines.items) |sl| alloc.free(sl.text);
        source_lines.deinit(alloc);
    }
    // key: (file_idx << 16 | line_num) -> index into source_lines
    var source_line_map: std.AutoHashMap(u32, u32) = .init(alloc);
    defer source_line_map.deinit();

    for (dwarf.func_list.items) |func| {
        if (func.name == null or func.pc_range == null) continue;
        if (func.pc_range.?.start < 0x80000000) continue;

        var func_idx: u16 = next_func_idx;
        if (func_map.get(func.name.?)) |f| {
            func_idx = f;
        } else {
            const owned = try alloc.dupe(u8, func.name.?);
            try func_names.append(alloc, owned);
            try func_map.put(owned, next_func_idx);
            func_idx = next_func_idx;
            next_func_idx += 1;
        }

        const cu = dwarf.findCompileUnit(.big, func.pc_range.?.start) catch continue;

        var pc = func.pc_range.?.start;
        while (pc < func.pc_range.?.end) : (pc += 4) {
            _ = text_arena.reset(.retain_capacity);
            const loc = dwarf.getLineNumberInfo(alloc, text_arena.allocator(), .big, cu, pc) catch continue;
            if (used_addr.contains(pc)) continue;

            var file_idx: u16 = next_file_idx;
            if (file_map.get(loc.file_name)) |f| {
                file_idx = f;
            } else {
                const owned = try alloc.dupe(u8, loc.file_name);
                try file_names.append(alloc, owned);
                try file_map.put(owned, next_file_idx);
                file_idx = next_file_idx;
                next_file_idx += 1;
            }

            const line_num: u16 = @truncate(loc.line);
            const column: u16 = @truncate(loc.column);

            const sl_key: u32 = (@as(u32, file_idx) << 16) | line_num;
            const gop = try source_line_map.getOrPut(sl_key);
            if (!gop.found_existing) {
                const fname = file_names.items[@intCast(file_idx)];
                const text = try readFileLine(io, alloc, fname, line_num);
                gop.value_ptr.* = @intCast(source_lines.items.len);
                try source_lines.append(alloc, .{
                    .file_idx = file_idx,
                    .line_num = line_num,
                    .func_idx = func_idx,
                    .text = text,
                });
            }

            try addr_entries.append(alloc, .{
                .addr = pc,
                .column = column,
                .source_line_idx = gop.value_ptr.*,
            });
            try used_addr.put(pc, {});
        }
    }

    // Sort by address.
    std.mem.sort(AddrEntry, addr_entries.items, {}, struct {
        fn cmp(_: void, lhs: AddrEntry, rhs: AddrEntry) bool {
            return lhs.addr < rhs.addr;
        }
    }.cmp);

    // Remove consecutive entries that resolve to the same source line and column.
    var write_idx: usize = 0;
    for (addr_entries.items, 0..) |entry, i| {
        const prev = if (i > 0) addr_entries.items[i - 1] else null;
        if (prev == null or
            entry.source_line_idx != prev.?.source_line_idx or
            entry.column != prev.?.column)
        {
            addr_entries.items[write_idx] = entry;
            write_idx += 1;
        }
    }
    addr_entries.shrinkRetainingCapacity(write_idx);

    // Build function name blob.
    var func_name_blob: std.ArrayList(u8) = .empty;
    defer func_name_blob.deinit(alloc);
    var func_name_offsets: std.ArrayList(u20) = .empty;
    defer func_name_offsets.deinit(alloc);
    for (func_names.items) |name| {
        try func_name_offsets.append(alloc, @intCast(func_name_blob.items.len));
        try func_name_blob.appendSlice(alloc, name);
        try func_name_blob.append(alloc, 0);
    }

    // Build file name blob.
    var file_name_blob: std.ArrayList(u8) = .empty;
    defer file_name_blob.deinit(alloc);
    var file_name_offsets: std.ArrayList(u20) = .empty;
    defer file_name_offsets.deinit(alloc);
    for (file_names.items) |name| {
        try file_name_offsets.append(alloc, @intCast(file_name_blob.items.len));
        try file_name_blob.appendSlice(alloc, name);
        try file_name_blob.append(alloc, 0);
    }

    // Build source line blob: each entry is [SourceLineInfo (8 bytes)][string\0][padding].
    // Each entry is padded to 8-byte alignment so SourceLineInfo reads are always aligned on MIPS.
    // source_line_blob_offsets[i] = byte offset of entry i within the blob.
    var source_line_blob: std.ArrayList(u8) = .empty;
    defer source_line_blob.deinit(alloc);
    var source_line_blob_offsets: std.ArrayList(u32) = .empty;
    defer source_line_blob_offsets.deinit(alloc);

    for (source_lines.items) |sl| {
        try source_line_blob_offsets.append(alloc, @intCast(source_line_blob.items.len));

        const sli: SourceLineInfo = .{
            .line = sl.line_num,
            .func_name_offset = func_name_offsets.items[sl.func_idx],
            .file_name_offset = @intCast(file_name_offsets.items[sl.file_idx]),
        };
        var sli_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &sli_bytes, @as(u64, @bitCast(sli)), .big);
        try source_line_blob.appendSlice(alloc, &sli_bytes);
        try source_line_blob.appendSlice(alloc, sl.text);
        try source_line_blob.append(alloc, 0);
        // Pad so the next SourceLineInfo starts on an 8-byte boundary.
        const aligned_len = std.mem.alignForward(usize, source_line_blob.items.len, 8);
        try source_line_blob.appendNTimes(alloc, 0, aligned_len - source_line_blob.items.len);
    }

    // Compute binary layout offsets.
    const entry_count: u32 = @intCast(addr_entries.items.len);
    const func_blob_offset: u32 = @sizeOf(sm.Header) + entry_count * @sizeOf(AddrInfo);
    const func_blob_size: u32 = @intCast(func_name_blob.items.len);
    const file_blob_offset: u32 = std.mem.alignForward(u32, func_blob_offset + func_blob_size, 4);
    const file_blob_size: u32 = @intCast(file_name_blob.items.len);
    // Line blob must be 8-byte aligned so the first SourceLineInfo is aligned on MIPS.
    const line_blob_offset: u32 = std.mem.alignForward(u32, file_blob_offset + file_blob_size, 8);
    const line_blob_size: u32 = @intCast(source_line_blob.items.len);

    const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    var out_buf: [4096]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    const w = &out_writer.interface;

    // Header
    try w.writeAll("NSRC");
    try w.writeInt(u32, entry_count, .big);
    try w.writeInt(u32, func_blob_offset, .big);
    try w.writeInt(u32, func_blob_size, .big);
    try w.writeInt(u32, file_blob_offset, .big);
    try w.writeInt(u32, file_blob_size, .big);
    try w.writeInt(u32, line_blob_offset, .big);
    try w.writeInt(u32, line_blob_size, .big);

    // AddrInfo array — resolve source_line_idx to blob byte offset.
    for (addr_entries.items) |entry| {
        const info: AddrInfo = .{
            .start_addr = @truncate(entry.addr),
            .column = entry.column,
            .source_line_offset = @intCast(source_line_blob_offsets.items[entry.source_line_idx]),
        };
        try w.writeStruct(info, .big);
    }

    // Function name blob.
    try w.writeAll(func_name_blob.items);

    // File name blob (4-byte aligned).
    const pad0 = file_blob_offset - (func_blob_offset + func_blob_size);
    try w.writeAll(([_]u8{0} ** 3)[0..@intCast(pad0)]);
    try w.writeAll(file_name_blob.items);

    // Source line blob (8-byte aligned).
    const pad1 = line_blob_offset - (file_blob_offset + file_blob_size);
    try w.writeAll(([_]u8{0} ** 7)[0..@intCast(pad1)]);
    try w.writeAll(source_line_blob.items);

    try w.flush();

    try stdout.print("Wrote {s}: {d} entries, {d} funcs, {d} files, {d} source lines\n", .{
        out_path, entry_count, func_names.items.len, file_names.items.len, source_lines.items.len,
    });
}

fn readFileLine(io: std.Io, alloc: std.mem.Allocator, path: []const u8, line_num: u16) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return alloc.dupe(u8, "");
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var current: u16 = 1;
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (current == line_num) {
                    const remaining = reader.interface.buffered();
                    return try alloc.dupe(u8, std.mem.trimEnd(u8, remaining, "\r\n"));
                }
                return try alloc.dupe(u8, "");
            },
            else => |e| return e,
        };
        if (current == line_num)
            return try alloc.dupe(u8, std.mem.trimEnd(u8, line, "\r\n"));
        current += 1;
    }
}
