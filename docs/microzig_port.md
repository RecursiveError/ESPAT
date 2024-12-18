# use in MicroZig
//TODO DOC

base code
```zig
const std = @import("std");
const microzig = @import("microzig");
const ESP_AT = @import("ESPAT");

const rp2040 = microzig.hal;
const time = rp2040.time;
const gpio = rp2040.gpio;
const clocks = rp2040.clocks;

const uart = rp2040.uart.instance.num(0);
const baud_rate = 115200;
const uart_tx_pin = gpio.num(0);
const uart_rx_pin = gpio.num(1);

const WiFiuart = rp2040.uart.instance.num(1);
const WiFibaud_rate = 115200;
const WiFiuart_tx_pin = gpio.num(8);
const WiFiuart_rx_pin = gpio.num(9);
const WiFiuart_RTS_pin = gpio.num(7);

pub const microzig_options = .{
    .log_level = .debug,
    .logFn = rp2040.uart.logFn,
};

const ATdrive = ESP_AT.create_drive(4096, 10);
const wifi_ssid = "SSID";
const wifi_password = "PASSWORD";
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
            std.log.info("event {} data {any}", .{ event, data });
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
                _ = std.log.info("SERVER: got error {}", .{err});
            };
            client.close() catch |err| {
                _ = std.log.info("SERVER: close got error {}", .{err});
            };
        },
        .SendDataComplete => {},
        .SendDataFail => {},
    }
}

var rv_internal_buf: [4096]u8 = .{0} ** 4096;
fn rx_callback(free_size: usize, user_data: ?*anyopaque) []u8 {
    _ = user_data;
    @memset(&rv_internal_buf, 0);
    WiFiuart.read_blocking(rv_internal_buf[0..free_size], time.Duration.from_ms(50)) catch WiFiuart.clear_errors();
    for (0..rv_internal_buf.len) |index| {
        if (rv_internal_buf[index] == 0) return rv_internal_buf[0..index];
    }
    return rv_internal_buf[0..free_size];
}

fn TX_callback(data: []const u8, user_data: ?*anyopaque) void {
    _ = user_data;
    var end: usize = data.len;
    for (0..data.len) |index| {
        if (data[index] == 0) {
            end = index;
            break;
        }
    }
    _ = WiFiuart.write_blocking(data[0..end], time.Duration.from_ms(200)) catch {
        WiFiuart.clear_errors();
    };
}

pub fn main() !void {
    inline for (&.{ uart_tx_pin, uart_rx_pin, WiFiuart_rx_pin, WiFiuart_tx_pin, WiFiuart_RTS_pin }) |pin| {
        pin.set_function(.uart);
    }

    uart.apply(.{
        .baud_rate = baud_rate,
        .clock_config = rp2040.clock_config,
    });

    rp2040.uart.init_logger(uart);

    WiFiuart.apply(.{
        .baud_rate = WiFibaud_rate,
        .clock_config = rp2040.clock_config,
        .flow_control = rp2040.uart.FlowControl.RTS,
    });

    var my_drive = ATdrive.new(TX_callback, rx_callback);
    my_drive.on_WiFi_event = device_callback;
    defer my_drive.deinit_driver();
    try my_drive.init_driver();
    try my_drive.set_WiFi_mode(ESP_AT.WiFiDriverMode.AP_STA);
    try my_drive.set_network_mode(ESP_AT.NetworkDriveMode.SERVER_ONLY);
    my_drive.WiFi_config_AP("banana", "123456789", 5, ESP_AT.WiFi_encryption.OPEN) catch |err| {
        _ = std.log.info("got error: {}", .{err});
    };
    try my_drive.WiFi_connect_AP(wifi_ssid, wifi_password);
    my_drive.create_server(server_port, ESP_AT.NetworkHandlerType.TCP, server_callback, null) catch |Err| {
        _ = std.log.info("server create fail: {}", .{Err});
    };
    time.sleep_ms(2500);
    while (my_drive.Wifi_state != .CONNECTED) {
        my_drive.process() catch |err| {
            _ = std.log.info("Driver got error: {}", .{err});
        };
    }
    _ = std.log.info("sERVER OPEN ON {}", .{server_port});
    while (true) {
        my_drive.process() catch |err| {
            _ = std.log.info("Driver got error: {}", .{err});
        };
        time.sleep_ms(20);
    }
}

```

