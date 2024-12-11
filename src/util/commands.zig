pub const Commands = enum(u8) {
    DUMMY,
    RESET,
    ECHO_OFF,
    ECHO_ON,
    SYSSTORE,
    IP_MUX,
    WIFI_SET_MODE,
    WIFI_CONNECT,
    WIFI_CONF,
    WIFI_DISCONNECT,
    WIFI_AUTOCONN,
    NETWORK_CONNECT,
    NETWORK_SEND,
    NETWORK_CLOSE,
    NETWORK_IP,
    NETWORK_SERVER_CONF,
    NETWORK_SERVER,
    NETWORK_RECV_MODE,
    NETWORK_RECV,
    NETWORK_MSG_CONFIG,
    //Extra

};

//This is not necessary since the user cannot send commands directly, but useful for debug
pub const COMMANDS_TOKENS = [_][]const u8{
    ".",
    "RST",
    "ATE0",
    "ATE1",
    "SYSSTORE",
    "CIPMUX",
    "CWMODE",
    "CWJAP",
    "CWSAP",
    "CWQAP",
    "CWAUTOCONN",
    "CIPSTART",
    "CIPSENDEX",
    "CIPCLOSE",
    "CIPSTA",
    "CIPSERVERMAXCONN",
    "CIPSERVER",
    "CIPRECVMODE",
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
