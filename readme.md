# ESPAT
simple driver made in Zig to use ESP(32/8266) boards as WiFi module via AT command firmware

AT command firmware for ESP modules (32/8266) is a simple and inexpensive way to add wireless connection to embedded devices, although it is more limited than conventional RF modules, ESP modules abstract much of the network stack, allowing their use in more limited devices.

***Important***: This driver is still under development, invalid inputs may cause deadlocks or breaks

__Minimum Espressif AT Firmware Version__: 2.2.0.0

**Warning**: for Ai-thinker modules such as ESP-01 or ESP-12E.
Boantong AT (BAT) firmware is not supported, and Espressif firmare is not compatible with the pin layout of these boards, to use them it is necessary to customize the firmware to ESP8266, if you don't know how to do this follow this guide: (TODO: firmware guide)

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

- [Porting](#porting)
- [WiFi setup](#basic-wifi-config)
- [Network Setup](#basic-network)
- [Error Handling](#error-handling)

### Porting
 
To start using this driver, the first step is to create the driver with: `EspAT(RX_buffer_size, TX_pool_size).init(TX_callback, RX_callback)`  

- `RX_buffer_size`: Byte size of the driver's input buffer, minimum size: 50 bytes
- `TX_pool_size`: Driver event pool size, minimum size: 5 events (amount of events used at driver startup)

This process is necessary because this driver does not do any kind of dynamic allocation (this will probably change in future versions)

All you need to do to port this driver is implement 2 callbacks:

- `RX_callback(free_size: usize, user_data: ?*anyopaque) []const u8`: this function responsible for sending the data to the driver 

    - `free_size`: count of bytes that the driver can read, you can return any amount of bytes as long as it does not exceed that value (additional data will be lost)

    - `user_data`: An optional pointer to a user parameter

    - `returns`: a slice containing the read bytes, this slice must live until the next call of this function, after which it can be released

- `TX_callback(data: []const u8, user_data: ?*anyopaque) void`: This function is responsible for sending the driver data to the module.

    - `data`: a slice containing the bytes that need to be sent to the module, note: you don't need to send all the data at once.

    - `user_data`: An optional pointer to a user parameter

    - `Returns`: Void

 You can set the user parameter by the attribute: `TX_RX_user_data`

 For the driver to work it is also necessary to call the function: `process` periodically, this function also returns internal driver errors. [TODO: Error Handling DOC]

 **Generic example**:
 ```zig

 const ESP_AT = @import("ESPAT");

 fn TX_callback(data: []const u8, user_data: ?*anyopaque) void {
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

fn main() !void {
    var serial = Serial.lib;
    var driver = ESP_AT.EspAT(4096, 20)
        .init(TX_callback, rx_callback);
    
    drive.TX_RX_user_data = &serial;
    while(true){
        my_drive.process() catch |err| {
            _ = std.log.err("Driver got error: {}", .{err});
        };
    }
}
 ```


TODO: microzig port  example

### Basic WiFi config

Before using any WiFi-related function, it is necessary to set the WiFi mode.

ESPAT has 3 WiFi modes:   
- WiFiDriverMode.AP: to configure the module as an access point.  
- WiFiDriverMode.STA: To configure the module as a station.  
- WiFiDriverMode.AP_STA: To set up the previous two modes at the same time.

the WiFi mode can be changed at any time, but keep in mind that the module will not automatically connect to the WiFi after the AP mode is changed to STA (this is not a hardware or driver limitation, it is just a default setting, it can be changed in the future according to user feedback)

TODO: configure AP doc  
TODO: configure: STA doc

all WiFi events are received by a callback: 
`fn on_WiFi_event(event: WifiEvent, data: ?[]const u8, user_data: ?*anyopaque) void`:
- `event`: enum of WiFi events
- `data`: some WiFi events may return additional data
- `user_data`: optional pointer to a user parameter

simply pass the function to the `on_WiFi_event` attribute to handle WiFi events.

to add user parameters, pass a reference from the data to the `internal_user_data` attribute (Note: this parameter is shared across all Driver event callbacks).



### Basic network
TODO: TCP/UDP/SSL client Doc  
TODO: TCP/UDP/SSL server Doc  
TODO: TCP/UDP/SSL client AND server coexistence Doc

### Error Handling
TODO

