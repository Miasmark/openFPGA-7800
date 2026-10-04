/* Linker script for the ISA tests: the BupChip memory map (bupchip_memory.sv),
   ROM 16 KiB at 0, RAM 16 KiB at 0x40000000, the signature (8 KiB) first in
   RAM. */
MEMORY
{
	ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
	RAM (rwx) : ORIGIN = 0x40000000, LENGTH = 16K
}
ENTRY(_start)
SECTIONS
{
	.text : { KEEP(*(.vectors)) *(.text*) *(.rodata*) } > ROM
	/* The signature lives at the bottom of RAM so both cores dump the same words. */
	.sig (NOLOAD) : { __sig_start = .; . += 8192; __sig_end = .; } > RAM
	.bss (NOLOAD) : { *(.bss*) *(COMMON) } > RAM
	__stack_top = ORIGIN(RAM) + LENGTH(RAM);
	/DISCARD/ : { *(.data*) *(.ARM.attributes) *(.comment) }
}
