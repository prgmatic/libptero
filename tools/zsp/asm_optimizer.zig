const std = @import("std");

const Kind = enum { other, label, instruction };

const Instruction = struct {
    reads: u64 = 0,
    writes: u64 = 0,
    branch: bool = false,
    nop: bool = false,
    vector: bool = false,
    memory: bool = false,
    latency: u8 = 0,
};

const Line = struct {
    text: []const u8,
    owned: bool = false,
    kind: Kind = .other,
    instruction: Instruction = .{},
};

/// Runs the deterministic, dependency-aware scheduling subset of RSPL's ASM
/// optimizer. Unknown instructions are barriers rather than optimization input.
pub fn writeOptimized(allocator: std.mem.Allocator, writer: *std.Io.Writer, assembly: []const u8) !void {
    var lines: std.ArrayList(Line) = .empty;
    defer {
        for (lines.items) |line| if (line.owned) allocator.free(line.text);
        lines.deinit(allocator);
    }

    var ordered_depth: usize = 0;
    var it = std.mem.splitScalar(u8, assembly, '\n');
    while (it.next()) |line_text| {
        if (std.mem.eql(u8, std.mem.trim(u8, line_text, " \t\r"), "# zsp ordered block begin")) {
            ordered_depth += 1;
            try lines.append(allocator, .{ .text = line_text });
            continue;
        }
        if (std.mem.eql(u8, std.mem.trim(u8, line_text, " \t\r"), "# zsp ordered block end")) {
            ordered_depth -= 1;
            try lines.append(allocator, .{ .text = line_text });
            continue;
        }
        var line = parseLine(line_text);
        if (ordered_depth != 0) line.kind = .other;
        try lines.append(allocator, line);
    }

    try foldSymbolOffsets(allocator, &lines);
    removeDeadWrites(&lines);
    try foldPollingLoops(allocator, &lines);
    fillDelaySlots(&lines);
    scheduleHazards(lines.items);
    pairPipelines(lines.items);

    for (lines.items, 0..) |line, index| {
        try writer.writeAll(line.text);
        if (index + 1 < lines.items.len) try writer.writeByte('\n');
    }
}

fn foldSymbolOffsets(allocator: std.mem.Allocator, lines: *std.ArrayList(Line)) !void {
    var index: usize = 0;
    while (index + 1 < lines.items.len) {
        const address = lines.items[index];
        const memory = lines.items[index + 1];
        if (address.kind != .instruction or memory.kind != .instruction or
            address.instruction.branch or memory.instruction.branch or
            (index > 0 and lines.items[index - 1].instruction.branch) or
            !std.mem.startsWith(u8, std.mem.trim(u8, address.text, " \t"), "addiu $at, $zero, %lo("))
        {
            index += 1;
            continue;
        }
        const label_start = std.mem.indexOf(u8, address.text, "%lo(") orelse {
            index += 1;
            continue;
        };
        const label_end = std.mem.indexOfScalarPos(u8, address.text, label_start + 4, ')') orelse {
            index += 1;
            continue;
        };
        const operand_end = std.mem.indexOf(u8, memory.text, "($at)") orelse {
            index += 1;
            continue;
        };
        var operand_start = operand_end;
        while (operand_start > 0 and memory.text[operand_start - 1] != ' ' and memory.text[operand_start - 1] != ',') {
            operand_start -= 1;
        }
        if (operand_start == operand_end) {
            index += 1;
            continue;
        }
        const replacement = try std.fmt.allocPrint(allocator, "{s}%lo({s} + {s})($zero){s}", .{
            memory.text[0..operand_start],
            address.text[label_start + 4 .. label_end],
            memory.text[operand_start..operand_end],
            memory.text[operand_end + "($at)".len ..],
        });
        if (lines.items[index + 1].owned) allocator.free(lines.items[index + 1].text);
        var replacement_line = parseLine(replacement);
        replacement_line.owned = true;
        lines.items[index + 1] = replacement_line;
        if (lines.items[index].owned) allocator.free(lines.items[index].text);
        _ = lines.orderedRemove(index);
    }
}

