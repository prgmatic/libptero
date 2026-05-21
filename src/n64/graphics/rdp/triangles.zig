
pub inline fn drawRotatedSprite(cmd_queue: anytype, tile: u3, x: f32, y: f32, s0: u8, t0: u8, 
    width: f32, height: f32, flip_x: bool, flip_y: bool, 
    rotation: f32, scale_x: f32, scale_y: f32, 
    cx: f32, cy: f32) void {

    const sin_theta = @sin(rotation);
    const cos_theta = @cos(rotation);

    // 2D affine transform matrix (column-major): maps texel coords → screen.
    // Screen coords are in screen-pixel units (not sub-pixel).
    const m00 = cos_theta * scale_x;  const m01 = -sin_theta * scale_x;
    const m10 = sin_theta * scale_y;  const m11 =  cos_theta * scale_y;

    // Pivot in absolute texture space.
    const cx_abs = @as(f32, s0) + cx;
    const cy_abs = @as(f32, t0) + cy;

    // Translation: pivot maps to screen (x, y).
    const m20 = x - (cx_abs * m00 + cy_abs * m10);
    const m21 = y - (cx_abs * m01 + cy_abs * m11);

    // Source sub-rect corners in texture space.
    const s0f: f32 = @floatFromInt(s0);
    const t0f: f32 = @floatFromInt(t0);
    const s1f = s0f + width;
    const t1f = t0f + height;

    // Apply flip by swapping the texture-space corners used for screen positions.
    // The texture coords passed to the triangle always use the originals (s0f..s1f).
    const ks0 = if (flip_x) s1f - 1.0 else s0f;
    const ks1 = if (flip_x) s0f - 1.0 else s1f;
    const kt0 = if (flip_y) t1f - 1.0 else t0f;
    const kt1 = if (flip_y) t0f - 1.0 else t1f;

    // Four screen corners via the affine matrix.
    //  k0 = top-left,  k1 = top-right,  k2 = bottom-right,  k3 = bottom-left
    const k0x = m00 * ks0 + m10 * kt0 + m20; const k0y = m01 * ks0 + m11 * kt0 + m21;
    const k1x = m00 * ks1 + m10 * kt0 + m20; const k1y = m01 * ks1 + m11 * kt0 + m21;
    const k2x = m00 * ks1 + m10 * kt1 + m20; const k2y = m01 * ks1 + m11 * kt1 + m21;
    const k3x = m00 * ks0 + m10 * kt1 + m20; const k3y = m01 * ks0 + m11 * kt1 + m21;

    // Triangle 1: k0 → k1 → k2  (texture coords always original, not flipped)
    texturedTriangle(cmd_queue, tile,
        .{ .x = k0x, .y = k0y, .s = s0f, .t = t0f },
        .{ .x = k1x, .y = k1y, .s = s1f, .t = t0f },
        .{ .x = k2x, .y = k2y, .s = s1f, .t = t1f });
    // Triangle 2: k0 → k2 → k3
    texturedTriangle(cmd_queue, tile,
        .{ .x = k0x, .y = k0y, .s = s0f, .t = t0f },
        .{ .x = k2x, .y = k2y, .s = s1f, .t = t1f },
        .{ .x = k3x, .y = k3y, .s = s0f, .t = t1f });
}

