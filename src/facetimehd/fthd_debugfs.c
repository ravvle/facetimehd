/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * FacetimeHD camera driver
 *
 * Copyright (C) 2015 Sven Schnelle <svens@stackframe.org>
 *
 */

#include <linux/kernel.h>
#include <linux/spinlock.h>
#include <linux/debugfs.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include "fthd_drv.h"
#include "fthd_debugfs.h"
#include "fthd_isp.h"
#include "fthd_ringbuf.h"
#include "fthd_hw.h"

static DEFINE_MUTEX(fthd_debugfs_lock);
static struct dentry *fthd_debugfs_root;
static unsigned int fthd_debugfs_users;

static int fthd_debugfs_open(struct inode *inode, struct file *file)
{
	struct fthd_private *dev_priv = inode->i_private;

	if (!fthd_get(dev_priv))
		return -ENODEV;
	if (READ_ONCE(dev_priv->removing)) {
		fthd_put(dev_priv);
		return -ENODEV;
	}

	file->private_data = dev_priv;
	return 0;
}

static int fthd_debugfs_release(struct inode *inode, struct file *file)
{
	fthd_put(file->private_data);
	return 0;
}

static ssize_t fthd_store_debug(struct file *file, const char __user *user_buf,
				size_t count, loff_t *ppos)
{
	struct fthd_isp_debug_cmd cmd;
	struct fthd_private *dev_priv = file->private_data;
	int ret, opcode;
	char buf[64];
	char *input;

	if (!count)
		return 0;
	if (count >= sizeof(buf))
		return -E2BIG;
	if (copy_from_user(buf, user_buf, count))
		return -EFAULT;

	buf[count] = '\0';
	input = strim(buf);

	memset(&cmd, 0, sizeof(cmd));

	if (!strcmp(input, "ps"))
		opcode = CISP_CMD_DEBUG_PS;
	else if (!strcmp(input, "banner"))
		opcode = CISP_CMD_DEBUG_BANNER;
	else if (!strcmp(input, "get_root"))
		opcode = CISP_CMD_DEBUG_GET_ROOT_HANDLE;
	else if (!strcmp(input, "heap"))
		opcode = CISP_CMD_DEBUG_HEAP_STATISTICS;
	else if (!strcmp(input, "irq"))
		opcode = CISP_CMD_DEBUG_IRQ_STATISTICS;
	else if (!strcmp(input, "semaphore"))
		opcode = CISP_CMD_DEBUG_SHOW_SEMAPHORE_STATUS;
	else if (!strcmp(input, "wiring"))
		opcode = CISP_CMD_DEBUG_SHOW_WIRING_OPERATIONS;
	else if (sscanf(input, "get_object_by_name %255s", (char *)&cmd.arg) == 1)
		opcode = CISP_CMD_DEBUG_GET_OBJECT_BY_NAME;
	else if (sscanf(input, "dump_object %x", &cmd.arg[0]) == 1)
		opcode = CISP_CMD_DEBUG_DUMP_OBJECT;
	else if (!strcmp(input, "dump_objects"))
		opcode = CISP_CMD_DEBUG_DUMP_ALL_OBJECTS;
	else if (!strcmp(input, "show_objects"))
		opcode = CISP_CMD_DEBUG_SHOW_OBJECT_GRAPH;
	else if (sscanf(input, "get_debug_level %u", &cmd.arg[0]) == 1)
		opcode = CISP_CMD_DEBUG_GET_DEBUG_LEVEL;
	else if (sscanf(input, "set_debug_level %x %u", &cmd.arg[0], &cmd.arg[1]) == 2)
		opcode = CISP_CMD_DEBUG_SET_DEBUG_LEVEL;
	else if (sscanf(input, "set_debug_level_rec %x %u", &cmd.arg[0], &cmd.arg[1]) == 2)
		opcode = CISP_CMD_DEBUG_SET_DEBUG_LEVEL_RECURSIVE;
	else if (!strcmp(input, "get_fsm_count"))
		opcode = CISP_CMD_DEBUG_GET_FSM_COUNT;
	else if (sscanf(input, "get_fsm_by_name %255s", (char *)&cmd.arg[0]) == 1)
		opcode = CISP_CMD_DEBUG_GET_FSM_BY_NAME;
	else if (sscanf(input, "get_fsm_by_index %u", &cmd.arg[0]) == 1)
		opcode = CISP_CMD_DEBUG_GET_FSM_BY_INDEX;
	else if (sscanf(input, "get_fsm_debug_level %x", &cmd.arg[0]) == 1)
		opcode = CISP_CMD_DEBUG_GET_FSM_DEBUG_LEVEL;
	else if (sscanf(input, "set_fsm_debug_level %x %u",
			&cmd.arg[0], &cmd.arg[1]) == 2)
		opcode = CISP_CMD_DEBUG_SET_FSM_DEBUG_LEVEL;

	else if (sscanf(input, "%i %u", &opcode, &cmd.arg[0]) != 2)
		return -EINVAL;
	cmd.show_errors = 1;

	/* The debugfs tree stays registered while the camera is runtime
	 * suspended, so anything that reaches the firmware has to power it
	 * back up first. */
	mutex_lock(&dev_priv->ioctl_lock);
	if (READ_ONCE(dev_priv->removing)) {
		ret = -ENODEV;
		goto out_unlock;
	}

	ret = fthd_pm_get(dev_priv);
	if (ret)
		goto out_unlock;

	ret = fthd_isp_debug_cmd(dev_priv, opcode, &cmd, sizeof(cmd), NULL);
	fthd_pm_put(dev_priv);
out_unlock:
	mutex_unlock(&dev_priv->ioctl_lock);
	if (ret)
		return ret;

	return count;
}


