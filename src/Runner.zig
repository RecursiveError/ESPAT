const std = @import("std");
const fifo = std.fifo;

const Types = @import("Types.zig");
const Device = Types.Device;
const Runner = Types.Runner;
const ToRead = Types.ToRead;
const TXPkg = Types.TXPkg;
const DriverError = Types.DriverError;

const Commands_util = @import("util/commands.zig");
const Commands = Commands_util.Commands;
const get_cmd_string = Commands_util.get_cmd_string;
const get_cmd_slice = Commands_util.get_cmd_slice;
const infix = Commands_util.infix;
const prefix = Commands_util.prefix;
const postfix = Commands_util.postfix;
const CommandErrorCodes = Commands_util.CommandsErrorCode;
pub const ReponseEvent = Commands_util.ResponseEvent;

pub const Config = struct {
    RX_size: usize = 2048,
    TX_event_pool: usize = 25,
    network_recv_size: usize = 2048,
};

const BusyBitFlags = packed struct {
    Command: bool = false,
    Device: bool = false,
};

const Drive_states = enum {
    init,
    IDLE,
    OFF,
    FATAL_ERROR,
};

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

pub const TXcallback = *const fn (data: []const u8, user_data: ?*anyopaque) void;
pub const RXcallback = ?*const fn (free_data: usize, user_data: ?*anyopaque) []u8;
pub const ResponseCallback = ?*const fn (result: ReponseEvent, cmd: Commands, user_data: ?*anyopaque) void;

