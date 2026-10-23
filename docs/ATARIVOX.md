# AtariVox: notes and plan

Status: in the core from 2.2.1, behind `POCKET_ATARIVOX` (`src/fpga/core/atarivox/`),
on whenever the SaveKey is and *AtariVox Voice* is not Off. The SaveKey half
of the AtariVox (the 24LC256 EEPROM) has been in the core since 2.0.8. The
voice is a speech engine of our own design ("The engine", below), playing
our own sound tables, since the SpeakJet's are not published.

## The device

The AtariVox plugs into controller port 2. It holds:

| Part | Port 2 pins | In the core |
|---|---|---|
| 24LC256 EEPROM | I²C on pins 3/4 (RIGHT, LEFT) | Yes, as the SaveKey |
| SpeakJet speech chip (Magnevation) | Serial in on UP; "buffer half full" back on DOWN | No |

## The serial line (seen in simulation)

From Bob Montgomery's AtariVox Speech Tester (2007), run in `sim/tb_load`
with `+voxlog`:

- **Data:** port 2's UP pin, RIOT port A bit 0. The game leaves the output
  register's bit at 0 and toggles the **direction** bit (`SWACNT` bit 0):
  1 drives the pin low, 0 lets it float high. 8 data bits, no parity,
  1 stop bit, not inverted, least significant bit first.
- **Rate:** one bit every 62 CPU cycles: about 19,250 baud at 1.19 MHz, the
  AtariVox's 19,200.
- **Flow control:** before each byte the driver reads port 2's DOWN pin
  (`SWCHA` bit 1) and sends only while it is high. Unconnected, it reads
  high.
- **Pacing:** the tester sends one byte a frame, in vertical blank.
- With fire pressed, `+voxlog` logs the 29 bytes of the tester's "Go fish"
  phrase exactly as stored in the cartridge.

So the core already delivers the signal; the voice side is what's missing.
`tb_load`'s `+voxlog` samples the line in the middle of each bit. Its
`+fireat` presses joystick bit 4, not this core's fire (the A button, bit
9); use a `+joyscript` such as `800 0200` / `950 0000`.

## The SpeakJet (from Magnevation's User's Manual, 2004)

**Synthesizer.** 8,192 samples a second; PWM out on a 32 kHz carrier.

