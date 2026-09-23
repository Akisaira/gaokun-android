/* SPDX-License-Identifier: Apache-2.0 */
#include "Lens.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <linux/videodev2.h>

#include <log/log.h>

namespace gaokun3 {

namespace {
constexpr char kSysfsDir[] = "/sys/class/video4linux";
constexpr char kNameMatch[] = "dw9714";

std::string readFirstLine(const std::string &path)
{
	int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return {};
	char buf[128] = {};
	const ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
	::close(fd);
	if (n <= 0)
		return {};
	std::string s(buf, static_cast<size_t>(n));
	while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' '))
		s.pop_back();
	return s;
}
} /* namespace */

std::string Lens::findNode()
{
	DIR *d = opendir(kSysfsDir);
	if (!d) {
		ALOGE("打不开 %s: %s", kSysfsDir, strerror(errno));
		return {};
	}
	std::string found;
	while (dirent *e = readdir(d)) {
		if (e->d_name[0] == '.')
			continue;
		const std::string name = readFirstLine(std::string(kSysfsDir) + "/" + e->d_name + "/name");
		if (name.find(kNameMatch) == std::string::npos)
			continue;
		found = std::string("/dev/") + e->d_name;
		ALOGI("VCM 子设备：%s -> \"%s\"", found.c_str(), name.c_str());
		break;
	}
	closedir(d);
	if (found.empty())
		ALOGW("%s 下没有名字含 \"%s\" 的子设备", kSysfsDir, kNameMatch);
	return found;
}

bool Lens::open(bool center)
{
	node_ = findNode();
	if (node_.empty())
		return false;

	fd_ = ::open(node_.c_str(), O_RDWR | O_CLOEXEC);
	if (fd_ < 0) {
		ALOGE("打开 %s 失败: %s", node_.c_str(), strerror(errno));
		return false;
	}

	/* 控件范围：优先 QUERY_EXT_CTRL（给全 min/max/step），退回老的 QUERYCTRL。 */
	bool got = false;
	{
		struct v4l2_query_ext_ctrl qc {};
		qc.id = V4L2_CID_FOCUS_ABSOLUTE;
		if (ioctl(fd_, VIDIOC_QUERY_EXT_CTRL, &qc) == 0) {
			min_ = static_cast<int>(qc.minimum);
			max_ = static_cast<int>(qc.maximum);
			step_ = static_cast<int>(qc.step ? qc.step : 1);
			got = true;
		}
	}
	if (!got) {
		struct v4l2_queryctrl q {};
		q.id = V4L2_CID_FOCUS_ABSOLUTE;
		if (ioctl(fd_, VIDIOC_QUERYCTRL, &q) != 0) {
			ALOGE("%s 上没有 V4L2_CID_FOCUS_ABSOLUTE: %s",
			      node_.c_str(), strerror(errno));
			close();
			return false;
		}
		if (q.flags & V4L2_CTRL_FLAG_DISABLED) {
			ALOGE("%s 的对焦控件被标为 DISABLED", node_.c_str());
			close();
			return false;
		}
		min_ = static_cast<int>(q.minimum);
		max_ = static_cast<int>(q.maximum);
		step_ = static_cast<int>(q.step ? q.step : 1);
	}
	if (max_ <= min_) {
		ALOGE("%s 的对焦范围不合法：[%d, %d]", node_.c_str(), min_, max_);
		close();
		return false;
	}

	/* 上电已经随 open() 完成（见 Lens.h）。取控件的当前值作为起点。 */
	const int cur = readControl();
	pos_ = cur >= 0 ? cur : min_;
	ALOGI("VCM 就绪：%s 范围 [%d, %d] step=%d 控件当前值 %d",
	      node_.c_str(), min_, max_, step_, pos_);

	if (center)
		setPosition((min_ + max_) / 2);
	return true;
}

int Lens::readControl() const
{
	if (fd_ < 0)
		return -1;
	struct v4l2_control c {};
	c.id = V4L2_CID_FOCUS_ABSOLUTE;
	if (ioctl(fd_, VIDIOC_G_CTRL, &c) != 0)
		return -1;
	return static_cast<int>(c.value);
}

void Lens::close()
{
	if (fd_ < 0)
		return;
	::close(fd_);   /* = 断电（dw9714_close → pm_runtime_put） */
	fd_ = -1;
}

bool Lens::setPosition(int pos)
{
	if (fd_ < 0)
		return false;
	if (pos < min_)
		pos = min_;
	if (pos > max_)
		pos = max_;
	if (step_ > 1)
		pos = min_ + ((pos - min_) / step_) * step_;
	if (pos == pos_)
		return true;

	struct v4l2_control c {};
	c.id = V4L2_CID_FOCUS_ABSOLUTE;
	c.value = static_cast<int32_t>(pos);
	if (ioctl(fd_, VIDIOC_S_CTRL, &c) != 0) {
		if (++errors_ <= 3 || errors_ % 50 == 0)
			ALOGE("写 %s 马达位置 %d 失败: %s（第 %d 次）",
			      node_.c_str(), pos, strerror(errno), errors_);
		return false;
	}
	errors_ = 0;
	pos_ = pos;
	return true;
}

} /* namespace gaokun3 */
