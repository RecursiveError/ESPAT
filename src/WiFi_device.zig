const std = @import("std");

const Types = @import("Types.zig");
const Device = Types.Device;
const Runner = Types.Runner;
const ToRead = Types.ToRead;
const TXEventPkg = Types.TXEventPkg;
const DriverError = Types.DriverError;

const Commands_util = @import("util/commands.zig");
const Commands = Commands_util.Commands;
const get_cmd_string = Commands_util.get_cmd_string;
const get_cmd_slice = Commands_util.get_cmd_slice;
const infix = Commands_util.infix;
const prefix = Commands_util.prefix;
const postfix = Commands_util.postfix;

const WiFi = @import("util/WiFi.zig");
pub const APConfig = WiFi.APConfig;
pub const STAConfig = WiFi.STAConfig;
pub const Event = WiFi.Event;
pub const Encryption = WiFi.Encryption;

pub const DriverMode = enum { NONE, STA, AP, AP_STA };

pub const state = enum {
    OFF,
    DISCONECTED,
    CONNECTED,
};

pub const WIFICallbackType = ?*const fn (event: WiFi.Event, user_data: ?*anyopaque) void;

pub const WiFiDevice = struct {
    const CMD_CALLBACK_TYPE = *const fn (self: *WiFiDevice, buffer: []const u8) DriverError!void;
    const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
        .{ "WIFI", WiFiDevice.wifi_response },
        .{ "+CIPSTA", WiFiDevice.WiFi_get_AP_info },
        .{ "+CWJAP", WiFiDevice.WiFi_error },
        .{ "+STA_CONNECTED", WiFiDevice.WiFi_get_device_conn_mac },
        .{ "+DIST_STA_IP", WiFiDevice.WiFi_get_device_ip },
        .{ "+STA_DISCONNECTED", WiFiDevice.WiFi_get_device_disc_mac },
    });

    runner_loop: *Runner = undefined,
    device: Device = .{
        .pool_data = pool_data,
        .check_cmd = check_cmd,
        .apply_cmd = apply_cmd,
        .ok_handler = ok_handler,
        .err_handler = err_handler,
    },

    Wifi_state: state = .OFF,
    Wifi_mode: DriverMode = .NONE,
    WiFi_dhcp: WiFi.DHCPEnable = .{},
    //callback handlers
    WiFi_user_data: ?*anyopaque = null,
    on_WiFi_event: WIFICallbackType = null,
    STAFlag: bool = false,

    //Device functions

    fn pool_data(_: *anyopaque) []const u8 {
        return "";
    }

    fn check_cmd(cmd: []const u8, buffer: []const u8, device_inst: *anyopaque) DriverError!void {
        const self: *WiFiDevice = @alignCast(@ptrCast(device_inst));
        const response_callback = cmd_response_map.get(cmd);
        if (response_callback) |callback| {
            try @call(.auto, callback, .{ self, buffer });
            return;
        }
    }

    fn apply_cmd(pkg: TXEventPkg, input_buffer: []u8, device_inst: *anyopaque) []const u8 {
        var self: *WiFiDevice = @alignCast(@ptrCast(device_inst));
        const runner_inst = self.runner_loop.runner_instance;

        switch (pkg.Extra_data) {
            .WiFi => |data| {
                switch (data) {
                    .AP_conf_pkg => |wpkg| {
                        return WiFi_apply_AP_config(wpkg, input_buffer);
                    },
                    .STA_conf_pkg => |wpkg| {
                        self.runner_loop.set_busy_flag(1, runner_inst);
                        self.STAFlag = true;
                        return WiFi_apply_STA_config(wpkg, input_buffer);
                    },
                    .MAC_config => |wpkg| {
                        return apply_WiFi_mac(pkg.cmd_enum, wpkg, input_buffer);
                    },
                    .static_ap_config => |wpkg| {
                        return apply_static_ip(pkg.cmd_enum, wpkg, input_buffer);
                    },
                    .dhcp_config => |wpkg| {
                        return apply_DHCP_config(wpkg, input_buffer);
                    },
                }
            },
            else => {},
        }
        return "\r\n";
    }

    fn apply_WiFi_mac(cmd_data: Commands, mac: []const u8, input_buffer: []u8) []const u8 {
        return WiFi.set_mac(input_buffer, cmd_data, mac) catch unreachable;
    }

    fn apply_static_ip(cmd_data: Commands, ip: WiFi.StaticIp, input_buffer: []u8) []const u8 {
        return WiFi.set_static_ip(input_buffer, cmd_data, ip) catch unreachable;
    }

    fn apply_DHCP_config(dhcp: WiFi.DHCPConfig, input_buffer: []u8) []const u8 {
        return WiFi.set_DHCP_config(input_buffer, dhcp) catch unreachable;
    }

    fn WiFi_apply_AP_config(config: WiFi.APpkg, input_buffer: []u8) []const u8 {
        return WiFi.set_AP_config(input_buffer, config) catch unreachable;
    }

    fn WiFi_apply_STA_config(config: WiFi.STApkg, input_buffer: []u8) []const u8 {
        return WiFi.set_STA_config(input_buffer, config) catch unreachable;
    }

    fn ok_handler(device_inst: *anyopaque) void {
        response_handler(device_inst);
    }
    fn err_handler(device_inst: *anyopaque) void {
        response_handler(device_inst);
    }

    fn response_handler(device_inst: *anyopaque) void {
        var self: *WiFiDevice = @alignCast(@ptrCast(device_inst));
        const runner_inst = self.runner_loop.runner_instance;
        if (self.STAFlag) {
            self.runner_loop.set_busy_flag(0, runner_inst);
            self.STAFlag = false;
        }
    }

    fn wifi_response(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        const inst = self.runner_loop.runner_instance;
        const wifi_event_slice = get_cmd_slice(aux_buffer[5..], &[_]u8{}, &[_]u8{'\r'});
        const base_event = WiFi.get_base_event(wifi_event_slice) catch return DriverError.INVALID_RESPONSE;
        const event: Event = switch (base_event) {
            .AP_DISCONNECTED => Event{ .AP_DISCONNECTED = {} },
            .AP_CON_START => Event{ .AP_CON_START = {} },
            .AP_CONNECTED => Event{ .AP_CONNECTED = {} },
            else => unreachable,
        };

        if (base_event == .AP_CONNECTED) {
            var pkg: Commands_util.Package = .{};
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}?{s}", .{ prefix, get_cmd_string(.WIFI_STA_IP), postfix }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .WIFI_STA_IP,
                .Extra_data = .{ .Command = pkg },
            }, inst) catch return DriverError.TX_BUFFER_FULL;
        }
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    fn WiFi_get_AP_info(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        const event_slice = get_cmd_slice(aux_buffer[8..], &[_]u8{}, &[_]u8{':'});
        const data_start = event_slice.len + 10;
        const data_slice = get_cmd_slice(aux_buffer[data_start..], &[_]u8{}, &[_]u8{'"'});
        const base_event = WiFi.get_base_event(event_slice) catch return DriverError.INVALID_RESPONSE;
        const event: Event = switch (base_event) {
            .AP_GOT_GATEWAY => Event{ .AP_GOT_GATEWAY = data_slice },
            .AP_GOT_IP => Event{ .AP_GOT_IP = data_slice },
            .AP_GOT_MASK => Event{ .AP_GOT_MASK = data_slice },
            else => unreachable,
        };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
        self.Wifi_state = .CONNECTED;
    }

    fn WiFi_error(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        const inst = self.runner_loop.runner_instance;
        self.runner_loop.set_busy_flag(0, inst);
        if (aux_buffer.len < 8) return DriverError.INVALID_RESPONSE;
        const error_id = WiFi.get_error_event(aux_buffer);
        const event = Event{ .ERROR = error_id };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    fn WiFi_get_device_conn_mac(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        if (aux_buffer.len < 34) return DriverError.INVALID_ARGS;
        const mac = aux_buffer[16..33];
        const event = Event{ .STA_CONNECTED = mac };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }
    fn WiFi_get_device_ip(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        if (aux_buffer.len < 46) return DriverError.INVALID_RESPONSE;
        const mac = get_cmd_slice(aux_buffer[14..], &[_]u8{}, &[_]u8{'"'});
        const ip = get_cmd_slice(aux_buffer[34..], &[_]u8{}, &[_]u8{'"'});
        const event = Event{ .STA_GOT_IP = .{ .ip = ip, .mac = mac } };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    fn WiFi_get_device_disc_mac(self: *WiFiDevice, aux_buffer: []const u8) DriverError!void {
        if (aux_buffer.len < 37) return DriverError.INVALID_ARGS;
        const mac = aux_buffer[19..36];
        const event = Event{ .STA_DISCONNECTED = mac };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    //WiFi functions
    pub fn WiFi_connect_AP(self: *WiFiDevice, config: STAConfig) !void {
        const inst = self.runner_loop.runner_instance;

        if (self.Wifi_mode == .AP) {
            return DriverError.STA_OFF;
        } else if (self.Wifi_mode == DriverMode.NONE) {
            return DriverError.WIFI_OFF;
        }
        const free_tx = self.runner_loop.get_tx_free_space(inst);
        const pkgs = try WiFi.check_STA_config(config);
        if (free_tx < pkgs) return DriverError.TX_BUFFER_FULL;

        var pkg: Commands_util.Package = .{};

        if (config.wifi_protocol) |proto| {
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{
                prefix,
                get_cmd_string(.WIFI_STA_PROTO),
                @as(u4, @bitCast(proto)),
                postfix,
            }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .WIFI_STA_PROTO,
                .Extra_data = .{ .Command = pkg },
            }, inst) catch unreachable;
        }

        if (config.mac) |mac| {
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .WIFI_STA_MAC,
                .Extra_data = .{
                    .WiFi = .{ .MAC_config = mac },
                },
            }, inst) catch unreachable;
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
                    self.runner_loop.store_tx_data(TXEventPkg{
                        .cmd_enum = .WiFi_SET_DHCP,
                        .Extra_data = .{ .Command = pkg },
                    }, inst) catch unreachable;
                },
                .static => |static_ip| {
                    self.WiFi_dhcp.STA = 0;
                    self.runner_loop.store_tx_data(TXEventPkg{
                        .cmd_enum = .WIFI_STA_IP,
                        .Extra_data = .{
                            .WiFi = .{
                                .static_ap_config = static_ip,
                            },
                        },
                    }, inst) catch unreachable;
                },
            }
        }

        self.runner_loop.store_tx_data(TXEventPkg{ .cmd_enum = .WIFI_CONNECT, .Extra_data = .{
            .WiFi = .{
                .STA_conf_pkg = WiFi.STApkg.from_config(config),
            },
        } }, inst) catch unreachable;
    }

    pub fn WiFi_config_AP(self: *WiFiDevice, config: APConfig) !void {
        const inst = self.runner_loop.runner_instance;

        if (self.Wifi_mode == .STA) {
            return DriverError.AP_OFF;
        } else if (self.Wifi_mode == .NONE) {
            return DriverError.WIFI_OFF;
        }
        const free_tx = self.runner_loop.get_tx_free_space(inst);
        const pkgs = try WiFi.check_AP_config(config);

        if (free_tx < pkgs) return DriverError.TX_BUFFER_FULL;

        var pkg: Commands_util.Package = .{};

        if (config.wifi_protocol) |proto| {
            const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{
                prefix,
                get_cmd_string(.WIFI_AP_PROTO),
                @as(u4, @bitCast(proto)),
                postfix,
            }) catch unreachable;
            pkg.len = cmd_slice.len;
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .WIFI_AP_PROTO,
                .Extra_data = .{ .Command = pkg },
            }, inst) catch unreachable;
        }

        if (config.mac) |mac| {
            self.runner_loop.store_tx_data(TXEventPkg{
                .cmd_enum = .WIFI_AP_MAC,
                .Extra_data = .{
                    .WiFi = .{
                        .MAC_config = mac,
                    },
                },
            }, inst) catch unreachable;
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
                    self.runner_loop.store_tx_data(TXEventPkg{
                        .cmd_enum = .WiFi_SET_DHCP,
                        .Extra_data = .{ .Command = pkg },
                    }, inst) catch unreachable;
                },
                .static => |static_ip| {
                    self.WiFi_dhcp.AP = 0;
                    const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}=", .{
                        prefix,
                        get_cmd_string(.WIFI_AP_IP),
                    }) catch unreachable;
                    pkg.len = cmd_slice.len;
                    self.runner_loop.store_tx_data(TXEventPkg{
                        .cmd_enum = .WIFI_AP_IP,
                        .Extra_data = .{
                            .WiFi = .{
                                .static_ap_config = static_ip,
                            },
                        },
                    }, inst) catch unreachable;
                },
            }
        }

        if (config.dhcp_config) |dhcp| {
            self.runner_loop.store_tx_data(TXEventPkg{ .cmd_enum = .WiFi_CONF_DHCP, .Extra_data = .{
                .WiFi = .{
                    .dhcp_config = dhcp,
                },
            } }, inst) catch unreachable;
        }

        self.runner_loop.store_tx_data(TXEventPkg{ .cmd_enum = .WIFI_CONF, .Extra_data = .{
            .WiFi = .{
                .AP_conf_pkg = WiFi.APpkg.from_config(config),
            },
        } }, inst) catch unreachable;
    }

    pub fn set_WiFi_mode(self: *WiFiDevice, mode: DriverMode) !void {
        const inst = self.runner_loop.runner_instance;

        var pkg: Commands_util.Package = .{};
        const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}={d}{s}", .{ prefix, get_cmd_string(.WIFI_SET_MODE), @intFromEnum(mode), postfix }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner_loop.store_tx_data(TXEventPkg{
            .cmd_enum = .WIFI_SET_MODE,
            .Extra_data = .{ .Command = pkg },
        }, inst) catch return DriverError.TX_BUFFER_FULL;
        self.Wifi_mode = mode;
    }

    pub fn WiFi_disconnect(self: *WiFiDevice) DriverError!void {
        const inst = self.runner_loop.runner_instance;

        var pkg: Commands_util.Package = .{};
        const cmd_slice = std.fmt.bufPrint(&pkg.str, "{s}{s}{s}", .{
            prefix,
            get_cmd_string(.WIFI_DISCONNECT),
            postfix,
        }) catch unreachable;
        pkg.len = cmd_slice.len;
        self.runner_loop.store_tx_data(TXEventPkg{
            .cmd_enum = .WIFI_DISCONNECT,
            .Extra_data = .{ .Command = pkg },
        }, inst) catch return DriverError.TX_BUFFER_FULL;
    }

    pub fn WiFi_disconnect_device(self: *WiFiDevice, mac: []const u8) DriverError!void {
        const inst = self.runner_loop.runner_instance;
        self.runner_loop.store_tx_data(TXEventPkg{
            .cmd_enum = .WIFI_DISCONNECT_DEVICE,
            .Extra_data = .{
                .WiFi = .{
                    .MAC_config = mac,
                },
            },
        }, inst) catch return DriverError.TX_BUFFER_FULL;
    }

    pub fn set_WiFi_event_handler(self: *WiFiDevice, callback: WIFICallbackType, user_data: ?*anyopaque) void {
        self.on_WiFi_event = callback;
        self.WiFi_user_data = user_data;
    }

    pub fn link_device(self: *WiFiDevice, runner: anytype) void {
        const info = @typeInfo(@TypeOf(runner));
        switch (info) {
            .Pointer => |ptr| {
                const child_type = ptr.child;
                if (@hasField(child_type, "WiFi_device")) {
                    const device = &runner.WiFi_device;
                    if (@TypeOf(device.*) == *Device) {
                        self.device.device_instance = self;
                        device.* = &self.device;
                    } else {
                        @compileError("WiFi_device need to be a Device pointer");
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

    pub fn init() WiFiDevice {
        return WiFiDevice{};
    }
};