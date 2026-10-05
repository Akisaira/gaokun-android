#pragma once
#include <errno.h>
#include <string.h>
#include <iostream>
#include <sstream>
struct StubLogLine {
    std::ostringstream os;
    const char* sev;
    int err;
    bool perr;
    StubLogLine(const char* s, bool p) : sev(s), err(errno), perr(p) {}
    ~StubLogLine() {
        if (perr) os << ": " << strerror(err);
        std::cerr << "[" << sev << "] " << os.str() << std::endl;
    }
    template <typename T> StubLogLine& operator<<(const T& v) { os << v; return *this; }
};
#define LOG(sev) StubLogLine(#sev, false)
#define PLOG(sev) StubLogLine(#sev, true)
#define CHECK(x) do { if (!(x)) abort(); } while (0)