/*
 * Takes the address of the channel pointer rather than its value: the channels
 * are freed by a runtime suspend and reallocated by the resume, so the pointer
 * must not be read until fthd_pm_get() has brought the hardware back.
 */
static int seq_channel_read(struct seq_file *seq, struct fthd_private *dev_priv,
			struct fw_channel **chanp)
{
	struct fthd_debugfs_ring_entry {
		u32 address;
		u32 request_size;
		u32 response_size;
		char pos;
	} *entries;
	struct fw_channel *chan;
	int i, ret;
	u32 entry;

	mutex_lock(&dev_priv->ioctl_lock);
	if (READ_ONCE(dev_priv->removing)) {
		ret = -ENODEV;
		goto out_unlock;
	}

	ret = fthd_pm_get(dev_priv);
	if (ret)
		goto out_unlock;

	chan = *chanp;
	if (!chan) {
		ret = -ENODEV;
		goto out;
	}

	entries = kcalloc(chan->size, sizeof(*entries), GFP_KERNEL);
	if (!entries) {
		ret = -ENOMEM;
		goto out;
	}

	spin_lock_irq(&chan->lock);
	for (i = 0; i < chan->size; i++) {
		entries[i].pos = chan->ringbuf.idx == i ? '*' : ' ';
		entry = get_entry_addr(dev_priv, chan, i);
		entries[i].address =
			FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_ADDRESS_FLAGS);
		entries[i].request_size =
			FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_REQUEST_SIZE);
		entries[i].response_size =
			FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_RESPONSE_SIZE);
	}
	spin_unlock_irq(&chan->lock);

	for (i = 0; i < chan->size; i++)
		seq_printf(seq, "%c%3.3d: ADDRESS %08x REQUEST_SIZE %08x RESPONSE_SIZE %08x\n",
			   entries[i].pos, i, entries[i].address,
			   entries[i].request_size, entries[i].response_size);
	kfree(entries);
out:
	fthd_pm_put(dev_priv);
out_unlock:
	mutex_unlock(&dev_priv->ioctl_lock);
	return ret;
}

static int seq_channel_terminal_read(struct seq_file *seq, void *data)
{
	struct fthd_private *dev_priv = seq->private;
	return seq_channel_read(seq, dev_priv, &dev_priv->channel_terminal);
}

static int seq_channel_sharedmalloc_read(struct seq_file *seq, void *data)
{
	struct fthd_private *dev_priv = seq->private;
	return seq_channel_read(seq, dev_priv, &dev_priv->channel_shared_malloc);
}

static int seq_channel_io_read(struct seq_file *seq, void *data)
{
	struct fthd_private *dev_priv = seq->private;
	return seq_channel_read(seq, dev_priv, &dev_priv->channel_io);
}

static int seq_channel_io_t2h_read(struct seq_file *seq, void *data)
{
	struct fthd_private *dev_priv = seq->private;
	return seq_channel_read(seq, dev_priv, &dev_priv->channel_io_t2h);
}

static int seq_channel_buf_h2t_read(struct seq_file *seq, void *data)
{
	struct fthd_private *dev_priv = seq->private;
	return seq_channel_read(seq, dev_priv, &dev_priv->channel_buf_h2t);
}

static int seq_channel_buf_t2h_read(struct seq_file *seq, void *data)
{
	struct fthd_private *dev_priv = seq->private;
	return seq_channel_read(seq, dev_priv, &dev_priv->channel_buf_t2h);
}

static int seq_channel_debug_read(struct seq_file *seq, void *data)
{
	struct fthd_private *dev_priv = seq->private;
	return seq_channel_read(seq, dev_priv, &dev_priv->channel_debug);
}

