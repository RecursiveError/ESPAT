const std = @import("std");

const Commands_util = @import("commands.zig");
const Commands = Commands_util.Commands;
const get_cmd_string = Commands_util.get_cmd_string;
const get_cmd_slice = Commands_util.get_cmd_slice;
const infix = Commands_util.infix;
const prefix = Commands_util.prefix;
const postfix = Commands_util.postfix;

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
    SendDataCancel: []const u8,
    SendDataOk: void,
    SendDataFail: void,
};

pub const RecvMode = enum(u1) {
    active,
    passive,
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

pub const NetworkSendPkg = struct {
    data: []const u8 = undefined,
};

pub const NetworkTCPConn = struct {
    keep_alive: u16 = 0,
};

pub const NetworkUDPModes = enum {
    Unchanged,
    Change_first,
    Change_all,
};

pub const NetworkUDPConn = struct {
    local_port: u16,
    mode: NetworkUDPModes = .Unchanged,
};
pub const NetWorkConnectType = union(enum) {
    tcp: NetworkTCPConn,
    ssl: NetworkTCPConn,
    udp: NetworkUDPConn,
};
pub const ConnectConfig = struct {
    recv_mode: RecvMode,
    remote_host: []const u8,
    remote_port: u16,
    local_ip: ?[]const u8 = null,
    timeout: ?u16 = null,
    config: NetWorkConnectType,
};

pub const ServerConfig = struct {
    recv_mode: RecvMode,
    callback: ClientCallback,
    user_data: ?*anyopaque,
    server_type: NetworkHandlerType,
    port: u16,
};

pub const NetworkPackageType = union(enum) {
    NetworkSendPkg: NetworkSendPkg,
    NetworkAcceptPkg: void,
    NetworkClosePkg: void,
    ConnectConfig: ConnectConfig,
};

pub const NetworkSendEvent = enum {
    ok,
    fail,
};

const SendMap = std.StaticStringMap(NetworkSendEvent).initComptime(.{
    .{ "OK", NetworkSendEvent.ok },
    .{ "FAIL", NetworkSendEvent.fail },
});

pub fn get_send_event(str: []const u8) !NetworkSendEvent {
    const event = SendMap.get(str);
    if (event) |data| {
        return data;
    }
    return error.EventNotFound;
}

pub fn set_tcp_config(out_buffer: []u8, id: usize, args: ConnectConfig, tcp_conf: NetworkTCPConn) ![]u8 {
    var cmd_slice: []const u8 = undefined;
    var cmd_size: usize = 0;
    cmd_slice = try std.fmt.bufPrint(out_buffer, "{s}{s}={d},\"TCP\",\"{s}\",{d},{d}", .{
        prefix,
        get_cmd_string(.NETWORK_CONNECT),
        id,
        args.remote_host,
        args.remote_port,
        tcp_conf.keep_alive,
    });
    cmd_size += cmd_slice.len;

    if (args.local_ip) |ip| {
        cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], ",\"{s}\"", .{ip});
        cmd_size += cmd_slice.len;
    } else {
        if (args.timeout != null) {
            cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], ",", .{});
            cmd_size += cmd_slice.len;
        }
    }
    if (args.timeout) |timeout| {
        cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], ",{d}", .{timeout});
        cmd_size += cmd_slice.len;
    }
    cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], "{s}", .{postfix});
    cmd_size += cmd_slice.len;

    return out_buffer[0..cmd_size];
}

pub fn set_udp_config(out_buffer: []u8, id: usize, args: ConnectConfig, udp_conf: NetworkUDPConn) ![]u8 {
    var cmd_slice: []const u8 = undefined;
    var cmd_size: usize = 0;
    cmd_slice = try std.fmt.bufPrint(out_buffer, "{s}{s}={d},\"UDP\",\"{s}\",{d},{d},{d}", .{
        prefix,
        get_cmd_string(.NETWORK_CONNECT),
        id,
        args.remote_host,
        args.remote_port,
        udp_conf.local_port,
        @intFromEnum(udp_conf.mode),
    });
    cmd_size = cmd_slice.len;

    if (args.local_ip) |ip| {
        cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], ",\"{s}\"", .{ip});
        cmd_size += cmd_slice.len;
    } else {
        if (args.timeout != null) {
            cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], ",", .{});
            cmd_size += cmd_slice.len;
        }
    }
    if (args.timeout) |timeout| {
        cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], ",{d}", .{timeout});
        cmd_size += cmd_slice.len;
    }
    cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], "{s}", .{postfix});
    cmd_size += cmd_slice.len;
    return out_buffer[0..cmd_size];
}

