/* Erasure and locking of credential storage (the key-store nonce).
 * PROVISIONAL. Header only, no vendor header. handbook security-review.md §6:
 * a credential is held in locked memory and erased with an erase the
 * compiler cannot remove.
 */
#ifndef ELE_SECURE_H
#define ELE_SECURE_H

#include <stddef.h>

/* Zero n bytes through a volatile pointer, so the stores are not elided. */
static inline void ele_secure_zero(void *p, size_t n)
{
	volatile unsigned char *v = p;

	while (n--)
		*v++ = 0;
	__asm__ __volatile__("" : : "r"(p) : "memory");
}

#endif