enum fthd_fw_readback {
	FTHD_FW_SENSOR_TEMPERATURE,
	FTHD_FW_AWB_CCT,
	FTHD_FW_AE_BIAS,
	FTHD_FW_AE_GAIN_CAP,
	FTHD_FW_AE_GAIN_CAP_MIN,
	FTHD_FW_AE_GAIN_CAP_MAX_WITH_EXP,
	FTHD_FW_AE_GAIN_CAP_OFF,
	FTHD_FW_AE_INTEGRATION_TIME_MAX,
	FTHD_FW_AE_SENSOR_INTEGRATION_TIME_MIN,
	FTHD_FW_AE_SENSOR_INTEGRATION_TIME_MAX,
	FTHD_FW_AE_METERING_MODE,
	FTHD_FW_AE_FRAME_RATE_MAX,
	FTHD_FW_AE_FRAME_RATE_MIN,
	FTHD_FW_AWB_2ND_GAIN,
	FTHD_FW_CROP,
};

enum fthd_fw_roundtrip {
	FTHD_FW_ROUNDTRIP_AE_BIAS,
	FTHD_FW_ROUNDTRIP_AE_METERING_MODE,
	FTHD_FW_ROUNDTRIP_AE_INTEGRATION_TIME_MAX,
	FTHD_FW_ROUNDTRIP_AE_GAIN_CAP,
	FTHD_FW_ROUNDTRIP_AE_GAIN_CAP_MIN,
};

/*
 * These files are deliberately unlike the ring-state diagnostics above.
 * Reading one sends exactly one statically whitelisted firmware GET.  Requiring
 * an already-running channel keeps a read from booting or configuring the ISP,
 * and ioctl_lock prevents STREAMOFF from racing the command.
 */
static int seq_firmware_readback(struct seq_file *seq,
				 enum fthd_fw_readback readback)
{
	struct fthd_private *dev_priv = seq->private;
	u32 value, tag;
	u32 gain[3];
	u32 rect1[4], rect2[4];
	s32 signed_value;
	u16 bias;
	u8 mode;
	int ret;

	mutex_lock(&dev_priv->ioctl_lock);
	if (READ_ONCE(dev_priv->removing)) {
		ret = -ENODEV;
		goto out_unlock;
	}
	if (!dev_priv->channel_running) {
		ret = -EPIPE;
		goto out_unlock;
	}

	ret = fthd_pm_get(dev_priv);
	if (ret)
		goto out_unlock;

