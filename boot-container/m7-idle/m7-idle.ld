/* Linker script of the Cortex-M7 idle image.
 *
 * ORIGIN 0x00000000 is the M7's own view of its TCM, the load address of the
 * AHAB container's M7 entry (scripts/ahab/m7-container.yaml,
 * docs/boot-container/m7-load-path-survey.md section 3 and section 5, TCM row;
 * M7_TCM_ADDR). The loader writes it at 0x303C0000 on the system bus.
 *
 * LENGTH is NOT confirmed. The survey (U2) says the ITCM and DTCM sizes and
 * their split are in IMX95RM, which has not been read. 64 KiB is this image's
 * own budget, chosen small on purpose: the whole image, its stack and .bss sit
 * in the one window from 0x0, as one flat binary. Change it when U2 is settled.
 * The stack top is the end of the window.
 */
MEMORY
{
	TCM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

ENTRY(Reset_Handler)

SECTIONS
{
	.vectors : { KEEP(*(.vectors)) } > TCM
	.text    : { *(.text .text.*) *(.rodata .rodata.*) . = ALIGN(4); } > TCM
	.data    : { *(.data .data.*) . = ALIGN(4); } > TCM
	.bss (NOLOAD) : {
		. = ALIGN(4);
		__bss_start = .;
		*(.bss .bss.*) *(COMMON)
		. = ALIGN(4);
		__bss_end = .;
	} > TCM
	__stack_top = ORIGIN(TCM) + LENGTH(TCM);
	/DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment) *(.note*) }
}
