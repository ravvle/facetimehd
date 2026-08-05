/*
 * Broadcom PCIe 1570 webcam driver
 *
 * Copyright (C) 2014 Patrik Jakobsson (patrik.r.jakobsson@gmail.com)
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 as published by
 * the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software Foundation.
 *
 */

#ifndef _FTHD_DDR_H
#define _FTHD_DDR_H

#define MEM_VERIFY_BASE		0x0 /* 0x1000000 */

/*
 * Words checked by fthd_ddr_verify_mem() after DDR bring-up.
 *
 * The resume figure is deliberately tiny: fthd_hw_init() runs on every
 * runtime-PM resume, so this is on the path of every camera open() and only
 * has to answer "did the restored PHY configuration come back working".
 *
 * Probe happens once, so it can afford to span enough address lines to be
 * worth something.  128 words is 512 bytes - it exercises so few address bits
 * that it cannot detect an address-line fault at all, which is what upstream
 * nonetheless logged as "Full memory verification succeeded".  Every word
 * costs a non-posted PCIe read on the way back (~1us), so this is a latency
 * trade, not a free one: 64K words is ~256KB and tens of milliseconds, added
 * to modprobe rather than to camera startup.
 *
 * Both are judgement calls made without hardware to measure on.  If probe
 * turns out to be too slow, lower MEM_VERIFY_NUM_PROBE; it is a coverage knob,
 * not a correctness one.
 */
#define MEM_VERIFY_NUM		128
#define MEM_VERIFY_NUM_PROBE	(64 * 1024)

int fthd_ddr_verify_mem(struct fthd_private *dev_priv, u32 base, int count);

#endif
