@ Formats 6-11, every size, sign and alignment, from and to every window:
@   F6  LDR [PC, #imm8 << 2] at both alignments (PC reads as the address +
@       4 with bit 1 cleared), at offsets 0 and 1020;
@   F7  LDR, STR, LDRB, STRB [Rb, Ro]; F8 STRH, LDRH, LDRSB, LDRSH [Rb, Ro];
@   F9  LDR, STR [Rb, #imm5 << 2], LDRB, STRB [Rb, #imm5];
@   F10 LDRH, STRH [Rb, #imm5 << 1];
@   F11 LDR, STR [SP, #imm8 << 2], including SP pointing at the peripheral
@       page (the two-clock store reads its data from hw[10:8]).
@ The lane rules are the ARM7TDMI's (docs/DARIA_CORE.md, "What the reference
@ does"): an unaligned LDR rotates the aligned word right by 8 x addr[1:0];
@ an odd LDRH returns the aligned halfword rotated right by 8; an odd LDRSH
@ returns the sign-extended byte (as LDRSB); LDRSB extends each lane's
@ byte; STR and odd STRH store aligned. Sources: RAM (the data area's
@ pattern has bytes of both signs), ROM (a table here), the assets (1 KiB,
@ +await delays these), the peripheral page (IDENT, status, an unused
@ register; pushes to the PCM FIFO). Also: the data register as the base,
@ a load into its own base or offset register, and results used by the
@ next instruction (the bypass; LATE_RF).
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	@ ---- F6 at both alignments
	.balign 4
	ldr	r0, rtab		@ 0 mod 4
	ldr	r1, rtab		@ 2 mod 4
	ldr	r2, rtab + 4
	ldr	r3, rtab + 8
	.balign 4
	ldr	r4, [pc, #1020]		@ imm8 255, 0 mod 4
	ldr	r5, [pc, #1020]		@ 2 mod 4: the same word
	ldr	r6, [pc, #0]		@ imm8 0
	b	1f
	.balign 4
rtab:	.word	0x89abcdef, 0x01234567, 0xfedc8070, 0x7f80ff01
1:
	@ ---- F7/F8 [Rb, Ro] on RAM: every offset 0-7 for each form
	ldr	r7, =DATA + 0x80	@ bytes 0x00 0x02 0x03 0x04 ... (word 32)
	movs	r6, #0
1:	ldr	r0, [r7, r6]
	ldrb	r1, [r7, r6]
	ldrh	r2, [r7, r6]
	ldrsb	r3, [r7, r6]
	ldrsh	r4, [r7, r6]
	SIG	r4
	adds	r6, #1
	cmp	r6, #8
	bne	1b
	ldr	r7, =DATA		@ bytes 0x80 0x81 ... (negative)
	movs	r6, #0
1:	ldr	r0, [r7, r6]
	ldrb	r1, [r7, r6]
	ldrh	r2, [r7, r6]
	ldrsb	r3, [r7, r6]
	ldrsh	r4, [r7, r6]
	adds	r6, #1
	cmp	r6, #8
	bne	1b
	@ stores: every offset 0-7, each size, into a scratch area
	ldr	r7, =DATA + 0x100
	ldr	r5, =0xa1b2c3d4
	movs	r6, #0
1:	str	r5, [r7, r6]
	adds	r5, #0x11
	strb	r5, [r7, r6]
	adds	r5, #0x11
	strh	r5, [r7, r6]
	adds	r6, #1
	cmp	r6, #8
	bne	1b
	ldr	r0, [r7, #0]
	ldr	r1, [r7, #4]
	ldr	r2, [r7, #8]
	POOL

	@ ---- F9/F10 immediates, aligned and unaligned bases
	ldr	r7, =DATA + 0x40
	ldr	r0, [r7, #0]
	ldr	r1, [r7, #4]
	ldr	r2, [r7, #124]
	ldrb	r3, [r7, #0]
	ldrb	r4, [r7, #31]
	ldrh	r5, [r7, #0]
	ldrh	r6, [r7, #62]
	adds	r7, #1			@ odd base
	ldr	r0, [r7, #0]		@ rotated by 8
	ldr	r1, [r7, #8]
	ldrb	r2, [r7, #2]
	ldrh	r3, [r7, #0]		@ odd LDRH
	ldrh	r4, [r7, #2]
	adds	r7, #1			@ base 2 mod 4
	ldr	r0, [r7, #4]		@ rotated by 16
	ldrh	r1, [r7, #2]
	adds	r7, #1			@ base 3 mod 4
	ldr	r0, [r7, #0]		@ rotated by 24
	ldrh	r1, [r7, #0]
	ldr	r7, =DATA + 0x140
	ldr	r5, =0x5ec0de42
	str	r5, [r7, #0]
	str	r5, [r7, #124]
	strb	r5, [r7, #5]
	strb	r5, [r7, #31]
	strh	r5, [r7, #8]
	strh	r5, [r7, #62]
	adds	r7, #3			@ unaligned base: STR and STRH store aligned
	str	r5, [r7, #8]
	strh	r5, [r7, #0]		@ odd: the aligned halfword below
	strh	r5, [r7, #2]
	strb	r5, [r7, #4]
	subs	r7, #3
	ldr	r0, [r7, #0]
	ldr	r1, [r7, #4]
	ldr	r2, [r7, #8]
	ldr	r3, [r7, #12]
	ldr	r4, [r7, #124]
	ldr	r6, [r7, #60]
	POOL

	@ ---- F11: SP-relative, aligned and not
	mov	r12, sp
	ldr	r0, =DATA + 0x80
	mov	sp, r0
	ldr	r1, [sp, #0]
	ldr	r2, [sp, #4]
	ldr	r3, [sp, #252]
	str	r1, [sp, #256]
	str	r2, [sp, #1020]		@ DATA + 0x47C
	ldr	r4, [sp, #1020]
	adds	r0, #2
	mov	sp, r0			@ SP 2 mod 4
	ldr	r5, [sp, #8]		@ rotated by 16
	str	r5, [sp, #260]		@ aligned
	ldr	r6, [sp, #256]
	mov	sp, r12

	@ ---- the data register as the base; a load into its base or offset
	ldr	r0, =DATA + 0x200
	str	r0, [r0, #0]		@ stores the base itself
	strh	r0, [r0, #4]
	strb	r0, [r0, #7]
	movs	r1, #8
	str	r0, [r0, r1]
	ldr	r0, [r0, #0]		@ load into the base: the loaded value
	ldr	r0, [r0, #8]
	movs	r1, #4
	ldrh	r1, [r0, r1]		@ load into the offset register
	ldr	r2, =DATA + 0x200
	ldrb	r2, [r2, #7]
	@ results used at once (the bypass)
	ldr	r3, =DATA
	ldr	r4, [r3, #4]
	adds	r4, #1
	str	r4, [r3, #0x60]
	ldr	r5, [r3, #0x60]		@ the store just made
	movs	r6, #0x60
	ldr	r6, [r3, r6]		@ an offset just written; the load into it
	str	r6, [r3, #0x64]
	POOL

	@ ---- ROM: a table in the code
	ldr	r7, =rtab
	movs	r6, #0
1:	ldr	r0, [r7, r6]
	ldrb	r1, [r7, r6]
	ldrh	r2, [r7, r6]
	ldrsb	r3, [r7, r6]
	ldrsh	r4, [r7, r6]
	adds	r6, #1
	cmp	r6, #8
	bne	1b
	ldr	r0, [r7, #12]
	ldrb	r1, [r7, #13]
	ldrh	r2, [r7, #14]
	adds	r7, #1
	ldr	r3, [r7, #4]
	ldrh	r4, [r7, #0]

	@ ---- assets: every size and offset
	ldr	r7, =ASSET
	movs	r6, #0
1:	ldr	r0, [r7, r6]
	ldrb	r1, [r7, r6]
	ldrh	r2, [r7, r6]
	ldrsb	r3, [r7, r6]
	ldrsh	r4, [r7, r6]
	adds	r6, #1
	cmp	r6, #8
	bne	1b
	ldr	r0, [r7, #124]
	ldrb	r1, [r7, #31]
	ldrh	r2, [r7, #62]
	ldr	r5, =0x3fc
	ldr	r3, [r7, r5]		@ the last asset word
	adds	r7, #3
	ldr	r4, [r7, #0]
	ldrh	r5, [r7, #0]
	POOL

	@ ---- the peripheral page
	ldr	r5, =MMIO
	ldr	r0, [r5, #0]		@ IDENT
	ldrb	r1, [r5, #1]
	ldrh	r2, [r5, #2]
	ldr	r3, [r5, #0x14]
	ldr	r4, [r5, #0x20]		@ unused: reads 0
	movs	r6, #0x14
	ldr	r0, [r5, r6]
	ldrsb	r1, [r5, r6]
	ldrsh	r2, [r5, r6]
	ldrb	r3, [r5, r6]
	ldrh	r4, [r5, r6]
	ldr	r1, =0x01234567
	str	r1, [r5, #0x10]		@ push
	strb	r1, [r5, #0x10]		@ push, the byte on every lane
	strh	r1, [r5, #0x10]		@ push, the halfword on both
	movs	r6, #0x10
	str	r1, [r5, r6]		@ register offset (two clocks)
	strh	r1, [r5, r6]
	strb	r1, [r5, r6]
	mov	r12, sp
	mov	sp, r5
	ldr	r0, [sp, #0]		@ F11 load from the page: IDENT
	ldr	r2, =0x76543210
	str	r2, [sp, #0x10]		@ F11 two-clock store: data from hw[10:8] (r2)
	ldr	r7, =0x0badcafe
	str	r7, [sp, #0x10]
	mov	sp, r12
	movs	r0, #3
	str	r0, [r5, #0x0c]		@ clear the command FIFO
	END
