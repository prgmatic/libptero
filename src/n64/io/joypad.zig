
pub const JoypadStyle = enum(u8) {
    None,
    N64,
    GameCube,
    Mouse
};

pub const JoypadAccessory = enum(u8) {
    Noen,
    Unknown,
    ControllerPak,
    RumblePak,
    TransferPak,
    BioSensor,
    SnapStation
};

pub const JoypadState = packed struct {
    y_axis: i8,
    x_axis: i8,
    c_right: bool,
    c_left: bool,
    c_down: bool,
    c_up: bool,
    rt: bool,
    lt: bool, 
    unused : bool,
    reset : bool,
    d_right : bool,
    d_left : bool,
    d_down : bool,
    d_up : bool,
    start : bool,
    z : bool,
    b : bool,
    a : bool,
};
