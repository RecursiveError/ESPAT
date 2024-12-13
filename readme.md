# ESPAT
simple driver made in Zig to use ESP(32/8266) boards as WiFi module via AT command firmware

AT command firmware for ESP modules (32/8266) is a simple and inexpensive way to add wireless connection to embedded devices, although it is more limited than conventional RF modules, ESP modules abstract much of the network stack, allowing their use in more limited devices.

***Important***: This driver is still under development, invalid inputs may cause deadlocks or breaks

__Recommended Espressif AT Firmware Version__:4.0.0.0
__Minimum Espressif AT Firmware Version__: 2.2.0.0

**Warning**: for Ai-thinker modules such as ESP-01 or ESP-12.
Boantong AT firmware (AT =< 1.7) is not supported, and Espressif firmware (2.2.0.0) is not compatible with the pin layout of these boards, to use them it is necessary to customize the firmware to ESP8266, if you don't know how to do this follow this guide: [custom pin AT](docs/customAT.md)

## Supported Features
- [x] WiFi STA/AP/AP+STA modes
- [x] TCP/UDP Client
- [x] TCP Server
- [x] Server + Client mode

## Others
Features that may be implemented
- [ ] UART Config
- [ ] IPv6 support
- [ ] Build-in SSL client  
- [ ] Build-in HTTP client
- [ ] Build-in MQTT client
- [ ] user Commands 
- [ ] Bluetooth LE (only for ESP32 based modules)
- [ ] Optional AT Features



## Get started

