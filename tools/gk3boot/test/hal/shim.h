// macOS 上跑 Gk3Boot.cpp 的垫片：bionic 有、macOS 没有的两样，外加一个测试钩子（statvfs）
#pragma once
#include <fcntl.h>
#include <unistd.h>
#ifndef O_DIRECT
#define O_DIRECT 0
#endif
#ifndef TEMP_FAILURE_RETRY
#define TEMP_FAILURE_RETRY(exp) ({ __typeof__(exp) _rc; do { _rc = (exp); } while (_rc == -1 && errno == EINTR); _rc; })
#endif
#include <errno.h>
// ESP 剩余空间：GK3T_ESP_FREE_KB 设了就按它报（测 fastboot.img 的空间判断），否则用真的 statvfs。
// 函数式宏只替换"statvfs("，struct statvfs 不受影响；系统头先 include，宏在它之后才定义。
#include <stdlib.h>
#include <sys/statvfs.h>
static inline int gk3t_statvfs(const char* path, struct statvfs* b) {
    int r = statvfs(path, b);
    const char* f = getenv("GK3T_ESP_FREE_KB");
    if (r == 0 && f) {
        b->f_frsize = 1024;
        b->f_bavail = (fsblkcnt_t)strtoull(f, nullptr, 10);
    }
    return r;
}
#define statvfs(p, b) gk3t_statvfs(p, b)
