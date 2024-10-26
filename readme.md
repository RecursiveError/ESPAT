# ESPAT
simple driver made in Zig to use ESP(32/8266) boards as WiFi module via AT command firmware

***Important***: This driver is still under development, ~~and invalid inputs will cause errors~~ There are checks for most errors, but invalid inputs may cause deadlocks or break

__Minimum AT Firmware Version__: 2.2.0.0  

**Warning**: for Ai-thinker modules such as ESP-01 or ESP-12E with Boantong AT firmware it is still possible to use the modes: client only and server only, but be aware that some boards do not provide CTS and RTS pins for UART interface, so you are responsible for ensuring that no data is lost

## TODO list
List of all the tasks that need to be done in the code:
- add more config (for all commands)
- enbale full suport for SSL (at the moment it is not possible to configure SSL certificates)
- add more functions to clients
- add timeout to avoid deadlocks on read functions
- add optinal args for WiFi
- break data bigger than 2048 into multi 2048 pkgs on send
- add eneble_IPv6 func [maybe]
- add bluetooth LE suport for ESP32 modules [maybe]
- remove "process" completely from the microZig implementation when "Framework driver" is added, Use notification instead of pull [maybe]

## Supported Features
- [ ] SSL config
- [x] STA WiFi mode
- [X] AP WiFi mode
- [x] AP + STA WiFi mode
- [x] TCP/UDP Client
- [ ] SSL Client
- [x] TCP Server
- [ ] SSL Server
- [x] Server + Client

## Others
Features that may be implemented
- [ ] UART Config  
- [ ] Build-in HTTP client
- [ ] Build-in MQTT client
- [ ] user Commands 
- [ ] Bluetooth LE (only for ESP32 based modules)
- [ ] Optional AT Features



## Get started

### Porting
TODO: Generic port  
TODO: microzig port  

### Basic WiFi config
TODO: wiFi modes  
TODO: configure AP doc  
TODO: configure: STA doc  

### Basic network
TODO: TCP/UDP/SSL client Doc  
TODO: TCP/UDP/SSL server Doc  
TODO: TCP/UDP/SSL client AND server coexistence Doc  

