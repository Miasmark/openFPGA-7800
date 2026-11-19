# FujiNet game loading: design

How the core would load a game a FujiNet pushes (MOUNT_IMAGE), so that
FujiNet's CONFIG, and any FujiNet program, can start games over the network.
Status (2026-11-20): steps 1 to 4 are built and pass in simulation. The
receiver passes `sim/fujinet/run_fujinet.py`. Staging and the replay pass
`sim/fujinet/run_fnstage.sh`: the PSRAM model with capture writes and cache
reads alongside, then the file read back through the loader with and
without its header. End to end, `sim/run_sim.sh`'s FujiNet section
(`ONLY=fujinet` alone) boots a game a FujiNet model pushes over the link
port, as an A78 and as a bare ROM. Not yet fitted (step 5) or tried on a
Pocket.

The approach reuses what the BupChip and DARIA already have on the Pocket's
PSRAM (cram0): a writer on clk_arm fed by messages from clk_sys
(`bupchip/bup_asset_wr.sv`), and a byte-read port from clk_sys
(`bupchip/daria_smp.sv`). The pushed image is staged in the PSRAM, and on the
swap it is replayed through the core's own cartridge load path, so the game
starts exactly as if the Pocket had loaded it from SD.

## 1. What a FujiNet sends

From fujinet-firmware `lib/device/rs232/disk.cpp` (`push_image`) and
`pico/common/src/fujimail.c` (`fujimail_inbound`), while the program's
MOUNT_IMAGE ($F8 to $70) is outstanding:

| Frame (device $FF) | Contents | The cart answers |
|---|---|---|
| NET_OPEN $4F | a 2-byte parameter (the segment), then 5 bytes: stream (0 the image, 1 a `.cfg`), size (32-bit LE) | ACK, or NAK to refuse |
| NET_WRITE $57 | up to 512 bytes of the stream (`DISK_SECTORBUF_SIZE`) | ACK |
| NET_CLOSE $43 | nothing (commit), or one byte $01 (abort) | ACK |

Then the FujiNet answers the MOUNT_IMAGE itself. The image stream is the whole
`.a78` file, its 128-byte header included when it has one
(`lib/media/rom/Atari7800ROM.cpp` takes a headerless image only in whole 16K
banks). The `.cfg` stream, when there is one, carries a `mapper=` override.

The core's mailbox already decodes these frames and answers them (refusing
the OPEN today). It already restarts the reply wait on each, as fujinet's own
`fujibus_usb.c` does.

## 2. The program's side

FujiNet's CONFIG (fujinet-config `atari7800/st_boot.c`) and fujinet-lib's
`fuji_a7800_boot()`:

1. send MOUNT_IMAGE, and while it is outstanding watch the status page's
   BOOT_STATE (`$0C06`): 1 transferring, 2 READY, $80 FAILED with BOOT_ERR
   (`$0C08`); BOOT_PCT (`$0C07`), BOOT_GOT (`$0C16-$0C18`) and BOOT_TOT
   (`$0C19-$0C1B`) drive the progress bar;
2. once the reply is in and BOOT_STATE is READY, read STAGED (`$0C1F`): bit 3
   (an HSC ROM) leads to the High Score Cart offer instead;
3. write BOOTLOCK (register $11) = $B5, then SEI, CTRL ($3C) = $7F, JMP $0600:
   the cartridge's loader.

## 3. The design

### 3.1 Receiving the push (fujinet_mailbox.sv)

