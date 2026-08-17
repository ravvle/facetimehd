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
#include <linux/version.h>
#include <linux/videodev2.h>
#include <media/v4l2-dev.h>
#include <media/v4l2-ioctl.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-event.h>
#include <media/videobuf2-dma-sg.h>
#include "fthd_drv.h"
#include "fthd_hw.h"
#include "fthd_isp.h"
#include "fthd_ringbuf.h"
#include "fthd_buffer.h"

/* Fallback ceiling used only if the sensor's native size wasn't detected.
 * The real per-device limit is dev_priv->sensor_width/height. */
#define FTHD_MAX_WIDTH 1280
#define FTHD_MAX_HEIGHT 720
#define FTHD_MIN_WIDTH 320
#define FTHD_MIN_HEIGHT 240
#define FTHD_NUM_FORMATS 3
#define FTHD_PROTOCOL_ERROR_LIMIT 4

/* The only rate the sensor delivers.  G_PARM, S_PARM and ENUM_FRAMEINTERVALS
 * must all report this same value or they contradict each other. */
#define FTHD_FPS 30

static int fthd_buffer_queue_setup(
    struct vb2_queue *vq,
    unsigned int *nbuffers,
    unsigned int *nplanes,
    unsigned int sizes[],
    struct device *alloc_devs[]
) {

	struct fthd_private *dev_priv = vb2_get_drv_priv(vq);
	struct v4l2_pix_format *cur_fmt = &dev_priv->fmt.fmt;

	/* Always exactly one vb2 plane, whatever dev_priv->fmt.planes says.
	 * That field counts the planes the *ISP* is given addresses for, and a
	 * semi-planar format keeps its chroma plane inside this same buffer at
	 * a fixed offset - which is precisely what a single-planar NV16 is.
	 * Userspace sees one buffer either way.  Returning fmt.planes here
	 * would have asked a V4L2_BUF_TYPE_VIDEO_CAPTURE queue for two planes,
	 * which it cannot have. */
	if (*nplanes) {
		if (*nplanes != 1)
			return -EINVAL;
		if (sizes[0] < cur_fmt->sizeimage)
			return -EINVAL;
		return 0;
	}

	*nplanes = 1;
	sizes[0] = cur_fmt->sizeimage;
	alloc_devs[0] = &dev_priv->pdev->dev;

	/* The ceiling is the h2t_bufs array, not a memory budget: every queued
	 * buffer needs one of its FTHD_BUFFERS hardware slots. The literal 4
	 * here used to duplicate that constant. */
	*nbuffers = (4096 * 4096) / sizes[0];
	if (*nbuffers > FTHD_BUFFERS)
		*nbuffers = FTHD_BUFFERS;
	if (*nbuffers <= 1)
		return -ENOMEM;
	pr_debug("using %d buffers\n", *nbuffers);

	return 0;
}

/*
 * Free the ISP-side memory a prepared buffer owns and put its slot back on the
 * free list.  The buffer must no longer be queued to the firmware, and the
 * hardware must still be up: both isp_mem_destroy() and iommu_free() write S2
 * registers, so this cannot run after fthd_pm_down().
 */
static void fthd_release_buffer_ctx(struct fthd_private *dev_priv,
				    struct h2t_buf_ctx *ctx)
{
	struct isp_mem_obj *dma_desc_obj;
	struct iommu_obj *planes[ARRAY_SIZE(dev_priv->h2t_bufs[0].plane)];
	unsigned long flags;
	int i;

	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	if (ctx->state == BUF_FREE) {
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
		return;
	}

	ctx->state = BUF_FREE;
	ctx->vb = NULL;
	dma_desc_obj = ctx->dma_desc_obj;
	ctx->dma_desc_obj = NULL;
	for (i = 0; i < ARRAY_SIZE(ctx->plane); i++) {
		planes[i] = ctx->plane[i];
		ctx->plane[i] = NULL;
	}
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	isp_mem_destroy(dma_desc_obj);
	for (i = 0; i < ARRAY_SIZE(planes); i++)
		iommu_free(dev_priv, planes[i]);
}

static void fthd_buffer_cleanup(struct vb2_buffer *vb)
{
	struct fthd_private *dev_priv = vb2_get_drv_priv(vb->vb2_queue);
	struct h2t_buf_ctx *ctx = NULL;
	unsigned long flags;
	int i;

	pr_debug("%p\n", vb);
	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	for (i = 0; i < FTHD_BUFFERS; i++) {
		if (dev_priv->h2t_bufs[i].vb == vb) {
			ctx = dev_priv->h2t_bufs + i;
			break;
		};
	}
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	if (ctx)
		fthd_release_buffer_ctx(dev_priv, ctx);
}

static int fthd_send_h2t_buffer(struct fthd_private *dev_priv, struct h2t_buf_ctx *ctx)
{
	u32 entry;
	int ret;

	pr_debug("sending buffer %p size %ld, ctx %p\n", ctx->vb, sizeof(ctx->dma_desc_list), ctx);
	ret = FTHD_S2_MEMCPY_TOIO(ctx->dma_desc_obj->offset,
				   &ctx->dma_desc_list,
				   sizeof(ctx->dma_desc_list));
	if (ret)
		return ret;
	ret = fthd_channel_ringbuf_send(dev_priv, dev_priv->channel_buf_h2t,
					ctx->dma_desc_obj->offset, 0x180, 0x30000000, &entry);

	if (ret) {
		dev_err(&dev_priv->pdev->dev, "%s: fthd_channel_ringbuf_send: %d\n", __func__, ret);
		return ret;
	}
	return fthd_channel_wait_ready(dev_priv, dev_priv->channel_buf_h2t, entry, 2000);
}

