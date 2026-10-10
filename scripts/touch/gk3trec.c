// SPDX-License-Identifier: GPL-2.0
/*
 * gk3trec - record the HX83121A touch pipeline for offline analysis.
 *
 * Polls the driver's debugfs grid dump and reads the touchscreen and pen
 * evdev nodes, and writes everything to one file with CLOCK_MONOTONIC
 * timestamps:
 *
 *   header  "GK3TREC1", u16 rows, u16 cols, u32 flags
 *           flags bit 0: a grid's timestamp is taken after its read, so
 *           the grid belongs to the last touch SYN_REPORT before it
 *   record  u16 type, u16 len, u32 reserved, s64 t_ns, payload[len]
 *     1  frame      grid after the driver's preprocessing (debugfs "frame"),
 *                   rows * cols s16, row-major
 *     2  frame_raw  grid straight after baseline subtraction ("frame_raw"),
 *                   only with -r; read right after the matching frame
 *     3  touch      struct input_event from the touchscreen
 *     4  pen        struct input_event from the pen
 *     5  marker     label text taken from the marker file
 *
 * The debugfs files return the latest grid with no sequence number, so the
 * grid is polled faster than the panel's ~120 Hz and kept only when it
 * differs from the previous read.  Grids whose largest |cell| is below the
 * -q threshold are skipped, so an idle panel costs nothing.
 *
 * The evdev nodes are only read, never grabbed: Android keeps receiving
 * every event.  Each fd is switched to CLOCK_MONOTONIC so event times line
 * up with grid times.
 *
 * Every record goes out in a single write(), so killing the recorder never
 * leaves a torn record.  Writing a label to the marker file (default
 * /data/local/tmp/gk3trec.mark) logs it and deletes the file; the label
 * "stop" ends the recording.
 *
 * Usage: gk3trec [-o out] [-m marker] [-q min_abs] [-t max_seconds] [-r]
 * Runs as root (debugfs, evdev).  Defaults: -o /data/local/tmp/gk3trec.bin,
 * -q 150, -t 1800.  -r also records frame_raw, which hxsim -r needs.
 *
 * Build it static, so it does not depend on the device's libc:
 *   aarch64-linux-gnu-gcc -O2 -static -o gk3trec scripts/touch/gk3trec.c
 * NDK clang works as well, and so does the kernel's nolibc (which defines
 * NOLIBC and brings its own libc part).
 */
#ifndef NOLIBC
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#endif
#include <linux/input.h>

#define ROWS		40
#define COLS		60
#define GRID_BYTES	(ROWS * COLS * 2)

#define DBG_DIR		"/sys/kernel/debug/himax-hx83121a/"
#define TOUCH_NAME	"Himax Capacitive TouchScreen"
#define PEN_NAME	"gk3 M-Pencil"

enum {
	REC_FRAME = 1,
	REC_FRAME_RAW = 2,
	REC_TOUCH = 3,
	REC_PEN = 4,
	REC_MARKER = 5,
};

struct rec_hdr {
	unsigned short type;
	unsigned short len;
	unsigned int reserved;
	long long t_ns;
};

static unsigned char recbuf[sizeof(struct rec_hdr) + GRID_BYTES];
static short grid[ROWS * COLS], prev[ROWS * COLS], raw[ROWS * COLS];
static int out_fd;
static unsigned int n_frames, n_touch, n_pen, n_markers;

static long long mono_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void write_full(int fd, const void *buf, size_t len)
{
	const unsigned char *p = buf;

	while (len) {
		ssize_t n = write(fd, p, len);

		if (n <= 0) {
			printf("gk3trec: write failed (%d), stopping\n", errno);
			exit(1);
		}
		p += n;
		len -= n;
	}
}

static void put_record(int type, long long t_ns, const void *payload, int len)
{
	struct rec_hdr h = { .type = type, .len = len, .t_ns = t_ns };

	memcpy(recbuf, &h, sizeof(h));
	memcpy(recbuf + sizeof(h), payload, len);
	write_full(out_fd, recbuf, sizeof(h) + len);
}

static int read_grid(int fd, short *dst)
{
	if (lseek(fd, 0, SEEK_SET) < 0)
		return -1;
	return read(fd, dst, GRID_BYTES) == GRID_BYTES ? 0 : -1;
}

static int max_abs(const short *g)
{
	int i, m = 0;

	for (i = 0; i < ROWS * COLS; i++) {
		int v = g[i] < 0 ? -g[i] : g[i];

		if (v > m)
			m = v;
	}
	return m;
}

/* Open the evdev node whose name matches, switched to CLOCK_MONOTONIC. */
static int open_evdev(const char *want)
{
	char path[32], name[128];
	int i;

	for (i = 0; i < 32; i++) {
		int fd;

		strcpy(path, "/dev/input/event");
		if (i >= 10) {
			path[16] = '0' + i / 10;
			path[17] = '0' + i % 10;
			path[18] = 0;
		} else {
			path[16] = '0' + i;
			path[17] = 0;
		}
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		memset(name, 0, sizeof(name));
		if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) >= 0 &&
		    !strcmp(name, want)) {
			int clk = CLOCK_MONOTONIC;

			ioctl(fd, EVIOCSCLOCKID, &clk);
			printf("gk3trec: %s = %s\n", want, path);
			return fd;
		}
		close(fd);
	}
	printf("gk3trec: %s not found\n", want);
	return -1;
}

