/* SPDX-License-Identifier: Apache-2.0 */
#include "AutoFocus.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>

#include <sys/system_properties.h>

#include <log/log.h>

namespace gaokun3 {

namespace {

/* RGB24 取亮度，整数近似 0.25R + 0.5G + 0.25B（移位实现，避免每像素浮点）。 */
inline int lumaAt(const uint8_t *p)
{
	return (static_cast<int>(p[0]) + 2 * static_cast<int>(p[1]) + p[2]) >> 2;
}

} /* namespace */

void AutoFocus::attach(Lens *lens)
{
	std::lock_guard<std::mutex> lk(m_);
	lens_ = lens;
	if (lens_)
		bestPos_ = lens_->position();
}

bool AutoFocus::ready() const
{
	std::lock_guard<std::mutex> lk(m_);
	return lens_ && lens_->usable();
}

bool AutoFocus::shouldScan() const
{
	switch (mode_) {
	case Mode::ContinuousPicture:
	case Mode::ContinuousVideo:
		return true;
	case Mode::Auto:
		return triggered_;
	default:
		return false;
	}
}

bool AutoFocus::locked() const
{
	return triggered_ && converged_;
}

void AutoFocus::setMode(uint8_t androidAfMode)
{
	Mode nm = Mode::Off;
	switch (androidAfMode) {
	case ANDROID_CONTROL_AF_MODE_AUTO:
		nm = Mode::Auto;
		break;
	case ANDROID_CONTROL_AF_MODE_CONTINUOUS_PICTURE:
		nm = Mode::ContinuousPicture;
		break;
	case ANDROID_CONTROL_AF_MODE_CONTINUOUS_VIDEO:
		nm = Mode::ContinuousVideo;
		break;
	default:
		nm = Mode::Off;
		break;
	}

	std::lock_guard<std::mutex> lk(m_);
	if (nm == mode_)
		return;
	ALOGI("AF 模式 %u -> %d（0=OFF 1=AUTO 2=CONT_PIC 3=CONT_VID）",
	      androidAfMode, static_cast<int>(nm));
	mode_ = nm;
	triggered_ = false;
	scanning_ = false;
	converged_ = false;
	stable_ = 0;
	if (nm != Mode::Off)
		startScan();
}

void AutoFocus::trigger(uint8_t androidAfTrigger)
{
	std::lock_guard<std::mutex> lk(m_);
	if (androidAfTrigger == ANDROID_CONTROL_AF_TRIGGER_START) {
		ALOGI("AF 触发 START");
		triggered_ = true;
		startScan();
	} else if (androidAfTrigger == ANDROID_CONTROL_AF_TRIGGER_CANCEL) {
		ALOGI("AF 触发 CANCEL");
		triggered_ = false;
		scanning_ = false;
		converged_ = false;
		stable_ = 0;
	}
}

/* 调用者必须已持锁。 */
void AutoFocus::startScan()
{
	if (!lens_ || !lens_->usable())
		return;
	scanning_ = true;
	converged_ = false;
	moves_ = 0;
	bestScore_ = 0.0;
	bestPos_ = lens_->position();
	stable_ = 0;
	fineDone_ = false;
	/* 粗扫 kCoarsePoints 点（含两端）覆盖整个行程；峰附近的细扫在粗扫结束后生成。 */
	sweep_.clear();
	const int lo = lens_->minPos();
	const int hi = lens_->maxPos();
	for (int i = 0; i < kCoarsePoints; i++)
		sweep_.push_back(lo + (hi - lo) * i / (kCoarsePoints - 1));
	sweepIdx_ = 0;
	settle_ = kSettleFrames;   /* 起始位置也要等流水线把画面换过来再采第一个点 */
}

void AutoFocus::apply(int pos)
{
	if (!lens_)
		return;
	if (lens_->setPosition(pos)) {
		justMoved_ = true;
		bestPos_ = (bestScore_ <= 0.0) ? pos : bestPos_;
	}
}

/* 调用者必须已持锁。 */
void AutoFocus::finishScan()
{
	scanning_ = false;
	converged_ = bestScore_ >= kMinScore;
	stable_ = 0;
	settle_ = 0;    /* 搜索结束，后面的"画面变化重扫"判定不必再等稳定帧 */
	if (lens_ && lens_->position() != bestPos_)
		apply(bestPos_);
	ALOGI("AF 搜索结束：最佳位置 %d 分数 %.1f（%s）共 %d 次移动",
	      bestPos_, bestScore_, converged_ ? "已合焦" : "未合焦（场景对比度太低）",
	      moves_);
}

double AutoFocus::sharpness(const uint8_t *rgb, int w, int h)
{
	/*
	 * 指标 = 网格亮度图的拉普拉斯能量 / 亮度总和。
	 *
	 * ★ 两处都是踩过坑才定下来的：
	 *   ① 【块平均】而不是单点采样 —— 每格取 kAvg×kAvg 的平均。单像素带着
	 *      全部传感器噪声，而噪声在位置之间是随机的：早先"每 16 像素只取
	 *      1 个像素"的版本量出来的曲线被噪声主导（同一场景下 pos1023 的分数
	 *      反而高于 pos512，与眼睛看到的相反）。对焦模糊的尺度远大于 4 像素，
	 *      4×4 平均不会削掉对焦信息。
	 *   ② 【拉普拉斯】而不是原始梯度 —— 二阶导只留细节，压掉画面里的大块
	 *      明暗结构（黑白测试卡、灰阶梯那种大面积高对比会把一阶梯度吃满，
	 *      对焦信号被淹没）。
	 *   最后除以亮度总和：AGC 改变曝光/增益时分子分母同比例变化，分数不动
	 *   —— 否则爬山会往"最亮"跑而不是往"最清晰"跑。
	 */
	const int x0 = w * 15 / 100;
	const int x1 = w * 85 / 100;
	const int y0 = h * 15 / 100;
	const int y1 = h * 85 / 100;
	const int gw = (x1 - x0) / kBlock;
	const int gh = (y1 - y0) / kBlock;
	if (gw < 3 || gh < 3)
		return 0.0;

	grid_.assign(static_cast<size_t>(gw) * gh, 0.0f);

	const size_t rowBytes = static_cast<size_t>(w) * 3;
	const int off = kBlock / 2 - kAvg / 2;     /* 每格中心取的 kAvg×kAvg 小块 */
	for (int gy = 0; gy < gh; gy++) {
		const int cy = y0 + gy * kBlock + off;
		for (int gx = 0; gx < gw; gx++) {
			const int cx = x0 + gx * kBlock + off;
			uint32_t acc = 0;
			for (int j = 0; j < kAvg; j++) {
				const uint8_t *p = rgb + static_cast<size_t>(cy + j) * rowBytes +
						   static_cast<size_t>(cx) * 3;
				for (int i = 0; i < kAvg; i++, p += 3)
					acc += static_cast<uint32_t>(lumaAt(p));
			}
			grid_[static_cast<size_t>(gy) * gw + gx] =
				static_cast<float>(acc) / static_cast<float>(kAvg * kAvg);
		}
	}

	double lap = 0.0;
	double lum = 0.0;
	for (int gy = 1; gy < gh - 1; gy++) {
		for (int gx = 1; gx < gw - 1; gx++) {
			const size_t o = static_cast<size_t>(gy) * gw + gx;
			const float c = grid_[o];
			lap += std::fabs(4.0f * c - grid_[o - 1] - grid_[o + 1] -
					 grid_[o - gw] - grid_[o + gw]);
			lum += c;
		}
	}
	if (lum <= 0.0)
		return 0.0;
	return 1000.0 * lap / lum;
}

void AutoFocus::onFrame(const uint8_t *rgb, int w, int h, bool sceneStable)
{
	if (!rgb || w <= 0 || h <= 0)
		return;
	const double score = sharpness(rgb, w, h);

	std::lock_guard<std::mutex> lk(m_);

	/* 镜头状态描述【这一帧曝光时】的马达：上一帧我们刚发过移动指令，
	 * 这一帧还没走到位 ⇒ MOVING；再下一帧起 STATIONARY。 */
	lensState_ = justMoved_ ? ANDROID_LENS_STATE_MOVING : ANDROID_LENS_STATE_STATIONARY;
	justMoved_ = false;

	if (!lens_ || !lens_->usable())
		return;

	/*
	 * ── 调试口：把马达钉在指定位置（标定/排障用）──
	 *   setprop debug.gaokun3.camera.af.hold 700   → 停在 700，AF 不搜（报 INACTIVE）
	 *   setprop debug.gaokun3.camera.af.hold ""    → 恢复正常 AF（-1 同义）
	 * ★ 为什么必须留这个口子：自动搜索的"锐度曲线"分不清"焦点变了"和
	 *   "AE 漂了"——实测同一位置 1020 在 AGC 收敛前后差 3 倍。要证明马达真的
	 *   在动、以及焦点落在哪，唯一严谨的办法是把位置钉住逐点量图。
	 */
	{
		char buf[PROP_VALUE_MAX] = {};
		if (__system_property_get("debug.gaokun3.camera.af.hold", buf) > 0) {
			const int v = atoi(buf);
			holdPos_ = (lens_ && (v < lens_->minPos() || v > lens_->maxPos()))
					   ? -1 : v;
		} else {
			/* ★ 属性被清空（`setprop … ""`）或从未设置 ⇒ **必须解除钉住**。
			 *   早先这里只是"读不到就不改 holdPos_"，于是 setprop "" 之后
			 *   马达被永久钉在上一个位置 —— 实测 A/B 实验里"放开后画面纹丝不动",
			 *   排查半天才发现钉住根本没放开。 */
			holdPos_ = -1;
		}
	}
	if (holdPos_ >= 0) {
		if (!hold_)
			ALOGW("AF 被属性钉住：保持马达位置 %d，不再自动搜索", holdPos_);
		hold_ = true;
		scanning_ = false;
		stableSeen_ = 0;
		if (lens_->position() != holdPos_) {
			if (lens_->setPosition(holdPos_)) {
				justMoved_ = true;
				settle_ = kSettleFrames;
			}
			return;
		}
		if (settle_ > 0) {
			settle_--;
			return;
		}
		/* ★ 钉住状态下每帧打分数 = 直接得到"位置 → 分数"曲线，
		 *   外部脚本只要逐个 setprop 就能把整条对焦曲线标出来。 */
		ALOGI("AF 钉住采样 pos=%d 分数=%.1f", holdPos_, score);
		return;
	}
	if (hold_) {
		ALOGI("AF 钉住解除，恢复自动搜索");
		hold_ = false;
	}

	if (mode_ == Mode::Off)
		return;

	if (!shouldScan()) {
		scanning_ = false;
		return;
	}

	/*
	 * AE 未收敛：这一帧的分数不可信（整帧 gamma 在变 ⇒ 锐度分数跟着漂）。
	 * ★★ 只【跳过这一帧】，绝不"作废重来"：
	 *   作废会把 step/dir/best/位置选择全部重置并立刻再挪马达，而 AGC 是
	 *   频繁台阶式调整的（实测 12 秒内十几次）⇒ 搜索被一直打断，最后被推
	 *   到行程端点、在一个平坦的低分平台上"收敛"（实测收敛到 896 / 34.9，
	 *   而真峰值在 320 / 347 —— 差 10 倍。这是把"等 AE"写成了"重启搜索"的错）。
	 *   跳过的话搜索状态原样保留，等稳定的帧接着推进，代价只是慢一点。
	 */
	if (!sceneStable) {
		if (!scanning_) {
			if (++stableSeen_ % 40 == 1)
				ALOGI("AF 等 AE 收敛中（第 %d 帧，画面还在变）", stableSeen_);
			return;
		}
		if (++stableSeen_ % 20 == 1)
			ALOGD("AF 跳过不稳定帧（第 %d 帧）", stableSeen_);
		return;
	}
	stableSeen_ = 0;

	if (!scanning_) {
		/* 连续模式：收敛后画面变了要能重新搜。
		 * 单次对焦(triggered_)时锁定不重搜，等应用发 CANCEL/START。 */
		if (triggered_)
			return;
		if (bestScore_ > 0.0 && score < bestScore_ * kDropToRescan) {
			if (++stable_ >= kRescanFrames) {
				ALOGI("AF 画面变化（分数 %.1f → %.1f），重新搜索",
				      bestScore_, score);
				startScan();
			}
		} else {
			stable_ = 0;
		}
		return;
	}

	/* ── 搜索中 ── */
	/*
	 * ★ 用【均匀粗扫 + 峰附近细扫】而不是爬山：
	 *   爬山是局部算法，实测会卡死 —— 起始 511 最佳、往 766 探到更差后反向，
	 *   只是从"已经走坏的那一侧"往回挪（639→702→671…），**峰在另一侧的
	 *   256~384 整片从未被探索**。行程只有 1024 步、实测约 28 fps，
	 *   14 个探测点 ≈ 2 秒就能拿到全局峰；代价可接受，换来确定性。
	 *   附带好处：整条"位置→分数"曲线都会打进日志，标定与排障直接看日志。
	 */
	const int cur = lens_->position();

	/*
	 * 流水线延迟：setPosition 之后，相机/ISP 流水线里还有 kSettleFrames 帧
	 * 是【旧位置】曝出来的。设完位置就采信下一帧的分数 = 把"位置"和"分数"
	 * 错配。所以刚移过就先扔掉几帧（扔掉的帧打 ALOGD，可从日志量真实延迟）。
	 */
	if (settle_ > 0) {
		settle_--;
		ALOGD("AF 等稳定：pos=%d 分数=%.1f（还需 %d 帧）", cur, score, settle_);
		return;
	}

	/* 每个采样点都打一行（pos + 分数）——"马达到底动没动 / 焦点落在哪"的客观证据。 */
	ALOGI("AF 采样 pos=%d 分数=%.1f（当前最佳 %d / %.1f）",
	      cur, score, bestPos_, bestScore_);
	if (score > bestScore_) {
		bestScore_ = score;
		bestPos_ = cur;
	}

	/* 取下一个【与当前位置不同】的探测点；粗扫走完就转到峰附近的细扫。 */
	while (true) {
		int target = -1;
		while (sweepIdx_ < static_cast<int>(sweep_.size())) {
			const int p = sweep_[sweepIdx_++];
			if (p != lens_->position()) {
				target = p;
				break;
			}
		}
		if (target >= 0) {
			moves_++;
			if (!lens_->setPosition(target)) {
				finishScan();
				return;
			}
			settle_ = kSettleFrames;
			justMoved_ = true;
			return;
		}
		if (fineDone_) {   /* 细扫也走完 → 收敛到最佳点 */
			finishScan();
			return;
		}
		/* 粗扫结束：在最佳点附近细扫 ±2 格，格距 = 行程/32（≈32 步）。 */
		const int st = std::max((lens_->maxPos() - lens_->minPos()) / 32, 1);
		sweep_.clear();
		for (int k = -2; k <= 2; k++) {
			const int p = bestPos_ + k * st;
			sweep_.push_back(std::clamp(p, lens_->minPos(), lens_->maxPos()));
		}
		sweepIdx_ = 0;
		fineDone_ = true;
		ALOGI("AF 粗扫完成：最佳 %d 分数 %.1f → 细扫 ±%d", bestPos_, bestScore_, 2 * st);
	}
}

uint8_t AutoFocus::afState() const
{
	std::lock_guard<std::mutex> lk(m_);
	if (!lens_ || !lens_->usable() || mode_ == Mode::Off || hold_)
		return ANDROID_CONTROL_AF_STATE_INACTIVE;
	if (mode_ == Mode::Auto && !triggered_)
		return ANDROID_CONTROL_AF_STATE_INACTIVE;
	if (scanning_) {
		if (mode_ == Mode::Auto || triggered_)
			return ANDROID_CONTROL_AF_STATE_ACTIVE_SCAN;
		return ANDROID_CONTROL_AF_STATE_PASSIVE_SCAN;
	}
	if (locked())
		return ANDROID_CONTROL_AF_STATE_FOCUSED_LOCKED;
	if (mode_ == Mode::Auto || triggered_)
		return ANDROID_CONTROL_AF_STATE_NOT_FOCUSED_LOCKED;
	return converged_ ? ANDROID_CONTROL_AF_STATE_PASSIVE_FOCUSED
			  : ANDROID_CONTROL_AF_STATE_PASSIVE_UNFOCUSED;
}

uint8_t AutoFocus::lensState() const
{
	std::lock_guard<std::mutex> lk(m_);
	return lensState_;
}

float AutoFocus::focusDistance() const
{
	std::lock_guard<std::mutex> lk(m_);
	if (!lens_ || !lens_->usable())
		return 0.0f;
	const int lo = lens_->minPos();
	const int hi = lens_->maxPos();
	if (hi <= lo)
		return 0.0f;
	/* 标称映射（UNCALIBRATED）：行程低端 = 无穷远(0 屈光度)，高端 = 最近。
	 * 声明为 UNCALIBRATED 后应用不该依赖它的绝对值，只要单调即可。 */
	return kMinFocusDiopters *
	       static_cast<float>(lens_->position() - lo) / static_cast<float>(hi - lo);
}

} /* namespace gaokun3 */
