
To create a modified version of the firmware with custom pins, just follow these steps:
1. Download the firmware following [Espressif's guide](https://docs.espressif.com/projects/esp-at/en/release-v2.2.0.0_esp8266/AT_Binary_Lists/ESP8266_AT_binaries.html).

2. Download the `at.py` program from the tools folder in the [ESPAT repo](https://github.com/espressif/esp-at/tree/master/tools).

3. Run the python command ```python at.py modify_bin -tx <tx pin> -rx <rx pin> -cts <cts pin> -rts <rts pin> -in <factory bin patch> --output <output bin patch>```

4. Send the generated binary to the board.

That's enough to have version 2.2.0.0 running on third-party boards based on the ESP8266 :)