//TODO: remove "process" completely from the microZig implementation when "Framework driver" is added, Use notification instead of pull [maybe]

const std = @import("std");
pub const Circular_buffer = @import("util/circular_buffer.zig");

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

pub const WiFi_encryption = enum {
    OPEN,
    WPA_PSK,
    WPA2_PSK,
    WPA_WPA2_PSK,
};

pub const commands_enum = enum(u8) {
    DUMMY,
    RESET,
    ECHO_OFF,
    ECHO_ON,
    IP_MUX,
    WIFI_SET_MODE,
    WIFI_CONNECT,
    WIFI_CONF,
    WIFI_AUTOCONN,
    NETWORK_CONNECT,
    NETWORK_SEND,
    NETWORK_CLOSE,
    NETWORK_IP,
    NETWORK_SERVER_CONF,
    NETWORK_SERVER,
    //Extra

};

//This is not necessary since the user cannot send commands directly
pub const COMMANDS_TOKENS = [_][]const u8{
    ".",
    "RST",
    "ATE0",
    "ATE1",
    "CIPMUX",
    "CWMODE",
    "CWJAP",
    "CWSAP",
    "CWAUTOCONN",
    "CIPSTART",
    "CIPSEND",
    "CIPCLOSE",
    "CIPSTA",
    "CIPSERVERMAXCONN",
    "CIPSERVER",
};

const prefix = "AT+";
const infix = "_CUR";
const postfix = "\r\n";

pub const COMMANDS_RESPOSES_TOKENS = [_][]const u8{
    "OK",
    "ERROR",
    "WIFI",
    ",CONNECT",
    ",CLOSED",
    "SEND",
    "ready",
};

pub const COMMAND_DATA_TYPES = [_][]const u8{
    "+IPD",
    "+CIPSTA",
    "+CWJAP",
    "+STA_CONNECTED",
    "+DIST_STA_IP",
    "+STA_DISCONNECTED",
};

pub const CommandResults = enum(u8) { Ok, Error };

pub const WIFI_RESPOSE_TOKEN = [_][]const u8{
    "DISCONNECT",
    "CONNECTED",
    "GOT IP",
};

pub const SEND_RESPONSE_TOKEN = [_][]const u8{
    "OK",
    "FAIL",
};

pub const WifiEvent = enum(u8) {
    //Events received from the access point (when in station mode)
    WiFi_AP_CON_START,
    WiFi_AP_CONNECTED,
    WiFi_AP_GOT_MASK,
    WiFi_AP_GOT_IP,
    WiFi_AP_GOT_GATEWAY,
    WiFi_AP_DISCONNECTED,
    //events received from the stations (when in access point mode)
    WiFi_STA_CONNECTED,
    WIFi_STA_GOT_IP,
    WiFi_STA_DISCONNECTED,
    //events generated from WiFi errors
    WiFi_ERROR_TIMEOUT,
    WiFi_ERROR_PASSWORD,
    WiFi_ERROR_INVALID_SSID,
    WiFi_ERROR_CONN_FAIL,
    WiFi_ERROR_UNKNOWN,
};

//TODO: add more events
pub const NetworkEvent = enum {
    Connected,
    Closed,
    ReciveData,
    SendDataComplete,
    SendDataFail,
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
    Command: bool,
    Socket: bool,
    WiFi: bool,
    Bluetooth: bool,
};

pub const WiFistate = enum {
    OFF,
    DISCONECTED,
    CONNECTED,
};

pub const CommandPackage = struct {
    busy_flag: bool = false,
};

pub const WiFiSTAConfig = struct {
    ssid: []const u8,
    pwd: ?[]const u8 = null,
    bssid: ?[]const u8 = null,
    pci_en: u1 = 0,
    reconn_interval: u32 = 1,
    listen_interval: u32 = 3,
    scan_mode: u1 = 0, //fast scan
    jap_timeout: u32 = 15,
    pmf: u1 = 0, //pmf disable
    full_support: bool = false,
};

pub const WiFiAPConfig = struct {
    ssid: []const u8,
    pwd: ?[]const u8 = null,
    channel: u8,
    ecn: WiFi_encryption,
    max_conn: u4 = 10,
    hidden_ssid: u1 = 0,
    full_support: bool = false,
};
pub const WiFiPackageTypes = enum {
    AP_conf_pkg,
    STA_conf_pkg,
};
pub const WiFiPackage = union(WiFiPackageTypes) {
    AP_conf_pkg: WiFiAPConfig,
    STA_conf_pkg: WiFiSTAConfig,
};
pub const NetworkPackage = struct {
    descriptor_id: usize = 255,
    data: ?[]u8 = null,
};
pub const BluetoothPackage = struct {
    //TODO
};

pub const TXPkgType = enum { Command, Socket, WiFi, Bluetooth };
pub const TXExtraData = union(TXPkgType) {
    Command: CommandPackage,
    Socket: NetworkPackage,
    WiFi: WiFiPackage,
    Bluetooth: BluetoothPackage,
};

pub const TXEventPkg = struct {
    cmd_data: [50]u8 = .{0} ** 50,
    cmd_len: usize,
    Extra_data: TXExtraData = .{ .Command = .{} },
};

