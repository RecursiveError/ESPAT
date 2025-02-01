const std = @import("std");
const Commands = @import("commands.zig");
const prefix = Commands.prefix;
const postfix = Commands.postfix;
const cmd_enum = Commands.Commands;

pub const WiFiErrors = error{
    invalidSSID,
    invalidBSSID,
    invalidPassword,
    invalidReconnTime,
    invalidListenTime,
    invalidTimeout,
};

pub const Encryption = enum {
    OPEN,
    WPA_PSK,
    WPA2_PSK,
    WPA_WPA2_PSK,
};

pub const StaticIp = struct {
    ip: []const u8,
    gateway: ?[]const u8 = null,
    mask: ?[]const u8 = null,
};
pub const WiFiIp = union(enum) {
    static: StaticIp,
    DHCP: void,
};

pub const DHCPConfig = struct {
    lease: u16,
    start_ip: []const u8,
    end_ip: []const u8,
};

pub const Protocol = packed struct(u4) {
    @"802.11b": u1 = 0,
    @"802.11g": u1 = 0,
    @"802.11n": u1 = 0,
    @"802.11LR": u1 = 0,
};

pub const DHCPEnable = packed struct(u2) {
    STA: u1 = 1,
    AP: u1 = 1,
};

pub const DHCPMode = packed struct(u3) {};

pub const STApkg = struct {
    ssid: []const u8,
    pwd: ?[]const u8,
    bssid: ?[]const u8,
    pci_en: u1,
    reconn_interval: u32,
    listen_interval: u32,
    scan_mode: u1,
    jap_timeout: u32,
    pmf: u1,

    pub fn from_config(config: STAConfig) STApkg {
        return STApkg{
            .ssid = config.ssid,
            .pwd = config.pwd,
            .bssid = config.bssid,
            .pci_en = config.pci_en,
            .reconn_interval = config.reconn_interval,
            .listen_interval = config.listen_interval,
            .scan_mode = config.scan_mode,
            .jap_timeout = config.jap_timeout,
            .pmf = config.pmf,
        };
    }
};

pub const STAConfig = struct {
    ssid: []const u8,
    pwd: ?[]const u8 = null,
    bssid: ?[]const u8 = null,
    pci_en: u1 = 0,
    reconn_interval: u32 = 1,
    listen_interval: u32 = 3,
    scan_mode: u1 = 0, //fast scan
    jap_timeout: u32 = 15,
    pmf: u1 = 0, //pmf disable

    wifi_protocol: ?Protocol = null,
    mac: ?[]const u8 = null,
    wifi_ip: ?WiFiIp = null,
    host_name: ?[]const u8 = null,
};

pub const APpkg = struct {
    ssid: []const u8,
    pwd: ?[]const u8,
    channel: u8,
    ecn: Encryption,
    max_conn: u4,
    hidden_ssid: u1,

    pub fn from_config(config: APConfig) APpkg {
        return APpkg{
            .ssid = config.ssid,
            .pwd = config.pwd,
            .channel = config.channel,
            .ecn = config.ecn,
            .max_conn = config.max_conn,
            .hidden_ssid = config.hidden_ssid,
        };
    }
};

