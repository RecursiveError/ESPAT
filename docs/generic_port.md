this is an example of generic impementation made using the [ZEG serial library](https://github.com/ZigEmbeddedGroup/serial)

## code:
```zig
const Driver = @import("ESPAT");
const Client = Driver.Client;
const EspAT = Driver.EspAT;
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
            if (b == '\n' or b == '>') break;
        }
        return rv_internal_buf[0..size];
    }
    _ = std.log.info("null args on RX", .{});

    return rv_internal_buf[0..0];
}

fn TX_callback(data: []const u8, user_data: ?*anyopaque) void {
    if (user_data) |userdata| {
        const serial: *std.fs.File = @ptrCast(@alignCast(userdata));
        serial.writer().writeAll(data) catch return;
    }
}

const wifi_ssid = "SSID";
const wifi_password = "PWD";
const server_port: u16 = 1234;

fn result_callback(result: Driver.CommandResults, cmd: Driver.Commands, user_data: ?*anyopaque) void {
    _ = user_data;
    const command = Driver.get_cmd_string(cmd);
    if (result == Driver.CommandResults.Ok) {
        _ = std.log.info("Command {s} return Ok", .{command});
    } else {
        _ = std.log.info("Command {s} return FAIL", .{command});
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

fn server_callback(client: Client, user_data: ?*anyopaque) void {
    _ = user_data;
    switch (client.event) {
        .DataReport => |len| {
            _ = std.log.info("SERVER: id {} have {} bytes in queue", .{ client.id, len });
            client.accept() catch |err| {
                _ = std.log.info("SERVER: got error {}, on bind {}", .{ err, client.id });
            };
        },
        .ReadData => |data| {
            _ = std.log.info("server got {s}", .{data});
            client.send(@constCast(html)) catch |err| {
                _ = std.log.info("SERVER: got error {}, on bind {}", .{ err, client.id });
            };
            client.close() catch |err| {
                _ = std.log.info("SERVER: close got error {}", .{err});
            };
        },
        else => {},
    }
}

fn client_callback(client: Client, user_data: ?*anyopaque) void {
    _ = user_data;
    switch (client.event) {
        .Connected => {
            client.send("teste\r\n") catch |err| {
                _ = std.log.info("client: got error {}, on bind {}", .{ err, client.id });
            };
        },
        .DataReport => |len| {
            _ = std.log.info("client: have {} bytes in queue", .{len});
            client.accept() catch |err| {
                _ = std.log.info("client: got error {}, on bind {}", .{ err, client.id });
            };
        },
        .ReadData => |data| {
            _ = std.log.info("client: LEN {} | DATA: {s}", .{ data.len, data });
            client.close() catch |err| {
                _ = std.log.info("client: close got error {}", .{err});
            };
        },
        else => {
            std.log.info("CLIENT EVENT: {any}", .{client.event});
        },
    }
}

const STA_config = Driver.WiFiSTAConfig{
    .ssid = wifi_ssid,
    .pwd = wifi_password,
};

const AP_config = Driver.WiFiAPConfig{
    .ssid = "banana",
    .channel = 5,
    .ecn = .OPEN,
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
        .baud_rate = 115273,
        .word_size = .eight,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    });
    var my_drive = EspAT(.{}).init(TX_callback, rx_callback, &serial);
    std.log.info("DRIVER MEM: {}", .{@sizeOf(@TypeOf(my_drive))});
    defer my_drive.deinit_driver();
    try my_drive.init_driver();
    my_drive.set_WiFi_event_handler(WiFi_callback, null);
    my_drive.set_response_event_handler(result_callback, null);
    try my_drive.set_WiFi_mode(Driver.WiFiDriverMode.AP_STA);
    try my_drive.set_network_mode(Driver.NetworkDriveMode.SERVER_CLIENT);
    my_drive.WiFi_config_AP(AP_config) catch |err| {
        _ = std.log.info("AP conf got error: {}", .{err});
    };
    try my_drive.WiFi_connect_AP(STA_config);
    my_drive.create_server(server_port, Driver.NetworkHandlerType.Default, server_callback, null) catch |Err| {
        _ = std.log.info("server create fail: {}", .{Err});
    };
    const config = Driver.NetworkConnectPkg{
        .remote_host = "google.com",
        .remote_port = 80,
        .config = .{
            .tcp = .{
                .keep_alive = 0,
            },
        },
    };
    const id = try my_drive.bind(client_callback, null);
    try my_drive.connect(id, config);
    _ = std.log.info("sERVER OPEN ON {}", .{server_port});
    while (true) {
        my_drive.process() catch |err| {
            _ = std.log.err("Driver got error: {}", .{err});
        };
    }
}

```