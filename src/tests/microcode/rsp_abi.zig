//! Supplies the RSP interpreter's ABI import from the host `n64` module so the
//! runtime's ABI files belong to a single module in this compilation.
const abi = @import("n64").rsp.host_abi;

pub const Program = abi.Program;
pub const overlay_layout = abi.overlay_layout;
pub const InternalCommand = abi.InternalCommand;
pub const fetch_window_byte_len = abi.fetch_window_byte_len;
