const std = @import("std");

const Types = @import("Types.zig");
const Device = Types.Device;
const Runner = Types.Runner;
const ToRead = Types.ToRead;
const DeviceError = Types.DeviceError;
const RunnerError = Types.RunnerError;

const Commands_util = @import("util/commands.zig");
const Commands = Commands_util.Commands;
const get_cmd_string = Commands_util.get_cmd_string;
const get_cmd_slice = Commands_util.get_cmd_slice;
const infix = Commands_util.infix;
const prefix = Commands_util.prefix;
const postfix = Commands_util.postfix;

const WiFi = @import("util/WiFi.zig");
pub const Package = WiFi.Package;
pub const APConfig = WiFi.APConfig;
pub const STAConfig = WiFi.STAConfig;
pub const Event = WiFi.Event;
pub const Encryption = WiFi.Encryption;
pub const ScanConfig = WiFi.ScanConfig;

pub const DriverMode = enum { NONE, STA, AP, AP_STA };

pub const state = enum {
    OFF,
    DISCONECTED,
    CONNECTED,
};

pub const WiFiError = DeviceError || WiFi.WiFiErrors || error{
    OFF,
    STA_OFF,
    AP_OFF,
    BAD_RSSI,
    LINK_FAIL,
};

pub const WIFICallbackType = ?*const fn (event: WiFi.Event, user_data: ?*anyopaque) void;

const lastFlag = enum {
    NONE,
    STA,
    SCAN,
};

pub const Config = struct {
    callback: WIFICallbackType,
    user_data: ?*anyopaque,
    cmd_buffer: []Package,
    runner: *const Runner,
    WiFi_mode: DriverMode,
};

