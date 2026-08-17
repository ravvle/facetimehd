/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * FacetimeHD camera driver - sensor die temperature
 *
 * The ISP has a CISP_CMD_CH_SENSOR_TEMPERATURE_GET opcode.  Apple documents
 * the opcode's name and nothing else, so the *scale* of what it returns is
 * unknown: celsius, deci-celsius and a raw sensor code are all plausible.
 *
 * hwmon has no way to express that uncertainty - temp1_input is millidegrees
 * celsius by definition, and a number in the wrong scale there is not a
 * caveat, it is a wrong reading in every monitoring tool on the system.  So
 * this file publishes a reading only when the firmware returns something that
 * can only sensibly be celsius, and refuses with -EIO otherwise.  The raw
 * value is always available through debugfs, which is where someone working
 * out the real scale should look; see DOWNSTREAM.md.
 */

#include <linux/hwmon.h>
#include <linux/kernel.h>
#include "fthd_drv.h"
#include "fthd_hwmon.h"
#include "fthd_isp.h"

/*
 * The window a reading has to fall in to be published as celsius.  A camera
 * sensor in a laptop cannot be below ambient-in-a-freezer or above the point
 * where the silicon stops working, so a value outside this is evidence that
 * the scale is not celsius rather than evidence of a very cold camera.
 */
#define FTHD_TEMP_MIN_C (-40)
#define FTHD_TEMP_MAX_C 125

int fthd_hwmon_read_raw(struct fthd_private *dev_priv, s32 *raw)
{
	int ret;

	mutex_lock(&dev_priv->ioctl_lock);
	if (READ_ONCE(dev_priv->removing)) {
		ret = -ENODEV;
		goto out_unlock;
	}

	/* Powers the camera up if it is runtime-suspended, exactly as a debugfs
	 * read does.  A monitoring daemon polling this will therefore keep the
	 * camera awake - the same documented trade-off the debugfs accessors
	 * make, and the reason this is not a volatile V4L2 control. */
	ret = fthd_pm_get(dev_priv);
	if (ret)
		goto out_unlock;

	ret = fthd_isp_cmd_channel_sensor_temperature(dev_priv, 0, raw);

	fthd_pm_put(dev_priv);
out_unlock:
	mutex_unlock(&dev_priv->ioctl_lock);
	return ret;
}

static umode_t fthd_hwmon_is_visible(const void *data,
				     enum hwmon_sensor_types type,
				     u32 attr, int channel)
{
	if (type == hwmon_temp && attr == hwmon_temp_input)
		return 0444;
	return 0;
}

static int fthd_hwmon_read(struct device *dev, enum hwmon_sensor_types type,
			   u32 attr, int channel, long *val)
{
	struct fthd_private *dev_priv = dev_get_drvdata(dev);
	s32 raw;
	int ret;

	if (type != hwmon_temp || attr != hwmon_temp_input)
		return -EOPNOTSUPP;

	ret = fthd_hwmon_read_raw(dev_priv, &raw);
	if (ret)
		return ret;

	if (raw < FTHD_TEMP_MIN_C || raw > FTHD_TEMP_MAX_C) {
		/* Rate-limited rather than silent: this is the one message that
		 * tells someone the scale needs working out, and it carries the
		 * value they need to do it. */
		dev_warn_ratelimited(&dev_priv->pdev->dev,
				     "sensor temperature %d is not plausible celsius; not reporting it (see DOWNSTREAM.md)\n",
				     raw);
		return -EIO;
	}

	*val = raw * 1000;
	return 0;
}

static const struct hwmon_channel_info * const fthd_hwmon_info[] = {
	HWMON_CHANNEL_INFO(temp, HWMON_T_INPUT),
	NULL,
};

static const struct hwmon_ops fthd_hwmon_ops = {
	.is_visible = fthd_hwmon_is_visible,
	.read = fthd_hwmon_read,
};

static const struct hwmon_chip_info fthd_hwmon_chip_info = {
	.ops = &fthd_hwmon_ops,
	.info = fthd_hwmon_info,
};

/*
 * Failure is not fatal: a camera without a temperature reading is a working
 * camera, so this warns and lets probe carry on.
 */
void fthd_hwmon_register(struct fthd_private *dev_priv)
{
	struct device *hwmon;

	/* "facetimehd" is not a valid hwmon name - the core rejects any name
	 * containing '-' or whitespace, and requires it to be usable as a
	 * sysfs attribute value. */
	hwmon = devm_hwmon_device_register_with_info(&dev_priv->pdev->dev,
						     "facetimehd", dev_priv,
						     &fthd_hwmon_chip_info,
						     NULL);
	if (IS_ERR(hwmon)) {
		dev_warn(&dev_priv->pdev->dev,
			 "could not register hwmon device: %ld\n",
			 PTR_ERR(hwmon));
		return;
	}

	dev_priv->hwmon = hwmon;
}