// Fold `read; while (read != 0) read` into a direct conditional back edge.
// CP0 status polling is the primary use, but the rewrite is dependency based.
fn foldPollingLoops(allocator: std.mem.Allocator, lines: *std.ArrayList(Line)) !void {
    var label_index: usize = 1;
    while (label_index + 6 < lines.items.len) : (label_index += 1) {
        // Two-operation recurrence: `read; mask; while (...) { read; mask; }`.
        // Rotate it to `read; loop: mask; bne loop; read`.
        if (label_index >= 2) {
            const read = lines.items[label_index - 2];
            const mask = lines.items[label_index - 1];
            const label = lines.items[label_index];
            const branch = lines.items[label_index + 1];
            if (label_index + 7 < lines.items.len and
                read.kind == .instruction and mask.kind == .instruction and label.kind == .label and
                std.mem.eql(u8, opcode(branch.text) orelse "", "beq") and
                lines.items[label_index + 2].instruction.nop and
                std.mem.eql(u8, read.text, lines.items[label_index + 3].text) and
                std.mem.eql(u8, mask.text, lines.items[label_index + 4].text) and
                std.mem.eql(u8, opcode(lines.items[label_index + 5].text) orelse "", "j") and
                lines.items[label_index + 6].instruction.nop and
                lines.items[label_index + 7].kind == .label and
                lineTargetsLabel(lines.items[label_index + 5].text, label.text) and
                lineTargetsLabel(branch.text, lines.items[label_index + 7].text))
            {
                const reg = firstRegister(branch.text) orelse continue;
                var new_branch = parseLine(try std.fmt.allocPrint(allocator, "  bne {s}, $zero, {s}", .{
                    reg,
                    std.mem.trimEnd(u8, label.text, ":\r"),
                }));
                new_branch.owned = true;
                lines.items[label_index - 1] = label;
                lines.items[label_index] = mask;
                lines.items[label_index + 1] = new_branch;
                lines.items[label_index + 2] = read;
                lines.items[label_index + 3] = lines.items[label_index + 7];
                var removed: usize = 0;
                while (removed < 4) : (removed += 1) _ = lines.orderedRemove(label_index + 4);
                label_index += 2;
                continue;
            }
        }

        const before = lines.items[label_index - 1];
        const label = lines.items[label_index];
        const branch = lines.items[label_index + 1];
        if (before.kind != .instruction or label.kind != .label or
            !std.mem.eql(u8, opcode(branch.text) orelse "", "beq") or
            !lines.items[label_index + 2].instruction.nop or
            !std.mem.eql(u8, before.text, lines.items[label_index + 3].text) or
            !std.mem.eql(u8, opcode(lines.items[label_index + 4].text) orelse "", "j") or
            !lines.items[label_index + 5].instruction.nop or
            lines.items[label_index + 6].kind != .label) continue;
        if (before.instruction.writes == 0 or
            (before.instruction.writes & branch.instruction.reads) == 0) continue;
        if (!lineTargetsLabel(lines.items[label_index + 4].text, label.text) or
            !lineTargetsLabel(branch.text, lines.items[label_index + 6].text)) continue;

        const reg = firstRegister(branch.text) orelse continue;
        const new_text = try std.fmt.allocPrint(allocator, "  bne {s}, $zero, {s}", .{
            reg,
            std.mem.trimEnd(u8, label.text, ":\r"),
        });
        var new_branch = parseLine(new_text);
        new_branch.owned = true;

        lines.items[label_index - 1] = label;
        lines.items[label_index] = before;
        lines.items[label_index + 1] = new_branch;
        lines.items[label_index + 3] = lines.items[label_index + 6];
        var removed: usize = 0;
        while (removed < 3) : (removed += 1) _ = lines.orderedRemove(label_index + 4);
        // Work after the exit that writes the polled register can run in the
        // delay slot: busy iterations overwrite it with the next read, while
        // the exiting iteration retains exactly the original result.
        if (label_index + 4 < lines.items.len) {
            const candidate = lines.items[label_index + 4];
            if (candidate.kind == .instruction and !candidate.instruction.branch and
                candidate.instruction.writes != 0 and
                (candidate.instruction.writes & before.instruction.writes) == candidate.instruction.writes and
                (candidate.instruction.reads & before.instruction.writes) == 0)
            {
                lines.items[label_index + 2] = candidate;
                _ = lines.orderedRemove(label_index + 4);
            }
        }
        label_index += 2;
    }
}