pub fn StdRunner(comptime driver_config: Config) type {
    if (driver_config.RX_size < 128) @compileError("RX SIZE CANNOT BE LESS THAN 128 byte");
    if (driver_config.network_recv_size < 128) @compileError("NETWORK RECV CAN NO BE LESS THAN 128 bytes");
    if (driver_config.TX_event_pool < 10) @compileError(" NETWORK POOL SIZE CANNOT BE LESS THAN 10 events");
    return struct {

        // data types
        const Self = @This();
        const CMD_CALLBACK_TYPE = *const fn (self: *Self, aux_buffer: []const u8) DriverError!void;
        const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
            .{ "ready", Self.driver_ready },
            .{ "OK", Self.ok_response },
            .{ "ERROR", Self.error_response },
            .{ "FAIL", Self.error_response },
            .{ "ERR", Self.parser_error_code },
        });

        //internal control data, (Do not modify)
        RX_fifo: fifo.LinearFifo(u8, .{ .Static = driver_config.RX_size }),
        TX_fifo: fifo.LinearFifo(TXPkg, .{ .Static = driver_config.TX_event_pool }),
        TX_wait_response: ?Commands = null,
        TXcallback_handler: TXcallback,
        RXcallback_handler: RXcallback,
        busy_flag: BusyBitFlags = .{},
        internal_aux_buffer: [driver_config.network_recv_size]u8 = undefined,
        internal_aux_buffer_pos: usize = 0,
        last_error_code: CommandErrorCodes = .ESP_AT_UNKNOWN_ERROR,
        last_device: ?*Device = null,

        //Long data needs to be handled in a special state
        //to avoid locks on the executor while reading this data
        //only for command data responses (+<cmd>:data) with unknow response len
        long_data_request: bool = false,
        long_data: ToRead = undefined,

        machine_state: Drive_states = .init,
        //callback handlers
        TX_RX_user_data: ?*anyopaque = null,
        Error_handler_user_data: ?*anyopaque = null,
        on_cmd_response: ResponseCallback = null,
        init_flag: bool align(1) = false,

        runner_dev: Runner = .{
            .runner_instance = undefined,
            .set_busy_flag = set_busy_flag,
            .set_long_data = set_long_data,
            .get_tx_data = get_tx_data,
            .get_tx_free_space = get_tx_freespace,
            .store_tx_data = store_tx_data,
            .get_tx_len = get_tx_len,
        },

        tcp_ip: ?*Device = null,
        WiFi_device: ?*Device = null,

        fn set_busy_flag(flag: u1, inst: *anyopaque) void {
            var self: *Self = @alignCast(@ptrCast(inst));
            self.busy_flag.Device = (flag == 1);
        }

        fn set_long_data(data: ToRead, inst: *anyopaque) void {
            var self: *Self = @alignCast(@ptrCast(inst));
            self.long_data_request = true;
            self.long_data = data;
        }
        fn get_tx_freespace(inst: *anyopaque) usize {
            var self: *Self = @alignCast(@ptrCast(inst));
            return self.get_tx_free_space();
        }

        fn get_tx_len(inst: *anyopaque) usize {
            var self: *Self = @alignCast(@ptrCast(inst));
            return self.TX_fifo.readableLength();
        }

        fn get_tx_data(inst: *anyopaque) ?TXPkg {
            var self: *Self = @alignCast(@ptrCast(inst));
            return self.TX_fifo.readItem();
        }

        fn store_tx_data(pkg: TXPkg, inst: *anyopaque) DriverError!void {
            var self: *Self = @alignCast(@ptrCast(inst));
            return self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
        }

        pub inline fn get_rx_free_space(self: *Self) usize {
            return self.RX_fifo.writableLength();
        }

        pub inline fn get_tx_free_space(self: *Self) usize {
            return self.TX_fifo.writableLength();
        }

        fn get_data(self: *Self) void {
            const free_space = self.get_rx_free_space();
            if (self.RXcallback_handler) |rxcallback| {
                const data_slice = rxcallback(free_space, self.TX_RX_user_data);
                const slice = if (data_slice.len > free_space) data_slice[0..free_space] else data_slice;
                self.RX_fifo.write(slice) catch unreachable;
            }
        }

        pub fn feed(self: *Self, data: []const u8) DriverError!usize {
            const free_space = self.get_rx_free_space();
            const slice = if (data.len > free_space) data[0..free_space] else data;
            self.RX_fifo.write(slice) catch unreachable;
            try self.process();
            return slice.len;
        }

        fn get_cmd_type(self: *Self, aux_buffer: []const u8) DriverError!void {
            const response = get_cmd_slice(aux_buffer, &[_]u8{}, &[_]u8{ ' ', '\r', ':', ',' });
            const response_callback = cmd_response_map.get(response);
            if (response_callback) |callback| {
                try @call(.auto, callback, .{ self, aux_buffer });
                return;
            }
            for (&[_]?*Device{ self.tcp_ip, self.WiFi_device }) |device| {
                if (device) |dev| {
                    try dev.check_cmd(response, aux_buffer, dev.device_instance);
                }
            }
        }

        fn ok_response(self: *Self, _: []const u8) DriverError!void {
            self.busy_flag.Command = false;
            if (self.last_device) |dev| {
                dev.ok_handler(dev.device_instance);
            }
        }

        fn error_response(self: *Self, _: []const u8) DriverError!void {
            self.busy_flag.Command = false;
            if (self.last_device) |dev| {
                dev.err_handler(dev.device_instance);
            }
        }

        fn fail_response(self: *Self, _: []const u8) DriverError!void {
            const cmd = self.TX_wait_response;
            self.busy_flag.Command = false;
            if (cmd) |resp| {
                if (self.on_cmd_response) |callback| {
                    callback(.{ .Fail = {} }, resp, self.Error_handler_user_data);
                }
            }
            self.TX_wait_response = null;
        }

        fn parser_error_code(self: *Self, aux_buffer: []const u8) DriverError!void {
            if (aux_buffer.len < 20) return DriverError.INVALID_RESPONSE;
            const error_code = Commands_util.parser_error(aux_buffer);
            self.last_error_code = error_code;
            if (error_code == .ESP_AT_UNKNOWN_ERROR) return DriverError.INVALID_RESPONSE;
        }

        fn driver_ready(self: *Self, _: []const u8) DriverError!void {
            //check if ESP as reset
            if (!self.init_flag) {
                self.busy_flag.Device = false;
                self.init_flag = true;
                return;
            }
            self.machine_state = .FATAL_ERROR;
            return DriverError.NON_RECOVERABLE_ERROR;
        }

        fn apply_cmd(self: *Self, pkg: TXPkg) []const u8 {
            const data = std.mem.bytesAsValue(Commands_util.Package, &pkg.buffer);
            std.mem.copyForwards(u8, &self.internal_aux_buffer, data.str[0..data.len]);
            if (data.busy) {
                self.busy_flag.Device = true;
            }
            return self.internal_aux_buffer[0..data.len];
        }

        pub fn process(self: *Self) DriverError!void {
            switch (self.machine_state) {
                .init => {
                    self.init_driver() catch return;
                },
                .IDLE => {
                    try self.IDLE_REV();
                    if (self.long_data_request) {
                        self.READ_LONG();
                    }
                    try self.IDLE_TRANS();
                },
                .OFF => return DriverError.DRIVER_OFF,
                .FATAL_ERROR => return DriverError.NON_RECOVERABLE_ERROR, //module need to reboot due a deadlock, Non-recoverable deadlocks occur when the data in a network packet is null.
            }
            self.get_data(); //read data for the next run
        }

        fn IDLE_REV(self: *Self) DriverError!void {
            const fifo_size = self.RX_fifo.readableLength();
            for (0..fifo_size) |_| {
                if (self.long_data_request) {
                    return;
                }
                const rev_data = self.RX_fifo.readItem();
                if (rev_data) |data| {
                    self.internal_aux_buffer[self.internal_aux_buffer_pos] = data;
                    self.internal_aux_buffer_pos += 1;
                    self.internal_aux_buffer_pos %= driver_config.network_recv_size;
                    if (data == '\n') {
                        if (self.internal_aux_buffer_pos > 3) {
                            self.get_cmd_type(self.internal_aux_buffer[0..self.internal_aux_buffer_pos]) catch |err| {
                                self.internal_aux_buffer_pos = 0;
                                return err;
                            };
                        }
                        self.internal_aux_buffer_pos = 0;
                    } else if ((data == '>') and (self.internal_aux_buffer_pos == 1)) {
                        self.internal_aux_buffer_pos = 0;
                        if (self.last_device) |dev| {
                            const send_data = dev.pool_data(dev.device_instance) catch |err| {
                                self.machine_state = .FATAL_ERROR; //cannot find device to pool data from
                                return err;
                            };
                            self.TXcallback_handler(send_data, self.TX_RX_user_data);
                        } else {
                            self.machine_state = .FATAL_ERROR; //cannot find device to pool data from
                            return DriverError.NO_POOL_DATA;
                        }
                    }
                } else {
                    break;
                }
            }
        }

        fn IDLE_TRANS(self: *Self) DriverError!void {
            const busy_bits: u2 = @bitCast(self.busy_flag);
            if (busy_bits != 0) {
                return;
            }
            const next_cmd: ?TXPkg = self.TX_fifo.readItem();
            if (next_cmd) |cmd| {
                self.busy_flag.Command = true;

                switch (cmd.device) {
                    .Command => {
                        self.last_device = null;
                        const to_send = self.apply_cmd(cmd);
                        self.TXcallback_handler(to_send, self.TX_RX_user_data);
                        return;
                    },
                    .TCP_IP => {
                        if (self.tcp_ip) |dev| {
                            const to_send = try dev.apply_cmd(cmd, &self.internal_aux_buffer, dev.device_instance);
                            self.TXcallback_handler(to_send, self.TX_RX_user_data);
                            self.last_device = dev;
                            return;
                        }
                    },
                    .WiFi => {
                        if (self.WiFi_device) |dev| {
                            const to_send = try dev.apply_cmd(cmd, &self.internal_aux_buffer, dev.device_instance);
                            self.TXcallback_handler(to_send, self.TX_RX_user_data);
                            self.last_device = dev;
                            return;
                        }
                    },
                    else => {},
                }
                return DriverError.NO_DEVICE;
            }
        }

        fn READ_LONG(self: *Self) void {
            const to_read = self.long_data.to_read;
            var offset = self.long_data.data_offset;
            const start = self.long_data.start_index;
            const rev_data = offset - start; //offset is always at least 3 nytes more than start
            if (rev_data < to_read) {
                const remain = to_read - rev_data;

                //do not read more than the max buffer size
                const read: usize = @min(driver_config.network_recv_size, (offset + remain));
                const rev = self.RX_fifo.read(self.internal_aux_buffer[offset..read]);
                const new_offset = offset + rev;
                const rev_data_len = new_offset - start;
                if (new_offset >= driver_config.network_recv_size) {
                    //if the buffer is full but still have data to read
                    //send the data and clear the buffer
                    //**only nescessary for active recv mode**(passive mode never read more than the buffer size)
                    if (rev_data_len < to_read) {
                        self.long_data.notify(self.internal_aux_buffer[start..], self.long_data.user_data);
                        self.long_data.data_offset = start;
                        self.long_data.to_read -= rev_data_len;
                        return;
                    }
                } else {
                    if (rev_data_len < to_read) {
                        self.long_data.data_offset = new_offset;
                        return;
                    }
                }
                offset = new_offset;
            }
            self.long_data.notify(self.internal_aux_buffer[start..offset], self.long_data.user_data);
            self.long_data_request = false;
        }

        pub fn set_UART(self: *Self, config: UartConfig) !void {
            if ((self.machine_state != .init) or (self.machine_state != .OFF)) return error.DriverRunning;
            if ((config.baudrate > 50_000_000) or (config.baudrate < 80)) return error.INVALID_ARGS;
            const cmd = try std.fmt.bufPrint(&self.internal_aux_buffer, "{s}{s}{s}={d},{d},{d},{d},{d}{s}", .{
                prefix,
                "UART",
                infix,
                config.baudrate,
                @intFromEnum(config.databits),
                @intFromEnum(config.stopbits),
                @intFromEnum(config.parity),
                @intFromEnum(config.flowcontrol),
                postfix,
            });
            self.TXcallback_handler(cmd, self.TX_RX_user_data);
            self.internal_aux_buffer_pos = 0;
        }
        pub fn init_driver(self: *Self) !void {

            //clear buffers
            self.deinit_driver();
            self.RX_fifo.discard(self.RX_fifo.readableLength());
            self.TX_fifo.discard(self.TX_fifo.readableLength());
            self.runner_dev.runner_instance = self;
            self.init_flag = false;

            var pkg: Commands_util.Package = .{};

            //send dummy cmd to clear the module input
            var cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}", .{ get_cmd_string(.DUMMY), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXPkg.convert_type(.Command, pkg)) catch unreachable;

            //send RST request
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}{s}", .{ prefix, get_cmd_string(.RESET), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            pkg.busy = true;
            self.TX_fifo.writeItem(TXPkg.convert_type(.Command, pkg)) catch unreachable;
            pkg.busy = false;

            //desable ECHO
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}", .{ get_cmd_string(.ECHO_OFF), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXPkg.convert_type(.Command, pkg)) catch unreachable;

            //disable sysstore
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=0{s}", .{ prefix, get_cmd_string(.SYSSTORE), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXPkg.convert_type(.Command, pkg)) catch unreachable;

            //enable error logs
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.SYSLOG), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXPkg.convert_type(.Command, pkg)) catch unreachable;

            //enable +LINK msg
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=2{s}", .{ prefix, get_cmd_string(.SYSMSG), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXPkg.convert_type(.Command, pkg)) catch unreachable;

            //enable IP info
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.NETWORK_MSG_CONFIG), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXPkg.convert_type(.Command, pkg)) catch unreachable;

            //enable multi-conn
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.IP_MUX), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXPkg.convert_type(.Command, pkg)) catch unreachable;

            //disable wifi auto connection
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=0{s}", .{ prefix, get_cmd_string(.WIFI_AUTOCONN), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXPkg.convert_type(.Command, pkg)) catch unreachable;

            self.machine_state = Drive_states.IDLE;
        }

        pub fn deinit_driver(self: *Self) void {
            for (&[_]?*Device{ self.tcp_ip, self.WiFi_device }) |dev| {
                if (dev) |inst| {
                    inst.deinit(inst.device_instance);
                }
            }
            self.last_device = null;
            self.machine_state = .OFF;
        }

        pub fn set_response_event_handler(self: *Self, callback: ResponseCallback, user_data: ?*anyopaque) void {
            self.on_cmd_response = callback;
            self.Error_handler_user_data = user_data;
        }

        //TODO: add more config param
        pub fn init(txcallback: TXcallback, rxcallback: RXcallback, user_data: ?*anyopaque) Self {
            //const ATdrive = create_drive(buffer_size);
            const driver = Self{
                .RXcallback_handler = rxcallback,
                .TXcallback_handler = txcallback,
                .TX_RX_user_data = user_data,
                .RX_fifo = fifo.LinearFifo(u8, .{ .Static = driver_config.RX_size }).init(),
                .TX_fifo = fifo.LinearFifo(TXPkg, .{ .Static = driver_config.TX_event_pool }).init(),
            };
            return driver;
        }
    };
}
