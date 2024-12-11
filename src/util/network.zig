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
    local_port: ?u16 = null,
    mode: NetworkUDPModes = .Unchanged,
};
pub const NetWorkConnectType = union(enum) {
    tcp: NetworkTCPConn,
    ssl: NetworkTCPConn,
    udp: NetworkUDPConn,
};
pub const NetworkConnectPkg = struct {
    remote_host: []const u8,
    remote_port: u16,
    config: NetWorkConnectType,
};

pub const NetworkPackageType = union(enum) {
    NetworkSendPkg: NetworkSendPkg,
    NetworkAcceptPkg: void,
    NetworkClosePkg: void,
    NetworkConnectPkg: NetworkConnectPkg,
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

pub fn set_tcp_config(out_buffer: []u8, id: usize, args: NetworkConnectPkg, tcp_conf: NetworkTCPConn) ![]u8 {
    var cmd_slice: []const u8 = undefined;
    var cmd_size: usize = 0;
    cmd_slice = try std.fmt.bufPrint(out_buffer, "{s}{s}={d},\"TCP\",\"{s}\",{d},{d}{s}", .{
        prefix,
        get_cmd_string(.NETWORK_CONNECT),
        id,
        args.remote_host,
        args.remote_port,
        tcp_conf.keep_alive,
        postfix,
    });
    cmd_size = cmd_slice.len;
    return out_buffer[0..cmd_size];
}

pub fn set_udp_config(out_buffer: []u8, id: usize, args: NetworkConnectPkg, udp_conf: NetworkUDPConn) ![]u8 {
    var cmd_slice: []const u8 = undefined;
    var cmd_size: usize = 0;
    cmd_slice = try std.fmt.bufPrint(out_buffer, "{s}{s}={d},\"UDP\",\"{s}\",{d}", .{
        prefix,
        get_cmd_string(.NETWORK_CONNECT),
        id,
        args.remote_host,
        args.remote_port,
    });
    cmd_size = cmd_slice.len;
    if (udp_conf.local_port) |port| {
        cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], ",{d}", .{port});
    } else {
        cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], ",", .{});
    }
    cmd_size += cmd_slice.len;
    cmd_slice = try std.fmt.bufPrint(out_buffer[cmd_size..], ",{d}{s}", .{ @intFromEnum(udp_conf.mode), postfix });
    cmd_size += cmd_slice.len;
    return out_buffer[0..cmd_size];
}

pub const ip_data = struct {
    id: usize,
    data_len: usize,
    //remote_host: []const u8 TODO

};
pub fn paser_ip_data(str: []const u8) !ip_data {
    var slices = std.mem.split(u8, str, ",");
    _ = slices.next(); //skip first arg (+IPD,)

    var id: usize = 0;
    var data_size: usize = 0;

    //get id
    if (slices.next()) |recive_id| {
        id = std.fmt.parseInt(usize, recive_id, 10) catch return error.InvalidId;
    } else {
        return error.InvalidPkg;
    }

    //get data len
    if (slices.next()) |data_str| {
        const data_size_slice = get_cmd_slice(data_str, &[_]u8{}, &[_]u8{'\r'});
        data_size = std.fmt.parseInt(usize, data_size_slice, 10) catch return error.invalidDataLen;
    } else {
        return error.InvalidPkg;
    }
    return ip_data{
        .id = id,
        .data_len = data_size,
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