| Register | What |
|---|---|
| 0 | Envelope frequency (the voice's pitch) |
| 1-5 | Oscillator 1-5 frequency, 0-3999 Hz |
| 6 | Distortion, 0-255: noise on oscillators 4 and 5 |
| 7 | Master volume, 0-127 |
| 8 | Envelope control: bits 1:0 wave (saw, sine, triangle, square); bit 6 envelope on oscillators 1-3; bit 7 half envelope on 4 and 5 |
| 11-15 | Oscillator 1-5 volume, 0-31 (oscillators 1-3 together at most 63) |

Mixer 1 adds oscillators 1-3, mixer 2 oscillators 4 and 5; mixers 3 and 4
apply the envelope; mixer 5 sums and applies the master volume.

**Command set (Table D).**

| Code | Meaning |
|---|---|
| 0-6 | Pauses: 0, 100, 200, 700, 30, 60, 90 ms. 1-3 ramp the volume while the formants change; 4-6 wait for silence first |
| 7, 8 | Next sound fast (half length), slow (one and a half) |
| 14, 15 | Next sound stressed, relaxed |
| 16 | Wait for a start command |
| 20, X | Volume, 0-127 (default 96) |
| 21, X | Speed, 0-127 (default 114) |
| 22, X | Pitch in Hz, 0-255 (default 88) |
| 23, X | Bend, 0-15 (default 5): shifts the oscillator frequencies, deep and hollow to high and metallic |
| 24, X / 25, X | Output port control and value |
| 26, X | Repeat the next code X times |
| 28, X / 29, X | Call / go to an EEPROM phrase |
| 30, X | Delay X × 10 ms |
| 31 | Reset volume, speed, pitch and bend to defaults |
| 128-199 | The 72 allophones, with lengths (Table E) |
| 200-254 | Effects: robot, alarm, beep, "biological" (10 each), DTMF 0-9 * #, sonar ping, pistol shot, "WOW" |
| 255 | End of phrase |

**Serial control mode.** `\` (`$5C`) and the character after it are an
escape, both consumed. `\0` enters a mode that sets synthesizer registers
directly (`8J0N`, `1J500N`, ...); a backslash followed by anything else
leaves it, or keeps the chip out of it (a digit 1-7 is another node; a
non-numeric character ends the mode). Inside it, `R` clears the 64-byte
buffer, `V` says "Ready", `W` resets, `X` leaves, `S` and `T` stop and
restart speaking. A receiver has to recognise all of it, at least so as not
to speak it. Star Raiders (7800, 2026) opens with `\V0 ` and its speech; the
first version of the receiver took `\V` as entering the mode and swallowed
the rest (fixed in 2.2.2).

**Not published:** the "MSA" database, the oscillator settings and
movements behind each allophone and effect. Ours will be written by ear.

## What games send: Stratovox

The Stratovox demo ROM (Champ Games, 2024; its AtariVox output disabled)
still holds the full game's phrase table (bank 5 from `$5D93`, "Game over"
in bank 4 at `$4C8C`):

- **Every phrase starts with the defaults:** `VOL=96 SPEED=114 PITCH=88
  BEND=5`, then allophones with `FAST` and `SLOW`, ending `$FF`. "Help me" is
  `HE EHLL PO MM IY IY`; "Save me" `SE FAST EYIY FAST IY SLOW VV MM IY IY`;
  "Hurry" `HO AXRR IY`; "Game over" steps the pitch between 68 and 86.
- **Before each phrase it sends `\0RX`:** serial control mode, clear the
  buffer, exit. A new phrase cuts off the one playing.
- **`\0RVX`** makes the chip say "Ready" in its own built-in phrase (the `V`
  acknowledge command). That is the "Ready." at the start of the game. In a
  clean recording it lasts 370 ms at a flat 69 Hz.
- One entry plays alarm A5 five times: `RESET REPEAT=5 A5`.

So the receiver must handle serial control mode at least for `R` (clear the
64-byte buffer and stop), `V` (say "Ready") and `X`, and must never speak
the escape bytes.

## What games send: Juno First

The Juno First demo ROM (Champ Games; AtariVox output disabled, speech by
Glenn Saunders) holds the full game's phrases in bank 0 (`$0969`-`$0F8x`).
They are far from plain speech: pitch and speed change on almost every
sound, with sounds repeated to hold and bend them. The title phrase:

    VOL=127 SPEED=90 JH PITCH=170 UW NO PITCH=90 OW, OW x7 with the pitch
    110 to 162, OWWW P0 FF, RR x5 with the pitch 200 down to 100, SO TT

Rendered from these codes at the manual's lengths, our model lasts 1.38 s
against 1.35 s for the real chip in a clean recording of the game's title:
the timing model (lengths from Table E, speed scaling, repeats) holds.
The timbre does not yet: the real voice keeps its energy in a few low
bands, while ours has buzz and hiss well up the spectrum.

## Sound settings measured against the real chip

Phrases whose exact codes are known (from the games' ROMs) and which are
clean in recordings: Juno First's title and "Foolish human", Stratovox's
"Game over". The voice's pitch steps line each sound up; formants are read
where the pitch is low or the sound is held across several pitches (at
high pitch the readings land on the voice's harmonics).

| Sound | Real chip (Hz) | Source | Status |
|---|---|---|---|
| `OW` | 490-500 / 900-908 | "Juno", "over", the alphabet's O | Textbook values matched |
| `AX` | 520 / 1,515 / 2,400 | "Game over" (`AXRR` start) | Textbook values matched |
| `RR` | 435-440 / 1,300-1,336 / 1,730-1,796 | "First" (`RR` x5), "over" (`AXRR` end), the alphabet's R | Set; was a consonantal R |
| `UX` | 605 / 1,335 | "human" (held while the pitch rises) | Set |
| `IH` | ~300 / 1,775 / 2,520 | "Foolish" | Set |
| `MM` | ~280 / 1,150 / 2,200 | "human", "Game" | Set |
| `EY` | 480 / 1,870 / 2,460 | "Game" (`EYIY` start) | Set |
| `EH` | 590 / 1,650 | the alphabet's F, L, M, N, S (identical in all five) | Set |
| `AW` | 610 / 1,030 | the alphabet's R (`AWRR` start) | Set |

**Lengths, by type of sound.** Magnevation's Phrase-A-Lator dictionary
(1,452 words with exact codes) identifies the demo recording's A-Z word
list (activated, basic, correct, ... x-ray). Aligning 20 of those words with
our render of their codes, 118 sounds in all, gives real / manual length:
vowels 1.41, nasals and liquids 1.33, hiss 1.25, glides 1.22, stops 0.85.
With these the 20 words come to 1.03 of the real total (0.83-1.15 per
word; one overall factor gave 0.86-1.45). Two more rules, from
phrases that hold vowels and change speed: a sound that repeats the one
before keeps the manual's length (no transition to make), and speed scales
length by about 2% a step, exp(-0.02 (speed - 114)), so speed 80 is about
twice as long as 114. Fitted to rubyQ's title (speed 80, bend 0) with Juno
First's phrases (90-127). All five reference phrases now come within about
7%: Juno First 1.42 / 1.40 s, "Foolish human" 1.22 / 1.26, Stratovox's "Game
over" 0.98 / 1.05, rubyQ's "Ru-" and "-by" 0.38 / ~0.41 and 0.32 / ~0.30.

The alphabet recording loses everything above about 1.6 kHz, so it gives
only F1 and a low F2: no reading of `IY`, `IH` or other high-F2 vowels.
Its letters start about every 0.3-0.35 s from 6.05 s (A), E at 7.43 s.

Also: the hiss sits about 20 dB under the vowels; F is quiet (22-32 dB under
the vowel in "Gorf" and "Juno First") and mostly below 1.5 kHz; after a
voiced stop the voice fades in over about 100 ms ("Gorf"); the voice is periodic at exactly the commanded pitch, so the
tone oscillators restart every pitch period; phrases run about 1.2 times
the manual's lengths. `tools/atarivox/sjsynth.py` has all of these.

## Measured from recordings of the real chip

A demonstration recording (effects, then the alphabet; no music behind it)
gives these, at the chip's default settings:

- **Voice pitch: 87 Hz,** flat through the whole alphabet: the manual's
  default of 88. So the demo used default settings, and is a fair reference.
- **Output filter:** the long-term spectrum falls steeply above 2 kHz
  (-22 dB at 2.5 kHz, -43 dB near 4 kHz, re 100-500 Hz). One two-pole
  low-pass at about 2,200 Hz on the model's output brings it to within
  3.4 dB, against 13-14 dB without: the low-pass after the SpeakJet's PWM
  output (the manual's Figure 1), which the AtariVox board has.
- **Glides between sounds are straight lines** in the spectrogram: linear
  interpolation of the oscillator frequencies, as the model does.
- **Harmonic density** in 0-2 kHz is between what a sine and a saw voice
  envelope give, nearer the sine.
- **Effects** are stacks of three parallel tones that sweep and step: data
  for the effect tables, once the codes behind each can be identified.

A clip of Juno First saying its title is clean too (the game silences
everything else for that one phrase) but sounds quite different: its
codes (above) hold and bend the vowels with repeats and pitch steps.

## A retail game in simulation: Juno First

The full Juno First (plain bank switching) runs in `tb_load` with the SaveKey
on (`+sk_on`): it finds the AtariVox's EEPROM (150 SCL edges) and, once fire
starts a game (not during the title animation: a press at 3 s was ignored,
6 s worked), speaks:

- **6.03 s:** the title phrase, 75 bytes, exactly the codes in the demo ROM's
  phrase table, one byte a frame (16.7 ms), 1.23 s to send.
- **8.63 s:** "wave one", 16 bytes built in RAM (not stored in the ROM):
  `96 21 118 22 64 23 4 WW EYIY VV 0 WW 14 AW 8 NE` (speed 118, pitch 64,
  bend 4; a stressed "one" with a slow AW).

Stella logs the same bytes in real time: the title phrase and "wave one"
match the simulation byte for byte, the bare 96 included. So the
simulation's serial decoder is right, and the game itself sends 96 without
the 20 in front.

- **Why the 20 is missing:** every stored phrase starts `20 96` (`VOL=96`).
  The game sends each phrase through one routine (bank 0, $F8E4/$F8EC),
  which reads `($99),Y` from the index in $93 and sends until $FF, one byte
  per frame. A phrase that comes in at $F8EC starts from whatever $93
  already holds. The menu code also writes $93, so the built phrases
  probably skip byte 0.
- **It is harmless:** 96 is a reserved code the chip ignores, and the
  volume stays where the last phrase left it.

### Phrases logged with Stella

`tools/atarivox/stella_voxlog.py` runs the logging against Stella 6.7
instead of the simulation: a game minute takes a minute, not hours. It
writes the same log format, takes a screenshot as each phrase starts, and
its docstring has the setup. Four sessions with no skill (hands off, twice; firing without moving;
firing while moving) gave:

| When | Phrase | Codes | Says |
|---|---|---|---|
| Game start | Stored `$0969` | `JH UW NO OW... RR... SO TT` | "Juno First" (title) |
| Each wave's start | Built in RAM | `WW EYIY VV`, then the number | "wave one", "wave two" (`8 TT IHWW`, a slow "two") |
| Game over | One of 8 stored taunts, at random (below) | | |

The four sessions ended on three different taunts. Both hands-off games
ended on "why why why why": with the same input, the game ends on the same
frame.

**How the taunt is picked** (bank 0, $F715): `LDA $81 / AND #7 / TAX`,
then the pointer comes from `$FD00,X` (high bytes) and `$FD08,X` (low
bytes). $81 is an 8-bit LFSR (`ASL`, then `EOR #$CF` on carry, at $F1B1),
seeded with $0F at power-on and stepped as the game runs. So the taunt
depends on exactly when the game ends.

The table, in index order:

| X | Phrase | Sounds (controls left out) | Says |
|---|---|---|---|
| 0 | `$0D10` | `IYUW HE AY VV`, `FF`, `EY` x6 with the pitch 210 down to 95, `EYIY LE ED` | "you have failed" |
| 1 | `$0D4B` | `FF UW LE IH SH`, `HO IYUW MM UX`... `NE` | "foolish human" (the clip measured above) |
| 2 | `$0D7C` | `IYUW SE LE EH SE SE`, `MM AY MM UX LE` | "useless mammal" |
| 3 | `$0DA8` | `WW AY` x4, pitch 180 down to 150 | "why why why why" |
| 4 | `$0E00` | `IY OWRR UX`, `DO UX MM`, `DO UX UX UX MM` | "your doom... doooom" |
| 5 | `$0E39` | `IYUW`, `GO AW TT`, `OW` x5 `NE DO` | "you got owned" |
| 6 | `$0E6B` | `PO UX TH EH TT IH KE`, `AXRR TH TH LE IH IH NGE` | "pathetic earthling" |
| 7 | `$0E9A` | `IYUW LO UW` x7 `ZZ ZZ SO` x3 | "you lose" |

The remaining stored phrases (`$0F00`/`$0F08`, `$0F46`) still need play
that reaches later in the game, which blind input doesn't.

The chip is never starved: in our model the title phrase lasts 1.60 s from
its first sound, longer than its bytes take to arrive, so arrival never
holds up a sound and the timing comparisons above hold. Speaking on
real-time arrival is still how the FPGA version will work.

## Which AtariVox games the core can run

Several AtariVox games are ARM cartridges. Before 2.2.1 the Pocket build
left them out (`NO_ARM_MAPPER`; they got the unsupported-cartridge screen).
From 2.2.1 DARIA runs them (`docs/DARIA_CORE.md`):

| Game (Champ Games demo ROMs) | Scheme | Runs in 2.2.1 |
|---|---|---|
| Juno First | plain bank switching | Yes |
| Stratovox | DPC+ | Yes, with DARIA |
| Wizard of Wor Arcade | CDFJ (detected as CDF) | Yes, with DARIA |
| Gorf Arcade | CDFJ | Yes, with DARIA |
| rubyQ | CDFJ (revision 2) | Yes, with DARIA |

Their phrase tables can still be read from the ROMs (above). With DARIA their
speech can also be logged in whole-core simulation, as Stratovox's is below.
So the AtariVox's usefulness on the Pocket depends on DARIA too, beyond
homebrews on plain bank switching (Juno First, the speech testers).

## The engine

The FPGA was short of logic and long on block RAM and multipliers after
DARIA (2,855 ALMs and 113 M10K free), so the voice is a small processor
built for the job rather than hand-wired logic. It spends block RAM and one
multiplier. One program does both of the SpeakJet's jobs: it reads codes,
and it computes the sound.

| Part | What |
|---|---|
| `avox_rx.sv` | The serial input: 8N1, a bit every 744 clk_sys; serial control mode (`\0` enters; `\` and anything else, or `X`, leaves; R clears and stops, V says "Ready", W resets, the rest is swallowed); the 64-byte buffer, with DOWN low from 32 bytes |
| `avox_engine.sv` | 4 clocks an instruction (3.6 million a second); 64 registers and 192 words of data memory in two block RAM copies; one 27x27 multiplier; a 4,096 x 20-bit data ROM; a 1,024 x 40-bit program ROM |
| `atarivox.sv` | The 16,384 Hz tick (874 clk_sys, 866 on the PAL clock) and the two above |
| `tools/atarivox/voxprog.py` | The program: the synthesizer (every other tick: the voice's envelope oscillator, five tone oscillators, noise on 4 and 5, the envelope and master volume, 8,192 samples a second), the output low-pass (every tick: two poles at 2.2 kHz) and the interpreter (on the other ticks, as a coroutine) |
| `tools/atarivox/vox_rom.py` | The data ROM: half a sine period, the speed, bend and length tables, and 264 segment records, which are `sjsynth.py`'s allophones and effects written out as data |
| `tools/atarivox/voxeng.py` | The instruction set, an assembler, and an emulator that matches the RTL clock for clock |

The interpreter turns each sound into segments (an allophone is 1 to 3:
a vowel 1, a diphthong 2, a stop 3 for closure, burst and aspiration) and
hands them to the synthesizer one at a time. The synthesizer starts each
segment from wherever the last one's glide had got to, as `sjsynth.py`
does. A sound's length is the manual's length x its type's factor x the
speed factor x FAST/SLOW, from the same tables as the model.

**Checks.**

- **The program against the model** (`sjhw.py` against `sjsynth.py`): on
  Juno First's title, "Foolish human" and the test cartridge's eight
  phrases (all 72 allophones, all effects, pitch, speed and bend steps), the
  same lengths to within 10 ms, loudness envelopes matching, and spectral
  frame correlation 0.93-0.97.
- **The RTL against the program** (`sim/atarivox/run.sh`): bytes sent over
  the serial line as a game sends them; every output sample equal, at the
  same clock, to the emulator's. Juno First's title, the allophones, the
  effects, the speed and bend steps and a serial-control sequence (clear
  before each phrase, a phrase cut off, "Ready"): about 357,000 samples,
  no difference, no tick missed.
- **On its own in Quartus** (5CEBA4F23C8): 420 ALMs, 17 M10K, 1 DSP, +55 ns
  of setup slack at clk_sys.
- **In the whole core** (`tb_load +voxlog +voxpcm +sk_on`, DARIA in):
  - **Juno First (retail):** a press of fire at 6 s starts a game, and it
    sends its title phrase and "wave one" as before. The voice plays them
    from the core (6.25-7.81 s, 8.74-9.40 s), and the emulator, given the
    game's own byte timing, gives the same loudness frame by frame.
  - **Stratovox (retail, DPC+, under DARIA):** at 6.37 s, as play starts,
    it sends `\0RVX`; the voice clears and says the built-in "Ready" from
    6.48 s, 0.32 s at 68.8 Hz (the real chip's: 0.37 s at a flat 69 Hz).
- **The full build** (2.2.1 with DARIA and the AtariVox, seed 2): 15,839
  ALMs (86%; DARIA's verified tree without the voice: 15,625 on seed 2),
  212 M10K, 13 DSP. The tightest path is DARIA's guard pair (6 ns). On
  the first AtariVox build (15,880 ALMs) seeds 1, 2 and 3 gave +0.391,
  -0.162 and +0.067 ns there, so the qsf used seed 1. With the voice made
  louder (a few ALMs in the mix) they gave +0.084, +0.193 and -0.262 ns,
  so it uses seed 2 (clk_arm +1.474, clk_sdram +2.345, worst hold +0.082).

**Differences from `sjsynth.py`,** all small:

- The output low-pass runs at 16,384 Hz on the held 8,192 Hz samples, as
  the board's analog filter does on the chip's PWM. This takes off more of
  the images above 4 kHz.
- A repeat (`26, X`) plays the code X times back to back. The model also
  added a 10 ms fade after each one.
- When the buffer and the queued sound run out, the voice fades out over
  10 ms (the model's closing pause), and starts again with the next byte.
- The alarms' step counts are fixed from the default speed.

**Mixing.** A real AtariVox has its own audio jack. Here the voice is mixed
into both channels: x4, x8 or x16 (*AtariVox Voice*: Quiet, Normal, Loud),
limited to +-32,767 on top of the core's output. The voice peaks near
+-2,000 at the chip's full volume, and a TIA channel swings 0-21,844 as a
square wave: the first test build's x1, x2 and x4 left it hard to hear
even on Loud (owner's hardware test), so each level moved up two steps.

## The plan

| Step | What | Status |
|---|---|---|
| 1 | Log what games send (`+voxlog`, or Stella with `stella_voxlog.py`) | Done: the speech tester, Juno First |
| 2 | Prototype the synthesizer and sound tables in Python (`sjsynth.py`), tuned against recordings | Done; tuning goes on |
| 3 | Test cartridge (`sim/vox_test.py`) | Done |
| 4 | The FPGA engine, its program and ROM (above) | Done, in simulation |
| 5 | Into the core (`POCKET_ATARIVOX`), with the menu setting | Done; whole-core simulation with Juno First and Stratovox; on hardware it says its words clearly at every level (second test build) |

## Tools

- `tools/atarivox/sjhw.py OUT.wav CODES...` or `--log tb.log`: the same
  codes through the engine's program in the emulator, as the FPGA plays
  them (16,384 Hz). `--build DIR` writes the engine's ROM images
  (`src/fpga/core/atarivox/vox_*rom.{hex,mif}`); rerun it after changing
  `voxprog.py` or `vox_rom.py`.
- `sim/atarivox/run.sh BYTES` (hex bytes, `gap MS`): the unit test, RTL
  against the emulator. `tb_load +voxpcm` writes the voice inside the whole
  core to `vox.pcm`.

- `tools/atarivox/sjsynth.py OUT.wav CODES...` or `--log tb.log`: renders
  SpeakJet codes to an 8,192 Hz WAV through a model of the manual's
  synthesizer and our tables. Phoneme formants are textbook values for
  English; effects other than DTMF are rough. It is a starting point for
  tuning, not the chip's voice.
- `sim/vox_test.py > vox_test.bin`: a 4 KiB 2600 cartridge. Select steps
  through eight phrases (each with its own background colour), fire speaks
  the current one: Hello world; one to five; Ready; pitch steps; speed and
  bend; all 72 allophones; DTMF; all effects. `--list` prints the codes.
