const std = @import("std");
const paths = @import("paths.zig");
const elf_image = @import("elf_image.zig");

const sm = @import("n64").debug.srcmap;
const AddrInfo = sm.AddrInfo;
const SourceLineInfo = sm.SourceLineInfo;
const UnwindInfo = sm.UnwindInfo;

const Allocator = std.mem.Allocator;

var stdout: *std.Io.Writer = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    stdout = &stdout_writer.interface;

    if (args.len < 3) {
        try stdout.writeAll("Usage: srcmap <input.elf> <output.srcmap> [project-root]\n");
        try stdout.flush();
        return error.InvalidArguments;
    }

    const options: Options = .{
        .elf_path = args[1],
        .out_path = args[2],
        .project_root_path = if (args.len > 3) args[3] else ".",
    };

    try writeSrcmap(io, allocator, options);
    try stdout.flush();
}

const Options = struct {
    elf_path: []const u8,
    out_path: []const u8,
    project_root_path: []const u8,
};

const AddrEntry = struct {
    addr: u64,
    column: u16,
    source_line_idx: u32,

    fn lessThan(_: void, lhs: AddrEntry, rhs: AddrEntry) bool {
        return lhs.addr < rhs.addr;
    }
};

const FileRef = struct {
    display_name: []const u8,
    source_path: []const u8,
};

const SourceLine = struct {
    file_idx: u16,
    line_num: u16,
    func_idx: u16,
    text: []const u8,
};

const NameTable = struct {
    names: std.ArrayList([]const u8) = .empty,
    map: std.StringHashMap(u16),

    fn init(alloc: Allocator) NameTable {
        return .{ .map = .init(alloc) };
    }

    fn deinit(self: *NameTable, alloc: Allocator) void {
        for (self.names.items) |name| alloc.free(name);
        self.names.deinit(alloc);
        self.map.deinit();
    }

    fn intern(self: *NameTable, alloc: Allocator, name: []const u8) !u16 {
        if (self.map.get(name)) |idx| return idx;

        const idx: u16 = @intCast(self.names.items.len);
        const owned = try alloc.dupe(u8, name);
        try self.names.append(alloc, owned);
        try self.map.put(owned, idx);
        return idx;
    }
};

const SrcmapBuilder = struct {
    addr_entries: std.ArrayList(AddrEntry) = .empty,
    used_addr: std.AutoHashMap(u64, void),
    funcs: NameTable,
    files: std.ArrayList(FileRef) = .empty,
    file_map: std.StringHashMap(u16),
    source_lines: std.ArrayList(SourceLine) = .empty,
    source_line_map: std.AutoHashMap(u32, u32),
    func_ranges: std.ArrayList(elf_image.FuncRange) = .empty,

    fn init(alloc: Allocator) SrcmapBuilder {
        return .{
            .used_addr = .init(alloc),
            .funcs = NameTable.init(alloc),
            .file_map = .init(alloc),
            .source_line_map = .init(alloc),
        };
    }

    fn deinit(self: *SrcmapBuilder, alloc: Allocator) void {
        self.addr_entries.deinit(alloc);
        self.used_addr.deinit();
        self.funcs.deinit(alloc);
        for (self.files.items) |file| {
            alloc.free(file.display_name);
            alloc.free(file.source_path);
        }
        self.files.deinit(alloc);
        self.file_map.deinit();
        for (self.source_lines.items) |line| alloc.free(line.text);
        self.source_lines.deinit(alloc);
        self.source_line_map.deinit();
        self.func_ranges.deinit(alloc);
    }

    fn addFunctionRange(self: *SrcmapBuilder, alloc: Allocator, range: elf_image.FuncRange) !void {
        try self.func_ranges.append(alloc, range);
    }

    fn internFunction(self: *SrcmapBuilder, alloc: Allocator, name: []const u8) !u16 {
        return self.funcs.intern(alloc, name);
    }

    fn internFile(self: *SrcmapBuilder, alloc: Allocator, display_name: []const u8, source_path: []const u8) !u16 {
        if (self.file_map.get(display_name)) |idx| return idx;

        const idx: u16 = @intCast(self.files.items.len);
        const owned_display = try alloc.dupe(u8, display_name);
        errdefer alloc.free(owned_display);
        const owned_source = try alloc.dupe(u8, source_path);
        errdefer alloc.free(owned_source);

        try self.files.append(alloc, .{
            .display_name = owned_display,
            .source_path = owned_source,
        });
        try self.file_map.put(owned_display, idx);
        return idx;
    }

    fn addAddress(
        self: *SrcmapBuilder,
        io: std.Io,
        alloc: Allocator,
        pc: u64,
        file_idx: u16,
        line_num: u16,
        column: u16,
        func_idx: u16,
    ) !void {
        if (self.used_addr.contains(pc)) return;

        const source_line_idx = try self.internSourceLine(io, alloc, file_idx, line_num, func_idx);
        try self.addr_entries.append(alloc, .{
            .addr = pc,
            .column = column,
            .source_line_idx = source_line_idx,
        });
        try self.used_addr.put(pc, {});
    }

    fn internSourceLine(
        self: *SrcmapBuilder,
        io: std.Io,
        alloc: Allocator,
        file_idx: u16,
        line_num: u16,
        func_idx: u16,
    ) !u32 {
        const key = sourceLineKey(file_idx, line_num);
        const gop = try self.source_line_map.getOrPut(key);
        if (gop.found_existing) return gop.value_ptr.*;

        const text = try paths.readFileLine(io, alloc, self.files.items[file_idx].source_path, line_num);
        errdefer alloc.free(text);

        const idx: u32 = @intCast(self.source_lines.items.len);
        try self.source_lines.append(alloc, .{
            .file_idx = file_idx,
            .line_num = line_num,
            .func_idx = func_idx,
            .text = text,
        });
        gop.value_ptr.* = idx;
        return idx;
    }

    fn sortAndCompact(self: *SrcmapBuilder) void {
        std.mem.sort(AddrEntry, self.addr_entries.items, {}, AddrEntry.lessThan);

        var write_idx: usize = 0;
        for (self.addr_entries.items, 0..) |entry, i| {
            const prev = if (i > 0) self.addr_entries.items[i - 1] else null;
            if (prev == null or
                entry.source_line_idx != prev.?.source_line_idx or
                entry.column != prev.?.column)
            {
                self.addr_entries.items[write_idx] = entry;
                write_idx += 1;
            }
        }
        self.addr_entries.shrinkRetainingCapacity(write_idx);

        std.mem.sort(elf_image.FuncRange, self.func_ranges.items, {}, elf_image.FuncRange.lessThan);
    }
};

