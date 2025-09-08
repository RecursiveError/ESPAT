const std = @import("std");

const Types = @import("Types.zig");
const Device = Types.Device;
const Runner = Types.Runner;
const ToRead = Types.ToRead;
const DriverError = Types.DriverError;
const RunnerError = Types.RunnerError;
const DeviceError = Types.DeviceError;
const Commands_util = @import("util/commands.zig");
const Commands = Commands_util.Commands;
const postfix = Commands_util.postfix;
const prefix = Commands_util.prefix;
const infix = Commands_util.infix;

const get_cmd_string = Commands_util.get_cmd_string;
const get_cmd_slice = Commands_util.get_cmd_slice;
const CommandErrorCodes = Commands_util.CommandsErrorCode;

pub const ReponseEvent = Commands_util.ResponseEvent;

pub const TypeConfig = struct {
    RX_size: usize = 2048,
    TX_event_pool: usize = 25,
    process_buffer: usize = 2048,
};

pub const CmdPkg = struct {
    str: [30]u8 = undefined,
    len: usize = undefined,
    busy: bool = false,
};

pub const RunnerConfig = struct {
    writer: *std.io.Writer,
    reader: *std.io.Reader,
    event_queue: []u32,
    reset_callback: ResetCallback = null,
    reset_userdata: ?*anyopaque = null,
};

const Drive_states = enum {
    INIT,
    IDLE,
    OFF,
    FATAL_ERROR,
};

const SendMap = std.StaticStringMap(bool).initComptime(.{
    .{ "OK\r\n", true },
    .{ "FAIL\r\n", false },
});

pub const ResetCallback = ?*const fn (user_data: ?*anyopaque) void;

pub const StdRunnerError = error{
    SEND_ERROR,
    NON_RECOVERABLE_ERROR,
    OFF,
} || RunnerError;