pub const APConfig = struct {
    ssid: []const u8,
    pwd: ?[]const u8 = null,
    channel: u8,
    ecn: Encryption,
    max_conn: u4 = 10,
    hidden_ssid: u1 = 0,

    wifi_protocol: ?Protocol = null,
    mac: ?[]const u8 = null,
    wifi_ip: ?WiFiIp = null,
    dhcp_config: ?DHCPConfig = null,
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

pub const BaseEvent = enum {
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

pub const Event = union(enum) {
    //Events received from the access point (when in station mode)
    AP_CON_START: void,
    AP_CONNECTED: void,
    AP_GOT_MASK: []const u8,
    AP_GOT_IP: []const u8,
    AP_GOT_GATEWAY: []const u8,
    AP_DISCONNECTED: void,
    //events received from the stations (when in access point mode)
    SCAN_START: void,
    SCAN_FIND: ScanData,
    SCAN_END: void,
    STA_CONNECTED: []const u8,
    STA_GOT_IP: DeviceInfo,
    STA_DISCONNECTED: []const u8,
    //events generated from WiFi errors
    ERROR: EventError,
};

const RESPOSE_TOKEN = std.StaticStringMap(BaseEvent).initComptime(.{
    .{ "DISCONNECT", BaseEvent.AP_DISCONNECTED },
    .{ "CONNECTED", BaseEvent.AP_CON_START },
    .{ "GOT IP", BaseEvent.AP_CONNECTED },
    .{ "ip", BaseEvent.AP_GOT_IP },
    .{ "gateway", BaseEvent.AP_GOT_GATEWAY },
    .{ "netmask", BaseEvent.AP_GOT_MASK },
});

pub const Package = union(enum) {
    scan: void,
    AP_conf_pkg: APpkg,
    STA_conf_pkg: STApkg,
    reconn: void,
    static_ap_config: StaticIp,
    static_sta_config: StaticIp,
    dhcp_config: DHCPConfig,
};

pub const AuthModeMask = packed struct(u10) {
    OPEN: bool,
    WEP: bool,
    WPA_PSK: bool,
    WPA2_PSK: bool,
    WPA_WPA2_PSK: bool,
    WPA2_ENTERPRISE: bool,
    WPA3_PSK: bool,
    WPA2_WPA3_PSK: bool,
    WAPI_PSK: bool,
    OWE: bool,
};

pub const ScanConfig = struct {
    rssi_filter: i8 = -100,
    auth_mode_mask: AuthModeMask = @bitCast(@as(u10, 0x3FF)),
};

pub const ScanECN = enum {
    OPEN,
    WEP,
    WPA_PSK,
    WPA2_PSK,
    WPA_WPA2_PSK,
    WPA2_ENTERPRISE,
    WPA3_PSK,
    WPA2_WPA3_PSK,
    WAPI_PSK,
    OWE,
};

pub const PairwiseCipher = enum {
    None,
    WEP40,
    WEP104,
    TKIP,
    CCMP,
    TKIP_CCMP,
    AES_CMAC_128,
    Unknown,
};

pub const ScanData = struct {
    ecn: ScanECN,
    ssid: []const u8,
    rssid: i8,
    mac: []const u8,
    channel: u16,
    freq_offset: i16,
    freqcal_val: i16,
    pair_wise_Cipher: PairwiseCipher,
    group_cipher: u8,
    bgn: Protocol,
    wps: bool,
};

pub fn get_base_event(event_str: []const u8) !BaseEvent {
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

//https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-guides/wifi.html#wi-fi-protocol-mode
pub fn check_protocol(proto: Protocol) !void {
    const value: u4 = @bitCast(proto);

    //check for BG
    if (value == 0b0101) return error.InvalidProtoConf;
    //1000
    //0b1xxx invalid proto
    //1111
    if ((value & 0b1000) != 0) {
        if ((value != 0b1000) or (value != 0b1111)) return error.InvalidProtoConf;
    }
}
pub fn check_static_ip(ip: StaticIp) !void {
    const ip_len = ip.ip.len;
    if ((ip_len > 15) or (ip_len < 7)) return error.InvalidIP;

    if (!std.net.isValidHostName(ip.ip)) {
        return error.InvalidIP;
    }

    if (ip.gateway) |gateway| {
        if (ip.mask) |mask| {
            const mask_len = mask.len;
            if ((mask_len > 15) or (mask_len < 7)) return error.InvalidGateWay;
            const gate_len = gateway.len;
            if ((gate_len > 15) or (gate_len < 7)) return error.InvalidGateWay;
            if (!std.net.isValidHostName(gateway) or !std.net.isValidHostName(mask)) {
                return error.InvalidNetConfig;
            }
        } else {
            //If the gateway is denified, mask is mandatory
            return error.NullMask;
        }
    }
}

fn check_DHCP_config(dhcp: DHCPConfig) !void {
    const lease = dhcp.lease;
    const st_len = dhcp.start_ip.len;
    const en_len = dhcp.end_ip.len;

    if ((lease < 1) or (lease > 2880)) return error.InvalidLease;
    if ((st_len > 15) or (st_len < 7)) return error.InvalidStartIP;
    if ((en_len > 15) or (en_len < 7)) return error.InvalidEndIP;
}

//TODO create a real IP and mac verify
pub fn check_STA_config(config: STAConfig) !usize {
    var pkgs: usize = 1;
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

    if (config.wifi_protocol) |proto| {
        pkgs += 1;
        try check_protocol(proto);
    }
    if (config.wifi_ip) |ip_config| {
        pkgs += 1;
        switch (ip_config) {
            .static => |ip| {
                try check_static_ip(ip);
            },
            else => {},
        }
    }

    if (config.mac) |mac| {
        pkgs += 1;
        if (mac.len != 17) return error.InvalidMac;
    }

    if (config.host_name) |name| {
        pkgs += 1;
        if (name.len > 32) return error.InvalidHostName;
    }
    return pkgs;
}

//TODO create a real IP and mac verify
pub fn check_AP_config(config: APConfig) !usize {
    var pkgs: usize = 1;
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

    if (config.wifi_protocol) |proto| {
        pkgs += 1;
        try check_protocol(proto);
    }

    if (config.wifi_ip) |ip_config| {
        pkgs += 1;
        switch (ip_config) {
            .static => |ip| {
                try check_static_ip(ip);
            },
            else => {},
        }
    }

    if (config.dhcp_config) |dhcp| {
        pkgs += 1;
        try check_DHCP_config(dhcp);
    }

    if (config.mac) |mac| {
        pkgs += 1;
        if (mac.len != 17) return error.InvalidMac;
    }
    return pkgs;
}

pub fn set_AP_config(out_buffer: []u8, config: APpkg) ![]const u8 {
    if (out_buffer.len < 200) return error.BufferTooSmall;
    var cmd_slice: []u8 = undefined;
    var cmd_size: usize = 0;
    cmd_slice = std.fmt.bufPrint(out_buffer, "{s}{s}=\"{s}\",", .{
        prefix,
        Commands.get_cmd_string(.WIFI_CONF),
        config.ssid,
    }) catch unreachable;
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
    cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], "{s}", .{postfix}) catch unreachable;
    cmd_size += cmd_slice.len;
    return out_buffer[0..cmd_size];
}

pub fn set_STA_config(out_buffer: []u8, config: STApkg) ![]const u8 {
    if (out_buffer.len < 200) return error.BufferTooSmall;
    var cmd_slice: []u8 = undefined;
    var cmd_size: usize = 0;
    cmd_slice = std.fmt.bufPrint(out_buffer, "{s}{s}=\"{s}\",", .{
        prefix,
        Commands.get_cmd_string(.WIFI_CONNECT),
        config.ssid,
    }) catch unreachable;
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
    cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], "{s}", .{postfix}) catch unreachable;
    cmd_size += cmd_slice.len;
    return out_buffer[0..cmd_size];
}