const Blobs = struct {
    func_names: StringBlob,
    file_names: StringBlob,
    source_lines: SourceLineBlob,

    fn deinit(self: *Blobs, alloc: Allocator) void {
        self.func_names.deinit(alloc);
        self.file_names.deinit(alloc);
        self.source_lines.deinit(alloc);
    }
};

const StringBlob = struct {
    bytes: std.ArrayList(u8) = .empty,
    offsets: std.ArrayList(u20) = .empty,

    fn deinit(self: *StringBlob, alloc: Allocator) void {
        self.bytes.deinit(alloc);
        self.offsets.deinit(alloc);
    }
};

const SourceLineBlob = struct {
    bytes: std.ArrayList(u8) = .empty,
    offsets: std.ArrayList(u32) = .empty,

    fn deinit(self: *SourceLineBlob, alloc: Allocator) void {
        self.bytes.deinit(alloc);
        self.offsets.deinit(alloc);
    }
};

const Layout = struct {
    entry_count: u32,
    unwind_count: u32,
    unwind_offset: u32,
    func_blob_offset: u32,
    func_blob_size: u32,
    file_blob_offset: u32,
    file_blob_size: u32,
    line_blob_offset: u32,
    line_blob_size: u32,

    fn init(entry_count: u32, unwind_count: u32, blobs: Blobs) Layout {
        const unwind_offset: u32 = @sizeOf(sm.Header) + entry_count * @sizeOf(AddrInfo);
        const func_blob_offset: u32 = unwind_offset + unwind_count * @sizeOf(UnwindInfo);
        const func_blob_size: u32 = @intCast(blobs.func_names.bytes.items.len);
        const file_blob_offset: u32 = std.mem.alignForward(u32, func_blob_offset + func_blob_size, 4);
        const file_blob_size: u32 = @intCast(blobs.file_names.bytes.items.len);
        const line_blob_offset: u32 = std.mem.alignForward(u32, file_blob_offset + file_blob_size, 8);
        const line_blob_size: u32 = @intCast(blobs.source_lines.bytes.items.len);

        return .{
            .entry_count = entry_count,
            .unwind_count = unwind_count,
            .unwind_offset = unwind_offset,
            .func_blob_offset = func_blob_offset,
            .func_blob_size = func_blob_size,
            .file_blob_offset = file_blob_offset,
            .file_blob_size = file_blob_size,
            .line_blob_offset = line_blob_offset,
            .line_blob_size = line_blob_size,
        };
    }
};

