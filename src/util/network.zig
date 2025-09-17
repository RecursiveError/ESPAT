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

pub const SendState = enum {
    Ok,
    Fail,
    cancel,
};

pub const SendResult = struct {
    state: SendState,
    data: []const u8 = undefined,
};
pub const Event = union(enum) {
    Connected: void,
    Closed: void,
    DataReport: usize,
    ReadData: []const u8,
    ReadEnd: void,
    SendData: SendResult,
};

pub const RecvMode = enum(u1) {
    active,
    passive,
};

pub const HandlerState = enum {
    None,
    Connected,
    Closed,
};
pub const HandlerType = enum {
    Default,
    TCP,
    UDP,
    SSL,
};

pub const SendPkg = struct {
    data: []const u8 = undefined,
};

pub const SendToPkg = struct {
    data: []const u8 = undefined,
    remote_host: []const u8,
    remote_port: u16,
};

pub const TCPConn = struct {
    keep_alive: u16 = 0,
};

pub const UDPModes = enum {
    Unchanged,
    Change_first,
    Change_all,
};

pub const UDPConn = struct {
    local_port: u16,
    mode: UDPModes = .Unchanged,
};
pub const ConnectType = union(enum) {
    tcp: TCPConn,
    ssl: TCPConn,
    udp: UDPConn,
};
pub const ConnectConfig = struct {
    recv_mode: RecvMode,
    remote_host: []const u8,
    remote_port: u16,
    local_ip: ?[]const u8 = null,
    timeout: ?u16 = null,
    config: ConnectType,
};

pub const ServerConfig = struct {
    recv_mode: RecvMode,
    callback: ClientCallback,
    user_data: ?*anyopaque,
    server_type: HandlerType,
    port: u16,
    timeout: ?u16 = null,
};

pub const TxtReport = struct {
    key: []const u8,
    value: []const u8,
};

pub const mDNSConfig = struct {
    hostname: []const u8,
    service_type: []const u8,
    service_port: u16,
    instance: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    txt_report: ?[]const TxtReport = null,
};

pub const PTRQuery = struct {
    service: []const u8,
    protocol: []const u8,
};

pub const TXTSRVQuery = struct {
    instance: []const u8,
    service: []const u8,
    protocol: []const u8,
};

pub const AAAAQuery = struct {
    hostname: []const u8,
};

pub const mDNSQueryType = union(enum) {
    PTR: PTRQuery,
    TXT: TXTSRVQuery,
    SRV: TXTSRVQuery,
    TXT_SRV: TXTSRVQuery,
    A: AAAAQuery,
    AAAA: AAAAQuery,
    A_AAAA: AAAAQuery,
};

pub const mDNSQueryInterface = enum {
    wifi_sta,
    Wi_Fi_ap,
    ethernet,
    unknown,
};

pub const mDNSQueryIP = enum {
    ipv6,
    ipv4,
};

pub const mDNSNewQuery = struct {
    interface: mDNSQueryInterface,
    ip_type: mDNSQueryIP,
};

pub const mDNSService = struct {
    hostname: []const u8,
    port: u16,
};

pub const mDNSTXT = struct {
    key: []const u8,
    value: []const u8,
};

pub const mDNSEvent = union(enum) {
    new_query: mDNSNewQuery,
    instance: []const u8,
    service: mDNSService,
    txt_param: mDNSTXT,
    ipv4: []const u8,
    ipv6: []const u8,
    query_end: void,
    no_results: void,
    query_fail: void,
};

pub const mDNSQuery = struct {
    type: mDNSQueryType,
    timeout: u32 = 5000,
    max_results: u8 = 1,
    handler: *const fn (mDNSEvent, ?*anyopaque) void,
    user_data: ?*anyopaque = null,
};

pub const mDNSRecv = enum {
    PTR,
    SRV,
    TXT,
    A,
    AAAA,
};
pub const mDNSRecvType = std.StaticStringMap(mDNSRecv).initComptime(
    .{
        .{ "PTR", mDNSRecv.PTR },
        .{ "SRV", mDNSRecv.SRV },
        .{ "TXT", mDNSRecv.TXT },
        .{ "A", mDNSRecv.A },
        .{ "AAAA", mDNSRecv.AAAA },
    },
);

pub const PackageType = union(enum) {
    //setup
    setup: void,
    link_msg: void,
    set_mode: void,
    set_data_mode: RecvMode,

    //client
    SendPkg: SendPkg,
    SendToPkg: SendToPkg,
    AcceptPkg: usize,
    ClosePkg: void,
    ConnectConfig: ConnectConfig,

    //server
    close_server: void,
    create_server: ServerConfig,
    config_server: usize,

    //mDNS
    create_mDNS: mDNSConfig,
    query_mDNS: mDNSQuery,

    //SNTP
    //TODO

    //SSL
    //TODO
};

pub fn set_tcp_config(writer: *std.io.Writer, id: usize, args: ConnectConfig, tcp_conf: TCPConn) !void {
    try writer.print("{s}{s}={d},\"TCP\",\"{s}\",{d},{d}", .{
        prefix,
        get_cmd_string(.NETWORK_CONNECT),
        id,
        args.remote_host,
        args.remote_port,
        tcp_conf.keep_alive,
    });

    if (args.local_ip) |ip| {
        try writer.print(",\"{s}\"", .{ip});
    } else {
        if (args.timeout != null) {
            try writer.print(",", .{});
        }
    }
    if (args.timeout) |timeout| {
        try writer.print(",{d}", .{timeout});
    }
    try writer.print("{s}", .{postfix});
}

