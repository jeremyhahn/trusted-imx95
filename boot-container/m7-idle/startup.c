/* Cortex-M7 idle image: vector table, reset handler, default handler.
 *
 * Written for this repository; no vendor code. It does nothing but sit in
 * WFI, so the boot image has a real, linkable Cortex-M7 input until the owner
 * chooses the production firmware (docs/boot-container/boot-image.md).
 *
 * The vector table is the ARMv7-M one: word 0 is the initial main stack
 * pointer, word 1 the reset vector (Thumb bit set by the toolchain), words
 * 2..15 the system exceptions. Interrupt vectors are not listed: no interrupt
 * is enabled here, and the NVIC's are all disabled out of reset.
 */
#include <stdint.h>

extern uint32_t __stack_top; /* top of the TCM region (m7-idle.ld) */
extern uint32_t __bss_start, __bss_end;

extern int main(void);
void Reset_Handler(void);
void Default_Handler(void);

/* Every exception but reset loops forever, so a fault is a stopped core, not a
 * wild jump. */
void Default_Handler(void)
{
	for (;;)
		__asm__ volatile("wfi");
}

#define WEAK_DEFAULT __attribute__((weak, alias("Default_Handler")))
void NMI_Handler(void) WEAK_DEFAULT;
void HardFault_Handler(void) WEAK_DEFAULT;
void MemManage_Handler(void) WEAK_DEFAULT;
void BusFault_Handler(void) WEAK_DEFAULT;
void UsageFault_Handler(void) WEAK_DEFAULT;
void SVC_Handler(void) WEAK_DEFAULT;
void DebugMon_Handler(void) WEAK_DEFAULT;
void PendSV_Handler(void) WEAK_DEFAULT;
void SysTick_Handler(void) WEAK_DEFAULT;

typedef void (*vector_t)(void);

__attribute__((section(".vectors"), used)) const vector_t vector_table[16] = {
	(vector_t)&__stack_top, /*  0 initial MSP */
	Reset_Handler,          /*  1 reset */
	NMI_Handler,            /*  2 */
	HardFault_Handler,      /*  3 */
	MemManage_Handler,      /*  4 */
	BusFault_Handler,       /*  5 */
	UsageFault_Handler,     /*  6 */
	0,                      /*  7 reserved */
	0,                      /*  8 reserved */
	0,                      /*  9 reserved */
	0,                      /* 10 reserved */
	SVC_Handler,            /* 11 */
	DebugMon_Handler,       /* 12 */
	0,                      /* 13 reserved */
	PendSV_Handler,         /* 14 */
	SysTick_Handler,        /* 15 */
};

void Reset_Handler(void)
{
	uint32_t *p;

	/* The hardware loaded MSP from word 0; set it again so a reset by a
	 * debugger or the System Manager into this address behaves the same. */
	__asm__ volatile("msr msp, %0" : : "r"(&__stack_top));

	/* The image is one flat binary at the TCM origin and .data is linked at
	 * its load address, so only .bss needs clearing. */
	for (p = &__bss_start; p < &__bss_end; p++)
		*p = 0;

	(void)main();
	Default_Handler();
}
