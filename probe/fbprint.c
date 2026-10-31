/* fbprint: put words on a framebuffer that has nobody else to draw them.
 *
 * The LineageOS 18 kernel for land (4.19.325-Mi8937v2) is built with
 * CONFIG_FB_MSM_MDSS=y but without CONFIG_VT and CONFIG_FRAMEBUFFER_CONSOLE, so
 * console=tty0 fbcon=map:1 is a request for something that does not exist: the
 * panel is live, the framebuffer is registered, and there is no text layer at all.
 * Writing pixels into the framebuffer directly is the way to get a verdict out of
 * a boot when the phone has no keyboard, no serial cable and no adb, which is the
 * state a boot probe most needs to report from.
 *
 * The frame is composed in memory and written in one pwrite at offset 0.  fb_write
 * starts at the top of the visible buffer as long as nothing has panned it, and
 * with no console driver and no Android surface flinger there is nothing to pan it.
 *
 * usage:
 *   fbprint [-d /dev/fb0] [--scale N] [--fg r,g,b] [--bg r,g,b] [--row N]
 *           [--clear] [text...]                 one line per argument
 *   fbprint --raw out.bin --xres 720 --yres 1280 --bpp 32 --pitch 2880 ...
 *
 * --raw exists so the drawing path can be tested on a PC: it writes the composed
 * frame to a plain file, which is then viewable as an image.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#if defined(__linux__) || defined(__ANDROID__)
#include <sys/ioctl.h>
#endif

#if defined(__linux__) || defined(__ANDROID__)
#include <linux/fb.h>
#define HAVE_FB_H 1
#else
/* Only the fields the program reads, laid out the way the kernel ABI has laid
 * them out since forever.  On a host build they are never filled by an ioctl. */
typedef unsigned int __u32;
typedef int __s32;
struct fb_bitfield {
	__u32 offset;
	__u32 length;
	__u32 msb_right;
};
struct fb_var_screeninfo {
	__u32 xres, yres;
	__u32 left, right, upper, lower;
	__u32 hsync_len, vsync_len, sync, vmode;
	__u32 rotate;
	struct fb_bitfield red, green, blue, transp;
	__u32 bpp;
	__u32 colormap;
	__u32 pixclock;
	__u32 hscroll;
};
struct fb_fix_screeninfo {
	char id[16];
	unsigned long smem_start;
	__u32 smem_len, type, visual;
	__u32 xpanstep, ypanstep, ywrapstep;
	__u32 line_length;
	unsigned long mmio_start;
	__u32 accel;
};
#define FBIOGET_VSCREENINFO 0x4600
#define FBIOGET_FSCREENINFO 0x4602
#endif

#include "font8x16.h"

#ifdef _O_BINARY
/* The host test writes a raw frame to a file, and the Windows default file mode
 * turns every 0x0a byte of that frame into two. */
#define RAW_OPEN_FLAGS (O_RDWR | O_CREAT | O_TRUNC | O_BINARY)
#else
#define RAW_OPEN_FLAGS (O_RDWR | O_CREAT | O_TRUNC)
#endif

#ifndef __linux__
/* A host build only ever takes the --raw path, and Windows has no pwrite. */
static ssize_t pwrite(int fd, const void *buf, size_t n, off_t off)
{
	if (lseek(fd, off, SEEK_SET) < 0)
		return -1;
	return write(fd, buf, n);
}
#endif

#define MAXLINES 64

static unsigned int parse_color(const char *s, unsigned int fallback)
{
	unsigned int r = 0, g = 0, b = 0, n = 0;
	if (s == NULL)
		return fallback;
	n = sscanf(s, "%u,%u,%u", &r, &g, &b);
	if (n != 3) {
		unsigned int v;
		if (sscanf(s, "%x", &v) == 1) {
			r = (v >> 16) & 0xff;
			g = (v >> 8) & 0xff;
			b = v & 0xff;
		} else {
			return fallback;
		}
	}
	return (r << 16) | (g << 8) | b;
}

static void put_pixel(unsigned char *frame, unsigned int pitch, unsigned int bpp,
                      unsigned int x, unsigned int y, unsigned int rgb,
                      struct fb_bitfield *red, struct fb_bitfield *green,
                      struct fb_bitfield *blue)
{
	unsigned int v = 0;
	unsigned char *p;

