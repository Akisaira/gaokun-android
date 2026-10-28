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
#define READ_ONCE(x)		(*(const volatile typeof(x) *)&(x))
#define DIV_ROUND_CLOSEST(x, d)	((((x) > 0) == ((d) > 0)) ? (((x) + (d) / 2) / (d)) : (((x) - (d) / 2) / (d)))
#define swap(a, b)		do { typeof(a) __t = (a); (a) = (b); (b) = __t; } while (0)

#define pr_info(...)		fprintf(stderr, __VA_ARGS__)
#define pr_warn(...)		fprintf(stderr, __VA_ARGS__)

static inline u32 int_sqrt64(u64 x)
{
	u64 r = 0, b = (u64)1 << 62;

	while (b > x)
		b >>= 2;
	for (; b; b >>= 2) {
		if (x >= r + b) {
			x -= r + b;
			r = (r >> 1) + b;
		} else {
			r >>= 1;
		}
	}
	return (u32)r;
}

/* The host is little-endian, like the panel's SPI frames. */
static inline u16 le16_to_cpup(const u16 *p)
{
	return *p;
}
#endif