	switch (readback) {
	case FTHD_FW_SENSOR_TEMPERATURE:
		ret = fthd_isp_cmd_channel_sensor_temperature(dev_priv, 0,
							      &signed_value);
		/*
		 * The raw value stays first on the line so anything parsing
		 * this file keeps working, with the interpretation appended
		 * rather than substituted.  -1 has now been read on a
		 * MacBookAir7,2 at every sampled condition, including after ten
		 * minutes of continuous streaming, which is what a
		 * not-supported sentinel looks like and not what an unknown
		 * temperature scale looks like.  Saying so here is what stops
		 * the next reader from trying to calibrate it.
		 */
		if (!ret)
			seq_printf(seq, "%d%s\n", signed_value,
				   signed_value == FTHD_SENSOR_TEMPERATURE_NONE ?
				   " (unavailable)" : "");
		break;
	case FTHD_FW_AWB_CCT:
		ret = fthd_isp_cmd_channel_awb_cct_get(dev_priv, 0, &value);
		if (!ret)
			seq_printf(seq, "%u\n", value);
		break;
	case FTHD_FW_AE_BIAS:
		ret = fthd_isp_cmd_channel_ae_bias_get(dev_priv, 0, &bias, &tag);
		if (!ret)
			seq_printf(seq, "bias=%u tag=%u\n", bias, tag);
		break;
	case FTHD_FW_AE_GAIN_CAP:
		ret = fthd_isp_cmd_channel_ae_gain_cap_get(dev_priv, 0, &value);
		if (!ret)
			seq_printf(seq, "%u\n", value);
		break;
	case FTHD_FW_AE_GAIN_CAP_MIN:
		ret = fthd_isp_cmd_channel_ae_gain_cap_min_get(dev_priv, 0,
							     &value);
		if (!ret)
			seq_printf(seq, "%u\n", value);
		break;
	case FTHD_FW_AE_GAIN_CAP_MAX_WITH_EXP:
		ret = fthd_isp_cmd_channel_ae_gain_cap_max_with_exp_get(dev_priv,
								      0, &value);
		if (!ret)
			seq_printf(seq, "%u\n", value);
		break;
	case FTHD_FW_AE_GAIN_CAP_OFF:
		ret = fthd_isp_cmd_channel_ae_gain_cap_off_get(dev_priv, 0,
							     &value);
		if (!ret)
			seq_printf(seq, "%u\n", value);
		break;
	case FTHD_FW_AE_INTEGRATION_TIME_MAX:
		ret = fthd_isp_cmd_channel_ae_integration_time_max_get(dev_priv,
								      0, &value);
		if (!ret)
			seq_printf(seq, "%u\n", value);
		break;
	case FTHD_FW_AE_SENSOR_INTEGRATION_TIME_MIN:
		ret = fthd_isp_cmd_channel_ae_sensor_integration_time_min_get(
			dev_priv, 0, &value);
		if (!ret)
			seq_printf(seq, "%u\n", value);
		break;
	case FTHD_FW_AE_SENSOR_INTEGRATION_TIME_MAX:
		ret = fthd_isp_cmd_channel_ae_sensor_integration_time_max_get(
			dev_priv, 0, &value);
		if (!ret)
			seq_printf(seq, "%u\n", value);
		break;
	case FTHD_FW_AE_METERING_MODE:
		ret = fthd_isp_cmd_channel_ae_metering_mode_get(dev_priv, 0,
							       &mode);
		if (!ret)
			seq_printf(seq, "%u\n", mode);
		break;
	case FTHD_FW_AE_FRAME_RATE_MAX:
	case FTHD_FW_AE_FRAME_RATE_MIN:
		ret = readback == FTHD_FW_AE_FRAME_RATE_MAX ?
			fthd_isp_cmd_channel_ae_frame_rate_max_get(dev_priv, 0,
								   &value) :
			fthd_isp_cmd_channel_ae_frame_rate_min_get(dev_priv, 0,
								   &value);
		/*
		 * Firmware skips writing the value when its internal limit is
		 * unset, leaving the zero this driver submitted.  Say that
		 * rather than reporting a rate of zero, which is not what it
		 * means.  See fthd_isp.c for the sentinel evidence.
		 */
		if (!ret)
			seq_printf(seq, "%u%s\n", value,
				   value ? "" : " (not written by firmware)");
		break;
	case FTHD_FW_AWB_2ND_GAIN:
		ret = fthd_isp_cmd_channel_awb_2nd_gain_get(dev_priv, 0, gain);
		/*
		 * Three words whose individual meanings are unrecovered, so
		 * they are printed positionally and not as named colour gains.
		 */
		if (!ret)
			seq_printf(seq, "%u %u %u\n",
				   gain[0], gain[1], gain[2]);
		break;
	case FTHD_FW_CROP:
		ret = fthd_isp_cmd_channel_crop_get(dev_priv, 0, rect1, rect2);
		/*
		 * Two four-word rectangles.  Which one the ISP actually
		 * latched is unestablished, so neither is labelled; a reader
		 * comparing them against the rectangle S_SELECTION requested
		 * is the point of the file.
		 */
		if (!ret)
			seq_printf(seq, "%u %u %u %u\n%u %u %u %u\n",
				   rect1[0], rect1[1], rect1[2], rect1[3],
				   rect2[0], rect2[1], rect2[2], rect2[3]);
		break;
	default:
		ret = -EINVAL;
		break;
	}

	fthd_pm_put(dev_priv);
out_unlock:
	mutex_unlock(&dev_priv->ioctl_lock);
	return ret;
}

#define FTHD_FW_READBACK_SHOW(_name, _readback)                         \
	static int _name(struct seq_file *seq, void *data)                \
	{                                                                  \
		return seq_firmware_readback(seq, _readback);                \
	}

FTHD_FW_READBACK_SHOW(seq_sensor_temperature_raw_read,
			  FTHD_FW_SENSOR_TEMPERATURE);
FTHD_FW_READBACK_SHOW(seq_awb_cct_raw_read, FTHD_FW_AWB_CCT);
FTHD_FW_READBACK_SHOW(seq_ae_bias_raw_read, FTHD_FW_AE_BIAS);
FTHD_FW_READBACK_SHOW(seq_ae_gain_cap_raw_read, FTHD_FW_AE_GAIN_CAP);
FTHD_FW_READBACK_SHOW(seq_ae_gain_cap_min_raw_read,
			  FTHD_FW_AE_GAIN_CAP_MIN);
FTHD_FW_READBACK_SHOW(seq_ae_gain_cap_max_with_exp_raw_read,
			  FTHD_FW_AE_GAIN_CAP_MAX_WITH_EXP);
FTHD_FW_READBACK_SHOW(seq_ae_gain_cap_off_raw_read,
			  FTHD_FW_AE_GAIN_CAP_OFF);
FTHD_FW_READBACK_SHOW(seq_ae_integration_time_max_raw_read,
			  FTHD_FW_AE_INTEGRATION_TIME_MAX);
FTHD_FW_READBACK_SHOW(seq_ae_sensor_integration_time_min_raw_read,
			  FTHD_FW_AE_SENSOR_INTEGRATION_TIME_MIN);
FTHD_FW_READBACK_SHOW(seq_ae_sensor_integration_time_max_raw_read,
			  FTHD_FW_AE_SENSOR_INTEGRATION_TIME_MAX);
