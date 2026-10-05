// Gk3Boot.cpp 的主机测试驱动。
//   driver mkmisc <file> <streak> [event[:notified] ...]   造一份 64 KiB misc（GK3 记录在 8 KiB）
//   driver nomisc <file>                                  造一份全零 misc（无 GK3 记录）
//   driver dump <file>                                    打印 GK3 记录
//   driver run                                            起线程、设触发属性、等 done，打印导出的属性
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <string>
#include <thread>

#include <android-base/properties.h>
#include <gk3core.h>

#include "Gk3Boot.h"

extern std::atomic<int> g_rw_mounts, g_ro_mounts;

static gk3_ev_code Code(const char* n) {
    for (int c = 0; c <= GK3_EV_BCB_IGNORED; c++)
        if (!strcmp(gk3_ev_name((gk3_ev_code)c), n)) return (gk3_ev_code)c;
    fprintf(stderr, "unknown event %s\n", n);
    exit(2);
}

int main(int argc, char** argv) {
    if (argc >= 3 && !strcmp(argv[1], "nomisc")) {
        static uint8_t m[65536];
        FILE* f = fopen(argv[2], "wb"); fwrite(m, 1, sizeof m, f); fclose(f);
        return 0;
    }
    if (argc >= 4 && !strcmp(argv[1], "mkmisc")) {
        static uint8_t m[65536];
        uint8_t* rec = m + GK3_MISC_GK3_OFF;
        gk3_rec_init(rec);
        gk3_rec_set_boot_streak(rec, (uint8_t)atoi(argv[3]));
        for (int i = 4; i < argc; i++) {
            char n[64]; snprintf(n, sizeof n, "%s", argv[i]);
            char* colon = strchr(n, ':');
            if (colon) *colon = 0;
            uint32_t seq = gk3_rec_event_add(rec, Code(n), 1, 0);
            if (colon) gk3_rec_events_mark_notified(rec, seq);
        }
        gk3_rec_seal(rec);
        memset(m + 10240, 0x5a, 2048);  // 记录之后、同一 4 KiB 块里的字节：写回时必须原样保留
        FILE* f = fopen(argv[2], "wb"); fwrite(m, 1, sizeof m, f); fclose(f);
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "dump")) {
        static uint8_t m[65536];
        FILE* f = fopen(argv[2], "rb"); fread(m, 1, sizeof m, f); fclose(f);
        uint8_t* rec = m + GK3_MISC_GK3_OFF;
        if (gk3_rec_validate(rec) != GK3_OK) { printf("record: invalid\n"); return 0; }
        printf("record: valid streak=%u\n", gk3_rec_boot_streak(rec));
        gk3_event ev[GK3_EV_N];
        uint32_t n = gk3_rec_events(rec, ev, GK3_EV_N);
        for (uint32_t i = 0; i < n; i++)
            printf("  ev seq=%u %s notified=%d\n", ev[i].seq, gk3_ev_name((gk3_ev_code)ev[i].code), ev[i].flags & 1);
        bool tail_ok = true;
        for (int i = 10240; i < 12288; i++) tail_ok &= m[i] == 0x5a;
        printf("tail bytes 10240..12287 preserved: %s\n", tail_ok ? "yes" : "NO");
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "run")) {
        gaokun3::StartBootCompletedWorker();
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        android::base::SetProperty("vendor.gaokun3.boot.done", "1");
        for (int i = 0; i < 500 && android::base::GetProperty("vendor.gaokun3.bootentry.done", "").empty(); i++)
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        for (const char* k : {"via", "event", "notify", "bypassed", "streak", "mode", "version", "error", "done"})
            printf("bootentry.%s=%s\n", k,
                   android::base::GetProperty(std::string("vendor.gaokun3.bootentry.") + k, "<unset>").c_str());
        printf("mounts: ro=%d rw=%d\n", g_ro_mounts.load(), g_rw_mounts.load());
        return 0;
    }
    fprintf(stderr, "usage\n");
    return 2;
}