//TODO: remove ArrayList and use ringbuffer
pub const StdRunner = struct {
    const Self = @This();

    // ========= data types ============
    const CMD_CALLBACK_TYPE = *const fn (self: *Self, aux_buffer: []const u8) RunnerError!void;
    const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
        .{ "ready", Self.ready_response },
        .{ "OK", Self.ok_response },
        .{ "ERROR", Self.error_response },
        .{ "FAIL", Self.error_response },
        .{ "ERR", Self.parser_error_code },
        .{ "SEND", Self.send_parser },
    });

    reader: *std.io.Reader,
    writer: *std.io.Writer,

    event_queue: std.ArrayList(u32),
    cmd_buffer: [15]CmdPkg = undefined,
    cmd_queue: std.ArrayList(CmdPkg) = undefined,
    aux_buffer: [256]u8 = @splat(0),

    Resetcallback_handler: ResetCallback,
    reset_userdata: ?*anyopaque = null,

    //==========internal control data, (Do not modify)===============
    reader_taken: bool = false,
    cmd_busy: bool = false,
    busy_flag: u32 = 0,
    last_error_code: CommandErrorCodes = .ESP_AT_UNKNOWN_ERROR,
    machine_state: Drive_states = .OFF,

    last_device: ?u32 = null,
    device_list: [32]?*const Device = @splat(null),

    //========= Runner Vtable ===========
    runner_dev: Runner = .{
        .set_busy_flag_fn = set_busy_flag,
        .set_long_data_fn = set_long_data,
        .queue_free_size_fn = queue_free_size,
        .queue_current_size_fn = queue_current_size,
        .link_device_fn = link_device,
        .release_device_fn = release_device,
        .queue_fn = queue,
        .cancel_fn = queue_cancel,
        .take_reader_fn = take_reader,
    },

    //=========basic commands ===========
    //this runner needs a default command configuration to work.
    //that's why it has a built-in basic device at id 0
    device_dev: Device = .{
        .check_cmd_fn = check_cmd,
        .get_cmd_fn = get_cmd,
        .send_data_fn = pool_data,
        .ok_handler_fn = ok_handler,
        .err_handler_fn = err_handler,
        .send_handler_fn = send_handler,
        .reset_fn = reset,
    },

    fn get_cmd(device: *const Device, writer: *std.io.Writer) DeviceError!void {
        var self: *Self = @alignCast(@constCast(@fieldParentPtr("device_dev", device)));

        const cmd = self.cmd_queue.pop() orelse return DeviceError.QUEUE_EMPTY;
        if (cmd.busy) self.busy_flag |= 1;
        writer.print("{s}", .{cmd.str[0..cmd.len]}) catch unreachable;
        writer.flush() catch {};
    }
    fn check_cmd(_: *const Device, _: []const u8, _: []const u8) DeviceError!void {}
    fn pool_data(_: *const Device, _: *std.io.Writer) DeviceError!void {
        return DeviceError.NO_SEND_DATA;
    }
    fn ok_handler(_: *const Device) void {}
    fn err_handler(_: *const Device) void {}
    fn send_handler(_: *const Device, _: bool) void {}
    fn reset(device: *const Device) DeviceError!void {
        var self: *Self = @alignCast(@constCast(@fieldParentPtr("device_dev", device)));
        self.basic_setup();
    }

    fn set_busy_flag(runner: *const Runner, set: bool, id: u32) RunnerError!void {
        var self: *Self = @alignCast(@constCast(@fieldParentPtr("runner_dev", runner)));
        if (id > std.math.maxInt(u5)) return RunnerError.INVALID_ID; //this runner only have 32 devices;
        const mask: u32 = (@as(u32, 1) << @as(u5, @intCast(id)));
        if (set) {
            self.busy_flag |= mask;
        } else {
            self.busy_flag &= ~mask;
        }
    }

    fn set_long_data(_: *const Runner, _: ToRead) void {}
    fn queue_free_size(runner: *const Runner) usize {
        const self: *const Self = @alignCast(@fieldParentPtr("runner_dev", runner));
        return self.event_queue.capacity - self.event_queue.items.len;
    }

    fn queue_current_size(runner: *const Runner) usize {
        const self: *const Self = @alignCast(@fieldParentPtr("runner_dev", runner));
        return self.event_queue.items.len;
    }

    fn link_device(runner: *const Runner, device: *const Device) RunnerError!u32 {
        const self: *Self = @alignCast(@constCast(@fieldParentPtr("runner_dev", runner)));
        for (1..self.device_list.len) |i| {
            if (self.device_list[i]) |_| continue;
            self.device_list[i] = device;
            return @intCast(i);
        }
        return RunnerError.DEVICE_LIST_FULL;
    }

    fn release_device(runner: *const Runner, id: u32) RunnerError!void {
        var self: *Self = @alignCast(@constCast(@fieldParentPtr("runner_dev", runner)));
        if ((id > self.device_list.len) or (id == 0)) return RunnerError.INVALID_ID;
        self.device_list[id] = null;
        const len = self.event_queue.items.len;
        for (0..len) |_| {
            const val = self.event_queue.pop() orelse break;
            if (val != id) {
                self.event_queue.insertAssumeCapacity(0, val);
            }
        }
    }

    fn queue(runner: *const Runner, id: u32) RunnerError!void {
        var self: *Self = @alignCast(@constCast(@fieldParentPtr("runner_dev", runner)));
        self.event_queue.insertBounded(0, id) catch return RunnerError.TASK_QUEUE_FULL;
    }

    fn queue_cancel(runner: *const Runner, id: u32, qtd: usize) void {
        var self: *Self = @alignCast(@constCast(@fieldParentPtr("runner_dev", runner)));
        var to_remove = qtd;
        for (0..self.event_queue.items.len) |_| {
            if (to_remove == 0) break;
            const val = self.event_queue.pop() orelse break;
            if (val == id) {
                to_remove -= 1;
            } else {
                self.event_queue.insertAssumeCapacity(0, val);
            }
        }
    }

    fn take_reader(runner: *const Runner) RunnerError!*std.io.Reader {
        const self: *const Self = @alignCast(@fieldParentPtr("runner_dev", runner));
        if (self.reader_taken) {
            return RunnerError.BUSY;
        }
        return self.reader;
    }

    fn get_cmd_type(self: *Self, aux_buffer: []const u8) RunnerError!void {
        const response = get_cmd_slice(aux_buffer, &[_]u8{}, &[_]u8{ ' ', '\r', ':', ',' });

        //check if response is a Gereric Command Return
        const response_callback = cmd_response_map.get(response);
        if (response_callback) |callback| {
            try @call(.auto, callback, .{ self, aux_buffer });
            return;
        }

        defer self.reader_taken = false;

        for (self.device_list) |dev| {
            if (dev) |inst_dev| {
                inst_dev.check_cmd(response, aux_buffer) catch |err| {
                    switch (err) {
                        DeviceError.FATAL_ERROR => {
                            self.machine_state = .FATAL_ERROR;
                            return RunnerError.NON_RECOVERABLE_ERROR;
                        },
                        else => {
                            return RunnerError.INVALID_RESPONSE;
                        },
                    }
                };
            }
        }
    }

    fn ready_response(self: *Self, _: []const u8) RunnerError!void {
        if (self.machine_state != .INIT) {
            self.reset_state();
            self.reset_devices() catch return RunnerError.NON_RECOVERABLE_ERROR;
        }

        const rst_cb = self.Resetcallback_handler orelse return;
        rst_cb(self.reset_userdata);
        self.busy_flag = 0;
        self.machine_state = .IDLE;
    }

    fn ok_response(self: *Self, _: []const u8) RunnerError!void {
        self.cmd_busy = false;
        if (self.last_device) |dev| {
            if (self.device_list[dev]) |inst_dev| {
                inst_dev.ok_handler();
                return;
            }
        }

        return RunnerError.INVALID_ID;
    }

    fn error_response(self: *Self, _: []const u8) RunnerError!void {
        self.cmd_busy = false;
        if (self.last_device) |dev| {
            if (dev == 0) {
                self.machine_state = .FATAL_ERROR; //dev 0 fail to setup
            } else if (self.device_list[dev]) |inst_dev| {
                inst_dev.err_handler();
            }
            return;
        }

        return RunnerError.INVALID_ID;
    }

    fn fail_response(self: *Self, _: []const u8) RunnerError!void {
        const cmd = self.TX_wait_response;
        self.cmd_busy = false;
        if (cmd) |resp| {
            if (self.on_cmd_response) |callback| {
                callback(.{ .Fail = {} }, resp, self.Error_handler_user_data);
            }
        }
        self.TX_wait_response = null;
    }

    fn parser_error_code(self: *Self, aux_buffer: []const u8) RunnerError!void {
        if (aux_buffer.len < 20) return RunnerError.INVALID_RESPONSE;
        const error_code = Commands_util.parser_error(aux_buffer);
        self.last_error_code = error_code;
    }

    fn send_parser(self: *Self, aux_buffer: []const u8) RunnerError!void {
        const send_event = get_send_event(aux_buffer[5..]) catch return RunnerError.INVALID_RESPONSE;
        if (self.last_device) |dev| {
            if (self.device_list[dev]) |inst_dev| {
                inst_dev.send_handler(send_event);
            }
        }
    }

    fn fatal_error(self: *Self) StdRunnerError {
        self.machine_state = .FATAL_ERROR;
        return StdRunnerError.NON_RECOVERABLE_ERROR;
    }

    pub fn process(self: *Self) StdRunnerError!void {
        switch (self.machine_state) {
            .IDLE, .INIT => {
                try self.IDLE_TRANS();
                try self.IDLE_REV();
            },
            .OFF => return StdRunnerError.OFF,
            .FATAL_ERROR => return StdRunnerError.NON_RECOVERABLE_ERROR, //module need to reboot due a deadlock, Non-recoverable deadlocks occur when the data in a network packet is null.
        }
    }

    fn IDLE_REV(self: *Self) StdRunnerError!void {
        const last_b = self.reader.peekByte() catch 0;
        if (last_b == '>') {
            self.reader.toss(1);
            const err: StdRunnerError = blk: {
                if (self.last_device) |id| {
                    if (self.device_list[id]) |dev| {
                        dev.send_data(self.writer) catch break :blk StdRunnerError.SEND_ERROR;
                        return;
                    }
                }
                break :blk StdRunnerError.NO_DEVICE;
            };

            self.writer.writeAll("\\0") catch return self.fatal_error();
            self.writer.flush() catch return self.fatal_error();
            return err;
        }

        const data = blk: {
            break :blk self.reader.takeDelimiterInclusive('\n') catch |err| {
                switch (err) {
                    error.StreamTooLong => {
                        const size = self.reader.readSliceShort(&self.aux_buffer) catch unreachable;
                        break :blk self.aux_buffer[0..size];
                    },
                    else => return,
                }
            };
        };
        try self.get_cmd_type(data);
    }

    fn IDLE_TRANS(self: *Self) StdRunnerError!void {
        if (self.cmd_busy or (self.busy_flag != 0)) {
            return;
        }
        const next_cmd: u32 = self.event_queue.pop() orelse {
            return;
        };
        if (self.device_list[next_cmd]) |dev| {
            dev.get_cmd(self.writer) catch return;
            self.cmd_busy = true;
            self.last_device = next_cmd;
            return;
        }
        return StdRunnerError.NO_DEVICE;
    }

    fn reset_state(self: *Self) void {
        self.cmd_queue = std.ArrayList(CmdPkg).initBuffer(&self.cmd_buffer);
        //_ = self.reader.discardRemaining() catch {};
        self.event_queue.clearRetainingCapacity();
        self.last_device = null;
        self.device_list[0] = &self.device_dev;
        self.busy_flag = 0;
        self.cmd_busy = false;
        self.reader_taken = false;
    }

    fn reset_devices(self: *Self) !void {
        for (0..self.device_list.len) |i| {
            if (self.device_list[i]) |dev| {
                try dev.reset();
            }
        }
    }

    ///load basic setup sequence to event queue
    fn basic_setup(self: *Self) void {
        var pkg: CmdPkg = .{};
        var cmd_slice: []u8 = undefined;

        //send dummy cmd to clear the module input
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}", .{ get_cmd_string(.DUMMY), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.event_queue.insertAssumeCapacity(0, 0);
        self.cmd_queue.insertAssumeCapacity(0, pkg);

        //desable ECHO
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}", .{ get_cmd_string(.ECHO_OFF), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.event_queue.insertAssumeCapacity(0, 0);
        self.cmd_queue.insertAssumeCapacity(0, pkg);

        //disable sysstore
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=0{s}", .{ prefix, get_cmd_string(.SYSSTORE), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.event_queue.insertAssumeCapacity(0, 0);
        self.cmd_queue.insertAssumeCapacity(0, pkg);

        //enable error logs
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.SYSLOG), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.event_queue.insertAssumeCapacity(0, 0);
        self.cmd_queue.insertAssumeCapacity(0, pkg);

        //enable +LINK msg
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=2{s}", .{ prefix, get_cmd_string(.SYSMSG), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.event_queue.insertAssumeCapacity(0, 0);
        self.cmd_queue.insertAssumeCapacity(0, pkg);
    }

    ///load software reset sequence to event queue
    fn soft_reset(self: *Self) !void {
        var pkg: CmdPkg = .{};
        var cmd_slice: []u8 = undefined;

        //send dummy cmd to clear the module input
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}", .{ get_cmd_string(.DUMMY), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        try self.event_queue.insertBounded(0, 0);
        try self.cmd_queue.insertBounded(0, pkg);

        //send RST request
        cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}{s}", .{ prefix, get_cmd_string(.RESET), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        pkg.busy = true;

        try self.event_queue.insertBounded(0, 0);
        try self.cmd_queue.insertBounded(0, pkg);
    }

    pub fn start_runner(self: *Self, power_on_reset: bool) !void {
        self.reset_state(); //get device into reset state (device list is maintained)

        if (power_on_reset) {
            self.busy_flag = 1;
        } else {
            self.soft_reset() catch unreachable;
        }
        self.basic_setup();
        self.reset_devices() catch unreachable;

        self.machine_state = .INIT;
    }

    pub fn init(config: RunnerConfig) error{INVALID_CONFIG}!Self {
        if (config.event_queue.len == 0) return error.INVALID_CONFIG;

        const driver = Self{
            .reader = config.reader,
            .writer = config.writer,
            .event_queue = std.ArrayList(u32).initBuffer(config.event_queue),
            .Resetcallback_handler = config.reset_callback,
            .reset_userdata = config.reset_userdata,
        };
        return driver;
    }
};

pub fn get_send_event(str: []const u8) !bool {
    const event = SendMap.get(str);
    if (event) |data| {
        return data;
    }
    return error.EventNotFound;
}
