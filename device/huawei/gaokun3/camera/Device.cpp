/* SPDX-License-Identifier: Apache-2.0 */
#include "Device.h"
#include "Provider.h"
#include "Session.h"

#include <cstdlib>
#include <fcntl.h>
#include <unistd.h>

#include <sys/system_properties.h>   /* __system_property_get：仅用于方向标定的调试覆盖 */

#include <aidl/android/hardware/camera/common/CameraResourceCost.h>
#include <aidl/android/hardware/camera/common/Status.h>
#include <aidl/android/hardware/camera/common/TorchModeStatus.h>
#include <aidl/android/hardware/camera/device/ICameraDeviceCallback.h>
#include <aidl/android/hardware/camera/device/ICameraDeviceSession.h>
#include <aidl/android/hardware/camera/device/ICameraInjectionSession.h>
#include <log/log.h>

#include <libcamera/property_ids.h>
#include <libcamera/stream.h>

using ::aidl::android::hardware::camera::common::CameraResourceCost;
using ::aidl::android::hardware::camera::common::Status;
using ::aidl::android::hardware::camera::common::TorchModeStatus;
using ::aidl::android::hardware::camera::device::CameraMetadata;
using ::aidl::android::hardware::camera::device::ICameraDeviceCallback;
using ::aidl::android::hardware::camera::device::ICameraDeviceSession;
using ::aidl::android::hardware::camera::device::ICameraInjectionSession;
using ::aidl::android::hardware::camera::device::RequestTemplate;
using ::aidl::android::hardware::camera::device::StreamConfiguration;