pub fn set_mac(out_buffer: []u8, cmd: cmd_enum, mac: []const u8) ![]const u8 {
    if (out_buffer.len < 50) return error.BufferTooSmall;
    var cmd_slice: []u8 = undefined;
    var cmd_size: usize = 0;
    cmd_slice = std.fmt.bufPrint(out_buffer, "{s}{s}=\"{s}\"{s}", .{
        prefix,
        Commands.get_cmd_string(cmd),
        mac,
        postfix,
    }) catch unreachable;
    cmd_size += cmd_slice.len;
    return out_buffer[0..cmd_size];
}

pub fn set_static_ip(out_buffer: []u8, cmd: cmd_enum, static_ip: StaticIp) ![]const u8 {
    if (out_buffer.len < 50) return error.BufferTooSmall;
    var cmd_slice: []u8 = undefined;
    var cmd_size: usize = 0;
    cmd_slice = std.fmt.bufPrint(out_buffer, "{s}{s}=\"{s}\"", .{
        prefix,
        Commands.get_cmd_string(cmd),
        static_ip.ip,
    }) catch unreachable;
    cmd_size += cmd_slice.len;

    if (static_ip.gateway) |gataway| {
        if (static_ip.mask) |mask| {
            cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], ",\"{s}\",\"{s}\"", .{ gataway, mask }) catch unreachable;
            cmd_size += cmd_slice.len;
        }
    }
    cmd_slice = std.fmt.bufPrint(out_buffer[cmd_size..], "{s}", .{postfix}) catch unreachable;
    cmd_size += cmd_slice.len;
    return out_buffer[0..cmd_size];
}