FTHD_FW_READBACK_SHOW(seq_ae_metering_mode_raw_read,
			  FTHD_FW_AE_METERING_MODE);
FTHD_FW_READBACK_SHOW(seq_ae_frame_rate_max_raw_read,
			  FTHD_FW_AE_FRAME_RATE_MAX);
FTHD_FW_READBACK_SHOW(seq_ae_frame_rate_min_raw_read,
			  FTHD_FW_AE_FRAME_RATE_MIN);
FTHD_FW_READBACK_SHOW(seq_awb_2nd_gain_raw_read, FTHD_FW_AWB_2ND_GAIN);
FTHD_FW_READBACK_SHOW(seq_crop_raw_read, FTHD_FW_CROP);

#undef FTHD_FW_READBACK_SHOW

static int fthd_firmware_roundtrip(struct fthd_private *dev_priv,
				   enum fthd_fw_roundtrip roundtrip)
{
	u32 before, after, tag_before, tag_after;
	u16 bias_before, bias_after;
	u8 mode_before, mode_after;
	int ret;

	switch (roundtrip) {
	case FTHD_FW_ROUNDTRIP_AE_BIAS:
		ret = fthd_isp_cmd_channel_ae_bias_get(dev_priv, 0,
						       &bias_before, &tag_before);
		if (ret)
			return ret;
		ret = fthd_isp_cmd_channel_ae_bias_set_raw(dev_priv, 0,
							   bias_before, tag_before);
		if (ret)
			return ret;
		ret = fthd_isp_cmd_channel_ae_bias_get(dev_priv, 0,
						       &bias_after, &tag_after);
		if (ret)
			return ret;
		return bias_before == bias_after && tag_before == tag_after ?
			0 : -EIO;
	case FTHD_FW_ROUNDTRIP_AE_METERING_MODE:
		ret = fthd_isp_cmd_channel_ae_metering_mode_get(dev_priv, 0,
							       &mode_before);
		if (ret)
			return ret;
		ret = fthd_isp_cmd_channel_ae_metering_mode_set(dev_priv, 0,
							       mode_before);
		if (ret)
			return ret;
		ret = fthd_isp_cmd_channel_ae_metering_mode_get(dev_priv, 0,
							       &mode_after);
		if (ret)
			return ret;
		return mode_before == mode_after ? 0 : -EIO;
	case FTHD_FW_ROUNDTRIP_AE_INTEGRATION_TIME_MAX:
		ret = fthd_isp_cmd_channel_ae_integration_time_max_get(dev_priv,
								      0, &before);
		if (ret)
			return ret;
		ret = fthd_isp_cmd_channel_ae_integration_time_max_set_raw(
			dev_priv, 0, before);
		if (ret)
			return ret;
		ret = fthd_isp_cmd_channel_ae_integration_time_max_get(dev_priv,
								      0, &after);
		if (ret)
			return ret;
		return before == after ? 0 : -EIO;
	case FTHD_FW_ROUNDTRIP_AE_GAIN_CAP:
		ret = fthd_isp_cmd_channel_ae_gain_cap_get(dev_priv, 0, &before);
		if (ret)
			return ret;
		ret = fthd_isp_cmd_channel_ae_gain_cap_set_raw(dev_priv, 0,
							      before);
		if (ret)
			return ret;
		ret = fthd_isp_cmd_channel_ae_gain_cap_get(dev_priv, 0, &after);
		if (ret)
			return ret;
		return before == after ? 0 : -EIO;
	case FTHD_FW_ROUNDTRIP_AE_GAIN_CAP_MIN:
		ret = fthd_isp_cmd_channel_ae_gain_cap_min_get(dev_priv, 0,
							     &before);
		if (ret)
			return ret;
		ret = fthd_isp_cmd_channel_ae_gain_cap_min_set_raw(dev_priv, 0,
								  before);
		if (ret)
			return ret;
		ret = fthd_isp_cmd_channel_ae_gain_cap_min_get(dev_priv, 0,
							     &after);
		if (ret)
			return ret;
		return before == after ? 0 : -EIO;
	default:
		return -EINVAL;
	}
}

static ssize_t fthd_firmware_roundtrip_write(
	struct file *file, const char __user *user_buf, size_t count,
	loff_t *ppos, enum fthd_fw_roundtrip roundtrip)
{
	struct fthd_private *dev_priv = file->private_data;
	char buf[16];
	int ret;

	if (!count)
		return 0;
	if (*ppos || count >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, user_buf, count))
		return -EFAULT;
	buf[count] = '\0';
	if (strcmp(strim(buf), "same"))
		return -EINVAL;

	mutex_lock(&dev_priv->ioctl_lock);
	if (READ_ONCE(dev_priv->removing)) {
		ret = -ENODEV;
		goto out_unlock;
	}
	if (!dev_priv->channel_running) {
		ret = -EPIPE;
		goto out_unlock;
	}

	ret = fthd_pm_get(dev_priv);
	if (ret)
		goto out_unlock;
	ret = fthd_firmware_roundtrip(dev_priv, roundtrip);
	fthd_pm_put(dev_priv);
