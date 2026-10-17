#!/usr/bin/env python3
"""The AtariVox engine's program (docs/ATARIVOX.md, "The engine"), as
assembly text for voxeng.py.

Two jobs share the engine, both driven by a 16,384 Hz tick:

- **The synthesizer**, every other tick (8,192 samples a second, as the
  SpeakJet): the voice's envelope oscillator, five tone oscillators (4 and 5
  with noise), the envelope and the master volume, as sjsynth.Synth. Every
  tick also runs the output low-pass (two poles at 2.2 kHz) on the latest
  sample.
- **The interpreter**, on the other ticks, as a coroutine (`jal rseq, main`
  yields to the main loop; the next slice resumes it): reads codes from the
  FIFO and turns each sound into segments from the ROM's records
  (vox_rom.py), handing them over one at a time through the pending slot
  (P_*). The synthesizer takes the pending segment when the current one
  ends, starting it from wherever the glide had got to.

MIT licence, as the rest of the Pocket port's own code.
"""
import vox_rom as R

REGS = """
.reg ph0 1
.reg ph1 2
.reg ph2 3
.reg ph3 4
.reg ph4 5
.reg ph5 6
.reg fs1 7
.reg fs2 8
.reg fs3 9
.reg fs4 10
.reg fs5 11
.reg fd1 12
.reg fd2 13
.reg fd3 14
.reg fd4 15
.reg fd5 16
.reg vs1 17
.reg vs2 18
.reg vs3 19
.reg vs4 20
.reg vs5 21
.reg vd1 22
.reg vd2 23
.reg vd3 24
.reg vd4 25
.reg vd5 26
.reg kk 27
.reg gg 28
.reg tt 29
.reg step 30
.reg nleft 31
.reg env 32
.reg dist16 33
.reg pinc 34
.reg master 35
.reg x1 36
.reg x2 37
.reg y1 38
.reg y2 39
.reg xh 40
.reg rseq 41
.reg tog 42
.reg t0 43
.reg t1 44
.reg t2 45
.reg t3 46
.reg t4 47
.reg c65536 48
.reg c32768 49
.reg c4096 50
.reg c2048 51
.reg s0 52
.reg s1 53
.reg s2 54
.reg s3 55
.reg s4 56
.reg s5 57
.reg s6 58
.reg s7 59
.reg s8 60
.reg l1 61
.reg l2 62
"""

# data memory (the register file's block RAM above r63)
MEM = dict(
    P_F=64, P_V=69, P_N=74, P_G=75, P_STEP=76, P_ENV=77, P_DIST16=78, P_PINC=79,
    P_MASTER=80, P_NKEEP=81, P_VALID=82,
    V_SPEED=90, V_PITCH=91, V_BEND=92, V_VOL=93, V_RATE=94, V_STRESS=95, V_LAST=96,
    V_PREVS=97, V_ENV=98, V_DIST16=99, V_PINC=100, V_ROMPTR=101, V_PSAVE=102,
    V_SILENT=103, V_FLAGS=104, V_REPC=105, V_REPCODE=106, V_REPN=107, V_CODE=108,
    V_REPF=109, V_ST=110, V_FADE=111, V_REC=112, V_N=113, V_G=114, V_STEP=115,
)

PAUSE_G = R.samples(10)                      # every pause fades over 10 ms
PAUSE_STEP = 65536 // PAUSE_G


def osc(i, acc):
    """Tone oscillator i (1-5) into accumulator acc: frequency and volume
    glide, noise on 4 and 5, phase, half-wave sine, volume."""
    s = f"""
    mul  t0, fd{i}, tt, 16
    add  t1, fs{i}, t0
"""
    if i >= 4:
        s += f"""
    in   t2, 2
    sub  t2, t2, c32768
    mul  t2, t2, dist16, 12
    add  t1, t1, t2
"""
    s += f"""
    mul  t0, t1, c32768, 0
    add  ph{i}, ph{i}, t0
    sin  t0, ph{i}
    bge  ph{i}, r0, sy_pos{i}
    sub  t0, r0, t0
sy_pos{i}:
    mul  t2, vd{i}, tt, 16
    add  t2, vs{i}, t2
    mul  t0, t0, t2, 12
    add  {acc}, {acc}, t0
"""
    return s