pub fn set_DHCP_config(out_buffer: []u8, config: DHCPConfig) ![]const u8 {
    if (out_buffer.len < 100) return error.BufferTooSmall;
    const cmd_slice = std.fmt.bufPrint(out_buffer, "{s}{s}=1,{d},\"{s}\",\"{s}\"{s}", .{
        prefix,
        Commands.get_cmd_string(.WiFi_CONF_DHCP),
        config.lease,
        config.start_ip,
        config.end_ip,
        postfix,
    }) catch unreachable;
    const cmd_size = cmd_slice.len;
    return out_buffer[0..cmd_size];
}

pub fn parser_scan_data(data: []const u8) !ScanData {
    var scandata: ScanData = undefined;
    var split_data = std.mem.tokenizeSequence(u8, data[8..], ",");
    //check ecn
    if (split_data.next()) |d| {
        const val = try std.fmt.parseInt(u4, d, 10);
        if (val > 10) return error.InvalidECN;
        scandata.ecn = @enumFromInt(val);
    } else {
        return error.InvalidECN;
    }
    //get SSID
    if (split_data.next()) |d| {
        scandata.ssid = d[1..(d.len - 1)];
    } else {
        return error.InvalidSSID;
    }

    //get RSSID
    if (split_data.next()) |d| {
        const val = try std.fmt.parseInt(i8, d, 10);
        scandata.rssid = val;
    } else {
        return error.InvalidRSSID;
    }

    //get mac
    if (split_data.next()) |d| {
        scandata.mac = d[1..(d.len - 1)];
    } else {
        return error.InvalidMAC;
    }

    //get channel
    if (split_data.next()) |d| {
        const val = try std.fmt.parseInt(u16, d, 10);
        scandata.channel = val;
    } else {
        return error.InvalidChannel;
    }

    //get freq_offset
    if (split_data.next()) |d| {
        const val = try std.fmt.parseInt(i16, d, 10);
        scandata.freq_offset = val;
    } else {
        return error.InvalidFreQ;
    }
    //get FraqCalib value
    if (split_data.next()) |d| {
        const val = try std.fmt.parseInt(i16, d, 10);
        scandata.freqcal_val = val;
    } else {
        return error.InvalidFreq;
    }

    //get pair wise value
    if (split_data.next()) |d| {
        const val = try std.fmt.parseInt(u8, d, 10);
        scandata.pair_wise_Cipher = @enumFromInt(val);
    } else {
        return error.InvalidPairWise;
    }

    if (split_data.next()) |d| {
        const val = try std.fmt.parseInt(u8, d, 10);
        scandata.group_cipher = val;
    } else {
        return error.InvalidPairWise;
    }

    //get protocol
    if (split_data.next()) |d| {
        const val = try std.fmt.parseInt(u4, d, 10);
        scandata.bgn = @bitCast(val);
    } else {
        return error.InvalidProtocol;
    }

    if (split_data.next()) |d| {
        scandata.wps = (d[0] == '1');
    } else {
        return error.InvalidWPS;
    }

    return scandata;
}
