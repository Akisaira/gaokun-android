/* SPDX-License-Identifier: Apache-2.0 */
/*
 * gaokun3-ncam-smoke —— 从【应用视角】对相机 HAL 做冒烟测试（NDK Camera2）。
 *
 * 为什么需要它：HAL 日志只能说明 HAL 自己以为做了什么；应用看到的是框架转交的
 * CaptureResult。PR #6 初版正是栽在这里 —— 马达扫到了峰（HAL 日志里有），结果元数据里
 * 却永远是 AF_STATE_INACTIVE。这个工具走的是与应用相同的路（cameraserver → HAL），
 * 读的是应用会读的那几个键。也不需要解锁屏幕、不需要装应用。
 *
 * 用法（adb root 之后，push 到 /data/local/tmp）：
 *   gaokun3-ncam-smoke            # 后摄：连续对焦 / 触发锁定 / AUTO 单次对焦 / 连拍 JPEG 旋转
 *   gaokun3-ncam-smoke front      # 前摄（定焦）：只测 JPEG 旋转与连拍
 *
 * ⚠️ 隐私：图像只在内存里解析尺寸，【不写任何文件】。
 * 输出最后一行是 "RESULT: PASS" 或 "RESULT: FAIL (n)"。
 */
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <android/binder_process.h>
#include <camera/NdkCameraCaptureSession.h>
#include <camera/NdkCameraDevice.h>
#include <camera/NdkCameraManager.h>
#include <camera/NdkCameraMetadata.h>
#include <camera/NdkCaptureRequest.h>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>

namespace {

int gFails = 0;
void check(bool ok, const char *what)
{
	printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
	if (!ok)
		gFails++;
}

const char *afName(int s)
{
	switch (s) {
	case ACAMERA_CONTROL_AF_STATE_INACTIVE: return "INACTIVE";
	case ACAMERA_CONTROL_AF_STATE_PASSIVE_SCAN: return "PASSIVE_SCAN";
	case ACAMERA_CONTROL_AF_STATE_PASSIVE_FOCUSED: return "PASSIVE_FOCUSED";
	case ACAMERA_CONTROL_AF_STATE_ACTIVE_SCAN: return "ACTIVE_SCAN";
	case ACAMERA_CONTROL_AF_STATE_FOCUSED_LOCKED: return "FOCUSED_LOCKED";
	case ACAMERA_CONTROL_AF_STATE_NOT_FOCUSED_LOCKED: return "NOT_FOCUSED_LOCKED";
	case ACAMERA_CONTROL_AF_STATE_PASSIVE_UNFOCUSED: return "PASSIVE_UNFOCUSED";
	default: return "?";
	}
}

struct State {
	std::mutex m;
	std::condition_variable cv;
	int afState = -1;
	int lensState = -1;
	float focusDist = -1.f;
	int results = 0;
	int failures = 0;
	std::vector<int> afHistory;          /* 去重后的 AF 状态序列 */
	std::vector<std::pair<int, int>> jpegDims;
} gS;

void onCompleted(void *, ACameraCaptureSession *, ACaptureRequest *, const ACameraMetadata *r)
{
	ACameraMetadata_const_entry e;
	std::lock_guard<std::mutex> lk(gS.m);
	gS.results++;
	if (ACameraMetadata_getConstEntry(r, ACAMERA_CONTROL_AF_STATE, &e) == ACAMERA_OK && e.count) {
		gS.afState = e.data.u8[0];
		if (gS.afHistory.empty() || gS.afHistory.back() != gS.afState)
			gS.afHistory.push_back(gS.afState);
	}
	if (ACameraMetadata_getConstEntry(r, ACAMERA_LENS_STATE, &e) == ACAMERA_OK && e.count)
		gS.lensState = e.data.u8[0];
	if (ACameraMetadata_getConstEntry(r, ACAMERA_LENS_FOCUS_DISTANCE, &e) == ACAMERA_OK && e.count)
		gS.focusDist = e.data.f[0];
	gS.cv.notify_all();
}

void onFailed(void *, ACameraCaptureSession *, ACaptureRequest *, ACameraCaptureFailure *f)
{
	std::lock_guard<std::mutex> lk(gS.m);
	gS.failures++;
	printf("  ! 帧失败 frame=%lld reason=%d\n", (long long)f->frameNumber, f->reason);
}

/* 在 JPEG 里找 SOF0/SOF2 读宽高（只解析头，不解码）。 */
bool jpegSize(const uint8_t *p, int len, int *w, int *h)
{
	for (int i = 2; i + 9 < len;) {
		if (p[i] != 0xFF) { i++; continue; }
		const uint8_t mk = p[i + 1];
		const int seg = (p[i + 2] << 8) | p[i + 3];
		if (mk == 0xC0 || mk == 0xC2) {
			*h = (p[i + 5] << 8) | p[i + 6];
			*w = (p[i + 7] << 8) | p[i + 8];
			return true;
		}
		i += 2 + seg;
	}
	return false;
}

void onJpeg(void *, AImageReader *reader)
{
	AImage *img = nullptr;
	if (AImageReader_acquireNextImage(reader, &img) != AMEDIA_OK || !img)
		return;
	uint8_t *data = nullptr;
	int len = 0, w = 0, h = 0;
	if (AImage_getPlaneData(img, 0, &data, &len) == AMEDIA_OK && jpegSize(data, len, &w, &h)) {
		std::lock_guard<std::mutex> lk(gS.m);
		gS.jpegDims.push_back({ w, h });
		gS.cv.notify_all();
	}
	AImage_delete(img);   /* 只量尺寸，不落盘 */
}

void onPreview(void *, AImageReader *reader)
{
	AImage *img = nullptr;
	if (AImageReader_acquireLatestImage(reader, &img) == AMEDIA_OK && img)
		AImage_delete(img);
}

void onDisconnected(void *, ACameraDevice *) { printf("  ! 设备断开\n"); }
void onError(void *, ACameraDevice *, int err) { printf("  ! 设备错误 %d\n", err); gFails++; }
void onSessionClosed(void *, ACameraCaptureSession *) {}
void onSessionReady(void *, ACameraCaptureSession *) {}
void onSessionActive(void *, ACameraCaptureSession *) {}

/* 等到 AF 状态满足 pred，或超时。 */
template <typename P>
bool waitAf(int ms, P pred)
{
	std::unique_lock<std::mutex> lk(gS.m);
	return gS.cv.wait_for(lk, std::chrono::milliseconds(ms), [&] { return pred(gS.afState); });
}

} /* namespace */

