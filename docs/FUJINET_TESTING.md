# Testing the FujiNet link

How to check the core's FujiNet support (`src/fpga/core/fujinet_mailbox.sv`;
README, "FujiNet over the link port or cartridge slot") on a Pocket, from no
hardware at all up to a FujiNet running on a PC.

The test program is `sim/fujinet/fn_test.asm`. Build it with `dasm` and sign
it (the header of the file has the commands); the test packages carry it as
`Assets/7800/common/fn_test.a78`. It claims the FujiNet mailbox, shows the
status page, asks the FujiNet for its adapter configuration
(GET_ADAPTERCONFIG_EXTENDED, $C4 to device $70) and shows the answer. Fire
or Reset asks again.

## 1. Nothing attached

Expected: `ERR 01 NO LINK` about 1.5 s (90 frames) after the request,
`PORT -`. This shows the core found the claim, serves the mailbox, and gives
up on a silent line. (Seen on a Pocket, 2026-11-17.)

## 2. Loopback

Join the core's TX to its RX through a 330 ohm to 1 k resistor (not a bare
wire: a slip onto ground or VCC then only passes a few mA):

- **Link port:** pin 2 (SO) to pin 3 (SI). With a GBC link cable, plug one
  end into the Pocket and put the resistor across the free end's SO and SI
  contacts; the cable crosses them over. Find the contacts with a
  multimeter on continuity, and keep away from pin 1 (VCC).
- **Cartridge slot:** pin 5 (GBA /CS) to pin 31 (GBA /REQ), on a GBA
  cartridge breakout board.

Expected: `ERR 00 OK`, `REPLY C4 LOOPBACK`, `RXLEN 0000`, `LINK 01`, and
`PORT LINK` or `PORT CART`. The core heard its own request come back as a
good frame, so its TX and RX both work on that port.

If the loopback still reports NO LINK, note which port fails: the link
port's translators may need power the core does not ask for, or a
direction bit may be wrong.

## 3. A FujiNet on a PC

FujiNet's firmware repository builds a PC version of the FujiNet. Its RS232
target (`FUJINET_TARGET=RS232`; `./build.sh -p RS232` in fujinet-firmware)
speaks the same protocol as FujiNet's own 7800 cartridge (`lib/bus/rs232`:
SLIP-framed FujiBus packets at 115,200 baud) and can use a real serial port
as well as a TCP connection (BoIP).

**Wiring** (a 3.3 V USB serial adapter, logic level 3.3 V):

| Pocket link port | Adapter |
|---|---|
| pin 2, SO (the core's TX) | RX, through a ~330 ohm resistor |
| pin 3, SI (the core's RX) | TX, through a ~330 ohm resistor |
| pin 6, GND | GND |
| pin 1, VCC | not connected |

The adapter is powered by the PC; nothing is drawn from the Pocket.

**fujinet-pc's configuration** (`fnconfig.ini`, beside the program), as its
config reader names the keys:

```
[BOIP]
enabled=0

[Serial]
port=/dev/ttyUSB0
baud=115200
```

(`port` is the adapter's device: `/dev/ttyUSB0` or `/dev/ttyACM0` on Linux,
`/dev/cu.usbserial-*` on macOS. 115,200 is also the RS232 build's default
baud rate.)

Expected: `ERR 00 OK`, `REPLY 06 ACK`, `RXLEN 00F0` (the 240-byte adapter
configuration), and the SSID, IP address and firmware version fujinet-pc
reports.

These instructions come from reading fujinet-firmware's source
(`fujinet_pc.cmake`, `lib/bus/rs232/rs232.cpp`, `lib/config/fnc_serial.cpp`,
`lib/device/rs232/rs232Fuji.cpp`, which answers $C4); they have not been
tried with this core yet.

## Another cartridge in the slot

- **Ordinary games:** the cartridge pins stay as Analogue's template sets
  them (bank 0 an output held high, the rest inputs), so an inserted
  cartridge sees no access. Cart power is on (`cartridge_adapter` 0), so it
  is powered while the core runs.
- **A FujiNet program:** TX toggles cartridge pin 5. On a GBA cart that is
  ROM /CS, on a GB/GBC cart the save RAM's select; /WR and /CS2 never move,
  so nothing is written. Analogue's own adapters (Game Gear, Lynx, ...) use
  the pins their own way: take them out first. A cartridge that drives pin
  31 (GBA /REQ, GB audio in) can garble replies until the core locks to the
  link port.
- **Voltage:** a GB or GBC cartridge presses the Pocket's voltage switch, and
  the whole rail goes to 5 V, the link port included. An FT232H's inputs
  take that; an ESP32 or any other 3.3 V-only device does not. With such a
  device on the link port, leave the slot empty or use a GBA cartridge. A
  device in the cartridge slot with a GBA-shaped edge keeps the rail at
  3.3 V.

## Power for a real FujiNet

A FujiNet device should bring its own power (USB or a LiPo) and share only
ground, TX and RX. The Pocket's cartridge rail has been seen to supply about
0.2 W (an EZ-Flash Omega, the hungriest common flash cart, which already has
trouble when the Pocket is low on charge); an ESP32 on Wi-Fi averages more
and peaks several times higher.
