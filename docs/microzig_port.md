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

const ATdrive = ESP_AT.create_drive(4096, 10, ESP_AT.WiFiDriverType.AP_STA, ESP_AT.NetworkDriveType.SERVER_ONLY);
const wifi_ssid = "SSID";
const wifi_password = "PASSWORD";
var wd_rdy = false;
const server_port: u16 = 1234;
const html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<!DOCTYPE html>\r\n<html lang=\"pt-BR\">\r\n<head>\r\n<meta charset=\"UTF-8\">\r\n<title>Hello World</title>\r\n<p>All Your Codebase Are Belong To Us</p>\r\n</head>\r\n<body>\r\n<h1>Hello World</h1>\r\n</body>\r\n</html>\r\n";


//GET RESULT
fn result_callback(result: ESP_AT.CommandResults, cmd: ESP_AT.commands_enum) void {
    const command = ESP_AT.COMMANDS_TOKENS[@intFromEnum(cmd)];
    if (result == ESP_AT.CommandResults.Ok) {
        _ = std.log.info("Command {s} return Ok", .{command});
    } else {}
}


//Print WiFi events
fn wifiEvent_callback(event: ESP_AT.WifiEvent) void {
    switch (event) {
        ESP_AT.WifiEvent.WiFi_CON_START => {
            _ = std.log.info("START WIFI!!!", .{});
        },
        ESP_AT.WifiEvent.WiFi_DISCONNECTED => {
            _ = std.log.info("FAIL TO CONNECT TO WIFI!!!", .{});
        },
        ESP_AT.WifiEvent.WiFi_CONNECTED => {
            _ = std.log.info("WIFI CONNECTED TO {s}", .{wifi_ssid});
        },
        ESP_AT.WifiEvent.WiFi_GOT_IP => {
            _ = std.log.info("WIFI GOT  IP", .{});
            wd_rdy = true;
        },
        else => _ = std.log.info("WIFI GOT {}", .{event}),
    }
}



fn server_callback(client: ATdrive.Client) void {
    switch (client.event) {
        .Connected => {},
        .Closed => {},
        .ReciveData => {
            if (client.rev) |data| {
                _ = std.log.info("server got {s}", .{data}); //read client request (NOTE: The data may come in multiple packets due to the behavior of the module)
            }
            client.send(html) catch |err| {
                _ = std.log.info("SERVER: got error {}", .{err});
            };
        },
        .SendDataComplete => client.close() catch return, //Wait until the packet is sent before closing the connection
    }
}

fn rx_callback(data: ATdrive.RX_buffer_type) void {
    var rv_internal_buf: [2048]u8 = .{0} ** 2048;

    while (true) {
        WiFiuart.read_blocking(&rv_internal_buf, time.Duration.from_ms(50)) catch |err| {
            WiFiuart.clear_errors();
            if (err == rp2040.uart.ReceiveError.Timeout) {
                break;
            }
        };
    }

    //TODO: add push slice to Circular_buffer
    var rx_data: u8 = 0;
    for (0..rv_internal_buf.len) |index| {
        rx_data = rv_internal_buf[index];
        if (rx_data == 0) break;
        data.push(rx_data) catch {
            break;
        };
    }
}

//send data until '\0'
fn TX_callback(data: []const u8) void {
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
    _ = std.log.info("sending {s}", .{data});
}

pub fn main() !void {
    inline for (&.{ uart_tx_pin, uart_rx_pin, WiFiuart_rx_pin, WiFiuart_tx_pin, WiFiuart_RTS_pin }) |pin| {
        pin.set_function(.uart);
    }

    //ENABLE LOG UART
    uart.apply(.{
        .baud_rate = baud_rate,
        .clock_config = rp2040.clock_config,
    });

    rp2040.uart.init_logger(uart);

    //ENEBLE WIFI module UART
    WiFiuart.apply(.{
        .baud_rate = WiFibaud_rate,
        .clock_config = rp2040.clock_config,
        .flow_control = rp2040.uart.FlowControl.RTS, //Enable RTS pin in UART | TODO: send pull request to RP2040 HAL
    });

    var buffer: [2048 * 6]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var my_drive = ATdrive.new(TX_callback, rx_callback, fba.allocator()); //create driver
    defer my_drive.deinit_driver();

    //add events callback 
    my_drive.on_cmd_response = result_callback;
    my_drive.on_WiFi_respnse = wifiEvent_callback;

    //create AP (only in AP or AP_STA MODE)
    my_drive.WiFi_config_AP("banana", "123456789", 5, ESP_AT.WiFi_encryption.OPEN) catch |err| {
        _ = std.log.info("got error: {}", .{err});
        return;
    };

    //connecte to a AP (only in STA or AP_STA mode)
    try my_drive.WiFi_connect_AP(wifi_ssid, wifi_password);
    time.sleep_ms(2500);

    while (true) {
        my_drive.process(); //need to call this function periodically

        //when configured as STA or AP_STA, it is necessary to wait until the "WiFi_GOT_IP" "WIFI_ERROR_x" event, as the module goes into "Busy time" during this time
        if (wd_rdy) {
            try my_drive.create_server(server_port, server_callback);
            const ip = my_drive.get_AP_ip();
            _ = std.log.info("sERVER OPEN ON {s}:{}", .{ ip, server_port });
            wd_rdy = false;
        }
        time.sleep_ms(200);
    }
}
```

