const std = @import("std");
const fifo = std.fifo;

const Commands_util = @import("util/commands.zig");
pub const Commands = Commands_util.Commands;
pub const get_cmd_string = Commands_util.get_cmd_string;
const get_cmd_slice = Commands_util.get_cmd_slice;
const infix = Commands_util.infix;
const prefix = Commands_util.prefix;
const postfix = Commands_util.postfix;
pub const CommandErrorCodes = Commands_util.CommandsErrorCode;
pub const ReponseEvent = Commands_util.ResponseEvent;

const WiFi = @import("util/WiFi.zig");
pub const WiFiAPConfig = WiFi.APConfig;
pub const WiFiSTAConfig = WiFi.STAConfig;
pub const WifiEvent = WiFi.Event;
pub const WiFiEncryption = WiFi.Encryption;

const Network = @import("util/network.zig");
pub const NetworkPackageType = Network.PackageType;
pub const NetworkEvent = Network.Event;
pub const NetworkHandlerState = Network.HandlerState;
pub const ConnectConfig = Network.ConnectConfig;
pub const ServerConfig = Network.ServerConfig;
pub const NetworkTCPConn = Network.TCPConn;
pub const NetworkUDPConn = Network.UDPConn;
pub const NetworkHandlerType = Network.HandlerType;
pub const NetworkHandler = Network.Handler;
pub const Client = Network.Client;
pub const ClientCallback = Network.ClientCallback;

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
pub const NetworkDriveMode = enum {
    SERVER_ONLY,
    CLIENT_ONLY,
    SERVER_CLIENT,
};

pub const WiFiDriverMode = enum { NONE, STA, AP, AP_STA };

//TODO: add uart config
pub const Drive_states = enum {
    init,
    IDLE,
    OFF,
    FATAL_ERROR,
};

pub const WiFistate = enum {
    OFF,
    DISCONECTED,
    CONNECTED,
};

pub const BusyBitFlags = packed struct {
    Reset: bool = false,
    Command: bool = false,
    Device: bool = false,
    WiFi: bool = false,
    Bluetooth: bool = false,
};

pub const CommandPkg = struct {
    str: [60]u8 = undefined,
    len: usize = 0,
};

pub const NetworkPackage = struct {
    descriptor_id: usize = 255,
    pkg_type: NetworkPackageType,
};

pub const WiFiPackage = union(enum) {
    AP_conf_pkg: WiFi.APpkg,
    STA_conf_pkg: WiFi.STApkg,
    static_ap_config: WiFi.StaticIp,
    dhcp_config: WiFi.DHCPConfig,
    MAC_config: []const u8,
};

pub const BluetoothPackage = struct {
    //TODO
};

pub const TXExtraData = union(enum) {
    Reset: void,
    Command: CommandPkg,
    Socket: NetworkPackage,
    WiFi: WiFiPackage,
    Bluetooth: BluetoothPackage,
};

pub const TXEventPkg = struct {
    cmd_enum: Commands,
    Extra_data: TXExtraData,
};

const ToRead = struct {
    to_read: usize,
    data_offset: usize,
    start_index: usize,
    notify: *const fn ([]const u8, *anyopaque) void,
    user_data: *anyopaque,
};

const NetworkToSend = struct {
    id: usize = std.math.maxInt(usize),
    data: []const u8 = undefined,
};

const Runner = struct {
    runner_instance: *anyopaque,
    set_busy_flag: *const fn (u1, *anyopaque) void,
    set_long_data: *const fn (ToRead, *anyopaque) void,
    get_tx_data: *const fn (*anyopaque) ?TXEventPkg,
    get_tx_free_space: *const fn (*anyopaque) usize,
    get_tx_len: *const fn (*anyopaque) usize,
    store_tx_data: *const fn (TXEventPkg, *anyopaque) DriverError!void,
};

const Device = struct {
    device_instance: *anyopaque = undefined,
    apply_cmd: *const fn (TXEventPkg, []u8, *anyopaque) []const u8 = undefined,
    pool_data: *const fn (*anyopaque) []const u8,
    check_cmd: *const fn ([]const u8, []const u8, *anyopaque) DriverError!void,
    ok_handler: *const fn (*anyopaque) void,
    err_handler: *const fn (*anyopaque) void,
};

pub const TX_callback = *const fn (data: []const u8, user_data: ?*anyopaque) void;
pub const RX_callback = ?*const fn (free_data: usize, user_data: ?*anyopaque) []u8;
pub const WIFI_event_type = ?*const fn (event: WifiEvent, user_data: ?*anyopaque) void;
pub const response_event_type = ?*const fn (result: ReponseEvent, cmd: Commands, user_data: ?*anyopaque) void;

pub const Config = struct {
    RX_size: usize = 2048,
    TX_event_pool: usize = 25,
    network_recv_size: usize = 2048,
    network_binds: usize = 5,
};

