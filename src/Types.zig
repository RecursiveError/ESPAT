const Commands_util = @import("util/commands.zig");
const WiFi = @import("util/WiFi.zig");
const Network = @import("util/network.zig");

pub const DriverError = error{
    DRIVER_OFF,
    WIFI_OFF,
    BUSY,
    AP_OFF,
    STA_OFF,
    SERVER_DISLABE,
    SERVER_OFF,
    CLIENT_DISABLE,
    CLIENT_DISCONNECTED,
    RX_BUFFER_FULL,
    TX_BUFFER_FULL,
    TASK_BUFFER_FULL,
    NETWORK_BUFFER_FULL,
    AUX_BUFFER_EMPTY,
    AUX_BUFFER_FULL,
    NETWORK_BUFFER_EMPTY,
    INVALID_RESPONSE,
    ALLOC_FAIL,
    MAX_BIND,
    INVALID_BIND,
    INVALID_NETWORK_TYPE,
    INVALID_ARGS,
    NON_RECOVERABLE_ERROR,
    UNKNOWN_ERROR,
};

pub const BluetoothPackage = struct {
    //TODO
};

pub const TXExtraData = union(enum) {
    Reset: void,
    Command: Commands_util.Package,
    Socket: Network.Package,
    WiFi: WiFi.Package,
    Bluetooth: BluetoothPackage,
};

pub const TXEventPkg = struct {
    cmd_enum: Commands_util.Commands,
    Extra_data: TXExtraData,
};

pub const ToRead = struct {
    to_read: usize,
    data_offset: usize,
    start_index: usize,
    notify: *const fn ([]const u8, *anyopaque) void,
    user_data: *anyopaque,
};

pub const Runner = struct {
    runner_instance: *anyopaque,
    set_busy_flag: *const fn (u1, *anyopaque) void,
    set_long_data: *const fn (ToRead, *anyopaque) void,
    get_tx_data: *const fn (*anyopaque) ?TXEventPkg,
    get_tx_free_space: *const fn (*anyopaque) usize,
    get_tx_len: *const fn (*anyopaque) usize,
    store_tx_data: *const fn (TXEventPkg, *anyopaque) DriverError!void,
};

pub const Device = struct {
    device_instance: *anyopaque = undefined,
    apply_cmd: *const fn (TXEventPkg, []u8, *anyopaque) []const u8 = undefined,
    pool_data: *const fn (*anyopaque) []const u8,
    check_cmd: *const fn ([]const u8, []const u8, *anyopaque) DriverError!void,
    ok_handler: *const fn (*anyopaque) void,
    err_handler: *const fn (*anyopaque) void,
};
