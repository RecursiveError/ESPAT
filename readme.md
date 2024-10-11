# ESPAT
simple driver made in Zig to use ESP(32/8266) boards as WiFi module via AT command firmware

***Important***: This driver is still under development and invalid inputs will cause errors

__Minimum AT Firmware Version__: 2.2.0.0  

**Warning**: for Ai-thinker modules such as ESP-01 or ESP-12E with Boantong AT firmware it is still possible to use the modes: client only and server only, but be aware that some boards do not provide CTS and RTS pins for UART interface, so you are responsible for ensuring that no data is lost

## Supported Features
- [ ] UART Config
- [ ] SSL config
- [x] STA WiFi mode
- [X] AP WiFi mode
- [ ] AP + STA WiFi mode
- [x] TCP/UDP Client
- [ ] SSL Client
- [x] TCP Server
- [ ] SSL Server
- [x] Server + Client
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

