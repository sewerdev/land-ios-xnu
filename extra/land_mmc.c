/*
 * land (Redmi 3S, MSM8937): read-only BSD block device over the SDHCI eMMC.
 *
 * The actual byte mover is pexpert/arm/land_sdhci.c, whose PIO recipe was
 * measured on the phone (CMD17, XFERMODE=0x10, block count in the ARG2 alias,
 * Buffer Read Ready drained word by word).  Because that path is programmed
 * I/O, transfers land straight in the caller's kernel virtual memory: no
 * physical address, no bounce buffer, no cache maintenance.
 *
 * The window this device exposes is the root partition, taken from the ADT's
 * /emmc node (land,root-lba, land,root-bytes, land,root-fs), so the on-disk
 * filesystem starts at block 0 here.  Mount it with rd=landmmc0 and let the
 * boot arg landmmc= choose the partition name to look for in /chosen when an
 * image is laid out by GPT instead.
 *
 * Writes are refused: this kernel has no partition-aware write path yet, and
 * the shim journal in dip is the only thing we deliberately overwrite.
 */
#if defined(ARM64_BOARD_CONFIG_SWEET)
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/buf.h>
#include <sys/conf.h>
#include <sys/disk.h>
#include <sys/errno.h>
#include <sys/proc.h>
#include <sys/uio.h>
#include <miscfs/devfs/devfs.h>
#include <kern/locks.h>
#include <machine/machine_routines.h>
#include <pexpert/pexpert.h>
#include <pexpert/device_tree.h>
#include <libkern/libkern.h>

/* pexpert/arm/land_sdhci.c */
extern int land_emmc_ready(void);
extern int land_emmc_read(uint64_t lba, void *buf, unsigned int nblk);
extern uint64_t land_emmc_root_lba(void);
extern uint64_t land_emmc_root_bytes(void);

#define MMC_BLOCK       512u            /* the SDHCI block size we initialise */
#define MMC_MAX_CHUNK   64u             /* blocks per command burst */
#define MMC_BOUNCE_SIZE (MMC_MAX_CHUNK * MMC_BLOCK)

/* Programmed I/O writes whole 32-bit words, so transfers go through an
 * aligned buffer and are copied out rather than aimed at a possibly
 * unaligned page from physio(). */
static uint8_t lm_bounce[MMC_BOUNCE_SIZE] __attribute__((aligned(64)));

static struct {
	uint64_t first_lba;               /* partition start, in 512-byte blocks */
	uint64_t nblocks;                 /* partition size, in 512-byte blocks */
	uint32_t secsize;
	int bmajor, cmajor;
	dev_t bdev;
	bool ready;
	char fs[16];
} lm;

static LCK_GRP_DECLARE(land_mmc_grp, "land_mmc");
static LCK_MTX_DECLARE(land_mmc_lock, &land_mmc_grp);

static int
land_mmc_open(dev_t dev, __unused int flags, __unused int devtype, __unused struct proc *p)
{
	if (!lm.ready || minor(dev) != 0) {
		return ENXIO;
	}
	return 0;
}

static int
land_mmc_close(__unused dev_t dev, __unused int flags, __unused int devtype,
    __unused struct proc *p)
{
	return 0;
}

static void
land_mmc_strategy(buf_t bp)
{
	int error = 0;
	caddr_t vaddr = NULL;
	uint64_t first = (uint64_t)buf_blkno(bp);
	uint32_t count = buf_count(bp) / lm.secsize;
	uint32_t done;

	buf_setresid(bp, buf_count(bp));
	if (!(buf_flags(bp) & B_READ)) {
		buf_seterror(bp, EROFS);
		buf_biodone(bp);
		return;
	}
	if ((buf_count(bp) % lm.secsize) != 0) {
		buf_seterror(bp, EINVAL);
		buf_biodone(bp);
		return;
	}
	if (first > lm.nblocks || count > lm.nblocks - first) {
		buf_seterror(bp, EINVAL);
		buf_biodone(bp);
		return;
	}
	if (count == 0) {
		buf_biodone(bp);
		return;
	}
	if (buf_map(bp, &vaddr)) {
		buf_seterror(bp, EIO);
		buf_biodone(bp);
		return;
	}

	lck_mtx_lock(&land_mmc_lock);
	for (done = 0; done < count; ) {
		uint32_t chunk = count - done;
		uint32_t bytes;

		if (chunk > MMC_MAX_CHUNK) {
			chunk = MMC_MAX_CHUNK;
		}
		bytes = chunk * lm.secsize;
		error = land_emmc_read(lm.first_lba + first + done, lm_bounce, chunk);
		if (error) {
			break;
		}
		memcpy(vaddr + (done * lm.secsize), lm_bounce, bytes);
		done += chunk;
		buf_setresid(bp, buf_count(bp) - (done * lm.secsize));
	}
	lck_mtx_unlock(&land_mmc_lock);
	buf_unmap(bp);

	if (error) {
		buf_seterror(bp, EIO);
	}
	buf_biodone(bp);
}

