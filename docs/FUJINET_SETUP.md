# Connecting a FujiNet to the Pocket

How to run FujiNet's 7800 menu (CONFIG) on the core and boot games from it,
with the FujiNet running on a computer and a USB serial adapter on the
Pocket's link port. This is the setup tested on a Pocket (2026-11-20). There
is no FujiNet for the Pocket's cartridge slot to buy yet
([FUJINET_POCKET_DEVICE.md](FUJINET_POCKET_DEVICE.md) specifies one).

What the core does, and its limits, are in the README: *FujiNet over the link
port or cartridge slot* and *New in 2.2.7*.

## 1. What you need

- The core, 2.2.7 or later.
- A computer to run **fujinet-pc**, FujiNet's PC version, built for RS232
  (2).
- A **USB serial adapter with 3.3 V logic** (an FT232H was used; an FT232R,
  CP2102 or CH340 set to 3.3 V should do the same). Not a 5 V adapter, and
  not an RS-232 (±12 V) one.
- A **Game Boy link cable** to cut, two resistors of about 330 ohm, and a
  multimeter to find the wires.
- A copy of **fujinet-firmware** (it carries the built CONFIG) and Python 3,
  to make CONFIG into an `.a78` (4).

## 2. fujinet-pc

FujiNet's firmware repository, fujinet-firmware, builds fujinet-pc. Build its
RS232 version (`./build.sh -p RS232` there; follow that repository's own
instructions for what the build needs). Its RS232 version speaks the
protocol the core uses: FujiBus packets in SLIP frames at 115,200 baud.

Beside the program, in `fnconfig.ini`, turn off its TCP transport and give it
the adapter:

```
[BOIP]
enabled=0

[Serial]
port=/dev/ttyUSB0
baud=115200
```

`port` is the adapter's device: `/dev/ttyUSB0` or `/dev/ttyACM0` on Linux,
`/dev/cu.usbserial-*` on macOS.

## 3. Wiring

| Pocket link port | Adapter |
|---|---|
| pin 2, SO (the core's TX) | RX, through ~330 ohm |
| pin 3, SI (the core's RX) | TX, through ~330 ohm |
| pin 6, GND | GND |
| pin 1, VCC | not connected |

Wire colours differ from cable to cable: find each pin with the multimeter.
The adapter is powered by the computer; nothing is drawn from the Pocket.

**Keep the cartridge slot empty, or use a GBA cartridge in it.** A GB or GBC
cartridge switches the slot's rail to 5 V, and the link port with it.

## 4. CONFIG

CONFIG is FujiNet's (GPL-3.0), so the core does not ship it.
fujinet-firmware carries a built copy. This repository's script wraps it
as an `.a78`; run it from a clone of openFPGA-7800:

```
python3 sim/fujinet/mk_config_a78.py PATH/TO/fujinet-firmware fujinet_config.a78
```

Copy `fujinet_config.a78` to the Pocket's SD card with your other 7800 games.
With *Skip BIOS* on (the default) it runs as it is. To run it through a
7800 BIOS, sign it: add
`--sign PATH/TO/a7800-toolkit/tools/sign7800.py`.

## 5. Using it

1. Start fujinet-pc on the computer.
2. On the Pocket, load `fujinet_config.a78`. CONFIG shows its banner and
   goes to its host slots. fujinet-pc uses the computer's network, so its
   Wi-Fi screen shows a stand-in network.
3. Pick a host, browse to a 7800 game and boot it. The FujiNet sends the
   game, and the core loads it as it would from the SD card. This takes a
   few seconds.

The game's A78 header decides the hardware, as from the SD card:

- **No POKEY music:** the copy's header lacks the POKEY flag. Correct the
  header, or use a copy that has it.
- **No high scores saved:** set *High Score Cart* to On. Scores go to the
  Pocket's `hsc.sav`.
- **Alien Brigade and Crossbow:** set Port 1 to Light Gun in the menu while
  the game loads, or Reset from the menu after.

PLAY GAME LOBBY fails with `?MOUNT ERROR 00` or `?HOST ERROR 00`: FujiNet's
server has no 7800 lobby yet. FujiNet's own 7800 cartridge does the same.

## 6. If it does not answer

CONFIG shows NO LINK, or a request ends with error 1 after 1.5 s:

- **Check the wiring:** RX and TX swapped is the usual mistake. Check the
  ground too.
- **Check fujinet-pc:** is it running, on the right `port`, at 115,200?
- **Check the adapter:** it must be at 3.3 V logic.
- **Narrow it down with the test program:** `sim/fujinet/fn_test.a78`
  (source: `fn_test.asm`). It shows the core's status page and asks the FujiNet for
  its configuration. [FUJINET_TESTING.md](FUJINET_TESTING.md) goes from no
  hardware (a loopback: SO to SI) up to fujinet-pc, with what each step
  should show.
