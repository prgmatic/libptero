const control:           *volatile Control = @ptrFromInt(0xA4400000);
const frame_buffer_addr: *volatile u32     = @ptrFromInt(0xA4400004);
const vi_width:          *volatile u32     = @ptrFromInt(0xA4400008);
const vi_v_interrupt:    *volatile u32     = @ptrFromInt(0xA440000C);
const vi_v_current:      *volatile u32     = @ptrFromInt(0xA4400010);
const vi_burst:          *volatile u32     = @ptrFromInt(0xA4400014);
const vi_v_total:        *volatile u32     = @ptrFromInt(0xA4400018);
const vi_h_total:        *volatile u32     = @ptrFromInt(0xA440001C);
const vi_h_total_leap:   *volatile u32     = @ptrFromInt(0xA4400020);
const vi_h_video:        *volatile u32     = @ptrFromInt(0xA4400024);
const vi_v_video:        *volatile u32     = @ptrFromInt(0xA4400028);
const vi_v_burst:        *volatile u32     = @ptrFromInt(0xA440002C);
const vi_x_scale:        *volatile u32     = @ptrFromInt(0xA4400030);
const vi_y_scale:        *volatile u32     = @ptrFromInt(0xA4400034);

var detected_tv_type: TvType = .ntsc;

const TvType = enum(u2) {
    pal,
    ntsc,
    m_pal,
};

const ScanMode = enum(u1) {
    progressive,
    interlaced
};

pub const Control = packed struct(u32){
    color_depth: ColorDepth = .Rgba5551,
    gamma_dither_enable: bool = false,
    gamma_enable: bool = false,
    divot_enable: bool = false,
    vbus_clock_enable: bool = false, // WARNING: Don't enable, can damage console
    serrate: bool = false,
    test_mode: bool = false,
    anti_alias_mode: AntiAliasMode = .Resample,
    unused1: bool = false,
    kill_we: bool = false,
    pixel_advance: u4 = 0b011,
    de_dither_enable: bool = false,
    unused0: u15 = 0,
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
    Rgba5551,
    Rgba32,
};


pub const VideoInitOptions = struct {
    tv: TvType = .ntsc,
    resolution: Resolution = .@"320x240p",
    anti_alias_mode: AntiAliasMode = .Resample,
    de_dither_enabled: bool = false,
    color_depth: ColorDepth = .Rgba5551,
    gamma_enabled: bool = false,
};


pub fn init(options: VideoInitOptions) void {
    const resInfo = resolutions[@intFromEnum(options.resolution)];
    setTvType(options.tv, resInfo.scan_mode);
    vi_width.* = resInfo.width;
    vi_x_scale.* = (1024 * resInfo.width + 320) / 640;
    vi_y_scale.* = (1024 * resInfo.height + 120) / 240;
    
    control.* = .{
        .anti_alias_mode = options.anti_alias_mode,
        .de_dither_enable = options.de_dither_enabled,
        .color_depth = options.color_depth,
        .gamma_enable = options.gamma_enabled,
    };
}

pub fn setTvType(tv: TvType, scan: ScanMode) void {
    vi_v_interrupt.* = 2;
    vi_burst.* = switch (tv) {
        .ntsc => 0x03e52239,
        .pal =>  0x0404233a,
        .m_pal => 0x04651e39,
    };
    vi_v_total.* = switch (tv) {
        .ntsc, .m_pal => if(scan == .interlaced) 0x0000020c else 0x0000020d,
        .pal => if(scan == .interlaced) 0x00000270 else 0x00000271,
    };
    vi_h_total.* = switch (tv) {
        .ntsc => 0x00000c15,
        .pal => 0x00150c69,
        .m_pal => if(scan == .interlaced) 0x00000c10 else 0x00040c11,
    };
    vi_h_total_leap.* = switch (tv) {
        .ntsc => 0x0c150c15,
        .pal => 0x0c6f0c6e,
        .m_pal => if(scan == .interlaced) 0x0c1c0c1c else 0x0c190c1a,
    };
    vi_h_video.* = switch (tv) {
        .ntsc => 0x006c02ec,
        .pal => 0x00800300,
        .m_pal => 0x006c02ec,
    };

    vi_v_video.* = switch (tv) {
        .ntsc, .m_pal => if(scan == .interlaced) 0x002301fd else 0x002501ff,
        .pal => if(scan == .interlaced) 0x005d0237 else 0x005f0239,
    };
    vi_v_burst.* = switch (tv) {
        .ntsc => 0x000e0204,
        .pal => 0x0009026b,
        .m_pal => if(scan == .interlaced) 0x000b0202 else 0x000e0204
    };
}

pub fn setFrameBuffer(buffer_addr: u32) void {
    frame_buffer_addr.* = buffer_addr;
}

pub fn claerInterrupt() void {
    vi_v_current.* = vi_v_current.*;
}

pub const Resolution = enum(u8) {
    @"256x240p",
    @"320x240p",
    @"512x240p",
    @"640x240p",
    @"512x480i",
    @"640x680i",
};

const ResolutionInfo = struct {
    width: u32,
    height: u32,
    scan_mode: ScanMode
};

const resolutions = [_]ResolutionInfo {
    .{ .width = 256, .height = 240, .scan_mode = .progressive },
    .{ .width = 320, .height = 240, .scan_mode = .progressive },
    .{ .width = 512, .height = 240, .scan_mode = .progressive },
    .{ .width = 640, .height = 240, .scan_mode = .progressive },
    .{ .width = 512, .height = 480, .scan_mode = .interlaced },
    .{ .width = 640, .height = 480, .scan_mode = .interlaced },
};