pub fn EspAT(comptime driver_config: Config) type {
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
        TX_fifo: fifo.LinearFifo(TXEventPkg, .{ .Static = driver_config.TX_event_pool }),
        TX_wait_response: ?Commands = null,
        TX_callback_handler: TX_callback,
        RX_callback_handler: RX_callback,
        busy_flag: BusyBitFlags = .{},
        internal_aux_buffer: [driver_config.network_recv_size]u8 = undefined,
        internal_aux_buffer_pos: usize = 0,
        last_error_code: CommandErrorCodes = .ESP_AT_UNKNOWN_ERROR,
        last_device: ?*Device = null,

        //Long data needs to be handled in a special state
        //to avoid locks on the executor while reading this data
        //only for command data responses (+<cmd>:data) with unknow response len
        long_data_request: bool = false,
        long_data: ToRead = undefined, //TODO: change this to support BLE

        machine_state: Drive_states = .init,
        Wifi_state: WiFistate = .OFF,
        Wifi_mode: WiFiDriverMode = .NONE,
        WiFi_dhcp: WiFi.DHCPEnable = .{},
        //callback handlers

        TX_RX_user_data: ?*anyopaque = null,
        WiFi_user_data: ?*anyopaque = null,
        Error_handler_user_data: ?*anyopaque = null,
        on_cmd_response: response_event_type = null,
        on_WiFi_event: WIFI_event_type = null,

        runner_dev: Runner = .{
            .runner_instance = undefined,
            .set_busy_flag = set_busy_flag,
            .set_long_data = set_long_data,
            .get_tx_data = get_tx_data,
            .get_tx_free_space = get_tx_freespace,
            .store_tx_data = store_tx_data,
            .get_tx_len = get_tx_len,
        },

        net_device: *Device = undefined,
        WiFi_device: *Device = undefined,

        pub fn set_net_dev(self: *Self, net_dev: *Device) void {
            self.net_device = net_dev;
        }

        fn set_busy_flag(flag: u1, inst: *anyopaque) void {
            var self: *Self = @alignCast(@ptrCast(inst));
            self.busy_flag.Device = flag == 1;
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

        fn get_tx_data(inst: *anyopaque) ?TXEventPkg {
            var self: *Self = @alignCast(@ptrCast(inst));
            return self.TX_fifo.readItem();
        }

        fn store_tx_data(pkg: TXEventPkg, inst: *anyopaque) DriverError!void {
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
            if (self.RX_callback_handler) |rxcallback| {
                const data_slice = rxcallback(free_space, self.TX_RX_user_data);
                const slice = if (data_slice.len > free_space) data_slice[0..free_space] else data_slice;
                self.RX_fifo.write(slice) catch unreachable;
            }
        }

        pub fn notify(self: *Self, data: []const u8) usize {
            const free_space = self.get_rx_free_space();
            const slice = if (data.len > free_space) data[0..free_space] else data;
            self.RX_fifo.write(slice) catch unreachable;
            return slice.len;
        }

        fn get_cmd_type(self: *Self, aux_buffer: []const u8) DriverError!void {
            const response = get_cmd_slice(aux_buffer, &[_]u8{}, &[_]u8{ ' ', '\r', ':', ',' });
            const response_callback = cmd_response_map.get(response);
            if (response_callback) |callback| {
                try @call(.auto, callback, .{ self, aux_buffer });
                return;
            }
            try self.net_device.check_cmd(response, aux_buffer, self.net_device.device_instance);
        }

        fn ok_response(self: *Self, _: []const u8) DriverError!void {
            self.busy_flag.Command = false;
            const cmd = self.TX_wait_response;
            if (cmd) |resp| {
                //add custom handler here
                switch (resp) {
                    .WIFI_CONNECT => self.busy_flag.WiFi = false, //wait WiFi OK before releasing the busy flag
                    else => {},
                }
                if (self.on_cmd_response) |callback| {
                    callback(.{ .Ok = {} }, resp, self.Error_handler_user_data);
                }
            }
            if (self.last_device) |dev| {
                dev.ok_handler(dev.device_instance);
            }
            self.TX_wait_response = null;
        }

        fn error_response(self: *Self, _: []const u8) DriverError!void {
            const cmd = self.TX_wait_response;
            self.busy_flag.Command = false;
            if (cmd) |resp| {
                if (self.on_cmd_response) |callback| {
                    callback(.{ .Error = self.last_error_code }, resp, self.Error_handler_user_data);
                }
            }
            if (self.last_device) |dev| {
                dev.err_handler(dev.device_instance);
            }
            self.last_error_code = .ESP_AT_UNKNOWN_ERROR; //reset error code handler
            self.TX_wait_response = null;
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
            self.busy_flag.Command = false;
            self.busy_flag.Reset = false;
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
                            const send_data = dev.pool_data(dev.device_instance);
                            self.TX_callback_handler(send_data, self.TX_RX_user_data);
                        } else {
                            self.machine_state = .FATAL_ERROR; //cannot find device to pool data from
                            return;
                        }
                    }
                } else {
                    break;
                }
            }
        }

        fn IDLE_TRANS(self: *Self) DriverError!void {
            const busy_bits: u5 = @bitCast(self.busy_flag);
            if (busy_bits != 0) return;
            const next_cmd = self.TX_fifo.readItem();
            if (next_cmd) |cmd| {
                self.busy_flag.Command = true;
                self.TX_wait_response = cmd.cmd_enum;
                switch (cmd.Extra_data) {
                    .Reset => {
                        self.TX_callback_handler("AT+RST\r\n", self.TX_RX_user_data);
                        self.busy_flag.Reset = true;
                    },
                    .Command => |cmd_data| {
                        const str = cmd_data.str;
                        const len = cmd_data.len;
                        self.TX_callback_handler(str[0..len], self.TX_RX_user_data);
                    },
                    .Socket => |_| {
                        const apply_cmd = self.net_device.apply_cmd(
                            cmd,
                            &self.internal_aux_buffer,
                            self.net_device.device_instance,
                        );
                        self.TX_callback_handler(apply_cmd, self.TX_RX_user_data);
                        self.last_device = self.net_device;
                    },
                    .WiFi => |_| {
                        const apply_cmd = self.WiFi_device.apply_cmd(
                            cmd,
                            &self.internal_aux_buffer,
                            self.WiFi_device.device_instance,
                        );
                        self.TX_callback_handler(apply_cmd, self.TX_RX_user_data);
                        self.last_device = self.WiFi_device;
                    },
                    .Bluetooth => {
                        //TODO
                    },
                }
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

        //TODO; make a event pool just to init commands
        pub fn init_driver(self: *Self) !void {

            //clear buffers
            self.deinit_driver();
            self.RX_fifo.discard(self.RX_fifo.readableLength());
            self.TX_fifo.discard(self.TX_fifo.readableLength());
            self.runner_dev.runner_instance = self;

            //send dummy cmd to clear the module input
            var pkg: CommandPkg = .{};
            var cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}", .{ get_cmd_string(.DUMMY), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(
                TXEventPkg{
                    .cmd_enum = .DUMMY,
                    .Extra_data = .{ .Command = pkg },
                },
            ) catch unreachable;

            //send RST request
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .RESET,
                .Extra_data = .{ .Reset = {} },
            }) catch unreachable;

            //desable ECHO
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}", .{ get_cmd_string(.ECHO_OFF), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .ECHO_OFF,
                .Extra_data = .{ .Command = pkg },
            }) catch unreachable;

            //disable sysstore
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=0{s}", .{ prefix, get_cmd_string(.SYSSTORE), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .SYSSTORE,
                .Extra_data = .{ .Command = pkg },
            }) catch unreachable;

            //enable error logs
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.SYSLOG), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .SYSLOG,
                .Extra_data = .{ .Command = pkg },
            }) catch unreachable;

            //enable +LINK msg
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=2{s}", .{ prefix, get_cmd_string(.SYSMSG), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .SYSMSG,
                .Extra_data = .{ .Command = pkg },
            }) catch unreachable;

            //enable IP info
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.NETWORK_MSG_CONFIG), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .NETWORK_MSG_CONFIG,
                .Extra_data = .{ .Command = pkg },
            }) catch unreachable;

            //enable multi-conn
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.IP_MUX), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .IP_MUX,
                .Extra_data = .{ .Command = pkg },
            }) catch unreachable;

            //disable wifi auto connection
            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=0{s}", .{ prefix, get_cmd_string(.WIFI_AUTOCONN), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .WIFI_AUTOCONN,
                .Extra_data = .{ .Command = pkg },
            }) catch unreachable;

            self.machine_state = Drive_states.IDLE;
        }

        //TODO: send reaming network pkgs with "SendDataFail" event for avoid memory leaks
        pub fn deinit_driver(self: *Self) void {
            //TODO: Clear all WiFi data Here
            self.machine_state = .OFF;
        }

        pub fn set_response_event_handler(self: *Self, callback: response_event_type, user_data: ?*anyopaque) void {
            self.on_cmd_response = callback;
            self.Error_handler_user_data = user_data;
        }

        //TODO: add more config param
        pub fn init(txcallback: TX_callback, rxcallback: RX_callback, user_data: ?*anyopaque) Self {
            //const ATdrive = create_drive(buffer_size);
            const driver = Self{
                .RX_callback_handler = rxcallback,
                .TX_callback_handler = txcallback,
                .TX_RX_user_data = user_data,
                .RX_fifo = fifo.LinearFifo(u8, .{ .Static = driver_config.RX_size }).init(),
                .TX_fifo = fifo.LinearFifo(TXEventPkg, .{ .Static = driver_config.TX_event_pool }).init(),
            };
            return driver;
        }
    };
}