pub const WiFiDevice = struct {
    const CMD_CALLBACK_TYPE = *const fn (self: *WiFiDevice, buffer: []const u8) DeviceError!void;
    const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
        .{ "WIFI", WiFiDevice.wifi_response },
        .{ "+CWLAP", WiFiDevice.WiFi_get_scan_data },
        .{ "+CIPSTA", WiFiDevice.WiFi_get_AP_info },
        .{ "+CWJAP", WiFiDevice.WiFi_error },
        .{ "+STA_CONNECTED", WiFiDevice.WiFi_get_device_conn_mac },
        .{ "+DIST_STA_IP", WiFiDevice.WiFi_get_device_ip },
        .{ "+STA_DISCONNECTED", WiFiDevice.WiFi_get_device_disc_mac },
    });

    runner_dev: *const Runner = undefined,
    wifi_dev: Device = .{
        .send_data_fn = send_data,
        .check_cmd_fn = check_cmd,
        .get_cmd_fn = get_cmd,
        .ok_handler_fn = ok_handler,
        .err_handler_fn = err_handler,
        .send_handler_fn = send_handler,
        .reset_fn = reset,
    },

    cmd_queue: std.ArrayList(Package),
    id: u32 = std.math.maxInt(u32), //invalid id
    Wifi_state: state = .OFF,
    Wifi_mode: DriverMode = .NONE,
    WiFi_dhcp: WiFi.DHCPEnable = .{},
    //callback handlers
    WiFi_user_data: ?*anyopaque = null,
    on_WiFi_event: WIFICallbackType = null,
    lastflag: lastFlag align(1) = .NONE,

    //Device functions

    fn send_data(_: *const Device, _: *std.io.Writer) DeviceError!void {
        return DeviceError.NO_SEND_DATA;
    }

    fn check_cmd(device: *const Device, cmd: []const u8, all: []const u8) DeviceError!void {
        const self: *WiFiDevice = @alignCast(@constCast(@fieldParentPtr("wifi_dev", device)));
        const response_callback = cmd_response_map.get(cmd);
        if (response_callback) |callback| {
            try @call(.auto, callback, .{ self, all });
            return;
        }
    }

    fn get_cmd(device: *const Device, writer: *std.io.Writer) DeviceError!void {
        const self: *WiFiDevice = @alignCast(@constCast(@fieldParentPtr("wifi_dev", device)));
        const pkg = self.cmd_queue.pop() orelse return DeviceError.QUEUE_EMPTY;

        switch (pkg) {
            .init_wifi => {
                writer.print("{s}{s}={d}{s}", .{
                    prefix,
                    "CWINIT",
                    1,
                    postfix,
                }) catch unreachable;
            },
            .disable_auto_reconn => {
                writer.print("{s}{s}={d}{s}", .{
                    prefix,
                    Commands_util.get_cmd_string(.WIFI_AUTOCONN),
                    0,
                    postfix,
                }) catch unreachable;
            },
            .set_mode => {
                writer.print("{s}{s}={d}{s}", .{
                    prefix,
                    get_cmd_string(.WIFI_SET_MODE),
                    @intFromEnum(self.Wifi_mode),
                    postfix,
                }) catch unreachable;
            },
            .get_ip => {
                writer.print("{s}{s}?{s}", .{
                    prefix,
                    Commands_util.get_cmd_string(.WIFI_STA_IP),
                    postfix,
                }) catch unreachable;
            },
            .scan => {
                if (self.on_WiFi_event) |callback| {
                    callback(Event{ .SCAN_START = {} }, self.WiFi_user_data);
                }
                self.lastflag = .SCAN;
                writer.print("{s}{s}{s}", .{
                    prefix,
                    "CWLAP",
                    postfix,
                }) catch unreachable;
            },
            .scan_config => |scanconfig| {
                self.lastflag = .NONE; //TODO handler scan config error
                const rssi = if (scanconfig.rssi_filter < -100) -100 else if (scanconfig.rssi_filter > 40) 40 else scanconfig.rssi_filter;
                writer.print("{s}{s}=,{d},{d},{d}{s}", .{
                    prefix,
                    "CWLAPOPT",
                    0x7FF,
                    rssi,
                    @as(u10, @bitCast(scanconfig.auth_mode_mask)),
                    postfix,
                }) catch unreachable;
            },
            .AP_conf_pkg => |wpkg| {
                WiFi_apply_AP_config(wpkg, writer);
            },
            .STA_conf_pkg => |wpkg| {
                self.runner_dev.set_busy_flag(true, self.id) catch unreachable;
                self.lastflag = .STA;
                WiFi_apply_STA_config(wpkg, writer);
            },
            .reconn => |_| {
                self.runner_dev.set_busy_flag(true, self.id) catch unreachable;
                self.lastflag = .STA;
                writer.print("{s}{s}{s}", .{
                    prefix,
                    get_cmd_string(.WIFI_CONNECT),
                    postfix,
                }) catch unreachable;
            },
            .static_ip_config => |wpkg| {
                const ip_mode = if (wpkg.wt == .AP) Commands.WIFI_AP_IP else Commands.WIFI_STA_IP;
                apply_static_ip(ip_mode, wpkg.ip, writer);
            },
            .dhcp => {
                writer.print("{s}{s}=1,{d}{s}", .{
                    prefix,
                    get_cmd_string(.WiFi_SET_DHCP),
                    @as(u2, @bitCast(self.WiFi_dhcp)),
                    postfix,
                }) catch unreachable;
            },
            .dhcp_config => |wpkg| {
                apply_DHCP_config(wpkg, writer);
            },
            .mac => |wpkg| {
                const cmd = if (wpkg.wt == .AP) Commands.WIFI_AP_MAC else Commands.WIFI_STA_MAC;
                apply_WiFi_mac(cmd, wpkg.mac, writer);
            },
            .host_name => |name| {
                writer.print("{s}{s}=\"{s}\"{s}", .{
                    prefix,
                    "CWHOSTNAME",
                    name,
                    postfix,
                }) catch unreachable;
            },
            .proto_config => |proto| {
                const cmd = if (proto.wt == .STA) Commands.WIFI_STA_PROTO else Commands.WIFI_AP_PROTO;
                writer.print("{s}{s}={d}{s}", .{
                    prefix,
                    get_cmd_string(cmd),
                    @as(u4, @bitCast(proto.proto)),
                    postfix,
                }) catch unreachable;
            },
            .disconnect => {
                writer.print("{s}{s}{s}", .{
                    prefix,
                    get_cmd_string(.WIFI_DISCONNECT),
                    postfix,
                }) catch unreachable;
            },
            .disconnect_device => |mac| {
                writer.print("{s}{s}=\"{s}\"{s}", .{
                    prefix,
                    get_cmd_string(.WIFI_DISCONNECT_DEVICE),
                    mac,
                    postfix,
                }) catch unreachable;
            },
        }
        writer.flush() catch {};
    }

    inline fn apply_WiFi_mac(cmd: Commands, mac: []const u8, writer: *std.io.Writer) void {
        return WiFi.set_mac(writer, mac, cmd);
    }

    inline fn apply_static_ip(cmd_data: Commands, ip: WiFi.StaticIp, writer: *std.io.Writer) void {
        return WiFi.set_static_ip(writer, cmd_data, ip);
    }

    inline fn apply_DHCP_config(dhcp: WiFi.DHCPConfig, writer: *std.io.Writer) void {
        return WiFi.set_DHCP_config(writer, dhcp);
    }

    inline fn WiFi_apply_AP_config(config: WiFi.APpkg, writer: *std.io.Writer) void {
        return WiFi.set_AP_config(config, writer);
    }

    inline fn WiFi_apply_STA_config(config: WiFi.STApkg, writer: *std.io.Writer) void {
        return WiFi.set_STA_config(writer, config);
    }

    fn ok_handler(device: *const Device) void {
        response_handler(device);
    }
    fn err_handler(device: *const Device) void {
        response_handler(device);
    }

    fn response_handler(device: *const Device) void {
        var self: *WiFiDevice = @alignCast(@constCast(@fieldParentPtr("wifi_dev", device)));
        switch (self.lastflag) {
            .STA => {
                self.runner_dev.set_busy_flag(false, self.id) catch unreachable;
            },
            .SCAN => {
                if (self.on_WiFi_event) |callback| {
                    callback(Event{ .SCAN_END = {} }, self.WiFi_user_data);
                }
            },
            .NONE => return,
        }
        self.lastflag = .NONE;
    }

    //WiFI does not have send events
    fn send_handler(_: *const Device, _: bool) void {}

    fn reset(device: *const Device) DeviceError!void {
        var self: *WiFiDevice = @alignCast(@constCast(@fieldParentPtr("wifi_dev", device)));
        self.Wifi_state = .OFF;
        self.lastflag = .NONE;
        self.cmd_queue.clearRetainingCapacity();
        self.runner_dev.queue_multi(self.id, 3) catch return DeviceError.QUEUE_FAIL;

        self.cmd_queue.insertAssumeCapacity(0, .{ .init_wifi = {} });
        self.cmd_queue.insertAssumeCapacity(0, .{ .disable_auto_reconn = {} });
        self.cmd_queue.insertAssumeCapacity(0, .{ .set_mode = {} });
    }

    fn wifi_response(self: *WiFiDevice, aux_buffer: []const u8) DeviceError!void {
        const wifi_event_slice = get_cmd_slice(aux_buffer[5..], &[_]u8{}, &[_]u8{'\r'});
        const base_event = WiFi.get_base_event(wifi_event_slice) catch return DeviceError.CMD_FAIL;
        const event: Event = switch (base_event) {
            .AP_DISCONNECTED => Event{ .AP_DISCONNECTED = {} },
            .AP_CON_START => Event{ .AP_CON_START = {} },
            .AP_CONNECTED => Event{ .AP_CONNECTED = {} },
            else => unreachable,
        };

        if (base_event == .AP_CONNECTED) {
            self.runner_dev.queue(self.id) catch return DeviceError.SETUP_FAIL;
            self.cmd_queue.insertBounded(0, .{ .get_ip = {} }) catch return DeviceError.QUEUE_FULL;
        }
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    fn WiFi_get_scan_data(self: *WiFiDevice, aux_buffer: []const u8) DeviceError!void {
        const data = WiFi.parser_scan_data(aux_buffer) catch return DeviceError.CMD_FAIL;
        if (self.on_WiFi_event) |callback| {
            callback(Event{ .SCAN_FIND = data }, self.WiFi_user_data);
        }
    }

    fn WiFi_get_AP_info(self: *WiFiDevice, aux_buffer: []const u8) DeviceError!void {
        const event_slice = get_cmd_slice(aux_buffer[8..], &[_]u8{}, &[_]u8{':'});
        const data_start = event_slice.len + 10;
        const data_slice = get_cmd_slice(aux_buffer[data_start..], &[_]u8{}, &[_]u8{'"'});
        const base_event = WiFi.get_base_event(event_slice) catch return DeviceError.CMD_FAIL;
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

    fn WiFi_error(self: *WiFiDevice, aux_buffer: []const u8) DeviceError!void {
        self.runner_dev.set_busy_flag(false, self.id) catch unreachable;
        if (aux_buffer.len < 8) return DeviceError.CMD_FAIL;
        const error_id = WiFi.get_error_event(aux_buffer);
        const event = Event{ .ERROR = error_id };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    fn WiFi_get_device_conn_mac(self: *WiFiDevice, aux_buffer: []const u8) DeviceError!void {
        if (aux_buffer.len < 34) return DeviceError.CMD_FAIL;
        const mac = aux_buffer[16..33];
        const event = Event{ .STA_CONNECTED = mac };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }
    fn WiFi_get_device_ip(self: *WiFiDevice, aux_buffer: []const u8) DeviceError!void {
        if (aux_buffer.len < 46) return DeviceError.CMD_FAIL;
        const mac = get_cmd_slice(aux_buffer[14..], &[_]u8{}, &[_]u8{'"'});
        const ip = get_cmd_slice(aux_buffer[34..], &[_]u8{}, &[_]u8{'"'});
        const event = Event{ .STA_GOT_IP = .{ .ip = ip, .mac = mac } };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    fn WiFi_get_device_disc_mac(self: *WiFiDevice, aux_buffer: []const u8) DeviceError!void {
        if (aux_buffer.len < 37) return DeviceError.CMD_FAIL;
        const mac = aux_buffer[19..36];
        const event = Event{ .STA_DISCONNECTED = mac };
        if (self.on_WiFi_event) |callback| {
            callback(event, self.WiFi_user_data);
        }
    }

    //WiFi functions

    pub fn scan(self: *WiFiDevice, scanconfig: ScanConfig) WiFiError!void {
        if (self.Wifi_mode == .NONE) return WiFiError.OFF;
        if ((scanconfig.rssi_filter < -100) or (scanconfig.rssi_filter > 40)) return WiFiError.BAD_RSSI;
        self.runner_dev.queue_multi(self.id, 2) catch return WiFiError.QUEUE_FULL;

        self.cmd_queue.insertBounded(0, .{ .scan_config = scanconfig }) catch return WiFiError.QUEUE_FULL;
        self.cmd_queue.insertBounded(0, .{ .scan = {} }) catch return WiFiError.QUEUE_FULL;
    }

    pub fn WiFi_connect_AP(self: *WiFiDevice, config: STAConfig) WiFiError!void {
        if (self.Wifi_mode == .AP) {
            return WiFiError.STA_OFF;
        } else if (self.Wifi_mode == DriverMode.NONE) {
            return WiFiError.OFF;
        }

        const pkgs = try WiFi.check_STA_config(config);
        self.runner_dev.queue_multi(self.id, pkgs) catch return WiFiError.QUEUE_FULL;
        if ((self.cmd_queue.capacity - self.cmd_queue.items.len) < pkgs) {
            return WiFiError.QUEUE_FULL;
        }

        if (config.wifi_protocol) |proto| {
            self.cmd_queue.insertAssumeCapacity(0, .{ .proto_config = .{
                .wt = .STA,
                .proto = proto,
            } });
        }

        if (config.mac) |mac| {
            self.cmd_queue.insertAssumeCapacity(0, .{ .mac = .{
                .wt = .STA,
                .mac = mac,
            } });
        }

        if (config.wifi_ip) |ip_mode| {
            switch (ip_mode) {
                .DHCP => {
                    self.WiFi_dhcp.STA = 1;
                    self.cmd_queue.insertAssumeCapacity(0, .{ .dhcp = {} });
                },
                .static => |static_ip| {
                    self.WiFi_dhcp.STA = 0;
                    self.cmd_queue.insertAssumeCapacity(0, .{ .static_ip_config = .{
                        .wt = .STA,
                        .ip = static_ip,
                    } });
                },
            }
        }

        if (config.host_name) |name| {
            self.cmd_queue.insertAssumeCapacity(0, .{ .host_name = name });
        }

        self.cmd_queue.insertAssumeCapacity(0, .{ .STA_conf_pkg = WiFi.STApkg.from_config(config) });
    }

    pub fn WiFI_reconnect(self: *WiFiDevice) WiFiError!void {
        self.runner_dev.queue(self.id) catch return WiFiError.QUEUE_FAIL;
        self.cmd_queue.insertBounded(0, .{ .reconn = {} }) catch return WiFiError.QUEUE_FULL;
    }

    pub fn WiFi_config_AP(self: *WiFiDevice, config: APConfig) WiFiError!void {
        if (self.Wifi_mode == .STA) {
            return WiFiError.AP_OFF;
        } else if (self.Wifi_mode == .NONE) {
            return WiFiError.OFF;
        }
        const pkgs = try WiFi.check_AP_config(config);
        self.runner_dev.queue_multi(self.id, pkgs) catch return WiFiError.QUEUE_FULL;
        if ((self.cmd_queue.capacity - self.cmd_queue.items.len) < pkgs) {
            return WiFiError.QUEUE_FULL;
        }

        if (config.wifi_protocol) |proto| {
            self.cmd_queue.insertAssumeCapacity(0, .{ .proto_config = .{
                .wt = .AP,
                .proto = proto,
            } });
        }

        if (config.mac) |mac| {
            self.cmd_queue.insertAssumeCapacity(0, .{ .mac = .{
                .wt = .AP,
                .mac = mac,
            } });
        }

        if (config.wifi_ip) |ip_mode| {
            switch (ip_mode) {
                .DHCP => {
                    self.WiFi_dhcp.AP = 1;
                    self.cmd_queue.insertAssumeCapacity(0, .{ .dhcp = {} });
                },
                .static => |static_ip| {
                    self.WiFi_dhcp.AP = 0;
                    self.cmd_queue.insertAssumeCapacity(0, .{ .static_ip_config = .{
                        .wt = .AP,
                        .ip = static_ip,
                    } });
                },
            }
        }

        if (config.dhcp_config) |dhcp| {
            self.cmd_queue.insertAssumeCapacity(0, .{ .dhcp_config = dhcp });
        }
        self.cmd_queue.insertAssumeCapacity(0, .{ .AP_conf_pkg = WiFi.APpkg.from_config(config) });
    }

    pub fn WiFi_disconnect(self: *WiFiDevice) WiFiError!void {
        if (self.Wifi_mode == .STA) {
            return WiFiError.STA_OFF;
        } else if (self.Wifi_mode == .NONE) {
            return WiFiError.OFF;
        }
        self.runner_dev.queue(self.id) catch return WiFiError.QUEUE_FAIL;
        self.cmd_queue.insertBounded(0, .{ .disconnect = {} }) catch return WiFiError.QUEUE_FULL;
    }

    pub fn WiFi_disconnect_device(self: *WiFiDevice, mac: []const u8) WiFiError!void {
        if (self.Wifi_mode == .STA) {
            return WiFiError.AP_OFF;
        } else if (self.Wifi_mode == .NONE) {
            return WiFiError.OFF;
        }

        self.runner_dev.queue(self.id) catch return WiFiError.QUEUE_FAIL;
        self.cmd_queue.insertBounded(0, .{ .disconnect_device = mac }) catch return WiFiError.QUEUE_FULL;
    }

    pub fn link_device(self: *WiFiDevice) WiFiError!void {
        self.id = self.runner_dev.link_device(&self.wifi_dev) catch return WiFiError.LINK_FAIL;
    }

    pub fn init(config: Config) WiFiDevice {
        return WiFiDevice{
            .cmd_queue = std.ArrayList(Package).initBuffer(config.cmd_buffer),
            .runner_dev = config.runner,
            .Wifi_mode = config.WiFi_mode,
            .on_WiFi_event = config.callback,
            .WiFi_user_data = config.user_data,
        };
    }
};
