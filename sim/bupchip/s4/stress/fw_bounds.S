@ Asset-window bounds through the whole step 4 path (run_bounds.sh): loaded
@ as the firmware slot's bupchip.bin, it reads an ARSC block of N bytes back
@ through the asset cache with every load the firmware's ISA has, pushing
@ each result into the PCM FIFO (tb_s4.sv logs every push), then loads at
@ offset HOFF with size HSZ (0 byte, 1 halfword, 2 word). With HOFF = N, at
@ asset_size, the core must halt with DATA (5) at `probe`; the store after it
@ must never run.
@   N     block bytes (>= 4)        HOFF  probe offset        HSZ  probe size
@ SPDX-License-Identifier: MIT
	.syntax unified
	.arm
	.cpu arm7tdmi
	.equ	MMIO, 0xE0009000
	.equ	ASSET, 0x02000000
	.section .vectors, "ax"
	.global	_start
_start:
	ldr	r0, =ASSET
	ldr	r1, =MMIO
	ldr	r2, =N
	@ every byte: LDRB
	mov	r3, #0
1:	cmp	r3, r2
	bge	2f
	ldrb	r4, [r0, r3]
	str	r4, [r1, #0x10]
	add	r3, r3, #1
	b	1b
	@ every halfword offset below N - 1, odd ones too: LDRH and LDRSH
2:	mov	r3, #0
	sub	r5, r2, #1
3:	cmp	r3, r5
	bge	4f
	ldrh	r4, [r0, r3]
	str	r4, [r1, #0x10]
	ldrsh	r4, [r0, r3]
	str	r4, [r1, #0x10]
	add	r3, r3, #1
	b	3b
	@ every word offset below N - 3, unaligned ones too: LDR and LDRSB
4:	mov	r3, #0
	sub	r5, r2, #3
5:	cmp	r3, r5
	bge	6f
	ldr	r4, [r0, r3]
	str	r4, [r1, #0x10]
	ldrsb	r4, [r0, r3]
	str	r4, [r1, #0x10]
	add	r3, r3, #1
	b	5b
	@ the last byte, by its own immediate-offset form, then the probe
6:	sub	r3, r2, #1
	ldrb	r4, [r0, r3]
	str	r4, [r1, #0x10]
	ldr	r3, =HOFF
	.global	probe
probe:
	.if HSZ == 0
	ldrb	r4, [r0, r3]
	.elseif HSZ == 1
	ldrh	r4, [r0, r3]
	.else
	ldr	r4, [r0, r3]
	.endif
	str	r4, [r1, #0x10]
	b	.
	.ltorg
