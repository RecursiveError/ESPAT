# ESPAT
simple driver made in Zig to use ESP(32/8266) boards as WiFi module via AT command firmware

AT command firmware for ESP modules (32/8266) is a simple and inexpensive way to add wireless connection to embedded devices, although it is more limited than conventional RF modules, ESP modules abstract much of the network stack, allowing their use in more limited devices.

***Important***: This driver is still under development, invalid inputs may cause deadlocks or breaks

__Minimum Espressif AT Firmware Version__: 2.2.0.0

**Warning**: for Ai-thinker modules such as ESP-01 or ESP-12E.
Boantong AT (BAT) firmware is not supported, and Espressif firmare is not compatible with the pin layout of these boards, to use them it is necessary to customize the firmware to ESP8266, if you don't know how to do this follow this guide: (TODO: firmware guide)

## TODO list
List of all the tasks that need to be done in the code:
- add timeout to avoid deadlocks on read functions
- add eneble_IPv6 func [maybe]
- add bluetooth LE suport for ESP32 modules [maybe]
- remove "process" completely from the microZig implementation when "Framework driver" is added, Use notification instead of pull [maybe]

## Supported Features
- [x] WiFi STA/AP/AP+STA modes
- [x] TCP/UDP Client
- [x] TCP Server
- [x] Server + Client mode

## Others
Features that may be implemented
- [ ] UART Config
- [ ] Build-in SSL client  
- [ ] Build-in HTTP client
- [ ] Build-in MQTT client
- [ ] user Commands 
- [ ] Bluetooth LE (only for ESP32 based modules)
- [ ] Optional AT Features



## Get started
TODO topics  
### Porting
 
To start using this driver, the first step is to create the driver with: `EspAT(RX_buffer_size, TX_pool_size).initTX_callback, RX_callback)`  

- RX_buffer_size: Byte size of the driver's input buffer, minimum size: 50 bytes
- TX_pool_size: Driver event pool size, minimum size: 5 events (amount of events used at driver startup)

This process is necessary because this driver does not do any kind of dynamic allocation (this will probably change in future versions)


TODO: Generic port  
TODO: microzig port  

### Basic WiFi config

Before using any WiFi-related function, it is necessary to set the WiFi mode.

ESPAT has 3 WiFi modes:   
- WiFiDriverMode.AP: to configure the module as an access point.  
- WiFiDriverMode.STA: To configure the module as a station.  
- WiFiDriverMode.AP_STA: To set up the previous two modes at the same time.



TODO: configure AP doc  
TODO: configure: STA doc  

### Basic network
TODO: TCP/UDP/SSL client Doc  
TODO: TCP/UDP/SSL server Doc  
TODO: TCP/UDP/SSL client AND server coexistence Doc  