fn removeDeadWrites(lines: *std.ArrayList(Line)) void {
    var index: usize = 0;
    while (index + 1 < lines.items.len) {
        const first = lines.items[index];
        const second = lines.items[index + 1];
        if (first.kind == .instruction and second.kind == .instruction and
            !first.instruction.branch and first.instruction.writes != 0 and
            (first.instruction.writes & second.instruction.writes) == first.instruction.writes and
            (first.instruction.writes & second.instruction.reads) == 0)
        {
            _ = lines.orderedRemove(index);
            continue;
        }
        index += 1;
    }
}

fn fillDelaySlots(lines: *std.ArrayList(Line)) void {
    var branch_index: usize = 0;
    while (branch_index + 1 < lines.items.len) : (branch_index += 1) {
        if (!lines.items[branch_index].instruction.branch or !lines.items[branch_index + 1].instruction.nop) continue;

        var candidate = branch_index;
        while (candidate > 0) {
            candidate -= 1;
            if (lines.items[candidate].kind != .instruction or lines.items[candidate].instruction.branch) break;
            if (lines.items[candidate].instruction.nop) continue;
            // Never steal an instruction that already fills another branch's
            // delay slot; doing so moves the following branch into that slot.
            if (candidate > 0 and lines.items[candidate - 1].instruction.branch) continue;
            if (!canMove(lines.items, candidate, branch_index + 1)) continue;

            const selected = lines.orderedRemove(candidate);
            branch_index -= 1;
            lines.items[branch_index + 1] = selected;
            break;
        }
    }
}

fn scheduleHazards(lines: []Line) void {
    var producer_index: usize = 0;
    while (producer_index < lines.len) : (producer_index += 1) {
        const producer = lines[producer_index];
        if (producer.kind != .instruction or producer.instruction.latency == 0) continue;

        var consumer_index = producer_index + 1;
        while (consumer_index < lines.len and
            lines[consumer_index].kind == .instruction and
            !lines[consumer_index].instruction.branch and
            (producer.instruction.writes & lines[consumer_index].instruction.reads) == 0) : (consumer_index += 1)
        {}
        if (consumer_index >= lines.len or lines[consumer_index].kind != .instruction or
            (producer.instruction.writes & lines[consumer_index].instruction.reads) == 0) continue;

        const desired_gap = producer.instruction.latency - 1;
        while (consumer_index - producer_index - 1 < desired_gap) {
            var candidate = consumer_index + 1;
            while (candidate < lines.len and lines[candidate].kind == .instruction and
                !canMove(lines, candidate, consumer_index)) : (candidate += 1)
            {}
            if (candidate >= lines.len or lines[candidate].kind != .instruction or
                !canMove(lines, candidate, consumer_index)) break;
            const selected = lines[candidate];
            var index = candidate;
            while (index > consumer_index) : (index -= 1) lines[index] = lines[index - 1];
            lines[consumer_index] = selected;
            consumer_index += 1;
        }
    }
}

fn pairPipelines(lines: []Line) void {
    var index: usize = 0;
    while (index + 2 < lines.len) : (index += 1) {
        if (lines[index].kind != .instruction or lines[index].instruction.branch or
            lines[index + 1].kind != .instruction or lines[index + 1].instruction.branch or
            lines[index].instruction.vector != lines[index + 1].instruction.vector) continue;
        var candidate = index + 2;
        while (candidate < lines.len and lines[candidate].kind == .instruction) : (candidate += 1) {
            if (lines[candidate].instruction.branch) break;
            if (lines[candidate].instruction.vector == lines[index].instruction.vector) continue;
            if (!canMove(lines, candidate, index + 1)) continue;
            const selected = lines[candidate];
            var move_index = candidate;
            while (move_index > index + 1) : (move_index -= 1) lines[move_index] = lines[move_index - 1];
            lines[index + 1] = selected;
            break;
        }
    }
}

