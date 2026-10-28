/* Host stand-in for <linux/math64.h>: the helpers hx-algo.c uses. */
#ifndef SHIM_LINUX_MATH64_H
#define SHIM_LINUX_MATH64_H
#include <linux/types.h>

static inline u64 div64_u64(u64 dividend, u64 divisor)
{
	return dividend / divisor;
}
#endif