//TODO: add more config (for all commands)
//TODO: change "command_response(error)" to internal error handler with stacktrace
//TODO: enbale full suport for SSL (at the moment it is not possible to configure SSL certificates)
//TODO: add eneble_IPv6 func [maybe]
//TODO: add bluetooth LE suport for ESP32 modules [maybe]
//TODO: add suport for optional AT frimware features [maybe]
pub fn create_drive(comptime RX_SIZE: comptime_int, comptime network_pool_size: comptime_int) type {
    if (RX_SIZE <= 50) @compileError("RX SIZE CANNOT BE LESS THAN 50 byte");
    if (network_pool_size <= 5) @compileError(" NETWORK POOL SIZE CANNOT BE LESS THAN 5 events");
    return struct {

        // data types
        const Self = @This();

        //TODO: add more functions
        pub const Client = struct {
            id: usize,
            driver: *Self,
            event: NetworkEvent,
            rev: ?[]const u8 = null,

            pub fn send(self: *const Client, data: []u8) DriverError!void {
                try self.driver.send(self.id, data);
            }

            pub fn close(self: *const Client) DriverError!void {
                try self.driver.close(self.id);
            }
        };
        const ServerCallback = *const fn (client: Client, user_data: ?*anyopaque) void;

        pub const network_handler = struct {
            state: NetworkHandlerState = .None,
            NetworkHandlerType: NetworkHandlerType = .Default,
            to_send: usize = 0,
            event_callback: ?ServerCallback = null,
            user_data: ?*anyopaque = null,
        };

        pub const TX_callback = *const fn (data: []const u8, user_data: ?*anyopaque) void;
        pub const RX_callback = *const fn (free_data: usize, user_data: ?*anyopaque) []u8;
        const time_out = 5; //TODO: add user defined timeout in MS

        //internal control data, (Do not modify)

        TX_buffer: Circular_buffer.create_buffer(TXEventPkg, 25) = .{},
        RX_buffer: Circular_buffer.create_buffer(u8, RX_SIZE) = .{},
        TX_callback_handler: TX_callback,
        RX_callback_handler: RX_callback,
        event_aux_buffer: Circular_buffer.create_buffer(commands_enum, 25) = .{},
        busy_flag: BusyBitFlags = .{
            .Command = false,
            .Socket = false,
            .WiFi = false,
            .Bluetooth = false,
        },

        machine_state: Drive_states = .init,
        Wifi_state: WiFistate = .OFF,
        Wifi_mode: WiFiDriverMode = .NONE,
        network_mode: NetworkDriveMode = .CLIENT_ONLY,
        div_binds: usize = 0,

        //network data
        Network_binds: [5]?network_handler = .{ null, null, null, null, null },
        Network_corrent_pkg: NetworkPackage = .{},

        //callback handlers
        //TODO: User event callbacks
        TX_RX_user_data: ?*anyopaque = null,
        internal_user_data: ?*anyopaque = null,
        on_cmd_response: ?*const fn (result: CommandResults, cmd: commands_enum, user_data: ?*anyopaque) void = null,
        on_WiFi_event: ?*const fn (event: WifiEvent, data: ?[]const u8, user_data: ?*anyopaque) void = null,
        fn get_data(self: *Self) void {
            const free_space = self.RX_buffer.len - self.RX_buffer.get_data_size();
            const data_slice = self.RX_callback_handler(free_space, self.TX_RX_user_data);
            for (data_slice) |data| {
                self.RX_buffer.push(data) catch return;
            }
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

        fn get_cmd_type(self: *Self, aux_buffer: []const u8) DriverError!void {
            const response = Self.get_cmd_slice(aux_buffer, &[_]u8{','}, &[_]u8{ ' ', '\r' });
            var result: bool = false;
            const cmd_len = COMMANDS_RESPOSES_TOKENS.len;
            for (0..cmd_len) |cmd_id| {
                result = std.mem.eql(u8, COMMANDS_RESPOSES_TOKENS[cmd_id], response);
                if (result) {
                    try self.read_cmd_response(cmd_id, aux_buffer);
                    break;
                }
            }
        }

        fn read_cmd_response(self: *Self, cmd_id: usize, aux_buffer: []const u8) DriverError!void {
            //TODO: change this
            switch (cmd_id) {
                0 => try self.ok_response(),
                1 => try self.error_response(),
                2 => try self.wifi_response(aux_buffer),
                3 => try self.network_conn_event(aux_buffer),
                4 => try self.network_closed_event(aux_buffer),
                5 => try self.network_send_event(aux_buffer),
                6 => self.busy_flag.Command = false,
                else => return DriverError.INVALID_RESPONSE,
            }
        }
        fn get_cmd_data_type(self: *Self, aux_buffer: []const u8) DriverError!void {
            const response = Self.get_cmd_slice(aux_buffer, &[_]u8{}, &[_]u8{ ':', ',' });
            var result: bool = false;
            for (0..COMMAND_DATA_TYPES.len) |cmd_id| {
                result = std.mem.eql(u8, response, COMMAND_DATA_TYPES[cmd_id]);
                if (result) {
                    try self.read_cmd_data(cmd_id, aux_buffer);
                    break;
                }
            }
        }

        //TODO: ADD more responses
        fn read_cmd_data(self: *Self, cmd_id: usize, aux_buffer: []const u8) DriverError!void {
            switch (cmd_id) {
                0 => try self.parse_network_data(aux_buffer),
                1 => try self.WiFi_get_AP_info(),
                2 => try self.WiFi_error(),
                3 => try self.WiFi_get_device_conn_mac(),
                4 => try self.WiFi_get_device_ip(),
                5 => try self.WiFi_get_device_disc_mac(),
                else => {
                    return DriverError.INVALID_RESPONSE;
                },
            }
        }

        fn ok_response(self: *Self) DriverError!void {
            const cmd = self.event_aux_buffer.get() catch return DriverError.AUX_BUFFER_EMPTY;
            //add custom handler here
            switch (cmd) {
                .WIFI_CONNECT => self.busy_flag.WiFi = false, //wait WiFi OK before releasing the busy flag
                else => {},
            }
            if (self.on_cmd_response) |callback| {
                callback(.Ok, cmd, self.internal_user_data);
            }
        }

        fn error_response(self: *Self) DriverError!void {
            const cmd = self.event_aux_buffer.get() catch return DriverError.AUX_BUFFER_EMPTY;
            switch (cmd) {
                .NETWORK_SEND => {
                    //clear current pkg on cipsend error (This happens only when a "CIPSEND" is sent to a client that is closed)
                    const pkg = self.Network_corrent_pkg;
                    if (pkg.data) |to_free| {
                        const client = Client{
                            .driver = self,
                            .event = .SendDataFail,
                            .id = pkg.descriptor_id,
                            .rev = to_free,
                        };
                        if (self.Network_binds[pkg.descriptor_id]) |*bd| {
                            if (bd.event_callback) |callback| {
                                callback(client, bd.user_data);
                            }
                        }
                    }
                    self.busy_flag.Socket = false;
                },
                else => {},
            }
            if (self.on_cmd_response) |callback| {
                callback(.Error, cmd, self.internal_user_data);
            }
        }

        fn wifi_response(self: *Self, aux_buffer: []const u8) DriverError!void {
            var inner_buffer: [50]u8 = .{0} ** 50;
            var index: usize = 0;
            var tx_event: ?WifiEvent = null;
            const wifi_event_slice = get_cmd_slice(aux_buffer[5..], &[_]u8{}, &[_]u8{'\r'});
            for (WIFI_RESPOSE_TOKEN) |TOKEN| {
                const result = std.mem.eql(u8, wifi_event_slice, TOKEN);
                if (result) {
                    break;
                }
                index += 1;
            }
            switch (index) {
                0 => {
                    tx_event = WifiEvent.WiFi_AP_DISCONNECTED;
                    self.Wifi_state = .DISCONECTED;
                },
                1 => tx_event = WifiEvent.WiFi_AP_CON_START,
                2 => {
                    //load IP request to the TX pool
                    tx_event = WifiEvent.WiFi_AP_CONNECTED;
                    const cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}{s}?{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_IP)], postfix }) catch return;
                    const cmd_size = cmd_slice.len;
                    self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size }) catch return DriverError.TX_BUFFER_FULL;
                    self.event_aux_buffer.push(commands_enum.NETWORK_IP) catch return DriverError.TASK_BUFFER_FULL;
                },
                else => {
                    return DriverError.INVALID_RESPONSE;
                },
            }
            if (tx_event) |event| {
                if (self.on_WiFi_event) |callback| {
                    callback(event, null, self.internal_user_data);
                }
            }
        }

        //ADD more WiFi events
        fn WiFi_get_AP_info(self: *Self) DriverError!void {
            var aux_buf: [25]u8 = .{0} ** 25;
            try self.wait_for_bytes(20); //netmask:"xxx.xxx.xxx.xxx"

            //next byte determine the event
            const nettype = self.RX_buffer.get() catch return DriverError.UNKNOWN_ERROR; //RX_beffer should be at least 20 bytes
            for (&aux_buf) |*data| {
                data.* = self.RX_buffer.get() catch return DriverError.UNKNOWN_ERROR;
                if (data.* == '\n') break;
            }
            const data_slice = Self.get_cmd_slice(&aux_buf, &[_]u8{':'}, &[_]u8{'\n'});
            const wifi_event = switch (nettype) {
                'i' => WifiEvent.WiFi_AP_GOT_IP,
                'g' => WifiEvent.WiFi_AP_GOT_GATEWAY,
                'n' => WifiEvent.WiFi_AP_GOT_MASK,
                else => {
                    return DriverError.INVALID_RESPONSE;
                },
            };
            if (self.on_WiFi_event) |callback| {
                callback(wifi_event, data_slice[2..(data_slice.len - 2)], self.internal_user_data);
            }
            self.Wifi_state = .CONNECTED;
        }

        fn WiFi_error(self: *Self) DriverError!void {
            self.busy_flag.WiFi = false;
            const error_id: u8 = self.RX_buffer.get() catch {
                return DriverError.INVALID_RESPONSE;
            };
            const error_enum = switch (error_id) {
                '1' => WifiEvent.WiFi_ERROR_TIMEOUT,
                '2' => WifiEvent.WiFi_ERROR_PASSWORD,
                '3' => WifiEvent.WiFi_ERROR_INVALID_SSID,
                '4' => WifiEvent.WiFi_ERROR_CONN_FAIL,
                else => WifiEvent.WiFi_ERROR_UNKNOWN,
            };
            if (self.on_WiFi_event) |callback| {
                callback(error_enum, null, self.internal_user_data);
            }
        }

        fn WiFi_get_device_conn_mac(self: *Self) DriverError!void {
            var info_buf: [20]u8 = .{0} ** 20;
            try self.get_STA_mac(&info_buf);
            if (self.on_WiFi_event) |callback| {
                callback(.WiFi_STA_CONNECTED, &info_buf, self.internal_user_data);
            }
        }
        fn WiFi_get_device_ip(self: *Self) DriverError!void {
            var info_buf: [20]u8 = .{0} ** 20;
            try self.get_STA_ip(&info_buf);
            if (self.on_WiFi_event) |callback| {
                callback(.WIFi_STA_GOT_IP, &info_buf, self.internal_user_data);
            }
        }

        fn WiFi_get_device_disc_mac(self: *Self) DriverError!void {
            var info_buf: [20]u8 = .{0} ** 20;
            try self.get_STA_mac(&info_buf);
            if (self.on_WiFi_event) |callback| {
                callback(.WiFi_STA_DISCONNECTED, &info_buf, self.internal_user_data);
            }
        }

        fn get_STA_mac(self: *Self, out_buf: []u8) DriverError!void {
            try self.wait_for_bytes(19);
            var aux_buffer: [19]u8 = .{0} ** 19;
            for (&aux_buffer) |*data| {
                data.* = self.RX_buffer.get() catch return DriverError.UNKNOWN_ERROR;
                if (data.* == '\n') break;
            }
            const buffer_len = aux_buffer.len - 3;
            const mac_slice = aux_buffer[1..buffer_len];
            std.mem.copyForwards(u8, out_buf, mac_slice);
        }

        fn get_STA_ip(self: *Self, out_buf: []u8) DriverError!void {
            try self.wait_for_bytes(33);
            var aux_buffer: [33]u8 = .{0} ** 33;
            for (&aux_buffer) |*data| {
                data.* = self.RX_buffer.get() catch return DriverError.UNKNOWN_ERROR;
                if (data.* == '\n') break;
            }
            const ip_slice = Self.get_cmd_slice(&aux_buffer, &[_]u8{','}, &[_]u8{'\n'});
            const ip_len = ip_slice.len - 3;
            if (ip_len > out_buf.len) return DriverError.INVALID_RESPONSE;
            std.mem.copyForwards(u8, out_buf, ip_slice[2..(ip_len + 2)]);
        }

        fn wait_for_bytes(self: *Self, data_len: usize) DriverError!void {
            var time: usize = time_out;
            var RX_data_len = self.RX_buffer.get_data_size();
            while (time > 0) : (time -= 1) {
                self.get_data();
                RX_data_len = self.RX_buffer.get_data_size();
                if (RX_data_len >= data_len) return;
            }
            return DriverError.INVALID_RESPONSE;
        }

        fn parse_network_data(self: *Self, aux_buffer: []const u8) DriverError!void {
            var slices = std.mem.split(u8, aux_buffer, ",");
            _ = slices.next();
            var id: usize = 0;
            var remain_data: usize = 0;

            if (slices.next()) |recive_id| {
                id = std.fmt.parseInt(usize, recive_id, 10) catch return DriverError.INVALID_RESPONSE;
            } else {
                return DriverError.INVALID_RESPONSE;
            }
            if (id > self.Network_binds.len) return DriverError.INVALID_RESPONSE;
            if (slices.next()) |data_size| {
                var end_index: usize = 0;
                for (data_size) |ch| {
                    if ((ch >= '0') and ch <= '9') {
                        end_index += 1;
                    }
                }

                remain_data = std.fmt.parseInt(usize, data_size[0..end_index], 10) catch return DriverError.INVALID_RESPONSE;
            } else {
                return DriverError.INVALID_RESPONSE;
            }
            try self.read_network_data(id, remain_data);
        }

        //TODO: add timeout
        fn read_network_data(self: *Self, id: usize, to_recive: usize) DriverError!void {
            var remain = to_recive;
            var index: usize = 0;
            var data: u8 = 0;
            var rev: [4096]u8 = .{0} ** 4096;
            while (remain > 0) {
                data = self.RX_buffer.get() catch {
                    self.get_data();
                    continue;
                };
                rev[index] = data;
                remain -= 1;
                index += 1;
            }
            if (self.Network_binds[id]) |bd| {
                if (bd.event_callback) |callback| {
                    const client = Client{
                        .id = @intCast(id),
                        .driver = self,
                        .event = .ReciveData,
                        .rev = rev[0..index],
                    };
                    callback(client, bd.user_data);
                }
            }
            self.machine_state = Drive_states.IDLE;
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
                        .event = NetworkEvent.Connected,
                        .driver = self,
                        .rev = null,
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
                        .event = NetworkEvent.Closed,
                        .driver = self,
                        .rev = null,
                    };
                    callback(client, bd.user_data);

                    //clear all pkgs from the TX pool
                    for (0..bd.to_send) |_| {
                        const TX_pkg = self.TX_buffer.get() catch return;
                        switch (TX_pkg.Extra_data) {
                            .Socket => |*net_pkg| {
                                if (net_pkg.descriptor_id == index) {
                                    client.event = .SendDataFail;
                                    client.rev = net_pkg.data;
                                    callback(client, bd.user_data);
                                    continue;
                                }
                                self.TX_buffer.push(TX_pkg) catch unreachable;
                            },
                            else => self.TX_buffer.push(TX_pkg) catch unreachable,
                        }
                    }
                }
            }
        }

        fn network_send_event(self: *Self, aux_buffer: []const u8) DriverError!void {
            self.busy_flag.Socket = false;
            const send_event_slice = get_cmd_slice(aux_buffer[5..], &[_]u8{}, &[_]u8{'\r'});
            for (0..SEND_RESPONSE_TOKEN.len) |index| {
                const result = std.mem.eql(u8, send_event_slice, SEND_RESPONSE_TOKEN[index]);
                if (result) {
                    try self.network_send_resposnse(index);
                    return;
                }
            }
            return DriverError.INVALID_RESPONSE;
        }

        fn network_send_resposnse(self: *Self, response_id: usize) DriverError!void {
            const to_free = self.Network_corrent_pkg;
            const pkg_id = to_free.descriptor_id;
            const event: NetworkEvent = switch (response_id) {
                0 => NetworkEvent.SendDataComplete,
                1 => NetworkEvent.SendDataFail,
                else => unreachable,
            };
            if (self.Network_binds[pkg_id]) |*bd| {
                if (bd.event_callback) |callback| {
                    const client: Client = .{
                        .driver = self,
                        .event = event,
                        .id = pkg_id,
                        .rev = to_free.data,
                    };
                    callback(client, bd.user_data);
                }
            }
        }

        fn network_send_data(self: *Self) DriverError!void {
            const pkg = self.Network_corrent_pkg;
            if (pkg.descriptor_id < self.Network_binds.len) {
                if (pkg.data) |data| {
                    self.TX_callback_handler(data, self.TX_RX_user_data);
                    if (self.Network_binds[pkg.descriptor_id]) |*bd| {
                        bd.to_send -= 1;
                    }
                    return;
                }
            }
            self.machine_state = .FATAL_ERROR;
            return DriverError.NON_RECOVERABLE_ERROR;
        }

        fn WiFi_apply_AP_config(self: *Self, cmd: []const u8, config: WiFiAPConfig) DriverError!void {
            var inner_buffer: [120]u8 = .{0} ** 120;
            var cmd_slice: []u8 = undefined;
            var cmd_size: usize = 0;
            cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}\"{s}\",", .{ cmd, config.ssid }) catch return DriverError.UNKNOWN_ERROR;
            cmd_size += cmd_slice.len;
            if (config.pwd) |pwd| {
                cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], "\"{s}\",", .{pwd}) catch return DriverError.UNKNOWN_ERROR;
                cmd_size += cmd_slice.len;
            } else {
                cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], ",", .{}) catch return DriverError.UNKNOWN_ERROR;
                cmd_size += cmd_slice.len;
            }

            cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], "{d},{d}", .{
                config.channel,
                @intFromEnum(config.ecn),
            }) catch return DriverError.UNKNOWN_ERROR;
            cmd_size += cmd_slice.len;

            if (config.full_support) {
                cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], ",{d},{d}", .{
                    config.max_conn,
                    config.hidden_ssid,
                }) catch return DriverError.UNKNOWN_ERROR;
                cmd_size += cmd_slice.len;
            }
            cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], "{s}", .{postfix}) catch return DriverError.UNKNOWN_ERROR;
            cmd_size += cmd_slice.len;
            self.TX_callback_handler(inner_buffer[0..cmd_size], self.TX_RX_user_data);
        }

        fn WiFi_apply_STA_config(self: *Self, cmd: []const u8, config: WiFiSTAConfig) DriverError!void {
            var inner_buffer: [120]u8 = .{0} ** 120;
            var cmd_slice: []u8 = undefined;
            var cmd_size: usize = 0;
            cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}\"{s}\",", .{ cmd, config.ssid }) catch return DriverError.UNKNOWN_ERROR;
            cmd_size += cmd_slice.len;
            if (config.pwd) |pwd| {
                cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], "\"{s}\",", .{pwd}) catch return DriverError.UNKNOWN_ERROR;
                cmd_size += cmd_slice.len;
            } else {
                cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], ",", .{}) catch return DriverError.UNKNOWN_ERROR;
                cmd_size += cmd_slice.len;
            }
            if (config.bssid) |bssid| {
                cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], "\"{s}\",", .{bssid}) catch return DriverError.UNKNOWN_ERROR;
                cmd_size += cmd_slice.len;
            } else {
                cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], ",", .{}) catch return DriverError.UNKNOWN_ERROR;
                cmd_size += cmd_slice.len;
            }
            if (config.full_support) {
                cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], "{d},{d},{d},{d}<{d},{d}", .{
                    config.pci_en,
                    config.reconn_interval,
                    config.listen_interval,
                    config.scan_mode,
                    config.jap_timeout,
                    config.pmf,
                }) catch return DriverError.UNKNOWN_ERROR;
                cmd_size += cmd_slice.len;
            }
            cmd_slice = std.fmt.bufPrint(inner_buffer[cmd_size..], "{s}", .{postfix}) catch return DriverError.UNKNOWN_ERROR;
            cmd_size += cmd_slice.len;
            self.TX_callback_handler(inner_buffer[0..cmd_size], self.TX_RX_user_data);
        }

        pub fn process(self: *Self) DriverError!void {
            switch (self.machine_state) {
                .init => {
                    self.init_driver() catch return;
                },
                .IDLE => {
                    try self.IDLE_TRANS();
                    try self.IDLE_REV();
                },
                .OFF => return DriverError.DRIVER_OFF,
                .FATAL_ERROR => return DriverError.NON_RECOVERABLE_ERROR, //module need to reboot due a deadlock, Non-recoverable deadlocks occur when the data in a network packet is null.
            }
        }

        fn IDLE_REV(self: *Self) DriverError!void {
            var data: u8 = 0;
            var data_size: usize = 0;
            var RX_aux_buffer: Circular_buffer.create_buffer(u8, 50) = .{};
            self.get_data();
            while (true) {
                data = self.RX_buffer.get() catch break;
                switch (data) {
                    '\n' => {
                        if (RX_aux_buffer.get_data_size() >= 3) {
                            try self.get_cmd_type(RX_aux_buffer.raw_buffer()[0..data_size]);
                        }
                        RX_aux_buffer.clear();
                    },
                    ':' => {
                        try self.get_cmd_data_type(RX_aux_buffer.raw_buffer()[0..data_size]);
                        RX_aux_buffer.clear();
                    },
                    '>' => {
                        try self.network_send_data();
                        RX_aux_buffer.clear();
                    },
                    else => {
                        RX_aux_buffer.push_overwrite(data);
                        data_size = RX_aux_buffer.get_data_size();
                    },
                }
            }
        }

        fn IDLE_TRANS(self: *Self) DriverError!void {
            if (check_flag(self.busy_flag)) return;
            const next_cmd = self.TX_buffer.get() catch return;
            _ = std.log.info("GOT PKG {any}", .{next_cmd});
            const cmd_data = next_cmd.cmd_data[0..next_cmd.cmd_len];
            switch (next_cmd.Extra_data) {
                .Command => |data| {
                    self.TX_callback_handler(cmd_data, self.TX_RX_user_data);
                    self.busy_flag.Command = data.busy_flag;
                },
                .Socket => |data| {
                    self.Network_corrent_pkg = data;
                    self.TX_callback_handler(cmd_data, self.TX_RX_user_data);
                    self.busy_flag.Socket = true;
                },
                .WiFi => |data| {
                    switch (data) {
                        .AP_conf_pkg => |pkg| {
                            try self.WiFi_apply_AP_config(cmd_data, pkg);
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

        //TODO; make a event pool just to init commands
        pub fn init_driver(self: *Self) !void {
            //clear buffers
            self.deinit_driver();
            self.RX_buffer.clear();
            self.TX_buffer.clear();
            self.event_aux_buffer.clear();
            var inner_buffer: [50]u8 = std.mem.zeroes([50]u8);
            var cmd_slice: []const u8 = undefined;
            var cmd_size: usize = 0;

            //send dummy cmd to clear the TX buffer

            cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}{s}", .{ COMMANDS_TOKENS[@intFromEnum(commands_enum.DUMMY)], postfix }) catch return DriverError.INVALID_ARGS;
            cmd_size = cmd_slice.len;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size }) catch return DriverError.TX_BUFFER_FULL;
            self.event_aux_buffer.push(commands_enum.DUMMY) catch return DriverError.TASK_BUFFER_FULL;

            //send RST request
            cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}{s}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.RESET)], postfix }) catch return DriverError.INVALID_ARGS;
            cmd_size = cmd_slice.len;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size, .Extra_data = .{ .Command = .{ .busy_flag = true } } }) catch return DriverError.TX_BUFFER_FULL;
            self.event_aux_buffer.push(commands_enum.RESET) catch return DriverError.TASK_BUFFER_FULL;

            //clear aux buffer
            inner_buffer = std.mem.zeroes([50]u8);

            //desable ECHO
            cmd_slice = try std.fmt.bufPrint(&inner_buffer, "{s}{s}", .{ COMMANDS_TOKENS[@intFromEnum(commands_enum.ECHO_OFF)], postfix });
            cmd_size = cmd_slice.len;
            try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size });
            try self.event_aux_buffer.push(commands_enum.ECHO_OFF);

            //enable multi-conn
            cmd_slice = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=1{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.IP_MUX)], postfix });
            cmd_size = cmd_slice.len;
            try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size });
            try self.event_aux_buffer.push(commands_enum.IP_MUX);

            //disable wifi auto connection
            cmd_slice = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=0{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_AUTOCONN)], postfix });
            cmd_size = cmd_slice.len;
            try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size });
            try self.event_aux_buffer.push(commands_enum.WIFI_AUTOCONN);
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

        //TODO: add more config
        pub fn WiFi_connect_AP(self: *Self, config: WiFiSTAConfig) DriverError!void {
            if (self.Wifi_mode == .AP) {
                return DriverError.STA_OFF;
            } else if (self.Wifi_mode == WiFiDriverMode.NONE) {
                return DriverError.WIFI_OFF;
            }
            const ssid_len = config.ssid.len;
            if ((ssid_len < 1) or (ssid_len > 32)) return DriverError.INVALID_ARGS;
            if (config.pwd) |pwd| {
                const pwd_len = pwd.len;
                if ((pwd_len < 8) or (pwd_len > 60)) return DriverError.INVALID_ARGS;
            }
            if (config.bssid) |bssid| {
                if (bssid.len < 17) return DriverError.INVALID_ARGS;
            }
            if (config.reconn_interval > 7200) return DriverError.INVALID_ARGS;
            if (config.listen_interval > 100) return DriverError.INVALID_ARGS;
            if (config.jap_timeout > 600) return DriverError.INVALID_ARGS;

            var inner_buffer: [50]u8 = .{0} ** 50;
            var cmd_slice: []const u8 = undefined;
            var cmd_size: usize = 0;
            cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}{s}=", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_CONNECT)] }) catch return;
            cmd_size = cmd_slice.len;
            self.event_aux_buffer.push(commands_enum.WIFI_CONNECT) catch return;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size, .Extra_data = .{ .WiFi = .{ .STA_conf_pkg = config } } }) catch return;
        }

        pub fn WiFi_config_AP(self: *Self, config: WiFiAPConfig) !void {
            if (self.Wifi_mode == .STA) {
                return DriverError.AP_OFF;
            } else if (self.Wifi_mode == .NONE) {
                return DriverError.WIFI_OFF;
            }
            //Error check
            const ssid_len = config.ssid.len;
            if ((ssid_len < 1) or (ssid_len > 32)) return DriverError.INVALID_ARGS;
            if (config.pwd) |pwd| {
                const pwd_len = pwd.len;
                if ((pwd_len < 8) or (pwd_len > 60)) return DriverError.INVALID_ARGS;
            }

            var inner_buffer: [50]u8 = .{0} ** 50;
            var cmd_slice: []const u8 = undefined;
            var cmd_size: usize = 0;
            cmd_slice = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_CONF)] });
            cmd_size = cmd_slice.len;
            try self.event_aux_buffer.push(commands_enum.WIFI_CONF);
            try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size, .Extra_data = .{ .WiFi = .{ .AP_conf_pkg = config } } });
        }

        pub fn set_WiFi_mode(self: *Self, mode: WiFiDriverMode) !void {
            var inner_buffer: [50]u8 = .{0} ** 50;
            var cmd_slice: []const u8 = undefined;
            var cmd_size: usize = 0;
            cmd_slice = try std.fmt.bufPrint(&inner_buffer, "{s}{s}={d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_SET_MODE)], @intFromEnum(mode), postfix });
            cmd_size = cmd_slice.len;
            try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size });
            try self.event_aux_buffer.push(commands_enum.WIFI_SET_MODE);
            self.Wifi_mode = mode;
        }
        pub fn set_network_mode(self: *Self, mode: NetworkDriveMode) !void {
            var inner_buffer: [50]u8 = .{0} ** 50;
            var cmd_slice: []const u8 = undefined;
            var cmd_size: usize = 0;
            if (mode == .SERVER_CLIENT) {
                //configure server to MAX connections to 3
                cmd_slice = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=3{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SERVER_CONF)], postfix });
                cmd_size = cmd_slice.len;
                try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size });
                try self.event_aux_buffer.push(commands_enum.NETWORK_SERVER_CONF);
            }

            self.div_binds = switch (mode) {
                .CLIENT_ONLY => 0,
                .SERVER_ONLY => 5,
                .SERVER_CLIENT => 3,
            };

            self.network_mode = mode;
        }

        pub fn bind(self: *Self, net_type: NetworkHandlerType, event_callback: ServerCallback, user_data: ?*anyopaque) DriverError!usize {
            const start_bind = self.div_binds;

            for (start_bind..self.Network_binds.len) |index| {
                if (self.Network_binds[index]) |_| {
                    continue;
                } else {
                    const new_bind: network_handler = .{
                        .NetworkHandlerType = net_type,
                        .event_callback = event_callback,
                        .user_data = user_data,
                    };
                    self.Network_binds[index] = new_bind;
                    return index;
                }
            }
            return DriverError.MAX_BINDS;
        }

        //TODO: ADD IPv6
        pub fn connect(self: *Self, id: usize, host: []const u8, port: u16) DriverError!void {
            if (id > self.Network_binds.len) return DriverError.INVALID_BIND;
            var inner_buffer: [50]u8 = .{0} ** 50;
            if (self.Network_binds[id]) |bd| {
                const net_type = switch (bd.NetworkHandlerType) {
                    .SSL => "SSL",
                    .TCP => "TCP",
                    .UDP => "UDP",
                    .None => {
                        return DriverError.INVALID_TYPE;
                    },
                };
                var cmd_slice: []const u8 = undefined;
                var cmd_size: usize = 0;
                cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}{s}={d},\"{s}\",\"{s}\",{d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_CONNECT)], id, net_type, host, port, postfix }) catch return DriverError.INVALID_ARGS;
                cmd_size = cmd_slice.len;
                self.event_aux_buffer.push(commands_enum.NETWORK_CONNECT) catch return DriverError.TASK_BUFFER_FULL;
                self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size }) catch return DriverError.TX_BUFFER_FULL;
            } else {
                return DriverError.INVALID_BIND;
            }
        }

        //TODO: add error checking for invalid closed erros
        pub fn close(self: *Self, id: usize) DriverError!void {
            var inner_buffer: [50]u8 = .{0} ** 50;
            var cmd_slice: []const u8 = undefined;
            var cmd_size: usize = 0;
            cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}{s}={d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_CLOSE)], id, postfix }) catch return DriverError.INVALID_ARGS;
            cmd_size = cmd_slice.len;
            self.event_aux_buffer.push(commands_enum.NETWORK_CLOSE) catch return DriverError.TASK_BUFFER_FULL;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size }) catch return DriverError.TX_BUFFER_FULL;
        }

        //TODO: add server type param (TCP, TCP6, SSL, SSL6)
        //TODO: Notify when the server is actually created
        pub fn create_server(self: *Self, port: u16, server_type: NetworkHandlerType, event_callback: ServerCallback, user_data: ?*anyopaque) DriverError!void {
            const end_bind = self.div_binds;
            var inner_buffer: [50]u8 = .{0} ** 50;
            var cmd_slice: []const u8 = undefined;
            var slice_len: usize = 0;
            if (self.network_mode == NetworkDriveMode.CLIENT_ONLY) return DriverError.SERVER_OFF;

            cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}{s}=1,{d}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SERVER)], port }) catch return DriverError.INVALID_ARGS;
            slice_len += cmd_slice.len;
            switch (server_type) {
                .Default => {
                    cmd_slice = std.fmt.bufPrint(inner_buffer[slice_len..], "{s}", .{postfix}) catch return DriverError.INVALID_ARGS;
                    slice_len += cmd_slice.len;
                },

                .SSL => {
                    cmd_slice = std.fmt.bufPrint(inner_buffer[slice_len..], ",\"SSL\"{s}", .{postfix}) catch return DriverError.INVALID_ARGS;
                    slice_len += cmd_slice.len;
                },

                .TCP => {
                    cmd_slice = std.fmt.bufPrint(inner_buffer[slice_len..], ",\"TCP\"{s}", .{postfix}) catch return DriverError.INVALID_ARGS;
                    slice_len += cmd_slice.len;
                },

                else => return DriverError.INVALID_ARGS,
            }

            self.event_aux_buffer.push(commands_enum.NETWORK_SERVER) catch return DriverError.TASK_BUFFER_FULL;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = slice_len }) catch return DriverError.TX_BUFFER_FULL;
            for (0..end_bind) |id| {
                self.Network_binds[id] = network_handler{
                    .NetworkHandlerType = NetworkHandlerType.TCP,
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
                    .event = .SendDataFail,
                    .rev = null,
                };
                const TX_size = self.TX_buffer.get_data_size();
                for (0..TX_size) |_| {
                    const data = self.TX_buffer.get() catch break;
                    switch (data.Extra_data) {
                        .Socket => |*net_data| {
                            if (id == net_data.descriptor_id) {
                                client.id = id;
                                client.rev = net_data.data;
                                if (bd.event_callback) |callback| {
                                    callback(client, bd.user_data);
                                }
                            } else {
                                self.TX_buffer.push(data) catch return;
                            }
                        },
                        else => self.TX_buffer.push(data) catch return,
                    }
                }
            }
            self.Network_binds[id] = null;
        }

        pub fn delete_server(self: *Self) DriverError!void {
            var inner_buffer: [50]u8 = .{0} ** 50;

            for (0..self.div_binds) |bind_id| {
                self.release(bind_id);
            }
            var cmd_slice: []const u8 = undefined;
            var cmd_size: usize = 0;
            //send close server command
            cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}{s}=0,1{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SERVER)], postfix }) catch unreachable;
            cmd_size = cmd_slice.len;
            self.event_aux_buffer.push(commands_enum.NETWORK_SERVER) catch DriverError.TASK_BUFFER_FULL;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size }) catch DriverError.TX_BUFFER_FULL;
        }

        //TODO: add error check
        //TODO: break data bigger than 2048 into multi 2048 pkgs
        //TODO: delete events from pool in case of erros
        pub fn send(self: *Self, id: usize, data: []u8) DriverError!void {
            if (id >= self.Network_binds.len) return DriverError.INVALID_ARGS;
            var cmd_slice: []const u8 = undefined;
            var cmd_size: usize = 0;
            const free_TX_cmd = self.TX_buffer.len - self.TX_buffer.get_data_size();
            if (free_TX_cmd < 2) return DriverError.BUSY; //keep some space to other commands
            var inner_buffer: [50]u8 = .{0} ** 50;
            if (self.Network_binds[id]) |*bd| {
                if (bd.state == .Connected) {
                    const pkg = NetworkPackage{
                        .data = data,
                        .descriptor_id = id,
                    };
                    cmd_slice = std.fmt.bufPrint(&inner_buffer, "{s}{s}={d},{d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SEND)], id, data.len, postfix }) catch return DriverError.INVALID_ARGS;
                    cmd_size = cmd_slice.len;
                    self.event_aux_buffer.push(commands_enum.NETWORK_SEND) catch return DriverError.TASK_BUFFER_FULL;
                    self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .cmd_len = cmd_size, .Extra_data = .{ .Socket = pkg } }) catch return DriverError.TX_BUFFER_FULL;
                    bd.to_send += 1;
                    return;
                }
            }
            return DriverError.INVALID_BIND;
        }

        //TODO: add more config param
        pub fn new(txcallback: TX_callback, rxcallback: RX_callback) Self {
            //const ATdrive = create_drive(buffer_size);
            return .{ .RX_callback_handler = rxcallback, .TX_callback_handler = txcallback };
        }
    };
}

pub fn check_flag(bitflags: BusyBitFlags) bool {
    return bitflags.Command or bitflags.Socket or bitflags.WiFi or bitflags.Bluetooth;
}
