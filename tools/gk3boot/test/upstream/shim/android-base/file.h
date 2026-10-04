// 测试垫片：android-base 的 ReadFully / WriteFully。
#pragma once
#include <unistd.h>
#include <cstddef>

namespace android {
namespace base {
inline bool ReadFully(int fd, void *buf, size_t n)
{
    char *p = static_cast<char *>(buf);
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r <= 0)
            return false;
        p += r;
        n -= static_cast<size_t>(r);
    }
    return true;
}
inline bool WriteFully(int fd, const void *buf, size_t n)
{
    const char *p = static_cast<const char *>(buf);
    while (n) {
        ssize_t r = write(fd, p, n);
        if (r <= 0)
            return false;
        p += r;
        n -= static_cast<size_t>(r);
    }
    return true;
}
}  // namespace base
}  // namespace android