pub fn set_udp_config(writer: *std.io.Writer, id: usize, args: ConnectConfig, udp_conf: UDPConn) !void {
    try writer.print("{s}{s}={d},\"UDP\",\"{s}\",{d},{d},{d}", .{
        prefix,
        get_cmd_string(.NETWORK_CONNECT),
        id,
        args.remote_host,
        args.remote_port,
        udp_conf.local_port,
        @intFromEnum(udp_conf.mode),
    });

    if (args.local_ip) |ip| {
        try writer.print(",\"{s}\"", .{ip});
    } else {
        if (args.timeout != null) {
            try writer.print(",", .{});
        }
    }
    if (args.timeout) |timeout| {
        try writer.print(",{d}", .{timeout});
    }
    try writer.print("{s}", .{postfix});
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
                return error.InvalidUDPMode;
            }
        },
    }

    if (config.timeout) |timeout| {
        if (timeout > 60000) return error.InvalidTimeout;
    }
}

pub fn check_mdns_query(query: mDNSQuery) !void {
    if ((query.timeout > 180000) or (query.timeout < 1000)) return error.InvalidTimeout;
    if (query.max_results == 0) return error.InvalidQuerySize;

    switch (query.type) {
        .PTR => |qt| {
            if ((qt.protocol.len > 64) or (qt.service.len > 64)) return error.StringTooLong;
        },
        .TXT, .SRV, .TXT_SRV => |qt| {
            if ((qt.protocol.len > 64) or (qt.service.len > 64) or (qt.instance.len > 64)) return error.StringTooLong;
        },
        .A, .AAAA, .A_AAAA => |qt| {
            if (qt.hostname.len > 64) return error.StringTooLong;
        },
    }
}

pub fn set_mdns_query(query: mDNSQuery, writer: *std.io.Writer) void {
    const q_type: usize = @intFromEnum(query.type);

    writer.print("{s}{s}=2,{d}", .{
        prefix,
        "MDNS",
        q_type,
    }) catch unreachable;

    switch (query.type) {
        .PTR => |qt| {
            writer.print(",\"{s}\",\"{s}\"", .{ qt.service, qt.protocol }) catch unreachable;
        },
        .TXT, .SRV, .TXT_SRV => |qt| {
            writer.print(",\"{s}\",\"{s}\",\"{s}\"", .{ qt.instance, qt.service, qt.protocol }) catch unreachable;
        },
        .A, .AAAA, .A_AAAA => |qt| {
            writer.print("\",{s}\"", .{qt.hostname}) catch unreachable;
        },
    }

    writer.print(",{d},{d}{s}", .{
        query.timeout,
        query.max_results,
        postfix,
    }) catch unreachable;
}

pub const RemoteConnInfo = struct {
    remote_host: []const u8,
    remote_port: u16,
    id: usize,
};

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
    var slices = std.mem.splitSequence(u8, str[5..], ",");
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
    var slices = std.mem.splitSequence(u8, str[13..], ",");
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

pub fn parser_conn_data(str: []const u8) !RemoteConnInfo {
    var slices = std.mem.splitSequence(u8, str[11..], ",");
    //all this skips can be avoid with msg filter but that will reduce the speed a lot
    _ = slices.next(); //skip status
    const id_slice = slices.next();
    _ = slices.next(); //skip ip type
    _ = slices.next(); //skip terminal type
    const ip = slices.next();
    const port_slice = slices.next();

    for (&[_]?[]const u8{ id_slice, ip, port_slice }) |value| {
        if (value == null) return error.InvalidResponse;
    }

    const id = std.fmt.parseInt(usize, id_slice.?, 10) catch return error.InvalidId;
    const port = std.fmt.parseInt(u16, port_slice.?, 10) catch return error.InvalidId;

    return .{
        .id = id,
        .remote_port = port,
        .remote_host = get_cmd_slice(ip.?[1..], &[_]u8{}, &[_]u8{'"'}),
    };
}

//TODO: add more error types
pub const ClientError = error{
    InternalError,
};

pub const Client = struct {
    id: usize,
    driver: *anyopaque,
    event: Event,
    remote_host: ?[]const u8 = null,
    remote_port: ?u16 = null,

    send_fn: *const fn (ctx: *anyopaque, id: usize, data: []const u8) ClientError!void,
    close_fn: *const fn (ctx: *anyopaque, id: usize) ClientError!void,
    accept_fn: *const fn (ctx: *anyopaque, id: usize) ClientError!void,
    sendTo_fn: *const fn (ctx: *anyopaque, id: usize, data: []const u8, remote_host: []const u8, remote_port: u16) ClientError!void,

    pub fn send(self: *const Client, data: []const u8) !void {
        try self.send_fn(self.driver, self.id, data);
    }

    pub fn send_to(self: *const Client, data: []const u8, remote_host: []const u8, remote_port: u16) !void {
        try self.sendTo_fn(self.driver, self.id, data, remote_host, remote_port);
    }

    pub fn close(self: *const Client) !void {
        try self.close_fn(self.driver, self.id);
    }
    pub fn accept(self: *const Client) !void {
        try self.accept_fn(self.driver, self.id);
    }
};

pub const ClientCallback = *const fn (client: Client, user_data: ?*anyopaque) void;
pub const Handler = struct {
    state: HandlerState = .None,
    to_send: usize = 0,
    event_callback: ?ClientCallback = null,
    client: Client,
    user_data: ?*anyopaque = null,
    pub fn notify(self: *const Handler) void {
        if (self.event_callback) |callback| {
            callback(self.client, self.user_data);
        }
    }
};

pub const Package = struct {
    descriptor_id: usize = 255,
    pkg_type: PackageType,
};
