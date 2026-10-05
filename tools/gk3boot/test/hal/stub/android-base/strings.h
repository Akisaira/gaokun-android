#pragma once
#include <string>
#include <vector>
namespace android::base {
// 与 libbase 同语义：delimiters 里任一字符都是分隔符，保留空段
inline std::vector<std::string> Split(const std::string& s, const std::string& delimiters) {
    std::vector<std::string> r;
    size_t base = 0, found;
    while (true) {
        found = s.find_first_of(delimiters, base);
        r.push_back(s.substr(base, found - base));
        if (found == std::string::npos) break;
        base = found + 1;
    }
    return r;
}
inline std::string Trim(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && isspace((unsigned char)s[a])) a++;
    while (b > a && isspace((unsigned char)s[b - 1])) b--;
    return s.substr(a, b - a);
}
inline bool StartsWith(const std::string& s, const std::string& p) { return s.compare(0, p.size(), p) == 0; }
inline bool EndsWith(const std::string& s, const std::string& p) {
    return s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0;
}
inline std::string Join(const std::vector<std::string>& v, const std::string& sep) {
    std::string r;
    for (size_t i = 0; i < v.size(); i++) { if (i) r += sep; r += v[i]; }
    return r;
}
}  // namespace android::base