// 0x0A — TRI_TEX: textured triangle, no shade, no z-buffer.
// Vertices may be in any order; they are sorted by Y internally.
// s/t are in texel units; inv_w = 1.0 for affine texturing.
pub inline fn texturedTriangle(cmd_queue: anytype, tile: u3, v1_in: TexVertex, v2_in: TexVertex, v3_in: TexVertex) void {
    // Sort by Y ascending (top = smallest Y).
    var v1 = v1_in; var v2 = v2_in; var v3 = v3_in;
    if (v1.y > v2.y) { const t = v1; v1 = v2; v2 = t; }
    if (v2.y > v3.y) { const t = v2; v2 = v3; v3 = t; }
    if (v1.y > v2.y) { const t = v1; v1 = v2; v2 = t; }

    // ── Edge coefficients ─────────────────────────────────────────
    // Y values floored to 1/4-pixel (the RDP rasterises at 1/4-pixel precision).
    const y1 = @floor(v1.y * 4.0) / 4.0;
    const y2 = @floor(v2.y * 4.0) / 4.0;
    const y3 = @floor(v3.y * 4.0) / 4.0;

    // Y in 11.2 fixed-point, clamped to 14-bit signed range.
    const y1f = @as(i32, @intFromFloat(@max(-16384.0, @min(16383.0, @floor(v1.y * 4.0)))));
    const y2f = @as(i32, @intFromFloat(@max(-16384.0, @min(16383.0, @floor(v2.y * 4.0)))));
    const y3f = @as(i32, @intFromFloat(@max(-16384.0, @min(16383.0, @floor(v3.y * 4.0)))));

    const x1 = v1.x; const x2 = v2.x; const x3 = v3.x;

    // Edge vectors: h = v3-v1 (high/major), m = v2-v1 (mid), l = v3-v2 (low).
    const hx = x3 - x1; const hy = y3 - y1;
    const mx = x2 - x1; const my = y2 - y1;
    const lx = x3 - x2; const ly = y3 - y2;

    // Triangle "normal" (signed area * 2). Determines left-major vs right-major.
    const nz = hx * my - hy * mx;
    const lft: u1 = if (nz < 0) 1 else 0;
    const attr_factor: f32 = if (nz != 0.0) -1.0 / nz else 0.0;

    // Inverse slopes (dx/dy) for each edge.
    const ish = if (hy != 0.0) hx / hy else 0.0;
    const ism = if (my != 0.0) mx / my else 0.0;
    const isl = if (ly != 0.0) lx / ly else 0.0;

    // Fractional scanline offset for the top vertex.
    const fy = @floor(y1) - y1;

    // Initial X positions for each edge at the top scanline.
    const xh = x1 + fy * ish;
    const xm = x1 + fy * ism;
    const xl = x2;

    // Pack 14-bit signed Y values (two's-complement truncation).
    const yh: u64 = @as(u64, @as(u14, @truncate(@as(u32, @bitCast(y1f)))));
    const ym: u64 = @as(u64, @as(u14, @truncate(@as(u32, @bitCast(y2f)))));
    const yl: u64 = @as(u64, @as(u14, @truncate(@as(u32, @bitCast(y3f)))));

    // Word 0: command header.
    cmd_queue.queue.push(
        (@as(u64, 0x0A) << 56) | // TRI_TEX opcode
        (@as(u64, lft)  << 55) | // left-major flag
        (@as(u64, tile) << 48) | // tile [50:48]
        (yl             << 32) | // YL = bottom Y [45:32]
        (ym             << 16) | // YM = middle Y [29:16]
        yh                       // YH = top Y    [13:0]
    );
    // Words 1-3: XL/ISL, XH/ISH, XM/ISM (all s16.16).
    cmd_queue.queue.push(pack32(f32ToFp(xl),  f32ToFp(isl)));
    cmd_queue.queue.push(pack32(f32ToFp(xh),  f32ToFp(ish)));
    cmd_queue.queue.push(pack32(f32ToFp(xm),  f32ToFp(ism)));

    // Scale S/T to internal texel*32 format; apply perspective correction.
    var s1 = v1.s * 32.0; var t1 = v1.t * 32.0; var w1 = v1.inv_w;
    var s2 = v2.s * 32.0; var t2 = v2.t * 32.0; var w2 = v2.inv_w;
    var s3 = v3.s * 32.0; var t3 = v3.t * 32.0; var w3 = v3.inv_w;

    // Normalise W so the largest inv_w = 1.0, then scale to [0, 0x7FFF].
    const minw = 1.0 / @max(@max(w1, w2), w3);
    w1 *= minw; w2 *= minw; w3 *= minw;
    s1 *= w1; t1 *= w1;
    s2 *= w2; t2 *= w2;
    s3 *= w3; t3 *= w3;
    w1 *= 0x7FFF; w2 *= 0x7FFF; w3 *= 0x7FFF;

    const ms = s2 - s1; const mt = t2 - t1; const mw = w2 - w1;
    const hs = s3 - s1; const ht = t3 - t1; const hw = w3 - w1;

    // Cross-product gradient components for each attribute.
    const DsDx = (hy * ms - my * hs) * attr_factor;
    const DtDx = (hy * mt - my * ht) * attr_factor;
    const DwDx = (hy * mw - my * hw) * attr_factor;
    const DsDy = (mx * hs - hx * ms) * attr_factor;
    const DtDy = (mx * ht - hx * mt) * attr_factor;
    const DwDy = (mx * hw - hx * mw) * attr_factor;

    // Along-edge gradient (de = dy + dx*ish).
    const DsDe = DsDy + DsDx * ish;
    const DtDe = DtDy + DtDx * ish;
    const DwDe = DwDy + DwDx * ish;

    // Attribute values at the first raster position of the top vertex.
    const fs = f32ToFp(s1 + fy * DsDe);
    const ft = f32ToFp(t1 + fy * DtDe);
    const fw = f32ToFp(w1 + fy * DwDe);

    const DsDx_f = f32ToFp(DsDx); const DtDx_f = f32ToFp(DtDx); const DwDx_f = f32ToFp(DwDx);
    const DsDe_f = f32ToFp(DsDe); const DtDe_f = f32ToFp(DtDe); const DwDe_f = f32ToFp(DwDe);
    const DsDy_f = f32ToFp(DsDy); const DtDy_f = f32ToFp(DtDy); const DwDy_f = f32ToFp(DwDy);

    // Words 4-11: 8 × 64-bit texture words.
    // Layout: [int(S) int(T) int(W) 0] paired with [int(dSdX) int(dTdX) int(dWdX) 0],
    // followed by their fractional halves — matching the RDP TRI_TEX coefficient format.
    cmd_queue.queue.push(packSTW_i(fs,      ft,      fw));
    cmd_queue.queue.push(packSTW_i(DsDx_f,  DtDx_f,  DwDx_f));
    cmd_queue.queue.push(packSTW_f(fs,      ft,      fw));
    cmd_queue.queue.push(packSTW_f(DsDx_f,  DtDx_f,  DwDx_f));
    cmd_queue.queue.push(packSTW_i(DsDe_f,  DtDe_f,  DwDe_f));
    cmd_queue.queue.push(packSTW_i(DsDy_f,  DtDy_f,  DwDy_f));
    cmd_queue.queue.push(packSTW_f(DsDe_f,  DtDe_f,  DwDe_f));
    cmd_queue.queue.push(packSTW_f(DsDy_f,  DtDy_f,  DwDy_f));
}

