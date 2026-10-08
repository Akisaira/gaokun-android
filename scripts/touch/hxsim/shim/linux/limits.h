/* Host stand-in for <linux/limits.h>. */
#ifndef SHIM_LINUX_LIMITS_H
#define SHIM_LINUX_LIMITS_H
#include <limits.h>

#define U8_MAX		((u8)~0U)
#define U16_MAX		((u16)~0U)
#define S16_MAX		((s16)(U16_MAX >> 1))
#define S16_MIN		((s16)(-S16_MAX - 1))
#endif
