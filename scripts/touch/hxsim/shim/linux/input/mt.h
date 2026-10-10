/* Host stand-in for <linux/input/mt.h>: only struct input_mt_pos. */
#ifndef SHIM_LINUX_INPUT_MT_H
#define SHIM_LINUX_INPUT_MT_H
#include <linux/types.h>

struct input_mt_pos {
	s16 x, y;
};
#endif