at the moment this Driver does not have a command to configure UART, you need to pre-configure with:[AT+UART_DEF](https://docs.espressif.com/projects/esp-at/en/latest/esp32/AT_Command_Set/Basic_AT_Commands.html#at-uart-def-default-uart-configuration-saved-in-flash) before using

- [Porting](#porting)
- [WiFi setup](#basic-wifi-config)
    - [WiFi AP](#setting-up-the-module-as-an-access-point)
    - [WiFi STA](#setting-up-the-module-as-a-station)
    - [WiFi Events](#wifi-events)
        - [WiFi errors](#wifi-error-table)
    - [WiFi example](#wifi-example)
- [Network Setup](#basic-network)
    - [Clients](#client)
    - [Server](#server)
    - [Network Events](#network-events)
        - [event table](#network-event-table)
    - [Network Example](#network-example)
- [Error Handling](#error-handling)
- [Examples](#examples)

### Porting
 
To start using this driver, the first step is to create the driver type with: `EspAT(Config)`

`Config` is a struct that defines the inner workings of the driver, it contains the following fields:
- `RX_size`: input buffer size, minimum: 128 bytes, default value: 2046 bytes.
- `TX_event_pool`: Event buffer size, minimum: 10 events, default value: 25.
- `network_recv_size`: Network buffer size, minimum: 128 bytes, default value: 2046 bytes.
- `network_binds`: Number of sockets supported by the module,  default value: 5.
- `@"2.2.0.0_Support"`: Optional support for versions older than 4.0.0.0, default value: false.

with the type created, just initialize it with: `init(TX_callback,RX_callback, user_data)`

- `TX_callback(data: []const u8, user_data: ?*anyopaque) `void``: This function is responsible for sending the driver data to the module.

    - `data`: a slice containing the bytes that need to be sent to the module, note: you don't need to send all the data at once.

    - `user_data`: An optional pointer to a user parameter

    - `Returns`: `Void`

            
- `RX_callback(free_size: usize, user_data: ?*anyopaque) []const u8`: This is an optional function used by the driver to request information.

    - `free_size`: count of bytes that the driver can read, you can return any amount of bytes as long as it does not exceed that value (additional data will be lost)

    - `user_data`: An optional pointer to a user parameter

    - `returns`: a slice containing the read bytes, this slice must live until the next call of this function, after which it can be released

    Alternatively you can use the function: `notify([]const u8)` to notify data to the driver and leave RX_callback as null, before sending any data using this function it is necessary to check the amount of bytes available in the input buffer with: `get_rx_free_space()`

    `notify` returns the amount of bytes saved in the buffer

- `user_data`: An optional pointer to a user parameter for TX and RX callbacks


Once the driver type is initialized, the first thing you should do is call the function: `init_driver()`, This function will clear any commands in the event queue and load the driver's startup sequence. To safely turn off the driver, use: `deinit_driver()`

To initialize the event handler, you should call the function `process()` periodically. This function returns internal driver errors.[TODO: Error Handling DOC]

 **Generic example**:
 ```zig

 const ESP_AT = @import("ESPAT");

 fn TX_callback(data: []const u8, user_data: ?*anyopaque) `void` {
    if (user_data) |userdata| {
        const serial: *serial_type = @ptrCast(@alignCast(userdata));
        serial.write(data);
    }
}

var foo_buf: [4096]u8 = undefined;
fn rx_callback(free_size: usize, user_data: ?*anyopaque) []u8 {
    var bytes_read: usize = 0;
    if (user_data) |userdata| {
        const serial: *serial_type = @ptrCast(@alignCast(userdata));
        bytes_read = serial.read(foo_buf[0..free_size]);
    }
    return foo_buf[0..bytes_read];
}

fn main() !`void` {
    var serial = Serial.lib;
    var driver = ESP_AT.EspAT(.{}).init(TX_callback, rx_callback, &serial);
    defer driver.deinit_driver();
        try driver.init_driver()
    while(true){
        my_drive.process() catch |err| {
            _ = std.log.err("Driver got error: {}", .{err});
        };
    }
}
 ```


TODO: microzig port  example

### Basic WiFi config

Before using any WiFi-related function, it is necessary to set the WiFi mode using the function: `set_WiFi_mode(mode: WiFiDriverMode)`

ESPAT has 3 WiFi modes:   
- WiFiDriverMode.AP: to configure the module as an access point.  
- WiFiDriverMode.STA: To configure the module as a station.  
- WiFiDriverMode.AP_STA: To set up the previous two modes at the same time.

the WiFi mode can be changed at any time, but keep in mind that the module will not automatically connect to the WiFi after the AP mode is changed to STA (this is not a hardware or driver limitation, it is just a default setting, it can be changed in the future according to user feedback)

#### Setting up the module as an access point:
With WiFi configured for AP or AP_STA mode , create a configuration struct: `WiFiAPConfig`
the fields in this struct correspond directly to the settings of the AT commands. [soft AP parameters](https://docs.espressif.com/projects/esp-at/en/release-v4.0.0.0/esp32/AT_Command_Set/Wi-Fi_AT_Commands.html#id28)

To save the settings and enable SoftAP mode, pass the configuration struct to the function: `WiFi_config_AP(config: WiFiAPConfig)`

#### Setting up the module as a station:
With WiFi configured for STA or AP_STA mode , create a configuration struct: `WiFiSTAConfig`
the fields in this struct correspond directly to the settings of the AT commands. [STA parameters](https://docs.espressif.com/projects/esp-at/en/release-v4.0.0.0/esp32/AT_Command_Set/Wi-Fi_AT_Commands.html#id11)

To save the settings and enable STA mode, pass the configuration struct to the function: `WiFi_connect_AP(config: WiFiSTAConfig)`

### WiFi events

all WiFi events are handled by a single handler, which can be set with: `set_WiFi_event_handler(callback: WIFI_event_type, user_data: ?*anyopaque)`:

- `WIFI_event_type`: `fn on_WiFi_event(event: WifiEvent, user_data: ?*anyopaque) `void``:
    - `event`: A tagged union containing the event tag and possible event data.
    - `user_data`: optional pointer to a user parameter
- `user_data`: optional pointer to a user parameter

WiFi event table

| **EVENT**   | **data** | **Info**        |
|------------|-------------|------------------------|
|AP_CON_START|`void`|WiFi has started a connection attempt.|
|AP_CONNECTED|`void`|WiFi connected to an access point, waiting for IP.|
|AP_GOT_MASK|`[]const u8`|WiFi received the network mask from the Access Point, returns a string with the network mask.|
|AP_GOT_IP|`[]const u8`|WiFi received an IP from the Access point, returns a string with the IP.|
|AP_GOT_GATEWAY|`[]const u8`|WiFi received the gateway IP of the Access point, returns a string with the gateway IP.|
|AP_DISCONNECTED|`void`|WiFi disconnected from an access point.|
|STA_CONNECTED|`[]const u8`|A device has connected to the module's access point. returns the MAC address of the device.|
|STA_GOT_IP|`DeviceInfo`|a device has been assigned an IP address from the module, returns the MAC and IP address of the device.|
|STA_DISCONNECTED|`[]const u8`| a device disconnected from the module's access point, returns the device's MAC address.|
|ERROR|`ErrorEvent`|An error occurred during the connection contain the reason for the error. [error table](#wifi-error-table)| 

#### WiFi Error Table
| **ERROR**  | **Info**|
|------------|---------|
|Timeout| Connection to an access point took too long to respond.|
|Password|Incorrect WiFi password.|
|SSID| The module was not able to find the specified SSID.|
|FAIL| The access point refused the connection.|
|Unknown| The module returned an unknown error code.|

To disconnect from WiFi, use: `WiFi_disconnect()`

(note: you don't need to use this function to switch WiFi networks)

#### WiFi Example
```zig
const Driver = @import("ESPAT");
...
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
...
fn main() !void {
    ...
    my_drive.set_WiFi_event_handler(WiFi_callback, null);
    ...
}
```


### Basic network

Before using any network-related function, it is necessary to set the network mode by the function: `set_network_mode(mode: NetworkDriveMode)`

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

to make a request you must create a configuration struct:`NetworkConnectPkg`

This struct gets:
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

To create a server call function: `create_server(port: u16, server_type: NetworkHandlerType, event_callback: ClientCallback, user_data: ?*anyopaque)` passing
- port = the port that the server will listen on
- server_type = the type of server, servers can be of 3 types: `.default` (default firmware configuration), `.TCP` and `.SSL`.

(The ESP-AT does not support creating UDP servers, but it is possible to receive data via UDP by initializing a UDP client where the `local_port` parameter is the port on which the device will listen for UDP packets.)

- event_callback and user_data = a Clientcallback and an optional user parameter, all server connections will share the same callback and parameters.

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

##### Network Event Table

| **Event**   | **Data** | **info**|
|-------------|-----------------|------------------|
|Connected|`Void`|id has started a connection.|
|Closed|`void`|The id closed a connection.|
|DataReport|`usize`| The id has data on hold, use `accept()` to receive or `close()` to close and clear the connection.|
|ReadData| `[]const u8`| data read from the buffer.|
|SendDataComplete| `[]const u8`| data has been sent, wait for response. |
|SendDataCancel| `[]const u8`| data send has been canceled. |
|SendDataOk| `void`| data was successfully sent to ID. |
|SendDataFail| `void`| sending data to ID failed. |

#### Network Example
```zig
const Driver = @import("ESPAT");
const Client = Driver.Client;
...
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
....
fn main() !void {
    ...
    const id = try my_drive.bind(client_callback, null);
    try my_drive.connect(id, config);
    ...
}
```



### Error Handling
TODO


### Examples:
complete example code: [Generic port](docs/generic_port.md)
