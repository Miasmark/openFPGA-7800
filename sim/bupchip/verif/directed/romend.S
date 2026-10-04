@ Running off the end of the ROM: the last word (0x3FFC) is an ordinary
@ instruction, and the next fetch, at 0x4000, is outside the ROM window.
@ MiSTer aborts it (bupchip_memory.sv: dec_rom is mem_addr < 16 KiB), so
@ the core must halt (FETCH, docs/BUPCHIP_CORE.md: exact or halt) and not
@ wrap to 0. run.sh runs this on tb_s1.sv only and expects halt code 4 at
@ 0x3FFC after exactly 14 retires:
@   first visit: the BEQ at 0x3FFC is taken, which must not halt;
@   second visit: its condition fails, and the core must halt there.
@ The end marker after a wrap to 0 would only be reached by a core that
@ wrapped (r5 is set before the second visit).
@ SPDX-License-Identifier: MIT
	.syntax unified
	.arm
	.cpu arm7tdmi
	.section .vectors, "ax"
	.global _start
_start:
	b	reset
	.rept 7
	b	.
	.endr
reset:
	cmp	r5, #0				@ not 0 only after a wrap to 0
	bne	wrapped
	mov	r6, #0
	ldr	r0, =0x3ff8
	bx	r0
back:						@ from the taken branch at 0x3FFC
	mov	r6, #1
	mov	r5, #1
	ldr	r0, =0x3ff8
	bx	r0
wrapped:
	ldr	r1, =0xE0009000
	mov	r0, #0xaa
	str	r0, [r1, #0x1c]
	b	.
	.ltorg
	.org	0x3ff8
	cmp	r6, #0
expect_halt:
	beq	back				@ 0x3FFC, the last ROM word
