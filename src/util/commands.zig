const std = @import("std");

pub const Commands = enum(u8) {
    DUMMY,
    RESET,
    ECHO_OFF,
    ECHO_ON,
    SYSSTORE,
    SYSLOG,
    SYSMSG,
    IP_MUX,
    WIFI_SET_MODE,
    WiFi_SET_DHCP,
    WIFI_CONNECT,
    WIFI_CONF,
    WIFI_DISCONNECT,
    WIFI_DISCONNECT_DEVICE,
    WIFI_AUTOCONN,
    WIFI_STA_PROTO,
    WIFI_STA_IP,
    WIFI_STA_MAC,
    WIFI_AP_PROTO,
    WIFI_AP_IP,
    WIFI_AP_MAC,
    NETWORK_CONNECT,
    NETWORK_SEND,
    NETWORK_CLOSE,
    NETWORK_SERVER_CONF,
    NETWORK_SERVER_TIMEOUT,
    NETWORK_SERVER,
    NETWORK_RECV_MODE,
    NETWORK_RECV,
    NETWORK_MSG_CONFIG,
    //Extra

};

//This is not necessary since the user cannot send commands directly, but useful for debug
pub const COMMANDS_TOKENS = [_][]const u8{
    "AT",
    "RST",
    "ATE0",
    "ATE1",
    "SYSSTORE",
    "SYSLOG",
    "SYSMSG",
    "CIPMUX",
    "CWMODE",
    "CWDHCP",
    "CWJAP",
    "CWSAP",
    "CWQAP",
    "CWQIF",
    "CWAUTOCONN",
    "CWSTAPROTO",
    "CIPSTA",
    "CIPSTAMAC",
    "CWAPPROTO",
    "CIPAP",
    "CIPAPMAC",
    "CIPSTART",
    "CIPSENDEX",
    "CIPCLOSE",
    "CIPSERVERMAXCONN",
    "CIPSTO",
    "CIPSERVER",
    "CIPRECVTYPE",
    "CIPRECVDATA",
    "CIPDINFO",
};

pub inline fn get_cmd_string(cmd: Commands) []const u8 {
    return COMMANDS_TOKENS[@intFromEnum(cmd)];
}

pub const prefix = "AT+";
pub const infix = "_CUR";
pub const postfix = "\r\n";

pub fn get_cmd_slice(buffer: []const u8, start_tokens: []const u8, end_tokens: []const u8) []const u8 {
    var start: usize = 0;
    for (0..buffer.len) |index| {
        for (start_tokens) |token| {
            if (token == buffer[index]) {
                start = index;
                continue;
            }
        }

        for (end_tokens) |token| {
            if (token == buffer[index]) {
                return buffer[start..index];
            }
        }
    }
    return buffer[start..];
}

pub const CommandsErrorCode = enum(u32) {
    ESP_AT_SUB_OK = 0x00,
    ESP_AT_SUB_COMMON_ERROR = 0x01,
    ESP_AT_SUB_NO_TERMINATOR = 0x02,
    ESP_AT_SUB_NO_AT = 0x03,
    ESP_AT_SUB_PARA_LENGTH_MISMATCH = 0x04,
    ESP_AT_SUB_PARA_TYPE_MISMATCH = 0x05,
    ESP_AT_SUB_PARA_NUM_MISMATCH = 0x06,
    ESP_AT_SUB_PARA_INVALID = 0x07,
    ESP_AT_SUB_PARA_PARSE_FAIL = 0x08,
    ESP_AT_SUB_UNSUPPORT_CMD = 0x09,
    ESP_AT_SUB_CMD_EXEC_FAIL = 0x0A,
    ESP_AT_SUB_CMD_PROCESSING = 0x0B,
    ESP_AT_SUB_CMD_OP_ERROR = 0x0C,
    ESP_AT_UNKNOWN_ERROR = 0xFF,
};

pub const ResponseEvent = union(enum) {
    Ok: void,
    Fail: void,
    Error: CommandsErrorCode,
};

pub fn parser_error(str: []const u8) CommandsErrorCode {
    const error_slice = get_cmd_slice(str, &[_]u8{'x'}, &[_]u8{'\r'});
    if (error_slice.len < 8) return .ESP_AT_UNKNOWN_ERROR;
    const code = std.fmt.parseInt(u32, error_slice[1..], 16) catch return .ESP_AT_UNKNOWN_ERROR;
    const bit_check: u32 = (code >> 24 & (0xFF));

    if (bit_check != 0x01) return .ESP_AT_UNKNOWN_ERROR;
    const error_flag: u32 = code >> 16 & (0xFF);
    if (error_flag > @intFromEnum(CommandsErrorCode.ESP_AT_SUB_CMD_OP_ERROR)) return .ESP_AT_UNKNOWN_ERROR;
    return @enumFromInt(error_flag);
}