- **OPEN, stream 0:** if the size is 1 to 524,416 bytes (512 KiB of ROM and a
  header; FujiNet's own 7800 cartridge has 512 KiB of SRAM), ACK, set
  BOOT_STATE 1, BOOT_TOT, BOOT_GOT 0, and send START to the stager. Otherwise
  NAK, BOOT_STATE $80, BOOT_ERR 1 (too big).
- **OPEN, stream 1 (`.cfg`):** ACK and ignore the stream: the image's own A78
  header decides the mapper. A documented limit.
- **WRITE:** each byte goes to the stager at the next offset; BOOT_GOT and
  BOOT_PCT follow. Bytes past the declared size are dropped.
- **CLOSE:** an abort, or fewer bytes than declared: BOOT_STATE $80, BOOT_ERR 2
  (truncated). Otherwise send SYNC to the stager and set BOOT_STATE 2 (READY)
  only when SYNC comes back: every byte is then in the PSRAM.
- **STAGED:** bit 0 READY; bit 1 the image carries the FUJI claim (the same
  test `fujinet_claim` applies while loading: bytes `$F70-$F75` of the last 4K
  block); bit 2 BIOS OK, always set (the core boots any image, through the
  BIOS or not as the Skip BIOS setting says); bit 3 never (no HSC ROM install).
- **BOOTLOCK** ($B5 to register $11) arms the swap, only while READY.

### 3.2 Staging in the PSRAM (bupchip_pocket.sv, bup_asset_wr.sv)

- **Where:** die 0, from byte 4 MiB (halfword address `$200000`), up to
  1 MiB. Nothing else uses it: a Souper cartridge's ARSC block is captured
  from 0 and is under 4 MiB (the cartridge slot holds 4 MiB); a DARIA image
  takes the first 512 KiB; the BupChip CPU reads only within its asset size.
- **A second message channel** into `bup_asset_wr`, beside `bup_capture`'s:
  WRITE (a halfword, its byte lanes and address in the staging area) and
  SYNC (answered once every earlier write has reached the PSRAM: the
  controller idle two clocks). `fujinet_stage.sv` on clk_sys packs the
  mailbox's bytes into halfwords and sends each with a toggle, holding the
  payload until the answering toggle comes back; the mailbox waits on its
  `busy`. The capture's WRITEs go first, the staging WRITE next, cache reads
  last. A push arrives at most at 115,200 baud, a halfword every 170 us or
  so; a crossing takes well under 1 us.
- **No conflict with the CPU:** a FujiNet program is never a Souper cartridge
  or a 2600 image, so the BupChip CPU is held and its cache does not fill
  while the program runs.

### 3.3 The loader at $0600 (fujinet_mailbox.sv)

While a claimed program runs, the mailbox serves reads at `$0600-$060B`:

```
$0600  JMP $0606        ; FN_LOADER_BOOT: the armed image
$0603  JMP ($FFFC)      ; FN_LOADER_CONFIG: no CONFIG in the core: restart this program
$0606  STA $0DFE        ; FN_HOT_SWAP
$0609  JMP $0609        ; the core takes the console from here
```

The write to `$0DFE` starts the swap if BOOTLOCK armed it (READY); otherwise
the core restarts the running program (a reset), never leaving the console
in the loop.

### 3.4 The swap (fujinet_loader.sv, fujinet_rd.sv, core_top.v)

The staged file is fed through the core's own load path:

- **The reader:** `fujinet_rd.sv` (clk_arm) sits in front of
  `bup_asset_wr`'s read port in `bupchip_pocket.sv`, ahead of `daria_smp.sv`
  and the cache, which pass through it untouched unless a swap reads. The
  loader posts one halfword address per request (a toggle, the address held)
  and gets the halfword back the same way; a read of theirs in flight
  finishes first, and while one of the swap's is out they see no `rd_ack`.
  `daria_smp.sv` is unchanged.
- **The loader:** `fujinet_loader.sv` (clk_sys) starts on the armed hot
  swap. It raises its download flag, reads the file in order and presents
  each byte as one `ioctl_wr` at least 4 clk_sys after the last (the
  bridge's loader manages one every 2.5; `bup_capture` relies on no faster),
  address and data held between strobes as the bridge's are. Before the
  first byte its address is all ones, which no header parser takes for a
  header byte.
- **The mux** is in `core_top.v`, at `atari7800_pocket`'s inputs:
  `cart_download | fn_ld_dl`, and `ioctl_wr`, `ioctl_addr`, `ioctl_dout`,
  `ioctl_wr_any` and `ioctl_hi` (0, the cartridge slot) from the loader while
  its flag is up. With the flag low, which it always is unless a swap runs,
  the bridge's signals pass unchanged.
- **The region PLL:** `pll_region` starts a retune only while no load is in
  progress; the loader's flag joins the bridge's `is_downloading` there
  (through two clk_74a flops), since an A78's region follows its header's
  byte 57 mid-load.
- Everything downstream sees an SD load: the A78 header and its flags, the
  extent, the SDRAM writes, region and the PLL retune, the High Score Cart,
  `bup_capture` (a Souper game's ARSC block is captured into die 0 below
  4 MiB, clear of the staging area), detect2600, and `fujinet_claim`, which
  re-arms the mailbox only if the new game is a FujiNet program. The console
  is held in reset for the load and starts after it, through the BIOS or
  not as the settings say.
- **A headerless image** (bytes 1-5 not "ATARI": FujiNet pushes those only
  in whole 16K banks) is given a generated header: version 3, "ATARI7800",
  its size, the SuperGame flag above 48 KiB, two joysticks, NTSC; the file
  follows from byte 128. Anything the header cannot say (a CRC-picked
  board, a PAL game) is a documented limit.
- **The restart:** an unarmed hot swap holds `reset_in` for 64 clk_sys, as
  a menu reset does, so the running program starts again.
- A Pocket load from the SD card during a swap wins: the bridge's load
  sequence (`is_downloading`, two flops in) ends the replay two clk_sys
  before its own `cart_download` rises, so every consumer sees the replay
  end and the new load begin; a replay never starts during one.

## 4. Risks

- `bupchip_pocket`, `bup_asset_wr` and `daria_smp` carry the BupChip and
  DARIA, with their own benches and fit gates (`sim/bupchip/`, step 7's
  checks). The changes must leave their streams bit for bit as they are when
  no FujiNet program runs.
- The fit's check (g) tripped twice on a retimed register named after
  `read_DB` (2026-11-19, the reverted line test). New logic on the bus side
  should stay small for the same reason.
- The BupChip end-to-end test needs `bupchip.hex`, which the development
  machine does not have; the DARIA section and the capture benches do run.

## 5. Plan

1. **Push receiver** (built): the mailbox's side (3.1) with a stager interface
   (START, a byte stream, SYNC back), and `tb_fujinet` cases for every frame
   and error.
2. **Staging** (built): the second channel in `bup_asset_wr`, a bench against
   `sim/bupchip/s4/psram_model.sv` (`sim/fujinet/run_fnstage.sh`), and the
   BupChip / DARIA benches unchanged.
3. **Loader and swap** (built): `$0600`, the hot swap, `fujinet_loader.sv`,
   the reader `fujinet_rd.sv` (ahead of `daria_smp`, which is unchanged), and
   the input mux in `core_top.v`.
4. **End to end in `tb_load`** (built): a FujiNet model on the link
   (`sim/fujinet/fn_model.sv`) that answers MOUNT_IMAGE by pushing a file,
   a test cart (`fn_boot.asm`) that mounts, waits for READY, arms and jumps
   to `$0600`, and the pushed game (`fn_game.asm`) booting, pushed as an A78
   and as a bare 16K ROM. The first run found the loader's data moving
   ahead of its address (the header parser reads by address), now fixed and
   checked in `run_fnstage.sh` too.
5. **Fits and the full regression**, then a test build for CONFIG and
   fujinet-pc on a Pocket.