static void fthd_buffer_queue(struct vb2_buffer *vb)
{
	struct fthd_private *dev_priv = vb2_get_drv_priv(vb->vb2_queue);
	struct dma_descriptor_list *list;
	struct h2t_buf_ctx *ctx = NULL;
	unsigned long flags;
	bool send = false;

	int i;
	pr_debug("vb = %p\n", vb);
	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	for (i = 0; i < FTHD_BUFFERS; i++) {
		if (dev_priv->h2t_bufs[i].vb == vb) {
			ctx = dev_priv->h2t_bufs + i;
			break;
		};
	}

	if (!ctx || ctx->state != BUF_ALLOC)
		goto out_unlock;

	if (!vb->vb2_queue->streaming) {
		ctx->state = BUF_DRV_QUEUED;
	} else {
		list = &ctx->dma_desc_list;
		list->field0 = 1;
		ctx->state = BUF_HW_QUEUED;
		wmb();
		pr_debug("%d: field0: %d, count %d, pool %d, addr0 0x%08x, addr1 0x%08x tag 0x%08llx vb = %p\n", i, list->field0,
			 list->desc[0].count, list->desc[0].pool,
			 list->desc[0].addr0, list->desc[0].addr1,
			 list->desc[0].tag, ctx->vb);

		send = true;
	}
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	if (send && fthd_send_h2t_buffer(dev_priv, ctx)) {
		fthd_mark_firmware_wedged(dev_priv);
		spin_lock_irqsave(&dev_priv->buffer_lock, flags);
		if (ctx->state == BUF_HW_QUEUED) {
			ctx->state = BUF_ALLOC;
			spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
			vb2_buffer_done(vb, VB2_BUF_STATE_ERROR);
			return;
		}
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
	}
	return;

out_unlock:
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
	vb2_buffer_done(vb, VB2_BUF_STATE_ERROR);
}

static int fthd_buffer_prepare(struct vb2_buffer *vb)
{
	struct fthd_private *dev_priv = vb2_get_drv_priv(vb->vb2_queue);
	struct sg_table *sgtable;
	struct h2t_buf_ctx *ctx = NULL;
	struct dma_descriptor_list *dma_list;
	unsigned long flags;
	u32 base;
	int i;
	int ret = 0;

	if (vb2_plane_size(vb, 0) < dev_priv->fmt.fmt.sizeimage)
		return -EINVAL;

	pr_debug("%p\n", vb);
	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	for (i = 0; i < FTHD_BUFFERS; i++) {
		if (dev_priv->h2t_bufs[i].state == BUF_FREE ||
		    (dev_priv->h2t_bufs[i].state == BUF_ALLOC && dev_priv->h2t_bufs[i].vb == vb)) {
			ctx = dev_priv->h2t_bufs + i;
			break;
		}
	}

	if (!ctx) {
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
		return -ENOBUFS;
	}

	if (ctx->state == BUF_FREE) {
		pr_debug("allocating new entry\n");
		ctx->vb = vb;
		ctx->state = BUF_ALLOC;
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

		ctx->dma_desc_obj = isp_mem_create(dev_priv, FTHD_MEM_BUFFER, 0x180);
		if (!ctx->dma_desc_obj) {
			ret = -ENOMEM;
			goto fail;
		}

		/* One mapping for the whole buffer.  See the addr1 comment
		 * below for why a semi-planar format does not need a second. */
		sgtable = vb2_dma_sg_plane_desc(vb, 0);
		ctx->plane[0] = iommu_allocate_sgtable(dev_priv, sgtable);
		if (!ctx->plane[0]) {
			ret = -ENOMEM;
			goto fail;
		}
	} else {
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
	}

	vb2_set_plane_payload(vb, 0, dev_priv->fmt.fmt.sizeimage);

	dma_list = &ctx->dma_desc_list;
	memset(dma_list, 0, sizeof(*dma_list));

	dma_list->field0 = 1;
	dma_list->count = 1;
	dma_list->desc[0].count = 1;
	dma_list->desc[0].pool = 0x02;

	/* iommu_allocate_sgtable() walks the scatterlist into one contiguous
	 * run of S2 IOVA pages, so the chroma plane of a semi-planar format is
	 * reachable as a byte offset from the start of the same mapping rather
	 * than needing a mapping of its own.  The offset stays far below the
	 * 0xc0000000 tag: the IOVA window is 4096 pages, so the whole address
	 * fits in the low 24 bits and the addition cannot carry into it. */
	base = (ctx->plane[0]->offset << PAGE_SHIFT) |
		ctx->plane[0]->page_offset | 0xc0000000;
	dma_list->desc[0].addr0 = base;

	if (dev_priv->fmt.planes >= 2)
		dma_list->desc[0].addr1 = base + dev_priv->fmt.fmt.bytesperline *
						 dev_priv->fmt.fmt.height;

	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	ctx->tag = ++dev_priv->buffer_tag;
	if (!ctx->tag)
		ctx->tag = ++dev_priv->buffer_tag;
	dma_list->desc[0].tag = ctx->tag;
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
	return 0;

fail:
	fthd_buffer_cleanup(vb);
	return ret;
}

static void fthd_protocol_error(struct fthd_private *dev_priv)
{
	unsigned long flags;
	bool fatal = false;

	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	if (dev_priv->protocol_errors < FTHD_PROTOCOL_ERROR_LIMIT &&
	    ++dev_priv->protocol_errors == FTHD_PROTOCOL_ERROR_LIMIT)
		fatal = true;
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	if (fatal) {
		dev_err(&dev_priv->pdev->dev,
			"too many invalid firmware buffer returns; failing the queue\n");
		fthd_mark_firmware_wedged(dev_priv);
	}
}

