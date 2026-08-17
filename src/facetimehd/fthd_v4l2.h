/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * FacetimeHD camera driver
 *
 * Copyright (C) 2015 Sven Schnelle <svens@stackframe.org>
 *
 */

#ifndef _FTHD_V4L2_H
#define _FTHD_V4L2_H

#include <linux/pci.h>
#include <linux/spinlock.h>
#include <linux/wait.h>
#include <linux/mutex.h>
#include <media/v4l2-device.h>

struct fthd_fmt {
	struct v4l2_pix_format fmt;
	const char *desc;
	int range; /* CISP_COMMAND_CH_OUTPUT_CONFIG_SET */
	/* Number of plane addresses the ISP is given, not the number of vb2
	 * planes - the queue is single-planar and always has exactly one.  A
	 * semi-planar format sets this to 2 and carries its chroma plane at an
	 * offset inside that same buffer. */
	int planes;
	int x1; /* for CISP_CMD_CH_CROP_SET */
	int y1;
	int x2;
	int y2;
};

struct fthd_private;
extern int fthd_v4l2_register(struct fthd_private *dev_priv);
extern void fthd_v4l2_unregister(struct fthd_private *dev_priv);
extern void fthd_v4l2_suspend_stop(struct fthd_private *dev_priv);

#endif
