# AtariVox: notes and plan

Status: research and prototype. Nothing is in the core yet. The SaveKey
half of the AtariVox (the 24LC256 EEPROM) has been in the core since 2.0.8;
this is about the voice.

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

**Serial control mode.** `\` (`$5C`) and a node digit enter a mode that sets
synthesizer registers directly (`8J0N`, `1J500N`, ...), until `X` or another
escape. A receiver has to recognise it, at least so as not to speak it.

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

The alphabet recording loses everything above about 1.6 kHz, so it gives
only F1 and a low F2: no reading of `IY`, `IH` or other high-F2 vowels.
Its letters start about every 0.3-0.35 s from 6.05 s (A), E at 7.43 s.

Also: the hiss sits about 20 dB under the vowels, and F is almost silent
("Juno First"); the voice is periodic at exactly the commanded pitch, so the
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

## The plan

| Step | What | FPGA cost |
|---|---|---|
| 1 | Log what games send (`+voxlog`): done for the speech tester; Juno First next | None |
| 2 | Prototype the synthesizer and our sound tables in Python (`tools/atarivox/sjsynth.py`), tuned by ear against videos | None |
| 3 | Test cartridge of our own (`sim/vox_test.py`) | None |
| 4 | FPGA: serial receiver, 64-byte buffer and DOWN pin; code interpreter; the synthesizer, time-shared; tables in block RAM; behind its own macro and a menu setting | Estimated 600-1,000 ALMs, 4-7 M10K, 1-3 DSP |

Step 4 waits for DARIA, so it can be sized against DARIA's real figures
(estimated 2,700-3,100 ALMs and 113 memory blocks free).

## Tools

- `tools/atarivox/sjsynth.py OUT.wav CODES...` or `--log tb.log`: renders
  SpeakJet codes to an 8,192 Hz WAV through a model of the manual's
  synthesizer and our tables. Phoneme formants are textbook values for
  English; effects other than DTMF are rough. It is a starting point for
  tuning, not the chip's voice.
- `sim/vox_test.py > vox_test.bin`: a 4 KiB 2600 cartridge. Select steps
  through eight phrases (each with its own background colour), fire speaks
  the current one: Hello world; one to five; Ready; pitch steps; speed and
  bend; all 72 allophones; DTMF; all effects. `--list` prints the codes.
