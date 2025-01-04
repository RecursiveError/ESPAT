# use in MicroZig
//TODO DOC

base code
```zig
const std = @import("std");
const microzig = @import("microzig");
const Driver = @import("ESPAT");

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

const Client = Driver.Client;
const EspAT = Driver.EspAT;

pub const microzig_options = .{
    .log_level = .debug,
    .logFn = rp2040.uart.logFn,
};

const wifi_ssid = "GUSTAVO";
const wifi_password = "anjos2018";
const server_port: u16 = 80;

var rv_internal_buf: [1024]u8 = undefined;
fn rx_callback(free_size: usize, user_data: ?*anyopaque) []u8 {
    _ = user_data;
    @memset(&rv_internal_buf, 0);
    const read = @min(rv_internal_buf.len, free_size);
    WiFiuart.read_blocking(rv_internal_buf[0..read], time.Duration.from_ms(50)) catch WiFiuart.clear_errors();
    for (0..rv_internal_buf.len) |index| {
        if (rv_internal_buf[index] == 0) return rv_internal_buf[0..index];
    }
    return rv_internal_buf[0..read];
}

fn TX_callback(data: []const u8, _: ?*anyopaque) void {
    _ = WiFiuart.write_blocking(data, time.Duration.from_ms(200)) catch {
        WiFiuart.clear_errors();
    };
}

fn result_callback(result: Driver.ReponseEvent, cmd: Driver.Commands, user_data: ?*anyopaque) void {
    _ = user_data;
    const command_str = Driver.get_cmd_string(cmd);
    switch (result) {
        .Ok => {
            std.log.info("Command {s} was successfully.", .{command_str});
        },
        .Fail => {
            std.log.info("Fail do run {s}", .{command_str});
        },
        .Error => |code| {
            std.log.info("Commands {s} return error {any}", .{ command_str, code });
        },
    }
}

fn WiFi_callback(event: Driver.WifiEvent, user_data: ?*anyopaque) void {
    _ = user_data;
    switch (event) {
        .AP_DISCONNECTED => {
            std.log.info("WiFi disconnect from {s}", .{wifi_ssid});
        },
        .AP_CON_START => {
            std.log.info("WiFi conn start", .{});
        },
        .AP_CONNECTED => {
            std.log.info("WiFi connect waiting for IP", .{});
        },
        .AP_GOT_IP => |ip| {
            std.log.info("WiFi got ip {s}", .{ip});
        },
        else => {
            std.log.info("WiFi got event {any}", .{event});
        },
    }
}

const html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<!DOCTYPE html>\r\n<html lang=\"pt-BR\">\r\n<head>\r\n<meta charset=\"UTF-8\">\r\n<title>Hello World</title>\r\n<p>All Your Codebase Are Belong To Us</p>\r\n</head>\r\n<body>\r\n<h1>Hello World</h1>\r\n</body>\r\n</html>\r\n";

//tcp server example
fn server_callback(client: Client, user_data: ?*anyopaque) void {
    _ = user_data;
    switch (client.event) {
        .Connected => {
            std.log.info("Client {d} from {s}:{d} connected to the server!", .{
                client.id,
                client.remote_host.?,
                client.remote_port.?,
            });
        },
        .DataReport => |len| {
            std.log.info("server: id {} have {} bytes in queue", .{ client.id, len });
            client.accept() catch |err| {
                std.log.info("SERVER: got error {}, on bind {}", .{ err, client.id });
            };
        },
        .ReadData => |data| {
            std.log.info("server got {s}", .{data});
            client.send(@constCast(html)) catch |err| {
                std.log.info("SERVER: got error {}, on bind {}", .{ err, client.id });
            };
            client.close() catch |err| {
                std.log.info("SERVER: close got error {}", .{err});
            };
        },
        else => {},
    }
}

//tcp request example
fn tcp_callback(client: Client, user_data: ?*anyopaque) void {
    _ = user_data;
    switch (client.event) {
        .Connected => {
            client.send("teste\r\n\r\n") catch unreachable;
            std.log.info("TCP send data!", .{});
        },
        .DataReport => |len| {
            std.log.info("client TCP: have {} bytes in queue", .{len});
            client.accept() catch |err| {
                std.log.info("tcp got error {}, on bind {}", .{ err, client.id });
            };
        },
        .ReadData => |data| {
            std.log.info("Client got data {s}", .{data});
            client.close() catch unreachable;
        },
        else => {
            std.log.info("CLIENT TCP EVENT: {any}", .{client.event});
        },
    }
}

//UDP echo example
var req_buf_udp: [20]u8 = undefined;
var remote_host: [50]u8 = undefined;
fn udp_callback(client: Client, user_data: ?*anyopaque) void {
    _ = user_data;
    switch (client.event) {
        .ReadData => |data| {
            const host_len = client.remote_host.?.len;
            std.mem.copyForwards(u8, &remote_host, client.remote_host.?);
            const msg = std.fmt.bufPrint(&req_buf_udp, "{d}\r\n", .{data.len}) catch unreachable;
            client.send_to(msg, remote_host[0..host_len], client.remote_port.?) catch |err| {
                std.log.info("udp got error {any}", .{err});
            };
        },
        else => {
            std.log.info("CLIENT UDP EVENT: {any}", .{client.event});
        },
    }
}

const STA_config = Driver.WiFiSTAConfig{
    .ssid = wifi_ssid,
    .pwd = wifi_password,
    .wifi_protocol = .{
        .@"802.11b" = 1,
        .@"802.11g" = 1,
        .@"802.11n" = 1,
    },

    .wifi_ip = .{ .static = .{ .ip = "192.168.15.37" } },
};

const AP_config = Driver.WiFiAPConfig{
    .ssid = "banana",
    .channel = 5,
    .ecn = .OPEN,
    .wifi_protocol = .{
        .@"802.11b" = 1,
        .@"802.11g" = 1,
        .@"802.11n" = 1,
    },
    .mac = "00:C0:DA:F0:F0:00",
    .wifi_ip = .{ .DHCP = {} },
};

const config_tcp = Driver.ConnectConfig{
    .recv_mode = .passive,
    .remote_host = "google.com",
    .remote_port = 80,
    .config = .{
        .tcp = .{ .keep_alive = 100 },
    },
};

const config_udp = Driver.ConnectConfig{
    .recv_mode = .active,
    .remote_host = "0.0.0.0",
    .remote_port = 1234,
    .config = .{
        .udp = .{
            .local_port = 1234,
            .mode = .Change_all,
        },
    },
};

const server_config = Driver.ServerConfig{
    .recv_mode = .passive,
    .callback = server_callback,
    .user_data = null,
    .server_type = .TCP,
    .port = server_port,
    .timeout = 2600,
};

pub fn main() !void {
    init_device();
    var my_drive = EspAT(.{ .TX_event_pool = 30 }).init(TX_callback, rx_callback, null);
    std.log.info("DRIVER MEM: {}", .{@sizeOf(@TypeOf(my_drive))});
    defer my_drive.deinit_driver();

    my_drive.set_WiFi_event_handler(WiFi_callback, null);
    my_drive.set_response_event_handler(result_callback, null);

    try my_drive.init_driver();
    try my_drive.set_WiFi_mode(Driver.WiFiDriverMode.AP_STA);
    try my_drive.set_network_mode(Driver.NetworkDriveMode.SERVER_CLIENT);
    try my_drive.WiFi_config_AP(AP_config);
    try my_drive.WiFi_connect_AP(STA_config);

    const id_udp = try my_drive.bind(udp_callback, null);
    const id_tcp = try my_drive.bind(tcp_callback, null);
    try my_drive.connect(id_tcp, config_tcp);
    try my_drive.connect(id_udp, config_udp);
    try my_drive.create_server(server_config);

    while (true) {
        my_drive.process() catch |err| {
            _ = std.log.err("Driver got error: {}", .{err});
        };
    }
}

fn init_device() void {
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
}

```

