#pragma once
#include <chrono>
#include <fstream>
#include <map>
#include <mutex>
#include <string>
#include <thread>
namespace android::base {
inline std::mutex& PropMu() { static std::mutex m; return m; }
inline std::map<std::string, std::string>& Props() {
    static std::map<std::string, std::string> m = [] {
        std::map<std::string, std::string> r;
        const char* f = getenv("GK3T_PROPS");
        if (f) {
            std::ifstream in(f);
            std::string line;
            while (std::getline(in, line)) {
                auto eq = line.find('=');
                if (eq != std::string::npos) r[line.substr(0, eq)] = line.substr(eq + 1);
            }
        }
        return r;
    }();
    return m;
}
inline std::string GetProperty(const std::string& k, const std::string& def) {
    std::lock_guard<std::mutex> g(PropMu());
    auto it = Props().find(k);
    return it == Props().end() ? def : it->second;
}
inline bool SetProperty(const std::string& k, const std::string& v) {
    if (v.size() > 91) abort();
    std::lock_guard<std::mutex> g(PropMu());
    Props()[k] = v;
    return true;
}
inline bool WaitForProperty(const std::string& k, const std::string& v,
                            std::chrono::milliseconds = std::chrono::milliseconds::max()) {
    while (GetProperty(k, "") != v) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    return true;
}
}  // namespace android::base
