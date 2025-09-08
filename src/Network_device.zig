const std = @import("std");

const Types = @import("Types.zig");
const Device = Types.Device;
const Runner = Types.Runner;

const DeviceError = Types.DeviceError;
const RunnerError = Types.RunnerError;

const Commands_util = @import("util/commands.zig");
const Commands = Commands_util.Commands;
const get_cmd_string = Commands_util.get_cmd_string;
const get_cmd_slice = Commands_util.get_cmd_slice;
const infix = Commands_util.infix;
const prefix = Commands_util.prefix;
const postfix = Commands_util.postfix;

const Network = @import("util/network.zig");
pub const Package = Network.Package;
pub const PackageType = Network.PackageType;
pub const Event = Network.Event;
pub const HandlerState = Network.HandlerState;
pub const ConnectConfig = Network.ConnectConfig;
pub const ServerConfig = Network.ServerConfig;
pub const mDNSConfig = Network.mDNSConfig;
pub const TxtReport = Network.TxtReport;
pub const TCPConn = Network.TCPConn;
pub const UDPConn = Network.UDPConn;
pub const HandlerType = Network.HandlerType;
pub const Handler = Network.Handler;
pub const Client = Network.Client;
pub const ClientCallback = Network.ClientCallback;

pub const DriverMode = enum {
    SERVER_ONLY,
    CLIENT_ONLY,
    SERVER_CLIENT,
};

const ToSend = struct {
    id: usize,
    data: []const u8,
};

pub const TcpIPError = error{
    MAX_BIND,
    INVALID_BIND,
    INVALID_CONFIG,
    INVALID_HOST,
    INVALID_PORT,
    INVALID_MDNS_REPORT,
    DATA_TOO_LONG, //only 8192Bytes per send request
    SERVER_OFF,
    CLIENT_OFF,
} || DeviceError;

pub const Config = struct {
    cmd_buf: []Package,
    net_buf: []u8,
    runner: *const Runner,
    mode: DriverMode,
};

var debug_buf: [1024]u8 = @splat(0);

