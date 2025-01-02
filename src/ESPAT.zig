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
pub const WiFiAPConfig = WiFi.WiFiAPConfig;
pub const WiFiSTAConfig = WiFi.WiFiSTAConfig;
pub const WifiEvent = WiFi.WifiEvent;
pub const WiFiEncryption = WiFi.WiFiEncryption;

const Network = @import("util/network.zig");
pub const NetworkPackageType = Network.NetworkPackageType;
pub const NetworkEvent = Network.NetworkEvent;
pub const NetworkHandlerState = Network.NetworkHandlerState;
pub const ConnectConfig = Network.ConnectConfig;
pub const ServerConfig = Network.ServerConfig;
pub const NetworkTCPConn = Network.NetworkTCPConn;
pub const NetworkUDPConn = Network.NetworkUDPConn;
pub const NetworkHandlerType = Network.NetworkHandlerType;
pub const NetworkHandler = Network.NetworkHandler;
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
    Socket: bool = false,
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

const NetworkToRead = struct {
    id: usize,
    to_read: usize,
    data_offset: usize,
    start_index: usize,
};

const NetworkToSend = struct {
    id: usize = std.math.maxInt(usize),
    data: []const u8 = undefined,
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
            .{ "+LINK_CONN", Self.network_conn_event },
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
        RX_fifo: fifo.LinearFifo(u8, .{ .Static = driver_config.RX_size }),
        TX_fifo: fifo.LinearFifo(TXEventPkg, .{ .Static = driver_config.TX_event_pool }),
        TX_wait_response: ?Commands = null,
        TX_callback_handler: TX_callback,
        RX_callback_handler: RX_callback,
        busy_flag: BusyBitFlags = .{},
        internal_aux_buffer: [driver_config.network_recv_size]u8 = undefined,
        internal_aux_buffer_pos: usize = 0,
        last_error_code: CommandErrorCodes = .ESP_AT_UNKNOWN_ERROR,

        //Long data needs to be handled in a special state
        //to avoid locks on the executor while reading this data
        //only for command data responses (+<cmd>:data) with unknow response len
        long_data_request: bool = false,
        long_data: NetworkToRead = undefined, //TODO: change this to support BLE

        machine_state: Drive_states = .init,
        Wifi_state: WiFistate = .OFF,
        Wifi_mode: WiFiDriverMode = .NONE,
        WiFi_dhcp: WiFi.DHCPEnable = .{},
        network_mode: NetworkDriveMode = .CLIENT_ONLY,
        div_binds: usize = 0,

        //network data
        Network_binds: [driver_config.network_binds]?NetworkHandler = undefined,
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
                    callback(.{ .Ok = {} }, resp, self.Error_handler_user_data);
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
                        if (self.Network_binds[pkg.id]) |*bd| {
                            bd.client.event = .{ .SendDataCancel = pkg.data };
                            bd.notify();
                        }

                        self.busy_flag.Socket = false;
                    },
                    else => {},
                }
                if (self.on_cmd_response) |callback| {
                    callback(.{ .Error = self.last_error_code }, resp, self.Error_handler_user_data);
                }
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

        fn wifi_response(self: *Self, aux_buffer: []const u8) DriverError!void {
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
                self.TX_fifo.writeItem(TXEventPkg{
                    .cmd_enum = .WIFI_STA_IP,
                    .Extra_data = .{ .Command = pkg },
                }) catch return DriverError.TX_BUFFER_FULL;
            }
            if (self.on_WiFi_event) |callback| {
                callback(event, self.WiFi_user_data);
            }
        }

        fn driver_ready(self: *Self, _: []const u8) DriverError!void {
            self.busy_flag.Reset = false;
        }

        fn WiFi_get_AP_info(self: *Self, aux_buffer: []const u8) DriverError!void {
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

        fn WiFi_error(self: *Self, aux_buffer: []const u8) DriverError!void {
            self.busy_flag.WiFi = false;
            if (aux_buffer.len < 8) return DriverError.INVALID_RESPONSE;
            const error_id = WiFi.get_error_event(aux_buffer);
            const event = WifiEvent{ .ERROR = error_id };
            if (self.on_WiFi_event) |callback| {
                callback(event, self.WiFi_user_data);
            }
        }

        fn WiFi_get_device_conn_mac(self: *Self, aux_buffer: []const u8) DriverError!void {
            if (aux_buffer.len < 34) return DriverError.INVALID_ARGS;
            const mac = aux_buffer[16..33];
            const event = WifiEvent{ .STA_CONNECTED = mac };
            if (self.on_WiFi_event) |callback| {
                callback(event, self.WiFi_user_data);
            }
        }
        fn WiFi_get_device_ip(self: *Self, aux_buffer: []const u8) DriverError!void {
            if (aux_buffer.len < 46) return DriverError.INVALID_RESPONSE;
            const mac = get_cmd_slice(aux_buffer[14..], &[_]u8{}, &[_]u8{'"'});
            const ip = get_cmd_slice(aux_buffer[34..], &[_]u8{}, &[_]u8{'"'});
            const event = WifiEvent{ .STA_GOT_IP = .{ .ip = ip, .mac = mac } };
            if (self.on_WiFi_event) |callback| {
                callback(event, self.WiFi_user_data);
            }
        }

        fn WiFi_get_device_disc_mac(self: *Self, aux_buffer: []const u8) DriverError!void {
            if (aux_buffer.len < 37) return DriverError.INVALID_ARGS;
            const mac = aux_buffer[19..36];
            const event = WifiEvent{ .STA_DISCONNECTED = mac };
            if (self.on_WiFi_event) |callback| {
                callback(event, self.WiFi_user_data);
            }
        }

        fn parse_network_data(self: *Self, aux_buffer: []const u8) DriverError!void {
            const data = Network.paser_ip_data(aux_buffer) catch return DriverError.INVALID_RESPONSE;
            if (data.id > self.Network_binds.len) return DriverError.INVALID_RESPONSE;
            const id = data.id;
            const data_size = data.data_len;

            if (data.data_info) |info| {
                if (self.Network_binds[id]) |*bd| {
                    bd.client.remote_host = info.remote_host;
                    bd.client.remote_port = info.remote_port;
                }

                self.long_data_request = true;
                self.long_data.id = id;
                self.long_data.to_read = data_size;
                self.long_data.start_index = info.start_index;
                self.long_data.data_offset = self.internal_aux_buffer_pos;
                return;
            }

            if (self.Network_binds[id]) |*bd| {
                bd.client.event = .{ .DataReport = data_size };
                bd.notify();
            }
        }

        fn network_read_data(self: *Self, aux_buffer: []const u8) DriverError!void {
            if (aux_buffer.len < 14) return DriverError.INVALID_RESPONSE;
            const recv = Network.parse_recv_data(aux_buffer) catch return DriverError.INVALID_RESPONSE;
            self.long_data_request = true;
            self.long_data.to_read = recv.data_len;
            self.long_data.start_index = recv.data_info.?.start_index;
            self.long_data.data_offset = self.internal_aux_buffer_pos;

            if (self.Network_binds[self.long_data.id]) |*bd| {
                bd.client.remote_host = recv.data_info.?.remote_host;
                bd.client.remote_port = recv.data_info.?.remote_port;
            }
        }

        fn network_conn_event(self: *Self, aux_buffer: []const u8) DriverError!void {
            const data = Network.parser_conn_data(aux_buffer) catch return DriverError.INVALID_RESPONSE;
            const id = data.id;
            if (id > self.Network_binds.len) return DriverError.INVALID_RESPONSE;

            if (self.Network_binds[id]) |*bd| {
                bd.client.remote_host = data.remote_host;
                bd.client.remote_port = data.remote_port;
                bd.state = .Connected;
                bd.client.event = .{ .Connected = {} };
                bd.notify();
                bd.client.remote_host = null;
                bd.client.remote_port = null;
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
                                            bd.client.event = .{ .SendDataCancel = to_clear.data };
                                            bd.notify();
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
                bd.client.event = .{ .Closed = {} };
                bd.notify();
            }
        }

        fn network_send_event(self: *Self, aux_buffer: []const u8) DriverError!void {
            self.busy_flag.Socket = false;
            const send_event_slice = get_cmd_slice(aux_buffer[5..], &[_]u8{}, &[_]u8{'\r'});
            const send_event = Network.get_send_event(send_event_slice) catch return DriverError.INVALID_RESPONSE;
            const event: NetworkEvent = switch (send_event) {
                .ok => NetworkEvent{ .SendDataOk = {} },
                .fail => NetworkEvent{ .SendDataFail = {} },
            };
            const corrent_id = self.Network_corrent_pkg.id;
            if (self.Network_binds[corrent_id]) |*bd| {
                bd.client.event = event;
                bd.notify();
            }
        }

        fn network_send_data(self: *Self) DriverError!void {
            const pkg = self.Network_corrent_pkg;
            //if pkg is invalid, close the send request"
            if (pkg.id < self.Network_binds.len) {
                if (self.Network_binds[pkg.id]) |*bd| {
                    if (bd.to_send > 0) {
                        self.TX_callback_handler(pkg.data, self.TX_RX_user_data);
                        bd.to_send -= 1;
                        bd.client.event = .{ .SendDataComplete = pkg.data };
                        bd.notify();
                    }
                }
                return;
            }
            //send stop code on invalid pkgs (yes stop code is \\0 not \0)
            self.TX_callback_handler("\\0", self.TX_RX_user_data);
        }

        fn apply_WiFi_mac(self: *Self, cmd_data: Commands, mac: []const u8) void {
            const config = WiFi.set_mac(&self.internal_aux_buffer, cmd_data, mac) catch unreachable;
            self.TX_callback_handler(config, self.TX_RX_user_data);
        }

        fn apply_static_ip(self: *Self, cmd_data: Commands, ip: WiFi.StaticIp) void {
            const config = WiFi.set_static_ip(&self.internal_aux_buffer, cmd_data, ip) catch unreachable;
            self.TX_callback_handler(config, self.TX_RX_user_data);
        }

        fn WiFi_apply_AP_config(self: *Self, config: WiFi.APpkg) void {
            const config_str = WiFi.set_AP_config(&self.internal_aux_buffer, config) catch unreachable;
            self.TX_callback_handler(config_str, self.TX_RX_user_data);
        }

        fn WiFi_apply_STA_config(self: *Self, config: WiFi.STApkg) void {
            const config_str = WiFi.set_STA_config(&self.internal_aux_buffer, config) catch unreachable;
            self.TX_callback_handler(config_str, self.TX_RX_user_data);
        }

        fn apply_send(self: *Self, id: usize, data_len: usize) void {
            const cmd = std.fmt.bufPrint(&self.internal_aux_buffer, "{s}{s}={d},{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_SEND),
                id,
                data_len,
                postfix,
            }) catch unreachable;
            self.TX_callback_handler(cmd, self.TX_RX_user_data);
        }

        fn apply_tcp_config(self: *Self, id: usize, args: ConnectConfig, tcp_conf: NetworkTCPConn) void {
            const config = Network.set_tcp_config(&self.internal_aux_buffer, id, args, tcp_conf) catch unreachable;
            self.TX_callback_handler(config, self.TX_RX_user_data);
        }
        fn apply_udp_config(self: *Self, id: usize, args: ConnectConfig, udp_conf: NetworkUDPConn) void {
            const config = Network.set_udp_config(&self.internal_aux_buffer, id, args, udp_conf) catch unreachable;
            self.TX_callback_handler(config, self.TX_RX_user_data);
        }

        fn apply_udp_send(self: *Self, id: usize, data: Network.NetworkSendToPkg) void {
            const cmd = std.fmt.bufPrint(&self.internal_aux_buffer, "{s}{s}={d},{d},\"{s}\",{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_SEND),
                id,
                data.data.len,
                data.remote_host,
                data.remote_port,
                postfix,
            }) catch unreachable;

            self.TX_callback_handler(cmd, self.TX_RX_user_data);
        }

        fn apply_accept(self: *Self, id: usize, len: usize) void {
            const cmd = std.fmt.bufPrint(&self.internal_aux_buffer, "{s}{s}={d},{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_RECV),
                id,
                len,
                postfix,
            }) catch unreachable;

            self.TX_callback_handler(cmd, self.TX_RX_user_data);
        }

        fn apply_close(self: *Self, id: usize) void {
            const cmd = std.fmt.bufPrint(&self.internal_aux_buffer, "{s}{s}={d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_CLOSE),
                id,
                postfix,
            }) catch unreachable;

            self.TX_callback_handler(cmd, self.TX_RX_user_data);
        }

        fn handler_WiFi_TX(self: *Self, cmd_data: Commands, data: WiFiPackage) void {
            switch (data) {
                .AP_conf_pkg => |pkg| {
                    self.WiFi_apply_AP_config(pkg);
                    self.busy_flag.Command = true;
                },
                .STA_conf_pkg => |pkg| {
                    self.WiFi_apply_STA_config(pkg);
                    self.busy_flag.WiFi = true;
                },
                .MAC_config => |pkg| {
                    self.apply_WiFi_mac(cmd_data, pkg);
                    self.busy_flag.Command = true;
                },
                .static_ap_config => |pkg| {
                    self.apply_static_ip(cmd_data, pkg);
                    self.busy_flag.Command = true;
                },
                else => {},
            }
        }

        fn handler_socket_TX(self: *Self, data: NetworkPackage) void {
            const id = data.descriptor_id;
            switch (data.pkg_type) {
                .NetworkSendPkg => |to_send| {
                    self.apply_send(id, to_send.data.len);
                    self.Network_corrent_pkg = NetworkToSend{
                        .data = to_send.data,
                        .id = id,
                    };
                    self.busy_flag.Socket = true;
                },
                .NetworkSendToPkg => |to_send| {
                    self.apply_udp_send(id, to_send);
                    self.Network_corrent_pkg = NetworkToSend{
                        .data = to_send.data,
                        .id = id,
                    };
                    self.busy_flag.Socket = true;
                },
                .NetworkAcceptPkg => |size| {
                    self.long_data.id = id;
                    self.apply_accept(id, size);
                    self.busy_flag.Command = true;
                },
                .NetworkClosePkg => {
                    self.apply_close(id);
                    self.busy_flag.Command = true;
                    if (self.Network_binds[id]) |*bd| {
                        bd.to_send -= 1;
                    }
                },
                .ConnectConfig => |connpkg| {
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
                            if (self.internal_aux_buffer[0] == '+') {
                                self.get_cmd_data_type(self.internal_aux_buffer[0..self.internal_aux_buffer_pos]) catch |err| {
                                    self.internal_aux_buffer_pos = 0;
                                    return err;
                                };
                            } else {
                                self.get_cmd_type(self.internal_aux_buffer[0..self.internal_aux_buffer_pos]) catch |err| {
                                    self.internal_aux_buffer_pos = 0;
                                    return err;
                                };
                            }
                        }
                        self.internal_aux_buffer_pos = 0;
                    } else if ((data == '>') and (self.internal_aux_buffer_pos == 1)) {
                        self.internal_aux_buffer_pos = 0;
                        try self.network_send_data();
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
                        self.busy_flag.Command = true;
                    },
                    .Socket => |data| {
                        self.handler_socket_TX(data);
                    },
                    .WiFi => |data| {
                        self.handler_WiFi_TX(cmd.cmd_enum, data);
                    },
                    .Bluetooth => {
                        //TODO
                    },
                }
            }
        }

        fn READ_LONG(self: *Self) void {
            const id = self.long_data.id;
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
                        if (self.Network_binds[id]) |*bd| {
                            bd.client.event = .{ .ReadData = self.internal_aux_buffer[start..] }; //not include the command response \r\n
                            bd.notify();
                        }
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
            if (self.Network_binds[id]) |*bd| {
                const temp = self.internal_aux_buffer[start..offset];
                bd.client.event = .{ .ReadData = temp[0..to_read] }; //not include the command response \r\n
                bd.notify();
                bd.client.remote_host = null;
                bd.client.remote_port = null;
            }
            self.long_data_request = false;
        }

        //TODO; make a event pool just to init commands
        pub fn init_driver(self: *Self) !void {

            //clear buffers
            self.deinit_driver();
            self.RX_fifo.discard(self.RX_fifo.readableLength());
            self.TX_fifo.discard(self.TX_fifo.readableLength());

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
            for (0..self.Network_binds.len) |id_to_free| {
                self.release(id_to_free) catch break;
            }
            //TODO: Clear all WiFi data Here
            self.machine_state = .OFF;
        }

        pub fn set_response_event_handler(self: *Self, callback: response_event_type, user_data: ?*anyopaque) void {
            self.on_cmd_response = callback;
            self.Error_handler_user_data = user_data;
        }

        pub fn WiFi_connect_AP(self: *Self, config: WiFiSTAConfig) !void {
            if (self.Wifi_mode == .AP) {
                return DriverError.STA_OFF;
            } else if (self.Wifi_mode == WiFiDriverMode.NONE) {
                return DriverError.WIFI_OFF;
            }
            const free_tx = self.get_tx_free_space();
            if (free_tx < WiFi.calc_STA_pkgs(config)) return DriverError.TX_BUFFER_FULL;
            try WiFi.check_STA_config(config);

            var pkg: CommandPkg = .{};

            if (config.wifi_protocol) |proto| {
                const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{
                    prefix,
                    get_cmd_string(.WIFI_STA_PROTO),
                    @as(u4, @bitCast(proto)),
                    postfix,
                }) catch unreachable;
                pkg.len = cmd_slice.len;
                self.TX_fifo.writeItem(TXEventPkg{
                    .cmd_enum = .WIFI_STA_PROTO,
                    .Extra_data = .{ .Command = pkg },
                }) catch unreachable;
            }

            if (config.mac) |mac| {
                self.TX_fifo.writeItem(TXEventPkg{
                    .cmd_enum = .WIFI_STA_MAC,
                    .Extra_data = .{
                        .WiFi = .{ .MAC_config = mac },
                    },
                }) catch unreachable;
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
                        self.TX_fifo.writeItem(TXEventPkg{
                            .cmd_enum = .WiFi_SET_DHCP,
                            .Extra_data = .{ .Command = pkg },
                        }) catch unreachable;
                    },
                    .static => |static_ip| {
                        self.WiFi_dhcp.STA = 0;
                        self.TX_fifo.writeItem(TXEventPkg{
                            .cmd_enum = .WIFI_STA_IP,
                            .Extra_data = .{
                                .WiFi = .{
                                    .static_ap_config = static_ip,
                                },
                            },
                        }) catch unreachable;
                    },
                }
            }

            self.TX_fifo.writeItem(TXEventPkg{ .cmd_enum = .WIFI_CONNECT, .Extra_data = .{
                .WiFi = .{
                    .STA_conf_pkg = WiFi.STApkg.from_config(config),
                },
            } }) catch unreachable;
        }

        pub fn WiFi_config_AP(self: *Self, config: WiFiAPConfig) !void {
            if (self.Wifi_mode == .STA) {
                return DriverError.AP_OFF;
            } else if (self.Wifi_mode == .NONE) {
                return DriverError.WIFI_OFF;
            }
            const free_tx = self.get_tx_free_space();
            if (free_tx < WiFi.calc_AP_pkgs(config)) return DriverError.TX_BUFFER_FULL;
            try WiFi.check_AP_config(config);

            var pkg: CommandPkg = .{};

            if (config.wifi_protocol) |proto| {
                const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{
                    prefix,
                    get_cmd_string(.WIFI_AP_PROTO),
                    @as(u4, @bitCast(proto)),
                    postfix,
                }) catch unreachable;
                pkg.len = cmd_slice.len;
                self.TX_fifo.writeItem(TXEventPkg{
                    .cmd_enum = .WIFI_AP_PROTO,
                    .Extra_data = .{ .Command = pkg },
                }) catch unreachable;
            }

            if (config.mac) |mac| {
                self.TX_fifo.writeItem(TXEventPkg{
                    .cmd_enum = .WIFI_AP_MAC,
                    .Extra_data = .{
                        .WiFi = .{
                            .MAC_config = mac,
                        },
                    },
                }) catch unreachable;
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
                        self.TX_fifo.writeItem(TXEventPkg{
                            .cmd_enum = .WiFi_SET_DHCP,
                            .Extra_data = .{ .Command = pkg },
                        }) catch unreachable;
                    },
                    .static => |static_ip| {
                        self.WiFi_dhcp.AP = 0;
                        const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=", .{
                            prefix,
                            get_cmd_string(.WIFI_AP_IP),
                        }) catch unreachable;
                        pkg.len = cmd_slice.len;
                        self.TX_fifo.writeItem(TXEventPkg{
                            .cmd_enum = .WIFI_AP_IP,
                            .Extra_data = .{
                                .WiFi = .{
                                    .static_ap_config = static_ip,
                                },
                            },
                        }) catch unreachable;
                    },
                }
            }

            self.TX_fifo.writeItem(TXEventPkg{ .cmd_enum = .WIFI_CONF, .Extra_data = .{
                .WiFi = .{
                    .AP_conf_pkg = WiFi.APpkg.from_config(config),
                },
            } }) catch unreachable;
        }

        pub fn set_WiFi_mode(self: *Self, mode: WiFiDriverMode) !void {
            var pkg: CommandPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{ prefix, get_cmd_string(.WIFI_SET_MODE), @intFromEnum(mode), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .WIFI_SET_MODE,
                .Extra_data = .{ .Command = pkg },
            }) catch return DriverError.TX_BUFFER_FULL;
            self.Wifi_mode = mode;
        }

        pub fn WiFi_disconnect(self: *Self) DriverError!void {
            var pkg: CommandPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}{s}", .{
                prefix,
                get_cmd_string(.WIFI_DISCONNECT),
                postfix,
            }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .WIFI_DISCONNECT,
                .Extra_data = .{ .Command = pkg },
            }) catch return DriverError.TX_BUFFER_FULL;
        }

        pub fn WiFi_disconnect_device(self: *Self, mac: []const u8) DriverError!void {
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .WIFI_DISCONNECT_DEVICE,
                .Extra_data = .{
                    .WiFi = .{
                        .MAC_config = mac,
                    },
                },
            }) catch return DriverError.TX_BUFFER_FULL;
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

            var pkg: CommandPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{ prefix, get_cmd_string(.NETWORK_SERVER_CONF), self.div_binds, postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .NETWORK_SERVER_CONF,
                .Extra_data = .{ .Command = pkg },
            }) catch return DriverError.TX_BUFFER_FULL;

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
            if (id > self.Network_binds.len) return DriverError.INVALID_BIND;
            if (self.Network_binds[id]) |*bd| {
                self.TX_fifo.writeItem(TXEventPkg{
                    .cmd_enum = .NETWORK_CLOSE,
                    .Extra_data = .{
                        .Socket = .{
                            .descriptor_id = id,
                            .pkg_type = .{
                                .NetworkClosePkg = {},
                            },
                        },
                    },
                }) catch return DriverError.TX_BUFFER_FULL;
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
            if (self.get_tx_free_space() < 2) return DriverError.TX_BUFFER_FULL; //one CMD for set mode and one to connect to the host
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
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .NETWORK_RECV_MODE,
                .Extra_data = .{ .Command = recv_mode },
            }) catch unreachable;

            //send connect request
            const pkg = TXEventPkg{ .cmd_enum = .NETWORK_CONNECT, .Extra_data = .{
                .Socket = .{
                    .descriptor_id = id,
                    .pkg_type = .{
                        .ConnectConfig = config,
                    },
                },
            } };
            self.TX_fifo.writeItem(pkg) catch unreachable;
        }
        pub fn accept(self: *Self, id: usize) DriverError!void {
            if (id >= self.Network_binds.len) return DriverError.INVALID_ARGS;
            const recv_buffer_size = driver_config.network_recv_size - 50; //50bytes  of pre-data
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .NETWORK_RECV,
                .Extra_data = .{
                    .Socket = .{
                        .descriptor_id = id,
                        .pkg_type = .{
                            .NetworkAcceptPkg = recv_buffer_size,
                        },
                    },
                },
            }) catch return DriverError.TX_BUFFER_FULL;
        }

        fn accpet_fn(ctx: *anyopaque, id: usize) Network.ClientError!void {
            const driver: *Self = @alignCast(@ptrCast(ctx));
            driver.accept(id) catch return error.InternalError;
        }

        pub fn send(self: *Self, id: usize, data: []const u8) DriverError!void {
            if (id >= self.Network_binds.len) return DriverError.INVALID_ARGS;
            if (data.len > 2048) return DriverError.INVALID_ARGS;
            const free_TX_cmd = self.TX_fifo.writableLength();
            if (free_TX_cmd < 2) return DriverError.BUSY; //keep some space to other commands

            if (self.Network_binds[id]) |*bd| {
                self.TX_fifo.writeItem(TXEventPkg{
                    .cmd_enum = .NETWORK_SEND,
                    .Extra_data = .{
                        .Socket = .{
                            .descriptor_id = id,
                            .pkg_type = .{
                                .NetworkSendPkg = .{ .data = data },
                            },
                        },
                    },
                }) catch return DriverError.TX_BUFFER_FULL;
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
            if (id >= self.Network_binds.len) return DriverError.INVALID_ARGS;
            if (data.len > 2048) return DriverError.INVALID_ARGS;
            const free_TX_cmd = self.TX_fifo.writableLength();
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
                                .NetworkSendToPkg = .{
                                    .data = data,
                                    .remote_host = remote_host,
                                    .remote_port = remote_port,
                                },
                            },
                        },
                    },
                };
                self.TX_fifo.writeItem(pkg) catch return DriverError.TX_BUFFER_FULL;
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
            if (self.network_mode == NetworkDriveMode.CLIENT_ONLY) return DriverError.SERVER_OFF;

            const end_bind = self.div_binds;
            var cmd_slice: []const u8 = undefined;

            var pkg: CommandPkg = .{};

            if (self.network_mode == .SERVER_ONLY) {
                if (self.get_tx_free_space() < 3) return DriverError.TX_BUFFER_FULL;
                cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=5,{d}{s}", .{
                    prefix,
                    get_cmd_string(.NETWORK_RECV_MODE),
                    @intFromEnum(config.recv_mode),
                    postfix,
                }) catch unreachable;

                pkg.len = cmd_slice.len;
                self.TX_fifo.writeItem(TXEventPkg{
                    .cmd_enum = .NETWORK_RECV_MODE,
                    .Extra_data = .{ .Command = pkg },
                }) catch unreachable;
            } else {
                if (self.get_tx_free_space() < (end_bind + 2)) return DriverError.TX_BUFFER_FULL;
                for (0..end_bind) |id| {
                    cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d},{d}{s}", .{
                        prefix,
                        get_cmd_string(.NETWORK_RECV_MODE),
                        id,
                        @intFromEnum(config.recv_mode),
                        postfix,
                    }) catch unreachable;

                    pkg.len = cmd_slice.len;
                    self.TX_fifo.writeItem(TXEventPkg{
                        .cmd_enum = .NETWORK_RECV_MODE,
                        .Extra_data = .{ .Command = pkg },
                    }) catch unreachable;
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
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .NETWORK_SERVER,
                .Extra_data = .{ .Command = pkg },
            }) catch return DriverError.TX_BUFFER_FULL;

            if (config.timeout) |timeout| {
                const time = @min(7200, timeout);
                cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{
                    prefix,
                    get_cmd_string(.NETWORK_SERVER_TIMEOUT),
                    time,
                    postfix,
                }) catch unreachable;
                pkg.len = cmd_slice.len;
                self.TX_fifo.writeItem(TXEventPkg{
                    .cmd_enum = .NETWORK_SERVER_TIMEOUT,
                    .Extra_data = .{ .Command = pkg },
                }) catch unreachable;
            }

            for (0..end_bind) |id| {
                try self.release(id);
                self.Network_binds[id] = Network.NetworkHandler{
                    .event_callback = config.callback,
                    .user_data = config.user_data,
                    .client = self.create_client(id),
                };
            }
        }

        pub fn release(self: *Self, id: usize) DriverError!void {
            if (id > self.Network_binds.len) return DriverError.INVALID_BIND;

            //clear all Sockect Pkg
            if (self.Network_binds[id]) |*bd| {
                const TX_size = self.TX_fifo.readableLength();
                for (0..TX_size) |_| {
                    const data = self.TX_fifo.readItem().?;
                    switch (data.Extra_data) {
                        .Socket => |net_data| {
                            if (id == net_data.descriptor_id) {
                                switch (net_data.pkg_type) {
                                    .NetworkSendPkg => |to_clear| {
                                        bd.client.event = .{ .SendDataCancel = to_clear.data };
                                        bd.notify();
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
            var pkg: CommandPkg = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=0,1{s}", .{ prefix, get_cmd_string(Commands.NETWORK_SERVER), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.TX_fifo.writeItem(TXEventPkg{
                .cmd_enum = .NETWORK_SERVER,
                .Extra_data = .{ .Command = pkg },
            }) catch DriverError.TX_BUFFER_FULL;
        }

        //TODO: add more config param
        pub fn init(txcallback: TX_callback, rxcallback: RX_callback, user_data: ?*anyopaque) Self {
            //const ATdrive = create_drive(buffer_size);
            var driver = Self{
                .RX_callback_handler = rxcallback,
                .TX_callback_handler = txcallback,
                .TX_RX_user_data = user_data,
                .RX_fifo = fifo.LinearFifo(u8, .{ .Static = driver_config.RX_size }).init(),
                .TX_fifo = fifo.LinearFifo(TXEventPkg, .{ .Static = driver_config.TX_event_pool }).init(),
            };
            for (0..driver_config.network_binds) |index| {
                driver.Network_binds[index] = null;
            }
            return driver;
        }
    };
}
