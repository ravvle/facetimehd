/*
 * FacetimeHD camera driver
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

/*
 * Upstream's DDR shmoo calibration used to live here and has been removed; see
 * patjak/facetimehd commit 364b1c663583 for the original, and DOWNSTREAM.md
 * for the reasoning.  In short: nothing ever called fthd_ddr_calibrate(), roughly
 * half of the state machine below it was never written (four stages were empty
 * `return 0` stubs, and the author's own comments read "It always fails, so
 * just pass success" and "Some global stuff that I need to figure out"), and
 * the parts that were written contained three timeouts that could not fire —
 * two of them guarding otherwise unbounded loops.
 *
 * The camera does not need it.  DDR is brought up by the fixed register
 * sequences in fthd_hw_s2_{pre,}init_ddr_controller_soc(), whose result is
 * checked by fthd_ddr_verify_mem() below and then snapshotted by
 * fthd_ddr_phy_save_regs() so a runtime-PM resume can restore it.  Training
 * exists to absorb part-to-part and thermal variation that fixed timings
 * cannot, and no such failure has been observed on this hardware.
 *
 * Do not revive this without a 2013-2015 MacBook to validate against, and
 * preferably several: the missing stages cannot be written without
 * reverse-engineering Apple's kext or Broadcom's DDR40 PHY (no public
 * datasheet exists), and "it works on my machine at room temperature" is not
 * evidence that memory training is correct.  Note also that fthd_hw_init()
 * runs on every runtime-PM resume, not once per boot, so a full shmoo would
 * be paid for on every camera open().
 *
 * The S2_DDR40_* register definitions are deliberately left in fthd_reg.h.
 * They document the hardware and cost nothing, and anyone reviving this would
 * need them back.
 */

#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
#include <linux/prandom.h>
#else
#include <linux/random.h>
#endif

#include "fthd_drv.h"
#include "fthd_hw.h"
#include "fthd_ddr.h"

/*
 * Write a pseudo-random pattern over @count words of ISP DRAM starting at
 * @base, read it back, and return the OR of every bit that came back wrong
 * (folded into 16 bits, one per data line).  Zero means the DDR link carried
 * everything intact.
 *
 * @count is clamped to what the S2 memory BAR actually maps.  Each individual
 * out-of-range access would otherwise log its own dev_err, so an oversized
 * request degrades to "verify as much as exists" rather than a million lines
 * of error spam.
 */
int fthd_ddr_verify_mem(struct fthd_private *dev_priv, u32 base, int count)
{
	u32 i, val, val_read, max_words;
	int failed_bits = 0;
	struct rnd_state state;

	if (count <= 0)
		return 0;

	if (dev_priv->s2_mem_len <= base)
		return 0;

	max_words = (dev_priv->s2_mem_len - base) / sizeof(u32);
	if ((u32)count > max_words)
		count = max_words;

	prandom_seed_state(&state, 0x12345678);

	for (i = 0; i < count; i++) {
		val = prandom_u32_state(&state);
		FTHD_S2_MEM_WRITE(val, i * 4 + base);
	}

	prandom_seed_state(&state, 0x12345678);

	for (i = 0; i < count; i++) {
		val = prandom_u32_state(&state);
		val_read = FTHD_S2_MEM_READ(i * 4 + base);

		failed_bits |= val ^ val_read;
	}

	return ((failed_bits & 0xffff) | ((failed_bits >> 16) & 0xffff));
}
