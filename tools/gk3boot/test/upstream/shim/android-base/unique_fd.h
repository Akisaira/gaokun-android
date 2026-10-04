// 测试垫片：android-base 的 unique_fd（只要 libboot_control.cpp 用到的那几样）。
#pragma once
#include <unistd.h>

namespace android {
namespace base {
class unique_fd {
  public:
    explicit unique_fd(int fd = -1) : fd_(fd) {}
    ~unique_fd() { if (fd_ >= 0) close(fd_); }
    unique_fd(const unique_fd &) = delete;
    unique_fd &operator=(const unique_fd &) = delete;
    int get() const { return fd_; }
    operator int() const { return fd_; }

  private:
    int fd_;
};
}  // namespace base
}  // namespace android