static void drain_evdev(int fd, int type, unsigned int *count)
{
	struct input_event ev[64];
	ssize_t n;
	int i;

	while ((n = read(fd, ev, sizeof(ev))) > 0) {
		for (i = 0; i < n / (int)sizeof(ev[0]); i++) {
			long long t = (long long)ev[i].input_event_sec * 1000000000LL +
				      (long long)ev[i].input_event_usec * 1000LL;

			put_record(type, t, &ev[i], sizeof(ev[i]));
			(*count)++;
		}
	}
}

/* Returns 1 when the marker asked to stop. */
static int check_marker(const char *path)
{
	char label[64];
	ssize_t n;
	int fd;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		return 0;
	n = read(fd, label, sizeof(label) - 1);
	close(fd);
	unlink(path);
	if (n < 0)
		n = 0;
	while (n > 0 && (label[n - 1] == '\n' || label[n - 1] == '\r' ||
			 label[n - 1] == ' '))
		n--;
	label[n] = 0;
	put_record(REC_MARKER, mono_ns(), label, n);
	n_markers++;
	printf("gk3trec: marker \"%s\" (frames %u, touch %u, pen %u)\n",
	       label, n_frames, n_touch, n_pen);
	return !strcmp(label, "stop");
}

int main(int argc, char **argv)
{
	const char *out = "/data/local/tmp/gk3trec.bin";
	const char *marker = "/data/local/tmp/gk3trec.mark";
	int min_abs = 150, max_s = 1800, with_raw = 0;
	int frame_fd, raw_fd = -1, touch_fd, pen_fd;
	struct {
		char magic[8];
		unsigned short rows, cols;
		unsigned int flags;
	} fh = {
		.magic = { 'G', 'K', '3', 'T', 'R', 'E', 'C', '1' },	/* no NUL */
		.rows = ROWS, .cols = COLS, .flags = 1,
	};
	long long t0, last_marker = 0, last_status;
	int i;

#ifndef NOLIBC
	setvbuf(stdout, NULL, _IOLBF, 0);	/* usually a pipe (adb), not a tty */
#endif
	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-o") && i + 1 < argc)
			out = argv[++i];
		else if (!strcmp(argv[i], "-m") && i + 1 < argc)
			marker = argv[++i];
		else if (!strcmp(argv[i], "-q") && i + 1 < argc)
			min_abs = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-t") && i + 1 < argc)
			max_s = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-r"))
			with_raw = 1;
		else {
			printf("usage: gk3trec [-o out] [-m marker] [-q min_abs] [-t max_seconds] [-r]\n");
			return 2;
		}
	}

	frame_fd = open(DBG_DIR "frame", O_RDONLY);
	if (frame_fd < 0) {
		printf("gk3trec: cannot open " DBG_DIR "frame (%d)\n", errno);
		return 1;
	}
	if (with_raw) {
		raw_fd = open(DBG_DIR "frame_raw", O_RDONLY);
		if (raw_fd < 0) {
			printf("gk3trec: cannot open " DBG_DIR "frame_raw (%d)\n", errno);
			return 1;
		}
	}
	touch_fd = open_evdev(TOUCH_NAME);
	pen_fd = open_evdev(PEN_NAME);
	if (touch_fd < 0)
		return 1;

	unlink(marker);
	out_fd = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (out_fd < 0) {
		printf("gk3trec: cannot create %s (%d)\n", out, errno);
		return 1;
	}
	write_full(out_fd, &fh, sizeof(fh));
	printf("gk3trec: recording to %s (q=%d, raw=%d, max %d s)\n",
	       out, min_abs, with_raw, max_s);

	memset(prev, 0, sizeof(prev));
	t0 = mono_ns();
	last_status = t0;
	for (;;) {
		struct pollfd p[2];
		int np = 0, k;
		long long now;

		p[np].fd = touch_fd;
		p[np++].events = POLLIN;
		if (pen_fd >= 0) {
			p[np].fd = pen_fd;
			p[np++].events = POLLIN;
		}
		poll(p, np, 2);

		for (k = 0; k < np; k++)
			if (p[k].revents & POLLIN)
				drain_evdev(p[k].fd, p[k].fd == touch_fd ?
					    REC_TOUCH : REC_PEN,
					    p[k].fd == touch_fd ? &n_touch : &n_pen);

		/*
		 * Take the time after the read: the read waits for the driver's
		 * op_lock, which the frame handler holds through the SPI transfer
		 * and the input report, so the grid it returns belongs to the
		 * last SYN_REPORT before this timestamp.
		 */
		if (read_grid(frame_fd, grid) == 0 &&
		    (now = mono_ns(), memcmp(grid, prev, GRID_BYTES))) {
			memcpy(prev, grid, GRID_BYTES);
			if (max_abs(grid) >= min_abs) {
				put_record(REC_FRAME, now, grid, GRID_BYTES);
				n_frames++;
				if (raw_fd >= 0 && read_grid(raw_fd, raw) == 0)
					put_record(REC_FRAME_RAW, mono_ns(),
						   raw, GRID_BYTES);
			}
		}

		now = mono_ns();
		if (now - last_marker >= 50000000LL) {
			last_marker = now;
			if (check_marker(marker))
				break;
		}
		if (now - last_status >= 10000000000LL) {
			last_status = now;
			printf("gk3trec: %u s, frames %u, touch %u, pen %u\n",
			       (unsigned int)((now - t0) / 1000000000LL),
			       n_frames, n_touch, n_pen);
		}
		if (now - t0 >= (long long)max_s * 1000000000LL) {
			printf("gk3trec: time limit reached\n");
			break;
		}
	}

	printf("gk3trec: done, frames %u, touch %u, pen %u, markers %u\n",
	       n_frames, n_touch, n_pen, n_markers);
	close(out_fd);
	return 0;
}