	if (bpp != 32 && bpp != 24 && bpp != 16)
		return;
	if (bpp == 32) {
		unsigned int r = (rgb >> 16) & 0xff;
		unsigned int g = (rgb >> 8) & 0xff;
		unsigned int b = rgb & 0xff;
		v = ((r >> (8 - (red->length ? red->length : 8))) << red->offset) |
		    ((g >> (8 - (green->length ? green->length : 8))) << green->offset) |
		    ((b >> (8 - (blue->length ? blue->length : 8))) << blue->offset);
		p = frame + (size_t)y * pitch + (size_t)x * 4;
		p[0] = v & 0xff;
		p[1] = (v >> 8) & 0xff;
		p[2] = (v >> 16) & 0xff;
		p[3] = (v >> 24) & 0xff;
	} else if (bpp == 16) {
		unsigned int r = ((rgb >> 16) & 0xff) >> (8 - red->length);
		unsigned int g = ((rgb >> 8) & 0xff) >> (8 - green->length);
		unsigned int b = (rgb & 0xff) >> (8 - blue->length);
		v = (r << red->offset) | (g << green->offset) | (b << blue->offset);
		p = frame + (size_t)y * pitch + (size_t)x * 2;
		p[0] = v & 0xff;
		p[1] = (v >> 8) & 0xff;
	} else {
		p = frame + (size_t)y * pitch + (size_t)x * 3;
		p[0] = (rgb >> 16) & 0xff;
		p[1] = (rgb >> 8) & 0xff;
		p[2] = rgb & 0xff;
	}
}

static void draw_char(unsigned char *frame, unsigned int xres, unsigned int yres,
                      unsigned int pitch, unsigned int bpp, unsigned int x,
                      unsigned int y, char c, unsigned int rgb, unsigned int scale,
                      struct fb_bitfield *red, struct fb_bitfield *green,
                      struct fb_bitfield *blue)
{
	const unsigned char *glyph;
	unsigned int row, col, sy, sx;

	if (c < 32 || c > 126)
		c = '?';
	glyph = font8x16[c - 32];
	for (row = 0; row < FONT_H; row++) {
		for (col = 0; col < FONT_W; col++) {
			if (!(glyph[row] & (0x80 >> col)))
				continue;
			for (sy = 0; sy < scale; sy++) {
				unsigned int py = y + row * scale + sy;
				if (py >= yres)
					continue;
				for (sx = 0; sx < scale; sx++) {
					unsigned int px = x + col * scale + sx;
					if (px < xres)
						put_pixel(frame, pitch, bpp, px, py, rgb,
							  red, green, blue);
				}
			}
		}
	}
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/fb0";
	const char *raw = NULL;
	char *lines[MAXLINES];
	int nlines = 0;
	unsigned int scale = 3;
	unsigned int startrow = 0;
	unsigned int fg = 0x7fffd4, bg = 0x060a12;
	int clear = 1;
	int i, fd, rc = 0;
	struct fb_var_screeninfo var;
	struct fb_fix_screeninfo fix;
	unsigned int xres = 720, yres = 1280, bpp = 32, pitch = 2880;
	unsigned char *frame;
	size_t framesz;

