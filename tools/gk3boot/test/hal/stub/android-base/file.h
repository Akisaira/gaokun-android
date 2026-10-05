#pragma once
#include <fcntl.h>
#include <unistd.h>
#include <string>
namespace android::base {
inline bool ReadFileToString(const std::string& path, std::string* out) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    out->clear();
    char buf[65536];
    ssize_t n;
    while ((n = read(fd, buf, sizeof buf)) > 0) out->append(buf, n);
    close(fd);
    return n == 0;
}
inline bool WriteFully(int fd, const void* data, size_t len) {
    const char* p = (const char*)data;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) return false;
        p += n; len -= n;
    }
    return true;
}
}  // namespace android::base