fn canMove(lines: []const Line, from: usize, to: usize) bool {
    const moving = lines[from];
    if (moving.kind != .instruction or moving.instruction.branch or moving.instruction.nop) return false;
    const start = @min(from, to);
    const end = @max(from, to);
    for (lines[start..end], start..) |crossed, index| {
        if (index == from) continue;
        if (crossed.kind != .instruction) return false;
        if (crossed.instruction.branch and to != index + 1) return false;
        if ((moving.instruction.reads & crossed.instruction.writes) != 0 or
            (moving.instruction.writes & (crossed.instruction.reads | crossed.instruction.writes)) != 0) return false;
        // ZSP has no alias analysis/barrier annotation yet. Keep all memory accesses ordered.
        if (moving.instruction.memory and crossed.instruction.memory) return false;
    }
    return true;
}

fn parseLine(text: []const u8) Line {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return .{ .text = text };
    if (trimmed[0] == '.' and !std.mem.startsWith(u8, trimmed, ".word ")) return .{ .text = text };
    if (trimmed[trimmed.len - 1] == ':') return .{ .text = text, .kind = .label };

    var instruction_text = trimmed;
    if (std.mem.startsWith(u8, trimmed, ".word ")) {
        const comment = std.mem.indexOfScalar(u8, trimmed, '#') orelse return .{ .text = text };
        instruction_text = std.mem.trimStart(u8, trimmed[comment + 1 ..], " \t");
    }
    var tokens = std.mem.tokenizeAny(u8, instruction_text, " ,()[]\t");
    const op = tokens.next() orelse return .{ .text = text };
    if (!isKnownOp(op)) return .{ .text = text };

    var regs: [8]u6 = undefined;
    var reg_count: usize = 0;
    while (tokens.next()) |token| {
        if (registerIndex(token)) |reg| {
            if (reg_count < regs.len) {
                regs[reg_count] = reg;
                reg_count += 1;
            }
        }
    }

    const branch = isBranch(op);
    const store = isStore(op);
    const load = isLoad(op);
    const vector = isVectorOp(op);
    var info = Instruction{
        .branch = branch,
        .nop = std.mem.eql(u8, op, "nop"),
        .vector = vector,
        .memory = load or store,
        .latency = if (load) (if (vector) 4 else 3) else if (vector) 4 else 0,
    };
    if (std.mem.eql(u8, op, "mtc0")) {
        if (reg_count > 0) info.reads |= registerMask(regs[0]);
    } else if (std.mem.eql(u8, op, "mfc0")) {
        if (reg_count > 0) info.writes |= registerMask(regs[0]);
        info.latency = 3;
    } else if (std.mem.eql(u8, op, "mtc2") and reg_count >= 2) {
        info.reads |= registerMask(regs[0]);
        info.writes |= registerMask(regs[1]);
    } else if (branch or store) {
        for (regs[0..reg_count]) |reg| info.reads |= registerMask(reg);
    } else if (reg_count > 0) {
        info.writes |= registerMask(regs[0]);
        for (regs[1..reg_count]) |reg| info.reads |= registerMask(reg);
    }
    if (std.mem.eql(u8, op, "jal")) info.writes |= registerMask(31);
    // Vector arithmetic shares the accumulator/flag datapath. Treat it as a
    // dependency to prevent unsafe reordering of currently supported VU ops.
    if (vector and !load and !store) {
        info.reads |= @as(u64, 1) << 63;
        info.writes |= @as(u64, 1) << 63;
    }
    return .{ .text = text, .kind = .instruction, .instruction = info };
}