pub fn check_connect_config(config: ConnectConfig) !void {
    if (config.remote_host.len > 64) return error.InvalidHots;
    if (config.remote_port == 0) return error.InvalidRemotePort;
    switch (config.config) {
        .tcp, .ssl => |args| {
            if (args.keep_alive > 7200) return error.InvalidKeepAliveValue;
        },
        .udp => |args| {
            if (args.local_port == 0) return error.InvalidLocalPort;
            if ((config.recv_mode == .passive) and (args.mode != .Unchanged)) {
                std.log.warn("UDP Mode 1 and 2 has no effect with passive recv", .{});
            }
        },
    }

    if (config.timeout) |timeout| {
        if (timeout > 60000) return error.InvalidTimeout;
    }
}

const IpDataInfo = struct {
    remote_host: []const u8,
    remote_port: u16,
    start_index: usize,
};

pub const IpData = struct {
    id: usize,
    data_len: usize,
    data_info: ?IpDataInfo = null,
};

pub fn paser_ip_data(str: []const u8) !IpData {
    //no check to invalid size, this func is only call when "+IPD," get into the buffer
    var slices = std.mem.split(u8, str[5..], ",");
    const id_str = slices.next();
    const data_str = slices.next();
    const remote_host_str = slices.next();
    const remote_port_str = slices.next();

    if (id_str == null) return error.InvalidPkg;
    if (data_str == null) return error.InvalidPkg;

    const id = std.fmt.parseInt(usize, id_str.?, 10) catch return error.InvalidId;

    const data_size_slice = get_cmd_slice(data_str.?, &[_]u8{}, &[_]u8{'\r'});
    const data_size = std.fmt.parseInt(usize, data_size_slice, 10) catch return error.InvalidDataLen;

    var data = IpData{
        .id = id,
        .data_len = data_size,
    };

    if (remote_host_str) |host| {
        if (remote_port_str) |port| {
            const data_host_name = get_cmd_slice(host[1..], &[_]u8{}, &[_]u8{'"'});
            const port_slice = get_cmd_slice(port, &[_]u8{}, &[_]u8{':'});
            const portnum = std.fmt.parseInt(u16, port_slice, 10) catch return error.InvalidPort;
            const start = id_str.?.len + data_str.?.len + host.len + port_slice.len + 9;
            data.data_info = IpDataInfo{
                .remote_host = data_host_name,
                .remote_port = portnum,
                .start_index = start,
            };
        }
    }

    return data;
}

pub fn parse_recv_data(str: []const u8) !IpData {
    var slices = std.mem.split(u8, str[13..], ",");
    const data_str = slices.next();
    const host_str = slices.next();
    const port_str = slices.next();

    for (&[_]?[]const u8{ data_str, host_str, port_str }) |value| {
        if (value == null) return error.InvalidPkg;
    }
    const data_len = std.fmt.parseInt(usize, data_str.?, 10) catch return error.InvalidPort;
    const host = get_cmd_slice(host_str.?[1..], &[_]u8{}, &[_]u8{'"'});
    const port = std.fmt.parseInt(u16, port_str.?, 10) catch return error.InvalidPort;
    const start = 16 + data_str.?.len + host_str.?.len + port_str.?.len;

    return .{
        .id = 255,
        .data_len = data_len,
        .data_info = .{
            .remote_host = host,
            .remote_port = port,
            .start_index = start,
        },
    };
}

//TODO: add more error types
pub const ClientError = error{
    InternalError,
};

pub const Client = struct {
    id: usize,
    driver: *anyopaque,
    event: NetworkEvent,
    remote_host: ?[]const u8 = null,
    remote_port: ?u16 = null,

    send_fn: *const fn (ctx: *anyopaque, id: usize, data: []const u8) ClientError!void,
    close_fn: *const fn (ctx: *anyopaque, id: usize) ClientError!void,
    accept_fn: *const fn (ctx: *anyopaque, id: usize) ClientError!void,

    pub fn send(self: *const Client, data: []const u8) !void {
        try self.send_fn(self.driver, self.id, data);
    }

    pub fn close(self: *const Client) !void {
        try self.close_fn(self.driver, self.id);
    }
    pub fn accept(self: *const Client) !void {
        try self.accept_fn(self.driver, self.id);
    }
};

pub const ClientCallback = *const fn (client: Client, user_data: ?*anyopaque) void;
pub const NetworkHandler = struct {
    state: NetworkHandlerState = .None,
    to_send: usize = 0,
    event_callback: ?ClientCallback = null,
    client: Client,
    user_data: ?*anyopaque = null,
    pub fn notify(self: *const NetworkHandler) void {
        if (self.event_callback) |callback| {
            callback(self.client, self.user_data);
        }
    }
};
