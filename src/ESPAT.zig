const std = @import("std");
const fifo = std.fifo;

const WiFi = @import("util/WiFi.zig");
pub const WiFiAPConfig = WiFi.WiFiAPConfig;
pub const WiFiSTAConfig = WiFi.WiFiSTAConfig;
pub const WifiEvent = WiFi.WifiEvent;
pub const WiFiEncryption = WiFi.WiFiEncryption;

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
    read_long,
    OFF,
    FATAL_ERROR,
};

pub const WiFistate = enum {
    OFF,
    DISCONECTED,
    CONNECTED,
};

pub const Commands = enum(u8) {
    DUMMY,
    RESET,
    ECHO_OFF,
    ECHO_ON,
    SYSSTORE,
    IP_MUX,
    WIFI_SET_MODE,
    WIFI_CONNECT,
    WIFI_CONF,
    WIFI_DISCONNECT,
    WIFI_AUTOCONN,
    NETWORK_CONNECT,
    NETWORK_SEND,
    NETWORK_CLOSE,
    NETWORK_IP,
    NETWORK_SERVER_CONF,
    NETWORK_SERVER,
    NETWORK_RECV_MODE,
    NETWORK_RECV,
    NETWORK_MSG_CONFIG,
    //Extra

};

//This is not necessary since the user cannot send commands directly, but useful for debug
pub const COMMANDS_TOKENS = [_][]const u8{
    ".",
    "RST",
    "ATE0",
    "ATE1",
    "SYSSTORE",
    "CIPMUX",
    "CWMODE",
    "CWJAP",
    "CWSAP",
    "CWQAP",
    "CWAUTOCONN",
    "CIPSTART",
    "CIPSENDEX",
    "CIPCLOSE",
    "CIPSTA",
    "CIPSERVERMAXCONN",
    "CIPSERVER",
    "CIPRECVMODE",
    "CIPRECVDATA",
    "CIPDINFO",
};

pub inline fn get_cmd_string(cmd: Commands) []const u8 {
    return COMMANDS_TOKENS[@intFromEnum(cmd)];
}

const prefix = "AT+";
const infix = "_CUR";
const postfix = "\r\n";

pub const CommandResults = enum(u8) { Ok, Error };

pub const SEND_RESPONSE_TOKEN = [_][]const u8{
    "OK",
    "FAIL",
};

//TODO: add more events
pub const NetworkEvent = union(enum) {
    Connected: void,
    Closed: void,
    DataReport: usize,
    ReadData: []const u8,
    SendDataComplete: []const u8,
    SendDataFail: void,
};

pub const NetworkHandlerState = enum {
    None,
    Connected,
    Closed,
};
pub const NetworkHandlerType = enum {
    Default,
    TCP,
    UDP,
    SSL,
};

pub const BusyBitFlags = packed struct {
    Reset: bool,
    Command: bool,
    Socket: bool,
    WiFi: bool,
    Bluetooth: bool,
};

pub const CommandPackage = struct {
    busy_flag: bool = false,
};

pub const NetworkSendPkg = struct {
    data: []const u8 = undefined,
};

pub const NetworkClosePkg = void;
pub const NetWorkTCPConn = struct {
    keep_alive: u16 = 0,
};

pub const NetworkUDPModes = enum {
    Unchanged,
    Change_first,
    Change_all,
};

pub const NetworkUDPConn = struct {
    local_port: ?u16 = null,
    mode: NetworkUDPModes = .Unchanged,
};
pub const NetWorkConnectType = union(enum) {
    tcp: NetWorkTCPConn,
    ssl: NetWorkTCPConn,
    udp: NetworkUDPConn,
};
pub const NetworkConnectPkg = struct {
    remote_host: []const u8,
    remote_port: u16,
    config: NetWorkConnectType,
};

pub const NetWorPkgType = union(enum) {
    NetworkSendPkg: NetworkSendPkg,
    NetworkClosePkg: NetworkClosePkg,
    NetworkConnectPkg: NetworkConnectPkg,
};

pub const NetworkPackage = struct {
    descriptor_id: usize = 255,
    pkg_type: NetWorPkgType,
};

pub const WiFiPackage = union(enum) {
    AP_conf_pkg: WiFiAPConfig,
    STA_conf_pkg: WiFiSTAConfig,
};

pub const BluetoothPackage = struct {
    //TODO
};

pub const TXExtraData = union(enum) {
    Reset: void,
    Command: void,
    Socket: NetworkPackage,
    WiFi: WiFiPackage,
    Bluetooth: BluetoothPackage,
};

pub const TXEventPkg = struct {
    cmd_data: [25]u8 = undefined, //maybe renove this end just create "apply" methods for each command and save some memory
    cmd_len: usize = 0,
    cmd_enum: Commands = .DUMMY,
    Extra_data: TXExtraData = .{ .Command = {} },
};

const NetworkToRead = struct {
    id: usize,
    to_read: usize,
    data_offset: usize,
    start_index: usize,
};

const NetworkToSend = struct {
    id: usize = 255,
    data: []const u8 = undefined,
};