int main(int argc, char **argv)
{
	const bool wantFront = argc > 1 && !strcmp(argv[1], "front");
	/* ★ 必须先起 binder 线程池：相机的状态/结果回调都是 cameraserver 反向调过来的，
	 *   没有线程接就一个结果都收不到（第一次跑就是这样：connect 成功、0 个结果）。 */
	ABinderProcess_setThreadPoolMaxThreadCount(4);
	ABinderProcess_startThreadPool();
	ACameraManager *mgr = ACameraManager_create();
	ACameraIdList *ids = nullptr;
	if (ACameraManager_getCameraIdList(mgr, &ids) != ACAMERA_OK || !ids || !ids->numCameras) {
		printf("没有相机（cameraserver 不给？是不是没 adb root）\nRESULT: FAIL (1)\n");
		return 1;
	}
	std::string camId;
	bool hasAf = false;
	int32_t orientation = -1;
	/* 尺寸从静态元数据里挑（HAL 按传感器比例算尺寸，后摄是 640x474 这种，写死会被框架拒）。 */
	int32_t yuvW = 0, yuvH = 0, jpgW = 0, jpgH = 0;
	for (int i = 0; i < ids->numCameras; i++) {
		ACameraMetadata *ch = nullptr;
		if (ACameraManager_getCameraCharacteristics(mgr, ids->cameraIds[i], &ch) != ACAMERA_OK)
			continue;
		ACameraMetadata_const_entry e;
		const bool front = ACameraMetadata_getConstEntry(ch, ACAMERA_LENS_FACING, &e) == ACAMERA_OK &&
				   e.data.u8[0] == ACAMERA_LENS_FACING_FRONT;
		if (front == wantFront && camId.empty()) {
			camId = ids->cameraIds[i];
			if (ACameraMetadata_getConstEntry(ch, ACAMERA_LENS_INFO_MINIMUM_FOCUS_DISTANCE, &e) ==
			    ACAMERA_OK && e.count)
				hasAf = e.data.f[0] > 0.f;
			if (ACameraMetadata_getConstEntry(ch, ACAMERA_SENSOR_ORIENTATION, &e) == ACAMERA_OK)
				orientation = e.data.i32[0];
			if (ACameraMetadata_getConstEntry(ch, ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS,
							  &e) == ACAMERA_OK) {
				for (uint32_t k = 0; k + 3 < e.count; k += 4) {
					const int32_t fmt = e.data.i32[k], w = e.data.i32[k + 1],
						      h = e.data.i32[k + 2], dir = e.data.i32[k + 3];
					if (dir != ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS_OUTPUT)
						continue;
					if (fmt == AIMAGE_FORMAT_YUV_420_888 && (!yuvW || w * h < yuvW * yuvH)) {
						yuvW = w; yuvH = h;
					}
					if (fmt == AIMAGE_FORMAT_JPEG && w <= 1280 && w * h > jpgW * jpgH) {
						jpgW = w; jpgH = h;
					}
				}
			}
		}
		ACameraMetadata_free(ch);
	}
	ACameraManager_deleteCameraIdList(ids);
	if (camId.empty()) {
		printf("找不到%s摄\nRESULT: FAIL (1)\n", wantFront ? "前" : "后");
		return 1;
	}
	printf("相机 %s（%s摄）SENSOR_ORIENTATION=%d 带AF=%d 预览 %dx%d JPEG %dx%d\n", camId.c_str(),
	       wantFront ? "前" : "后", orientation, hasAf, yuvW, yuvH, jpgW, jpgH);
	if (!yuvW || !jpgW) {
		printf("静态元数据里没有可用的 YUV / JPEG 尺寸\nRESULT: FAIL (1)\n");
		return 1;
	}

	ACameraDevice_StateCallbacks devCb = { nullptr, onDisconnected, onError };
	ACameraDevice *dev = nullptr;
	if (ACameraManager_openCamera(mgr, camId.c_str(), &devCb, &dev) != ACAMERA_OK) {
		printf("openCamera 失败（权限？）\nRESULT: FAIL (1)\n");
		return 1;
	}

	AImageReader *prev = nullptr, *jpeg = nullptr;
	AImageReader_new(yuvW, yuvH, AIMAGE_FORMAT_YUV_420_888, 4, &prev);
	AImageReader_new(jpgW, jpgH, AIMAGE_FORMAT_JPEG, 4, &jpeg);
	AImageReader_ImageListener pl = { nullptr, onPreview }, jl = { nullptr, onJpeg };
	AImageReader_setImageListener(prev, &pl);
	AImageReader_setImageListener(jpeg, &jl);
	ANativeWindow *pw = nullptr, *jw = nullptr;
	AImageReader_getWindow(prev, &pw);
	AImageReader_getWindow(jpeg, &jw);

	ACaptureSessionOutputContainer *outs = nullptr;
	ACaptureSessionOutputContainer_create(&outs);
	ACaptureSessionOutput *po = nullptr, *jo = nullptr;
	ACaptureSessionOutput_create(pw, &po);
	ACaptureSessionOutput_create(jw, &jo);
	ACaptureSessionOutputContainer_add(outs, po);
	ACaptureSessionOutputContainer_add(outs, jo);
	ACameraCaptureSession_stateCallbacks sCb = { nullptr, onSessionClosed, onSessionReady,
						    onSessionActive };
	ACameraCaptureSession *sess = nullptr;
	if (ACameraDevice_createCaptureSession(dev, outs, &sCb, &sess) != ACAMERA_OK) {
		printf("createCaptureSession 失败\nRESULT: FAIL (1)\n");
		return 1;
	}

	ACameraOutputTarget *pt = nullptr, *jt = nullptr;
	ACameraOutputTarget_create(pw, &pt);
	ACameraOutputTarget_create(jw, &jt);
	ACaptureRequest *preview = nullptr;
	ACameraDevice_createCaptureRequest(dev, TEMPLATE_PREVIEW, &preview);
	ACaptureRequest_addTarget(preview, pt);
	ACameraCaptureSession_captureCallbacks cc = {};
	cc.onCaptureCompleted = onCompleted;
	cc.onCaptureFailed = onFailed;
	ACameraCaptureSession_setRepeatingRequest(sess, &cc, 1, &preview, nullptr);

	printf("== 1. 预览出帧\n");
	{
		std::unique_lock<std::mutex> lk(gS.m);
		gS.cv.wait_for(lk, std::chrono::seconds(8), [] { return gS.results >= 10; });
		check(gS.results >= 10, "8 秒内收到 >=10 个结果");
	}

	if (hasAf) {
		printf("== 2. 连续对焦（模板 PREVIEW 默认 CONTINUOUS_PICTURE）\n");
		const bool left = waitAf(4000, [](int s) { return s != ACAMERA_CONTROL_AF_STATE_INACTIVE && s >= 0; });
		check(left, "AF 状态离开 INACTIVE（结果元数据里真的有 AF 状态）");
		const bool settled = waitAf(12000, [](int s) {
			return s == ACAMERA_CONTROL_AF_STATE_PASSIVE_FOCUSED ||
			       s == ACAMERA_CONTROL_AF_STATE_PASSIVE_UNFOCUSED;
		});
		check(settled, "12 秒内扫完（PASSIVE_FOCUSED / PASSIVE_UNFOCUSED）");
		{
			std::lock_guard<std::mutex> lk(gS.m);
			printf("     当前 %s，镜头 %d，对焦距离 %.2f D\n", afName(gS.afState), gS.lensState,
			       gS.focusDist);
			check(gS.focusDist >= 0.f, "结果里带 LENS_FOCUS_DISTANCE");
		}

		printf("== 3. 连续模式下触发 START：应【立刻】锁定，不重扫\n");
		ACaptureRequest *trig = ACaptureRequest_copy(preview);
		uint8_t t = ACAMERA_CONTROL_AF_TRIGGER_START;
		ACaptureRequest_setEntry_u8(trig, ACAMERA_CONTROL_AF_TRIGGER, 1, &t);
		const auto t0 = std::chrono::steady_clock::now();
		ACameraCaptureSession_capture(sess, &cc, 1, &trig, nullptr);
		const bool locked = waitAf(3000, [](int s) {
			return s == ACAMERA_CONTROL_AF_STATE_FOCUSED_LOCKED ||
			       s == ACAMERA_CONTROL_AF_STATE_NOT_FOCUSED_LOCKED;
		});
		const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::steady_clock::now() - t0).count();
		check(locked, "3 秒内 *_LOCKED");
		printf("     用时 %lld ms（旧实现重扫全程约 2 秒）\n", (long long)ms);
		check(ms < 1500, "锁定用时 < 1.5 s");
		t = ACAMERA_CONTROL_AF_TRIGGER_CANCEL;
		ACaptureRequest_setEntry_u8(trig, ACAMERA_CONTROL_AF_TRIGGER, 1, &t);
		ACameraCaptureSession_capture(sess, &cc, 1, &trig, nullptr);
		const bool unlocked = waitAf(3000, [](int s) {
			return s != ACAMERA_CONTROL_AF_STATE_FOCUSED_LOCKED &&
			       s != ACAMERA_CONTROL_AF_STATE_NOT_FOCUSED_LOCKED;
		});
		check(unlocked, "CANCEL 后解锁");

		printf("== 4. AUTO 模式单次对焦：INACTIVE → START → ACTIVE_SCAN → *_LOCKED\n");
		ACaptureRequest *autoReq = ACaptureRequest_copy(preview);
		uint8_t mode = ACAMERA_CONTROL_AF_MODE_AUTO;
		ACaptureRequest_setEntry_u8(autoReq, ACAMERA_CONTROL_AF_MODE, 1, &mode);
		ACameraCaptureSession_setRepeatingRequest(sess, &cc, 1, &autoReq, nullptr);
		const bool inactive = waitAf(3000, [](int s) { return s == ACAMERA_CONTROL_AF_STATE_INACTIVE; });
		check(inactive, "切到 AUTO 后是 INACTIVE（不触发就不动镜头）");
		ACaptureRequest *autoTrig = ACaptureRequest_copy(autoReq);
		t = ACAMERA_CONTROL_AF_TRIGGER_START;
		ACaptureRequest_setEntry_u8(autoTrig, ACAMERA_CONTROL_AF_TRIGGER, 1, &t);
		{
			std::lock_guard<std::mutex> lk(gS.m);
			gS.afHistory.clear();
		}
		ACameraCaptureSession_capture(sess, &cc, 1, &autoTrig, nullptr);
		const bool autoLocked = waitAf(8000, [](int s) {
			return s == ACAMERA_CONTROL_AF_STATE_FOCUSED_LOCKED ||
			       s == ACAMERA_CONTROL_AF_STATE_NOT_FOCUSED_LOCKED;
		});
		check(autoLocked, "8 秒内 *_LOCKED");
		{
			std::lock_guard<std::mutex> lk(gS.m);
			bool sawScan = false;
			printf("     序列：");
			for (int s : gS.afHistory) {
				printf("%s ", afName(s));
				sawScan = sawScan || s == ACAMERA_CONTROL_AF_STATE_ACTIVE_SCAN;
			}
			printf("\n");
			check(sawScan, "中间出现过 ACTIVE_SCAN");
		}
		/* 回到连续模式的预览 */
		ACameraCaptureSession_setRepeatingRequest(sess, &cc, 1, &preview, nullptr);
		ACaptureRequest_free(trig);
		ACaptureRequest_free(autoReq);
		ACaptureRequest_free(autoTrig);
	}

	printf("== 5. 重复请求连拍 JPEG（JPEG_ORIENTATION=90）\n");
	printf("     框架对【同一个】重复请求从第二帧起给 HAL 发空设置（Camera3Device 按 mPrevRequest 比较）\n");
	printf("     —— 第 2 张起测的正是\"设置为空 = 沿用上一帧\"\n");
	ACaptureRequest *still = nullptr;
	ACameraDevice_createCaptureRequest(dev, TEMPLATE_STILL_CAPTURE, &still);
	ACaptureRequest_addTarget(still, pt);
	ACaptureRequest_addTarget(still, jt);
	int32_t rot = 90;
	ACaptureRequest_setEntry_i32(still, ACAMERA_JPEG_ORIENTATION, 1, &rot);
	{
		std::lock_guard<std::mutex> lk(gS.m);
		gS.jpegDims.clear();
	}
	ACameraCaptureSession_setRepeatingRequest(sess, &cc, 1, &still, nullptr);
	{
		std::unique_lock<std::mutex> lk(gS.m);
		gS.cv.wait_for(lk, std::chrono::seconds(20), [] { return gS.jpegDims.size() >= 3; });
	}
	ACameraCaptureSession_stopRepeating(sess);
	{
		std::lock_guard<std::mutex> lk(gS.m);
		for (size_t i = 0; i < gS.jpegDims.size(); i++)
			printf("     第 %zu 张 %dx%d\n", i + 1, gS.jpegDims[i].first, gS.jpegDims[i].second);
		check(gS.jpegDims.size() >= 3, "收到 >=3 张 JPEG");
		bool allRot = gS.jpegDims.size() >= 3;
		for (const auto &d : gS.jpegDims)
			allRot = allRot && d.first == jpgH && d.second == jpgW;
		printf("     期望每张 %dx%d（宽高互换 = 像素真的转了 90°）\n", jpgH, jpgW);
		check(allRot, "每一张都转了 90°");
	}

	ACameraCaptureSession_stopRepeating(sess);
	std::this_thread::sleep_for(std::chrono::milliseconds(500));
	{
		std::lock_guard<std::mutex> lk(gS.m);
		printf("== 共 %d 个结果，%d 次帧失败\n", gS.results, gS.failures);
		check(gS.failures == 0, "没有帧失败");
	}
	ACameraCaptureSession_close(sess);
	ACameraDevice_close(dev);
	ACaptureRequest_free(preview);
	ACaptureRequest_free(still);
	AImageReader_delete(prev);
	AImageReader_delete(jpeg);
	ACameraManager_delete(mgr);

	if (gFails)
		printf("RESULT: FAIL (%d)\n", gFails);
	else
		printf("RESULT: PASS\n");
	return gFails ? 1 : 0;
}
