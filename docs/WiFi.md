- [WiFi setup](#basic-wifi-config)
    - [WiFi AP](#setting-up-the-module-as-an-access-point)
    - [WiFi STA](#setting-up-the-module-as-a-station)
    - [WiFi Events](#wifi-events)
        - [WiFi errors](#wifi-error-table)
    - [WiFi example](#wifi-example)


## Basic WiFi config

To use ESP's WiFi features, you need to create a device: `WiFi.Device.init()` 

link this device to the Runner with: `WiFi_device.link_device(&my_drive);`

Before using any WiFi-related function, it is necessary to set the WiFi mode using the function: `set_WiFi_mode(mode: DriverMode)`

ESPAT has 3 WiFi modes:   
- DriverMode.AP: to configure the module as an access point.  
- DriverMode.STA: To configure the module as a station.  
- DriverMode.AP_STA: To set up the previous two modes at the same time.

the WiFi mode can be changed at any time, but keep in mind that the module will not automatically connect to the WiFi after the AP mode is changed to STA (this is not a hardware or driver limitation, it is just a default setting, it can be changed in the future according to user feedback)

#### Setting up the module as an access point:
With WiFi configured for AP or AP_STA mode , create a configuration struct: `WiFi.APConfig`
the fields in this struct correspond directly to the settings of the AT commands. [soft AP parameters](https://docs.espressif.com/projects/esp-at/en/release-v4.0.0.0/esp32/AT_Command_Set/Wi-Fi_AT_Commands.html#id28)

To save the settings and enable SoftAP mode, pass the configuration struct to the function: `WiFi_config_AP(config: APConfig)`

#### Setting up the module as a station:
With WiFi configured for STA or AP_STA mode , create a configuration struct: `WiFi.STAConfig`
the fields in this struct correspond directly to the settings of the AT commands. [STA parameters](https://docs.espressif.com/projects/esp-at/en/release-v4.0.0.0/esp32/AT_Command_Set/Wi-Fi_AT_Commands.html#id11)

To save the settings and enable STA mode, pass the configuration struct to the function: `WiFi_connect_AP(config: WiFi.STAConfig)`

### WiFi events

all WiFi events are handled by a single handler, which can be set with: `set_WiFi_event_handler(callback: WIFI_event_type, user_data: ?*anyopaque)`:

- `WIFI_event_type`: `fn on_WiFi_event(event: Wifi.Event, user_data: ?*anyopaque) `void``:
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
|SCAN_START| `void` | AP scanning started|
|SCAN_FIND| `ScanData` |an access point was found|
|SCAN_END| `void` | |AP scanning has finished|
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

To disconnect from WiFi, use: `WiFi.disconnect()`

(note: you don't need to use this function to switch WiFi networks)

#### WiFi Example
```zig
const Driver = @import("ESPAT");
const WiFi = Driver.WiFi;

...
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
        else => {
            std.log.info("WiFi got event {any}", .{event});
        },
    }
}

const STA_config = WiFi.STAConfig{
    .ssid = wifi_ssid,
    .pwd = wifi_password,
    .wifi_protocol = .{
        .@"802.11b" = 1,
        .@"802.11g" = 1,
        .@"802.11n" = 1,
    },

    .wifi_ip = .{ .static = .{ .ip = "192.168.15.37" } },
};

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


...
fn main() !void {
    ...
    my_driver.init_driver();
    var WiFi_dev = WiFi.Device.init();
    WiFi_dev.link_device(&my_drive);
    WiFi_dev.set_WiFi_event_handler(WiFi_callback, null);
    try WiFi_dev.set_WiFi_mode(.AP_STA);
    try WiFi_dev.WiFi_config_AP(AP_config);
    try WiFi_dev.WiFi_connect_AP(STA_config);
    ...
}
```

TODO: Add doc for all WiFI functions