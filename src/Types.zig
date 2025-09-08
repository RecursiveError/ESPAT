const std = @import("std");

pub const DriverError = error{
    DRIVER_OFF,
    WIFI_OFF,

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
    INVALID_PKG,
    NO_send_data,
    UNKNOWN_ERROR,
    UNSUPPORTED,
};

pub const RunnerError = error{
    BUSY,
    OFF,
    INVALID_PKG,
    INVALID_RESPONSE,
    NO_DEVICE,
    TASK_QUEUE_FULL,
    DEVICE_LIST_FULL,
    INVALID_ID,
    NON_RECOVERABLE_ERROR,
};

pub const DeviceError = error{
    NO_SEND_DATA,
    UNSUPPORTED,
    QUEUE_EMPTY,
    QUEUE_FAIL,
    QUEUE_FULL,
    CMD_FAIL,
    SETUP_FAIL,
    SEND_FAIL,
    INVALID_RESPONSE,
    FATAL_ERROR,
};

pub const ToRead = struct {
    to_read: usize,
    data_offset: usize,
    start_index: usize,
    notify: *const fn ([]const u8, *anyopaque) void,
    user_data: *anyopaque,
};

pub const Runner = struct {
    set_busy_flag_fn: *const fn (*const Runner, bool, u32) RunnerError!void,
    set_long_data_fn: *const fn (*const Runner, ToRead) void,
    queue_free_size_fn: *const fn (*const Runner) usize,
    queue_current_size_fn: *const fn (*const Runner) usize,
    link_device_fn: *const fn (*const Runner, *const Device) RunnerError!u32,
    release_device_fn: *const fn (*const Runner, u32) RunnerError!void,
    queue_fn: *const fn (*const Runner, u32) RunnerError!void,
    cancel_fn: *const fn (*const Runner, u32, usize) void,
    take_reader_fn: *const fn (*const Runner) RunnerError!*std.io.Reader,

    pub inline fn set_busy_flag(self: *const Runner, busy: bool, id: u32) RunnerError!void {
        return self.set_busy_flag_fn(self, busy, id);
    }

    pub inline fn set_long_data(self: *const Runner, to_read: ToRead) void {
        self.set_long_data_fn(self, to_read);
    }

    pub inline fn queue_free_size(self: *const Runner) usize {
        return self.queue_free_size_fn(self);
    }

    pub inline fn queue_corrent_size(self: *const Runner) usize {
        return self.queue_corrent_size_fn(self);
    }

    pub inline fn link_device(self: *const Runner, device: *const Device) RunnerError!u32 {
        return self.link_device_fn(self, device);
    }

    pub inline fn release_device(self: *const Runner, id: u32) RunnerError!void {
        return self.release_device_fn(self, id);
    }

    pub inline fn queue(self: *const Runner, id: u32) RunnerError!void {
        return self.queue_fn(self, id);
    }

    pub fn queue_multi(self: *const Runner, id: u32, qtd: usize) RunnerError!void {
        if (self.queue_free_size() < qtd) return RunnerError.TASK_QUEUE_FULL;
        for (0..qtd) |_| {
            self.queue(id) catch unreachable;
        }
    }

    pub inline fn queue_cancel(self: *const Runner, id: u32, qtd: usize) void {
        self.cancel_fn(self, id, qtd);
    }

    pub inline fn take_reader(self: *const Runner) RunnerError!*std.io.Reader {
        return self.take_reader_fn(self);
    }
};

pub const Device = struct {
    get_cmd_fn: *const fn (*const Device, *std.io.Writer) DeviceError!void,
    check_cmd_fn: *const fn (*const Device, []const u8, []const u8) DeviceError!void,

    send_data_fn: *const fn (*const Device, *std.io.Writer) DeviceError!void,

    ok_handler_fn: *const fn (*const Device) void,
    err_handler_fn: *const fn (*const Device) void,
    send_handler_fn: *const fn (*const Device, bool) void,

    reset_fn: *const fn (*const Device) DeviceError!void,

    pub inline fn get_cmd(self: *const Device, writer: *std.io.Writer) DeviceError!void {
        return self.get_cmd_fn(self, writer);
    }

    pub inline fn check_cmd(self: *const Device, cmd: []const u8, all: []const u8) DeviceError!void {
        return self.check_cmd_fn(self, cmd, all);
    }

    pub inline fn send_data(self: *const Device, writer: *std.io.Writer) DeviceError!void {
        return self.send_data_fn(self, writer);
    }

    pub inline fn ok_handler(self: *const Device) void {
        self.ok_handler_fn(self);
    }

    pub inline fn err_handler(self: *const Device) void {
        self.err_handler_fn(self);
    }

    pub inline fn send_handler(self: *const Device, success: bool) void {
        self.send_handler_fn(self, success);
    }

    pub inline fn reset(self: *const Device) DeviceError!void {
        try self.reset_fn(self);
    }
};