void fthd_buffer_return_handler(struct fthd_private *dev_priv, u32 offset,
				u32 size)
{
	struct dma_descriptor_list list;
	struct h2t_buf_ctx *ctx = NULL;
	struct vb2_buffer *vb = NULL;
	struct vb2_v4l2_buffer *vbuf;
	enum fthd_buffer_state invalid_state = BUF_FREE;
	unsigned long flags;
	int i;

	if (size && size < sizeof(list)) {
		dev_warn(&dev_priv->pdev->dev,
			 "short buffer return descriptor: %u bytes\n", size);
		fthd_protocol_error(dev_priv);
		return;
	}

	if (FTHD_S2_MEMCPY_FROMIO(&list, offset, sizeof(list))) {
		dev_warn_ratelimited(&dev_priv->pdev->dev,
				     "unreadable buffer return descriptor at %#x\n",
				     offset);
		fthd_protocol_error(dev_priv);
		return;
	}

	if (list.count != 1) {
		dev_warn_ratelimited(&dev_priv->pdev->dev,
				     "buffer return descriptor at %#x has %u entries\n",
				     offset, list.count);
		fthd_protocol_error(dev_priv);
		return;
	}

	/* Match on the opaque generation tag the firmware echoes back, which is
	 * the only field it is contractually required to return unchanged.
	 *
	 * Do NOT match on dma_desc_obj->offset: that assumes the address in the
	 * ring entry is the descriptor object we submitted, and on a MacBookAir7,2
	 * it is not - the lookup missed for every frame, the handler returned
	 * silently, and capture starved after the initial buffer set with no
	 * diagnostic at all.
	 *
	 * The tag is a generation counter, never a kernel pointer, so a hostile
	 * or confused firmware can at worst complete the wrong one of our own
	 * buffers - which is what the state check below is for. */
	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	for (i = 0; i < FTHD_BUFFERS; i++) {
		/* Tags start at 1, so zero means "never submitted" and must not
		 * match a zeroed descriptor. */
		if (dev_priv->h2t_bufs[i].tag &&
		    dev_priv->h2t_bufs[i].tag == list.desc[0].tag) {
			ctx = &dev_priv->h2t_bufs[i];
			break;
		}
	}

	if (!ctx) {
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
		dev_warn_ratelimited(&dev_priv->pdev->dev,
				     "buffer return at %#x carries unknown tag %#llx\n",
				     offset, list.desc[0].tag);
		fthd_protocol_error(dev_priv);
		return;
	}

	pr_debug("field0: %d, count %d, pool %d, addr0 0x%08x, addr1 0x%08x tag 0x%08llx vb = %p, ctx = %p\n",
		 list.field0, list.desc[0].count, list.desc[0].pool,
		 list.desc[0].addr0, list.desc[0].addr1,
		 list.desc[0].tag, ctx->vb, ctx);

	if ((ctx->state == BUF_HW_QUEUED || ctx->state == BUF_DRV_QUEUED) &&
	    ctx->vb) {
		vb = ctx->vb;
		ctx->state = BUF_ALLOC;
		dev_priv->protocol_errors = 0;
	} else
		invalid_state = ctx->state;

	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
	if (!vb) {
		dev_warn_ratelimited(&dev_priv->pdev->dev,
				     "buffer return tag %#llx has invalid state %u\n",
				     list.desc[0].tag, invalid_state);
		fthd_protocol_error(dev_priv);
		return;
	}

	vbuf = to_vb2_v4l2_buffer(vb);
	vbuf->sequence = dev_priv->sequence++;
	vbuf->vb2_buf.timestamp = ktime_get_ns();
	vbuf->field = V4L2_FIELD_NONE;
	vb2_buffer_done(vb, VB2_BUF_STATE_DONE);
}

static void fthd_return_all_buffers(struct fthd_private *dev_priv,
				    enum vb2_buffer_state state)
{
	struct vb2_buffer *buffers[FTHD_BUFFERS];
	unsigned long flags;
	int count = 0;
	int i;

	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	for (i = 0; i < FTHD_BUFFERS; i++) {
		struct h2t_buf_ctx *ctx = &dev_priv->h2t_bufs[i];

		if ((ctx->state == BUF_DRV_QUEUED ||
		     ctx->state == BUF_HW_QUEUED) && ctx->vb) {
			buffers[count++] = ctx->vb;
			ctx->state = BUF_ALLOC;
		}
	}
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	for (i = 0; i < count; i++)
		vb2_buffer_done(buffers[i], state);
}

static int fthd_start_streaming(struct vb2_queue *vq, unsigned int count)
{
	struct fthd_private *dev_priv = vb2_get_drv_priv(vq);
	struct h2t_buf_ctx *ctx;
	unsigned int submitted = 0;
	int i, ret;

	pr_debug("count = %d\n", count);
	dev_priv->sequence = 0;
	spin_lock_irq(&dev_priv->buffer_lock);
	dev_priv->protocol_errors = 0;
	spin_unlock_irq(&dev_priv->buffer_lock);

	if (READ_ONCE(dev_priv->removing)) {
		ret = -ENODEV;
		goto fail_buffers;
	}
	if (READ_ONCE(dev_priv->wedged)) {
		ret = -EIO;
		goto fail_buffers;
	}

	ret = fthd_start_channel(dev_priv, 0);
	if (ret) {
		/* The firmware command sequence may have failed after a partial start. */
		fthd_stop_channel(dev_priv, 0);
		fthd_return_all_buffers(dev_priv, VB2_BUF_STATE_QUEUED);
		return ret;
	}
	dev_priv->channel_running = true;

	/* Push the control values the user set while the channel was down.  The
	 * ISP comes up with its own defaults every time the firmware is
	 * reloaded, which runtime PM now makes happen on each idle cycle, so
	 * without this a control set once is forgotten on the next open(). */
	ret = v4l2_ctrl_handler_setup(&dev_priv->v4l2_ctrl_handler);
	if (ret)
		goto fail_channel;

	for (i = 0; i < FTHD_BUFFERS; i++) {
		unsigned long flags;
		bool submit = false;

		ctx = dev_priv->h2t_bufs + i;
		spin_lock_irqsave(&dev_priv->buffer_lock, flags);
		if (ctx->state == BUF_DRV_QUEUED) {
			ctx->state = BUF_HW_QUEUED;
			submit = true;
		}
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
		if (!submit)
			continue;

		ret = fthd_send_h2t_buffer(dev_priv, ctx);
		if (ret) {
			fthd_mark_firmware_wedged(dev_priv);
			goto fail_channel;
		}
		submitted++;
	}
	if (!submitted) {
		ret = -ENOBUFS;
		goto fail_channel;
	}
	return 0;

fail_channel:
	dev_priv->channel_running = false;
	fthd_stop_channel(dev_priv, 0);
fail_buffers:
	fthd_return_all_buffers(dev_priv, VB2_BUF_STATE_QUEUED);
	return ret;
}

static void fthd_stop_streaming(struct vb2_queue *vq)
{
	struct fthd_private *dev_priv = vb2_get_drv_priv(vq);
	int ret;

	/* A system suspend that arrived mid-stream already stopped the channel
	 * and errored the queue; the STREAMOFF that clears the error then lands
	 * here with nothing left to stop. */
	if (dev_priv->channel_running) {
		dev_priv->channel_running = false;

		ret = fthd_stop_channel(dev_priv, 0);
		if (ret)
			dev_warn(&dev_priv->pdev->dev,
				 "failed to stop firmware channel: %d\n", ret);
	}

	/* stop_streaming must return every buffer owned by the driver.  Never
	 * wait without a timeout for firmware that has already failed a command. */
	fthd_return_all_buffers(dev_priv, VB2_BUF_STATE_ERROR);
}

/*
 * Give the hardware up for a system suspend that arrived with buffers
 * allocated - usually with an app streaming.  Unlike a runtime suspend this
 * cannot be refused: returning an error from the system sleep callback aborts
 * the whole transition and the machine stays awake, so the stream has to be
 * torn down under userspace instead.
 *
 * Everything the buffers own lives in ISP memory that fthd_pm_down() is about
 * to destroy, so it is all released here while the registers are still mapped.
 * That leaves the vb2 buffers prepared but with no hardware behind them, which
 * is why the queue is errored: vb2 only re-runs buf_prepare() after a
 * STREAMOFF, and marking the queue is what makes an app notice it has to do
 * one.  DQBUF and poll() then fail with -EIO, the STREAMOFF clears the error,
 * and a STREAMON re-prepares the buffers against the resumed hardware.
 *
 * Runs under ioctl_lock, with the hardware still powered: buffers can only be
 * allocated while /dev/videoN is open, and an open fd holds a runtime-PM
 * reference.
 */