out_unlock:
	mutex_unlock(&dev_priv->ioctl_lock);
	if (ret)
		return ret;
	*ppos += count;
	return count;
}

#define FTHD_FW_ROUNDTRIP_FOPS(_name, _roundtrip)                         \
	static ssize_t _name##_write(struct file *file,                    \
				     const char __user *user_buf,          \
				     size_t count, loff_t *ppos)           \
	{                                                                    \
		return fthd_firmware_roundtrip_write(file, user_buf, count,   \
						     ppos, _roundtrip);       \
	}                                                                    \
	static const struct file_operations _name##_fops = {                 \
		.owner = THIS_MODULE,                                           \
		.open = fthd_debugfs_open,                                      \
		.write = _name##_write,                                         \
		.release = fthd_debugfs_release,                                \
		.llseek = noop_llseek,                                          \
	}

FTHD_FW_ROUNDTRIP_FOPS(roundtrip_ae_bias, FTHD_FW_ROUNDTRIP_AE_BIAS);
FTHD_FW_ROUNDTRIP_FOPS(roundtrip_ae_metering_mode,
			      FTHD_FW_ROUNDTRIP_AE_METERING_MODE);
FTHD_FW_ROUNDTRIP_FOPS(roundtrip_ae_integration_time_max,
			      FTHD_FW_ROUNDTRIP_AE_INTEGRATION_TIME_MAX);
FTHD_FW_ROUNDTRIP_FOPS(roundtrip_ae_gain_cap,
			      FTHD_FW_ROUNDTRIP_AE_GAIN_CAP);
FTHD_FW_ROUNDTRIP_FOPS(roundtrip_ae_gain_cap_min,
			      FTHD_FW_ROUNDTRIP_AE_GAIN_CAP_MIN);

#undef FTHD_FW_ROUNDTRIP_FOPS

/*
 * A deliberately narrow mutation endpoint for identifying the four recovered
 * Apple AE metering modes.  Numeric input is not accepted: spelling out the
 * four compile-time tokens keeps this from becoming an arbitrary firmware
 * setter while their user-visible meanings are still under test.
 */
static int fthd_metering_test_mode(char *token, u8 *mode)
{
	if (!strcmp(token, "mode0"))
		*mode = 0;
	else if (!strcmp(token, "mode1"))
		*mode = 1;
	else if (!strcmp(token, "mode2"))
		*mode = 2;
	else if (!strcmp(token, "mode3"))
		*mode = 3;
	else
		return -EINVAL;

	return 0;
}

static ssize_t fthd_test_ae_metering_mode_write(
	struct file *file, const char __user *user_buf, size_t count, loff_t *ppos,
	bool restart_ae)
{
	struct fthd_private *dev_priv = file->private_data;
	char buf[16];
	u8 requested, readback;
	int ret, restart_ret;

	if (!count)
		return 0;
	if (*ppos || count >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, user_buf, count))
		return -EFAULT;
	buf[count] = '\0';
	ret = fthd_metering_test_mode(strim(buf), &requested);
	if (ret)
		return ret;

	mutex_lock(&dev_priv->ioctl_lock);
	if (READ_ONCE(dev_priv->removing)) {
		ret = -ENODEV;
		goto out_unlock;
	}
	if (!dev_priv->channel_running) {
		ret = -EPIPE;
		goto out_unlock;
	}

	ret = fthd_pm_get(dev_priv);
	if (ret)
		goto out_unlock;
	if (restart_ae) {
		ret = fthd_isp_cmd_channel_ae(dev_priv, 0, 0);
		if (ret)
			goto out_pm;
	}
	ret = fthd_isp_cmd_channel_ae_metering_mode_set(dev_priv, 0,
							 requested);
	/* Once AE was stopped, always try to start it again even if SET failed. */
	if (restart_ae) {
		restart_ret = fthd_isp_cmd_channel_ae(dev_priv, 0, 1);
		if (!ret)
			ret = restart_ret;
	}
	if (!ret)
		ret = fthd_isp_cmd_channel_ae_metering_mode_get(dev_priv, 0,
							 &readback);
	if (!ret && readback != requested)
		ret = -EIO;
out_pm:
	fthd_pm_put(dev_priv);
out_unlock:
	mutex_unlock(&dev_priv->ioctl_lock);
	if (ret)
		return ret;
	*ppos += count;
	return count;
}