def swap(i):
    return f"""
    mul  t0, fd{i}, tt, 16
    add  t0, fs{i}, t0
    ldm  t1, r0, {MEM['P_F'] + i - 1}
    sub  t1, t1, t0
    mul  fd{i}, t1, t2, 0
    mov  fs{i}, t0
    mul  t0, vd{i}, tt, 16
    add  t0, vs{i}, t0
    ldm  t1, r0, {MEM['P_V'] + i - 1}
    sub  vd{i}, t1, t0
    mov  vs{i}, t0
"""


def record_osc(i):
    s = f"""
    ldr  s4, s2, {6 + i}
    andi s5, s4, 4095
    mul  s5, s5, c65536, 12
"""
    if i < 3:
        s += f"""
    beq  s7, r0, pr_ns{i}
    ldr  s1, s8, {R.STRESS_TAB + i}
    sub  s1, s1, s5
    addi t0, r0, 1024
    mul  s1, s1, t0, 12
    add  s5, s5, s1
pr_ns{i}:
    mul  s5, s5, s6, 12
"""
    s += f"""
    stm  s5, r0, {MEM['P_F'] + i}
    addi t0, r0, 1
    mul  s1, s4, t0, 12
    andi s1, s1, 31
    addi t0, r0, 64
    mul  s1, s1, t0, 0
    stm  s1, r0, {MEM['P_V'] + i}
"""
    return s


