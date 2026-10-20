# Development board status

All 20 development boards under `data/components/boards.json` are implemented as
**documented pinouts + external electrical terminals**: every header pin is a real
terminal in the netlist (`pin_nets`), every board cites its provenance references, and
no board MCU is a solver element. The optional firmware backend executes compiled AVR
sketches (avr8js via Node) for the ATmega328P boards only - every other SoC reports
this honestly as "external / no firmware backend" instead of pretending to run.

Each board also carries a documented identity (`board_info`): MCU part, core, clock,
logic voltage, USB connector, programming interface and the manufacturer-documented
fixed interface-to-pin mappings (`interfaces`: i2c/spi/uart/pwm/analog_in). Every
interface pin is validated to exist in the pinout, and every board passes structural,
electrical-terminal, save/load and MCP-discovery tests (see `tests/unit/test_boards.gd`).

| Board | MCU / SoC | Header pins | Logic | Firmware backend |
|---|---|---|---|---|
| Arduino Uno R3 | ATmega328P | 29 | 5 V | full (avr8js) - FQBN `arduino:avr:uno` |
| Arduino Uno R4 WiFi | Renesas RA4M1 | 30 | 5 V | none - non-AVR SoC, no firmware model (honest `external`) |
| Arduino Nano | ATmega328P | 30 | 5 V | full (avr8js) - FQBN `arduino:avr:nano` |
| Arduino Mega 2560 | ATmega2560 | 79 | 5 V | none - AVR family, but the harness models only the ATmega328P (honest `external`) |
| Arduino Leonardo | ATmega32U4 | 29 | 5 V | none - AVR family, but the harness models only the ATmega328P (honest `external`) |
| Arduino Micro | ATmega32U4 | 25 | 5 V | none - AVR family, but the harness models only the ATmega328P (honest `external`) |
| Arduino Pro Mini 5V | ATmega328P | 27 | 5 V | full (avr8js) - FQBN `arduino:avr:pro` |
| NodeMCU ESP8266 (v3) | ESP8266EX | 24 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| ESP32 DevKit V1 | ESP32-WROOM-32 | 30 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| ESP32-C3 DevKitM-1 | ESP32-C3 | 21 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| Raspberry Pi Pico | RP2040 | 40 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| Raspberry Pi Pico 2 | RP2350 | 40 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| Raspberry Pi 4 Model B | BCM2711 | 40 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| Raspberry Pi Zero 2 W | RP3A0 | 40 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| Raspberry Pi 5 | BCM2712 | 40 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| STM32 Blue Pill (F103C8T6) | STM32F103C8T6 | 41 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| STM32 Black Pill (F411CEU6) | STM32F411CEU6 | 39 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| Teensy 4.1 | NXP i.MX RT1062 | 39 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| Seeed XIAO (SAMD21) | SAMD21G18A | 14 | 3.3 V | none - non-AVR SoC, no firmware model (honest `external`) |
| Digispark ATtiny85 | ATtiny85 | 8 | 5 V | none - AVR family, but the harness models only the ATmega328P (honest `external`) |

Notes:

- The three firmware-capable boards are explained by hardware truth: the Uno R3,
  Nano and Pro Mini all carry ATmega328P family chips (`board_fqbn` returns their
  real FQBNs; only they return an FQBN at all). The Mega2560 (ATmega2560), Leonardo
  (32u4), Micro (32u4) and ATtiny85 are AVR family but carry parts the harness does
  not model, and the ESP8266/ESP32, RP2040/RP2350, Pi SBCs, STM32, Teensy and XIAO
  (SAMD21) are different architectures entirely; claiming `full` firmware for either
  group would simulate hardware the harness does not possess.
- Header sizes corrected against manufacturer documentation: Pico/Pico2 and all
  three Raspberry Pi SBCs expose the complete 40-pin header (including ADC_VREF,
  ID_SD/ID_SC and both 3V3 pins), the ESP32 DevKit V1 has GND on both sides (30),
  and the classic Nano has its 2x15 header with AREF and RESET on both sides (30).
- `arduino_android_usb_host_shield` (in `mobile_devices.json`) is an accessory
  shield, not one of the 20: MAX3421E USB host controller over SPI, no MCU of its
  own, so `firmware` is not its backend.

