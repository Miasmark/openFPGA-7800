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
everything else for that one phrase) but sounds quite different: a voice
of about 150-165 Hz rising through "Juno", "Juno" about 0.9 s long, and
energy only below about 1.5 kHz. The game evidently sets the chip up its
own way for it (pitch, speed, perhaps bend, or synthesizer registers
written directly in serial control mode). It becomes a second reference,
for the controls rather than the default voice, once Juno First's code log
(`tb_load +voxlog`) shows what it sends.

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