static int
land_mmc_ioctl(dev_t dev, u_long cmd, caddr_t data, __unused int flag,
    __unused struct proc *p, int is_char)
{
	uint32_t *f = (uint32_t *)data;
	uint64_t *o = (uint64_t *)data;

	if (minor(dev) != 0) {
		return ENXIO;
	}

	switch (cmd) {
	case DKIOCGETBLOCKSIZE:
		*f = lm.secsize;
		return 0;
	case DKIOCSETBLOCKSIZE:
		if (is_char) {
			return ENODEV;
		}
		if (*f < DEV_BSIZE || (*f & (*f - 1)) || (MMC_BLOCK % *f)) {
			return EINVAL;
		}
		lm.secsize = *f;
		return 0;
	case DKIOCGETPHYSICALBLOCKSIZE:
		*f = MMC_BLOCK;
		return 0;
	case DKIOCGETBLOCKCOUNT:
		*o = lm.nblocks * MMC_BLOCK / lm.secsize;
		return 0;
	case DKIOCISWRITABLE:
		*f = 0;
		return 0;
	case DKIOCGETMAXBLOCKCOUNTREAD:
		*o = MMC_MAX_CHUNK;
		return 0;
	case DKIOCGETMAXBLOCKCOUNTWRITE:
		*o = 0;
		return 0;
	case DKIOCGETMAXSEGMENTCOUNTREAD:
	case DKIOCGETMAXSEGMENTCOUNTWRITE:
		*o = 1;
		return 0;
	/* DKIOCGMEDIAINFO(EXT) are not in this tree's kernel headers; sweet_ufs.c
	 * gets by without them and so does hfs, which asks block size and count. */

	default:
		return ENOTTY;
	}
}

static int
land_mmc_bioctl(dev_t dev, u_long cmd, caddr_t data, int flag, struct proc *p)
{
	return land_mmc_ioctl(dev, cmd, data, flag, p, 0);
}

static int
land_mmc_cioctl(dev_t dev, u_long cmd, caddr_t data, int flag, struct proc *p)
{
	return land_mmc_ioctl(dev, cmd, data, flag, p, 1);
}

static int
land_mmc_psize(__unused dev_t dev)
{
	return lm.ready ? (int)MIN(lm.nblocks * MMC_BLOCK / lm.secsize, INT_MAX) : -1;
}

static int
land_mmc_read(dev_t dev, struct uio *uio, __unused int ioflag)
{
	return physio(land_mmc_strategy, NULL, dev, B_READ, minphys, uio, (int)lm.secsize);
}

static int
land_mmc_write(__unused dev_t dev, __unused struct uio *uio, __unused int ioflag)
{
	return EROFS;
}

static const struct bdevsw land_mmc_bdevsw = {
	.d_open     = land_mmc_open,
	.d_close    = land_mmc_close,
	.d_strategy = land_mmc_strategy,
	.d_ioctl    = land_mmc_bioctl,
	.d_dump     = eno_dump,
	.d_psize    = land_mmc_psize,
	.d_type     = D_DISK,
};

static const struct cdevsw land_mmc_cdevsw = {
	.d_open       = land_mmc_open,
	.d_close      = land_mmc_close,
	.d_read       = land_mmc_read,
	.d_write      = land_mmc_write,
	.d_ioctl      = land_mmc_cioctl,
	.d_stop       = eno_stop,
	.d_reset      = eno_reset,
	.d_ttys       = NULL,
	.d_select     = eno_select,
	.d_mmap       = eno_mmap,
	.d_strategy   = eno_strat,
	.d_reserved_1 = eno_getc,
	.d_reserved_2 = eno_putc,
	.d_type       = D_DISK,
};

static int
land_mmc_init(void)
{
	DTEntry node;
	void const *value = NULL;
	uint32_t size = 0;

	lm.first_lba = land_emmc_root_lba();
	lm.nblocks = land_emmc_root_bytes() / MMC_BLOCK;
	lm.secsize = MMC_BLOCK;
	strlcpy(lm.fs, "hfsplus", sizeof(lm.fs));

	if (SecureDTFindEntry("name", "emmc", &node) == kSuccess) {
		if (SecureDTGetProperty(node, "land,root-fs", &value, &size) == kSuccess &&
		    size > 1) {
			strlcpy(lm.fs, (const char *)value, sizeof(lm.fs));
		}
	}

	if (!land_emmc_ready()) {
		printf("land-mmc: eMMC is not ready\n");
		return ENXIO;
	}
	if (lm.nblocks < 2) {
		printf("land-mmc: root window is empty (lba 0x%llx)\n", lm.first_lba);
		return ENXIO;
	}

	lm.bmajor = bdevsw_add(-1, &land_mmc_bdevsw);
	if (lm.bmajor < 0) {
		return ENXIO;
	}
	lm.cmajor = cdevsw_add_with_bdev(-1, &land_mmc_cdevsw, lm.bmajor);
	if (lm.cmajor < 0) {
		return ENXIO;
	}
	lm.bdev = makedev(lm.bmajor, 0);
	devfs_make_node(lm.bdev, DEVFS_BLOCK, UID_ROOT, GID_OPERATOR, 0640, "landmmc0");
	devfs_make_node(makedev(lm.cmajor, 0), DEVFS_CHAR, UID_ROOT, GID_OPERATOR,
	    0640, "rlandmmc0");
	lm.ready = true;
	printf("land-mmc: 0x%llx blocks at lba 0x%llx, fs %s, read-only\n",
	    lm.nblocks, lm.first_lba, lm.fs);
	return 0;
}

/* Root device for rd=landmmc0 (IOFindBSDRoot). */
int land_mmc_rootdev(dev_t *dev);

int
land_mmc_rootdev(dev_t *dev)
{
	if (!lm.ready) {
		int error = land_mmc_init();
		if (error) {
			return error;
		}
	}
	*dev = lm.bdev;
	return 0;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
