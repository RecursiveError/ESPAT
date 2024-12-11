const std = @import("std");

pub const WiFiErrors = error{
    invalidSSID,
    invalidBSSID,
    invalidPassword,
    invalidReconnTime,
    invalidListenTime,
    invalidTimeout,
};

pub const WiFiEncryption = enum {
    OPEN,
    WPA_PSK,
    WPA2_PSK,
    WPA_WPA2_PSK,
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
};

pub const WiFiAPConfig = struct {
    ssid: []const u8,
    pwd: ?[]const u8 = null,
    channel: u8,
    ecn: WiFiEncryption,
    max_conn: u4 = 10,
    hidden_ssid: u1 = 0,
};

pub const EventError = enum {
    Timeout,
    Password,
    SSID,
    FAIL,
    Unknown,
};

pub const DeviceInfo = struct {
    mac: []const u8,
    ip: []const u8,
};

pub const WiFiBaseEvent = enum {
    AP_CON_START,
    AP_CONNECTED,
    AP_GOT_MASK,
    AP_GOT_IP,
    AP_GOT_GATEWAY,
    AP_DISCONNECTED,
    //events received from the stations (when in access point mode)
    STA_CONNECTED,
    STA_GOT_IP,
    STA_DISCONNECTED,
    ERROR,
};

pub const WifiEvent = union(enum) {
    //Events received from the access point (when in station mode)
    AP_CON_START: void,
    AP_CONNECTED: void,
    AP_GOT_MASK: []const u8,
    AP_GOT_IP: []const u8,
    AP_GOT_GATEWAY: []const u8,
    AP_DISCONNECTED: void,
    //events received from the stations (when in access point mode)
    STA_CONNECTED: []const u8,
    STA_GOT_IP: DeviceInfo,
    STA_DISCONNECTED: []const u8,
    //events generated from WiFi errors
    ERROR: EventError,
};

const RESPOSE_TOKEN = std.StaticStringMap(WiFiBaseEvent).initComptime(.{
    .{ "DISCONNECT", WiFiBaseEvent.AP_DISCONNECTED },
    .{ "CONNECTED", WiFiBaseEvent.AP_CON_START },
    .{ "GOT IP", WiFiBaseEvent.AP_CONNECTED },
    .{ "ip", WiFiBaseEvent.AP_GOT_IP },
    .{ "gateway", WiFiBaseEvent.AP_GOT_GATEWAY },
    .{ "netmask", WiFiBaseEvent.AP_GOT_MASK },
});

pub fn get_base_event(event_str: []const u8) !WiFiBaseEvent {
    const event = RESPOSE_TOKEN.get(event_str);
    if (event) |data| {
        return data;
    }
    return error.EventNotFound;
}

pub fn get_error_event(event_str: []const u8) EventError {
    const error_id: u8 = event_str[7];
    if ((error_id < '1') or (error_id > '4')) return EventError.Unknown;
    return @enumFromInt(error_id - '0');
}

pub fn check_AP_config(config: WiFiAPConfig) !void {
    const ssid_len = config.ssid.len;
    if ((ssid_len < 1) or (ssid_len > 32)) return WiFiErrors.invalidSSID;

    //WiFi is not OPEN, PASSWORD can't be null (pwd has no effect if ECN is OPEN)
    if (config.ecn != .OPEN) {
        if (config.pwd) |pwd| {
            const pwd_len = pwd.len;
            if ((pwd_len < 8) or (pwd_len > 60)) return WiFiErrors.invalidPassword;
        } else {
            return WiFiErrors.invalidPassword;
        }
    }
}

pub fn set_AP_config(out_buffer: []u8, cmd: []const u8, config: WiFiAPConfig) ![]const u8 {
    if (out_buffer.len < 200) return error.BufferTooSmall;
    var cmd_slice: []u8 = undefined;
    var cmd_size: usize = 0;
    cmd_slice = std.fmt.bufPrint(out_buffer, "{s}\"{s}\",", .{ cmd, config.ssid }) catch unreachable;
    cmd_size += cmd_slice.len;
    if (config.pwd) |pwd| {
        cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], "\"{s}\",", .{pwd}) catch unreachable;
        cmd_size += cmd_slice.len;
    } else {
        cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], ",", .{}) catch unreachable;
        cmd_size += cmd_slice.len;
    }

    cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], "{d},{d}", .{
        config.channel,
        @intFromEnum(config.ecn),
    }) catch unreachable;
    cmd_size += cmd_slice.len;
    cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], ",{d},{d}", .{
        config.max_conn,
        config.hidden_ssid,
    }) catch unreachable;
    cmd_size += cmd_slice.len;
    cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], "{s}", .{"\r\n"}) catch unreachable;
    cmd_size += cmd_slice.len;
    return out_buffer[0..cmd_size];
}

pub fn check_STA_config(config: WiFiSTAConfig) !void {
    const ssid_len = config.ssid.len;
    if ((ssid_len < 1) or (ssid_len > 32)) return WiFiErrors.invalidSSID;

    if (config.pwd) |pwd| {
        const pwd_len = pwd.len;
        if ((pwd_len < 8) or (pwd_len > 60)) return WiFiErrors.invalidPassword;
    }

    if (config.bssid) |bssid| {
        if (bssid.len < 17) return WiFiErrors.invalidBSSID;
    }

    if (config.reconn_interval > 7200) return WiFiErrors.invalidReconnTime;
    if (config.listen_interval > 100) return WiFiErrors.invalidListenTime;
    if (config.jap_timeout > 600) return WiFiErrors.invalidTimeout;
}
pub fn set_STA_config(out_buffer: []u8, cmd: []const u8, config: WiFiSTAConfig) ![]u8 {
    if (out_buffer.len < 200) return error.BufferTooSmall;
    var cmd_slice: []u8 = undefined;
    var cmd_size: usize = 0;
    cmd_slice = std.fmt.bufPrint(out_buffer, "{s}\"{s}\",", .{ cmd, config.ssid }) catch unreachable;
    cmd_size += cmd_slice.len;
    if (config.pwd) |pwd| {
        cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], "\"{s}\",", .{pwd}) catch unreachable;
        cmd_size += cmd_slice.len;
    } else {
        cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], ",", .{}) catch unreachable;
        cmd_size += cmd_slice.len;
    }
    if (config.bssid) |bssid| {
        cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], "\"{s}\",", .{bssid}) catch unreachable;
        cmd_size += cmd_slice.len;
    } else {
        cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], ",", .{}) catch unreachable;
        cmd_size += cmd_slice.len;
    }
    cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], "{d},{d},{d},{d},{d},{d}", .{
        config.pci_en,
        config.reconn_interval,
        config.listen_interval,
        config.scan_mode,
        config.jap_timeout,
        config.pmf,
    }) catch unreachable;
    cmd_size += cmd_slice.len;
    cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], "{s}", .{"\r\n"}) catch unreachable;
    cmd_size += cmd_slice.len;
    return out_buffer[0..cmd_size];
}
