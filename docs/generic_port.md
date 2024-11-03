TODO
base code
```zig
const ESP_AT = @import("ESPAT");
const zig_serial = @import("serial");
const std = @import("std");

var rv_internal_buf: [4096]u8 = undefined;
fn rx_callback(free_size: usize, user_data: ?*anyopaque) []u8 {
    if (user_data) |data| {
        const serial: *std.fs.File = @ptrCast(@alignCast(data));
        rv_internal_buf = std.mem.zeroes([4096]u8);
        var size: usize = 0;
        for (0..free_size) |_| {
            const b = serial.reader().readByte() catch break;
            rv_internal_buf[size] = b;
            size += 1;
            if (b == 0) _ = std.log.info("here", .{});
            if (b == '\n' or b == '>') break;
        }
        _ = std.log.info("RX got {s}", .{rv_internal_buf[0..size]});
        return rv_internal_buf[0..size];
    }
    _ = std.log.info("null args on RX", .{});

    return rv_internal_buf[0..0];
}

fn TX_callback(data: []const u8, user_data: ?*anyopaque) void {
    if (user_data) |userdata| {
        const serial: *std.fs.File = @ptrCast(@alignCast(userdata));
        var end: usize = data.len;
        for (0..data.len) |index| {
            if (data[index] == 0) {
                end = index;
                break;
            }
        }
        _ = std.log.info("TX Send  {s}", .{data[0..end]});
        serial.writer().writeAll(data[0..end]) catch return;
    }
}

const ATdrive = ESP_AT.create_drive(4096, 10);
const wifi_ssid = "SSID";
const wifi_password = "pwd";
const server_port: u16 = 1234;

fn result_callback(result: ESP_AT.CommandResults, cmd: ESP_AT.commands_enum, user_data: ?*anyopaque) void {
    _ = user_data;
    const command = ESP_AT.COMMANDS_TOKENS[@intFromEnum(cmd)];
    if (result == ESP_AT.CommandResults.Ok) {
        _ = std.log.info("Command {s} return Ok", .{command});
    } else {
        _ = std.log.info("Command {s} return FAIL", .{command});
    }
}

fn device_callback(event: ESP_AT.WifiEvent, data: ?[]const u8, user_data: ?*anyopaque) void {
    _ = user_data;
    switch (event) {
        ESP_AT.WifiEvent.WiFi_AP_CON_START => {
            _ = std.log.info("START WIFI!!!", .{});
        },
        ESP_AT.WifiEvent.WiFi_AP_DISCONNECTED => {
            _ = std.log.info("FAIL TO CONNECT TO WIFI!!!", .{});
        },
        ESP_AT.WifiEvent.WiFi_AP_CONNECTED => {
            _ = std.log.info("WIFI CONNECTED TO {s}", .{wifi_ssid});
        },
        ESP_AT.WifiEvent.WiFi_AP_GOT_IP => {
            if (data) |ip| {
                _ = std.log.info("WIFI GOT  IP {s}", .{ip});
            }
        },
        else => {
            std.debug.print("event {} data {any}", .{ event, data });
        },
    }
}

const html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<!DOCTYPE html>\r\n<html lang=\"pt-BR\">\r\n<head>\r\n<meta charset=\"UTF-8\">\r\n<title>Hello World</title>\r\n<p>All Your Codebase Are Belong To Us</p>\r\n</head>\r\n<body>\r\n<h1>Hello World</h1>\r\n</body>\r\n</html>\r\n";

fn server_callback(client: ATdrive.Client, user_data: ?*anyopaque) void {
    _ = user_data;
    switch (client.event) {
        .Connected => {},
        .Closed => {},
        .ReciveData => {
            if (client.rev) |data| {
                _ = std.log.info("server got {s}", .{data});
            }
            client.send(@constCast(html)) catch |err| {
                _ = std.log.info("SERVER: got error {}, on bind {}", .{ err, client.id });
            };
            client.close() catch |err| {
                _ = std.log.info("SERVER: close got error {}", .{err});
            };
        },
        .SendDataComplete => {},
        .SendDataFail => {},
    }
}

const STA_config = ESP_AT.WiFiSTAConfig{
    .ssid = wifi_ssid,
    .pwd = wifi_password,
};

const AP_config = ESP_AT.WiFiAPConfig{
    .ssid = "banana",
    .channel = 5,
    .ecn = ESP_AT.WiFi_encryption.OPEN,
};

pub fn main() !void {
    const port_name = "\\\\.\\COM4";

    var serial = std.fs.cwd().openFile(port_name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Invalid config: the serial port '{s}' does not exist.\n", .{port_name});
            return;
        },
        else => return err,
    };
    defer serial.close();

    try zig_serial.configureSerialPort(serial, zig_serial.SerialConfig{
        .baud_rate = 115200,
        .word_size = .eight,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    });
    var my_drive = ATdrive.new(TX_callback, rx_callback);
    my_drive.on_WiFi_event = device_callback;
    my_drive.on_cmd_response = result_callback;
    my_drive.TX_RX_user_data = &serial;
    defer my_drive.deinit_driver();
    try my_drive.init_driver();
    try my_drive.set_WiFi_mode(ESP_AT.WiFiDriverMode.AP_STA);
    try my_drive.set_network_mode(ESP_AT.NetworkDriveMode.SERVER_ONLY);
    my_drive.WiFi_config_AP(AP_config) catch |err| {
        _ = std.log.info("AP conf got error: {}", .{err});
    };
    try my_drive.WiFi_connect_AP(STA_config);
    my_drive.create_server(server_port, ESP_AT.NetworkHandlerType.Default, server_callback, null) catch |Err| {
        _ = std.log.info("server create fail: {}", .{Err});
    };
    while (my_drive.Wifi_state != .CONNECTED) {
        my_drive.process() catch |err| {
            _ = std.log.info("Driver got error: {}", .{err});
            _ = std.log.info("here", .{});
        };
        std.time.sleep(std.time.ns_per_ms * 20);
    }
    _ = std.log.info("sERVER OPEN ON {}", .{server_port});
    while (true) {
        my_drive.process() catch |err| {
            _ = std.log.info("Driver got error: {}", .{err});
        };
        std.time.sleep(std.time.ns_per_ms * 20);
    }
}

```