namespace gaokun3 {

namespace {
ndk::ScopedAStatus err(Status s)
{
	return ndk::ScopedAStatus::fromServiceSpecificError(static_cast<int32_t>(s));
}

/* 后摄闪光灯在内核里的名字（patches/0036：PM8350C 闪光模块 1+4 路 → 一个 LED）。 */
constexpr char kRearFlashLed[] = "/sys/class/leds/white:flash";

bool writeSysfs(const std::string &path, const std::string &value)
{
	int fd = open(path.c_str(), O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		ALOGE("打不开 %s: %s", path.c_str(), strerror(errno));
		return false;
	}
	ssize_t n = write(fd, value.c_str(), value.size());
	close(fd);
	if (n != static_cast<ssize_t>(value.size())) {
		ALOGE("写 %s 失败: %s", path.c_str(), strerror(errno));
		return false;
	}
	return true;
}

std::string readSysfs(const std::string &path)
{
	char buf[64] = {};
	int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return {};
	ssize_t n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return {};
	std::string s(buf, static_cast<size_t>(n));
	while (!s.empty() && (s.back() == '\n' || s.back() == ' '))
		s.pop_back();
	return s;
}
} /* namespace */

Device::Device(std::shared_ptr<libcamera::Camera> cam, std::string name, Provider *provider)
	: cam_(std::move(cam)), name_(std::move(name)), provider_(provider)
{
}

Device::~Device() = default;

bool Device::init()
{
	const libcamera::ControlList &props = cam_->properties();

	/* ── 传感器阵列尺寸 ── */
	auto pixelArray = props.get(libcamera::properties::PixelArraySize);
	if (pixelArray) {
		facts_.pixelArrayW = pixelArray->width;
		facts_.pixelArrayH = pixelArray->height;
	} else {
		ALOGW("相机没有报 PixelArraySize");
	}

	/* 有效区优先用 PixelArrayActiveAreas，没有就退回全阵列。 */
	auto active = props.get(libcamera::properties::PixelArrayActiveAreas);
	if (active && !active->empty()) {
		facts_.activeW = (*active)[0].width;
		facts_.activeH = (*active)[0].height;
	} else {
		facts_.activeW = facts_.pixelArrayW;
		facts_.activeH = facts_.pixelArrayH;
	}
	if (facts_.activeW <= 0 || facts_.activeH <= 0) {
		ALOGE("拿不到有效的传感器尺寸（%dx%d）", facts_.activeW, facts_.activeH);
		return false;
	}

	/* ── 朝向 ── */
	auto loc = props.get(libcamera::properties::Location);
	facts_.frontFacing = !loc || *loc == libcamera::properties::CameraLocationFront;

	/*
	 * ⚠️★★ 两个"方向"的约定是【相反的】，直接抄数值会差 180°。
	 *
	 *   libcamera properties::Rotation = 传感器相对机身的【物理安装角】，
	 *     用【逆时针】表达（property_ids 原文："the angular difference in the
	 *     counter-clockwise direction between the camera reference system 'Rc'
	 *     and the projected scene reference system 'Rp'"；内核
	 *     Documentation/devicetree/bindings/media/video-interface-devices.yaml
	 *     的 rotation 属性是同一套文字，libcamera 从这里继承 ——
	 *     camera_sensor_legacy.cpp 读的就是 V4L2_CID_CAMERA_SENSOR_ROTATION，
	 *     而那个控件由驱动 v4l2_ctrl_new_fwnode_properties() 从设备树填）。
	 *
	 *   ANDROID_SENSOR_ORIENTATION = 把输出图像转正所需的【顺时针】角。
	 *
	 *   ⇒ android = (360 - rotation) % 360。上游 libcamera 自己的 Android HAL
	 *     就是这么算的（src/android/camera_device.cpp）：
	 *       "The Android orientation metadata specifies its rotation correction
	 *        value in clockwise direction whereas libcamera specifies the
	 *        rotation property in anticlockwise direction."
	 *
	 *   ★ 本机设备树：后摄 180（2026-09-24 用户目视确认，patches/0049 只去掉了 FIXME）、
	 *     前摄 0（待目视）⇒ SENSOR_ORIENTATION 后 180 / 前 0。0 和 180 在这个换算下自反，
	 *     所以换算方向错了在本机看不出来 —— 一旦哪颗标成 90/270，错了就立刻差 180°。
	 *     ⚠️ PR #6 描述里的"前 90 / 后 270"与目视结论相反，别照它改。
	 */
	auto rot = props.get(libcamera::properties::Rotation);
	const int32_t rawRotation = rot ? *rot : 0;
	if (!rot)
		ALOGW("libcamera 没报 Rotation 属性，按 0° 处理"
		      "（到 /dev/v4l-subdev* 上查 camera_sensor_rotation 控件）");
	int32_t ccw = ((rawRotation % 360) + 360) % 360;

	/*
	 * ★ 调试覆盖：用系统属性顶掉设备树的值，省掉标定时的
	 *   「改设备树 → 重编内核 → 刷机 → 重启」循环。
	 *
	 *   为什么必须留这个口子：设备树里的 rotation 经驱动
	 *   v4l2_ctrl_new_fwnode_properties() 变成 V4L2_CID_CAMERA_SENSOR_ROTATION，
	 *   而那个控件 min==max==def，是【只读】的 —— 运行时 v4l2-ctl 改不动它，
	 *   每次试一个角都要重来一遍内核。
	 *   ⚠️ 它只是标定用的临时口子：正确值必须写进设备树（patches/0032 / 0049）。PR #6 初版把
	 *      标定结果只放在仓库外的 post-fs-data 脚本里设这组属性，干净构建的 ROM 就又歪了。
	 *
	 *   ⚠️ 属性给的数就是【写进设备树的那个数】（同一个约定，不用再换算），
	 *      免得标定时多做一次 360-x 的心算：
	 *        setprop debug.gaokun3.camera.orientation.rear 270
	 *      标定完把属性清空，并把值写进设备树 —— 正确的位置是设备树。
	 *      步骤见 docs/camera-photo-rotation-2026-09-19.md。
	 */
	const char *prop = facts_.frontFacing
				   ? "debug.gaokun3.camera.orientation.front"
				   : "debug.gaokun3.camera.orientation.rear";
	char propVal[PROP_VALUE_MAX] = {};
	if (__system_property_get(prop, propVal) > 0) {
		const int32_t v = atoi(propVal);
		if (v == 0 || v == 90 || v == 180 || v == 270) {
			ALOGW("%s 方向被属性覆盖：%s=%d（设备树报的是 %d）—— 仅调试用",
			      name_.c_str(), prop, v, rawRotation);
			ccw = v;
		} else {
			ALOGW("%s 属性 %s=\"%s\" 不是 0/90/180/270，忽略",
			      name_.c_str(), prop, propVal);
		}
	}

	if (ccw % 90 != 0) {
		ALOGW("Rotation=%d 不是 90 的整数倍，按 0° 处理（Android 只认 0/90/180/270）",
		      rawRotation);
		ccw = 0;
	}
	facts_.orientation = (360 - ccw) % 360;

	/*
	 * ── 闪光灯（#110）──
	 * 只有后摄有；LED 由内核暴露成 /sys/class/leds/white:flash（PM8350C 闪光模块 1+4 路）。
	 * 节点不在（旧内核 / 旧 dtb）就如实声明没有闪光灯，别让应用点一个不存在的灯。
	 * ⚠️ 写权限来自 ueventd.gaokun3.rc（brightness 0664 root camera）；HAL 以 cameraserver 跑。
	 */
	if (!facts_.frontFacing && access((std::string(kRearFlashLed) + "/brightness").c_str(),
					  W_OK) == 0)
		facts_.flashLed = kRearFlashLed;

	/*
	 * ── 对焦马达 ──
	 * 只有后摄有 VCM（i2c 1-000c 的 dw9714，内核把它暴露成独立 v4l2 子设备）。
	 * 这里【只找节点】、不开设备：打开 /dev/v4l-subdevN 本身就会给马达上电
	 * （dw9714_open → pm_runtime，见 Lens.h），相机还没开的时候不该占着它。真正的 open 在
	 * Session::init()（有会话才有必要）。
	 * 前摄 hi846 无马达 ⇒ hasAf 保持 false，元数据如实按定焦声明。
	 */
	if (!facts_.frontFacing && !Lens::findNode().empty()) {
		facts_.hasAf = true;
		ALOGI("%s 检测到对焦马达（VCM），将声明 AF", name_.c_str());
	}

	/*
	 * ── 对外声明的输出尺寸 ──
	 * ⚠️★ 不要把传感器满分辨率一股脑报上去：软件去拜耳 8 MP 单帧就要几十毫秒
	 *    （[#95] 实测 AGC 收敛后帧间隔约 130 ms），预览用满分辨率会卡死。
	 *    这里给一组【降采样】的常用尺寸 + 满分辨率（留给静态拍照），
	 *    宽高比与传感器一致，避免框架做非等比裁剪。
	 */
	auto ratio = [&](int w) {
		return std::make_pair(w, static_cast<int>(
			static_cast<int64_t>(w) * facts_.activeH / facts_.activeW) & ~1);
	};
	facts_.outputSizes = { ratio(640), ratio(1280),
			       { facts_.activeW, facts_.activeH } };

	/* 15 fps 是软件 ISP 的现实上限，别声明做不到的数。 */
	facts_.minFrameDurationNs = 66666666;   /* 15 fps */

	characteristics_ = buildCharacteristics(facts_);
	if (characteristics_.empty()) {
		ALOGE("characteristics 构造失败");
		return false;
	}

	ALOGI("%s 就绪：阵列 %dx%d 有效 %dx%d 朝向 %d（libcamera rotation=%d，逆时针） %s%s%s",
	      name_.c_str(), facts_.pixelArrayW, facts_.pixelArrayH,
	      facts_.activeW, facts_.activeH, facts_.orientation, rawRotation,
	      facts_.frontFacing ? "前摄" : "后摄",
	      facts_.flashLed.empty() ? "" : "（带闪光灯）",
	      facts_.hasAf ? "（带自动对焦）" : "");
	return true;
}

ndk::ScopedAStatus Device::getCameraCharacteristics(CameraMetadata *out)
{
	std::lock_guard<std::mutex> lk(mutex_);
	out->metadata = characteristics_;
	return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Device::getPhysicalCameraCharacteristics(const std::string &,
							    CameraMetadata *)
{
	/* 不是逻辑多摄，没有物理子相机。 */
	return err(Status::ILLEGAL_ARGUMENT);
}

ndk::ScopedAStatus Device::getResourceCost(CameraResourceCost *out)
{
	out->resourceCost = 100;     /* 软件 ISP 吃 CPU，如实报满 */
	out->conflictingDevices.clear();
	return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Device::isStreamCombinationSupported(const StreamConfiguration &cfg,
							bool *out)
{
	/* 与 Session::configureStreams 同一个判据（Metadata.h），也与静态元数据的
	 * MAX_NUM_OUTPUT_STREAMS 一致。⚠️ PR #6 初版把这里从 <=1 悄悄改成 <=2，
	 * 既不看格式也不看路数构成，与声明的 {0,2,1} 互相矛盾。 */
	std::string why;
	*out = streamCombinationSupported(cfg, facts_, &why);
	if (!*out)
		ALOGI("isStreamCombinationSupported: 否（%s）", why.c_str());
	return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Device::open(const std::shared_ptr<ICameraDeviceCallback> &cb,
				std::shared_ptr<ICameraDeviceSession> *out)
{
	std::lock_guard<std::mutex> lk(mutex_);
	if (!cb)
		return err(Status::ILLEGAL_ARGUMENT);

	auto session = ndk::SharedRefBase::make<Session>(cam_, facts_, cb);
	if (!session->init()) {
		ALOGE("Session::init 失败");
		return err(Status::INTERNAL_ERROR);
	}
	/* 相机被占用期间手电筒不可用（框架的约定）；灯由会话按请求控制。 */
	inUse_ = true;
	if (!facts_.flashLed.empty()) {
		setLed(false);
		provider_->notifyTorch(name_, TorchModeStatus::NOT_AVAILABLE);
	}
	session->setOnClosed([this] { onSessionClosed(); });
	*out = session;
	ALOGI("%s 已打开", name_.c_str());
	return ndk::ScopedAStatus::ok();
}

void Device::onSessionClosed()
{
	std::lock_guard<std::mutex> lk(mutex_);
	inUse_ = false;
	if (!facts_.flashLed.empty()) {
		setLed(false);
		provider_->notifyTorch(name_, TorchModeStatus::AVAILABLE_OFF);
	}
}

bool Device::setLed(bool on)
{
	if (facts_.flashLed.empty())
		return false;
	std::string max = readSysfs(facts_.flashLed + "/max_brightness");
	if (max.empty())
		max = "255";
	return writeSysfs(facts_.flashLed + "/brightness", on ? max : "0");
}

ndk::ScopedAStatus Device::openInjectionSession(
	const std::shared_ptr<ICameraDeviceCallback> &,
	std::shared_ptr<ICameraInjectionSession> *out)
{
	*out = nullptr;
	return err(Status::OPERATION_NOT_SUPPORTED);
}

ndk::ScopedAStatus Device::setTorchMode(bool on)
{
	/*
	 * 手电筒（快捷设置的那块砖、以及 CameraManager.setTorchMode）。
	 * 契约（ICameraDevice.aidl）：没有闪光灯 → OPERATION_NOT_SUPPORTED；
	 * 相机正被会话占用 → CAMERA_IN_USE；成功后必须经 provider 回调报状态。
	 */
	std::lock_guard<std::mutex> lk(mutex_);
	if (facts_.flashLed.empty())
		return err(Status::OPERATION_NOT_SUPPORTED);
	if (inUse_)
		return err(Status::CAMERA_IN_USE);
	if (!setLed(on))
		return err(Status::INTERNAL_ERROR);
	provider_->notifyTorch(name_, on ? TorchModeStatus::AVAILABLE_ON
					 : TorchModeStatus::AVAILABLE_OFF);
	ALOGI("%s 手电筒 %s", name_.c_str(), on ? "开" : "关");
	return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Device::turnOnTorchWithStrengthLevel(int32_t)
{
	return err(Status::OPERATION_NOT_SUPPORTED);
}

ndk::ScopedAStatus Device::getTorchStrengthLevel(int32_t *)
{
	return err(Status::OPERATION_NOT_SUPPORTED);
}

ndk::ScopedAStatus Device::constructDefaultRequestSettings(RequestTemplate type,
							   CameraMetadata *out)
{
	out->metadata = buildDefaultRequest(static_cast<int>(type), facts_);
	if (out->metadata.empty())
		return err(Status::INTERNAL_ERROR);
	return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Device::isStreamCombinationWithSettingsSupported(
	const StreamConfiguration &cfg, bool *out)
{
	return isStreamCombinationSupported(cfg, out);
}

ndk::ScopedAStatus Device::getSessionCharacteristics(const StreamConfiguration &,
						     CameraMetadata *out)
{
	/* 会话特性与静态特性一致（我们没有随配置变化的能力）。 */
	std::lock_guard<std::mutex> lk(mutex_);
	out->metadata = characteristics_;
	return ndk::ScopedAStatus::ok();
}

} /* namespace gaokun3 */
