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