pub fn NetworkDevice(binds: usize) type {
    if (binds < 5) {
        @compileError("Binds cannot be less than 5");
    }
    return struct {
        const Self = @This();
        const CMD_CALLBACK_TYPE = *const fn (self: *Self, buffer: []const u8) DeviceError!void;
        const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
            .{ "+LINK_CONN", Self.network_conn_event },
            .{ "+IPD", Self.parse_network_data },
            .{ "+CIPRECVDATA", Self.network_read_data },
        });

        runner_dev: *const Runner,
        id: u32 = std.math.maxInt(u32),
        cmd_queue: std.ArrayList(Package),
        tcp_buf: []u8,

        device: Device = .{
            .send_data_fn = send_data,
            .check_cmd_fn = check_cmd,
            .get_cmd_fn = get_cmd,
            .ok_handler_fn = ok_handler,
            .err_handler_fn = err_handler,
            .send_handler_fn = send_event,
            .reset_fn = reset,
        },

        //network data
        Network_binds: [binds]?Handler = undefined,
        Network_corrent_pkg: ?ToSend = null,
        read_id: usize = undefined,
        div_binds: usize,
        network_mode: DriverMode = .CLIENT_ONLY,

        //device functions
        fn check_cmd(device: *const Device, cmd: []const u8, all: []const u8) DeviceError!void {
            const self: *Self = @alignCast(@constCast(@fieldParentPtr("device", device)));
            const response_callback = cmd_response_map.get(cmd);
            if (response_callback) |callback| {
                try @call(.auto, callback, .{ self, all });
                return;
            } else {
                //check if the input is a ID
                _ = std.fmt.parseInt(usize, cmd, 10) catch return;
                try self.network_closed_event(all);
            }
        }

        fn ok_handler(_: *const Device) void {
            return;
        }

        //send command is the only command that need to be check for Ok and Error response
        fn err_handler(device: *const Device) void {
            var self: *Self = @alignCast(@constCast(@fieldParentPtr("device", device)));
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

        fn get_cmd(device: *const Device, writer: *std.io.Writer) DeviceError!void {
            var self: *Self = @alignCast(@constCast(@fieldParentPtr("device", device)));

            const data = self.cmd_queue.pop() orelse return DeviceError.QUEUE_EMPTY;
            const id = data.descriptor_id;

            switch (data.pkg_type) {
                .setup => {
                    writer.print("{s}{s}=1{s}", .{
                        prefix,
                        get_cmd_string(.IP_MUX),
                        postfix,
                    }) catch unreachable;
                },
                .link_msg => {
                    writer.print("{s}{s}=1{s}", .{
                        prefix,
                        get_cmd_string(.NETWORK_MSG_CONFIG),
                        postfix,
                    }) catch unreachable;
                },
                .set_mode => {
                    writer.print("{s}{s}={d}{s}", .{
                        prefix,
                        get_cmd_string(.NETWORK_SERVER_CONF),
                        self.div_binds,
                        postfix,
                    }) catch unreachable;
                },
                .set_data_mode => |recv_m| {
                    writer.print("{s}{s}={d},{d}{s}", .{
                        prefix,
                        get_cmd_string(.NETWORK_RECV_MODE),
                        id,
                        @intFromEnum(recv_m),
                        postfix,
                    }) catch unreachable;
                },
                .SendPkg => |to_send| {
                    self.Network_corrent_pkg = ToSend{
                        .data = to_send.data,
                        .id = id,
                    };
                    self.runner_dev.set_busy_flag(true, self.id) catch return DeviceError.CMD_FAIL;
                    apply_send(id, to_send.data.len, writer);
                },
                .SendToPkg => |to_send| {
                    self.Network_corrent_pkg = ToSend{
                        .data = to_send.data,
                        .id = id,
                    };
                    self.runner_dev.set_busy_flag(true, self.id) catch return DeviceError.CMD_FAIL;
                    apply_udp_send(id, to_send, writer);
                },
                .AcceptPkg => |size| {
                    self.read_id = id;
                    apply_accept(id, size, writer);
                },
                .ClosePkg => {
                    if (self.Network_binds[id]) |*bd| {
                        bd.to_send -= 1;
                    }
                    apply_close(id, writer);
                },
                .ConnectConfig => |connpkg| {
                    switch (connpkg.config) {
                        .tcp, .ssl => |config| {
                            apply_tcp_config(id, connpkg, config, writer);
                        },
                        .udp => |config| {
                            apply_udp_config(id, connpkg, config, writer);
                        },
                    }
                },
                .close_server => {
                    writer.print("{s}{s}=0,1{s}", .{
                        prefix,
                        get_cmd_string(Commands.NETWORK_SERVER),
                        postfix,
                    }) catch unreachable;
                },
                .create_server => |conf| {
                    apply_server_conf(conf, writer);
                },
                .config_server => |timeout| {
                    writer.print("{s}{s}={d}{s}", .{
                        prefix,
                        get_cmd_string(.NETWORK_SERVER_TIMEOUT),
                        timeout,
                        postfix,
                    }) catch unreachable;
                },
                .create_mDNS => |mDNS| {
                    apply_create_mdns(writer, mDNS);
                },
            }
            writer.flush() catch unreachable;
        }

        fn send_data(device: *const Device, writer: *std.io.Writer) DeviceError!void {
            const self: *Self = @alignCast(@constCast(@fieldParentPtr("device", device)));

            if (self.Network_corrent_pkg) |pkg| {
                if (pkg.id < self.Network_binds.len) {
                    if (self.Network_binds[pkg.id]) |*bd| {
                        if (bd.to_send > 0) {
                            bd.to_send -= 1;
                            writer.writeAll(pkg.data) catch return DeviceError.SEND_FAIL;
                            writer.flush() catch return DeviceError.SEND_FAIL;
                            return;
                        }
                    }
                }
            }
            return DeviceError.NO_SEND_DATA;
        }

        fn send_event(device: *const Device, send_state: bool) void {
            const self: *Self = @alignCast(@constCast(@fieldParentPtr("device", device)));
            self.runner_dev.set_busy_flag(false, self.id) catch {};

            if (self.Network_corrent_pkg) |pkg| {
                const event: Network.SendState = if (send_state) Network.SendState.Ok else Network.SendState.Fail;
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

        fn reset(device: *const Device) DeviceError!void {
            const self: *Self = @alignCast(@constCast(@fieldParentPtr("device", device)));
            for (&self.Network_binds) |*bind_i| {
                if (bind_i.*) |*bd| {
                    bd.client.remote_host = null;
                    bd.client.remote_port = null;
                    bd.state = .Closed;
                    bd.client.event = .{ .Closed = {} };
                    bd.notify();
                }
                bind_i.* = null;
            }

            self.cmd_queue.clearRetainingCapacity();
            self.Network_corrent_pkg = null;
            self.read_id = undefined;

            self.runner_dev.queue_multi(self.id, 3) catch return DeviceError.QUEUE_FAIL;

            self.cmd_queue.insertAssumeCapacity(0, .{
                .pkg_type = .{ .setup = {} },
            });

            self.cmd_queue.insertAssumeCapacity(0, .{
                .pkg_type = .{ .link_msg = {} },
            });

            self.cmd_queue.insertAssumeCapacity(0, .{
                .pkg_type = .{ .set_mode = {} },
            });
        }

        fn apply_send(id: usize, data_len: usize, writer: *std.io.Writer) void {
            writer.print("{s}{s}={d},{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_SEND),
                id,
                data_len,
                postfix,
            }) catch unreachable;
        }

        fn apply_tcp_config(id: usize, args: ConnectConfig, tcp_conf: TCPConn, writer: *std.io.Writer) void {
            Network.set_tcp_config(writer, id, args, tcp_conf) catch unreachable;
        }
        fn apply_udp_config(id: usize, args: ConnectConfig, udp_conf: UDPConn, writer: *std.io.Writer) void {
            Network.set_udp_config(writer, id, args, udp_conf) catch unreachable;
        }

        fn apply_udp_send(id: usize, data: Network.SendToPkg, writer: *std.io.Writer) void {
            writer.print("{s}{s}={d},{d},\"{s}\",{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_SEND),
                id,
                data.data.len,
                data.remote_host,
                data.remote_port,
                postfix,
            }) catch unreachable;
        }

        fn apply_accept(id: usize, len: usize, writer: *std.io.Writer) void {
            writer.print("{s}{s}={d},{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_RECV),
                id,
                len,
                postfix,
            }) catch unreachable;
        }

        fn apply_close(id: usize, writer: *std.io.Writer) void {
            writer.print("{s}{s}={d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_CLOSE),
                id,
                postfix,
            }) catch unreachable;
        }

        fn apply_server_conf(conf: ServerConfig, writer: *std.io.Writer) void {
            writer.print("{s}{s}=1,{d}", .{
                prefix,
                get_cmd_string(.NETWORK_SERVER),
                conf.port,
            }) catch unreachable;
            switch (conf.server_type) {
                .Default => {
                    writer.print("{s}", .{postfix}) catch unreachable;
                },

                .SSL => {
                    writer.print(",\"SSL\"{s}", .{postfix}) catch unreachable;
                },

                .TCP => {
                    writer.print(",\"TCP\"{s}", .{postfix}) catch unreachable;
                },
                else => unreachable,
            }
        }

        pub fn apply_create_mdns(writer: *std.io.Writer, config: mDNSConfig) void {
            writer.print("{s}{s}=1,\"{s}\",\"{s}\",{d}", .{
                prefix,
                "MDNS",
                config.hostname,
                config.service_type,
                config.service_port,
            }) catch unreachable;

            if (config.instance) |instname| {
                writer.print(",\"{s}\"", .{instname}) catch unreachable;
            }
            if (config.protocol) |protocol| {
                writer.print(",\"{s}\"", .{protocol}) catch unreachable;
            }
            if (config.txt_report) |report| {
                writer.print(",{d}", .{report.len}) catch unreachable;
                for (report) |item| {
                    writer.print(",\"{s}\",\"{s}\"", .{ item.key, item.value }) catch unreachable;
                }
            }
            writer.writeAll(postfix) catch unreachable;
        }

        //events handlers
        fn network_conn_event(self: *Self, buffer: []const u8) DeviceError!void {
            const data = Network.parser_conn_data(buffer) catch return DeviceError.INVALID_RESPONSE;
            const id = data.id;
            if (id > self.Network_binds.len) return DeviceError.INVALID_RESPONSE;

            if (self.Network_binds[id]) |*bd| {
                bd.client.remote_host = data.remote_host;
                bd.client.remote_port = data.remote_port;
                bd.state = .Connected;
                bd.client.event = .{ .Connected = {} };
                bd.notify();
            }
        }

        fn network_closed_event(self: *Self, aux_buffer: []const u8) DeviceError!void {
            var to_remove: usize = 0;
            const id_index = aux_buffer[0];
            if ((id_index < '0') or (id_index > '9')) {
                return DeviceError.INVALID_RESPONSE;
            }

            const index: usize = id_index - '0';
            if (index > self.Network_binds.len) return DeviceError.INVALID_RESPONSE;

            if (self.Network_binds[index]) |*bd| {
                bd.state = .Closed;
                const id = index;

                //clear all pkgs from the TX pool
                if (bd.to_send > 0) {
                    for (0..self.cmd_queue.items.len) |_| {
                        const data = self.cmd_queue.pop() orelse break;
                        if (id == data.descriptor_id) {
                            to_remove += 1;
                            switch (data.pkg_type) {
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
                        self.cmd_queue.insertAssumeCapacity(0, data);
                    }
                }
                bd.to_send = 0;
                bd.client.event = .{ .Closed = {} };
                bd.notify();
                bd.client.remote_host = null;
                bd.client.remote_port = null;
                self.runner_dev.queue_cancel(self.id, to_remove);
            }
        }

        fn parse_network_data(self: *Self, aux_buffer: []const u8) DeviceError!void {
            const data = Network.paser_ip_data(aux_buffer) catch return DeviceError.INVALID_RESPONSE;
            if (data.id > self.Network_binds.len) return DeviceError.INVALID_RESPONSE;
            const id = data.id;
            const data_size = data.data_len;
            if (self.Network_binds[id]) |*bd| {
                if (data.data_info) |info| {
                    bd.client.remote_host = info.remote_host;
                    bd.client.remote_port = info.remote_port;

                    const reader = self.runner_dev.take_reader() catch return DeviceError.CMD_FAIL;
                    const start_index = info.start_index;
                    const rev = aux_buffer[start_index..];
                    var to_read = data_size - rev.len;
                    var read_size = @min(to_read, (self.tcp_buf.len - rev.len));
                    const end_index = (read_size + rev.len);

                    std.mem.copyForwards(u8, self.tcp_buf, rev);
                    reader.readSliceAll(self.tcp_buf[rev.len..end_index]) catch return DeviceError.FATAL_ERROR;
                    to_read -= read_size;
                    //read revice data
                    bd.client.event = .{ .ReadData = self.tcp_buf[0..end_index] };
                    bd.notify();
                    while (to_read > 0) {
                        read_size = @min(to_read, self.tcp_buf.len);
                        reader.readSliceAll(self.tcp_buf[0..read_size]) catch return DeviceError.FATAL_ERROR;
                        bd.client.event = .{ .ReadData = self.tcp_buf[0..read_size] };
                        to_read -= read_size;
                        bd.notify();
                    }
                    bd.client.event = .{ .ReadEnd = {} };
                    bd.notify();

                    return;
                }
                bd.client.event = .{ .DataReport = data_size };
                bd.notify();
                return;
            }
            return DeviceError.INVALID_RESPONSE;
        }

        fn network_read_data(self: *Self, aux_buffer: []const u8) DeviceError!void {
            if (aux_buffer.len < 14) return DeviceError.INVALID_RESPONSE;
            const recv = Network.parse_recv_data(aux_buffer) catch return DeviceError.INVALID_RESPONSE;
            const id = self.read_id;
            if (self.Network_binds[id]) |*bd| {
                if (recv.data_info) |info| {
                    bd.client.remote_host = info.remote_host;
                    bd.client.remote_port = info.remote_port;

                    const reader: *std.io.Reader = self.runner_dev.take_reader() catch return DeviceError.CMD_FAIL;
                    const rev_len = recv.data_len;
                    const start_index = info.start_index;
                    const rev_slice = aux_buffer[start_index..];
                    // if data in buffer is less than the data to read, copy the                     //and read the rest from the reader
                    if (rev_len > rev_slice.len) {
                        std.mem.copyForwards(u8, self.tcp_buf, rev_slice);
                        reader.readSliceAll(self.tcp_buf[rev_slice.len..rev_len]) catch return DeviceError.FATAL_ERROR;
                        bd.client.event = .{ .ReadData = self.tcp_buf[0..rev_len] };
                        bd.notify();
                        return;
                    }
                    //if all data is in the buffer just slice and send
                    bd.client.event = .{ .ReadData = rev_slice[0..rev_len] };
                    bd.notify();
                    return;
                }
            }
            return DeviceError.INVALID_RESPONSE;
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

        pub fn bind(self: *Self, event_callback: ClientCallback, user_data: ?*anyopaque) TcpIPError!usize {
            if (self.network_mode == .SERVER_ONLY) return TcpIPError.CLIENT_OFF;
            const start_bind = self.div_binds;

            for (start_bind..binds) |index| {
                if (self.Network_binds[index]) |_| {
                    continue;
                } else {
                    const new_bind: Handler = .{
                        .event_callback = event_callback,
                        .user_data = user_data,
                        .client = self.create_client(index),
                    };
                    self.Network_binds[index] = new_bind;
                    return index;
                }
            }
            return TcpIPError.MAX_BIND;
        }

        //TODO: add error checking for invalid closed erros
        pub fn close(self: *Self, id: usize) TcpIPError!void {
            if (id > self.Network_binds.len) return TcpIPError.INVALID_BIND;
            if (self.Network_binds[id]) |*bd| {
                self.runner_dev.queue(self.id) catch return TcpIPError.QUEUE_FAIL;
                self.cmd_queue.insertBounded(0, .{
                    .descriptor_id = id,
                    .pkg_type = .{ .ClosePkg = {} },
                }) catch return TcpIPError.QUEUE_FULL;
                bd.to_send += 1;
                return;
            }
            return TcpIPError.INVALID_BIND;
        }

        fn close_fn(ctx: *anyopaque, id: usize) Network.ClientError!void {
            const driver: *Self = @ptrCast(@alignCast(ctx));
            driver.close(id) catch return error.InternalError;
        }

        pub fn connect(self: *Self, id: usize, config: ConnectConfig) TcpIPError!void {
            self.runner_dev.queue_multi(self.id, 3) catch return TcpIPError.QUEUE_FULL;
            if ((self.cmd_queue.capacity - self.cmd_queue.items.len) < 3) {
                return TcpIPError.QUEUE_FULL;
            }
            if (id > self.Network_binds.len or id < self.div_binds) return TcpIPError.INVALID_BIND;
            Network.check_connect_config(config) catch return TcpIPError.INVALID_CONFIG;

            self.runner_dev.queue_multi(self.id, 2) catch unreachable;
            self.cmd_queue.insertAssumeCapacity(0, .{
                .descriptor_id = id,
                .pkg_type = .{
                    .set_data_mode = config.recv_mode,
                },
            });

            self.cmd_queue.insertAssumeCapacity(0, .{
                .descriptor_id = id,
                .pkg_type = .{
                    .ConnectConfig = config,
                },
            });
        }

        pub fn accept(self: *Self, id: usize) TcpIPError!void {
            if (id >= self.Network_binds.len) return TcpIPError.INVALID_BIND;

            const recv_buffer_size = self.tcp_buf.len - 50; //50bytes  of pre-data
            self.runner_dev.queue(self.id) catch return TcpIPError.QUEUE_FAIL;
            self.cmd_queue.insertBounded(
                0,
                .{ .descriptor_id = id, .pkg_type = .{
                    .AcceptPkg = recv_buffer_size,
                } },
            ) catch return TcpIPError.QUEUE_FULL;
        }

        fn accpet_fn(ctx: *anyopaque, id: usize) Network.ClientError!void {
            const driver: *Self = @ptrCast(@alignCast(ctx));
            driver.accept(id) catch return error.InternalError;
        }

        pub fn send(self: *Self, id: usize, data: []const u8) TcpIPError!void {
            if (id >= self.Network_binds.len) return TcpIPError.INVALID_BIND;
            if (data.len > 8192) return TcpIPError.DATA_TOO_LONG;
            const free = self.runner_dev.queue_free_size();
            const cmd_free = self.cmd_queue.capacity - self.cmd_queue.items.len;
            if ((free < 3) or (cmd_free < 3)) return TcpIPError.QUEUE_FULL; //to leave some space available for close

            if (self.Network_binds[id]) |*bd| {
                self.runner_dev.queue(self.id) catch unreachable;
                self.cmd_queue.insertAssumeCapacity(0, .{
                    .descriptor_id = id,
                    .pkg_type = .{
                        .SendPkg = .{ .data = data },
                    },
                });
                bd.to_send += 1;
                return;
            }
            return TcpIPError.INVALID_BIND;
        }

        fn send_fn(ctx: *anyopaque, id: usize, data: []const u8) Network.ClientError!void {
            const driver: *Self = @ptrCast(@alignCast(ctx));
            driver.send(id, data) catch return error.InternalError;
        }
        ///sends data to a specific host, can only be used on UDP type connections.
        ///always result in a send fail if used in TCP or SSL conn
        pub fn send_to(self: *Self, id: usize, data: []const u8, remote_host: []const u8, remote_port: u16) TcpIPError!void {
            if (id >= self.Network_binds.len) return TcpIPError.INVALID_BIND;
            if (data.len > 8192) return TcpIPError.DATA_TOO_LONG;
            const free = self.runner_dev.queue_free_size();
            const cmd_free = self.cmd_queue.capacity - self.cmd_queue.items.len;
            if ((free < 3) or (cmd_free < 3)) return TcpIPError.QUEUE_FULL; //to leave some space available for close

            if (!std.net.isValidHostName(remote_host)) return TcpIPError.INVALID_HOST;
            if (remote_port == 0) return TcpIPError.INVALID_PORT;

            if (self.Network_binds[id]) |*bd| {
                self.runner_dev.queue(self.id) catch unreachable;
                self.cmd_queue.insertAssumeCapacity(0, .{
                    .descriptor_id = id,
                    .pkg_type = .{
                        .SendToPkg = .{
                            .data = data,
                            .remote_host = remote_host,
                            .remote_port = remote_port,
                        },
                    },
                });
                bd.to_send += 1;
                return;
            }
            return TcpIPError.INVALID_BIND;
        }

        fn sendTo_fn(ctx: *anyopaque, id: usize, data: []const u8, remote_host: []const u8, remote_port: u16) Network.ClientError!void {
            const driver: *Self = @ptrCast(@alignCast(ctx));
            driver.send_to(id, data, remote_host, remote_port) catch return error.InternalError;
        }

        pub fn create_server(self: *Self, config: ServerConfig) TcpIPError!void {
            const end_bind = self.div_binds;
            const calc_pkgs: usize = 2 + @as(usize, if (self.network_mode == .SERVER_ONLY) 1 else end_bind);
            const free = self.runner_dev.queue_free_size();
            const cmd_free = self.cmd_queue.capacity - self.cmd_queue.items.len;

            if ((free < calc_pkgs) or (cmd_free < calc_pkgs)) return TcpIPError.QUEUE_FULL; //to leave some space available for close
            if (self.network_mode == DriverMode.CLIENT_ONLY) return TcpIPError.SERVER_OFF;
            if (config.server_type == .UDP) return TcpIPError.UNSUPPORTED;

            for (0..end_bind) |id| {
                try self.release(id);
                self.Network_binds[id] = Network.Handler{
                    .event_callback = config.callback,
                    .user_data = config.user_data,
                    .client = self.create_client(id),
                };
            }

            if (self.network_mode == .SERVER_ONLY) {
                self.cmd_queue.insertAssumeCapacity(0, .{
                    .descriptor_id = binds,
                    .pkg_type = .{ .set_data_mode = config.recv_mode },
                });
            } else {
                for (0..end_bind) |id| {
                    self.cmd_queue.insertAssumeCapacity(0, .{
                        .descriptor_id = id,
                        .pkg_type = .{ .set_data_mode = config.recv_mode },
                    });
                }
            }

            self.cmd_queue.insertAssumeCapacity(0, .{
                .pkg_type = .{ .create_server = config },
            });
            if (config.timeout) |timeout| {
                const time = @min(7200, timeout);
                self.cmd_queue.insertAssumeCapacity(0, .{ .pkg_type = .{ .config_server = time } });
            }

            self.runner_dev.queue_multi(self.id, calc_pkgs) catch unreachable;
        }

        pub fn release(self: *Self, id: usize) TcpIPError!void {
            if (id > self.Network_binds.len) return TcpIPError.INVALID_BIND;

            //clear all Sockect pkgs
            var to_remove: usize = 0;

            if (self.Network_binds[id]) |*bd| {
                bd.state = .Closed;

                //clear all pkgs from the TX pool
                if (bd.to_send > 0) {
                    for (0..self.cmd_queue.items.len) |_| {
                        const data = self.cmd_queue.pop() orelse break;
                        if (id == data.descriptor_id) {
                            to_remove += 1;
                            switch (data.pkg_type) {
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
                        self.cmd_queue.insertAssumeCapacity(0, data);
                    }
                }
            }
            self.Network_binds[id] = null;
        }

        pub fn delete_server(self: *Self) TcpIPError!void {
            const free = self.runner_dev.queue_free_size();
            const cmd_free = self.cmd_queue.capacity - self.cmd_queue.items.len;
            if ((free < 1) or (cmd_free < 1)) return TcpIPError.QUEUE_FULL;

            for (0..self.div_binds) |bind_id| {
                try self.release(bind_id);
            }

            //send server close server command
            self.cmd_queue.insertAssumeCapacity(0, .{ .pkg_type = .{ .ClosePkg = {} } });
            self.runner_dev.queue(self.id) catch unreachable;
        }

        pub fn create_mDNS(self: *Self, config: mDNSConfig) TcpIPError!void {
            const free = self.runner_dev.queue_free_size();
            const cmd_free = self.cmd_queue.capacity - self.cmd_queue.items.len;
            if ((free < 1) or (cmd_free < 1)) return TcpIPError.QUEUE_FULL;
            if (config.txt_report) |reports| {
                const len = reports.len;
                if ((len >= 10) or len == 0) return TcpIPError.INVALID_MDNS_REPORT;
            }
            self.cmd_queue.insertAssumeCapacity(0, .{ .pkg_type = .{ .create_mDNS = config } });
            self.runner_dev.queue(self.id) catch unreachable;
        }

        //function
        pub fn link_device(self: *Self) TcpIPError!void {
            self.id = self.runner_dev.link_device(&self.device) catch return TcpIPError.SETUP_FAIL;
        }

        pub fn init(config: Config) Self {
            const div_binds: usize = switch (config.mode) {
                .CLIENT_ONLY => 1,
                .SERVER_ONLY => binds,
                .SERVER_CLIENT => 3,
            };

            var dev: Self = .{
                .network_mode = config.mode,
                .div_binds = div_binds,
                .cmd_queue = std.ArrayList(Package).initBuffer(config.cmd_buf),
                .tcp_buf = config.net_buf,
                .runner_dev = config.runner,
            };

            for (0..binds) |i| {
                dev.Network_binds[i] = null;
            }

            return dev;
        }
    };
}