	memset(&var, 0, sizeof(var));
	memset(&fix, 0, sizeof(fix));

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "-d") && i + 1 < argc)
			dev = argv[++i];
		else if (!strcmp(a, "--raw") && i + 1 < argc)
			raw = argv[++i];
		else if (!strcmp(a, "--scale") && i + 1 < argc)
			scale = (unsigned int)atoi(argv[++i]);
		else if (!strcmp(a, "--row") && i + 1 < argc)
			startrow = (unsigned int)atoi(argv[++i]);
		else if (!strcmp(a, "--fg") && i + 1 < argc)
			fg = parse_color(argv[++i], fg);
		else if (!strcmp(a, "--bg") && i + 1 < argc)
			bg = parse_color(argv[++i], bg);
		else if (!strcmp(a, "--xres") && i + 1 < argc)
			xres = (unsigned int)atoi(argv[++i]);
		else if (!strcmp(a, "--yres") && i + 1 < argc)
			yres = (unsigned int)atoi(argv[++i]);
		else if (!strcmp(a, "--bpp") && i + 1 < argc)
			bpp = (unsigned int)atoi(argv[++i]);
		else if (!strcmp(a, "--pitch") && i + 1 < argc)
			pitch = (unsigned int)atoi(argv[++i]);
		else if (!strcmp(a, "--noclear"))
			clear = 0;
		else if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
			fprintf(stderr,
				"usage: fbprint [-d FB|--raw FILE] [--scale N] [--row N]"
				" [--fg r,g,b] [--bg r,g,b] [text...]\n");
			return 2;
		} else if (nlines < MAXLINES)
			lines[nlines++] = argv[i];
	}
	if (scale < 1)
		scale = 1;
	if (nlines == 0) {
		/* Read from stdin when no text was given, so a probe can pipe a whole
		 * status block through one call. */
		static char buf[4096];
		ssize_t n = read(0, buf, sizeof(buf) - 1);
		if (n > 0) {
			char *s, *save = NULL;
			buf[n] = '\0';
			for (s = strtok_r(buf, "\n", &save); s && nlines < MAXLINES;
			     s = strtok_r(NULL, "\n", &save))
				lines[nlines++] = s;
		}
	}

	if (raw != NULL) {
		fd = open(raw, RAW_OPEN_FLAGS, 0644);
		if (fd < 0) {
			perror(raw);
			return 1;
		}
	} else {
#ifndef HAVE_FB_H
		fprintf(stderr, "no linux/fb.h on this build, use --raw\n");
		return 1;
	}
	(void)dev;
#else
		fd = open(dev, O_RDWR);
		if (fd < 0) {
			perror(dev);
			return 1;
		}
		if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0 ||
		    ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0) {
			perror("ioctl fb");
			close(fd);
			return 1;
		}
		xres = var.xres;
		yres = var.yres;
		bpp = var.bits_per_pixel;
		pitch = fix.line_length;
	}
#endif
	if (fd < 0)
		return 1;

	if (var.red.length == 0) {
		/* Either the --raw path or a driver that left the bitfields empty:
		 * the common phone layout, XRGB8888 with red at bit 16. */
		var.red.offset = 16;
		var.red.length = 8;
		var.green.offset = 8;
		var.green.length = 8;
		var.blue.offset = 0;
		var.blue.length = 8;
	}

	framesz = (size_t) pitch * yres;
	frame = calloc(1, framesz);
	if (frame == NULL) {
		fprintf(stderr, "no memory for a %zu byte frame\n", framesz);
		close(fd);
		return 1;
	}

	if (clear) {
		unsigned int x, y;
		for (y = 0; y < yres; y++)
			for (x = 0; x < xres; x++)
				put_pixel(frame, pitch, bpp, x, y, bg, &var.red, &var.green,
					  &var.blue);
	}

	{
		unsigned int cpl = xres / (FONT_W * scale);
		unsigned int row = startrow, col = 0, l;
		if (cpl == 0)
			cpl = 1;
		for (l = 0; l < (unsigned int)nlines; l++) {
			const char *s;
			for (s = lines[l]; *s; s++) {
				unsigned int x, y;
				if (*s == '\t')
					continue;
				if (col >= cpl) {
					col = 0;
					row++;
				}
				x = col * FONT_W * scale;
				y = row * FONT_H * scale;
				if (y + FONT_H * scale > yres)
					break;
				draw_char(frame, xres, yres, pitch, bpp, x, y, *s, fg, scale,
					  &var.red, &var.green, &var.blue);
				col++;
			}
			col = 0;
			row++;
		}
	}

	if (pwrite(fd, frame, framesz, 0) != (ssize_t) framesz) {
		perror(raw ? "write raw" : "write fb");
		rc = 1;
	}
	if (raw) {
		/* The caller may want to look at the result as an image. */
		fprintf(stderr, "raw %ux%u bpp %u pitch %u, %zu bytes written\n", xres,
			yres, bpp, pitch, framesz);
	}
	free(frame);
	close(fd);
	return rc;
}
