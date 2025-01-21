const std = @import("std");

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
    INVALID_RESPONSE,
    NO_DEVICE,
    MAX_BIND,
    INVALID_BIND,
    INVALID_NETWORK_TYPE,
    INVALID_ARGS,
    NON_RECOVERABLE_ERROR,
    INVALID_PKG,
    NO_POOL_DATA,
    UNKNOWN_ERROR,
};

pub const Devices = enum {
    Basic,
    WiFi,
    Bluethooth,
    BluethoothLE,
    TCP_IP,
    HTTP,
    MQTT,
    Filesystem,
    WebSocket,
    Ethernet,
    WebServer,
    Driver,
    User,
    //extra devices
    Command,
    Custom,
};

pub const TXPkg = struct {
    device: Devices,
    buffer: [80]u8,

    pub fn init(dev: Devices, data: []const u8) TXPkg {
        var buf: [80]u8 = undefined;
        std.mem.copyForwards(u8, &buf, data);
        return TXPkg{ .device = dev, .buffer = buf };
    }

    pub fn convert_type(dev: Devices, t: anytype) TXPkg {
        if (@sizeOf(@TypeOf(t)) > @sizeOf(TXPkg)) {
            @compileError(std.fmt.comptimePrint("Type {s} cannot fit in TxPkg", .{@typeName(@TypeOf(t))}));
        }
        const data = std.mem.asBytes(&t);
        return init(dev, data);
    }
};

pub const ApplyCallbackType = *const fn (TXPkg, []u8, *anyopaque) ?[]const u8;

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
    get_tx_data: *const fn (*anyopaque) ?TXPkg,
    get_tx_free_space: *const fn (*anyopaque) usize,
    get_tx_len: *const fn (*anyopaque) usize,
    store_tx_data: *const fn (TXPkg, *anyopaque) DriverError!void,
};

pub const Device = struct {
    device_instance: *anyopaque = undefined,
    apply_cmd: *const fn (TXPkg, []u8, *anyopaque) DriverError![]const u8,
    pool_data: *const fn (*anyopaque) DriverError![]const u8,
    check_cmd: *const fn ([]const u8, []const u8, *anyopaque) DriverError!void,
    ok_handler: *const fn (*anyopaque) void,
    err_handler: *const fn (*anyopaque) void,
};