fn writeSrcmap(io: std.Io, alloc: Allocator, options: Options) !void {
    const elf_data = try elf_image.readAll(io, alloc, options.elf_path);
    defer alloc.free(elf_data);

    const file = try std.Io.Dir.cwd().openFile(io, options.elf_path, .{});
    defer file.close(io);

    const search_paths: std.debug.ElfFile.DebugInfoSearchPaths = .none;
    var elf = try std.debug.ElfFile.load(alloc, io, file, null, &search_paths);
    var dwarf = &elf.dwarf.?;
    try dwarf.open(alloc, .big);

    const project_root = try paths.normalizedProjectRoot(alloc, options.project_root_path);
    defer alloc.free(project_root);

    var text_arena = std.heap.ArenaAllocator.init(alloc);
    defer text_arena.deinit();

    var builder = SrcmapBuilder.init(alloc);
    defer builder.deinit(alloc);

    try collectDwarfLines(io, alloc, dwarf, project_root, &text_arena, &builder);
    builder.sortAndCompact();

    var unwind_entries = try buildUnwindTable(alloc, elf_data, builder.func_ranges.items);
    defer unwind_entries.deinit(alloc);

    var blobs = try buildBlobs(alloc, builder);
    defer blobs.deinit(alloc);

    const layout = Layout.init(
        @intCast(builder.addr_entries.items.len),
        @intCast(unwind_entries.items.len),
        blobs,
    );

    try writeFile(io, options.out_path, layout, builder.addr_entries.items, unwind_entries.items, blobs);

    try stdout.print("Wrote {s}: {d} lines, {d} unwind entries, {d} funcs, {d} files, {d} source lines\n", .{
        options.out_path,
        layout.entry_count,
        layout.unwind_count,
        builder.funcs.names.items.len,
        builder.files.items.len,
        builder.source_lines.items.len,
    });
}

fn collectDwarfLines(
    io: std.Io,
    alloc: Allocator,
    dwarf: *std.debug.Dwarf,
    project_root: []const u8,
    text_arena: *std.heap.ArenaAllocator,
    builder: *SrcmapBuilder,
) !void {
    for (dwarf.func_list.items) |func| {
        if (func.name == null or func.pc_range == null) continue;

        const range = elf_image.FuncRange.fromDwarf(func.pc_range.?) orelse continue;
        try builder.addFunctionRange(alloc, range);

        const func_idx = try builder.internFunction(alloc, func.name.?);
        const cu = dwarf.findCompileUnit(.big, range.start) catch continue;

        var pc: u64 = range.start;
        while (pc < range.end) : (pc += 4) {
            _ = text_arena.reset(.retain_capacity);
            const loc = dwarf.getLineNumberInfo(alloc, text_arena.allocator(), .big, cu, pc) catch continue;

            const display_name = try paths.normalizeDisplayPath(alloc, project_root, loc.file_name);
            defer alloc.free(display_name);

            const file_idx = try builder.internFile(alloc, display_name, loc.file_name);
            try builder.addAddress(
                io,
                alloc,
                pc,
                file_idx,
                @truncate(loc.line),
                @truncate(loc.column),
                func_idx,
            );
        }
    }
}

fn buildUnwindTable(
    alloc: Allocator,
    elf_data: []const u8,
    ranges: []const elf_image.FuncRange,
) !std.ArrayList(UnwindInfo) {
    var entries: std.ArrayList(UnwindInfo) = .empty;
    errdefer entries.deinit(alloc);

    for (ranges) |range| {
        const frame = elf_image.analyzeFrame(elf_data, range) orelse continue;
        try entries.append(alloc, .{
            .start_addr = range.start,
            .end_addr = range.end,
            .stack_size = frame.stack_size,
            .ra_offset = frame.ra_offset,
        });
    }

    return entries;
}

fn buildBlobs(alloc: Allocator, builder: SrcmapBuilder) !Blobs {
    var blobs: Blobs = .{
        .func_names = try buildStringBlob(alloc, builder.funcs.names.items),
        .file_names = .{},
        .source_lines = .{},
    };
    errdefer blobs.deinit(alloc);

    var file_names: std.ArrayList([]const u8) = .empty;
    defer file_names.deinit(alloc);
    try file_names.ensureTotalCapacity(alloc, builder.files.items.len);
    for (builder.files.items) |file| file_names.appendAssumeCapacity(file.display_name);
    blobs.file_names = try buildStringBlob(alloc, file_names.items);

    blobs.source_lines = try buildSourceLineBlob(
        alloc,
        builder.source_lines.items,
        blobs.func_names.offsets.items,
        blobs.file_names.offsets.items,
    );

    return blobs;
}

fn buildStringBlob(alloc: Allocator, names: []const []const u8) !StringBlob {
    var blob: StringBlob = .{};
    errdefer blob.deinit(alloc);

    for (names) |name| {
        try blob.offsets.append(alloc, @intCast(blob.bytes.items.len));
        try blob.bytes.appendSlice(alloc, name);
        try blob.bytes.append(alloc, 0);
    }

    return blob;
}

