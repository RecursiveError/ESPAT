# ESPAT

ZIG VERSION: 0.14.0

simple driver made in Zig to use ESP32 boards as WiFi module via AT command firmware

AT command firmware for ESP modules (32/8266) is a simple and inexpensive way to add wireless connection to embedded devices, although it is more limited than conventional RF modules, ESP modules abstract much of the network stack, allowing their use in more limited devices.

***Important***: This driver is still under development, invalid inputs may cause deadlocks or breaks

__Recommended Espressif AT Firmware Version__:4.0.0.0
__Minimum Espressif AT Firmware Version__: 3.4.0.0

**Warning**: for Ai-thinker modules such as ESP-01 or ESP-12.
Boantong AT firmware (AT =< 1.7) is not supported, and Espressif firmware (2.2.0.0) is not compatible with the pin layout of these boards, to use them it is necessary to customize the firmware to ESP8266, if you don't know how to do this follow this guide: [custom pin AT](docs/customAT.md)

## Supported Features
- WiFi STA/AP/AP+STA modes
- WiFi static IP and DHCP config
- WiFi protocol config
- Multi conn support
- TCP/UDP Client
- TCP Server
- Server + Client mode
- passive and active recv mode (for All sockets)
- build-in HTTP/HTTPS client



## Get started

- [ESP AT](#what-is-esp-at)
- [Driver](#how-this-driver-works)
- [Porting](#porting)
- [Dvices](#devices)
- [Error Handling](#error-handling)
- [Examples](#examples)

### What is ESP-AT?

The [ESP-AT firmware](https://www.espressif.com/en/products/sdks/esp-at/overview) is an official firmware provided by Espressif Systems for their ESP8266 and ESP32 series of microcontrollers. It transforms the ESP module into a device that can be controlled via standard AT commands over a serial interface.

AT commands, which are simple text-based instructions, enable the configuration and operation of the ESP module without requiring the user to write custom firmware. These commands can be used to perform tasks such as:

    Configuring Wi-Fi connections (e.g., connecting to an access point or setting up as a Wi-Fi hotspot)
    Sending and receiving data over TCP/UDP or HTTP protocols
    Managing low-power modes
    Accessing additional features, like Bluetooth (on ESP32) or GPIO control

The ESP-AT firmware is particularly suitable for applications where the ESP chip is used as a peripheral communication module controlled by another host device, such as a microcontroller or a computer. By using this firmware, developers can focus on the integration and higher-level functionalities of their system without delving into the complexities of programming the ESP chip itself.

### How this driver works

This driver is made in a modular way, where parse of AT commands (Runner)  are separated from the device features (Devices)

Allowing the user to choose between the implementations they want to use without additional memory cost

### Porting
 
To start using this driver it is necessary to create a runner to communicate with the ESP, this can be done with the: `StandartRunner.runner(Config)`

`Config` is a struct that defines the inner workings of the driver, it contains the following fields:
- `RX_size`: input buffer size, minimum: 128 bytes, default value: 2046 bytes.
- `TX_event_pool`: Event buffer size, minimum: 10 events, default value: 25.
- `network_recv_size`: Network buffer size, minimum: 128 bytes, default value: 2046 bytes.

with the type created, just initialize it with: `init(TX_callback,RX_callback, user_data)`

- `TX_callback(data: []const u8, user_data: ?*anyopaque) void`: This function is responsible for sending the driver data to the module.

    - `data`: a slice containing the bytes that need to be sent to the module, note: you don't need to send all the data at once.

    - `user_data`: An optional pointer to a user parameter

    - `Returns`: `Void`

            
- `RX_callback(free_size: usize, user_data: ?*anyopaque) []const u8`: This is an optional function used by the driver to request information.

    - `free_size`: count of bytes that the driver can read, you can return any amount of bytes as long as it does not exceed that value (additional data will be lost)

    - `user_data`: An optional pointer to a user parameter

    - `returns`: a slice containing the read bytes, this slice must live until the next call of this function, after which it can be released

- `user_data`: An optional pointer to a user parameter for TX and RX callbacks


Once the driver type is initialized, the first thing you should do is call the function: `init_driver()`, This function will clear any commands in the event queue and load the driver's startup sequence. To safely turn off the driver, use: `deinit_driver()`

To initialize the event loop, you should call the function `process()` periodically. This function returns internal driver errors.[TODO: Error Handling DOC]

Alternatively you can use the function: `feed([]const u8)` to notify data to the driver and leave RX_callback as null,In this case, it is not necessary to call `process()` periodically, before sending any data using this function it is necessary to check the amount of bytes available in the input buffer with: `get_rx_free_space()`

`feed` returns the amount of bytes saved in the buffer

 **Generic example**:
 ```zig

 const Driver = @import("ESPAT");
 const StandartRunner = Driver.StandartRunner

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
    var driver = StandartRunner.Runner(.{}).init(TX_callback, rx_callback, &serial);
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

### Devices
- [WiFi](docs/WiFi.md)
- [Network](docs/Network.md)
- [HTTP CLient](docs/HTTP.md)


### Examples:
complete example code: 

- [Generic port](docs/generic_port.md) 

- [ESP8266 Support](docs/ESP8266.md) 




