pub const control:           *volatile Control = @ptrFromInt(0xA4400000);
pub const frame_buffer_addr: *volatile u32     = @ptrFromInt(0xA4400004);
pub const vi_width:          *volatile u32     = @ptrFromInt(0xA4400008);
pub const vi_v_int:          *volatile u32     = @ptrFromInt(0xA440000C);
pub const vi_v_current:      *volatile u32     = @ptrFromInt(0xA4400010);
pub const vi_burst:          *volatile u32     = @ptrFromInt(0xA4400014);
pub const vi_v_total:        *volatile u32     = @ptrFromInt(0xA4400018);
pub const vi_h_total:        *volatile u32     = @ptrFromInt(0xA440001C);
pub const vi_h_total_leap:   *volatile u32     = @ptrFromInt(0xA4400020);
pub const vi_h_video:        *volatile u32     = @ptrFromInt(0xA4400024);
pub const vi_v_video:        *volatile u32     = @ptrFromInt(0xA4400028);
pub const vi_v_burst:        *volatile u32     = @ptrFromInt(0xA440002C);
pub const vi_x_scale:        *volatile u32     = @ptrFromInt(0xA4400030);
pub const vi_y_scale:        *volatile u32     = @ptrFromInt(0xA4400034);

const TvType = enum(u2) {
    Ntsc,
    Pal,
    MPal,
};

const ScanMode = enum(u1) {
    Progressive,
    Interlaced
};

pub const Control = packed struct(u32){
    unused0: u15 = 0,
    deDitherEnable: bool = false,
    pixelAdvance: u4 = 0b011,
    killWe: bool = false,
    unused1: bool = false,
    antiAliasMode: AntiAliasMode = .Always,
    testMode: bool = false,
    serrate: bool = false,
    vbusClockEnable: bool = false, // WARNING: Don't enable, can damage console
    divonEnable: bool = false,
    gammaEnable: bool = true,
    gammaDitherEnable: bool = true,
    colorDepth: ColorDepth = .RGBA5553,
};

pub const AntiAliasMode = enum(u2) {
    Always,
    Needed,
    Resample,
    Replicate,
};

pub const ColorDepth = enum(u2) {
    Off,
    Unused,
    RGBA5553,
    RGBA8888,
};


pub fn setTvType(tv: TvType, scan: ScanMode) void {
    vi_v_int.* = 2;
    vi_burst.* = switch (tv) {
        .Ntsc => 0x03e52239,
        .Pal =>  0x0404233a,
        .MPal => 0x04651e39,
    };
    vi_v_total.* = switch (tv) {
        .Ntsc, .MPal => if(scan == .Interlaced) 0x0000020c else 0x0000020d,
        .Pal => if(scan == .Interlaced) 0x00000270 else 0x00000271,
    };
    vi_h_total.* = switch (tv) {
        .Ntsc => 0x00000c15,
        .Pal => 0x00150c69,
        .MPal => if(scan == .Interlaced) 0x00000c10 else 0x00040c11,
    };
    vi_h_total_leap.* = switch (tv) {
        .Ntsc => 0x0c150c15,
        .Pal => 0x0c6f0c6e,
        .MPal => if(scan == .Interlaced) 0x0c1c0c1c else 0x0c190c1a,
    };
    vi_h_video.* = switch (tv) {
        .Ntsc => 0x006c02ec,
        .Pal => 0x00800300,
        .MPal => 0x006c02ec,
    };

    vi_v_video.* = switch (tv) {
        .Ntsc, .MPal => if(scan == .Interlaced) 0x002301fd else 0x002501ff,
        .Pal => if(scan == .Interlaced) 0x005d0237 else 0x005f0239,
    };
    vi_v_burst.* = switch (tv) {
        .Ntsc => 0x000e0204,
        .Pal => 0x0009026b,
        .MPal => if(scan == .Interlaced) 0x000b0202 else 0x000e0204
    };
}

