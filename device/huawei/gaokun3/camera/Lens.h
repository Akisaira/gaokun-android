/* SPDX-License-Identifier: Apache-2.0 */
/*
 * gaokun3 相机 HAL —— VCM（对焦马达）直驱。
 *
 * ★ 为什么是"直驱"而不是走 libcamera：
 *   libcamera 侧的 LensPosition 控制【只有定义、没有实现】——
 *   全树 grep 只命中 src/libcamera/control_ids_core.yaml，
 *   src/libcamera/ 里没有任何 pipeline 处理它（simple pipeline 连 lens 字样都没有）。
 *   也就是说 libcamera 不会替我们把镜头位置写下去。
 *   而内核已经把马达暴露成一个独立的 v4l2 子设备：
 *       /sys/class/video4linux/v4l-subdevN/name = "dw9714 1-000c"
 *   所以最短的路是本 HAL 自己 open /dev/v4l-subdevN，用 VIDIOC_S_CTRL 写
 *   V4L2_CID_FOCUS_ABSOLUTE。
 *
 *   SELinux 已经放行（不用改 policy）：
 *     system/sepolicy/private/hal_camera.te:
 *       allow hal_camera video_device:chr_file rw_file_perms;
 *   而本服务跑在 hal_camera_default 域（vendor/hal_camera_default.te:
 *   hal_server_domain(hal_camera_default, hal_camera)）。
 *   设备节点权限来自 ueventd.rc（/dev/v4l-subdev* 0660 root camera），
 *   服务的 group 里有 camera（gaokun3-camera.rc）。
 *
 * ⚠️ 节点编号（v4l-subdev46）会随开机探测顺序变，必须【按名字找】，不能写死。
 * ⚠️ dw9714 驱动的电源在 s_stream() 里用 pm_runtime 管 —— 不 streamon 就写
 *    控件，i2c 写会静默失败（马达不动、但不报错）。所以 open() 里要 streamon。
 */
#pragma once

#include <string>

namespace gaokun3 {

class Lens {
public:
	/* 只找节点（不打开、不改状态）：给 Device::init() 判断有没有马达用。 */
	static std::string findNode();

	/* 打开 + 查控件范围 + streamon 上电 + 归位到中间位置。 */
	bool open();
	void close();

	bool setPosition(int pos);
	int position() const { return pos_; }
	int minPos() const { return min_; }
	int maxPos() const { return max_; }
	bool ready() const { return fd_ >= 0; }
	const std::string &node() const { return node_; }

	/* 一次写失败后的退避：连续失败到一定次数就不再骚扰内核（半路坏掉的马达
	 * 不该把每帧的完成路径拖慢）。 */
	bool usable() const { return fd_ >= 0 && errors_ < kMaxErrors; }

private:
	static constexpr int kMaxErrors = 5;

	int fd_ = -1;
	std::string node_;
	int min_ = 0, max_ = 1023, step_ = 1;
	int pos_ = 0;
	int errors_ = 0;
};

} /* namespace gaokun3 */