static ssize_t test_ae_metering_mode_write(
	struct file *file, const char __user *user_buf, size_t count, loff_t *ppos)
{
	return fthd_test_ae_metering_mode_write(file, user_buf, count, ppos,
						 false);
}

static ssize_t test_ae_metering_mode_restart_write(
	struct file *file, const char __user *user_buf, size_t count, loff_t *ppos)
{
	return fthd_test_ae_metering_mode_write(file, user_buf, count, ppos,
						 true);
}

static const struct file_operations test_ae_metering_mode_fops = {
	.owner = THIS_MODULE,
	.open = fthd_debugfs_open,
	.write = test_ae_metering_mode_write,
	.release = fthd_debugfs_release,
	.llseek = noop_llseek,
};

static const struct file_operations test_ae_metering_mode_restart_fops = {
	.owner = THIS_MODULE,
	.open = fthd_debugfs_open,
	.write = test_ae_metering_mode_restart_write,
	.release = fthd_debugfs_release,
	.llseek = noop_llseek,
};

static int fthd_debugfs_seq_open(struct inode *inode, struct file *file,
				 int (*show)(struct seq_file *, void *))
{
	struct fthd_private *dev_priv = inode->i_private;
	int ret;

	if (!fthd_get(dev_priv))
		return -ENODEV;
	if (READ_ONCE(dev_priv->removing)) {
		fthd_put(dev_priv);
		return -ENODEV;
	}

	ret = single_open(file, show, dev_priv);
	if (ret)
		fthd_put(dev_priv);
	return ret;
}

static int fthd_debugfs_seq_release(struct inode *inode, struct file *file)
{
	struct seq_file *seq = file->private_data;
	struct fthd_private *dev_priv = seq->private;
	int ret;

	ret = single_release(inode, file);
	fthd_put(dev_priv);
	return ret;
}

#define FTHD_DEBUGFS_SEQ_FOPS(_name)                                    \
	static int _name##_open(struct inode *inode, struct file *file)   \
	{                                                                  \
		return fthd_debugfs_seq_open(inode, file, _name);            \
	}                                                                  \
	static const struct file_operations _name##_fops = {               \
		.owner = THIS_MODULE,                                         \
		.open = _name##_open,                                         \
		.read = seq_read,                                              \
		.llseek = seq_lseek,                                           \
		.release = fthd_debugfs_seq_release,                           \
	}

FTHD_DEBUGFS_SEQ_FOPS(seq_channel_terminal_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_channel_sharedmalloc_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_channel_io_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_channel_io_t2h_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_channel_buf_h2t_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_channel_buf_t2h_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_channel_debug_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_sensor_temperature_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_awb_cct_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_bias_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_gain_cap_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_gain_cap_min_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_gain_cap_max_with_exp_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_gain_cap_off_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_integration_time_max_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_sensor_integration_time_min_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_sensor_integration_time_max_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_metering_mode_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_frame_rate_max_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_ae_frame_rate_min_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_awb_2nd_gain_raw_read);
FTHD_DEBUGFS_SEQ_FOPS(seq_crop_raw_read);

static const struct file_operations fops_debug = {
	.write = fthd_store_debug,
	.open = fthd_debugfs_open,
	.release = fthd_debugfs_release,
	.owner = THIS_MODULE,
	.llseek = default_llseek,
};

