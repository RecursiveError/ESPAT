const zig_serial = @import("serial");
const std = @import("std");

const Driver = @import("ESPAT");
const WiFi = Driver.WiFi;
const Network = Driver.Network;
const Client = Network.Client;
const Http = Driver.HttpDevice;
const Runner = Driver.StandartRunner;

const wifi_ssid = "SSID";
const wifi_password = "PASSWORD";

const html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<!DOCTYPE html>\r\n<html lang=\"pt-BR\">\r\n<head>\r\n<meta charset=\"UTF-8\">\r\n<title>Hello World</title>\r\n<p>All Your Codebase Are Belong To Us</p>\r\n</head>\r\n<body>\r\n<h1>Hello World</h1>\r\n</body>\r\n</html>\r\n";

const AP_config = WiFi.APConfig{
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

const STA_config = WiFi.STAConfig{
    .ssid = wifi_ssid,
    .pwd = wifi_password,

    .wifi_protocol = .{
        .@"802.11b" = 1,
        .@"802.11g" = 1,
        .@"802.11n" = 1,
    },
    .host_name = "example",
    .wifi_ip = .{ .DHCP = {} },
    // .wifi_ip = .{ .static = .{ .ip = "192.168.15.37" } },
};

const config_mDNS = Network.mDNSConfig{
    .hostname = "example",
    .service_type = "_http",
    .service_port = 80,
    .instance = "ESPAT",
    .protocol = "_tcp",
    .txt_report = &.{
        .{ .key = "api", .value = "/teste" },
    },
};

const server_config = Network.ServerConfig{
    .recv_mode = .passive,
    .callback = server_callback,
    .user_data = null,
    .server_type = .TCP,
    .port = 80,
    .timeout = 2600,
};

const config_tcp = Network.ConnectConfig{
    .recv_mode = .active,
    .remote_host = "google.com",
    .remote_port = 80,
    .config = .{
        .tcp = .{ .keep_alive = 100 },
    },
};

const config_udp = Network.ConnectConfig{
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

fn WiFi_callback(event: WiFi.Event, _: ?*anyopaque) void {
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
        .SCAN_FIND => |data| {
            std.log.info("FIND: SSID {s}, MAC{s}, Db {d}, ecn{any}", .{
                data.ssid,
                data.mac,
                data.rssid,
                data.ecn,
            });
        },
        else => {
            std.log.info("WiFi got event {any}", .{event});
        },
    }
}

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
        else => {
            std.log.info("SERVER TCP EVENT: {any}", .{client.event});
        },
    }
}

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
            std.log.info("Client got {d}bytes: {s}", .{ data.len, data });
        },
        else => {
            std.log.info("CLIENT TCP EVENT: {any}", .{client.event});
        },
    }
}

//all data passed to send or send_to needs to live until a Send event occurs
var req_buf_udp: [200]u8 = undefined;
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

fn HTTP_callback(data: Http.Status, _: ?*anyopaque) void {
    switch (data) {
        .Data => |info| {
            std.log.info("|HTTP| get data: {s}", .{info});
        },
        .Finish => |state| {
            std.log.info("|HTTP| request Finish With: {any}", .{state});
        },
    }
}

fn reset(_: ?*anyopaque) void {
    std.log.info("in reset", .{});
}

pub fn main() !void {
    const port_name = "/dev/ttyUSB0";
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

    var reader_buf: [1024]u8 = @splat(0);
    var writer_buf: [1024]u8 = @splat(0);
    var http_recv: [1024]u8 = @splat(0);
    var net_buf: [1024]u8 = @splat(0);

    var runner_buffer: [50]u32 = @splat(0);
    var WifIBuffer: [25]WiFi.Package = undefined;
    var Http_buffer: [12]Http.Package = undefined;
    var NetworkBuffer: [25]Network.Package = undefined;

    var reader = serial.reader(&reader_buf);
    var writer = serial.writer(&writer_buf);

    var my_drive = Runner.Runner.init(.{
        .reader = &reader.interface,
        .writer = &writer.interface,
        .event_queue = &runner_buffer,
        .reset_callback = reset,
        .reset_userdata = null,
    }) catch unreachable;

    var wifi = WiFi.Device.init(.{
        .runner = &my_drive.runner_dev,
        .callback = WiFi_callback,
        .user_data = null,
        .cmd_buffer = &WifIBuffer,
        .WiFi_mode = .AP_STA,
    });
    var tcpip = Network.Device(5).init(.{
        .cmd_buf = &NetworkBuffer,
        .net_buf = &net_buf,
        .mode = .SERVER_CLIENT,
        .runner = &my_drive.runner_dev,
    });

    var http = Http.Device.init(.{
        .cmd_buf = &Http_buffer,
        .data_buf = &http_recv,
        .runner = &my_drive.runner_dev,
    });
    try wifi.link_device();
    try tcpip.link_device();
    try http.link_device();

    std.log.info("Driver initialized", .{});
    try my_drive.start_runner(true);
    std.log.info("Runner started", .{});

    try wifi.WiFi_connect_AP(STA_config);
    try wifi.WiFi_config_AP(AP_config);

    try tcpip.create_mDNS(config_mDNS);
    try tcpip.create_server(server_config);
    const tcp_id = try tcpip.bind(tcp_callback, null);
    const udp_id = try tcpip.bind(udp_callback, null);

    try http.request(.{
        .url = "http://httpbin.org/post",
        .header = "User-Agent: ESPAT\r\n",
        .data = "blablabla",
        .method = .POST,
        .handler = HTTP_callback,
        .user_data = null,
    });

    try http.simple_request(.{
        .url = "https://httpbin.org/get",
        .header = "User-Agent: ESPAT\r\n",
        .data = "blablabla", //not send
        .method = .GET,
        .content = .@"text/xml",
        .transport = .SSL,
        .handler = HTTP_callback,
        .user_data = null,
    });

    try tcpip.connect(tcp_id, config_tcp);
    try tcpip.connect(udp_id, config_udp);

    while (true) {
        my_drive.process() catch |err| {
            _ = std.log.err("Driver got error: {}", .{err});
            while (true) {}
        };
    }
}