void fthd_v4l2_suspend_stop(struct fthd_private *dev_priv)
{
	int i;

	if (dev_priv->channel_running) {
		dev_priv->channel_running = false;
		if (fthd_stop_channel(dev_priv, 0))
			dev_warn(&dev_priv->pdev->dev,
				 "failed to stop firmware channel for suspend\n");
	}

	fthd_return_all_buffers(dev_priv, VB2_BUF_STATE_ERROR);

	for (i = 0; i < FTHD_BUFFERS; i++)
		fthd_release_buffer_ctx(dev_priv, &dev_priv->h2t_bufs[i]);

	vb2_queue_error(&dev_priv->vb2_queue);
}

static const struct vb2_ops vb2_queue_ops = {
	.queue_setup            = fthd_buffer_queue_setup,
	.buf_prepare            = fthd_buffer_prepare,
	.buf_cleanup            = fthd_buffer_cleanup,
	.start_streaming        = fthd_start_streaming,
	.stop_streaming         = fthd_stop_streaming,
	.buf_queue              = fthd_buffer_queue,
#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 0, 0)
	.wait_prepare           = vb2_ops_wait_prepare,
	.wait_finish            = vb2_ops_wait_finish,
#endif
};

/*
 * An open file descriptor is what keeps the camera powered: runtime PM parks
 * the ISP whenever nothing has /dev/videoN open, and the reference taken here
 * is what brings it back.  Held across the whole life of the fd rather than
 * just streaming, because every ioctl below talks to the firmware.
 */
static int fthd_v4l2_open(struct file *filp)
{
	struct fthd_private *dev_priv = video_drvdata(filp);
	int ret;

	mutex_lock(&dev_priv->ioctl_lock);
	if (READ_ONCE(dev_priv->removing)) {
		ret = -ENODEV;
		goto out_unlock;
	}

	ret = fthd_pm_get(dev_priv);
	if (ret)
		goto out_unlock;
	if (READ_ONCE(dev_priv->removing)) {
		fthd_pm_put(dev_priv);
		ret = -ENODEV;
		goto out_unlock;
	}

	ret = v4l2_fh_open(filp);
	if (ret)
		fthd_pm_put(dev_priv);

out_unlock:
	mutex_unlock(&dev_priv->ioctl_lock);
	return ret;
}

static int fthd_v4l2_close(struct file *filp)
{
	struct fthd_private *dev_priv = video_drvdata(filp);
	int ret;

	ret = vb2_fop_release(filp);
	fthd_pm_put(dev_priv);

	return ret;
}

static const struct v4l2_file_operations fthd_vdev_fops = {
	.owner          = THIS_MODULE,
	.open           = fthd_v4l2_open,

	.read		= vb2_fop_read,
	.release        = fthd_v4l2_close,
	.poll           = vb2_fop_poll,
	.mmap           = vb2_fop_mmap,
	.unlocked_ioctl = video_ioctl2
};

static int fthd_v4l2_ioctl_enum_input(struct file *filp, void *priv,
				      struct v4l2_input *input)
{
	if (input->index != 0)
		return -EINVAL;

	memset(input, 0, sizeof(*input));
	strscpy(input->name, "Camera", sizeof(input->name));
	input->type = V4L2_INPUT_TYPE_CAMERA;
	input->std = 0;

	return 0;
}

static int fthd_v4l2_ioctl_g_input(struct file *filp, void *priv, unsigned int *i)
{
	*i = 0;
	return 0;
}

static int fthd_v4l2_ioctl_s_input(struct file *filp, void *priv, unsigned int i)
{
	if (i != 0)
		return -EINVAL;
	return 0;
}

static int fthd_v4l2_ioctl_querycap(struct file *filp, void *priv,
				    struct v4l2_capability *cap)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	strscpy(cap->driver, "facetimehd", sizeof(cap->driver));
	strscpy(cap->card, "Apple Facetime HD", sizeof(cap->card));
	snprintf(cap->bus_info, sizeof(cap->bus_info), "PCI:%s",
		 pci_name(dev_priv->pdev));

	cap->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_READWRITE |
			   V4L2_CAP_STREAMING;
	cap->capabilities = cap->device_caps | V4L2_CAP_DEVICE_CAPS;
	return 0;
}

/*
 * NV16 is a single-planar format here: V4L2 defines it as one buffer holding a
 * luma plane followed by an interleaved CbCr plane, so it needs no multiplanar
 * queue - only a second address handed to the ISP, which fthd_buffer_prepare()
 * derives from the one mapping.
 *
 * NV12 is deliberately absent.  The ISP's own output-format codes are known
 * only for the three formats below (NV16 is 0, YUYV 1, YVYU 2); nothing
 * identifies a 4:2:0 code.  Guessing one is not like guessing a command
 * payload, where a wrong value simply gets refused: a buffer sized for 4:2:0
 * at 1.5 bytes per pixel while the ISP still writes 4:2:2 at 2 would have the
 * hardware DMA past the end of the mapping.  It stays out until real hardware
 * can confirm a code.
 */
static bool fthd_format_supported(u32 pixelformat)
{
	return pixelformat == V4L2_PIX_FMT_YUYV ||
	       pixelformat == V4L2_PIX_FMT_YVYU ||
	       pixelformat == V4L2_PIX_FMT_NV16;
}

static int fthd_v4l2_ioctl_enum_fmt_vid_cap(struct file *filp, void *priv,
				   struct v4l2_fmtdesc *fmt)
{
	char *desc = NULL;

	switch (fmt->index) {
	case 0:
		fmt->pixelformat = V4L2_PIX_FMT_YUYV;
		desc = "YUYV";
		break;
	case 1:
		fmt->pixelformat = V4L2_PIX_FMT_YVYU;
		desc = "YVYU";
		break;
	case 2:
		fmt->pixelformat = V4L2_PIX_FMT_NV16;
		desc = "NV16";
		break;
	default:
		return -EINVAL;
	}

	fmt->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	strscpy(fmt->description, desc, sizeof(fmt->description));

	return 0;
}

static int fthd_v4l2_adjust_format(struct fthd_private *dev_priv,
				   struct v4l2_pix_format *pix)
{

