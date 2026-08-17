/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * FacetimeHD camera driver - sensor die temperature
 */

#ifndef _FTHD_HWMON_H
#define _FTHD_HWMON_H

struct fthd_private;

/* Read the firmware's sensor temperature exactly as reported, applying no
 * scale.  Takes ioctl_lock and a runtime-PM reference, so it must not be
 * called from anything already holding either. */
extern int fthd_hwmon_read_raw(struct fthd_private *dev_priv, s32 *raw);
extern void fthd_hwmon_register(struct fthd_private *dev_priv);

#endif
