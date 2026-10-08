/*
 * Host stand-in for <linux/kernel.h>: just the helpers hx-algo.c uses, so the
 * driver's algorithm compiles unchanged as a user-space program.
 */
#ifndef SHIM_LINUX_KERNEL_H
#define SHIM_LINUX_KERNEL_H
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <linux/types.h>

#define __maybe_unused		__attribute__((unused))
#define IS_ENABLED(opt)		0	/* no Kconfig on the host */
#define SZ_64K			0x10000
#define ARRAY_SIZE(a)		(sizeof(a) / sizeof((a)[0]))

#define min(a, b)		((a) < (b) ? (a) : (b))
#define max(a, b)		((a) > (b) ? (a) : (b))
#define min_t(t, a, b)		((t)(a) < (t)(b) ? (t)(a) : (t)(b))
#define max_t(t, a, b)		((t)(a) > (t)(b) ? (t)(a) : (t)(b))
#define clamp_t(t, v, lo, hi)	min_t(t, max_t(t, v, lo), hi)
#define clamp_val(v, lo, hi)	clamp_t(typeof(v), v, lo, hi)
#define swap(a, b)		do { typeof(a) __t = (a); (a) = (b); (b) = __t; } while (0)

#define pr_info(...)		fprintf(stderr, __VA_ARGS__)
#define pr_warn(...)		fprintf(stderr, __VA_ARGS__)

/* The host is little-endian, like the panel's SPI frames. */
static inline u16 le16_to_cpup(const u16 *p)
{
	return *p;
}
#endif