fn registerMask(index: u6) u64 {
    return @as(u64, 1) << index;
}

fn registerIndex(token: []const u8) ?u6 {
    if (token.len < 2 or token[0] != '$') return null;
    const names = [_][]const u8{
        "zero", "at", "v0", "v1", "a0", "a1", "a2", "a3", "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7",
        "s0",   "s1", "s2", "s3", "s4", "s5", "s6", "s7", "t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra",
    };
    for (names, 0..) |name, index| if (std.mem.eql(u8, token[1..], name)) return @intCast(index);
    if (token.len == 4 and token[1] == 'v') {
        const number = std.fmt.parseInt(u6, token[2..], 10) catch return null;
        if (number < 32) return 32 + number;
    }
    return null;
}

fn isKnownOp(op: []const u8) bool {
    const ops = [_][]const u8{
        "nop",   "break", "j",     "jr",    "jal",   "beq",   "bne",   "bgez",  "bltz",  "blez",  "bgtz",
        "addi",  "add",   "addiu", "addu",  "sub",   "subu",  "and",   "andi",  "or",    "ori",   "xor",
        "xori",  "nor",   "slt",   "sltu",  "slti",  "sltiu", "sll",   "sllv",  "srl",   "srlv",  "sra",
        "srav",  "lui",   "lb",    "lbu",   "lh",    "lhu",   "lw",    "sb",    "sh",    "sw",    "lqv",
        "sqv",   "lsv",   "ssv",   "mtc0",  "mfc0",  "mtc2",  "mfc2",  "vadd",  "vaddc", "vsub",  "vsubc",
        "vand",  "vnand", "vor",   "vnor",  "vxor",  "vnxor", "vmulf", "vmulu", "vmacf", "vmacu", "vmudl",
        "vmudm", "vmudn", "vmudh", "vmadl", "vmadm", "vmadn", "vmadh",
    };
    for (ops) |known| if (std.mem.eql(u8, op, known)) return true;
    return false;
}

fn opcode(text: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, std.mem.trim(u8, text, " \t\r"), " ,()[]\t");
    return tokens.next();
}

fn firstRegister(text: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, text, " ,()[]\t");
    _ = tokens.next();
    while (tokens.next()) |token| if (token.len > 1 and token[0] == '$') return token;
    return null;
}

fn lineTargetsLabel(text: []const u8, label_text: []const u8) bool {
    const label = std.mem.trimEnd(u8, std.mem.trim(u8, label_text, " \t\r"), ":");
    var tokens = std.mem.tokenizeAny(u8, text, " ,()[]\t");
    var last: []const u8 = "";
    while (tokens.next()) |token| last = token;
    return std.mem.eql(u8, last, label);
}

fn isBranch(op: []const u8) bool {
    return op[0] == 'b' or std.mem.eql(u8, op, "j") or std.mem.eql(u8, op, "jr") or std.mem.eql(u8, op, "jal");
}

fn isLoad(op: []const u8) bool {
    return std.mem.eql(u8, op, "lb") or std.mem.eql(u8, op, "lbu") or std.mem.eql(u8, op, "lh") or
        std.mem.eql(u8, op, "lhu") or std.mem.eql(u8, op, "lw") or std.mem.eql(u8, op, "lqv") or
        std.mem.eql(u8, op, "lsv");
}

fn isStore(op: []const u8) bool {
    return std.mem.eql(u8, op, "sb") or std.mem.eql(u8, op, "sh") or std.mem.eql(u8, op, "sw") or
        std.mem.eql(u8, op, "sqv") or std.mem.eql(u8, op, "ssv");
}

fn isVectorOp(op: []const u8) bool {
    return (op.len > 1 and op[0] == 'v') or std.mem.eql(u8, op, "lqv") or std.mem.eql(u8, op, "sqv") or
        std.mem.eql(u8, op, "lsv") or std.mem.eql(u8, op, "ssv") or std.mem.eql(u8, op, "mtc2") or
        std.mem.eql(u8, op, "mfc2");
}
