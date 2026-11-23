/* Cortex-M7 idle image: the main loop. Sleeps until an interrupt, and none is
 * enabled, so it sleeps for good. */
int main(void)
{
	for (;;)
		__asm__ volatile("wfi");
	return 0;
}