fn buildSourceLineBlob(
    alloc: Allocator,
    source_lines: []const SourceLine,
    func_name_offsets: []const u20,
    file_name_offsets: []const u20,
) !SourceLineBlob {
    var blob: SourceLineBlob = .{};
    errdefer blob.deinit(alloc);

    for (source_lines) |line| {
        try blob.offsets.append(alloc, @intCast(blob.bytes.items.len));
        try appendSourceLineInfo(alloc, &blob.bytes, .{
            .line = line.line_num,
            .func_name_offset = func_name_offsets[line.func_idx],
            .file_name_offset = @intCast(file_name_offsets[line.file_idx]),
        });
        try blob.bytes.appendSlice(alloc, line.text);
        try blob.bytes.append(alloc, 0);
        try appendPadding(alloc, &blob.bytes, 8);
    }

    return blob;
}

fn appendSourceLineInfo(alloc: Allocator, bytes: *std.ArrayList(u8), info: SourceLineInfo) !void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, packSourceLineInfo(info), .big);
    try bytes.appendSlice(alloc, &encoded);
}

fn writeFile(
    io: std.Io,
    out_path: []const u8,
    layout: Layout,
    addr_entries: []const AddrEntry,
    unwind_entries: []const UnwindInfo,
    blobs: Blobs,
) !void {
    const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);

    var out_buf: [4096]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    const w = &out_writer.interface;

    try writeHeader(w, layout);
    try writeAddrTable(w, addr_entries, blobs.source_lines.offsets.items);
    try writeUnwindTable(w, unwind_entries);

    try w.writeAll(blobs.func_names.bytes.items);
    try writeZeroPadding(w, layout.file_blob_offset - (layout.func_blob_offset + layout.func_blob_size));
    try w.writeAll(blobs.file_names.bytes.items);
    try writeZeroPadding(w, layout.line_blob_offset - (layout.file_blob_offset + layout.file_blob_size));
    try w.writeAll(blobs.source_lines.bytes.items);

    try w.flush();
}

fn writeHeader(w: *std.Io.Writer, layout: Layout) !void {
    try w.writeAll("NSRC");
    try w.writeInt(u32, layout.entry_count, .big);
    try w.writeInt(u32, layout.unwind_count, .big);
    try w.writeInt(u32, layout.unwind_offset, .big);
    try w.writeInt(u32, layout.func_blob_offset, .big);
    try w.writeInt(u32, layout.func_blob_size, .big);
    try w.writeInt(u32, layout.file_blob_offset, .big);
    try w.writeInt(u32, layout.file_blob_size, .big);
    try w.writeInt(u32, layout.line_blob_offset, .big);
    try w.writeInt(u32, layout.line_blob_size, .big);
}

fn writeAddrTable(w: *std.Io.Writer, addr_entries: []const AddrEntry, source_line_offsets: []const u32) !void {
    for (addr_entries) |entry| {
        try w.writeInt(u64, packAddrInfo(.{
            .start_addr = @truncate(entry.addr),
            .column = entry.column,
            .source_line_offset = @intCast(source_line_offsets[entry.source_line_idx]),
        }), .big);
    }
}

fn writeUnwindTable(w: *std.Io.Writer, unwind_entries: []const UnwindInfo) !void {
    for (unwind_entries) |entry| {
        try w.writeInt(u32, entry.start_addr, .big);
        try w.writeInt(u32, entry.end_addr, .big);
        try w.writeInt(u16, entry.stack_size, .big);
        try w.writeInt(u16, entry.ra_offset, .big);
    }
}

fn appendPadding(alloc: Allocator, bytes: *std.ArrayList(u8), alignment: usize) !void {
    const aligned_len = std.mem.alignForward(usize, bytes.items.len, alignment);
    try bytes.appendNTimes(alloc, 0, aligned_len - bytes.items.len);
}

fn writeZeroPadding(w: *std.Io.Writer, count: u32) !void {
    const zeros = [_]u8{0} ** 8;
    try w.writeAll(zeros[0..@intCast(count)]);
}

fn sourceLineKey(file_idx: u16, line_num: u16) u32 {
    return (@as(u32, file_idx) << 16) | line_num;
}

fn packAddrInfo(info: AddrInfo) u64 {
    return (@as(u64, info.start_addr) << 40) |
        (@as(u64, info.column) << 24) |
        @as(u64, info.source_line_offset);
}

fn packSourceLineInfo(info: SourceLineInfo) u64 {
    return (@as(u64, info.line) << 48) |
        (@as(u64, info.func_name_offset) << 28) |
        @as(u64, info.file_name_offset);
}
