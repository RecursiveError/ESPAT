const std = @import("std");
const fifo = std.fifo;
const Types = @import("Types.zig");
const util = @import("util/commands.zig");
const prefix = util.prefix;
const postfix = util.postfix;
const get_cmd_string = util.get_cmd_string;

pub const DataBits = enum(u8) {
    @"5" = 5,
    @"6" = 6,
    @"7" = 7,
    @"8" = 8,
};

pub const StopBits = enum(u8) {
    @"1" = 1,
    @"1.5" = 2,
    @"2" = 3,
};

pub const Parity = enum {
    none,
    odd,
    even,
};

pub const FlowControl = enum {
    none,
    rts,
    cts,
    both,
};

pub const UartConfig = struct {
    baudrate: u32,
    databits: DataBits = .@"8",
    stopbits: StopBits = .@"1",
    parity: Parity = .none,
    flowcontrol: FlowControl = .none,
};

pub const CmdPkg = struct {
    str: [30]u8 = undefined,
    len: usize = undefined,
    busy: bool = false,
};
const Device = Types.Device;
const Runner = Types.Runner;
const DeviceError = Types.DeviceError;

pub const BasicCommands = struct {
    pub const Reset_Handler_Type = *const fn (user_data: ?*anyopaque) void;
    const CMD_CALLBACK_TYPE = *const fn (self: *BasicCommands, buffer: []const u8) DeviceError!void;
    const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
        .{ "ready", ready_handler },
    });

    id: u32,
    reset_callback: Reset_Handler_Type = undefined,
    reset_userdata: ?*anyopaque = null,

    cmd_queue: fifo.LinearFifo(CmdPkg, .{ .Static = 10 }),
    runner: *const Runner = undefined,
    device_dev: Device = .{
        .check_cmd_fn = check_cmd,
        .get_cmd_fn = get_cmd,
        .pool_data_fn = pool_data,
        .ok_handler_fn = ok_handler,
        .err_handler_fn = err_handler,
        .send_handler_fn = send_handler,
        .reset_fn = reset,
    },

    fn get_cmd(device: *const Device, out_buf: []u8) DeviceError![]const u8 {
        var self: *BasicCommands = @alignCast(@constCast(@fieldParentPtr("device_dev", device)));

        const cmd = self.cmd_queue.readItem() orelse return DeviceError.QUEUE_EMPTY;
        if (cmd.busy) self.runner.set_busy_flag(true, self.id) catch unreachable;
        return std.fmt.bufPrint(out_buf, "{s}", .{cmd.str[0..cmd.len]}) catch return DeviceError.CMD_FAIL;
    }
    fn check_cmd(device: *const Device, response: []const u8, full_msg: []const u8) DeviceError!void {
        _ = full_msg;
        const self: *BasicCommands = @alignCast(@constCast(@fieldParentPtr("device_dev", device)));
        const callback = cmd_response_map.get(response) orelse return;
        try @call(.auto, callback, .{ self, response });
    }

    fn pool_data(_: *const Device) DeviceError![]const u8 {
        return DeviceError.POOL_DATA_EMPTY;
    }

    fn ok_handler(_: *const Device) void {}
    fn err_handler(_: *const Device) void {}
    fn send_handler(_: *const Device, _: bool) void {}
    fn reset(_: *const Device) void {}

    fn ready_handler(self: *BasicCommands, _: []const u8) DeviceError!void {
        self.runner.set_busy_flag(false, self.id) catch unreachable;
        self.reset_callback(self.reset_userdata);
    }

    //pub fn set_UART(self: *BasicCommands, config: UartConfig) !void {
    //    if ((self.machine_state != .init) or (self.machine_state != .OFF)) return error.DriverRunning;
    //    if ((config.baudrate > 50_000_000) or (config.baudrate < 80)) return error.INVALID_ARGS;
    //    const cmd = try std.fmt.bufPrint(&self.internal_aux_buffer, "{s}{s}{s}={d},{d},{d},{d},{d}{s}", .{
    //        util.prefix,
    //        "UART",
    //        "_DEF",
    //        config.baudrate,
    //        @intFromEnum(config.databits),
    //        @intFromEnum(config.stopbits),
    //        @intFromEnum(config.parity),
    //        @intFromEnum(config.flowcontrol),
    //        util.postfix,
    //    });
    //
    //    self.runner.queue(self.id) catch unreachable;
    //    self.cmd_queue.writeItem(pkg) catch unreachable;
    //}

    pub fn soft_reset(self: *BasicCommands) !void {
        var pkg: CmdPkg = .{};

        //send dummy cmd to clear the module input
        var cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}", .{ get_cmd_string(.DUMMY), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner.queue(self.id) catch unreachable;
        self.cmd_queue.writeItem(pkg) catch unreachable;

        //send RST request
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}{s}", .{ prefix, get_cmd_string(.RESET), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        pkg.busy = true;

        self.runner.queue(self.id) catch unreachable;
        self.cmd_queue.writeItem(pkg) catch unreachable;
    }

    pub fn init_driver(self: *BasicCommands) !void {
        var pkg: CmdPkg = .{};

        //desable ECHO
        var cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}", .{ get_cmd_string(.ECHO_OFF), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner.queue(self.id) catch unreachable;
        self.cmd_queue.writeItem(pkg) catch unreachable;

        //disable sysstore
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=0{s}", .{ prefix, get_cmd_string(.SYSSTORE), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner.queue(self.id) catch unreachable;
        self.cmd_queue.writeItem(pkg) catch unreachable;

        //enable error logs
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.SYSLOG), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner.queue(self.id) catch unreachable;
        self.cmd_queue.writeItem(pkg) catch unreachable;

        //enable +LINK msg
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=2{s}", .{ prefix, get_cmd_string(.SYSMSG), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner.queue(self.id) catch unreachable;
        self.cmd_queue.writeItem(pkg) catch unreachable;

        //enable IP info
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.NETWORK_MSG_CONFIG), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner.queue(self.id) catch unreachable;
        self.cmd_queue.writeItem(pkg) catch unreachable;

        //enable multi-conn
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.IP_MUX), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner.queue(self.id) catch unreachable;
        self.cmd_queue.writeItem(pkg) catch unreachable;

        //disable wifi auto connection
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=0{s}", .{ prefix, get_cmd_string(.WIFI_AUTOCONN), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner.queue(self.id) catch unreachable;
        self.cmd_queue.writeItem(pkg) catch unreachable;
    }
};