pub const TX_callback = *const fn (data: []const u8, user_data: ?*anyopaque) void;
pub const RX_callback = ?*const fn (free_data: usize, user_data: ?*anyopaque) []u8;
pub const WIFI_event_type = ?*const fn (event: WifiEvent, data: ?[]const u8, user_data: ?*anyopaque) void;
pub const response_event_type = ?*const fn (result: CommandResults, cmd: Commands, user_data: ?*anyopaque) void;

pub fn EspAT(comptime RX_SIZE: comptime_int, comptime TX_event_pool: comptime_int) type {
    if (RX_SIZE <= 50) @compileError("RX SIZE CANNOT BE LESS THAN 50 byte");
    if (TX_event_pool <= 5) @compileError(" NETWORK POOL SIZE CANNOT BE LESS THAN 5 events"); //
    return struct {

        // data types
        const Self = @This();

        pub const Client = struct {
            id: usize,
            driver: *Self,
            event: NetworkEvent,

            pub fn send(self: *const Client, data: []const u8) DriverError!void {
                try self.driver.send(self.id, data);
            }

            pub fn close(self: *const Client) DriverError!void {
                try self.driver.close(self.id);
            }
            pub fn accept(self: *const Client) DriverError!void {
                try self.driver.accept(self.id);
            }
        };

        pub const network_handler = struct {
            state: NetworkHandlerState = .None,
            to_send: usize = 0,
            event_callback: ?ClientCallback = null,
            user_data: ?*anyopaque = null,
        };
        const ClientCallback = *const fn (client: Client, user_data: ?*anyopaque) void;
        const CMD_CALLBACK_TYPE = *const fn (self: *Self, aux_buffer: []const u8) DriverError!void;
        const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
            .{ "ready", Self.driver_ready },
            .{ "OK", Self.ok_response },
            .{ "ERROR", Self.error_response },
            .{ "FAIL", Self.error_response },
            .{ ",CONNECT", Self.network_conn_event },
            .{ ",CLOSED", Self.network_closed_event },
            .{ "SEND", Self.network_send_event },
            .{ "+IPD", Self.parse_network_data },
            .{ "+CIPRECVDATA", Self.network_read_data },
            .{ "WIFI", Self.wifi_response },
            .{ "+CIPSTA", Self.WiFi_get_AP_info },
            .{ "+CWJAP", Self.WiFi_error },
            .{ "+STA_CONNECTED", Self.WiFi_get_device_conn_mac },
            .{ "+DIST_STA_IP", Self.WiFi_get_device_ip },
            .{ "+STA_DISCONNECTED", Self.WiFi_get_device_disc_mac },
        });

        //internal control data, (Do not modify)
        RX_fifo: fifo.LinearFifo(u8, .{ .Static = RX_SIZE }),
        TX_fifo: fifo.LinearFifo(TXEventPkg, .{ .Static = TX_event_pool }),
        TX_wait_response: ?Commands = null,
        TX_callback_handler: TX_callback,
        RX_callback_handler: RX_callback,
        busy_flag: BusyBitFlags = .{
            .Reset = false,
            .Command = false,
            .Socket = false,
            .WiFi = false,
            .Bluetooth = false,
        },
        internal_aux_buffer: [9000]u8 = undefined,
        internal_aux_buffer_pos: usize = 0,

        //Long data needs to be handled in a special state
        //to avoid locks on the executor while reading this data
        //only for command data responses (+<cmd>:data)
        long_data_request: bool = false,
        long_data: NetworkToRead = undefined,

        machine_state: Drive_states = .init,
        Wifi_state: WiFistate = .OFF,
        Wifi_mode: WiFiDriverMode = .NONE,
        network_mode: NetworkDriveMode = .CLIENT_ONLY,
        div_binds: usize = 0,

        //network data
        Network_binds: [5]?network_handler = .{ null, null, null, null, null },
        Network_corrent_pkg: NetworkToSend = .{},

        //callback handlers

        TX_RX_user_data: ?*anyopaque = null,
        WiFi_user_data: ?*anyopaque = null,
        Error_handler_user_data: ?*anyopaque = null,
        on_cmd_response: response_event_type = null,
        on_WiFi_event: WIFI_event_type = null,
        pub inline fn get_rx_free_space(self: *Self) usize {
            return self.RX_fifo.writableLength();
        }

        fn get_data(self: *Self) void {
            const free_space = self.get_rx_free_space();
            if (self.RX_callback_handler) |rxcallback| {
                const data_slice = rxcallback(free_space, self.TX_RX_user_data);
                const slice = if (data_slice.len > free_space) data_slice[0..free_space] else data_slice;
                self.RX_fifo.write(slice) catch unreachable;
            }
        }

        pub fn notify(self: *Self, data: []const u8) void {
            const free_space = self.get_rx_free_space();
            const slice = if (data.len > free_space) data[0..free_space] else data;
            self.RX_fifo.write(slice) catch unreachable;
        }

        fn get_cmd_type(self: *Self, aux_buffer: []const u8) DriverError!void {
            const response = get_cmd_slice(aux_buffer, &[_]u8{','}, &[_]u8{ ' ', '\r' });
            const response_callback = cmd_response_map.get(response);
            if (response_callback) |callback| {
                try @call(.auto, callback, .{ self, aux_buffer });
                return;
            }
        }

        fn get_cmd_data_type(self: *Self, aux_buffer: []const u8) DriverError!void {
            const response = get_cmd_slice(aux_buffer, &[_]u8{}, &[_]u8{ ':', ',' });
            const response_callback = cmd_response_map.get(response);
            if (response_callback) |callback| {
                try @call(.auto, callback, .{ self, aux_buffer });
                return;
            }
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
                    callback(.Ok, resp, self.Error_handler_user_data);
                }
            }
            self.TX_wait_response = null;
        }

        fn error_response(self: *Self, _: []const u8) DriverError!void {
            const cmd = self.TX_wait_response;
            self.busy_flag.Command = false;
            if (cmd) |resp| {
                switch (resp) {
                    .NETWORK_SEND => {
                        //clear current pkg on cipsend error (This happens only when a "CIPSEND" is sent to a client that is closed)
                        const pkg = self.Network_corrent_pkg;
                        const client = Client{
                            .driver = self,
                            .event = .{ .SendDataFail = {} },
                            .id = pkg.id,
                        };
                        if (self.Network_binds[pkg.id]) |*bd| {
                            if (bd.event_callback) |callback| {
                                callback(client, bd.user_data);
                            }
                        }

                        self.busy_flag.Socket = false;
                    },
                    else => {},
                }
                if (self.on_cmd_response) |callback| {
                    callback(.Error, resp, self.Error_handler_user_data);
                }
            }
            self.TX_wait_response = null;
        }

        fn wifi_response(self: *Self, aux_buffer: []const u8) DriverError!void {
            const wifi_event_slice = get_cmd_slice(aux_buffer[5..], &[_]u8{}, &[_]u8{'\r'});
            const base_event = WiFi.get_WiFi_base_event(wifi_event_slice);
            if (base_event == .WiFi_AP_CONNECTED) {
                var pkg: TXEventPkg = .{};
                const cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}?{s}", .{ prefix, get_cmd_string(.NETWORK_IP), postfix }) catch unreachable;
                pkg.cmd_len = cmd_slice.len;
                pkg.cmd_enum = .NETWORK_IP;
                self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
            }
            if (self.on_WiFi_event) |callback| {
                callback(base_event, null, self.WiFi_user_data);
            }
        }

        fn driver_ready(self: *Self, _: []const u8) DriverError!void {
            self.busy_flag.Reset = false;
        }

        fn WiFi_get_AP_info(self: *Self, aux_buffer: []const u8) DriverError!void {
            const event_slice = get_cmd_slice(aux_buffer[8..], &[_]u8{}, &[_]u8{':'});
            const data_start = event_slice.len + 10;
            const data_slice = get_cmd_slice(aux_buffer[data_start..], &[_]u8{}, &[_]u8{'"'});
            const wifi_event = WiFi.get_WiFi_base_event(event_slice);
            if (self.on_WiFi_event) |callback| {
                callback(wifi_event, data_slice, self.WiFi_user_data);
            }
            self.Wifi_state = .CONNECTED;
        }

        fn WiFi_error(self: *Self, aux_buffer: []const u8) DriverError!void {
            self.busy_flag.WiFi = false;
            if (aux_buffer.len < 8) return DriverError.INVALID_RESPONSE;
            const error_id = WiFi.get_WiFi_error_event(aux_buffer);
            if (self.on_WiFi_event) |callback| {
                callback(error_id, null, self.WiFi_user_data);
            }
        }

        fn WiFi_get_device_conn_mac(self: *Self, aux_buffer: []const u8) DriverError!void {
            if (aux_buffer.len < 34) return DriverError.INVALID_ARGS;
            const mac = aux_buffer[16..33];
            if (self.on_WiFi_event) |callback| {
                callback(.WiFi_STA_DISCONNECTED, mac, self.WiFi_user_data);
            }
        }
        fn WiFi_get_device_ip(self: *Self, aux_buffer: []const u8) DriverError!void {
            if (aux_buffer.len < 46) return DriverError.INVALID_RESPONSE;
            const ip = get_cmd_slice(aux_buffer[34..], &[_]u8{}, &[_]u8{'"'});
            if (self.on_WiFi_event) |callback| {
                callback(.WIFi_STA_GOT_IP, ip, self.WiFi_user_data);
            }
        }

        fn WiFi_get_device_disc_mac(self: *Self, aux_buffer: []const u8) DriverError!void {
            if (aux_buffer.len < 37) return DriverError.INVALID_ARGS;
            const mac = aux_buffer[19..36];
            if (self.on_WiFi_event) |callback| {
                callback(.WiFi_STA_DISCONNECTED, mac, self.WiFi_user_data);
            }
        }

        //+IPD only return \r\n at the and of the data pkg, and data pkg can be up to 8192 bytes
        //It is necessary to check how many bytes are already in the buffer before requesting more
        fn parse_network_data(self: *Self, aux_buffer: []const u8) DriverError!void {
            var slices = std.mem.split(u8, aux_buffer, ",");
            _ = slices.next(); //skip first arg (+IPD,)

            var id: usize = 0;
            var data_size: usize = 0;

            //get id
            if (slices.next()) |recive_id| {
                id = std.fmt.parseInt(usize, recive_id, 10) catch return DriverError.INVALID_RESPONSE;
                if (id > self.Network_binds.len) return DriverError.INVALID_BIND;
            } else {
                return DriverError.INVALID_RESPONSE;
            }

            //get data len
            if (slices.next()) |data_str| {
                const data_size_slice = get_cmd_slice(data_str, &[_]u8{}, &[_]u8{'\r'});
                data_size = std.fmt.parseInt(usize, data_size_slice, 10) catch return DriverError.INVALID_RESPONSE;
            } else {
                return DriverError.INVALID_RESPONSE;
            }

            if (self.Network_binds[id]) |bd| {
                if (bd.event_callback) |callback| {
                    const client = Client{
                        .driver = self,
                        .id = id,
                        .event = .{ .DataReport = data_size },
                    };
                    callback(client, bd.user_data);
                }
            }
        }

        fn network_read_data(self: *Self, aux_buffer: []const u8) DriverError!void {
            if (aux_buffer.len < 14) return DriverError.INVALID_RESPONSE;
            const data_str = aux_buffer[13..];
            const data_slice = get_cmd_slice(data_str, &[_]u8{}, &[_]u8{','});
            const data_len = std.fmt.parseInt(usize, data_slice, 10) catch return DriverError.INVALID_RESPONSE;
            const start = 14 + data_slice.len;
            self.long_data_request = true;
            self.long_data.to_read = data_len;
            self.long_data.start_index = start;
            self.long_data.data_offset = self.internal_aux_buffer_pos;
            self.machine_state = .read_long;
        }

        fn network_conn_event(self: *Self, aux_buffer: []const u8) DriverError!void {
            const id_index = aux_buffer[0];
            if ((id_index < '0') or (id_index > '9')) {
                return DriverError.INVALID_RESPONSE;
            }

            const index: usize = id_index - '0';
            if (index > self.Network_binds.len) return DriverError.INVALID_RESPONSE;

            if (self.Network_binds[index]) |*bd| {
                bd.state = .Connected;
                if (bd.event_callback) |callback| {
                    const client = Client{
                        .id = @intCast(index),
                        .event = .{ .Connected = {} },
                        .driver = self,
                    };
                    callback(client, bd.user_data);
                }
            }
        }

        fn network_closed_event(self: *Self, aux_buffer: []const u8) DriverError!void {
            const id_index = aux_buffer[0];
            if ((id_index < '0') or (id_index > '9')) {
                return DriverError.INVALID_RESPONSE;
            }

            const index: usize = id_index - '0';
            if (index > self.Network_binds.len) return DriverError.INVALID_RESPONSE;

            if (self.Network_binds[index]) |*bd| {
                bd.state = .Closed;
                var client: Client = undefined;
                if (bd.event_callback) |callback| {
                    client = Client{
                        .id = @intCast(index),
                        .event = .{ .Closed = {} },
                        .driver = self,
                    };
                    callback(client, bd.user_data);

                    //clear all pkgs from the TX pool
                    if (bd.to_send > 0) {
                        const cmd_len = self.TX_fifo.readableLength();
                        for (0..cmd_len) |_| {
                            const TX_pkg = self.TX_fifo.readItem().?;
                            switch (TX_pkg.Extra_data) {
                                .Socket => |*net_pkg| {
                                    const id = net_pkg.descriptor_id;
                                    if (id == index) {
                                        switch (net_pkg.pkg_type) {
                                            .NetworkSendPkg => |to_clear| {
                                                client.id = id;
                                                client.event = .{ .SendDataComplete = to_clear.data };
                                                callback(client, bd.user_data);
                                            },
                                            else => {},
                                        }
                                        continue;
                                    }
                                },
                                else => {},
                            }
                            self.TX_fifo.writeItem(TX_pkg) catch unreachable;
                        }
                        bd.to_send = 0;
                    }
                }
            }
        }

        fn network_send_event(self: *Self, aux_buffer: []const u8) DriverError!void {
            self.busy_flag.Socket = false;
            const send_event_slice = get_cmd_slice(aux_buffer[5..], &[_]u8{}, &[_]u8{'\r'});
            const result = std.mem.eql(u8, send_event_slice, SEND_RESPONSE_TOKEN[1]);
            if (result) {
                try self.network_send_resposnse();
                return;
            }
        }

        fn network_send_resposnse(self: *Self) DriverError!void {
            const to_free = self.Network_corrent_pkg;
            const pkg_id = to_free.id;
            if (pkg_id > self.Network_binds.len) return DriverError.INVALID_RESPONSE;
            if (self.Network_binds[pkg_id]) |*bd| {
                if (bd.event_callback) |callback| {
                    const client: Client = .{
                        .driver = self,
                        .event = .{ .SendDataFail = {} },
                        .id = pkg_id,
                    };
                    callback(client, bd.user_data);
                }
            }
        }

        //TODO: send dummy pkg if pkg is null to void deadlocks
        fn network_send_data(self: *Self) DriverError!void {
            const pkg = self.Network_corrent_pkg;
            //if pkg is invalid, close the send request"
            if (pkg.id < self.Network_binds.len) {
                self.TX_callback_handler(pkg.data, self.TX_RX_user_data);
                if (self.Network_binds[pkg.id]) |*bd| {
                    bd.to_send -= 1;
                    const client = Client{
                        .driver = self,
                        .event = .{ .SendDataComplete = pkg.data },
                        .id = pkg.id,
                    };
                    if (bd.event_callback) |callback| {
                        callback(client, bd.user_data);
                    }
                }
                return;
            }
        }

        fn WiFi_apply_AP_config(self: *Self, cmd: []const u8, config: WiFiAPConfig) DriverError!void {
            const config_str = WiFi.set_WiFi_AP_config(&self.internal_aux_buffer, cmd, config) catch unreachable;
            self.TX_callback_handler(config_str, self.TX_RX_user_data);
        }

        fn WiFi_apply_STA_config(self: *Self, cmd: []const u8, config: WiFiSTAConfig) DriverError!void {
            const config_str = WiFi.set_WiFi_STA_config(&self.internal_aux_buffer, cmd, config) catch unreachable;
            self.TX_callback_handler(config_str, self.TX_RX_user_data);
        }

        fn apply_tcp_config(self: *Self, id: usize, args: NetworkConnectPkg, tcp_conf: NetWorkTCPConn) void {
            var inner_buffer = &self.internal_aux_buffer;
            var cmd_slice: []const u8 = undefined;
            var cmd_size: usize = 0;
            cmd_slice = std.fmt.bufPrint(inner_buffer, "{s}{s}={d},\"TCP\",\"{s}\",{d},{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_CONNECT),
                id,
                args.remote_host,
                args.remote_port,
                tcp_conf.keep_alive,
                postfix,
            }) catch unreachable;
            cmd_size = cmd_slice.len;
            self.TX_callback_handler(inner_buffer[0..cmd_size], self.TX_RX_user_data);
        }
        fn apply_udp_config(self: *Self, id: usize, args: NetworkConnectPkg, udp_conf: NetworkUDPConn) void {
            var inner_buffer = &self.internal_aux_buffer;
            var cmd_slice: []const u8 = undefined;
            var cmd_size: usize = 0;
            cmd_slice = std.fmt.bufPrint(inner_buffer, "{s}{s}={d},\"UDP\",\"{s}\",{d}", .{
                prefix,
                get_cmd_string(.NETWORK_CONNECT),
                id,
                args.remote_host,
                args.remote_port,
            }) catch unreachable;
            cmd_size = cmd_slice.len;
            if (udp_conf.local_port) |port| {
                cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], ",{d}", .{port}) catch unreachable;
            } else {
                cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], ",", .{}) catch unreachable;
            }
            cmd_size += cmd_slice.len;
            cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], ",{d}{s}", .{ @intFromEnum(udp_conf.mode), postfix }) catch unreachable;
            cmd_size += cmd_slice.len;
            self.TX_callback_handler(inner_buffer[0..cmd_size], self.TX_RX_user_data);
        }

        pub fn process(self: *Self) DriverError!void {
            switch (self.machine_state) {
                .init => {
                    self.init_driver() catch return;
                },
                .IDLE => {
                    try self.IDLE_REV();
                    try self.IDLE_TRANS();
                },
                .read_long => try self.READ_LONG(),
                .OFF => return DriverError.DRIVER_OFF,
                .FATAL_ERROR => return DriverError.NON_RECOVERABLE_ERROR, //module need to reboot due a deadlock, Non-recoverable deadlocks occur when the data in a network packet is null.
            }
            self.get_data(); //read data for the next run
        }

        fn IDLE_REV(self: *Self) DriverError!void {
            const fifo_size = self.RX_fifo.readableLength();
            for (0..fifo_size) |_| {
                const rev_data = self.RX_fifo.readItem();
                if (rev_data) |data| {
                    self.internal_aux_buffer[self.internal_aux_buffer_pos] = data;
                    self.internal_aux_buffer_pos += 1;
                    self.internal_aux_buffer_pos %= self.internal_aux_buffer.len;
                    if (data == '\n') {
                        if (self.internal_aux_buffer_pos > 3) {
                            if (self.internal_aux_buffer[0] == '+') {
                                try self.get_cmd_data_type(self.internal_aux_buffer[0..self.internal_aux_buffer_pos]);
                                if (self.long_data_request) return;
                            } else {
                                try self.get_cmd_type(self.internal_aux_buffer[0..self.internal_aux_buffer_pos]);
                            }
                        }
                        self.internal_aux_buffer_pos = 0;
                    } else if (data == '>') {
                        try self.network_send_data();
                        self.internal_aux_buffer_pos = 0;
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
                const cmd_data = cmd.cmd_data[0..cmd.cmd_len];
                self.TX_wait_response = cmd.cmd_enum;
                switch (cmd.Extra_data) {
                    .Reset => {
                        self.TX_callback_handler("AT+RST\r\n", self.TX_RX_user_data);
                        self.busy_flag.Reset = true;
                    },
                    .Command => {
                        self.TX_callback_handler(cmd_data, self.TX_RX_user_data);
                        self.busy_flag.Command = true;
                    },
                    .Socket => |data| {
                        const id = data.descriptor_id;
                        switch (data.pkg_type) {
                            .NetworkSendPkg => |to_send| {
                                self.TX_callback_handler(cmd_data, self.TX_RX_user_data);
                                self.Network_corrent_pkg = NetworkToSend{
                                    .data = to_send.data,
                                    .id = id,
                                };
                                self.busy_flag.Socket = true;
                            },
                            .NetworkClosePkg => {
                                self.TX_callback_handler(cmd_data, self.TX_RX_user_data);
                                self.busy_flag.Command = true;
                                if (self.Network_binds[id]) |*bd| {
                                    bd.to_send -= 1;
                                }
                            },
                            .NetworkConnectPkg => |connpkg| {
                                switch (connpkg.config) {
                                    .tcp => |config| {
                                        self.apply_tcp_config(id, connpkg, config);
                                    },
                                    .ssl => |config| {
                                        self.apply_tcp_config(id, connpkg, config);
                                    },
                                    .udp => |config| {
                                        self.apply_udp_config(id, connpkg, config);
                                    },
                                }
                                self.busy_flag.Command = true;
                            },
                        }
                    },
                    .WiFi => |data| {
                        switch (data) {
                            .AP_conf_pkg => |pkg| {
                                try self.WiFi_apply_AP_config(cmd_data, pkg);
                                self.busy_flag.Command = true;
                            },
                            .STA_conf_pkg => |pkg| {
                                try self.WiFi_apply_STA_config(cmd_data, pkg);
                                self.busy_flag.WiFi = true;
                            },
                        }
                    },
                    .Bluetooth => {
                        //TODO
                    },
                }
            }
        }

        fn READ_LONG(self: *Self) DriverError!void {
            self.long_data_request = false;
            const id = self.long_data.id;
            const to_read = self.long_data.to_read;
            const offset = self.long_data.data_offset;
            const start = self.long_data.start_index;
            const rev_data = offset - start; //offset is always at least 3 nytes more than start
            if (rev_data >= to_read) {
                if (id >= self.Network_binds.len) {
                    //invalid bind, reset aux buffer, go back to IDLE
                    self.internal_aux_buffer_pos = 0;
                    self.machine_state = .IDLE;
                    return DriverError.INVALID_RESPONSE;
                }
                if (self.Network_binds[id]) |bd| {
                    if (bd.event_callback) |callback| {
                        const client = Client{
                            .id = @intCast(id),
                            .driver = self,
                            .event = .{ .ReadData = self.internal_aux_buffer[start..offset] },
                        };
                        callback(client, bd.user_data);
                    }
                }
                self.internal_aux_buffer_pos = 0;
                self.machine_state = .IDLE;
            } else {
                const remain = to_read - rev_data;
                const read = offset + remain;
                const rev = self.RX_fifo.read(self.internal_aux_buffer[offset..read]);
                const new_offset = offset + rev;
                self.long_data.data_offset = new_offset;
            }
        }

        //TODO; make a event pool just to init commands
        pub fn init_driver(self: *Self) !void {
            //clear buffers
            self.deinit_driver();
            self.RX_fifo.discard(self.RX_fifo.readableLength());
            self.TX_fifo.discard(self.TX_fifo.readableLength());

            //send dummy cmd to clear the module input
            var pkg: TXEventPkg = .{};
            var cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}", .{ get_cmd_string(.DUMMY), postfix }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;

            self.TX_fifo.writeItem(pkg) catch unreachable;

            //send RST request
            pkg.cmd_enum = .RESET;
            pkg.Extra_data = .{ .Reset = {} };
            self.TX_fifo.writeItem(pkg) catch unreachable;

            //desable ECHO
            cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}", .{ get_cmd_string(.ECHO_OFF), postfix }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .ECHO_OFF;
            pkg.Extra_data = .{ .Command = {} };
            self.TX_fifo.writeItem(pkg) catch unreachable;

            //disable sysstore
            cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}=0{s}", .{ prefix, get_cmd_string(.SYSSTORE), postfix }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .SYSSTORE;
            self.TX_fifo.writeItem(pkg) catch unreachable;

            //enable multi-conn
            cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}=1{s}", .{ prefix, get_cmd_string(Commands.IP_MUX), postfix }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .IP_MUX;
            self.TX_fifo.writeItem(pkg) catch unreachable;

            //disable wifi auto connection
            cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}=0{s}", .{ prefix, get_cmd_string(.WIFI_AUTOCONN), postfix }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .WIFI_AUTOCONN;
            self.TX_fifo.writeItem(pkg) catch unreachable;

            cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}=1{s}", .{ prefix, get_cmd_string(.NETWORK_RECV_MODE), postfix }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .NETWORK_RECV_MODE;
            self.TX_fifo.writeItem(pkg) catch unreachable;

            self.machine_state = Drive_states.IDLE;
        }

        //TODO: send reaming network pkgs with "SendDataFail" event for avoid memory leaks
        pub fn deinit_driver(self: *Self) void {
            for (0..self.Network_binds.len) |id_to_free| {
                self.release(id_to_free) catch break;
            }
            //TODO: Clear all WiFi data Here
            self.machine_state = .OFF;
        }

        //TODO: deinit all data here
        pub fn reset(self: *Self) DriverError!void {
            self.machine_state = .init;
        }

        pub fn set_response_event_handler(self: *Self, callback: response_event_type, user_data: ?*anyopaque) void {
            self.on_cmd_response = callback;
            self.Error_handler_user_data = user_data;
        }

        //TODO: add more config
        pub fn WiFi_connect_AP(self: *Self, config: WiFiSTAConfig) !void {
            if (self.Wifi_mode == .AP) {
                return DriverError.STA_OFF;
            } else if (self.Wifi_mode == WiFiDriverMode.NONE) {
                return DriverError.WIFI_OFF;
            }
            try WiFi.check_WiFi_STA_config(config);

            var pkg: TXEventPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}=", .{ prefix, get_cmd_string(.WIFI_CONNECT) }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .WIFI_CONNECT;
            pkg.Extra_data = .{ .WiFi = .{ .STA_conf_pkg = config } };
            self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
        }

        pub fn WiFi_config_AP(self: *Self, config: WiFiAPConfig) !void {
            if (self.Wifi_mode == .STA) {
                return DriverError.AP_OFF;
            } else if (self.Wifi_mode == .NONE) {
                return DriverError.WIFI_OFF;
            }
            try WiFi.check_WiFi_AP_config(config);

            var pkg: TXEventPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}=", .{ prefix, get_cmd_string(.WIFI_CONF) }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .WIFI_CONF;
            pkg.Extra_data = .{ .WiFi = .{ .AP_conf_pkg = config } };
            self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
        }

        pub fn set_WiFi_mode(self: *Self, mode: WiFiDriverMode) !void {
            var pkg: TXEventPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}={d}{s}", .{ prefix, get_cmd_string(.WIFI_SET_MODE), @intFromEnum(mode), postfix }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .WIFI_SET_MODE;
            self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
            self.Wifi_mode = mode;
        }

        pub fn WiFi_disconnect(self: *Self) DriverError!void {
            var pkg: TXEventPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}{s}", .{ prefix, get_cmd_string(.WIFI_DISCONNECT), postfix }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .WIFI_DISCONNECT;
            self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
        }

        pub fn set_WiFi_event_handler(self: *Self, callback: WIFI_event_type, user_data: ?*anyopaque) void {
            self.on_WiFi_event = callback;
            self.WiFi_user_data = user_data;
        }
        pub fn set_network_mode(self: *Self, mode: NetworkDriveMode) !void {
            self.div_binds = switch (mode) {
                .CLIENT_ONLY => 0,
                .SERVER_ONLY => 5,
                .SERVER_CLIENT => 3,
            };

            var pkg: TXEventPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}={d}{s}", .{ prefix, get_cmd_string(.NETWORK_SERVER_CONF), self.div_binds, postfix }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .NETWORK_SERVER_CONF;
            self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;

            self.network_mode = mode;
        }

        pub fn bind(self: *Self, event_callback: ClientCallback, user_data: ?*anyopaque) DriverError!usize {
            const start_bind = self.div_binds;

            for (start_bind..self.Network_binds.len) |index| {
                if (self.Network_binds[index]) |_| {
                    continue;
                } else {
                    const new_bind: network_handler = .{
                        .event_callback = event_callback,
                        .user_data = user_data,
                    };
                    self.Network_binds[index] = new_bind;
                    return index;
                }
            }
            return DriverError.MAX_BIND;
        }

        //TODO: add error checking for invalid closed erros
        pub fn close(self: *Self, id: usize) DriverError!void {
            var pkg: TXEventPkg = .{};
            if (id > self.Network_binds.len) return DriverError.INVALID_BIND;
            if (self.Network_binds[id]) |*bd| {
                const cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}={d}{s}", .{ prefix, get_cmd_string(.NETWORK_CLOSE), id, postfix }) catch unreachable;
                pkg.cmd_len = cmd_slice.len;
                pkg.cmd_enum = .NETWORK_CLOSE;
                pkg.Extra_data = .{
                    .Socket = .{ .descriptor_id = id, .pkg_type = .{
                        .NetworkClosePkg = {},
                    } },
                };
                self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
                bd.to_send += 1;
                return;
            }
            return DriverError.INVALID_BIND;
        }

        pub fn connect(self: *Self, id: usize, config: NetworkConnectPkg) DriverError!void {
            if (id > self.Network_binds.len or id < self.div_binds) return DriverError.INVALID_ARGS;
            if (config.remote_host.len > 64) return DriverError.INVALID_ARGS;
            switch (config.config) {
                .tcp => |args| {
                    if (args.keep_alive > 7200) return DriverError.INVALID_ARGS;
                },
                .ssl => |args| {
                    if (args.keep_alive > 7200) return DriverError.INVALID_ARGS;
                },
                .udp => |args| {
                    if (args.local_port) |port| {
                        if (port == 0) return DriverError.INVALID_ARGS;
                    }
                },
            }
            const pkg: TXEventPkg = .{ .cmd_enum = .NETWORK_CONNECT, .Extra_data = .{
                .Socket = .{
                    .descriptor_id = id,
                    .pkg_type = .{
                        .NetworkConnectPkg = config,
                    },
                },
            } };
            self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
        }

        pub fn create_server(self: *Self, port: u16, server_type: NetworkHandlerType, event_callback: ClientCallback, user_data: ?*anyopaque) DriverError!void {
            const end_bind = self.div_binds;
            if (self.network_mode == NetworkDriveMode.CLIENT_ONLY) return DriverError.SERVER_OFF;
            var pkg: TXEventPkg = .{ .cmd_enum = .NETWORK_SERVER };

            var cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}=1,{d}", .{ prefix, get_cmd_string(.NETWORK_SERVER), port }) catch unreachable;
            var slice_len = cmd_slice.len;
            switch (server_type) {
                .Default => {
                    cmd_slice = std.fmt.bufPrint(pkg.cmd_data[slice_len..], "{s}", .{postfix}) catch unreachable;
                    slice_len += cmd_slice.len;
                },

                .SSL => {
                    cmd_slice = std.fmt.bufPrint(pkg.cmd_data[slice_len..], ",\"SSL\"{s}", .{postfix}) catch unreachable;
                    slice_len += cmd_slice.len;
                },

                .TCP => {
                    cmd_slice = std.fmt.bufPrint(pkg.cmd_data[slice_len..], ",\"TCP\"{s}", .{postfix}) catch unreachable;
                    slice_len += cmd_slice.len;
                },

                else => return DriverError.INVALID_ARGS,
            }
            pkg.cmd_len = slice_len;
            self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
            for (0..end_bind) |id| {
                try self.release(id);
                self.Network_binds[id] = network_handler{
                    .event_callback = event_callback,
                    .user_data = user_data,
                };
            }
        }

        pub fn release(self: *Self, id: usize) DriverError!void {
            if (id > self.Network_binds.len) return DriverError.INVALID_BIND;

            //clear all Sockect Pkg
            if (self.Network_binds[id]) |*bd| {
                var client = Client{
                    .driver = self,
                    .id = 255,
                    .event = .{ .Closed = {} },
                };
                const TX_size = self.TX_fifo.readableLength();
                for (0..TX_size) |_| {
                    const data = self.TX_fifo.readItem().?;
                    switch (data.Extra_data) {
                        .Socket => |net_data| {
                            if (id == net_data.descriptor_id) {
                                switch (net_data.pkg_type) {
                                    .NetworkSendPkg => |to_clear| {
                                        client.id = id;
                                        client.event = .{ .SendDataComplete = to_clear.data };
                                        if (bd.event_callback) |callback| {
                                            callback(client, bd.user_data);
                                        }
                                    },
                                    else => {},
                                }
                                continue;
                            }
                        },
                        else => {},
                    }
                    self.TX_fifo.writeItem(data) catch return;
                }
            }
            self.Network_binds[id] = null;
        }

        pub fn delete_server(self: *Self) DriverError!void {
            for (0..self.div_binds) |bind_id| {
                self.release(bind_id);
            }

            //send server close server command
            var pkg: TXEventPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}=0,1{s}", .{ prefix, get_cmd_string(Commands.NETWORK_SERVER), postfix }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .NETWORK_SERVER;
            self.TX_fifo.writeItem(pkg) catch DriverError.TX_BUFFER_FULL;
        }

        pub fn accept(self: *Self, id: usize) DriverError!void {
            if (id >= self.Network_binds.len) return DriverError.INVALID_ARGS;
            const recv_buffer_size = self.internal_aux_buffer.len;
            var pkg: TXEventPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}={d},{d}{s}", .{
                prefix,
                get_cmd_string(Commands.NETWORK_RECV),
                id,
                recv_buffer_size,
                postfix,
            }) catch unreachable;
            pkg.cmd_len = cmd_slice.len;
            pkg.cmd_enum = .NETWORK_RECV;
            self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
            self.long_data.id = id;
        }

        pub fn send(self: *Self, id: usize, data: []const u8) DriverError!void {
            if (id >= self.Network_binds.len) return DriverError.INVALID_ARGS;
            if (data.len > 2048) return DriverError.INVALID_ARGS;
            const free_TX_cmd = self.TX_fifo.writableLength();
            if (free_TX_cmd < 2) return DriverError.BUSY; //keep some space to other commands

            if (self.Network_binds[id]) |*bd| {
                var pkg: TXEventPkg = .{};
                const cmd_slice = std.fmt.bufPrint(&pkg.cmd_data, "{s}{s}={d},{d}{s}", .{ prefix, get_cmd_string(.NETWORK_SEND), id, data.len, postfix }) catch unreachable;
                pkg.cmd_len = cmd_slice.len;
                pkg.cmd_enum = .NETWORK_SEND;
                pkg.Extra_data = .{ .Socket = .{ .descriptor_id = id, .pkg_type = .{
                    .NetworkSendPkg = .{ .data = data },
                } } };
                self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
                bd.to_send += 1;
                return;
            }
            return DriverError.INVALID_BIND;
        }

        //TODO: add more config param
        pub fn init(txcallback: TX_callback, rxcallback: RX_callback, user_data: ?*anyopaque) Self {
            //const ATdrive = create_drive(buffer_size);
            return .{
                .RX_callback_handler = rxcallback,
                .TX_callback_handler = txcallback,
                .TX_RX_user_data = user_data,
                .RX_fifo = fifo.LinearFifo(u8, .{ .Static = RX_SIZE }).init(),
                .TX_fifo = fifo.LinearFifo(TXEventPkg, .{ .Static = TX_event_pool }).init(),
            };
        }
    };
}

fn get_cmd_slice(buffer: []const u8, start_tokens: []const u8, end_tokens: []const u8) []const u8 {
    var start: usize = 0;
    for (0..buffer.len) |index| {
        for (start_tokens) |token| {
            if (token == buffer[index]) {
                start = index;
                continue;
            }
        }

        for (end_tokens) |token| {
            if (token == buffer[index]) {
                return buffer[start..index];
            }
        }
    }
    return buffer[start..];
}
