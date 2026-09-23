/*
 * gaokun3-ssc-test —— 从 Android 侧直接读 SLPI 传感器
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 对标 Linux 上的 ssccli。存在的意义：它验证的正是将来 sensors HAL 逻辑的
 * 90%（SUID 查找 → 使能 → 解读数），但不牵扯 AIDL、不牵扯 SensorService，
 * 失败时容易定位。
 *
 * 前提：hexagonrpcd 在跑（否则 QRTR 上没有服务 400）。
 *   /vendor/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /vendor/etc/hexagonrpcd-root
 *
 * 用法：
 *   gaokun3-ssc-test                     读加速度计 10 Hz 10 秒
 *   gaokun3-ssc-test accel 20 5          指定 data_type / 采样率 / 秒数
 *   gaokun3-ssc-test gyro
 *   gaokun3-ssc-test ambient_light 1 10 onchange   用 514（变化时上报）使能
 * 每次都会列出该 data_type 的【全部】UID 并打印其属性（名字、厂商等字符串/数值），
 * 用来分清提供者是物理芯片还是虚拟传感器。
 * data_type 可用值见 docs/sensors-ssc-protocol.md（accel / gyro / mag /
 * ambient_light / proximity / rotv）。
 *
 * ⚠️ ambient_light：2026-09-23 起 tcs3701 能注册出来（#118），但使能后只回一条
 *    msg_id=130（载荷 08 04）、没有读数，而且仍会污染整个 SSC 会话 —— 之后连加速度计
 *    也读不到，必须重启 hexagonrpcd（#37）。测完它就按 scripts/ssc/README 收工。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <string>
#include <vector>

#include "ssc_client.h"
#include "ssc-sensor-accelerometer.pb.h"

using gaokun3::SscClient;
using gaokun3::SscReport;

// 收属性应答（msg_id=128）并把每个属性的字符串/数值打出来。最多等 3 秒。
static void PrintAttributes(SscClient* client, const SscUid& uid) {
    for (int t = 0; t < 3; t++) {
        std::vector<SscReport> reports;
        std::string ignore;
        if (!client->ReadReports(&reports, 1000, &ignore)) continue;
        for (size_t i = 0; i < reports.size(); i++) {
            const SscReport& r = reports[i];
            if (r.msg_id != gaokun3::kMsgResponseGetAttributes) continue;
            if (r.uid_low != uid.low() || r.uid_high != uid.high()) continue;
            SscAttrResponse resp;
            if (!resp.ParseFromString(r.payload)) {
                printf("      （属性应答解析失败，%zu 字节）\n", r.payload.size());
                return;
            }
            for (int a = 0; a < resp.attr_size(); a++) {
                const SscAttr& at = resp.attr(a);
                printf("      attr %d:", at.id());
                for (int v = 0; v < at.value_array().v_size(); v++) {
                    const SscAttrValue& x = at.value_array().v(v);
                    if (x.has_s()) printf(" \"%s\"", x.s().c_str());
                    if (x.has_i()) printf(" %lld", static_cast<long long>(x.i()));
                    if (x.has_f()) printf(" %g", x.f());
                    if (x.has_b()) printf(" %s", x.b() ? "true" : "false");
                    if (x.has_a()) printf(" [数组 %d]", x.a().element_size());
                }
                printf("\n");
            }
            return;
        }
    }
    printf("      （3 秒内没收到属性应答）\n");
}

static int64_t NowMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

int main(int argc, char** argv) {
    const std::string data_type = (argc > 1) ? argv[1] : "accel";
    const float rate_hz = (argc > 2) ? strtof(argv[2], nullptr) : 10.0f;
    const int seconds = (argc > 3) ? atoi(argv[3]) : 10;

    SscClient client;
    std::string err;

    if (!client.Open(&err)) {
        fprintf(stderr, "打开失败: %s\n", err.c_str());
        return 1;
    }
    printf("SSC 服务 400 在 node %u port %u\n", client.service_node(),
           client.service_port());

    // hexagonrpcd 刚起来时 SSC 要沉降约 20 秒，给足 40 秒
    printf("等 SSC 就绪（最多 40 秒，刚重启过 hexagonrpcd 时确实要等）…\n");
    if (!client.WaitForService(40000, &err)) {
        fprintf(stderr, "SSC 没就绪: %s\n", err.c_str());
        return 1;
    }
    printf("SSC 已就绪\n");

    std::vector<SscUid> uids;
    if (!client.FindSensors(data_type, &uids, &err)) {
        fprintf(stderr, "找不到传感器 %s: %s\n", data_type.c_str(), err.c_str());
        return 1;
    }
    printf("data_type=%s 共 %zu 个提供者\n", data_type.c_str(), uids.size());
    for (size_t k = 0; k < uids.size(); k++) {
        printf("  [%zu] UID = %016llx%016llx\n", k,
               static_cast<unsigned long long>(uids[k].high()),
               static_cast<unsigned long long>(uids[k].low()));
        if (client.RequestAttributes(uids[k], &err)) PrintAttributes(&client, uids[k]);
    }
    const SscUid uid = uids[0];
    printf("传感器 %s 的 UID = %016llx%016llx\n", data_type.c_str(),
           static_cast<unsigned long long>(uid.high()),
           static_cast<unsigned long long>(uid.low()));

    const bool on_change = (argc > 4) && strcmp(argv[4], "onchange") == 0;
    const bool ok = on_change ? client.EnableOnChange(uid, rate_hz, &err)
                              : client.EnableContinuous(uid, rate_hz, &err);
    if (!ok) {
        fprintf(stderr, "使能失败: %s\n", err.c_str());
        return 1;
    }
    printf("已请求 %.1f Hz %s上报，收 %d 秒\n", rate_hz,
           on_change ? "变化时（514）" : "连续（513）", seconds);

    const int64_t deadline = NowMs() + seconds * 1000;
    int n_meas = 0, n_other = 0;
    while (NowMs() < deadline) {
        std::vector<SscReport> reports;
        std::string ignore;
        if (!client.ReadReports(&reports, 1000, &ignore)) continue;
        for (size_t i = 0; i < reports.size(); i++) {
            const SscReport& r = reports[i];
            if (r.msg_id != gaokun3::kMsgReportMeasurement) {
                n_other++;
                printf("  [其它消息] msg_id=%u  %zu 字节:", r.msg_id,
                       r.payload.size());
                // 载荷原样十六进制打出来（前 32 字节），不猜它是什么结构
                for (size_t j = 0; j < r.payload.size() && j < 32; j++)
                    printf(" %02x", static_cast<unsigned char>(r.payload[j]));
                printf("\n");
                continue;
            }
            n_meas++;
            if (data_type == "accel" || data_type == "gyro" ||
                data_type == "mag") {
                // 这三个的载荷布局相同：repeated float + accuracy
                SscAccelerometerResponse m;
                if (!m.ParseFromString(r.payload)) {
                    printf("  [解析失败，%zu 字节]\n", r.payload.size());
                    continue;
                }
                if (m.acceleration_size() >= 3) {
                    printf("  X=%9.6f Y=%9.6f Z=%9.6f  accuracy=%d\n",
                           m.acceleration(0), m.acceleration(1),
                           m.acceleration(2), m.accuracy());
                } else {
                    printf("  [只有 %d 个分量]\n", m.acceleration_size());
                }
            } else {
                // 其它传感器的事件也是 repeated float（字段 1）+ accuracy，
                // 环境光的第 0 个就是 lux —— 全部打出来，不猜含义。
                SscAccelerometerResponse m;
                if (!m.ParseFromString(r.payload)) {
                    printf("  msg_id=%u  %zu 字节（解析失败）\n", r.msg_id,
                           r.payload.size());
                    continue;
                }
                printf("  data[%d] =", m.acceleration_size());
                for (int j = 0; j < m.acceleration_size(); j++)
                    printf(" %.3f", m.acceleration(j));
                printf("  accuracy=%d\n", m.accuracy());
            }
        }
    }

    client.Disable(uid, &err);
    printf("\n共 %d 条测量、%d 条其它消息\n", n_meas, n_other);
    if (n_meas == 0) {
        fprintf(stderr,
                "一条读数都没有。排查顺序：\n"
                "  1) gaokun3-qrtr-lookup 400 —— 服务还在吗\n"
                "  2) hexagonrpcd 的日志里 DSP 还在请求文件吗\n"
                "  3) 之前是不是试过 ambient_light？它会污染整个会话，"
                "重启 hexagonrpcd 再等 20 秒\n");
        return 2;
    }
    // 静止平放时加速度计 Z 应该 ≈ 9.8 m/s²，这是整条通路的硬判据
    return 0;
}
