#pragma once
#include <unistd.h>
namespace android::base {
class unique_fd {
  public:
    explicit unique_fd(int fd = -1) : fd_(fd) {}
    ~unique_fd() { if (fd_ >= 0) close(fd_); }
    int get() const { return fd_; }
    operator int() const { return fd_; }
    unique_fd(const unique_fd&) = delete;
  private:
    int fd_;
};
}  // namespace android::base