	/* Upper bound is the sensor's native resolution (e.g. 1280x720 on
	 * MacBookPro, 848x588 on the 12-inch MacBook); fall back to the generic
	 * ceiling if it hasn't been detected yet. */
	unsigned int max_w = dev_priv->sensor_width  ? : FTHD_MAX_WIDTH;
	unsigned int max_h = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;

	if (!fthd_format_supported(pix->pixelformat))
		pix->pixelformat = V4L2_PIX_FMT_YUYV;

	if (pix->width < FTHD_MIN_WIDTH)
		pix->width = FTHD_MIN_WIDTH;
	if (pix->width > max_w)
		pix->width = max_w;
	if (pix->height < FTHD_MIN_HEIGHT)
		pix->height = FTHD_MIN_HEIGHT;
	if (pix->height > max_h)
		pix->height = max_h;

	pix->colorspace = V4L2_COLORSPACE_SRGB;
	pix->field = V4L2_FIELD_NONE;
	pix->width = ALIGN(pix->width, 8);
	if (pix->width > max_w)
		pix->width = round_down(max_w, 8);

	switch (pix->pixelformat) {
	case V4L2_PIX_FMT_NV16:
		/* Semi-planar 4:2:2: a width*height luma plane followed by an
		 * interleaved CbCr plane of the same size.  Both live in the
		 * one buffer, so sizeimage covers both. */
		pix->bytesperline = pix->width;
		pix->sizeimage = pix->bytesperline * pix->height * 2;
		break;
	case V4L2_PIX_FMT_YUYV:
	case V4L2_PIX_FMT_YVYU:
	default:
		pix->bytesperline = pix->width * 2;
		pix->sizeimage = pix->bytesperline * pix->height;
		break;
	}

	return 0;
}

static int fthd_v4l2_ioctl_try_fmt_vid_cap(struct file *filp, void *_priv,
					   struct v4l2_format *fmt)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	pr_debug("%s: %dx%d\n", __func__, fmt->fmt.pix.width, fmt->fmt.pix.height);

	if (fmt->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	return fthd_v4l2_adjust_format(dev_priv, &fmt->fmt.pix);
}

static int fthd_v4l2_ioctl_g_fmt_vid_cap(struct file *filp, void *priv,
					 struct v4l2_format *fmt)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	pr_debug("%s\n", __func__);
	fmt->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	fmt->fmt.pix = dev_priv->fmt.fmt;

	return 0;
}

static int fthd_v4l2_ioctl_s_fmt_vid_cap(struct file *filp, void *priv,
					 struct v4l2_format *fmt)
{
	struct fthd_private *dev_priv = video_drvdata(filp);
	int ret;

	if (fmt->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	/* Existing buffers were allocated for the old size.  Reconfiguring the
	 * firmware while they remain mapped would let it DMA past those mappings. */
	if (vb2_is_busy(&dev_priv->vb2_queue))
		return -EBUSY;

	ret = fthd_v4l2_adjust_format(dev_priv, &fmt->fmt.pix);
	if (ret)
		return ret;

	pr_debug("%c%c%c%c\n", fmt->fmt.pix.pixelformat, fmt->fmt.pix.pixelformat >> 8,
		 fmt->fmt.pix.pixelformat >> 16, fmt->fmt.pix.pixelformat >> 24);

	dev_priv->fmt.fmt = fmt->fmt.pix;

	switch (fmt->fmt.pix.pixelformat) {
	case V4L2_PIX_FMT_NV16:
		dev_priv->fmt.planes = 2;
		break;
	case V4L2_PIX_FMT_YUYV:
	case V4L2_PIX_FMT_YVYU:
		dev_priv->fmt.planes = 1;
		break;
	}

	return 0;
}


static int fthd_v4l2_ioctl_g_parm(struct file *filp, void *priv,
		struct v4l2_streamparm *parm)
{
	/* Report a consistent 30 fps, matching what the sensor actually delivers
	 * and what enum_frameintervals advertises. The old frametime/1000 value
	 * (25 fps) disagreed with the real 30 fps rate, which made GStreamer's
	 * pipewiresrc compute negative frame durations and stall after one frame
	 * (e.g. GNOME Snapshot froze, while ffplay/v4l2-ctl were unaffected). */
	struct v4l2_fract timeperframe = {
		.numerator = 1,
		.denominator = FTHD_FPS,
	};

	if (parm->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	parm->parm.capture.readbuffers = FTHD_BUFFERS;
	parm->parm.capture.capability = V4L2_CAP_TIMEPERFRAME;
	parm->parm.capture.timeperframe = timeperframe;
	return 0;
}

static int fthd_v4l2_ioctl_s_parm(struct file *filp, void *priv,
		struct v4l2_streamparm *parm)
{
	if (parm->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	/* The sensor runs at one rate, so there is nothing to select: report
	 * back what will actually be delivered.  Storing the requested interval
	 * in dev_priv->frametime, as this used to, made S_PARM disagree with
	 * the G_PARM immediately following it. */
	return fthd_v4l2_ioctl_g_parm(filp, priv, parm);
}

static int fthd_v4l2_ioctl_enum_framesizes(struct file *filp, void *priv,
		struct v4l2_frmsizeenum *sizes)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	if (sizes->index)
		return -EINVAL;

	if (!fthd_format_supported(sizes->pixel_format))
		return -EINVAL;

	/* The ISP scales, so every size TRY_FMT accepts has to be enumerated,
	 * not just the sensor's native one.  The bounds and the width step must
	 * match fthd_v4l2_adjust_format() exactly. */
	sizes->type = V4L2_FRMSIZE_TYPE_STEPWISE;
	sizes->stepwise.min_width   = FTHD_MIN_WIDTH;
	sizes->stepwise.max_width   = round_down(dev_priv->sensor_width ? : FTHD_MAX_WIDTH, 8);
	sizes->stepwise.step_width  = 8;
	sizes->stepwise.min_height  = FTHD_MIN_HEIGHT;
	sizes->stepwise.max_height  = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;
	sizes->stepwise.step_height = 1;

	return 0;
}

static int fthd_v4l2_ioctl_enum_frameintervals(struct file *filp, void *priv,
		struct v4l2_frmivalenum *interval)
{
	struct fthd_private *dev_priv = video_drvdata(filp);
	unsigned int max_w = dev_priv->sensor_width  ? : FTHD_MAX_WIDTH;
	unsigned int max_h = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;

	pr_debug("%s\n", __func__);

	if (interval->index)
		return -EINVAL;

	/* Must agree with ENUM_FMT, or this advertises an interval for a format
	 * the device does not offer. */
	if (!fthd_format_supported(interval->pixel_format))
		return -EINVAL;

