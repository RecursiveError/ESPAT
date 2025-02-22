const std = @import("std");

const Types = @import("Types.zig");
const Device = Types.Device;
const Runner = Types.Runner;
const ToRead = Types.ToRead;
const TXPkg = Types.TXPkg;
const CommandPkg = Types.TXPkg;
const Devices = Types.Devices;
const DriverError = Types.DriverError;

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

pub fn NetworkDevice(binds: usize) type {
    if (binds < 5) {
        @compileError("Binds cannot be less than 5");
    }
    return struct {
        const Self = @This();
        const CMD_CALLBACK_TYPE = *const fn (self: *Self, buffer: []const u8) DriverError!void;
        const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
            .{ "+LINK_CONN", Self.network_conn_event },
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
            .send_handler = send_event,
            .deinit = deinit,
        },

        //network data
        Network_binds: [binds]?Handler = undefined,
        Network_corrent_pkg: ?ToSend = null,
        corrent_read_id: usize = 0,
        div_binds: usize = 0,
        network_mode: DriverMode = .CLIENT_ONLY,

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

        fn apply_cmd(pkg: TXPkg, input_buffer: []u8, device_inst: *anyopaque) DriverError![]const u8 {
            var self: *Self = @alignCast(@ptrCast(device_inst));
            const runner_inst = self.runner_loop.runner_instance;
            const data = std.mem.bytesAsValue(Package, &pkg.buffer);

            const id = data.descriptor_id;
            switch (data.pkg_type) {
                .SendPkg => |to_send| {
                    self.Network_corrent_pkg = ToSend{
                        .data = to_send.data,
                        .id = id,
                    };
                    self.runner_loop.set_busy_flag(1, runner_inst);
                    return apply_send(id, to_send.data.len, input_buffer);
                },
                .SendToPkg => |to_send| {
                    self.Network_corrent_pkg = ToSend{
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
            return DriverError.INVALID_PKG;
        }

        fn pool_data(inst: *anyopaque) DriverError![]const u8 {
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

        fn send_event(device_inst: *anyopaque, send_state: bool) void {
            var self: *Self = @alignCast(@ptrCast(device_inst));
            const runner_inst = self.runner_loop.runner_instance;
            self.runner_loop.set_busy_flag(0, runner_inst);

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

        fn deinit(inst: *anyopaque) void {
            const self: *Self = @alignCast(@ptrCast(inst));
            for (0..binds) |id| {
                self.release(id) catch continue;
            }

            self.delete_server() catch return;
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

        fn apply_tcp_config(id: usize, args: ConnectConfig, tcp_conf: TCPConn, buffer: []u8) []const u8 {
            const config = Network.set_tcp_config(buffer, id, args, tcp_conf) catch unreachable;
            return config;
        }
        fn apply_udp_config(id: usize, args: ConnectConfig, udp_conf: UDPConn, buffer: []u8) []const u8 {
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
                const id = index;

                //clear all pkgs from the TX pool
                if (bd.to_send > 0) {
                    const TX_size = self.runner_loop.get_tx_len(runner_inst);
                    for (0..TX_size) |_| {
                        const data = self.runner_loop.get_tx_data(runner_inst).?;
                        switch (data.device) {
                            .TCP_IP => {
                                const net_data = std.mem.bytesAsValue(Package, &data.buffer);
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
                bd.to_send = 0;
                bd.client.event = .{ .Closed = {} };
                bd.notify();
                bd.client.remote_host = null;
                bd.client.remote_port = null;
            }
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

        pub fn set_network_mode(self: *Self, mode: DriverMode) !void {
            const runner_inst = self.runner_loop.runner_instance;
            self.div_binds = switch (mode) {
                .CLIENT_ONLY => 0,
                .SERVER_ONLY => 5,
                .SERVER_CLIENT => 3,
            };

            var pkg: Commands_util.Package = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{ prefix, get_cmd_string(.NETWORK_SERVER_CONF), self.div_binds, postfix }) catch unreachable;
            pkg.len = cmd_slice.len;

            self.runner_loop.store_tx_data(
                TXPkg.convert_type(.Command, pkg),
                runner_inst,
            ) catch return DriverError.TX_BUFFER_FULL;

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
                    const new_bind: Handler = .{
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
                const pkg = Package{
                    .descriptor_id = id,
                    .pkg_type = .{ .ClosePkg = {} },
                };
                self.runner_loop.store_tx_data(
                    TXPkg.convert_type(.TCP_IP, pkg),
                    runner_inst,
                ) catch return DriverError.TX_BUFFER_FULL;
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
            var recv_mode = Commands_util.Package{};
            const cmd_slice = std.fmt.bufPrint(&recv_mode.str, "{s}{s}={d},{d}{s}", .{
                prefix,
                get_cmd_string(.NETWORK_RECV_MODE),
                id,
                @intFromEnum(config.recv_mode),
                postfix,
            }) catch unreachable;
            recv_mode.len = cmd_slice.len;
            self.runner_loop.store_tx_data(
                TXPkg.convert_type(
                    .Command,
                    recv_mode,
                ),
                runner_inst,
            ) catch unreachable;

            //send connect request
            const pkg = Package{
                .descriptor_id = id,
                .pkg_type = .{
                    .ConnectConfig = config,
                },
            };
            self.runner_loop.store_tx_data(
                TXPkg.convert_type(
                    .TCP_IP,
                    pkg,
                ),
                runner_inst,
            ) catch unreachable;
        }
        pub fn accept(self: *Self, id: usize) DriverError!void {
            const runner_inst = self.runner_loop.runner_instance;

            if (id >= self.Network_binds.len) return DriverError.INVALID_ARGS;
            const recv_buffer_size = 2046 - 50; //50bytes  of pre-data
            const pkg = Package{ .descriptor_id = id, .pkg_type = .{
                .AcceptPkg = recv_buffer_size,
            } };
            self.runner_loop.store_tx_data(TXPkg.convert_type(.TCP_IP, pkg), runner_inst) catch return DriverError.TX_BUFFER_FULL;
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
                const pkg = Package{
                    .descriptor_id = id,
                    .pkg_type = .{
                        .SendPkg = .{ .data = data },
                    },
                };
                self.runner_loop.store_tx_data(TXPkg.convert_type(.TCP_IP, pkg), runner_inst) catch return DriverError.TX_BUFFER_FULL;
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
                const pkg = Package{
                    .descriptor_id = id,
                    .pkg_type = .{
                        .SendToPkg = .{
                            .data = data,
                            .remote_host = remote_host,
                            .remote_port = remote_port,
                        },
                    },
                };
                self.runner_loop.store_tx_data(TXPkg.convert_type(.TCP_IP, pkg), runner_inst) catch return DriverError.TX_BUFFER_FULL;
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

            if (self.network_mode == DriverMode.CLIENT_ONLY) return DriverError.SERVER_OFF;

            const end_bind = self.div_binds;
            var cmd_slice: []const u8 = undefined;

            var pkg: Commands_util.Package = .{};

            if (self.network_mode == .SERVER_ONLY) {
                if (self.runner_loop.get_tx_free_space(runner_inst) < 3) return DriverError.TX_BUFFER_FULL;
                cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=5,{d}{s}", .{
                    prefix,
                    get_cmd_string(.NETWORK_RECV_MODE),
                    @intFromEnum(config.recv_mode),
                    postfix,
                }) catch unreachable;

                pkg.len = cmd_slice.len;
                self.runner_loop.store_tx_data(TXPkg.convert_type(.Command, pkg), runner_inst) catch unreachable;
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
                    self.runner_loop.store_tx_data(TXPkg.convert_type(.Command, pkg), runner_inst) catch unreachable;
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
            self.runner_loop.store_tx_data(TXPkg.convert_type(.Command, pkg), runner_inst) catch unreachable;

            if (config.timeout) |timeout| {
                const time = @min(7200, timeout);
                cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{
                    prefix,
                    get_cmd_string(.NETWORK_SERVER_TIMEOUT),
                    time,
                    postfix,
                }) catch unreachable;
                pkg.len = cmd_slice.len;
                self.runner_loop.store_tx_data(TXPkg.convert_type(.Command, pkg), runner_inst) catch unreachable;
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
                    switch (data.device) {
                        .TCP_IP => {
                            const net_data = std.mem.bytesAsValue(Package, &data.buffer);
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
                try self.release(bind_id);
            }

            //send server close server command
            var pkg: Commands_util.Package = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=0,1{s}", .{ prefix, get_cmd_string(Commands.NETWORK_SERVER), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.runner_loop.store_tx_data(TXPkg.convert_type(.Command, pkg), runner_inst) catch return DriverError.TX_BUFFER_FULL;
        }

        //functions

        pub fn link_device(self: *Self, runner: anytype) void {
            const info = @typeInfo(@TypeOf(runner));
            switch (info) {
                .pointer => |ptr| {
                    const child_type = ptr.child;
                    if (@hasField(child_type, "tcp_ip")) {
                        const net_device = &runner.tcp_ip;
                        if (@TypeOf(net_device.*) == ?*Device) {
                            self.device.device_instance = @ptrCast(self);
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