/// Vertex for textured triangle commands. s/t are in texel units.
/// Set inv_w = 1.0 for affine (non-perspective) texturing.
pub const TexVertex = struct {
    x: f32,
    y: f32,
    s: f32,
    t: f32,
    inv_w: f32 = 1.0,
};


// Convert f32 to S16.16 fixed-point (clamped).
fn f32ToFp(f: f32) i32 {
    if (f >= 32768.0)  return 0x7FFFFFFF;
    if (f < -32768.0)  return @bitCast(@as(u32, 0x80000000));
    return @intFromFloat(@floor(f * 65536.0));
}

// Pack two S16.16 values into one 64-bit word: hi in [63:32], lo in [31:0].
fn pack32(hi: i32, lo: i32) u64 {
    return (@as(u64, @as(u32, @bitCast(hi))) << 32) |
            @as(u64, @as(u32, @bitCast(lo)));
}

// Pack the integer parts (upper 16 bits) of three S16.16 values into a 64-bit word.
// Layout: [S_int:47..32] [T_int:31..16] [W_int:15..0].  Matches RDP TRI_TEX format.
fn packSTW_i(s: i32, t: i32, w: i32) u64 {
    const su: u32 = @bitCast(s);
    const tu: u32 = @bitCast(t);
    const wu: u32 = @bitCast(w);
    return (@as(u64, su >> 16) << 48) |
           (@as(u64, tu >> 16) << 32) |
           (@as(u64, wu >> 16) << 16);
}

// Pack the fractional parts (lower 16 bits) of three S16.16 values into a 64-bit word.
fn packSTW_f(s: i32, t: i32, w: i32) u64 {
    const su: u32 = @bitCast(s);
    const tu: u32 = @bitCast(t);
    const wu: u32 = @bitCast(w);
    return (@as(u64, su & 0xFFFF) << 48) |
           (@as(u64, tu & 0xFFFF) << 32) |
           (@as(u64, wu & 0xFFFF) << 16);
}
