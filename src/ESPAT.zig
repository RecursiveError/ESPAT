const std = @import("std");
pub const Circular_buffer = @import("util/circular_buffer.zig");

//TODO: add more error types
pub const NetworkError = error{ MAX_BINDS, ALLOC_ERROR, NULL_BIND, INVALID_TYPE };
pub const DriverErros = error{
    WIFI_OFF,
    BUSY,
    AP_OFF,
    STA_OFF,
    SERVER_DISLABE,
    SERVER_OFF,
    CLIENT_DISABLE,
    CLIENT_DISCONNECTED,
    BUFFER_FULL,
};
pub const NetworkDriveType = enum {
    SERVER_ONLY,
    CLIENT_ONLY,
    SERVER_CLIENT,
};

pub const WiFiDriverType = enum { NONE, STA, AP, AP_STA };

pub const Drive_states = enum {
    init,
    WiFiinit,
    IDLE,
};

pub const WiFi_encryption = enum {
    OPEN,
    WPA_PSK,
    WPA2_PSK,
    WPA_WPA2_PSK,
};

pub const commands_enum = enum(u8) {
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
};

//This is not necessary since the user cannot send commands directly
pub const COMMANDS_TOKENS = [_][]const u8{
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
    "CON",
    "CLO",
};
pub const COMMAND_DATA_TYPES = [_][]const u8{
    "IPD",
    "CIPSTA",
    "CWJAP",
};

pub const CommandResults = enum(u8) { Ok, Error };

pub const WIFI_RESPOSE_TOKEN = [_][]const u8{
    "DIS",
    "CON",
    "GOT",
};

pub const WifiEvent = enum(u8) {
    WiFi_CON_START,
    WiFi_DISCONNECTED,
    WiFi_CONNECTED,
    WiFi_GOT_IP,
    WiFi_ERROR_TIMEOUT,
    WiFi_ERROR_PASSWORD,
    WiFi_ERROR_INVALID_AP,
    WiFi_ERROR_CONN_FAIL,
    WiFi_ERROR_UNKNOWN,
};

