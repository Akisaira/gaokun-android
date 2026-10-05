// macOS 上跑 Gk3Boot.cpp 的垫片：bionic 有、macOS 没有的两样
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