int fthd_debugfs_init(struct fthd_private *dev_priv)
{
	struct dentry *d;

	mutex_lock(&fthd_debugfs_lock);
	if (!fthd_debugfs_root) {
		fthd_debugfs_root = debugfs_create_dir("facetimehd", NULL);
		if (IS_ERR_OR_NULL(fthd_debugfs_root)) {
			dev_warn(&dev_priv->pdev->dev,
				 "debugfs unavailable: %ld\n",
				 fthd_debugfs_root ?
				 PTR_ERR(fthd_debugfs_root) : -ENODEV);
			fthd_debugfs_root = NULL;
			goto out_unlock;
		}
	}

	d = debugfs_create_dir(dev_name(&dev_priv->pdev->dev),
			       fthd_debugfs_root);
	if (IS_ERR_OR_NULL(d)) {
		dev_warn(&dev_priv->pdev->dev,
			 "could not create debugfs directory: %ld\n",
			 d ? PTR_ERR(d) : -ENOMEM);
		goto remove_unused_root;
	}

	debugfs_create_file("channel_terminal", 0400, d, dev_priv,
			    &seq_channel_terminal_read_fops);
	debugfs_create_file("channel_sharedmalloc", 0400, d, dev_priv,
			    &seq_channel_sharedmalloc_read_fops);
	debugfs_create_file("channel_io", 0400, d, dev_priv,
			    &seq_channel_io_read_fops);
	debugfs_create_file("channel_io_t2h", 0400, d, dev_priv,
			    &seq_channel_io_t2h_read_fops);
	debugfs_create_file("channel_buf_h2t", 0400, d, dev_priv,
			    &seq_channel_buf_h2t_read_fops);
	debugfs_create_file("channel_buf_t2h", 0400, d, dev_priv,
			    &seq_channel_buf_t2h_read_fops);
	debugfs_create_file("channel_debug", 0400, d, dev_priv,
			    &seq_channel_debug_read_fops);
	debugfs_create_file("sensor_temperature_raw", 0400, d, dev_priv,
			    &seq_sensor_temperature_raw_read_fops);
	debugfs_create_file("awb_cct_raw", 0400, d, dev_priv,
			    &seq_awb_cct_raw_read_fops);
	debugfs_create_file("ae_bias_raw", 0400, d, dev_priv,
			    &seq_ae_bias_raw_read_fops);
	debugfs_create_file("ae_gain_cap_raw", 0400, d, dev_priv,
			    &seq_ae_gain_cap_raw_read_fops);
	debugfs_create_file("ae_gain_cap_min_raw", 0400, d, dev_priv,
			    &seq_ae_gain_cap_min_raw_read_fops);
	debugfs_create_file("ae_gain_cap_max_with_exp_raw", 0400, d, dev_priv,
			    &seq_ae_gain_cap_max_with_exp_raw_read_fops);
	debugfs_create_file("ae_gain_cap_off_raw", 0400, d, dev_priv,
			    &seq_ae_gain_cap_off_raw_read_fops);
	debugfs_create_file("ae_integration_time_max_raw", 0400, d, dev_priv,
			    &seq_ae_integration_time_max_raw_read_fops);
	debugfs_create_file("ae_sensor_integration_time_min_raw", 0400, d,
			    dev_priv,
			    &seq_ae_sensor_integration_time_min_raw_read_fops);
	debugfs_create_file("ae_sensor_integration_time_max_raw", 0400, d,
			    dev_priv,
			    &seq_ae_sensor_integration_time_max_raw_read_fops);
	debugfs_create_file("ae_metering_mode_raw", 0400, d, dev_priv,
			    &seq_ae_metering_mode_raw_read_fops);
	debugfs_create_file("ae_frame_rate_max_raw", 0400, d, dev_priv,
			    &seq_ae_frame_rate_max_raw_read_fops);
	debugfs_create_file("ae_frame_rate_min_raw", 0400, d, dev_priv,
			    &seq_ae_frame_rate_min_raw_read_fops);
	debugfs_create_file("awb_2nd_gain_raw", 0400, d, dev_priv,
			    &seq_awb_2nd_gain_raw_read_fops);
	debugfs_create_file("crop_raw", 0400, d, dev_priv,
			    &seq_crop_raw_read_fops);
	debugfs_create_file("roundtrip_ae_bias", 0200, d, dev_priv,
			    &roundtrip_ae_bias_fops);
	debugfs_create_file("roundtrip_ae_metering_mode", 0200, d, dev_priv,
			    &roundtrip_ae_metering_mode_fops);
	debugfs_create_file("roundtrip_ae_integration_time_max", 0200, d,
			    dev_priv, &roundtrip_ae_integration_time_max_fops);
	debugfs_create_file("roundtrip_ae_gain_cap", 0200, d, dev_priv,
			    &roundtrip_ae_gain_cap_fops);
	debugfs_create_file("roundtrip_ae_gain_cap_min", 0200, d, dev_priv,
			    &roundtrip_ae_gain_cap_min_fops);
	debugfs_create_file("test_ae_metering_mode", 0200, d, dev_priv,
			    &test_ae_metering_mode_fops);
	debugfs_create_file("test_ae_metering_mode_restart", 0200, d, dev_priv,
			    &test_ae_metering_mode_restart_fops);
	debugfs_create_file("debug", 0600, d, dev_priv, &fops_debug);
	dev_priv->debugfs = d;
	fthd_debugfs_users++;
	goto out_unlock;

remove_unused_root:
	if (!fthd_debugfs_users) {
		debugfs_remove(fthd_debugfs_root);
		fthd_debugfs_root = NULL;
	}
out_unlock:
	mutex_unlock(&fthd_debugfs_lock);
	return 0;
}

void fthd_debugfs_exit(struct fthd_private *dev_priv)
{
	mutex_lock(&fthd_debugfs_lock);
	if (!dev_priv->debugfs)
		goto out_unlock;

	debugfs_remove(dev_priv->debugfs);
	dev_priv->debugfs = NULL;
	if (WARN_ON_ONCE(!fthd_debugfs_users))
		goto out_unlock;

	fthd_debugfs_users--;
	if (!fthd_debugfs_users) {
		debugfs_remove(fthd_debugfs_root);
		fthd_debugfs_root = NULL;
	}

out_unlock:
	mutex_unlock(&fthd_debugfs_lock);
}