pub fn NetworkDevice(binds: usize) type {
    return struct {
        const Self = @This();
        const CMD_CALLBACK_TYPE = *const fn (self: *Self, buffer: []const u8) DriverError!void;
        const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
            .{ "+LINK_CONN", Self.network_conn_event },
            .{ "SEND", Self.network_send_event },
            .{ "+IPD", Self.parse_network_data },
            .{ "+CIPRECVDATA", Self.network_read_data },
        });

        runner_loop: *Runner = undefined,
        device: Device = .{
            .pool_data = pool_data,
            .check_cmd = check_cmd,
            .apply_cmd = apply_cmd,
            .ok_handler = ok_handler,
            .err_handler = err_handler,
        },

        //network data
        Network_binds: [binds]?NetworkHandler = undefined,
        Network_corrent_pkg: ?NetworkToSend = .{},
        corrent_read_id: usize = 0,
        div_binds: usize = 0,
        network_mode: NetworkDriveMode = .CLIENT_ONLY,

        //device functions
        fn check_cmd(cmd: []const u8, buffer: []const u8, device_inst: *anyopaque) DriverError!void {
            var self: *Self = @alignCast(@ptrCast(device_inst));
            const response_callback = cmd_response_map.get(cmd);
            if (response_callback) |callback| {
                try @call(.auto, callback, .{ self, buffer });
                return;
            } else {
                //check if the input is a ID
                _ = std.fmt.parseInt(usize, cmd, 10) catch return;
                try self.network_closed_event(buffer);
            }
        }

        fn recive_data(data: []const u8, device_inst: *anyopaque) void {
            var self: *Self = @alignCast(@ptrCast(device_inst));
            const id = self.corrent_read_id;
            if (self.Network_binds[id]) |*bd| {
                bd.client.event = .{ .ReadData = data };
                bd.notify();
            }
        }

        fn ok_handler(_: *anyopaque) void {
            return;
        }

        //send command is the only command that need to be check for Ok and Error response
        fn err_handler(device_inst: *anyopaque) void {
            var self: *Self = @alignCast(@ptrCast(device_inst));
            //Network_corrent_pkg is only set if a send command is the next to be send
            if (self.Network_corrent_pkg) |pkg| {
                const id = pkg.id;
                if (self.Network_binds[id]) |*bd| {
                    bd.client.event = .{
                        .SendData = .{
                            .state = .cancel,
                            .data = pkg.data,
                        },
                    };
                }
            }
            self.Network_corrent_pkg = null;
        }

        fn apply_cmd(pkg: TXEventPkg, input_buffer: []u8, device_inst: *anyopaque) []const u8 {
            var self: *Self = @alignCast(@ptrCast(device_inst));
            const runner_inst = self.runner_loop.runner_instance;

            switch (pkg.Extra_data) {
                .Socket => |data| {
                    const id = data.descriptor_id;
                    switch (data.pkg_type) {
                        .SendPkg => |to_send| {
                            self.Network_corrent_pkg = NetworkToSend{
                                .data = to_send.data,
                                .id = id,
                            };
                            self.runner_loop.set_busy_flag(1, runner_inst);
                            return apply_send(id, to_send.data.len, input_buffer);
                        },
                        .SendToPkg => |to_send| {
                            self.Network_corrent_pkg = NetworkToSend{
                                .data = to_send.data,
                                .id = id,
                            };
                            self.runner_loop.set_busy_flag(1, runner_inst);
                            return apply_udp_send(id, to_send, input_buffer);
                        },
                        .AcceptPkg => |size| {
                            return apply_accept(id, size, input_buffer);
                        },
                        .ClosePkg => {
                            if (self.Network_binds[id]) |*bd| {
                                bd.to_send -= 1;
                            }
                            return apply_close(id, input_buffer);
                        },
                        .ConnectConfig => |connpkg| {
                            switch (connpkg.config) {
                                .tcp, .ssl => |config| {
                                    return apply_tcp_config(id, connpkg, config, input_buffer);
                                },
                                .udp => |config| {
                                    return apply_udp_config(id, connpkg, config, input_buffer);
                                },
                            }
                        },
                    }
                },
                else => {},
            }
            return "\r\n";
        }

        fn pool_data(inst: *anyopaque) []const u8 {
            const self: *Self = @alignCast(@ptrCast(inst));
            //if pkg is invalid, close the send request"
            if (self.Network_corrent_pkg) |pkg| {
                if (pkg.id < self.Network_binds.len) {
                    if (self.Network_binds[pkg.id]) |*bd| {
                        if (bd.to_send > 0) {
                            bd.to_send -= 1;
                            return pkg.data;
                        }
                    }
                }
            }
            //send stop code on invalid pkgs (yes stop code is '\''0' not '\0')
            return "\\0";
        }

        fn apply_send(id: usize, data_len: usize, buffer: []u8) []const u8 {
            const cmd = std.fmt.bufPrint(buffer, "{s}{s}={d},{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_SEND),
                id,
                data_len,
                postfix,
            }) catch unreachable;
            return cmd;
        }

        fn apply_tcp_config(id: usize, args: ConnectConfig, tcp_conf: NetworkTCPConn, buffer: []u8) []const u8 {
            const config = Network.set_tcp_config(buffer, id, args, tcp_conf) catch unreachable;
            return config;
        }
        fn apply_udp_config(id: usize, args: ConnectConfig, udp_conf: NetworkUDPConn, buffer: []u8) []const u8 {
            const config = Network.set_udp_config(buffer, id, args, udp_conf) catch unreachable;
            return config;
        }

        fn apply_udp_send(id: usize, data: Network.SendToPkg, buffer: []u8) []const u8 {
            const cmd = std.fmt.bufPrint(buffer, "{s}{s}={d},{d},\"{s}\",{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_SEND),
                id,
                data.data.len,
                data.remote_host,
                data.remote_port,
                postfix,
            }) catch unreachable;

            return cmd;
        }

        fn apply_accept(id: usize, len: usize, buffer: []u8) []const u8 {
            const cmd = std.fmt.bufPrint(buffer, "{s}{s}={d},{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_RECV),
                id,
                len,
                postfix,
            }) catch unreachable;

            return cmd;
        }

        fn apply_close(id: usize, buffer: []u8) []const u8 {
            const cmd = std.fmt.bufPrint(buffer, "{s}{s}={d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_CLOSE),
                id,
                postfix,
            }) catch unreachable;

            return cmd;
        }

        //events handlers
        fn network_conn_event(self: *Self, buffer: []const u8) DriverError!void {
            const data = Network.parser_conn_data(buffer) catch return DriverError.INVALID_RESPONSE;
            const id = data.id;
            if (id > self.Network_binds.len) return DriverError.INVALID_RESPONSE;

            if (self.Network_binds[id]) |*bd| {
                bd.client.remote_host = data.remote_host;
                bd.client.remote_port = data.remote_port;
                bd.state = .Connected;
                bd.client.event = .{ .Connected = {} };
                bd.notify();
            }
        }

        fn network_closed_event(self: *Self, aux_buffer: []const u8) DriverError!void {
            const id_index = aux_buffer[0];
            const runner_inst = self.runner_loop.runner_instance;
            if ((id_index < '0') or (id_index > '9')) {
                return DriverError.INVALID_RESPONSE;
            }

            const index: usize = id_index - '0';
            if (index > self.Network_binds.len) return DriverError.INVALID_RESPONSE;

            if (self.Network_binds[index]) |*bd| {
                bd.state = .Closed;

                //clear all pkgs from the TX pool
                if (bd.to_send > 0) {
                    const cmd_len = self.runner_loop.get_tx_len(runner_inst);
                    for (0..cmd_len) |_| {
                        const TX_pkg = self.runner_loop.get_tx_data(runner_inst).?;
                        switch (TX_pkg.Extra_data) {
                            .Socket => |*net_pkg| {
                                const id = net_pkg.descriptor_id;
                                if (id == index) {
                                    switch (net_pkg.pkg_type) {
                                        .SendPkg => |to_clear| {
                                            bd.client.event = .{ .SendData = .{
                                                .data = to_clear.data,
                                                .state = .cancel,
                                            } };
                                            bd.notify();
                                        },
                                        else => {},
                                    }
                                    continue;
                                }
                            },
                            else => {},
                        }
                        self.runner_loop.store_tx_data(TX_pkg, runner_inst) catch unreachable;
                    }
                    bd.to_send = 0;
                }
                bd.client.event = .{ .Closed = {} };
                bd.notify();
                bd.client.remote_host = null;
                bd.client.remote_port = null;
            }
        }

        fn network_send_event(self: *Self, aux_buffer: []const u8) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;
            self.runner_loop.set_busy_flag(0, runner_inst);
            const send_event_slice = get_cmd_slice(aux_buffer[5..], &[_]u8{}, &[_]u8{'\r'});
            const send_event = Network.get_send_event(send_event_slice) catch return DriverError.INVALID_RESPONSE;
            if (self.Network_corrent_pkg) |pkg| {
                const event: Network.SendState = switch (send_event) {
                    .ok => .Ok,
                    .fail => .Fail,
                };
                const corrent_id = pkg.id;

                if (self.Network_binds[corrent_id]) |*bd| {
                    bd.client.event = .{ .SendData = .{
                        .data = pkg.data,
                        .state = event,
                    } };
                    bd.notify();
                }
            }
            self.Network_corrent_pkg = null;
        }

        fn parse_network_data(self: *Self, aux_buffer: []const u8) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;
            const data = Network.paser_ip_data(aux_buffer) catch return DriverError.INVALID_RESPONSE;
            if (data.id > self.Network_binds.len) return DriverError.INVALID_RESPONSE;
            const id = data.id;
            const data_size = data.data_len;

            self.corrent_read_id = id;
            if (data.data_info) |info| {
                if (self.Network_binds[id]) |*bd| {
                    bd.client.remote_host = info.remote_host;
                    bd.client.remote_port = info.remote_port;
                }
                const read_request: ToRead = .{
                    .to_read = data_size,
                    .start_index = info.start_index,
                    .data_offset = aux_buffer.len,
                    .notify = recive_data,
                    .user_data = self,
                };
                self.runner_loop.set_long_data(read_request, runner_inst);

                return;
            }
            if (self.Network_binds[id]) |*bd| {
                bd.client.event = .{ .DataReport = data_size };
                bd.notify();
            }
        }

        fn network_read_data(self: *Self, aux_buffer: []const u8) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;
            if (aux_buffer.len < 14) return DriverError.INVALID_RESPONSE;
            const recv = Network.parse_recv_data(aux_buffer) catch return DriverError.INVALID_RESPONSE;
            const id = self.corrent_read_id;
            if (recv.data_info) |info| {
                if (self.Network_binds[id]) |*bd| {
                    bd.client.remote_host = info.remote_host;
                    bd.client.remote_port = info.remote_port;
                }
                self.corrent_read_id = id;
                const read_request: ToRead = .{
                    .to_read = recv.data_len,
                    .start_index = info.start_index,
                    .data_offset = aux_buffer.len,
                    .notify = recive_data,
                    .user_data = self,
                };
                self.runner_loop.set_long_data(read_request, runner_inst);
            }
        }

        //network methods

        pub fn set_network_mode(self: *Self, mode: NetworkDriveMode) !void {
            const runner_inst = self.runner_loop.runner_instance;
            self.div_binds = switch (mode) {
                .CLIENT_ONLY => 0,
                .SERVER_ONLY => 5,
                .SERVER_CLIENT => 3,
            };

            var pkg: CommandPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{ prefix, get_cmd_string(.NETWORK_SERVER_CONF), self.div_binds, postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .NETWORK_SERVER_CONF,
                .Extra_data = .{ .Command = pkg },
            }, runner_inst) catch return DriverError.TX_BUFFER_FULL;

            self.network_mode = mode;
        }

        fn create_client(self: *Self, id: usize) Client {
            return Client{
                .accept_fn = Self.accpet_fn,
                .close_fn = Self.close_fn,
                .send_fn = Self.send_fn,
                .sendTo_fn = Self.sendTo_fn,
                .driver = self,
                .id = id,
                .event = .{ .Closed = {} },
            };
        }

        pub fn bind(self: *Self, event_callback: ClientCallback, user_data: ?*anyopaque) DriverError!usize {
            const start_bind = self.div_binds;

            for (start_bind..self.Network_binds.len) |index| {
                if (self.Network_binds[index]) |_| {
                    continue;
                } else {
                    const new_bind: NetworkHandler = .{
                        .event_callback = event_callback,
                        .user_data = user_data,
                        .client = self.create_client(index),
                    };
                    self.Network_binds[index] = new_bind;
                    return index;
                }
            }
            return DriverError.MAX_BIND;
        }

        //TODO: add error checking for invalid closed erros
        pub fn close(self: *Self, id: usize) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;
            if (id > self.Network_binds.len) return DriverError.INVALID_BIND;
            if (self.Network_binds[id]) |*bd| {
                self.runner_loop.store_tx_data(TXEventPkg{
                    .cmd_enum = .NETWORK_CLOSE,
                    .Extra_data = .{
                        .Socket = .{
                            .descriptor_id = id,
                            .pkg_type = .{
                                .ClosePkg = {},
                            },
                        },
                    },
                }, runner_inst) catch return DriverError.TX_BUFFER_FULL;
                bd.to_send += 1;
                return;
            }
            return DriverError.INVALID_BIND;
        }

        fn close_fn(ctx: *anyopaque, id: usize) Network.ClientError!void {
            const driver: *Self = @alignCast(@ptrCast(ctx));
            driver.close(id) catch return error.InternalError;
        }

        pub fn connect(self: *Self, id: usize, config: ConnectConfig) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;

            if (self.runner_loop.get_tx_free_space(runner_inst) < 2) return DriverError.TX_BUFFER_FULL; //one CMD for set mode and one to connect to the host
            if (id > self.Network_binds.len or id < self.div_binds) return DriverError.INVALID_ARGS;
            Network.check_connect_config(config) catch return DriverError.INVALID_ARGS;

            //set RECV mode for the ID
            var recv_mode = CommandPkg{};
            const cmd_slice = std.fmt.bufPrint(&recv_mode.str, "{s}{s}={d},{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_RECV_MODE),
                id,
                @intFromEnum(config.recv_mode),
                postfix,
            }) catch unreachable;
            recv_mode.len = cmd_slice.len;
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .NETWORK_RECV_MODE,
                .Extra_data = .{ .Command = recv_mode },
            }, runner_inst) catch unreachable;

            //send connect request
            const pkg = TXEventPkg{ .cmd_enum = .NETWORK_CONNECT, .Extra_data = .{
                .Socket = .{
                    .descriptor_id = id,
                    .pkg_type = .{
                        .ConnectConfig = config,
                    },
                },
            } };
            self.runner_loop.store_tx_data(pkg, runner_inst) catch unreachable;
        }
        pub fn accept(self: *Self, id: usize) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;

            if (id >= self.Network_binds.len) return DriverError.INVALID_ARGS;
            const recv_buffer_size = 2046 - 50; //50bytes  of pre-data
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .NETWORK_RECV,
                .Extra_data = .{
                    .Socket = .{
                        .descriptor_id = id,
                        .pkg_type = .{
                            .AcceptPkg = recv_buffer_size,
                        },
                    },
                },
            }, runner_inst) catch return DriverError.TX_BUFFER_FULL;
        }

        fn accpet_fn(ctx: *anyopaque, id: usize) Network.ClientError!void {
            const driver: *Self = @alignCast(@ptrCast(ctx));
            driver.accept(id) catch return error.InternalError;
        }

        pub fn send(self: *Self, id: usize, data: []const u8) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;

            if (id >= self.Network_binds.len) return DriverError.INVALID_ARGS;
            if (data.len > 2048) return DriverError.INVALID_ARGS;
            const free_TX_cmd = self.runner_loop.get_tx_free_space(runner_inst);
            if (free_TX_cmd < 2) return DriverError.BUSY; //keep some space to other commands

            if (self.Network_binds[id]) |*bd| {
                self.runner_loop.store_tx_data(TXEventPkg{
                    .cmd_enum = .NETWORK_SEND,
                    .Extra_data = .{
                        .Socket = .{
                            .descriptor_id = id,
                            .pkg_type = .{
                                .SendPkg = .{ .data = data },
                            },
                        },
                    },
                }, runner_inst) catch return DriverError.TX_BUFFER_FULL;
                bd.to_send += 1;
                return;
            }
            return DriverError.INVALID_BIND;
        }

        fn send_fn(ctx: *anyopaque, id: usize, data: []const u8) Network.ClientError!void {
            const driver: *Self = @alignCast(@ptrCast(ctx));
            driver.send(id, data) catch return error.InternalError;
        }
        ///sends data to a specific host, can only be used on UDP type connections.
        ///always result in a send fail if used in TCP or SSL conn
        pub fn send_to(self: *Self, id: usize, data: []const u8, remote_host: []const u8, remote_port: u16) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;
            if (id >= self.Network_binds.len) return DriverError.INVALID_ARGS;
            if (data.len > 2048) return DriverError.INVALID_ARGS;
            const free_TX_cmd = self.runner_loop.get_tx_free_space(runner_inst);
            if (free_TX_cmd < 2) return DriverError.BUSY; //keep some space to other commands

            if (!std.net.isValidHostName(remote_host)) return error.INVALID_ARGS;
            if (remote_port == 0) return error.INVALID_ARGS;

            if (self.Network_binds[id]) |*bd| {
                const pkg = TXEventPkg{
                    .cmd_enum = .NETWORK_SEND,
                    .Extra_data = .{
                        .Socket = .{
                            .descriptor_id = id,
                            .pkg_type = .{
                                .SendToPkg = .{
                                    .data = data,
                                    .remote_host = remote_host,
                                    .remote_port = remote_port,
                                },
                            },
                        },
                    },
                };
                self.runner_loop.store_tx_data(pkg, runner_inst) catch return DriverError.TX_BUFFER_FULL;
                bd.to_send += 1;
                return;
            }
            return DriverError.INVALID_BIND;
        }

        fn sendTo_fn(ctx: *anyopaque, id: usize, data: []const u8, remote_host: []const u8, remote_port: u16) Network.ClientError!void {
            const driver: *Self = @alignCast(@ptrCast(ctx));
            driver.send_to(id, data, remote_host, remote_port) catch return error.InternalError;
        }

        pub fn create_server(self: *Self, config: ServerConfig) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;

            if (self.network_mode == NetworkDriveMode.CLIENT_ONLY) return DriverError.SERVER_OFF;

            const end_bind = self.div_binds;
            var cmd_slice: []const u8 = undefined;

            var pkg: CommandPkg = .{};

            if (self.network_mode == .SERVER_ONLY) {
                if (self.runner_loop.get_tx_free_space(runner_inst) < 3) return DriverError.TX_BUFFER_FULL;
                cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=5,{d}{s}", .{
                    prefix,
                    get_cmd_string(.NETWORK_RECV_MODE),
                    @intFromEnum(config.recv_mode),
                    postfix,
                }) catch unreachable;

                pkg.len = cmd_slice.len;
                self.runner_loop.store_tx_data(TXEventPkg{
                    .cmd_enum = .NETWORK_RECV_MODE,
                    .Extra_data = .{ .Command = pkg },
                }, runner_inst) catch unreachable;
            } else {
                if (self.runner_loop.get_tx_free_space(runner_inst) < (end_bind + 2)) return DriverError.TX_BUFFER_FULL;
                for (0..end_bind) |id| {
                    cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d},{d}{s}", .{
                        prefix,
                        get_cmd_string(.NETWORK_RECV_MODE),
                        id,
                        @intFromEnum(config.recv_mode),
                        postfix,
                    }) catch unreachable;

                    pkg.len = cmd_slice.len;
                    self.runner_loop.store_tx_data(TXEventPkg{
                        .cmd_enum = .NETWORK_RECV_MODE,
                        .Extra_data = .{ .Command = pkg },
                    }, runner_inst) catch unreachable;
                }
            }

            cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1,{d}", .{
                prefix,
                get_cmd_string(.NETWORK_SERVER),
                config.port,
            }) catch unreachable;
            var slice_len = cmd_slice.len;
            switch (config.server_type) {
                .Default => {
                    cmd_slice = std.fmt.bufPrint(pkg.str[slice_len..], "{s}", .{postfix}) catch unreachable;
                    slice_len += cmd_slice.len;
                },

                .SSL => {
                    cmd_slice = std.fmt.bufPrint(pkg.str[slice_len..], ",\"SSL\"{s}", .{postfix}) catch unreachable;
                    slice_len += cmd_slice.len;
                },

                .TCP => {
                    cmd_slice = std.fmt.bufPrint(pkg.str[slice_len..], ",\"TCP\"{s}", .{postfix}) catch unreachable;
                    slice_len += cmd_slice.len;
                },

                else => return DriverError.INVALID_ARGS,
            }
            pkg.len = slice_len;
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .NETWORK_SERVER,
                .Extra_data = .{ .Command = pkg },
            }, runner_inst) catch return DriverError.TX_BUFFER_FULL;

            if (config.timeout) |timeout| {
                const time = @min(7200, timeout);
                cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{
                    prefix,
                    get_cmd_string(.NETWORK_SERVER_TIMEOUT),
                    time,
                    postfix,
                }) catch unreachable;
                pkg.len = cmd_slice.len;
                self.runner_loop.store_tx_data(TXEventPkg{
                    .cmd_enum = .NETWORK_SERVER_TIMEOUT,
                    .Extra_data = .{ .Command = pkg },
                }, runner_inst) catch unreachable;
            }

            for (0..end_bind) |id| {
                try self.release(id);
                self.Network_binds[id] = Network.Handler{
                    .event_callback = config.callback,
                    .user_data = config.user_data,
                    .client = self.create_client(id),
                };
            }
        }

        pub fn release(self: *Self, id: usize) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;

            if (id > self.Network_binds.len) return DriverError.INVALID_BIND;

            //clear all Sockect Pkg
            if (self.Network_binds[id]) |*bd| {
                const TX_size = self.runner_loop.get_tx_len(runner_inst);
                for (0..TX_size) |_| {
                    const data = self.runner_loop.get_tx_data(runner_inst).?;
                    switch (data.Extra_data) {
                        .Socket => |net_data| {
                            if (id == net_data.descriptor_id) {
                                switch (net_data.pkg_type) {
                                    .SendPkg => |to_clear| {
                                        bd.client.event = .{ .SendData = .{
                                            .data = to_clear.data,
                                            .state = .cancel,
                                        } };
                                        bd.notify();
                                    },
                                    else => {},
                                }
                                continue;
                            }
                        },
                        else => {},
                    }
                    self.runner_loop.store_tx_data(data, runner_inst) catch return;
                }
            }
            self.Network_binds[id] = null;
        }

        pub fn delete_server(self: *Self) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;

            for (0..self.div_binds) |bind_id| {
                self.release(bind_id);
            }

            //send server close server command
            var pkg: CommandPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=0,1{s}", .{ prefix, get_cmd_string(Commands.NETWORK_SERVER), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .NETWORK_SERVER,
                .Extra_data = .{ .Command = pkg },
            }, runner_inst) catch DriverError.TX_BUFFER_FULL;
        }

        //functions

        pub fn link_device(self: *Self, runner: anytype) void {
            const info = @typeInfo(@TypeOf(runner));
            switch (info) {
                .Pointer => |ptr| {
                    const child_type = ptr.child;
                    if (@hasField(child_type, "net_device")) {
                        const net_device = &runner.net_device;
                        if (@TypeOf(net_device.*) == *Device) {
                            self.device.device_instance = self;
                            net_device.* = &self.device;
                        } else {
                            @compileError("net_device need to be a Device pointer");
                        }
                    } else {
                        @compileError(std.fmt.comptimePrint("type {s} does not have field \"net_device\"", .{@typeName(runner)}));
                    }

                    if (@hasField(child_type, "runner_dev")) {
                        if (@TypeOf(runner.runner_dev) == Runner) {
                            self.runner_loop = &(runner.*.runner_dev);
                        } else {
                            @compileError("runner_dev need to be a Runner type");
                        }
                    } else {
                        @compileError(std.fmt.comptimePrint("type {s} does not have field \"runner_dev\"", .{@typeName(runner)}));
                    }
                },
                else => {
                    @compileError("\"runner\" need to be a Pointer");
                },
            }
        }

        pub fn init() Self {
            var net_dev = Self{};
            for (0..binds) |index| {
                net_dev.Network_binds[index] = null;
            }
            return net_dev;
        }
    };
}