def source():
    m = MEM
    a = REGS
    a += f"""
; ------------------------------------------------------------ start
reset:
    addi c4096, r0, 4096
    addi c2048, r0, 2048
    ori  c32768, r0, 32768
    lui  c65536, 1
    addi rseq, r0, seq_init

; ------------------------------------------------------------ main loop
main:
    in   t0, 0
    andi t1, t0, 12
    beq  t1, r0, m_nofl
    ldm  t2, r0, {m['V_FLAGS']}
    or   t2, t2, t1
    stm  t2, r0, {m['V_FLAGS']}
m_nofl:
    andi t1, t0, 1
    beq  t1, r0, main
    ; the output low-pass, every tick, on the latest sample
    add  t0, xh, x1
    add  t0, t0, x1
    add  t0, t0, x2
    ldrs t1, r0, {R.LPF_TAB}
    mul  t0, t0, t1, 16
    ldrs t1, r0, {R.LPF_TAB + 1}
    mul  t2, y1, t1, 16
    sub  t0, t0, t2
    ldrs t1, r0, {R.LPF_TAB + 2}
    mul  t2, y2, t1, 16
    sub  t0, t0, t2
    mov  x2, x1
    mov  x1, xh
    mov  y2, y1
    mov  y1, t0
    out  0, t0
    addi tog, tog, 1
    andi tog, tog, 1
    bne  tog, r0, synth
    ; an interpreter slice; an abort (SCP R) restarts it
    ldm  t0, r0, {m['V_FLAGS']}
    andi t1, t0, 4
    beq  t1, r0, m_seq
    andi t0, t0, 65531
    stm  t0, r0, {m['V_FLAGS']}
    stm  r0, r0, {m['P_VALID']}
    mov  nleft, r0
    addi rseq, r0, seq_abort
m_seq:
    jr   rseq

; ------------------------------------------------------------ synthesizer
synth:
    bne  nleft, r0, sy_go
    ldm  t0, r0, {m['P_VALID']}
    beq  t0, r0, sy_osc             ; nothing pending: hold
    ldm  t2, r0, {m['P_NKEEP']}
"""
    for i in range(1, 6):
        a += swap(i)
    a += f"""
    ldm  nleft, r0, {m['P_N']}
    ldm  gg, r0, {m['P_G']}
    ldm  step, r0, {m['P_STEP']}
    ldm  env, r0, {m['P_ENV']}
    ldm  dist16, r0, {m['P_DIST16']}
    ldm  pinc, r0, {m['P_PINC']}
    ldm  master, r0, {m['P_MASTER']}
    mov  kk, r0
    mov  tt, r0
    stm  r0, r0, {m['P_VALID']}
sy_go:
    addi kk, kk, 1
    blt  kk, gg, sy_tinc
    mov  tt, c65536
    j    sy_tdone
sy_tinc:
    add  tt, tt, step
sy_tdone:
    addi nleft, nleft, -1
sy_osc:
    add  t0, ph0, pinc
    bltu t0, ph0, sy_wrap
    mov  ph0, t0
    j    sy_o1
sy_wrap:
    mov  ph0, t0
    andi t1, env, 64
    beq  t1, r0, sy_o1
    mov  ph1, r0                    ; pitch sync: tone oscillators restart
    mov  ph2, r0
    mov  ph3, r0
sy_o1:
    mov  t3, r0
    mov  t4, r0
"""
    for i in range(1, 6):
        a += osc(i, "t3" if i <= 3 else "t4")
    a += f"""
    ; the envelope, from the voice oscillator's phase
    hi12 t0, ph0
    andi t1, env, 3
    beq  t1, r0, e_saw
    addi t2, r0, 1
    beq  t1, t2, e_sin
    addi t2, r0, 2
    beq  t1, t2, e_tri
    blt  t0, c2048, e_sq1
    mov  t0, r0
    j    e_done
e_sq1:
    mov  t0, c4096
    j    e_done
e_saw:
    sub  t0, c4096, t0
    j    e_done
e_sin:
    lui  t1, 16384
    add  t1, ph0, t1
    sin  t2, t1
    bge  t1, r0, e_s2
    sub  t2, r0, t2
e_s2:
    sub  t2, c4096, t2
    mul  t0, t2, c2048, 12
    j    e_done
e_tri:
    blt  t0, c2048, e_t1
    sub  t0, c4096, t0
e_t1:
    add  t0, t0, t0
e_done:
    andi t1, env, 64
    beq  t1, r0, e_m2
    mul  t3, t3, t0, 12
e_m2:
    andi t1, env, 128
    beq  t1, r0, e_mix
    mul  t1, t0, c2048, 12
    add  t1, t1, c2048
    mul  t4, t4, t1, 12
e_mix:
    add  t0, t3, t4
    mul  xh, t0, master, 7
    j    main

; ------------------------------------------------------------ interpreter
seq_init:
    addi s0, r0, 114
    stm  s0, r0, {m['V_SPEED']}
    addi s0, r0, 88
    stm  s0, r0, {m['V_PITCH']}
    addi s0, r0, 5
    stm  s0, r0, {m['V_BEND']}
    addi s0, r0, 96
    stm  s0, r0, {m['V_VOL']}
    stm  c4096, r0, {m['V_RATE']}
    addi s0, r0, -1
    stm  s0, r0, {m['V_LAST']}
    addi s0, r0, 64
    stm  s0, r0, {m['V_ENV']}
    addi s0, r0, 1
    stm  s0, r0, {m['V_SILENT']}
    j    seq_next
seq_abort:
    stm  r0, r0, {m['V_ROMPTR']}
    stm  r0, r0, {m['V_REPC']}
    stm  c4096, r0, {m['V_RATE']}
    stm  r0, r0, {m['V_STRESS']}
    addi s3, r0, {PAUSE_G}
    jal  l2, do_pause
seq_next:
    jal  l1, getbyte
dispatch:
    addi s1, r0, 7
    blt  s0, s1, d_pause
    beq  s0, s1, d_fast
    addi s1, r0, 8
    beq  s0, s1, d_slow
    addi s1, r0, 14
    beq  s0, s1, d_stress
    addi s1, r0, 15
    beq  s0, s1, d_relax
    addi s1, r0, 128
    bge  s0, s1, d_high
    addi s1, r0, 20
    blt  s0, s1, d_done
    addi s1, r0, 31
    beq  s0, s1, d_reset
    bge  s0, s1, d_done
    addi s1, r0, 27
    beq  s0, s1, d_done
    ; 20-26, 28-30: one argument byte
    stm  s0, r0, {m['V_CODE']}
    jal  l1, getbyte
    ldm  s1, r0, {m['V_CODE']}
    addi s2, r0, 20
    beq  s1, s2, d_vol
    addi s2, r0, 21
    beq  s1, s2, d_speed
    addi s2, r0, 22
    beq  s1, s2, d_pitch
    addi s2, r0, 23
    beq  s1, s2, d_bend
    addi s2, r0, 26
    beq  s1, s2, d_rep
    addi s2, r0, 30
    beq  s1, s2, d_delay
    j    seq_next
d_vol:
    addi s2, r0, 127
    blt  s0, s2, d_v1
    mov  s0, s2
d_v1:
    stm  s0, r0, {m['V_VOL']}
    j    seq_next
d_speed:
    stm  s0, r0, {m['V_SPEED']}
    j    seq_next
d_pitch:
    stm  s0, r0, {m['V_PITCH']}
    j    seq_next
d_bend:
    stm  s0, r0, {m['V_BEND']}
    j    seq_next
d_rep:
    stm  s0, r0, {m['V_REPN']}
    jal  l1, getbyte
    stm  s0, r0, {m['V_REPCODE']}
    ldm  s1, r0, {m['V_REPN']}
    stm  s1, r0, {m['V_REPC']}
    j    seq_next
d_delay:
    li   s2, {round(10 * 8.192 * 4096)}
    mul  s3, s0, s2, 12
    addi s2, r0, {PAUSE_G}
    bge  s3, s2, d_dl1
    mov  s3, s2
d_dl1:
    jal  l2, do_pause
    j    seq_next
d_fast:
    stm  c2048, r0, {m['V_RATE']}
    j    seq_next
d_slow:
    addi s1, r0, 6144
    stm  s1, r0, {m['V_RATE']}
    j    seq_next
d_stress:
    addi s1, r0, 1
    stm  s1, r0, {m['V_STRESS']}
    j    seq_next
d_relax:
    addi s1, r0, 2
    stm  s1, r0, {m['V_STRESS']}
    j    seq_next
d_pause:
    ldr  s3, s0, {R.PAUSE_TAB}
    jal  l2, do_pause
    j    d_done
d_reset:
    addi s0, r0, 114
    stm  s0, r0, {m['V_SPEED']}
    addi s0, r0, 88
    stm  s0, r0, {m['V_PITCH']}
    addi s0, r0, 5
    stm  s0, r0, {m['V_BEND']}
    addi s0, r0, 96
    stm  s0, r0, {m['V_VOL']}
    addi s0, r0, -1
    stm  s0, r0, {m['V_LAST']}
    j    d_done
d_high:
    addi s1, r0, 200
    blt  s0, s1, d_allo
    addi s1, r0, 255
    blt  s0, s1, d_eff
    j    d_done
d_eff:
    addi s1, s0, -200
    ldr  s2, s1, {R.EFF_IDX}
    stm  r0, r0, {m['V_REPF']}
    stm  r0, r0, {m['V_ST']}
    jal  l1, play_records
    j    d_done
d_allo:
    addi s1, s0, -128
    ldr  s2, s1, {R.ALLO_IDX}
    andi s3, s2, 4096
    bne  s3, r0, da_glide
    ldm  s4, r0, {m['V_LAST']}
    addi s5, r0, 0
    bne  s4, s0, da_nrep
    addi s5, r0, 1
da_nrep:
    stm  s5, r0, {m['V_REPF']}
    stm  s0, r0, {m['V_LAST']}
    ldm  s4, r0, {m['V_PREVS']}
    stm  s4, r0, {m['V_FADE']}
    andi s4, s2, 8192
    stm  s4, r0, {m['V_PREVS']}
    ldm  s4, r0, {m['V_STRESS']}
    stm  s4, r0, {m['V_ST']}
    j    da_go
da_glide:
    stm  r0, r0, {m['V_REPF']}
    stm  r0, r0, {m['V_ST']}
da_go:
    andi s2, s2, 4095
    jal  l1, play_records
d_done:
    stm  c4096, r0, {m['V_RATE']}
    stm  r0, r0, {m['V_STRESS']}
    j    seq_next

; getbyte: the next code into s0 (repeat, then the "Ready" phrase, then the
; FIFO). While the FIFO is empty it yields; if the synthesizer has run out
; as well, it first fades to silence.
getbyte:
    ldm  s1, r0, {m['V_REPC']}
    beq  s1, r0, gb_rom
    addi s1, s1, -1
    stm  s1, r0, {m['V_REPC']}
    ldm  s0, r0, {m['V_REPCODE']}
    jr   l1
gb_rom:
    ldm  s1, r0, {m['V_ROMPTR']}
    beq  s1, r0, gb_fifo
    ldr  s0, s1, 0
    addi s1, s1, 1
    stm  s1, r0, {m['V_ROMPTR']}
    addi s2, r0, 256
    bne  s0, s2, gb_ret
    stm  r0, r0, {m['V_ROMPTR']}
    ldm  s2, r0, {m['V_PSAVE']}
    stm  s2, r0, {m['V_PITCH']}
    j    getbyte
gb_fifo:
    ldm  s1, r0, {m['V_FLAGS']}
    andi s2, s1, 8
    beq  s2, r0, gb_f2
    andi s1, s1, 65527
    stm  s1, r0, {m['V_FLAGS']}
    ldm  s2, r0, {m['V_PITCH']}
    stm  s2, r0, {m['V_PSAVE']}
    addi s2, r0, {R.READY_ROM}
    stm  s2, r0, {m['V_ROMPTR']}
    j    getbyte
gb_f2:
    in   s1, 3
    bne  s1, r0, gb_pop
    ldm  s2, r0, {m['V_SILENT']}
    bne  s2, r0, gb_wait
    bne  nleft, r0, gb_wait
    ldm  s2, r0, {m['P_VALID']}
    bne  s2, r0, gb_wait
    addi s3, r0, {PAUSE_G}
    jal  l2, do_pause
gb_wait:
    jal  rseq, main
    j    getbyte
gb_pop:
    in   s0, 1
gb_ret:
    jr   l1

; do_pause: s3 samples of silence, the voice fading out over 10 ms with the
; frequencies held (link l2)
do_pause:
    ldm  s1, r0, {m['P_VALID']}
    beq  s1, r0, dp_free
    jal  rseq, main
    j    do_pause
dp_free:
"""
    for i in range(5):
        a += f"    stm  r0, r0, {m['P_V'] + i}\n"
    a += f"""
    stm  s3, r0, {m['P_N']}
    addi s1, r0, {PAUSE_G}
    stm  s1, r0, {m['P_G']}
    addi s1, r0, {PAUSE_STEP}
    stm  s1, r0, {m['P_STEP']}
    stm  r0, r0, {m['P_NKEEP']}
    ldm  s1, r0, {m['V_ENV']}
    stm  s1, r0, {m['P_ENV']}
    ldm  s1, r0, {m['V_DIST16']}
    stm  s1, r0, {m['P_DIST16']}
    ldm  s1, r0, {m['V_PINC']}
    stm  s1, r0, {m['P_PINC']}
    ldm  s1, r0, {m['V_VOL']}
    stm  s1, r0, {m['P_MASTER']}
    addi s1, r0, 1
    stm  s1, r0, {m['V_SILENT']}
    stm  s1, r0, {m['P_VALID']}
    jr   l2

; play_records: the records from s2 to the one marked last (link l1)
play_records:
pr_wait:
    ldm  s1, r0, {m['P_VALID']}
    beq  s1, r0, pr_free
    jal  rseq, main
    j    pr_wait
pr_free:
    ldr  s3, s2, 0                  ; flags
    ; d = base x LEN x speed x rate
    ldr  s4, s2, 1
    addi s1, r0, 1
    mul  s5, s3, s1, 12
    andi s5, s5, 7
    ldm  s1, r0, {m['V_REPF']}
    beq  s1, r0, pr_len
    mov  s5, r0
pr_len:
    ldr  s5, s5, {R.LEN_TAB}
    mul  s4, s4, s5, 12
    ldm  s5, r0, {m['V_SPEED']}
    andi s5, s5, 255
    ldr  s6, s5, {R.SPEED_TAB}
    mul  s4, s4, s6, 12
    ldm  s5, r0, {m['V_RATE']}
    mul  s4, s4, s5, 12
    ; duration
    ldr  s5, s2, 2
    andi s1, s3, {3 << 7}
    beq  s1, r0, pr_n_abs
    addi s7, r0, {R.DUR_DFRAC}
    beq  s1, s7, pr_n_frac
    mul  s5, s5, s6, 12             ; closure: scaled by speed only
    j    pr_n_abs
pr_n_frac:
    mul  s5, s4, s5, 12
    andi s1, s3, {R.F_MIN8}
    beq  s1, r0, pr_n_abs
    addi s7, r0, {R.samples(8)}
    bge  s5, s7, pr_n_abs
    mov  s5, s7
pr_n_abs:
    addi s7, r0, 1
    bge  s5, s7, pr_n_ok
    mov  s5, s7
pr_n_ok:
    stm  s5, r0, {m['V_N']}
    ; glide
    ldr  s5, s2, 3
    andi s1, s3, {3 << 10}
    beq  s1, r0, pr_g_abs
    addi s7, r0, {R.GL_DFRAC}
    beq  s1, s7, pr_g_frac
    addi s5, r0, {R.samples(30)}
    ldm  s1, r0, {m['V_FADE']}
    beq  s1, r0, pr_g_abs
    addi s5, r0, {R.samples(60)}
    j    pr_g_abs
pr_g_frac:
    mul  s5, s4, s5, 12
pr_g_abs:
    addi s7, r0, 1
    bge  s5, s7, pr_g_ok
    mov  s5, s7
pr_g_ok:
    stm  s5, r0, {m['V_G']}
    ; step = 65536 / g
    bltu c65536, s5, dv_zero
    addi s1, r0, 1
    mov  s4, r0
    bltu s1, s5, dv_l
    sub  s1, s1, s5
    addi s4, s4, 1
dv_l:
    addi s7, r0, 16
dv_loop:
    add  s1, s1, s1
    add  s4, s4, s4
    bltu s1, s5, dv_n
    sub  s1, s1, s5
    addi s4, s4, 1
dv_n:
    addi s7, s7, -1
    bne  s7, r0, dv_loop
    j    dv_done
dv_zero:
    mov  s4, r0
dv_done:
    stm  s4, r0, {m['V_STEP']}
    jal  rseq, main
    ; oscillator targets: stress, then bend, on 1-3
    ldm  s7, r0, {m['V_ST']}
    andi s1, s3, {R.F_STRESS}
    bne  s1, r0, pr_st
    mov  s7, r0
pr_st:
    add  s8, s7, s7
    add  s8, s8, s7
    addi s8, s8, -3
    ldm  s6, r0, {m['V_BEND']}
    andi s6, s6, 15
    ldr  s6, s6, {R.BEND_TAB}
    andi s1, s3, {R.F_BEND}
    bne  s1, r0, pr_b
    mov  s6, c4096
pr_b:
"""
    for i in range(5):
        a += record_osc(i)
    a += f"""
    ; envelope, noise and pitch
    ldr  s4, s2, 4
    andi s5, s4, 255
    stm  s5, r0, {m['V_ENV']}
    addi t0, r0, 256
    mul  s5, s4, t0, 12
    andi s5, s5, 4080
    stm  s5, r0, {m['V_DIST16']}
    andi s1, s3, {3 << 5}
    beq  s1, r0, pr_preg
    addi t0, r0, {R.PITCH_LIT}
    beq  s1, t0, pr_plit
    ldm  s5, r0, {m['V_PINC']}
    j    pr_pdone
pr_plit:
    ldr  s5, s2, 5
    j    pr_pmul
pr_preg:
    ldm  s5, r0, {m['V_PITCH']}
    andi s5, s5, 255
pr_pmul:
    li   t0, 524288
    mul  s5, s5, t0, 0
pr_pdone:
    stm  s5, r0, {m['V_PINC']}
    ; hand it over
    ldm  s1, r0, {m['V_N']}
    stm  s1, r0, {m['P_N']}
    ldm  s1, r0, {m['V_G']}
    stm  s1, r0, {m['P_G']}
    ldm  s1, r0, {m['V_STEP']}
    stm  s1, r0, {m['P_STEP']}
    ldm  s1, r0, {m['V_ENV']}
    stm  s1, r0, {m['P_ENV']}
    ldm  s1, r0, {m['V_DIST16']}
    stm  s1, r0, {m['P_DIST16']}
    stm  s5, r0, {m['P_PINC']}
    ldm  s1, r0, {m['V_VOL']}
    stm  s1, r0, {m['P_MASTER']}
    andi s1, s3, {R.F_KEEPF}
    addi t0, r0, 1
    beq  s1, r0, pr_nk
    mov  t0, r0
pr_nk:
    stm  t0, r0, {m['P_NKEEP']}
    stm  r0, r0, {m['V_SILENT']}
    addi t0, r0, 1
    stm  t0, r0, {m['P_VALID']}
    andi s1, s3, {R.F_LAST}
    bne  s1, r0, pr_end
    addi s2, s2, {R.REC_WORDS}
    jal  rseq, main
    j    play_records
pr_end:
    jr   l1
"""
    return a


if __name__ == "__main__":
    print(source())
