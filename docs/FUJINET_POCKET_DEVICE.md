# A FujiNet device for the Analogue Pocket: specification

What a FujiNet device has to be for this core's FujiNet support
(`src/fpga/core/fujinet_mailbox.sv`; README, "FujiNet over the link port or
cartridge slot"). Nothing here is built yet. The link itself is proven: on a
Pocket (2026-11-19) the core exchanged requests and replies with fujinet-pc
through an FT232H on the link port, and (2026-11-20) booted games the
FujiNet pushed ([FUJINET_TESTING.md](FUJINET_TESTING.md)).

## 1. What it is

An ESP32-S3 running FujiNet's firmware, talking to the Pocket over a 3.3 V
serial line. The Pocket's core is the cartridge: it serves the FujiNet 7800
mailbox to the program, so the device needs no microcontroller of its own on
the console side. Compared with FujiNet's own 7800 cartridge
(fujinet-hardware `ATARI-7800/FujiNet-7800-Rev0`), the device is that board's
FujiNet half alone: the RP2354B, its SRAM and the 74HCT glue are what the
core replaces.

## 2. The link

| | |
|---|---|
| Protocol | FujiBus packets in SLIP frames (fujinet-firmware `lib/bus/rs232`), the same on every FujiNet |
| Serial | 115,200 baud, 8 data bits, no parity, 1 stop bit; no flow control |
| Levels | 3.3 V logic, idle high |
| Who talks first | the core: one request, one reply; the device sends unasked only while a MOUNT_IMAGE is under way (see 7) |

**Pins, cartridge slot** (the intended home):

| Cartridge pin | GBA name | Core | Device |
|---|---|---|---|
| 5 | /CS | TX (output, held high when idle) | UART RX |
| 31 | /REQ | RX (input) | UART TX, through the buffer in 4 |
| 32 | GND | ground | ground |
| 1 | VCC | 3.3 V while the Pocket runs | power sense only (4); draw nothing from it |

Every other cartridge pin is left unconnected. The core leaves them as
Analogue's template does (bank 0 an output held high, the rest inputs).

**Pins, link port** (for bench work): SO (pin 2) is the core's TX, SI (pin 3)
its RX, pin 6 ground; pin 1 unconnected. The core listens to both ports and
locks to the one that answers, so the same device works on either.

## 3. Firmware

- **Personality:** FujiNet's generic RS232 build (`build_platform =
  BUILD_RS232`). It is what FujiNet's own 7800 cartridge runs
  (`fujiversal-atari7800`), and what fujinet-pc's RS232 build runs: the one
  that answered the Pocket. Their 7800 pin map says it plainly: "Nothing here
  is 7800-specific -- the console identity lives entirely in the RP2354B
  firmware."
- **Transport:** a wired UART. `lib/bus/rs232/rs232.h` takes the UART when the
  pin map defines `PIN_UART1_RX` (or `PIN_UART2_RX`), USB otherwise. The
  existing `fujinet-rs232-s3` build (`include/pinmap/rs232_s3.h`) is the
  model: UART1 RX on GPIO41, TX on GPIO42, `PIN_BUS_UART UART_NUM_1`.
- **A new pin map** for the board: UART1 on two free GPIOs; SD, LED and
  buttons wherever the board puts them. The RS-232 handshake pins (RI, DCD,
  RTS, CTS, DTR, DSR) can all be `GPIO_NUM_NC`: the UART channel only sets
  them up as plain GPIO and the bus never waits on them
  (`lib/hardware/ESP32UARTChannel.cpp`, `lib/bus/rs232/rs232.cpp`).
  `PIN_RS232_INVALID` (the RS-232 board's transceiver flag) was not found in
  use in `lib/` or `include/`; worth confirming in `src/`.
- **Baud:** 115,200 is the RS232 build's default (`CONFIG_DEFAULT_RS232_BAUD`).
  The core is fixed at it.

## 4. Electrical

- **Voltage switch:** the cartridge's lower corner over the Pocket's voltage
  switch must be GBA-shaped, so the slot stays at 3.3 V. Cut it 0.5-1 mm deeper
  and wider than a GBA cart's, so the switch is never grazed or half pressed,
  and leave enough side wall to guide the cart straight. A GB/GBC-shaped corner
  would put the slot, and the ESP32's pins, at 5 V.
- **No back-powering:** the device has its own battery; the Pocket may be off.
  Its TX goes to pin 31 through a single buffer (74LVC1G125 class) powered
  from cartridge pin 1, so an unpowered Pocket never sees current from it.
  The device's RX (pin 5) takes a series resistor (100-330 ohm).
- **Power sense:** pin 1's 3.3 V (the Pocket on, cart power on) can enable the
  device's regulator through a small MOSFET or the regulator's EN pin, so the
  device wakes and sleeps with the Pocket and needs no power switch. Pin 1
  carries the sense current only.
- **Cart power:** the core asks for it (`core.json` `cartridge_adapter` 0); the
  slot's level translators need it.

## 5. Power

The device powers itself. The Pocket's cartridge rail has only been seen to
supply about 0.2 W (an EZ-Flash Omega, the hungriest common flash cart, which
already has trouble when the Pocket is low on charge). An ESP32-S3 on Wi-Fi
averages roughly 0.3-0.5 W and peaks at 1-1.6 W in transmit bursts (typical
figures, not measured here).

- **Cell:** a thin LiPo pouch. A 303450 (3 x 34 x 50 mm, roughly 400-500 mAh)
  gives about 4 h at a 100 mA average; a 403450 (4 mm, roughly 600 mAh) about
  5-6 h. Protected cell, or a protection IC (DW01 class with its MOSFET pair).
  A coin cell cannot supply the current.
- **Charging:** USB-C, single-cell charger (MCP73831 class) at about 0.5 C, a
  charge LED. Not from the Pocket.
- **3.3 V:** an LDO of 500 mA or more with low dropout, or a buck-boost for the
  whole of the cell's range; a few hundred uF of bulk capacitance for the
  Wi-Fi bursts.
- **Firmware help:** Wi-Fi modem sleep between requests, and a capped transmit
  power, stretch the battery and soften the peaks.

## 6. Form

- **A GB-cart-sized body with the GBA corner** (4). A GB cart stands about
  half its height above the Pocket, a GBA cart sits nearly all inside: the
  exposed upper part is where the antenna, USB-C and battery go.
- **In the slot:** the edge fingers, the TX buffer, the power sense and the
  regulator.
- **Above the Pocket:** the ESP32-S3 module with its antenna at the top edge,
  the cell, USB-C (top or side), a microSD slot, a status LED, the buttons.
- **About 8 mm thick**, as a GB cart.
- **Check the fit with a printed blank** before any board: that it seats fully,
  clears the voltage switch and the shoulder buttons.

**Parts to reuse:** FujiNet-7800-Rev0's FujiNet half, which that board in turn
took from FujiNet's NES / SMS Rev0: ESP32-S3-WROOM-1-N16R8, microSD,
USB-C with a CP2102N (programming and the debug console) and its auto-program
circuit, a WS2812-2020 status LED, RESET / BOOT buttons.

## 7. What works, and what does not

- **Works:** FujiNet programs loaded from the Pocket's SD card, using the
  FujiNet device ($70) and the network devices N1-N8 ($71-$78): adapter
  configuration, Wi-Fi setup commands, HTTP, TCP, the rest of the network
  device's protocols, app keys, everything that is a request and its reply.
- **Booting games:** MOUNT_IMAGE's image push. The core takes the pushed
  game into the PSRAM and starts it through its own cartridge load path
  ([FUJINET_GAME_LOADING.md](FUJINET_GAME_LOADING.md)); seen working on a
  Pocket with fujinet-pc (2026-11-20). PLAY GAME LOBBY waits for a 7800
  lobby on FujiNet's server.
- **Not served:** the cartridge's hot operations other than the swap, and
  the High Score Cart kept on the device's SD card. The core's own HSC and
  its save on the Pocket's SD card serve instead, for games the FujiNet
  boots too; set High Score Cart to On for a game whose header lacks the
  flag.
- **CONFIG**, FujiNet's own 7800 menu, runs as an `.a78` from the Pocket's SD
  card (in simulation, 2026-11-19), all but booting games
  ([FUJINET_TESTING.md](FUJINET_TESTING.md), section 5).

## 8. Bring-up

With the core's test cart, `sim/fujinet/fn_test.asm`
([FUJINET_TESTING.md](FUJINET_TESTING.md)):

1. Device unpowered or absent: `ERR 01 NO LINK`, `PORT -`.
2. Device on: `REPLY 06 ACK`, `RXLEN 00F0`, its SSID, IP address and firmware
   version, `PORT CART` (or `PORT LINK`).
3. SELECT: an HTTP GET of example.com on N1, with OPEN, STATUS, READ and CLOSE
   each shown, and the first bytes of the page.