pub const NetworkEvent = enum {
    Connected,
    Closed,
    ReciveData,
    SendDataComplete,
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

//TODO: add more config
//TODO: delete server
//TODO: add Restart driver
//TODO: add eneble_IPv6 func
pub fn create_drive(comptime RX_SIZE: comptime_int, comptime network_pool_size: comptime_int, comptime Wifi_type: WiFiDriverType, comptime network_type: NetworkDriveType) type {
    if (RX_SIZE <= 50) @compileError("RX SIZE CANNOT BE LESS THAN 50 byte");
    if (network_pool_size <= 5) @compileError(" NETWORK POOL SIZE CANNOT BE LESS THAN 5 events");
    return struct {

        // data types
        const Self = @This();
        pub const Client = struct {
            id: u8,
            driver: *Self,
            event: NetworkEvent,
            rev: ?[]const u8 = null,

            pub fn send(self: *const Client, data: []const u8) !void {
                try self.driver.send(self.id, data);
            }

            pub fn close(self: *const Client) !void {
                try self.driver.close(self.id);
            }
        };

        pub const network_handler = struct {
            descriptor_id: u8 = 255,
            state: NetworkHandlerState = .None,
            NetworkHandlerType: NetworkHandlerType = .None,
            event_callback: ?*const fn (client: Client) void = null,
        };

        pub const NetworkPackage = struct { descriptor_id: u8 = 255, data: ?[]u8 = null };
        const buffer_type = Circular_buffer.create_buffer(u8, RX_SIZE);
        const Wifi_mode = Wifi_type;
        pub const RX_buffer_type = *buffer_type;
        pub const TX_callback = *const fn (data: []const u8) void;
        pub const RX_callback = *const fn (data: RX_buffer_type) void;

        //internal alloc
        inner_alloc: std.mem.Allocator = undefined,
        //internal control data, (Do not modify)
        TX_buffer: Circular_buffer.create_buffer([50]u8, 25) = .{},
        RX_buffer: buffer_type = .{},
        TX_callback_handler: TX_callback,
        RX_callback_handler: RX_callback,
        machine_state: Drive_states = .init,
        RX_aux_buffer: Circular_buffer.create_buffer(u8, 50) = .{},
        event_aux_buffer: Circular_buffer.create_buffer(commands_enum, 10) = .{},
        busy_flag: bool = false,

        WiFi_AP_SSID: ?[]const u8 = null,
        WiFi_AP_PASSWORD: ?[]const u8 = null,

        //network data
        Network_binds: [5]?network_handler = .{ null, null, null, null, null },
        Network_pool: Circular_buffer.create_buffer(NetworkPackage, network_pool_size) = .{},
        NetWork_get_remain_data: usize = 0,
        NetWork_push_remain_data: usize = 0,
        NetWork_id: usize = 0,
        network_AP_ip: [16]u8 = .{0} ** 16,
        network_AP_gateway: [16]u8 = .{0} ** 16,
        network_AP_mask: [16]u8 = .{0} ** 16,

        //callback handlers
        //TODO: User event callbacks
        on_cmd_response: ?*const fn (result: CommandResults, cmd: commands_enum) void = null,
        on_WiFi_respnse: ?*const fn (event: WifiEvent) void = null,

        fn get_cmd_type(self: *Self) void {
            var result: ?usize = null;
            const RX_aux_buffer = self.RX_aux_buffer.raw_buffer();
            const cmd_len = COMMANDS_RESPOSES_TOKENS.len;
            for (0..cmd_len) |COMMAND| {
                result = std.mem.indexOf(u8, RX_aux_buffer, COMMANDS_RESPOSES_TOKENS[COMMAND]);
                if (result) |index| {
                    self.exec_cmd(COMMAND, index);
                }
            }
        }

        fn exec_cmd(self: *Self, cmd_id: usize, buffer_index: usize) void {
            _ = buffer_index;
            switch (cmd_id) {
                0 => self.command_response(CommandResults.Ok),
                1 => self.command_response(CommandResults.Error),
                2 => self.wifi_response(),
                3 => self.network_event(NetworkHandlerState.Connected),
                4 => self.network_event(NetworkHandlerState.Closed),
                else => unreachable,
            }
            self.RX_aux_buffer.clear();
        }

        //TODO: remove external use of RX_aux_buffer, recive a slice insted
        fn get_cmd_data_type(self: *Self) void {
            var result: ?usize = null;
            const RX_aux_buffer = self.RX_aux_buffer.raw_buffer();
            for (0..COMMAND_DATA_TYPES.len) |COMMAND| {
                result = std.mem.indexOf(u8, RX_aux_buffer, COMMAND_DATA_TYPES[COMMAND]);
                if (result) |index| {
                    self.read_cmd_data(COMMAND, index);
                }
            }
        }

        //TODO: ADD more responses
        fn read_cmd_data(self: *Self, cmd_id: usize, buffer_index: usize) void {
            switch (cmd_id) {
                0 => self.parse_network_data(buffer_index),
                1 => self.WiFi_get_AP_info(),
                2 => self.WiFi_error(),
                else => {},
            }
            self.RX_aux_buffer.clear();
        }
        fn command_response(self: *Self, state: CommandResults) void {
            const cmd_result = self.event_aux_buffer.get() catch return;
            if (self.on_cmd_response) |callback| {
                callback(state, cmd_result);
            }
        }

        //TODO: add error check on invalid input
        fn wifi_response(self: *Self) void {
            self.busy_flag = false;
            var inner_buffer: [50]u8 = std.mem.zeroes([50]u8);
            const wifi_buffer = self.RX_aux_buffer.raw_buffer();
            var index: usize = 0;
            var result: ?usize = null;
            var tx_event: ?WifiEvent = null;
            for (WIFI_RESPOSE_TOKEN) |TOKEN| {
                result = std.mem.indexOf(u8, wifi_buffer, TOKEN);
                if (result != null) {
                    break;
                }
                index += 1;
            }
            switch (index) {
                0 => tx_event = WifiEvent.WiFi_DISCONNECTED,
                1 => tx_event = WifiEvent.WiFi_CON_START,
                2 => {
                    tx_event = WifiEvent.WiFi_CONNECTED;
                    _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}?{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_IP)], postfix }) catch return;
                    self.TX_buffer.push(inner_buffer) catch return;
                    self.event_aux_buffer.push(commands_enum.NETWORK_IP) catch return;
                },
                else => {
                    return;
                },
            }
            if (tx_event) |event| {
                if (self.on_WiFi_respnse) |callback| {
                    callback(event);
                }
            }
        }

        //ADD more WiFi events
        fn WiFi_get_AP_info(self: *Self) void {
            self.RX_aux_buffer.clear();
            var data: u8 = 0;
            while (data != '\n') {
                data = self.RX_buffer.get() catch {
                    self.RX_callback_handler(&self.RX_buffer);
                    continue;
                };
                self.RX_aux_buffer.push(data) catch return;
            }
            const inner_buffer = self.RX_aux_buffer.raw_buffer();
            const nettype = inner_buffer[0];
            const ip_flag = nettype == 'i';
            const out_pointer: *[16]u8 = switch (nettype) {
                'i' => &self.network_AP_ip,
                'g' => &self.network_AP_gateway,
                'n' => &self.network_AP_mask,
                else => {
                    return;
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
                            if (self.on_WiFi_respnse) |callback| {
                                callback(WifiEvent.WiFi_GOT_IP);
                            }
                        }
                    }
                }
            }
        }

        fn WiFi_error(self: *Self) void {
            if (self.busy_flag) self.busy_flag = false;
            if (self.on_WiFi_respnse) |callback| {
                const error_id: u8 = self.RX_buffer.get() catch {
                    callback(WifiEvent.WiFi_ERROR_UNKNOWN);
                    return;
                };
                switch (error_id) {
                    '1' => callback(WifiEvent.WiFi_ERROR_TIMEOUT),
                    '2' => callback(WifiEvent.WiFi_ERROR_PASSWORD),
                    '3' => callback(WifiEvent.WiFi_ERROR_INVALID_AP),
                    '4' => callback(WifiEvent.WiFi_ERROR_CONN_FAIL),
                    else => callback(WifiEvent.WiFi_ERROR_UNKNOWN),
                }
            }
        }

        //TODO: add error check on invalid input
        fn parse_network_data(self: *Self, start_index: usize) void {
            const data_buffer = self.RX_aux_buffer.raw_buffer();
            var slices = std.mem.split(u8, data_buffer[start_index..], ",");
            _ = slices.next();

            //TODO: add error checking
            const id = std.fmt.parseInt(usize, slices.next().?, 10) catch return;
            const temp_slice = slices.next().?;
            var end_index: usize = 0;
            for (temp_slice) |ch| {
                if ((ch >= '0') and ch <= '9') {
                    end_index += 1;
                }
            }

            const remain_data = std.fmt.parseInt(usize, temp_slice[0..end_index], 10) catch return;
            self.read_network_data(id, remain_data);
        }

        //TODO: add timeout
        fn read_network_data(self: *Self, id: usize, to_recive: usize) void {
            var remain = to_recive;
            var index: usize = 0;
            var data: u8 = 0;
            var rev = self.inner_alloc.alloc(u8, to_recive) catch return;
            defer self.inner_alloc.free(rev);
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
                        .rev = rev,
                    };
                    callback(client);
                }
            }
            self.machine_state = Drive_states.IDLE;
        }

        //TODO: ADD ERROR CHECK on invalid input
        fn network_event(self: *Self, state: NetworkHandlerState) void {
            const buffer = self.RX_aux_buffer.raw_buffer();
            const id_index = std.mem.indexOf(u8, buffer, ",");
            if (id_index) |id| {
                const index: usize = buffer[id - 1] - '0';
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
                        callback(client);
                    }
                }
            }
        }

        fn network_send_data(self: *Self) void {
            const pkg = self.Network_pool.get() catch return;
            const id = pkg.descriptor_id;
            if (pkg.data) |data| {
                self.TX_callback_handler(data);
                self.inner_alloc.free(data);
                if (self.Network_binds[id]) |bd| {
                    if (bd.event_callback) |callback| {
                        const client = Client{
                            .id = id,
                            .driver = self,
                            .event = .SendDataComplete,
                            .rev = null,
                        };
                        callback(client);
                    }
                }
            }
        }

        //TODO: ADD error returns
        //TODO: block TX on Busy
        //TODO: ADD MORE AT commands
        //TODO: Fix deadlock on WiFi connect error
        pub fn process(self: *Self) void {
            self.RX_callback_handler(&self.RX_buffer);

            switch (self.machine_state) {
                .init => {
                    self.init_driver() catch return;
                    self.machine_state = Drive_states.WiFiinit;
                },
                .WiFiinit => {
                    if (Wifi_type != WiFiDriverType.AP) {
                        self.innerWiFi_connect();
                    }
                    //go to IDLE mode
                    self.machine_state = Drive_states.IDLE;
                },
                .IDLE => {
                    self.IDLE_REV();
                    self.IDLE_TRANS();
                },
            }
        }

        fn IDLE_REV(self: *Self) void {
            var data: u8 = 0;
            while (true) {
                data = self.RX_buffer.get() catch break;
                if (data == '\n') {
                    if (self.RX_aux_buffer.get_data_size() >= 3) {
                        self.get_cmd_type();
                    }
                    self.RX_aux_buffer.clear();
                    return;
                } else if (data == ':') {
                    if (self.RX_aux_buffer.get_data_size() > 3) {
                        self.get_cmd_data_type();
                    }
                    self.RX_aux_buffer.clear();
                    return;
                } else if (data == '>') {
                    self.network_send_data();
                    self.RX_aux_buffer.clear();
                    return;
                }
                self.RX_aux_buffer.push_overwrite(data);
            }
        }

        fn IDLE_TRANS(self: *Self) void {
            const next_cmd = self.TX_buffer.get() catch return;
            self.TX_callback_handler(&next_cmd);
        }

        fn init_driver(self: *Self) !void {
            var inner_buffer: [50]u8 = std.mem.zeroes([50]u8);
            //clear buffers
            self.TX_buffer.clear();
            self.RX_buffer.clear();
            self.RX_aux_buffer.clear();
            self.event_aux_buffer.clear();

            //desable ECHO
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}", .{ COMMANDS_TOKENS[@intFromEnum(commands_enum.ECHO_OFF)], postfix });
            try self.TX_buffer.push(inner_buffer);
            try self.event_aux_buffer.push(commands_enum.ECHO_OFF);

            //enable multi-conn
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=1{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.IP_MUX)], postfix });
            try self.TX_buffer.push(inner_buffer);
            try self.event_aux_buffer.push(commands_enum.IP_MUX);

            //set WiFi to STA and AP
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}={d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_SET_MODE)], @intFromEnum(Wifi_mode), postfix });
            try self.TX_buffer.push(inner_buffer);
            try self.event_aux_buffer.push(commands_enum.WIFI_SET_MODE);

            //disable wifi auto connection
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=0{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_AUTOCONN)], postfix });
            try self.TX_buffer.push(inner_buffer);
            try self.event_aux_buffer.push(commands_enum.WIFI_AUTOCONN);

            if (network_type == NetworkDriveType.SERVER_CLIENT) {
                //configure server to MAX connections to 3
                _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=3{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SERVER_CONF)], postfix });
                try self.TX_buffer.push(inner_buffer);
                try self.event_aux_buffer.push(commands_enum.NETWORK_SERVER_CONF);
            }
        }

        pub fn deinit_driver(self: *Self) void {
            while (true) {
                const data = self.Network_pool.get() catch {
                    break;
                };
                if (data.data) |to_free| self.inner_alloc.free(to_free);
            }
        }
        fn innerWiFi_connect(self: *Self) void {
            if (self.WiFi_AP_SSID) |ssid| {
                var password: []const u8 = "\"\"";
                if (self.WiFi_AP_PASSWORD) |pass| {
                    password = pass;
                }
                var inner_buffer: [50]u8 = .{0} ** 50;
                _ = std.fmt.bufPrint(&inner_buffer, "{s}{s}=\"{s}\",\"{s}\"{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_CONNECT)], ssid, password, postfix }) catch return;
                self.event_aux_buffer.push(commands_enum.WIFI_CONNECT) catch return;
                self.TX_buffer.push(inner_buffer) catch return;
                self.busy_flag = true;
            }
        }

        //TODO: ADD error check in WiFi name and password
        //TODO: add optinal args
        pub fn WiFi_connect_AP(self: *Self, ssid: []const u8, password: []const u8) !void {
            if (self.busy_flag) return DriverErros.BUSY;
            if (Wifi_type == WiFiDriverType.AP) {
                return DriverErros.STA_OFF;
            } else if (Wifi_type == WiFiDriverType.NONE) {
                return DriverErros.WIFI_OFF;
            }
            self.WiFi_AP_SSID = ssid;
            self.WiFi_AP_PASSWORD = password;
        }

        //TODO: ADD error check in WiFi name and password
        //TODO: add optinal args
        pub fn WiFi_config_AP(self: *Self, ssid: []const u8, password: []const u8, channel: u8, ecn: WiFi_encryption) !void {
            if (self.busy_flag) return DriverErros.BUSY;
            if (Wifi_type == WiFiDriverType.STA) {
                return DriverErros.AP_OFF;
            } else if (Wifi_type == WiFiDriverType.NONE) {
                return DriverErros.WIFI_OFF;
            }
            var inner_buffer: [50]u8 = .{0} ** 50;
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=\"{s}\",\"{s}\",{d},{d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.WIFI_CONF)], ssid, password, channel, @intFromEnum(ecn), postfix });
            try self.event_aux_buffer.push(commands_enum.WIFI_CONF);
            try self.TX_buffer.push(inner_buffer);
        }

        pub fn bind(self: *Self, net_type: NetworkHandlerType, event_callback: *const fn (client: Client) void) NetworkError!u8 {
            const start_bind: usize = switch (network_type) {
                .CLIENT_ONLY => 0,
                .SERVER_CLIENT => 3,
                .SERVER_ONLY => self.Network_binds.len,
            };

            for (start_bind..self.Network_binds.len) |index| {
                if (self.Network_binds[index]) |_| {
                    continue;
                } else {
                    const id: u8 = @intCast(index);
                    const new_bind: network_handler = .{
                        .descriptor_id = id,
                        .NetworkHandlerType = net_type,
                        .event_callback = event_callback,
                    };
                    self.Network_binds[index] = new_bind;
                    return id;
                }
            }
            return NetworkError.MAX_BINDS;
        }

        //TODO: ADD IPv6
        pub fn connect(self: *Self, id: u8, host: []const u8, port: u16) !void {
            if (self.busy_flag) return DriverErros.BUSY;
            if (id > self.Network_binds.len) return NetworkError.NULL_BIND;
            var inner_buffer: [50]u8 = .{0} ** 50;
            if (self.Network_binds[id]) |bd| {
                const net_type = switch (bd.NetworkHandlerType) {
                    .SSL => "SSL",
                    .TCP => "TCP",
                    .UDP => "UDP",
                    .None => {
                        return NetworkError.INVALID_TYPE;
                    },
                };
                _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}={d},\"{s}\",\"{s}\",{d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_CONNECT)], id, net_type, host, port, postfix });
                try self.event_aux_buffer.push(commands_enum.NETWORK_CONNECT);
                try self.TX_buffer.push(inner_buffer);
            } else {
                return NetworkError.NULL_BIND;
            }
        }

        pub fn close(self: *Self, id: u8) !void {
            var inner_buffer: [50]u8 = .{0} ** 50;
            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}={d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_CLOSE)], id, postfix });
            try self.event_aux_buffer.push(commands_enum.NETWORK_CLOSE);
            try self.TX_buffer.push(inner_buffer);
        }

        //TODO: add server type param (TCP, TCP6, SSL, SSL6)
        pub fn create_server(self: *Self, port: u16, event_callback: *const fn (client: Client) void) !void {
            if (self.busy_flag) return DriverErros.BUSY;
            var inner_buffer: [50]u8 = .{0} ** 50;
            if (network_type == NetworkDriveType.CLIENT_ONLY) return DriverErros.SERVER_OFF;

            const end_bind: usize = switch (network_type) {
                .SERVER_CLIENT => 3,
                .SERVER_ONLY => self.Network_binds.len,
                else => unreachable,
            };

            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}=1,{d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SERVER)], port, postfix });
            try self.event_aux_buffer.push(commands_enum.NETWORK_SERVER);
            try self.TX_buffer.push(inner_buffer);
            for (0..end_bind) |id| {
                self.Network_binds[id] = .{
                    .descriptor_id = @intCast(id),
                    .NetworkHandlerType = NetworkHandlerType.TCP,
                    .event_callback = event_callback,
                };
            }
        }

        //TODO: add error check
        pub fn send(self: *Self, id: u8, data: []const u8) !void {
            if (self.busy_flag) return DriverErros.BUSY;
            var inner_buffer: [50]u8 = .{0} ** 50;

            if (id > self.Network_binds.len) return NetworkError.NULL_BIND;
            const pkg_data = try self.inner_alloc.alloc(u8, data.len);
            @memcpy(pkg_data, data);
            const pkg = NetworkPackage{
                .data = pkg_data,
                .descriptor_id = id,
            };
            try self.Network_pool.push(pkg);
            try self.event_aux_buffer.push(commands_enum.NETWORK_CONNECT);

            _ = try std.fmt.bufPrint(&inner_buffer, "{s}{s}={d},{d}{s}", .{ prefix, COMMANDS_TOKENS[@intFromEnum(commands_enum.NETWORK_SEND)], id, data.len, postfix });
            try self.event_aux_buffer.push(commands_enum.NETWORK_SEND);
            try self.TX_buffer.push(inner_buffer);
        }

        pub fn get_AP_ip(self: *Self) []u8 {
            return &self.network_AP_ip;
        }

        //TODO: add more config param
        pub fn new(txcallback: anytype, rxcallback: anytype, alloc: std.mem.Allocator) Self {
            //const ATdrive = create_drive(buffer_size);
            return .{ .RX_callback_handler = rxcallback, .TX_callback_handler = txcallback, .inner_alloc = alloc };
        }
    };
}