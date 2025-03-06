- [Network Setup](#basic-network)
    - [Clients](#client)
    - [Server](#server)
    - [Network Events](#network-events)
        - [event table](#network-event-table)
    - [Network Example](#network-example)


## Basic network

To use the Network feature it is necessary to create a device: `Network.Device(binds).init();`

where `binds` is the number of binds configured in the ESP, minimum: 5

link this device to the Runner with: `Network_device.link_device(&my_drive);`


Before using any network-related function, it is necessary to set the network mode by the function: `set_network_mode(mode: Network.DriveMode)`

By default the module has a total of 5 Sockets, which can be divided between client and server, the network modes define how this division will be done.


| **NetworkDriveMode**   | **Client connections** | **Server connections**|
|-------------|-----------------|------------------|
| .CLIENT_ONLY|5|0|
| .SERVER_ONLY|0|5|
| .SERVER_CLIENT|2|3|

(This may change in the future, allowing the user to configure the division.)

You can change the network mode at any time, but this may have some side effects:

- Clients: Decreasing the number of client connections will immediately delete the associated handler for the connection, causing data loss. Make sure that all client connections have been terminated.

- Server: change the number of server connections will only take effect when the server is deleted.

#### Client
To start a client the first thing you should do is get a Socket ID by the function: `bind(event_callback: ClientCallback, user_data: ?*anyopaque)`

this function is assigned a ClientCallback and an optional user-defined parameter (each ID can have its own callback and parameter).

if a client socket is available, this function will associate the callback and the user's parameter with that socket and return the ID.

to make a request you must create a configuration struct:`ConnectConfig`

This struct gets:
- `recv_mode` = socket data reception mode, `.active`: the module will send all received data immediately, `.passive`: the module will store the received data in an internal buffer until the user requests the data.
- `remote_host` = a string containing the IP or domain of the host
- `remote_port` = the host port
- `config` = Request type configuration:
    - `TCP`/`SSL`:
        - `keep_alive` = keep-alive timeout
    - `UDP`:
        - `local_port` = optional local port 
        `mode` = udp mode [(refer to ESPAT Doc)](https://docs.espressif.com/projects/esp-at/en/release-v4.0.0.0/esp32/AT_Command_Set/TCP-IP_AT_Commands.html#id11)

With this struct configured, call the function: `connect(id: usize, config: NetworkConnectPkg)` passing the id and the configuration.

now all communication will happen through the callback associated with the socket. [Network events](#network-events)

To return a socket, use the function: `release(id: usize)`, this function will clear all data associated with the Socket and return the ID to the list of available Sockets
 
#### Server

To create a server you must create a configuration struct: `ServerConfig` this struct contains:
- `recv_mode` = socket data reception mode, `.active`: the module will send all received data immediately, `.passive`: the module will store the received data in an internal buffer until the user requests the data.
- `port` = the port that the server will listen on
- `server_type` = the type of server, servers can be of 3 types: `.default` (default firmware configuration), `.TCP` and `.SSL`.

(The ESP-AT does not support creating UDP servers, but it is possible to receive data via UDP by initializing a UDP client where the `local_port` parameter is the port on which the device will listen for UDP packets.)

- `callback` and user_data = a Clientcallback and an optional user parameter, all server connections will share the same callback and parameters.

- `user_data` = optional user-defined parameter.
- `timeout` = optional timeout time for server.

After configured, create the server by calling: `create_server(ServerConfig)` and passing the settings

all communication will happen through the event_callback. [Network events](#network-events)

**Note**: ESPAT only supports listening on one port at a time.
To delete the server use the function: `delete_server()`

#### Network Events
both clients and servers use ClientCallbacks for communication, a ClientCallback is just: `(client: ESPAT.Client, user_data: ?*anyopaque) `void``

The Struct Client contains all the information needed to manage the connection:
- `id` = the connection ID
- `event` = A tagged union containing the tag of each event and the event data. [Event Table](#network-event-table)
- `accept()` = makes a request for the data saved in the id buffer, this function always tries to read as much as allowed by the `network_recv_size` setting. 
- `close()` = function to close the connection
- `send()` = function to send data. (**Note**: the data should live until it is returned by event: `.SendDataComplete` or  `.SendDataCancel` ).
- `send_to()` = sends data to a specific host. (UDP only)

##### Network Event Table

| **Event**   | **Data** | **info**|
|-------------|-----------------|------------------|
|Connected|`Void`|id has started a connection.|
|Closed|`void`|The id closed a connection.|
|DataReport|`usize`| The id has data on hold, use `accept()` to receive or `close()` to close and clear the connection. (only in passive mode)|
|ReadData| `[]const u8`| data read from the buffer.|
|SendData| `SendResult`| The data sent can now be cleaned, it also returns the result of the operation |

#### Network Example
```zig
const Driver = @import("ESPAT");
const Network = Driver.Network;
const Client = Network.Client;
...

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

var req_buf_tcp: [200]u8 = undefined;
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

const config_tcp = Network.ConnectConfig{
    .recv_mode = .passive,
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

const server_config = Network.ServerConfig{
    .recv_mode = .passive,
    .callback = server_callback,
    .user_data = null,
    .server_type = .TCP,
    .port = 80,
    .timeout = 2600,
};

....
fn main() !void {
    ...
    my_driver.init_driver();
    var net_dev = WiFi.Device.init();
    net_dev.link_device(&my_drive);


    try net_dev.set_network_mode(.SERVER_CLIENT);
    const id_udp = try net_dev.bind(udp_callback, null);
    const id_tcp = try net_dev.bind(tcp_callback, null);
    try net_dev.connect(id_tcp, config_tcp);
    try net_dev.connect(id_udp, config_udp);
    try net_dev.create_server(server_config);
    ...
}
```

It is also possible to find the `ESP8266Network`, a version compatible with the network device made for the ESP8266

TODO: add ESP8266Network doc