# ESPAT

ZIG VERSION: 0.15.1





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
- mDNs



## Get started

***WARNING***: Documentation for version 0.15.1 is still under development. Files in the `docs/` directory are outdated! Please refer to the examples for guidance in the meantime.

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

TODO

### Devices
- WiFi TODO
- Networkdocs TODO
- HTTP CLient TODO


### Examples:
complete example code: 
- [Generic port](examples/) 




