//TODO: remove "process" completely from the microZig implementation when "Framework driver" is added, Use notification instead of pull [maybe]

const std = @import("std");
pub const Circular_buffer = @import("util/circular_buffer.zig");

pub const DriverError = error{
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
    UNKNOWN_ERROR,
};
pub const NetworkDriveType = enum {
    SERVER_ONLY,
    CLIENT_ONLY,
    SERVER_CLIENT,
};

pub const WiFiDriverType = enum { NONE, STA, AP, AP_STA };

//TODO: add uart config
pub const Drive_states = enum {
    init,
    IDLE,
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

//TODO: rework commands check for avoid errors like: "SEND OK == OK"
pub const COMMANDS_RESPOSES_TOKENS = [_][]const u8{
    "SEND", //send need to be check first due "SEND OK" response,
    "OK",
    "ERROR",
    "WIFI",
    "CON",
    "CLO",
    "ready",
};
pub const COMMAND_DATA_TYPES = [_][]const u8{ "IPD", "CIPSTA", "CWJAP", "STA" };

pub const CommandResults = enum(u8) { Ok, Error };

pub const WIFI_RESPOSE_TOKEN = [_][]const u8{
    "DISC",
    "CON",
    "IP",
};

pub const SEND_RESPONSE_TOKEN = [_][]const u8{
    "OK",
    "FAIL",
};

pub const WifiEvent = enum(u8) {
    WiFi_CON_START,
    WiFi_AP_CONNECTED,
    WiFi_AP_GOT_IP,
    WiFi_AP_DISCONNECTED,
    WiFi_STA_CONNECTED,
    WIFi_STA_GOT_IP,
    WiFi_STA_DISCONNECTED,
    WiFi_ERROR_TIMEOUT,
    WiFi_ERROR_PASSWORD,
    WiFi_ERROR_INVALID_AP,
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
    None,
    TCP,
    UDP,
    SSL,
};

pub const WiFistate = enum {
    OFF,
    DISCONECTED,
    CONNECTED,
};

pub const TXEventPkg = struct {
    busy: bool = false,
    cmd_data: [50]u8,
};

//TODO: add more config (for all commands)
//TODO: change "command_response(error)" to internal error handler with stacktrace
//TODO: enbale full suport for SSL (at the moment it is not possible to configure SSL certificates)
//TODO: add eneble_IPv6 func [maybe]
//TODO: add bluetooth LE suport for ESP32 modules [maybe]
//TODO: add suport for optional AT frimware features [maybe]
pub fn create_drive(comptime RX_SIZE: comptime_int, comptime network_pool_size: comptime_int, comptime Wifi_type: WiFiDriverType, comptime network_type: NetworkDriveType) type {
    if (RX_SIZE <= 50) @compileError("RX SIZE CANNOT BE LESS THAN 50 byte");
    if (network_pool_size <= 5) @compileError(" NETWORK POOL SIZE CANNOT BE LESS THAN 5 events");
    const max_binds = switch (network_type) {
        .SERVER_CLIENT => 3,
        .SERVER_ONLY => 5,
        .CLIENT_ONLY => 0,
    };
    return struct {

        // data types
        const Self = @This();
        const div_binds = max_binds;

        //TODO: add more functions
        pub const Client = struct {
            id: u8,
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
            descriptor_id: u8 = 255,
            state: NetworkHandlerState = .None,
            NetworkHandlerType: NetworkHandlerType = .None,
            event_callback: ?ServerCallback = null,
            user_data: ?*anyopaque = null,
        };

        pub const NetworkPackage = struct { descriptor_id: u8 = 255, data: ?[]u8 = null };
        const buffer_type = Circular_buffer.create_buffer(u8, RX_SIZE);
        const Wifi_mode = Wifi_type;
        pub const RX_buffer_type = *buffer_type;
        pub const TX_callback = *const fn (data: []const u8) void;
        pub const RX_callback = *const fn (data: RX_buffer_type) void;
        const time_out = 5; //TODO: add user defined timeout in MS

        //internal control data, (Do not modify)
        TX_buffer: Circular_buffer.create_buffer(TXEventPkg, 25) = .{},
        RX_buffer: buffer_type = .{},
        TX_callback_handler: TX_callback,
        RX_callback_handler: RX_callback,
        event_aux_buffer: Circular_buffer.create_buffer(commands_enum, 25) = .{},
        machine_state: Drive_states = .init,
        busy_flag: bool = false, //TODO: Create a better busy interface
        Wifi_state: WiFistate = .OFF,
        last_busy: commands_enum = .DUMMY, //for debug only

        //network data
        Network_binds: [5]?network_handler = .{ null, null, null, null, null },
        Network_pool: Circular_buffer.create_buffer(NetworkPackage, network_pool_size) = .{},
        network_AP_ip: [16]u8 = .{0} ** 16,
        network_AP_gateway: [16]u8 = .{0} ** 16,
        network_AP_mask: [16]u8 = .{0} ** 16,

        //callback handlers
        //TODO: User event callbacks
        internal_user_data: ?*anyopaque = null,
        on_cmd_response: ?*const fn (result: CommandResults, cmd: commands_enum, user_data: ?*anyopaque) void = null,
        on_STA_event: ?*const fn (event: WifiEvent, user_data: ?*anyopaque) void = null,
        on_AP_event: ?*const fn (event: WifiEvent, data: []u8, user_data: ?*anyopaque) void = null,

        //TODO: parse commands and use HASH to compare
        fn get_cmd_type(self: *Self, aux_buffer: []const u8) DriverError!void {
            var result: ?usize = null;
            const cmd_len = COMMANDS_RESPOSES_TOKENS.len;
            for (0..cmd_len) |COMMAND| {
                result = std.mem.indexOf(u8, aux_buffer, COMMANDS_RESPOSES_TOKENS[COMMAND]);
                if (result) |_| {
                    self.read_cmd_response(COMMAND, aux_buffer) catch |err| {
                        return err;
                    };
                    break;
                }
            }
        }

        fn read_cmd_response(self: *Self, cmd_id: usize, aux_buffer: []const u8) DriverError!void {
            //TODO: change this
            switch (cmd_id) {
                1 => try self.command_response(CommandResults.Ok),
                2 => try self.command_response(CommandResults.Error),
                3 => try self.wifi_response(aux_buffer),
                4 => try self.network_event(NetworkHandlerState.Connected, aux_buffer),
                5 => try self.network_event(NetworkHandlerState.Closed, aux_buffer),
                0 => try self.network_send_event(aux_buffer), //TODO fix this after rework
                6 => self.busy_flag = false, //TODO: add timeout for ready state
                else => return DriverError.INVALID_RESPONSE,
            }
        }
        fn get_cmd_data_type(self: *Self, aux_buffer: []const u8) DriverError!void {
            var result: ?usize = null;
            for (0..COMMAND_DATA_TYPES.len) |COMMAND| {
                result = std.mem.indexOf(u8, aux_buffer, COMMAND_DATA_TYPES[COMMAND]);
                if (result) |_| {
                    try self.read_cmd_data(COMMAND, aux_buffer);
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
                3 => try self.WiFi_get_STA_info(aux_buffer),
                else => {
                    return DriverError.INVALID_RESPONSE;
                },
            }
        }
        fn command_response(self: *Self, state: CommandResults) DriverError!void {
            const cmd_result = self.event_aux_buffer.get() catch return DriverError.AUX_BUFFER_EMPTY;
            //delete pkg if send fail
            if (state == .Error) {
                if (cmd_result == .NETWORK_SEND) {
                    _ = self.Network_pool.get() catch return DriverError.NETWORK_BUFFER_EMPTY; //TODO: generate event "SendDataFail" to avoid memory leaks
                    self.busy_flag = false;
                }
            }
            if (self.on_cmd_response) |callback| {
                callback(state, cmd_result, self.internal_user_data);
            }
        }

        fn wifi_response(self: *Self, aux_buffer: []const u8) DriverError!void {
            var inner_buffer: [50]u8 = .{0} ** 50;
            var index: usize = 0;
            var result: ?usize = null;
            var tx_event: ?WifiEvent = null;
            for (WIFI_RESPOSE_TOKEN) |TOKEN| {
                result = std.mem.indexOf(u8, aux_buffer, TOKEN);
                if (result != null) {
                    break;
                }
                index += 1;
            }
            switch (index) {
                0 => {
                    tx_event = WifiEvent.WiFi_AP_DISCONNECTED;
                    self.Wifi_state = .DISCONECTED;
                },
                1 => tx_event = WifiEvent.WiFi_CON_START,
                2 => {
                    self.busy_flag = false;
                    tx_event = WifiEvent.WiFi_AP_CONNECTED;
                    _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}?{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_IP)], postfix }) catch return;
                    self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer }) catch return DriverError.TX_BUFFER_FULL;
                    self.event_aux_buffer.push(commands_enum.NETWORK_IP) catch return DriverError.TASK_BUFFER_FULL;
                },
                else => {
                    return DriverError.INVALID_RESPONSE;
                },
            }
            if (tx_event) |event| {
                if (self.on_STA_event) |callback| {
                    callback(event, self.internal_user_data);
                }
            }
        }

        //ADD more WiFi events
        fn WiFi_get_AP_info(self: *Self) DriverError!void {
            var data: u8 = 0;
            var aux_buffer: Circular_buffer.create_buffer(u8, 50) = .{};
            while (data != '\n') {
                data = self.RX_buffer.get() catch {
                    self.RX_callback_handler(&self.RX_buffer);
                    continue;
                };
                aux_buffer.push(data) catch return DriverError.TASK_BUFFER_FULL;
            }
            const inner_buffer = aux_buffer.raw_buffer();
            const nettype = inner_buffer[0];
            const ip_flag = nettype == 'i';
            const out_pointer: *[16]u8 = switch (nettype) {
                'i' => &self.network_AP_ip,
                'g' => &self.network_AP_gateway,
                'n' => &self.network_AP_mask,
                else => {
                    return DriverError.INVALID_RESPONSE;
                },
            };
            const data_start_index = std.mem.indexOf(u8, inner_buffer, ":");
            if (data_start_index) |bindex| {
                const data_slice = inner_buffer[(bindex + 2)..];
                const data_end_index = std.mem.indexOf(u8, data_slice, "\"");
                if (data_end_index) |eindex| {
                    const net_data = data_slice[0..eindex];
                    if (net_data.len < out_pointer.len) {
                        std.mem.copyForwards(u8, out_pointer, net_data);
                        if (ip_flag) {
                            self.Wifi_state = .CONNECTED;
                            if (self.on_STA_event) |callback| {
                                callback(WifiEvent.WiFi_AP_GOT_IP, self.internal_user_data);
                            }
                        }
                    }
                }
            } else {
                return DriverError.INVALID_RESPONSE;
            }
        }

        fn WiFi_error(self: *Self) DriverError!void {
            self.busy_flag = false;
            if (self.on_STA_event) |callback| {
                const error_id: u8 = self.RX_buffer.get() catch {
                    return DriverError.INVALID_RESPONSE;
                };
                switch (error_id) {
                    '1' => callback(WifiEvent.WiFi_ERROR_TIMEOUT, self.internal_user_data),
                    '2' => callback(WifiEvent.WiFi_ERROR_PASSWORD, self.internal_user_data),
                    '3' => callback(WifiEvent.WiFi_ERROR_INVALID_AP, self.internal_user_data),
                    '4' => callback(WifiEvent.WiFi_ERROR_CONN_FAIL, self.internal_user_data),
                    else => callback(WifiEvent.WiFi_ERROR_UNKNOWN, self.internal_user_data),
                }
            }
        }

        fn WiFi_get_STA_info(self: *Self, aux_buffer: []const u8) DriverError!void {
            var result: ?usize = null;
            var info_buf: [20]u8 = .{0} ** 20;
            var sta_event = WifiEvent.WiFi_ERROR_UNKNOWN;
            if (self.on_AP_event) |callback| {
                for (0..WIFI_RESPOSE_TOKEN.len) |index| {
                    result = std.mem.indexOf(u8, aux_buffer, WIFI_RESPOSE_TOKEN[index]);
                    if (result) |_| {
                        switch (index) {
                            0 => {
                                try self.get_STA_mac(&info_buf);
                                sta_event = .WiFi_STA_DISCONNECTED;
                            },
                            1 => {
                                try self.get_STA_mac(&info_buf);
                                sta_event = .WiFi_STA_CONNECTED;
                            },
                            2 => {
                                try self.get_STA_ip(&info_buf);
                                sta_event = .WIFi_STA_GOT_IP;
                            },
                            else => return DriverError.UNKNOWN_ERROR,
                        }
                        callback(sta_event, &info_buf, self.internal_user_data);
                        return;
                    }
                }
            }
        }

        fn get_STA_mac(self: *Self, out_buf: []u8) DriverError!void {
            try self.wait_for_bytes(19);
            var aux_buffer: Circular_buffer.create_buffer(u8, 50) = .{};
            var data: u8 = 0;
            while (data != '\n') {
                data = self.RX_buffer.get() catch {
                    return DriverError.UNKNOWN_ERROR;
                };
                aux_buffer.push(data) catch return DriverError.AUX_BUFFER_FULL;
            }
            const buffer_len = aux_buffer.get_data_size() - 3;
            const mac_slice = aux_buffer.raw_buffer()[1..buffer_len];
            std.mem.copyForwards(u8, out_buf, mac_slice);
        }

        fn get_STA_ip(self: *Self, out_buf: []u8) DriverError!void {
            try self.wait_for_bytes(33);
            var aux_buffer: Circular_buffer.create_buffer(u8, 50) = .{};
            var data: u8 = 0;
            while (data != '\n') {
                data = self.RX_buffer.get() catch {
                    return DriverError.UNKNOWN_ERROR;
                };
                aux_buffer.push(data) catch return DriverError.AUX_BUFFER_FULL;
            }
            const buffer_len = aux_buffer.get_data_size() - 3;
            const ip_slice = aux_buffer.raw_buffer()[21..buffer_len];
            std.mem.copyForwards(u8, out_buf, ip_slice);
        }

        fn wait_for_bytes(self: *Self, data_len: usize) DriverError!void {
            var time: usize = time_out;
            var RX_data_len = self.RX_buffer.get_data_size();
            while (time > 0) : (time -= 1) {
                self.RX_callback_handler(&self.RX_buffer);
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
                    self.RX_callback_handler(&self.RX_buffer);
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

        //TODO: ADD ERROR CHECK on invalid input
        //TODO: clear all Network pkgs on connection close event
        //TODO: separe network event in two functions
        fn network_event(self: *Self, state: NetworkHandlerState, aux_buffer: []const u8) DriverError!void {
            const id_index = std.mem.indexOf(u8, aux_buffer, ",");
            if (id_index) |id| {
                const index: usize = aux_buffer[id - 1] - '0';
                if (index > self.Network_binds.len) return DriverError.INVALID_RESPONSE;

                if (self.Network_binds[index]) |*bd| {
                    bd.state = state;
                    if (bd.event_callback) |callback| {
                        const client_event: NetworkEvent = switch (state) {
                            .Closed => NetworkEvent.Closed,
                            .Connected => NetworkEvent.Connected,
                            .None => return,
                        };
                        const client = Client{
                            .id = @intCast(index),
                            .event = client_event,
                            .driver = self,
                            .rev = null,
                        };
                        callback(client, bd.user_data);
                    }
                }
            } else {
                return DriverError.INVALID_RESPONSE;
            }
        }

        fn network_send_event(self: *Self, aux_buffer: []const u8) DriverError!void {
            self.busy_flag = false;
            var result: ?usize = null;
            for (0..SEND_RESPONSE_TOKEN.len) |index| {
                result = std.mem.indexOf(u8, aux_buffer, SEND_RESPONSE_TOKEN[index]);
                if (result) |_| {
                    try self.network_send_resposnse(index);
                }
                return;
            }
            return DriverError.INVALID_RESPONSE;
        }

        fn network_send_resposnse(self: *Self, response_id: usize) DriverError!void {
            const to_free = self.Network_pool.get() catch return DriverError.NETWORK_BUFFER_EMPTY;
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
            const pkg = self.Network_pool.peek_at(self.Network_pool.get_begin_index()) catch return DriverError.NETWORK_BUFFER_EMPTY;
            if (pkg.data) |data| {
                self.TX_callback_handler(data);
            }
        }

        pub fn process(self: *Self) DriverError!void {
            switch (self.machine_state) {
                .init => {
                    self.init_driver() catch return;
                },
                .IDLE => {
                    try self.IDLE_REV();
                    self.IDLE_TRANS();
                },
            }
        }

        fn IDLE_REV(self: *Self) DriverError!void {
            var data: u8 = 0;
            var RX_aux_buffer: Circular_buffer.create_buffer(u8, 50) = .{};
            self.RX_callback_handler(&self.RX_buffer);
            while (true) {
                data = self.RX_buffer.get() catch break;
                switch (data) {
                    '\n' => {
                        if (RX_aux_buffer.get_data_size() >= 3) {
                            try self.get_cmd_type(RX_aux_buffer.raw_buffer());
                        }
                        RX_aux_buffer.clear();
                        return;
                    },
                    ':' => {
                        try self.get_cmd_data_type(RX_aux_buffer.raw_buffer());
                        RX_aux_buffer.clear();
                        return;
                    },
                    '>' => {
                        try self.network_send_data();
                        RX_aux_buffer.clear();
                        return;
                    },
                    else => RX_aux_buffer.push_overwrite(data),
                }
            }
        }

        fn IDLE_TRANS(self: *Self) void {
            if (self.busy_flag) {
                return;
            }
            const next_cmd = self.TX_buffer.get() catch return;
            self.busy_flag = next_cmd.busy;
            self.TX_callback_handler(&next_cmd.cmd_data);
        }

        //TODO; make a event pool just to init commands
        pub fn init_driver(self: *Self) !void {
            //clear buffers
            self.deinit_driver();
            self.RX_buffer.clear();
            self.TX_buffer.clear();
            self.event_aux_buffer.clear();
            var inner_buffer: [50]u8 = std.mem.zeroes([50]u8);

            //send dummy cmd to clear the TX buffer

            _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}", .{ COMMANDS_TOKENS[@intFromEnum(commands_enum.DUMMY)], postfix }) catch return DriverError.INVALID_ARGS;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .busy = false }) catch return DriverError.TX_BUFFER_FULL;
            self.event_aux_buffer.push(commands_enum.DUMMY) catch return DriverError.TASK_BUFFER_FULL;

            //send RST request
            _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.RESET)], postfix }) catch return DriverError.INVALID_ARGS;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .busy = true }) catch return DriverError.TX_BUFFER_FULL;
            self.event_aux_buffer.push(commands_enum.RESET) catch return DriverError.TASK_BUFFER_FULL;

            //clear aux buffer
            inner_buffer = std.mem.zeroes([50]u8);

            //desable ECHO
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}", .{ COMMANDS_TOKENS[@intFromEnum(commands_enum.ECHO_OFF)], postfix });
            try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer });
            try self.event_aux_buffer.push(commands_enum.ECHO_OFF);

            //enable multi-conn
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=1{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.IP_MUX)], postfix });
            try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer });
            try self.event_aux_buffer.push(commands_enum.IP_MUX);

            //set WiFi to STA and AP
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}={d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_SET_MODE)], @intFromEnum(Wifi_mode), postfix });
            try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer });
            try self.event_aux_buffer.push(commands_enum.WIFI_SET_MODE);

            //disable wifi auto connection
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=0{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_AUTOCONN)], postfix });
            try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer });
            try self.event_aux_buffer.push(commands_enum.WIFI_AUTOCONN);

            if (network_type == NetworkDriveType.SERVER_CLIENT) {
                //configure server to MAX connections to 3
                _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=3{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SERVER_CONF)], postfix });
                try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer });
                try self.event_aux_buffer.push(commands_enum.NETWORK_SERVER_CONF);
            }
            self.machine_state = Drive_states.IDLE;
        }

        //TODO: send reaming network pkgs with "SendDataFail" event for avoid memory leaks
        pub fn deinit_driver(self: *Self) void {
            while (true) {
                _ = self.Network_pool.get() catch {
                    break;
                };
            }
        }

        //TODO: deinit all data here
        pub fn reset(self: *Self) DriverError!void {
            self.machine_state = .init;
        }

        //TODO: add more config
        pub fn WiFi_connect_AP(self: *Self, ssid: []const u8, password: []const u8) DriverError!void {
            if (Wifi_type == WiFiDriverType.AP) {
                return DriverError.STA_OFF;
            } else if (Wifi_type == WiFiDriverType.NONE) {
                return DriverError.WIFI_OFF;
            }
            const pwd_len = password.len;
            if ((pwd_len > 0) and (pwd_len < 5)) return DriverError.INVALID_ARGS;

            var inner_buffer: [50]u8 = .{0} ** 50;
            _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}=\"{s}\",\"{s}\"{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_CONNECT)], ssid, password, postfix }) catch return;
            self.event_aux_buffer.push(commands_enum.WIFI_CONNECT) catch return;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .busy = true }) catch return;
        }

        //TODO: add optinal args
        pub fn WiFi_config_AP(self: *Self, ssid: []const u8, password: []const u8, channel: u8, ecn: WiFi_encryption) !void {
            if (Wifi_type == WiFiDriverType.STA) {
                return DriverError.AP_OFF;
            } else if (Wifi_type == WiFiDriverType.NONE) {
                return DriverError.WIFI_OFF;
            }
            if (ssid.len == 0) return DriverError.INVALID_ARGS;
            if ((ecn != .OPEN) and (password.len < 8)) return DriverError.INVALID_ARGS;
            var inner_buffer: [50]u8 = .{0} ** 50;
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=\"{s}\",\"{s}\",{d},{d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_CONF)], ssid, password, channel, @intFromEnum(ecn), postfix });
            try self.event_aux_buffer.push(commands_enum.WIFI_CONF);
            try self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer });
        }

        pub fn bind(self: *Self, net_type: NetworkHandlerType, event_callback: ServerCallback, user_data: ?*anyopaque) DriverError!u8 {
            const start_bind = div_binds;

            for (start_bind..self.Network_binds.len) |index| {
                if (self.Network_binds[index]) |_| {
                    continue;
                } else {
                    const id: u8 = @intCast(index);
                    const new_bind: network_handler = .{
                        .descriptor_id = id,
                        .NetworkHandlerType = net_type,
                        .event_callback = event_callback,
                        .user_data = user_data,
                    };
                    self.Network_binds[index] = new_bind;
                    return id;
                }
            }
            return DriverError.MAX_BINDS;
        }

        //TODO: ADD IPv6
        pub fn connect(self: *Self, id: u8, host: []const u8, port: u16) DriverError!void {
            if (self.busy_flag) return DriverError.BUSY;
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
                _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}={d},\"{s}\",\"{s}\",{d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_CONNECT)], id, net_type, host, port, postfix }) catch return DriverError.INVALID_ARGS;
                self.event_aux_buffer.push(commands_enum.NETWORK_CONNECT) catch return DriverError.TASK_BUFFER_FULL;
                self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer }) catch return DriverError.TX_BUFFER_FULL;
            } else {
                return DriverError.INVALID_BIND;
            }
        }

        //TODO: add error checking for invalid closed erros
        pub fn close(self: *Self, id: u8) DriverError!void {
            var inner_buffer: [50]u8 = .{0} ** 50;
            _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}={d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_CLOSE)], id, postfix }) catch return DriverError.INVALID_ARGS;
            self.event_aux_buffer.push(commands_enum.NETWORK_CLOSE) catch return DriverError.TASK_BUFFER_FULL;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer }) catch return DriverError.TX_BUFFER_FULL;
        }

        //TODO: add server type param (TCP, TCP6, SSL, SSL6)
        //TODO: Notify when the server is actually created
        pub fn create_server(self: *Self, port: u16, server_type: NetworkHandlerType, event_callback: ServerCallback, user_data: ?*anyopaque) DriverError!void {
            const end_bind = div_binds;
            var inner_buffer: [50]u8 = .{0} ** 50;

            const net_type: []const u8 = switch (server_type) {
                .SSL => "SSL",
                .TCP => "TCP",
                else => return DriverError.INVALID_ARGS,
            };

            if (self.busy_flag) return DriverError.BUSY;

            if (network_type == NetworkDriveType.CLIENT_ONLY) return DriverError.SERVER_OFF;

            _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}=1,{d},\"{s}\"{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SERVER)], port, net_type, postfix }) catch return DriverError.INVALID_ARGS;
            self.event_aux_buffer.push(commands_enum.NETWORK_SERVER) catch return DriverError.TASK_BUFFER_FULL;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer }) catch return DriverError.TX_BUFFER_FULL;
            for (0..end_bind) |id| {
                self.Network_binds[id] = network_handler{
                    .descriptor_id = @intCast(id),
                    .NetworkHandlerType = NetworkHandlerType.TCP,
                    .event_callback = event_callback,
                    .user_data = user_data,
                };
            }
        }

        //TODO: wait for commands respose for delete data from pool to avois deadlocks (also generate "SendDataFail" event for avoid memory leaks)
        pub fn delete_server(self: *Self) DriverError!void {
            var inner_buffer: [50]u8 = .{0} ** 50;
            const end_bind = div_binds;

            //send close server command
            _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}=0,1{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SERVER)], postfix }) catch unreachable;
            self.event_aux_buffer.push(commands_enum.NETWORK_SERVER) catch DriverError.TASK_BUFFER_FULL;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer }) catch DriverError.TX_BUFFER_FULL;

            //clear all server binds
            for (0..end_bind) |id| {
                self.Network_binds[id] = null;
            }

            //clear all server pkgs
            const pool_size = self.Network_pool.get_data_size();
            for (0..pool_size) |_| {
                const pkg = self.Network_pool.get() catch break;
                if (pkg.descriptor_id < end_bind) {
                    continue;
                } else {
                    self.Network_pool.push(pkg);
                }
            }
        }

        //TODO: add error check
        //TODO: break data bigger than 2048 into multi 2048 pkgs
        //TODO: delete events from pool in case of erros
        pub fn send(self: *Self, id: u8, data: []u8) DriverError!void {
            const free_events = self.event_aux_buffer.len - self.event_aux_buffer.get_data_size();
            const free_TX_cmd = self.TX_buffer.len - self.TX_buffer.get_data_size();
            if ((free_events < 4) or (free_TX_cmd < 2)) return DriverError.BUSY; //keep some space to other commands
            var inner_buffer: [50]u8 = .{0} ** 50;

            const pkg = NetworkPackage{
                .data = data,
                .descriptor_id = id,
            };
            self.Network_pool.push(pkg) catch {
                return DriverError.NETWORK_BUFFER_FULL;
            };

            _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}={d},{d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SEND)], id, data.len, postfix }) catch return DriverError.INVALID_ARGS;
            self.event_aux_buffer.push(commands_enum.NETWORK_SEND) catch return DriverError.TASK_BUFFER_FULL;
            self.TX_buffer.push(TXEventPkg{ .cmd_data = inner_buffer, .busy = true }) catch return DriverError.TX_BUFFER_FULL;
        }

        pub fn get_AP_ip(self: *Self) []u8 {
            return &self.network_AP_ip;
        }

        //TODO: add more config param
        pub fn new(txcallback: anytype, rxcallback: anytype) Self {
            //const ATdrive = create_drive(buffer_size);
            return .{ .RX_callback_handler = rxcallback, .TX_callback_handler = txcallback };
        }
    };
}