pub const WiFiDevice = struct {
    const CMD_CALLBACK_TYPE = *const fn (self: *WiFiDevice, buffer: []const u8) DriverError!void;
    const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
        .{ "WIFI", WiFiDevice.wifi_response },
        .{ "+CIPSTA", WiFiDevice.WiFi_get_AP_info },
        .{ "+CWJAP", WiFiDevice.WiFi_error },
        .{ "+STA_CONNECTED", WiFiDevice.WiFi_get_device_conn_mac },
        .{ "+DIST_STA_IP", WiFiDevice.WiFi_get_device_ip },
        .{ "+STA_DISCONNECTED", WiFiDevice.WiFi_get_device_disc_mac },
    });

    runner_loop: *Runner = undefined,
    device: Device = .{
        .pool_data = pool_data,
        .check_cmd = check_cmd,
        .apply_cmd = apply_cmd,
        .ok_handler = ok_handler,
        .err_handler = err_handler,
    },

    Wifi_state: WiFistate = .OFF,
    Wifi_mode: WiFiDriverMode = .NONE,
    WiFi_dhcp: WiFi.DHCPEnable = .{},
    //callback handlers
    WiFi_user_data: ?*anyopaque = null,
    on_WiFi_event: WIFI_event_type = null,
    STAFlag: bool = false,

    //Device functions

    fn pool_data(_: *anyopaque) []const u8 {
        return "";
    }

    fn check_cmd(cmd: []const u8, buffer: []const u8, device_inst: *anyopaque) DriverError!void {
        const self: *WiFiDevice = @alignCast(@ptrCast(device_inst));
        const response_callback = cmd_response_map.get(cmd);
        if (response_callback) |callback| {
            try @call(.auto, callback, .{ self, buffer });
            return;
        }
    }

    fn apply_cmd(pkg: TXEventPkg, input_buffer: []u8, device_inst: *anyopaque) []const u8 {
        var self: *WiFiDevice = @alignCast(@ptrCast(device_inst));
        const runner_inst = self.runner_loop.runner_instance;

        switch (pkg.Extra_data) {
            .WiFi => |data| {
                switch (data) {
                    .AP_conf_pkg => |wpkg| {
                        return WiFi_apply_AP_config(wpkg, input_buffer);
                    },
                    .STA_conf_pkg => |wpkg| {
                        self.runner_loop.set_busy_flag(1, runner_inst);
                        self.STAFlag = true;
                        return WiFi_apply_STA_config(wpkg, input_buffer);
                    },
                    .MAC_config => |wpkg| {
                        return apply_WiFi_mac(pkg.cmd_enum, wpkg, input_buffer);
                    },
                    .static_ap_config => |wpkg| {
                        return apply_static_ip(pkg.cmd_enum, wpkg, input_buffer);
                    },
                    .dhcp_config => |wpkg| {
                        return apply_DHCP_config(wpkg, input_buffer);
                    },
                }
            },
            else => {},
        }
        return "\r\n";
    }

    fn apply_WiFi_mac(cmd_data: Commands, mac: []const u8, input_buffer: []u8) []const u8 {
        return WiFi.set_mac(input_buffer, cmd_data, mac) catch unreachable;
    }

    fn apply_static_ip(cmd_data: Commands, ip: WiFi.StaticIp, input_buffer: []u8) []const u8 {
        return WiFi.set_static_ip(input_buffer, cmd_data, ip) catch unreachable;
    }

    fn apply_DHCP_config(dhcp: WiFi.DHCPConfig, input_buffer: []u8) []const u8 {
        return WiFi.set_DHCP_config(input_buffer, dhcp) catch unreachable;
    }

    fn WiFi_apply_AP_config(config: WiFi.APpkg, input_buffer: []u8) []const u8 {
        return WiFi.set_AP_config(input_buffer, config) catch unreachable;
    }

    fn WiFi_apply_STA_config(config: WiFi.STApkg, input_buffer: []u8) []const u8 {
        return WiFi.set_STA_config(input_buffer, config) catch unreachable;
    }

    fn ok_handler(device_inst: *anyopaque) void {
        response_handler(device_inst);
    }
    fn err_handler(device_inst: *anyopaque) void {
        response_handler(device_inst);
    }

    fn response_handler(device_inst: *anyopaque) void {
        var self: *WiFiDevice = @alignCast(@ptrCast(device_inst));
        const runner_inst = self.runner_loop.runner_instance;
        if (self.STAFlag) {
            self.runner_loop.set_busy_flag(0, runner_inst);
            self.STAFlag = false;
        }
    }

    fn wifi_response(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        const inst = self.runner_loop.runner_instance;
        const wifi_event_slice = get_cmd_slice(aux_buffer[5..], &[_]u8{}, &[_]u8{'\r'});
        const base_event = WiFi.get_base_event(wifi_event_slice) catch return DriverError.INVALID_RESPONSE;
        const event: WifiEvent = switch (base_event) {
            .AP_DISCONNECTED => WifiEvent{ .AP_DISCONNECTED = {} },
            .AP_CON_START => WifiEvent{ .AP_CON_START = {} },
            .AP_CONNECTED => WifiEvent{ .AP_CONNECTED = {} },
            else => unreachable,
        };

        if (base_event == .AP_CONNECTED) {
            var pkg: CommandPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}?{s}", .{ prefix, get_cmd_string(.WIFI_STA_IP), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .WIFI_STA_IP,
                .Extra_data = .{ .Command = pkg },
            }, inst) catch return DriverError.TX_BUFFER_FULL;
        }
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    fn WiFi_get_AP_info(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        const event_slice = get_cmd_slice(aux_buffer[8..], &[_]u8{}, &[_]u8{':'});
        const data_start = event_slice.len + 10;
        const data_slice = get_cmd_slice(aux_buffer[data_start..], &[_]u8{}, &[_]u8{'"'});
        const base_event = WiFi.get_base_event(event_slice) catch return DriverError.INVALID_RESPONSE;
        const event: WifiEvent = switch (base_event) {
            .AP_GOT_GATEWAY => WifiEvent{ .AP_GOT_GATEWAY = data_slice },
            .AP_GOT_IP => WifiEvent{ .AP_GOT_IP = data_slice },
            .AP_GOT_MASK => WifiEvent{ .AP_GOT_MASK = data_slice },
            else => unreachable,
        };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
        self.Wifi_state = .CONNECTED;
    }

    fn WiFi_error(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        const inst = self.runner_loop.runner_instance;
        self.runner_loop.set_busy_flag(0, inst);
        if (aux_buffer.len < 8) return DriverError.INVALID_RESPONSE;
        const error_id = WiFi.get_error_event(aux_buffer);
        const event = WifiEvent{ .ERROR = error_id };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    fn WiFi_get_device_conn_mac(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        if (aux_buffer.len < 34) return DriverError.INVALID_ARGS;
        const mac = aux_buffer[16..33];
        const event = WifiEvent{ .STA_CONNECTED = mac };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }
    fn WiFi_get_device_ip(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        if (aux_buffer.len < 46) return DriverError.INVALID_RESPONSE;
        const mac = get_cmd_slice(aux_buffer[14..], &[_]u8{}, &[_]u8{'"'});
        const ip = get_cmd_slice(aux_buffer[34..], &[_]u8{}, &[_]u8{'"'});
        const event = WifiEvent{ .STA_GOT_IP = .{ .ip = ip, .mac = mac } };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    fn WiFi_get_device_disc_mac(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        if (aux_buffer.len < 37) return DriverError.INVALID_ARGS;
        const mac = aux_buffer[19..36];
        const event = WifiEvent{ .STA_DISCONNECTED = mac };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    //WiFi functions
    pub fn WiFi_connect_AP(self: *WiFiDevice, config: WiFiSTAConfig) !void {
        const inst = self.runner_loop.runner_instance;

        if (self.Wifi_mode == .AP) {
            return DriverError.STA_OFF;
        } else if (self.Wifi_mode == WiFiDriverMode.NONE) {
            return DriverError.WIFI_OFF;
        }
        const free_tx = self.runner_loop.get_tx_free_space(inst);
        const pkgs = try WiFi.check_STA_config(config);
        if (free_tx < pkgs) return DriverError.TX_BUFFER_FULL;

        var pkg: CommandPkg = .{};

        if (config.wifi_protocol) |proto| {
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{
                prefix,
                get_cmd_string(.WIFI_STA_PROTO),
                @as(u4, @bitCast(proto)),
                postfix,
            }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .WIFI_STA_PROTO,
                .Extra_data = .{ .Command = pkg },
            }, inst) catch unreachable;
        }

        if (config.mac) |mac| {
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .WIFI_STA_MAC,
                .Extra_data = .{
                    .WiFi = .{ .MAC_config = mac },
                },
            }, inst) catch unreachable;
        }

        if (config.wifi_ip) |ip_mode| {
            switch (ip_mode) {
                .DHCP => {
                    self.WiFi_dhcp.STA = 1;
                    const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1,{d}{s}", .{
                        prefix,
                        get_cmd_string(.WiFi_SET_DHCP),
                        @as(u2, @bitCast(self.WiFi_dhcp)),
                        postfix,
                    }) catch unreachable;
                    pkg.len = cmd_slice.len;
                    self.runner_loop.store_tx_data(TXEventPkg{
                        .cmd_enum = .WiFi_SET_DHCP,
                        .Extra_data = .{ .Command = pkg },
                    }, inst) catch unreachable;
                },
                .static => |static_ip| {
                    self.WiFi_dhcp.STA = 0;
                    self.runner_loop.store_tx_data(TXEventPkg{
                        .cmd_enum = .WIFI_STA_IP,
                        .Extra_data = .{
                            .WiFi = .{
                                .static_ap_config = static_ip,
                            },
                        },
                    }, inst) catch unreachable;
                },
            }
        }

        self.runner_loop.store_tx_data(TXEventPkg{ .cmd_enum = .WIFI_CONNECT, .Extra_data = .{
            .WiFi = .{
                .STA_conf_pkg = WiFi.STApkg.from_config(config),
            },
        } }, inst) catch unreachable;
    }

    pub fn WiFi_config_AP(self: *WiFiDevice, config: WiFiAPConfig) !void {
        const inst = self.runner_loop.runner_instance;

        if (self.Wifi_mode == .STA) {
            return DriverError.AP_OFF;
        } else if (self.Wifi_mode == .NONE) {
            return DriverError.WIFI_OFF;
        }
        const free_tx = self.runner_loop.get_tx_free_space(inst);
        const pkgs = try WiFi.check_AP_config(config);

        if (free_tx < pkgs) return DriverError.TX_BUFFER_FULL;

        var pkg: CommandPkg = .{};

        if (config.wifi_protocol) |proto| {
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{
                prefix,
                get_cmd_string(.WIFI_AP_PROTO),
                @as(u4, @bitCast(proto)),
                postfix,
            }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .WIFI_AP_PROTO,
                .Extra_data = .{ .Command = pkg },
            }, inst) catch unreachable;
        }

        if (config.mac) |mac| {
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .WIFI_AP_MAC,
                .Extra_data = .{
                    .WiFi = .{
                        .MAC_config = mac,
                    },
                },
            }, inst) catch unreachable;
        }

        if (config.wifi_ip) |ip_mode| {
            switch (ip_mode) {
                .DHCP => {
                    self.WiFi_dhcp.AP = 1;
                    const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=1,{d}{s}", .{
                        prefix,
                        get_cmd_string(.WiFi_SET_DHCP),
                        @as(u2, @bitCast(self.WiFi_dhcp)),
                        postfix,
                    }) catch unreachable;
                    pkg.len = cmd_slice.len;
                    self.runner_loop.store_tx_data(TXEventPkg{
                        .cmd_enum = .WiFi_SET_DHCP,
                        .Extra_data = .{ .Command = pkg },
                    }, inst) catch unreachable;
                },
                .static => |static_ip| {
                    self.WiFi_dhcp.AP = 0;
                    const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=", .{
                        prefix,
                        get_cmd_string(.WIFI_AP_IP),
                    }) catch unreachable;
                    pkg.len = cmd_slice.len;
                    self.runner_loop.store_tx_data(TXEventPkg{
                        .cmd_enum = .WIFI_AP_IP,
                        .Extra_data = .{
                            .WiFi = .{
                                .static_ap_config = static_ip,
                            },
                        },
                    }, inst) catch unreachable;
                },
            }
        }

        if (config.dhcp_config) |dhcp| {
            self.runner_loop.store_tx_data(TXEventPkg{ .cmd_enum = .WiFi_CONF_DHCP, .Extra_data = .{
                .WiFi = .{
                    .dhcp_config = dhcp,
                },
            } }, inst) catch unreachable;
        }

        self.runner_loop.store_tx_data(TXEventPkg{ .cmd_enum = .WIFI_CONF, .Extra_data = .{
            .WiFi = .{
                .AP_conf_pkg = WiFi.APpkg.from_config(config),
            },
        } }, inst) catch unreachable;
    }

    pub fn set_WiFi_mode(self: *WiFiDevice, mode: WiFiDriverMode) !void {
        const inst = self.runner_loop.runner_instance;

        var pkg: CommandPkg = .{};
        const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{ prefix, get_cmd_string(.WIFI_SET_MODE), @intFromEnum(mode), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner_loop.store_tx_data(TXEventPkg{
            .cmd_enum = .WIFI_SET_MODE,
            .Extra_data = .{ .Command = pkg },
        }, inst) catch return DriverError.TX_BUFFER_FULL;
        self.Wifi_mode = mode;
    }

    pub fn WiFi_disconnect(self: *WiFiDevice) DriverError!void {
        const inst = self.runner_loop.runner_instance;

        var pkg: CommandPkg = .{};
        const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}{s}", .{
            prefix,
            get_cmd_string(.WIFI_DISCONNECT),
            postfix,
        }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner_loop.store_tx_data(TXEventPkg{
            .cmd_enum = .WIFI_DISCONNECT,
            .Extra_data = .{ .Command = pkg },
        }, inst) catch return DriverError.TX_BUFFER_FULL;
    }

    pub fn WiFi_disconnect_device(self: *WiFiDevice, mac: []const u8) DriverError!void {
        const inst = self.runner_loop.runner_instance;
        self.runner_loop.store_tx_data(TXEventPkg{
            .cmd_enum = .WIFI_DISCONNECT_DEVICE,
            .Extra_data = .{
                .WiFi = .{
                    .MAC_config = mac,
                },
            },
        }, inst) catch return DriverError.TX_BUFFER_FULL;
    }

    pub fn set_WiFi_event_handler(self: *WiFiDevice, callback: WIFI_event_type, user_data: ?*anyopaque) void {
        self.on_WiFi_event = callback;
        self.WiFi_user_data = user_data;
    }

    pub fn init() WiFiDevice {
        return WiFiDevice{};
    }
};
