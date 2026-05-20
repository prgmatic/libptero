
pub const SpriteDrawOptions = struct {
    tile_index: u3 = 0,
    s0: u8 = 0,
    t0: u8 = 0,
    width: u8 = 0,      // 0 = full texture width
    height: u8 = 0,     // 0 = full texture height
    flip_x: bool = false,
    flip_y: bool = false,
    pivot: Pivot = .top_left,
    scale_x: f32 = 1.0, // negative applies additional flip
    scale_y: f32 = 1.0,
    rotation: f32 = 0.0, // not yet implemented
};

pub const Pivot = union(enum) {
    top_left,
    top_middle,
    top_right,
    middle_left,
    center,
    middle_right,
    bottom_left,
    bottom_middle,
    bottom_right,

    custom: struct {
        x: u8,
        y: u8,
    },
};