	if (interval->width & 7
	    || interval->width < FTHD_MIN_WIDTH
	    || interval->width > round_down(max_w, 8)
	    || interval->height < FTHD_MIN_HEIGHT
	    || interval->height > max_h)
		return -EINVAL;

	interval->type = V4L2_FRMIVAL_TYPE_DISCRETE;
	interval->discrete.numerator = 1;
	interval->discrete.denominator = FTHD_FPS;

	return 0;
}

/*
 * The ISP crops the full sensor array and scales the result to the negotiated
 * format (see fthd_start_channel()), so the crop rectangle is fixed at the
 * sensor's native size and there is nothing for S_SELECTION to select.  It is
 * still worth reporting: without G_SELECTION an application cannot learn the
 * sensor's real dimensions or pixel aspect, and v4l2-compliance flags a
 * capture device that answers neither G_SELECTION nor the legacy CROPCAP.
 */
static int fthd_v4l2_ioctl_g_selection(struct file *filp, void *priv,
		struct v4l2_selection *sel)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	if (sel->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
	case V4L2_SEL_TGT_CROP_DEFAULT:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		sel->r.left = 0;
		sel->r.top = 0;
		sel->r.width  = dev_priv->sensor_width  ? : FTHD_MAX_WIDTH;
		sel->r.height = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;
		return 0;
	default:
		return -EINVAL;
	}
}

static int fthd_v4l2_ioctl_subscribe_event(struct v4l2_fh *fh,
		const struct v4l2_event_subscription *sub)
{
	switch (sub->type) {
	case V4L2_EVENT_CTRL:
		return v4l2_ctrl_subscribe_event(fh, sub);
	}

	return -EINVAL;
}

static const struct v4l2_ioctl_ops fthd_ioctl_ops = {
	.vidioc_enum_input      = fthd_v4l2_ioctl_enum_input,
	.vidioc_g_input         = fthd_v4l2_ioctl_g_input,
	.vidioc_s_input         = fthd_v4l2_ioctl_s_input,
	.vidioc_enum_fmt_vid_cap = fthd_v4l2_ioctl_enum_fmt_vid_cap,
	.vidioc_try_fmt_vid_cap = fthd_v4l2_ioctl_try_fmt_vid_cap,

	.vidioc_g_fmt_vid_cap   = fthd_v4l2_ioctl_g_fmt_vid_cap,
	.vidioc_s_fmt_vid_cap   = fthd_v4l2_ioctl_s_fmt_vid_cap,
	.vidioc_querycap        = fthd_v4l2_ioctl_querycap,


        .vidioc_reqbufs         = vb2_ioctl_reqbufs,
	/*
	 * No .vidioc_create_bufs.  CREATE_BUFS asks for buffers *in addition*
	 * to those already allocated, and dev_priv->h2t_bufs is a fixed array
	 * of FTHD_BUFFERS slots, so the pool cannot grow past four however it
	 * is asked.  fthd_buffer_queue_setup() overwrote the caller's count
	 * with its own instead of failing, which meant CREATE_BUFS silently
	 * returned a different number of buffers than it was asked for -
	 * five v4l2-compliance failures, all this one cause.
	 *
	 * REQBUFS is the supported way to size the queue here.  An optional
	 * ioctl reported as unsupported is correct; one that lies is not.
	 */
	.vidioc_querybuf        = vb2_ioctl_querybuf,
	.vidioc_qbuf            = vb2_ioctl_qbuf,
	.vidioc_dqbuf           = vb2_ioctl_dqbuf,
	.vidioc_expbuf          = vb2_ioctl_expbuf,
	.vidioc_streamon        = vb2_ioctl_streamon,
	.vidioc_streamoff       = vb2_ioctl_streamoff,

	.vidioc_g_parm          = fthd_v4l2_ioctl_g_parm,
	.vidioc_s_parm          = fthd_v4l2_ioctl_s_parm,
	.vidioc_enum_framesizes = fthd_v4l2_ioctl_enum_framesizes,
	.vidioc_enum_frameintervals = fthd_v4l2_ioctl_enum_frameintervals,

	.vidioc_g_selection     = fthd_v4l2_ioctl_g_selection,

	.vidioc_subscribe_event	= fthd_v4l2_ioctl_subscribe_event,
	.vidioc_unsubscribe_event = v4l2_event_unsubscribe,

	.vidioc_log_status      = v4l2_ctrl_log_status,
};

/*
 * Auto-cluster member indices.  v4l2_ctrl_auto_cluster() hands s_ctrl the
 * leader whenever any member changes, so the manual values are read out of
 * ctrl->cluster[] rather than from ctrl->val.
 */
enum {
	FTHD_EXP_AUTO,
	FTHD_EXP_ABSOLUTE,
	FTHD_EXP_GAIN,
	FTHD_EXP_NUM,
};

enum {
	FTHD_WB_AUTO,
	FTHD_WB_TEMPERATURE,
	FTHD_WB_NUM,
};

/* Exposure compensation offered as +/-2 EV in thirds, in milli-EV. */
static const s64 fthd_exposure_bias_menu[] = {
	-2000, -1667, -1333, -1000, -667, -333,
	0,
	333, 667, 1000, 1333, 1667, 2000,
};
#define FTHD_EXPOSURE_BIAS_DEF 6

/*
 * The sensor's own pattern generator, which is worth having because it is the
 * one way to tell "the sensor or firmware is not producing frames" apart from
 * "the ring, the IOMMU mapping or buffer return is broken" without needing a
 * lit room or anything in front of the camera.  Only "Disabled" is known to be
 * accepted; the firmware refuses a pattern index it does not implement, which
 * surfaces as an error from S_CTRL.
 */
static const char * const fthd_test_pattern_menu[] = {
	"Disabled",
	"Sensor Pattern 1",
	"Sensor Pattern 2",
	"Sensor Pattern 3",
};

/*
 * Selecting V4L2_EXPOSURE_MANUAL used to be a dead end: the menu offered it,
 * but nothing existed to set once AE was stopped, so it just froze the
 * exposure wherever AE happened to leave it.  Integration time and gain are
 * separate ISP state, so replaying both is order-independent.
 */
static int fthd_set_exposure(struct fthd_private *dev_priv, struct v4l2_ctrl *ctrl)
{
	bool manual = ctrl->val == V4L2_EXPOSURE_MANUAL;
	int ret;

	ret = fthd_isp_cmd_channel_ae(dev_priv, 0, !manual);
	if (ret || !manual)
		return ret;

	/* V4L2_CID_EXPOSURE_ABSOLUTE counts in 100us units. */
	ret = fthd_isp_cmd_channel_ae_integration_time_set(dev_priv, 0,
			ctrl->cluster[FTHD_EXP_ABSOLUTE]->val * 100);
	if (ret)
		return ret;

	return fthd_isp_cmd_channel_ae_gain_set(dev_priv, 0,
			ctrl->cluster[FTHD_EXP_GAIN]->val);
}

/*
 * The same dead end on the white-balance side: AUTO_WHITE_BALANCE could be
 * switched off with nothing to set afterwards.
 *
 * Only the colour temperature is offered, deliberately.  The ISP also has
 * CISP_CMD_CH_AWB_1ST_GAIN_MANUAL, but the CCT and the per-channel gains are
 * two ways of writing the same white-balance state - exposing both would put
 * two controls in this cluster whose replay order decides which one wins, and
 * v4l2_ctrl_handler_setup() replays every member on each runtime-PM cycle.
 * One unambiguous control beats two that quietly fight.
 */
static int fthd_set_white_balance(struct fthd_private *dev_priv, struct v4l2_ctrl *ctrl)
{
	bool manual = !ctrl->val;
	int ret;

	ret = fthd_isp_cmd_channel_awb(dev_priv, 0, !manual);
	if (ret || !manual)
		return ret;

	return fthd_isp_cmd_channel_awb_cct_manual(dev_priv, 0,
			ctrl->cluster[FTHD_WB_TEMPERATURE]->val);
}

static int fthd_s_ctrl(struct v4l2_ctrl *ctrl)
{
	struct fthd_private *dev_priv = container_of(ctrl->handler, struct fthd_private, v4l2_ctrl_handler);
	int ret;

	pr_debug("id = %x, val = %d\n", ctrl->id, ctrl->val);

	/* The ISP rejects these while the channel is down.  The control
	 * framework has already stored the new value, and
	 * fthd_start_streaming() replays the whole handler once the channel is
	 * up, so accepting it here is what makes a control set before
	 * STREAMON take effect rather than fail. */
	if (!dev_priv->channel_running)
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_CONTRAST:
		ret = fthd_isp_cmd_channel_contrast_set(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_BRIGHTNESS:
		ret = fthd_isp_cmd_channel_brightness_set(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_SATURATION:
		ret = fthd_isp_cmd_channel_saturation_set(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_HUE:
		ret = fthd_isp_cmd_channel_hue_set(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_AUTO_WHITE_BALANCE:
		/* This fell through to default: without a break, which happened
		 * to preserve ret only because default: does nothing. */
		ret = fthd_set_white_balance(dev_priv, ctrl);
		break;
	case V4L2_CID_POWER_LINE_FREQUENCY:
		ret = fthd_isp_cmd_channel_ae_flicker_freq_set(dev_priv, 0,
				ctrl->val == V4L2_CID_POWER_LINE_FREQUENCY_50HZ ? 50 :
				ctrl->val == V4L2_CID_POWER_LINE_FREQUENCY_60HZ ? 60 : 0);
		break;
	case V4L2_CID_EXPOSURE_AUTO:
		ret = fthd_set_exposure(dev_priv, ctrl);
		break;
	case V4L2_CID_AUTO_EXPOSURE_BIAS:
		/* An integer menu: ctrl->val is the menu index, and the value
		 * the user actually asked for is qmenu_int[] at that index. */
		ret = fthd_isp_cmd_channel_ae_bias_set(dev_priv, 0,
				ctrl->qmenu_int[ctrl->val]);
		break;
	case V4L2_CID_EXPOSURE_METERING:
		/* The V4L2 menu and the ISP's mode numbering coincide, and
		 * MATRIX is 3 - the value fthd_start_channel() used to pin. */
		ret = fthd_isp_cmd_channel_ae_metering_mode_set(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_SHARPNESS:
		ret = fthd_isp_cmd_channel_sharpness_set(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_TEST_PATTERN:
		ret = fthd_isp_cmd_channel_test_pattern_config(dev_priv, 0, ctrl->val);
		break;
	default:
		return -EINVAL;
	}

	pr_debug("ret = %d\n", ret);
	return ret;
}

/*
 * No .g_volatile_ctrl: none of these controls is volatile, so the framework
 * answers G_CTRL from its own cached value.  The stub that used to be here
 * returned -EINVAL unconditionally, which would have made every read fail had
 * anything ever marked a control volatile.
 */
static const struct v4l2_ctrl_ops fthd_ctrl_ops = {
	.s_ctrl = fthd_s_ctrl,
};

static void fthd_video_device_release(struct video_device *vdev)
{
	struct fthd_private *dev_priv = video_get_drvdata(vdev);

	video_device_release(vdev);
	fthd_put(dev_priv);
}

int fthd_v4l2_register(struct fthd_private *dev_priv)
{
	struct v4l2_device *v4l2_dev = &dev_priv->v4l2_dev;
	struct v4l2_ctrl *exp_cluster[FTHD_EXP_NUM];
	struct v4l2_ctrl *wb_cluster[FTHD_WB_NUM];
	struct video_device *vdev;
	struct vb2_queue *q;
	int ret;

	ret = v4l2_device_register(&dev_priv->pdev->dev, v4l2_dev);
	if (ret) {
		dev_err(&dev_priv->pdev->dev, "v4l2_device_register: %d\n", ret);
		return ret;
	}

	vdev = video_device_alloc();
	if (!vdev) {
		ret = -ENOMEM;
		goto fail;
	}
	/* The video_device can outlive PCI unbind while an fd remains open. */
	if (WARN_ON_ONCE(!fthd_get(dev_priv))) {
		video_device_release(vdev);
		ret = -ENODEV;
		goto fail;
	}
	vdev->release = fthd_video_device_release;
	dev_priv->videodev = vdev;

	q = &dev_priv->vb2_queue;
	q->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	q->io_modes = VB2_MMAP | VB2_USERPTR | VB2_DMABUF | VB2_READ;
	q->drv_priv = dev_priv;
	q->ops = &vb2_queue_ops;
	q->mem_ops = &vb2_dma_sg_memops;
	q->timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC;
	q->dev = &dev_priv->pdev->dev;
#if LINUX_VERSION_CODE < KERNEL_VERSION(6,8,0)
	q->min_buffers_needed = 1;
#else
	q->min_queued_buffers = 1;
#endif
	q->lock = &dev_priv->ioctl_lock;

	ret = vb2_queue_init(q);
	if (ret)
		goto fail_vdev_alloc;

	v4l2_ctrl_handler_init(&dev_priv->v4l2_ctrl_handler, 14);
	v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			  V4L2_CID_BRIGHTNESS, 0, 0xff, 1, 0x80);
	v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			  V4L2_CID_CONTRAST, 0, 0xff, 1, 0x80);
	v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			  V4L2_CID_SATURATION, 0, 0xff, 1, 0x80);
	v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			  V4L2_CID_HUE, 0, 0xff, 1, 0x80);
	v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			  V4L2_CID_SHARPNESS, 0, 0xff, 1, 0x80);
	/* Anti-banding.  Defaults to disabled so the ISP keeps the behaviour it
	 * has always had unless the user asks for their mains frequency. */
	v4l2_ctrl_new_std_menu(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			       V4L2_CID_POWER_LINE_FREQUENCY,
			       V4L2_CID_POWER_LINE_FREQUENCY_60HZ, 0,
			       V4L2_CID_POWER_LINE_FREQUENCY_DISABLED);
	/* Defaults to the mode fthd_start_channel() used to pin unconditionally,
	 * so the out-of-the-box metering behaviour is unchanged. */
	v4l2_ctrl_new_std_menu(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			       V4L2_CID_EXPOSURE_METERING,
			       V4L2_EXPOSURE_METERING_MATRIX, 0,
			       V4L2_EXPOSURE_METERING_MATRIX);
	/* Exposure compensation, which unlike the manual cluster below stays
	 * useful with AE running - the fix for being backlit. */
	v4l2_ctrl_new_int_menu(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			       V4L2_CID_AUTO_EXPOSURE_BIAS,
			       ARRAY_SIZE(fthd_exposure_bias_menu) - 1,
			       FTHD_EXPOSURE_BIAS_DEF, fthd_exposure_bias_menu);
	v4l2_ctrl_new_std_menu_items(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
				     V4L2_CID_TEST_PATTERN,
				     ARRAY_SIZE(fthd_test_pattern_menu) - 1, 0, 0,
				     fthd_test_pattern_menu);

	/* SHUTTER_PRIORITY and APERTURE_PRIORITY are not offered: this sensor
	 * has neither a controllable shutter nor an aperture, only AE
	 * start/stop. */
	exp_cluster[FTHD_EXP_AUTO] =
		v4l2_ctrl_new_std_menu(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
				       V4L2_CID_EXPOSURE_AUTO,
				       V4L2_EXPOSURE_MANUAL, 0,
				       V4L2_EXPOSURE_AUTO);
	/* One frame at FTHD_FPS is the longest integration the sensor can be
	 * given, and V4L2_CID_EXPOSURE_ABSOLUTE counts in 100us units. */
	exp_cluster[FTHD_EXP_ABSOLUTE] =
		v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
				  V4L2_CID_EXPOSURE_ABSOLUTE, 1,
				  10000 / FTHD_FPS, 1, 100);
	exp_cluster[FTHD_EXP_GAIN] =
		v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
				  V4L2_CID_GAIN, 0, 0xff, 1, 0);

	wb_cluster[FTHD_WB_AUTO] =
		v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
				  V4L2_CID_AUTO_WHITE_BALANCE, 0, 1, 1, 1);
	wb_cluster[FTHD_WB_TEMPERATURE] =
		v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
				  V4L2_CID_WHITE_BALANCE_TEMPERATURE,
				  2000, 10000, 50, 5000);

	if (dev_priv->v4l2_ctrl_handler.error) {
		dev_err(&dev_priv->pdev->dev, "failed to setup control handlers\n");
		ret = dev_priv->v4l2_ctrl_handler.error;
		v4l2_ctrl_handler_free(&dev_priv->v4l2_ctrl_handler);
		goto fail_queue;
	}

	/* Only safe once the error check above has confirmed every member was
	 * actually created.  The manual controls are marked inactive while
	 * their leader is in auto, which is what stops an application from
	 * setting an exposure the ISP is about to overwrite. */
	v4l2_ctrl_auto_cluster(FTHD_EXP_NUM, &exp_cluster[FTHD_EXP_AUTO],
			       V4L2_EXPOSURE_MANUAL, false);
	v4l2_ctrl_auto_cluster(FTHD_WB_NUM, &wb_cluster[FTHD_WB_AUTO], 0, false);
	vdev->v4l2_dev = v4l2_dev;
	strscpy(vdev->name, "Apple Facetime HD", sizeof(vdev->name));
	vdev->vfl_dir = VFL_DIR_RX;
	vdev->lock = &dev_priv->ioctl_lock;
	vdev->fops = &fthd_vdev_fops;
	vdev->ioctl_ops = &fthd_ioctl_ops;
	vdev->queue = q;
	vdev->ctrl_handler = &dev_priv->v4l2_ctrl_handler;
	vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_READWRITE |
			    V4L2_CAP_STREAMING;
	video_set_drvdata(vdev, dev_priv);

	/* Initialise every field visible through G_FMT before publishing the
	 * device node: userspace may open it as soon as registration succeeds. */
	dev_priv->fmt.fmt.width = dev_priv->sensor_width ? : FTHD_MAX_WIDTH;
	dev_priv->fmt.fmt.height = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;
	dev_priv->fmt.fmt.pixelformat = V4L2_PIX_FMT_YUYV;
	dev_priv->fmt.planes = 1;
	fthd_v4l2_adjust_format(dev_priv, &dev_priv->fmt.fmt);

	ret = video_register_device(vdev, VFL_TYPE_VIDEO, -1);
	if (ret) {
		vdev->release(vdev);
		vdev = NULL;
		dev_priv->videodev = NULL;
		goto fail_ctrl;
	}
	WRITE_ONCE(dev_priv->v4l2_registered, true);

	return 0;
fail_ctrl:
	v4l2_ctrl_handler_free(&dev_priv->v4l2_ctrl_handler);
fail_queue:
	vb2_queue_release(q);
fail_vdev_alloc:
	if (vdev)
		vdev->release(vdev);
fail:
	dev_priv->videodev = NULL;
	v4l2_device_unregister(&dev_priv->v4l2_dev);
	return ret;
}

void fthd_v4l2_unregister(struct fthd_private *dev_priv)
{
	struct video_device *vdev = dev_priv->videodev;

	if (!vdev)
		return;

	WRITE_ONCE(dev_priv->v4l2_registered, false);
	v4l2_device_disconnect(&dev_priv->v4l2_dev);
	vb2_video_unregister_device(vdev);
	dev_priv->videodev = NULL;
	v4l2_ctrl_handler_free(&dev_priv->v4l2_ctrl_handler);
	v4l2_device_unregister(&dev_priv->v4l2_dev);
}
